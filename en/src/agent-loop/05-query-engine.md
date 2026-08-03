The previous 4 articles covered specific mechanisms inside the loop: tool declaration, permissions, hooks, parallel scheduling, stop_reason handling, error recovery. Each one was a specific angle.

This article **unifies them**. The core of the main loop isn't that 5-line pseudocode — it's **an explicit state machine**. Before every LLM call, the loop first decides "which path do I take now"; after every LLM call, the loop first decides "which path do I take next." Recovery / retry / autocompact / stop-hook blocking are all **first-class branches** inside this state machine.

Seeing the main loop clearly means answering a few questions:

- What does the 5-line pseudocode actually look like in the Claude Code source?
- What exactly is a loop iteration — how many things happen in one iteration?
- What determines which path the loop takes?
- Is recovery nested, or is it sequential?

## First, a Naming Misconception to Correct

`src/QueryEngine.ts` is a single 45KB file — the name makes it sound like "the query engine main loop."

**It isn't.**

`QueryEngine` is an **SDK adapter layer** — a stable interface for SDK / non-interactive CLI consumers, wrapping the underlying loop. Its `submitMessage()` is an async generator, used to progressively expose loop events to SDK consumers.

**The real main loop lives in the `queryLoop` function in `src/query.ts`** — 1700+ lines. Everything discussed in this article is about that `queryLoop`.

Why isn't `QueryEngine` the engine, and `queryLoop` is? Most likely a naming accident of history — `QueryEngine` was added later as the adapter layer for SDK integration, while the main loop had already been called `queryLoop` for a long time. Seeing a 45KB file and assuming it's the main loop is a **misconception**. The main loop itself isn't actually that large — its complexity is high instead: 1700 lines that are almost entirely branching decisions.

## The Shape of the State Machine

The main loop has this skeleton:

```
while (true) {
    Decide what to do this round based on state.transition.reason
    Execute: call LLM · process stream · append messages · run tools ...
    Produce a new state.transition · deciding what to do next
}
```

**The key is `state.transition.reason`** — a union with exactly **7 values**:

- **`next_turn`** — normal forward progress: call the LLM, process the output
- **`collapse_drain_retry`** — context is full; retry after triggering aggressive compaction (context collapse)
- **`reactive_compact_retry`** — the API returned prompt_too_long; retry after compacting
- **`max_output_tokens_escalate`** — output tokens hit the ceiling; retry after raising max_tokens
- **`max_output_tokens_recovery`** — hit the ceiling again after raising it; retry after injecting a "continue" message
- **`stop_hook_blocking`** — the Stop hook blocked the exit; forced to run another round
- **`token_budget_continuation`** — output-token-budget mode; continue after exceeding +500k

**At the start of every iteration**, the loop checks `state.transition.reason` to decide the path:
- `next_turn` — call the LLM normally
- `reactive_compact_retry` — take the compact branch, then call the LLM
- `stop_hook_blocking` — the loop was about to exit, but a hook blocked it, so it's forced to run again

**At the end of every iteration**, the loop decides the next transition based on this round's outcome. Continue with `next_turn`? Need recovery? Or can it end with `completed`?

**This is what "the loop is a state machine" means** — not a simple `while (has_tool_use)`, but `while (transition ≠ terminal)`.

## What Happens in One Iteration

One iteration = one API call + one batch of tool execution. Concretely:

1. **Build the request** — assemble the messages array, load tools, system prompt
2. **Call the LLM** — streaming, consuming events one by one (see 06)
3. **Determine the stop reason** — find tool_use in the content / check stop_reason (see [04](04-stop-reason.md))
4. **Execute tools** — permission approval → hooks → parallel scheduling (see [01](01-tool-permission.md) / [02](02-hooks.md) / [03](03-parallel-scheduling.md))
5. **Decide the next transition** — update state.transition.reason based on this round's result

**Every iteration is this full five-step cycle.** The complexity isn't in a single iteration — it's in **state continuity across multiple iterations**.

## Loop Termination — Terminal States

Paired with transitions is a set of **Terminal** states — signaling that the loop should end:

- **`completed`** — everything went normally, the LLM is done talking (no tool_use in the content), clean exit
- **`max_turns`** — hit the maxTurns safety cap, forced exit
- **`aborted_tools`** — user Ctrl-C'd during tool execution
- **`aborted_streaming`** — user Ctrl-C'd during LLM streaming
- **`hook_stopped`** — a Post-tool hook blocked, forced exit
- **`stop_hook_prevented`** — the Stop hook refused to let it exit, but retries ran out
- **`blocking_limit`** — hit some kind of blocking limit
- **`image_error`** / **`model_error`** — an unrecoverable upstream error
- **`prompt_too_long`** — not even compaction can save it; ultimately thrown to the user

**There are also 10+ Terminal types** — each one signaling "the loop ended for this specific reason." The SDK consumer takes the Terminal and gives the user a different UX depending on the type.

## After a Failure, Return to the Main Loop — Not Layered Retries Inside `try/catch`

This is the same design philosophy as [how tool failures are handled](03-parallel-scheduling.md#what-happens-when-a-tool-blows-up): **turn the error into a state or piece of data that can be handled by continuing, rather than letting an exception directly interrupt the loop.** A tool error becomes a `tool_result` handed to the LLM; when the main loop needs to recover, it becomes a `transition`, handed to the next round.

In a naive design, recovery usually looks like this:

```python
try:
    call_llm()
except PromptTooLong:
    compact()
    call_llm()  # nested retry
except MaxTokens:
    escalate()
    call_llm()
```

**That's not how Claude Code writes it.**

When Claude Code hits a situation that needs recovery, it doesn't immediately retry in the current round with try-except — instead it first records what should happen next, then enters the next round of the main loop, and the next round carries out the corresponding recovery action.

```
This round ends (some kind of failure)
    ↓
Produce a new state.transition.reason = 'reactive_compact_retry'
    ↓
loop moves to the next iteration · starting again from the top of while
    ↓
check transition first · it's reactive_compact_retry · take the compact branch
    ↓
compact finishes · continue this iteration's "call LLM" step
    ↓
get the result · produce the next transition again ...
```

**This is the core design insight** — recovery is a **first-class state transition** of the loop, not exception catching.

**Why design it this way?** Two benefits:

**Benefit 1 · Recovery can chain**:

After one iteration completes, it enters `reactive_compact_retry` — compact finishes, then the LLM is called again — and the result is **max_tokens again**. Now the transition becomes `max_output_tokens_escalate`. Then **this** hits the ceiling again — the transition becomes `max_output_tokens_recovery`, injecting a continue message. All of it happens inside the same `while` loop, dispatched by transition each time it enters an iteration.

**With nested try-except**, every layer of recovery would need its own nested try, or complicated re-entry checks — it would inevitably get messy.

**Benefit 2 · Testability**:

Source comments explicitly state that `state.transition` is **for use in test assertions**. After a piece of code finishes executing, asserting `state.transition.reason === 'reactive_compact_retry'` tells you whether that branch was hit — far more stable than grepping error messages.

## Withholding Errors from the Outside World — The Loop's Core Philosophy

"Withhold" means **holding something back temporarily, not passing it outward**. Here it means: when the loop hits an error, it doesn't notify the SDK caller right away — it first tries to recover internally, and only reports the final error once recovery has failed.

This design has an even deeper goal — **hiding intermediate errors from the SDK caller**.

There's a blunt comment in the Claude Code source: some SDK callers (like cowork, the desktop product) see an `error` field in an API response and assume "it's terminated," "the loop is dead" — and immediately surface an error to the user.

**But Claude Code wants to hide errors during recovery** — meaning, when it receives `prompt_too_long`, it does **not** propagate it upward. It first tries to compact, and if that succeeds and the next LLM call goes smoothly, then as far as the SDK layer is concerned, this error **never happened**. Only once recovery also fails does it throw the terminal error.

**This is why the loop is a "recovery engine," not an "error handler"** — an error is a signal **internal** to the loop, not an **external** output of the loop.

## A Counterintuitive Fact: The Main Agent and Sub-Agents Share the **Same** `queryLoop` Code

The intuitive way to build a sub-agent system is: sub-agents should have their own loop logic, their own state machine.

**Claude Code does the opposite**: both the main agent and sub-agents call the same `queryLoop` implementation — they just each run independently, distinguished via `toolUseContext.agentId`. "The same" here means **reusing the same code**, not sharing the same running loop instance.

The cost: roughly a dozen or so `if (!toolUseContext.agentId)` checks scattered throughout the loop, used to distinguish "things that should only happen on the main thread" — MemoryPrefetch, mobile UI summaries, MCP cleanup, the Stop hook's lock, and so on.

The benefit: fix a bug in one place, and the main thread and every sub-agent benefit at once.

**Shared loop, flag-based branching** — this is a classic **shared code vs. forked code** trade-off. A sub-agent's independent context / worktree isolation / sandboxed execution are all handled by `AgentTool.tsx`, outside the loop; the loop itself **doesn't know** whether it's a sub-agent or not — it just runs the same iterations.

More in 09 · Sidechain · From Sub-Agent to agentId Routing.

## The Full Picture of the Main Loop

Putting the mechanisms from the previous 4 articles together with the state machine above, here's the full picture of one iteration of the main loop:

```
─── Start of one iteration ─────────────────────
Dispatch based on state.transition.reason:

  next_turn                    → do nothing · go straight into the main flow
  reactive_compact_retry       → run compact first
  collapse_drain_retry         → run context-collapse
  max_output_tokens_escalate   → raise the max_tokens ceiling
  max_output_tokens_recovery   → inject a "[continue]" message
  stop_hook_blocking           → no-op · go straight into the main flow (because exit is being refused)
  token_budget_continuation    → continue in output mode

─── Main flow ─────────────────────────────────
Call the LLM · consume the stream (article 06)
      ↓
Messages appended one by one into the messages array (Context series 02)
      ↓
Check: does the content have tool_use?
      ├─ no → check whether stop_reason is a special one (article 04)
      │       ├─ yes → produce a recovery transition · handled next iteration
      │       └─ no → check whether the Stop hook blocks
      │               ├─ blocked → transition = stop_hook_blocking · continue
      │               └─ passed → return { reason: 'completed' } · loop exits
      └─ yes → execute tools:
              Permission approval (article 01)
                    ↓
              PreToolUse hook (article 02)
                    ↓
              Parallel scheduling · batched by isConcurrencySafe (article 03)
                    ↓
              tool_result appended · pairing invariant maintained (Context series 02)
                    ↓
              PostToolUse hook (article 02)
              (any failure along the way · turned into an is_error tool_result · not thrown)

─── End of iteration ─────────────────────────
Update state.transition.reason based on this round's result
      ↓
Back to the top of while · next iteration
```

**This is what the previous 4 articles look like, unified.** Every layer of mechanism is one link in the iteration — the specific mechanisms from the previous 4 articles are all embedded in this skeleton.

## Summary

- **`QueryEngine.ts` is not the main loop** — it's the SDK adapter layer. The main loop lives in `queryLoop` in `src/query.ts`
- **The main loop is a state machine, not a simple while** — 7 values of `state.transition.reason`, 10+ Terminal types
- **Recovery is a sequential transition, not a nested try** — recovery can chain, and can be tested
- **Withholding errors from the outside world** — the loop hides intermediate errors it can recover from itself from the SDK caller, only throwing the ones it truly can't save
- **The loop is a recovery engine, not an error handler**
- **The main agent and sub-agents reuse the same `queryLoop` code** — each runs independently, branching via the `agentId` flag

The next article, 06 · Streaming · SSE Event Stream · Ink Consumption, covers the **details** of the "call the LLM" step in the main loop — the Anthropic API returns results as a streamed sequence of SSE fragments; how do the 6 event types get merged into a complete message, and how does the UI layer render incrementally?

---

## References

**Main file locations** (v2.1.220):
- `src/query.ts` · `queryLoop` main loop · a 1700+ line while-based state machine
- The `state.transition.reason` union definition in `src/query.ts`
- `src/QueryEngine.ts` · SDK adapter layer · `submitMessage()`
- `src/services/tools/toolOrchestration.ts` · tool execution within an iteration

**Related articles**:
- [00 · Intro · From Chat Window to Loop](00-intro.md) · the 5-line pseudocode skeleton
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) · permissions within an iteration
- [02 · Hooks · Programmable Intervention Points on the Loop](02-hooks.md) · hooks within an iteration
- [03 · From Reading a File to Parallel Scheduling](03-parallel-scheduling.md) · tool execution within an iteration
- [04 · From "Done Answering" to the 7 Meanings of stop_reason](04-stop-reason.md) · stop-condition checks within an iteration
- 06 · Streaming · SSE Event Stream · Ink Consumption · next article · the details of "call the LLM" within an iteration
- [07 · Retry and Error Recovery](07-retry-recovery.md) · directly corresponds to this article's recovery transitions
- 09 · Sidechain · From Sub-Agent to Loop · shared loop / agentId routing

**Anthropic official**:
- [Messages API — streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · the streaming protocol
