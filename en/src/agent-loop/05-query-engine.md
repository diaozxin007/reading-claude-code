The previous four chapters examined the loop's concrete mechanisms: tool declarations, permissions, hooks, parallel scheduling, `stop_reason` handling, and error recovery. Each approached the loop from a different angle.

This chapter **unifies them.** The core of the main loop isn't those 5 lines of pseudocode — it's **an explicit state machine**: before every LLM call, the loop first decides "which path do I take now," and after every LLM call, it decides "which path do I take next." Recovery, retry, autocompact, and Stop-hook blocking are all **first-class branches** in this state machine.

Seeing the main loop clearly means answering a few questions:

- What does that 5-line pseudocode actually look like in the Claude Code source?
- What exactly is a loop iteration — how many things does one iteration do?
- What determines which path the loop takes?
- Is recovery nested or parallel?

## First, correcting a naming misconception

`src/QueryEngine.ts` is a 45KB file — the name suggests "the query engine main loop."

**It isn't.**

`QueryEngine` is the **SDK adapter layer** — a stable interface for SDK / non-interactive CLI consumers, wrapping the underlying loop. Its `submitMessage()` is an async generator used to progressively expose loop events to SDK consumers.

**The real main loop lives in the `queryLoop` function in `src/query.ts`** — 1700+ lines. Everything in this chapter is about that `queryLoop`.

Why isn't QueryEngine named QueryEngine, and why is queryLoop actually the engine? Most likely historical naming — `QueryEngine` was added later as the adapter layer for SDK integration, while the main loop had already been called `queryLoop` for a long time. Seeing a 45KB file and assuming it's the main loop is simply **a misunderstanding**. The main loop is actually not that large — but it's high in complexity, with nearly all of its 1700 lines being branching decisions.

## The shape of the state machine

The main loop's skeleton looks like this:

```
while (true) {
    Decide what to do this round based on state.transition.reason
    Execute: call the LLM · process the stream · append messages · run tools ...
    Generate a new state.transition · decide what to do next
}
```

**The key is `state.transition.reason`** — a union with **7 possible values**:

- **`next_turn`** — normal forward progress: call the LLM, process its output
- **`collapse_drain_retry`** — context is full, retry after triggering aggressive compaction (context collapse)
- **`reactive_compact_retry`** — the API returned `prompt_too_long`, retry after compacting
- **`max_output_tokens_escalate`** — output tokens hit the ceiling, retry after raising `max_tokens`
- **`max_output_tokens_recovery`** — hit the ceiling again after raising it, retry after injecting a "continue" message
- **`stop_hook_blocking`** — a Stop hook blocked, force another round
- **`token_budget_continuation`** — output token budget mode, continuing past a +500k threshold

**At the start of each iteration**, the loop checks `state.transition.reason` to decide the path:
- `next_turn` — call the LLM normally
- `reactive_compact_retry` — take the compact branch, then call the LLM again
- `stop_hook_blocking` — the loop was about to exit, but a hook blocked it, so force another round

**At the end of each iteration**, the loop decides the next transition based on this round's outcome. Does it continue with `next_turn`? Does it need recovery? Or can it end with `completed`?

**This is what "the loop is a state machine" means** — not a simple `while (has_tool_use)`, but `while (transition ≠ terminal)`.

## What one iteration does

One iteration = one API call + one tool batch. Specifically:

1. **Build the request** — assemble the messages array, load tools, the system prompt
2. **Call the LLM** — streaming, consuming events one at a time (see chapter 06)
3. **Determine the stop reason** — find `tool_use` in the content / check `stop_reason` (see [04](04-stop-reason.md))
4. **Execute tools** — permission approval → hooks → parallel scheduling (see [01](01-tool-permission.md) / [02](02-hooks.md) / [03](03-parallel-scheduling.md))
5. **Decide the next transition** — update `state.transition.reason` based on this round's outcome

**Every iteration is a complete run through these five steps.** The complexity isn't in a single iteration — it's in the **continuity of state across iterations**.

## Loop termination — Terminal states

Corresponding to transitions is a set of **Terminal** states — states indicating the loop should end:

- **`completed`** — everything went fine, the LLM finished speaking (no `tool_use` in the content), clean exit
- **`max_turns`** — hit the `maxTurns` safety cap, force exit
- **`aborted_tools`** — the user hit Ctrl-C during tool execution
- **`aborted_streaming`** — the user hit Ctrl-C during LLM streaming
- **`hook_stopped`** — a Post-tool hook blocked, force exit
- **`stop_hook_prevented`** — a Stop hook refused to let the loop exit, but retries ran out
- **`blocking_limit`** — some blocking limit was reached
- **`image_error`** / **`model_error`** — an unrecoverable upstream error
- **`prompt_too_long`** — even compaction couldn't save it, ultimately thrown to the user

**There are 10+ Terminal types as well** — each representing "the loop ended for this specific reason." Once an SDK consumer gets a Terminal, it gives the user a different UX depending on the type.

## After an error, control returns to the main loop — not nested `try/catch` retries

This follows the same design philosophy as [how tool errors are handled](03-parallel-scheduling.md#what-happens-when-a-tool-crashes): **convert the error into a state or piece of data that can keep being processed, rather than letting an exception directly interrupt the loop.** A tool error becomes a `tool_result` handed to the LLM; when the main loop needs to recover, the error becomes a `transition`, handed off to the next round.

In a naive design, recovery would typically look like this:

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

When Claude Code hits a situation requiring recovery, it doesn't retry immediately within the same round using `try-except`. Instead, it first records what should happen next, then proceeds to the next round of the main loop, where the corresponding recovery action is carried out.

```
This round ends (with some kind of failure)
    ↓
Generate a new state.transition.reason = 'reactive_compact_retry'
    ↓
The loop moves to the next iteration · starting from the top of the while
    ↓
Check the transition first · it is reactive_compact_retry · take the compact branch
    ↓
After compacting · continue to this iteration's LLM-call step
    ↓
Get the result · generate the next transition ...
```

**This is the core design insight** — recovery is a **first-class state transition** of the loop, not an exception being caught.

**Why design it this way?** Two benefits:

**Benefit 1 · Recovery can chain**:

After one iteration completes, it enters `reactive_compact_retry` — after compacting, it calls the LLM again — and **the result is `max_tokens` again** — at which point the transition becomes `max_output_tokens_escalate`. Then **this time** it hits the ceiling again, and the transition becomes `max_output_tokens_recovery`, injecting a continue message. Everything happens within the same `while` loop, dispatched by transition each time it enters an iteration.

**If this used nested try-except** — every layer of recovery would need a nested try, or complex reentry checks — it would inevitably become a mess.

**Benefit 2 · Testability**:

The source comments explicitly state that `state.transition` is **for test assertions**. After a piece of code runs, you can assert `state.transition.reason === 'reactive_compact_retry'` to know whether it took that branch. Much more stable than grepping for error messages.

## Withholding errors from being reported outward — the loop's core philosophy

`withhold` means to **temporarily hold back, not pass outward**. Here, it refers to the loop, upon encountering an error, not first notifying the SDK caller but instead attempting internal recovery; only if recovery fails does it report the final error outward.

This design has an even deeper goal — **hiding intermediate errors from SDK callers**.

There's a blunt comment in Claude Code: some SDK callers (like cowork, the desktop product) treat seeing an `error` field in an API response as meaning "it's terminated," "the loop is dead" — and immediately show the user an error.

**But Claude Code wants to hide errors during recovery** — meaning, upon receiving `prompt_too_long`, it does **not** propagate it upward. It first attempts to compact, and if that succeeds and the next LLM call also goes smoothly, then as far as the SDK layer is concerned, this error **never happened**. Only when recovery also fails does it throw the terminal error.

**This is what makes the loop a "recovery engine," not an "error handler"** — an error is a signal **internal** to the loop, not an **output** of the loop.

## A counterintuitive fact: the main agent and subagents reuse the **exact same** `queryLoop` code

The intuition when building a subagent system is that subagents should have their own loop logic, their own state machine.

**Claude Code does the opposite**: both the main agent and subagents call the same `queryLoop` implementation, each running independently, distinguished only by `toolUseContext.agentId`. "Same" here means **reusing the same code**, not sharing the same running loop instance.

The cost: roughly a dozen `if (!toolUseContext.agentId)` checks scattered throughout the loop, used to distinguish "things that should only happen on the main thread" — MemoryPrefetch, mobile UI summaries, MCP cleanup, the Stop hook's lock, and so on.

The benefit: fixing one bug benefits the main thread and all subagents simultaneously.

**Shared loop, branching by flag** — a classic tradeoff between **shared code vs. forked code**. A subagent's independent context / worktree isolation / sandboxed execution are all handled by `AgentTool.tsx` outside the loop; the loop itself **doesn't know** whether it's a subagent or not — it just runs the same iteration.

See chapter 09 · Sidechain · the subagent loop, for details.

## The full picture of the main loop

Putting the mechanisms from the previous four chapters together with the state machine above, the full picture of one main-loop iteration looks like this:

```
─── Start of one iteration ──────────────────
Dispatch based on state.transition.reason:

  next_turn                    → Do nothing · enter the main flow directly
  reactive_compact_retry       → Run compact first
  collapse_drain_retry         → Run context collapse
  max_output_tokens_escalate   → Raise the max_tokens limit
  max_output_tokens_recovery   → Inject a "[continue]" message
  stop_hook_blocking           → No-op · enter the main flow (because exit was rejected)
  token_budget_continuation    → Continue output mode

─── Main flow ───────────────────────────────
Call the LLM · consume the stream (chapter 06)
      ↓
Append messages one by one to the messages array (Context series 02)
      ↓
Check · does content contain tool_use?
      ├─ No → Check whether stop_reason is special (chapter 04)
      │       ├─ Yes → Generate a recovery transition · handle it next iteration
      │       └─ No → Check whether the Stop hook blocks exit
      │               ├─ Blocked → transition = stop_hook_blocking · continue
      │               └─ Allowed → return { reason: 'completed' } · exit the loop
      └─ Yes → Execute tools:
              Permission approval (chapter 01)
                    ↓
              PreToolUse hook (chapter 02)
                    ↓
              Parallel scheduling · batch by isConcurrencySafe (chapter 03)
                    ↓
              Append tool_result · preserve the pairing invariant (Context series 02)
                    ↓
              PostToolUse hook (chapter 02)
              (If any step fails · convert it to an is_error tool_result · do not throw)

─── End of iteration ────────────────────────
Update state.transition.reason based on this round's result
      ↓
Return to the top of the while · next iteration
```

**This is what the previous four chapters look like once unified.** Every layer of mechanism is one link in the iteration — all the concrete mechanisms from the earlier chapters are embedded within this skeleton.

## Summary

- **`QueryEngine.ts` is not the main loop** — it's the SDK adapter layer. The main loop is `queryLoop` in `src/query.ts`
- **The main loop is a state machine, not a simple while** — 7 kinds of `state.transition.reason`, 10+ kinds of Terminal
- **Recovery is a parallel transition, not a nested try** — recovery can chain, and it's testable
- **Withholding errors from being reported outward** — the loop hides intermediate errors it can recover from itself from the SDK caller, and only throws ones that are truly unrecoverable
- **The loop is a recovery engine, not an error handler**
- **The main agent and subagents reuse the same `queryLoop` code** — each runs independently, branching via the `agentId` flag

The next chapter, 06 · Streaming · SSE event streams · Ink consumption, covers the **details** of the "call the LLM" step within the main loop — how the Anthropic API streams results back in SSE chunks, how the 6 event types are merged into complete messages, and how the UI layer renders incrementally.

---

## References

**Primary file locations** (v2.1.220):
- `src/query.ts` · the `queryLoop` main loop · a 1700+ line while-based state machine
- The `state.transition.reason` union definition in `src/query.ts`
- `src/QueryEngine.ts` · the SDK adapter layer · `submitMessage()`
- `src/services/tools/toolOrchestration.ts` · tool execution within an iteration

**Related chapters**:
- [00 · Introduction · From the chat window to the loop](00-intro.md) · the 5-line pseudocode skeleton
- [01 · From tool declaration to pre-execution approval](01-tool-permission.md) · permissions within an iteration
- [02 · Hooks · Programmable intervention points on the loop](02-hooks.md) · hooks within an iteration
- [03 · From reading files to parallel scheduling](03-parallel-scheduling.md) · tool execution within an iteration
- [04 · From "the answer is done" to the 7 meanings of stop_reason](04-stop-reason.md) · stop determination within an iteration
- 06 · Streaming · SSE event streams · Ink consumption · next chapter · details of "calling the LLM" within an iteration
- [07 · Retry and error recovery](07-retry-recovery.md) · directly corresponds to this chapter's recovery transitions
- 09 · Sidechain · the subagent loop · shared loop / branching by `agentId`

**Official Anthropic docs**:
- [Messages API — streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · the streaming protocol
