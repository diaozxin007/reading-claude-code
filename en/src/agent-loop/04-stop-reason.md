The previous three articles nailed down "whether to execute a tool" and "how to execute it" inside the loop: permission approval, hooks, parallel scheduling. Those are the mechanics of **every single turn of the wheel**.

This article covers **the other end**: when does the loop **stop**?

Following the 5-line skeleton from article 00:

```python
while True:
    response = call_llm(messages)
    if response.has_tool_use:
        execute_tools + append
    else:
        break         ← here
```

**"Break when there's no tool_use"** — but it's not that simple. Every LLM call returns with a `stop_reason` field, indicating why it stopped this time: "I'm done talking"? "I need to call a tool"? "Output got truncated"? "I refuse to answer"? "Context is full"?

Every kind of stop_reason needs the loop to handle it differently. To see clearly how a turn ends, we need to answer these questions:

- How many kinds of stop_reason does the Anthropic API have in total, and what does each mean?
- Which signal does Claude Code actually rely on to decide "this turn has truly ended"?
- Which stop_reasons make the loop stop, and which make it continue?
- If the loop simply refuses to stop (an infinite loop), what happens?

## The Full stop_reason Roster

A single Anthropic API response carries one of the following `stop_reason` values:

| stop_reason | Meaning |
|---|---|
| **`end_turn`** | The model believes it's done talking — the user's turn now |
| **`tool_use`** | The model output a tool_use block — it wants to call a tool |
| **`max_tokens`** | Output token ceiling hit — forcibly truncated server-side |
| **`stop_sequence`** | A custom stop sequence was matched |
| **`refusal`** | Safety policy triggered — the model refuses to answer |
| **`pause_turn`** | The model requests to pause this turn and continue later |
| **`model_context_window_exceeded`** | Context exceeded its ceiling — input too long |

**7 kinds** — but Claude Code's handling of them is **very uneven**.

## Counterintuitive Fact #1: Turn Completion Doesn't Look at stop_reason

The intuitive way to write the loop would be:

```
if stop_reason == "end_turn":
    break
elif stop_reason == "tool_use":
    execute_tools
```

**That's not how Claude Code writes it.**

The way Claude Code decides "this turn has ended" is: **whether the assistant message contains a `tool_use` block**.

```
if response.content contains a tool_use block:
    execute_tools
else:
    break
```

**Why not look at stop_reason** — because `stop_reason === 'tool_use'` is **unreliable** in practice. The source code has a comment saying exactly this. Sometimes the model clearly outputs a tool_use, yet stop_reason comes back as `end_turn`; sometimes stop_reason is `tool_use` but there's no actual tool_use block in the content.

**The only reliable criterion is the content itself** — scan the content array; if there's a tool_use, continue; if not, exit.

**stop_reason's main use is error UX** — telling the user "the output got cut off, ask the model to continue" or "the model refused to answer, try rephrasing." **It is not used as the loop's dispatch criterion.**

## How Each stop_reason Is Actually Handled

**`end_turn`** — normal completion. The loop checks content; no tool_use; takes the `completed` branch and ends.

**`tool_use`** — this reason is **ignored outright**. Only whether the content has a tool_use block matters. If it does, execute_tools, append tool_result, and move to the next turn.

**`max_tokens`** — output hit the ceiling and got truncated. This is an error state; the loop triggers the `max_output_tokens` recovery flow:
- First try **raising the max_tokens ceiling** (escalate), then retry
- If it still hits the ceiling after raising it, inject a `[Output token limit hit, continue]` user message so the LLM knows explicitly to keep going
- Retry at most 3 times (`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`); if it still fails, surface it to the user
- **From the loop's point of view, this is "not yet finished" — it keeps running**

**`model_context_window_exceeded`** — context exceeded the ceiling. The loop triggers the [reactive-compact](../context-management/04-compaction.md) flow — try to compress history, then retry. This is also a **keep running** branch.

**`refusal`** — the model triggered a safety policy. The loop generates an error message suggesting the user try `/model` to switch models. But **it does not retry** — refusal is the model's active decision to decline, and automatic retry wouldn't help. The loop **ends**.

**`stop_sequence`** — a custom stop sequence matched. Claude Code almost **never** uses this field, because it doesn't set stop_sequences. It falls through to "check content for tool_use" — usually there is none, and it breaks out.

**`pause_turn`** — **entirely unhandled**. There's **no branch anywhere in the source** that handles `pause_turn`. The SDK layer recognizes it, but the Claude Code loop layer has no related code at all. The likely reason: pause_turn is meant "for very long-running, complex turns," and Claude Code's main loop typically makes 3-10 calls per turn — pause_turn just never comes up. This is **a genuine gap in the source** — if long-thinking models get wired in someday, handling for this will need to be added.

## The Counterintuitive Philosophy of Error Handling

The `max_tokens` / `context_window_exceeded` handling paths above reveal one of Claude Code's core philosophies:

**An error is not a termination — it's a trigger for recovery.**

- `max_tokens` → not "sorry, the output was too long, please retry" — it's automatically raising the ceiling + injecting continue + retrying
- `context_window_exceeded` → not "sorry, context is full" — it's automatically compacting + retrying
- `overloaded` / rate limit → automatically falling back to another model + retrying
- Network errors → `withRetry` exponential backoff + retrying

**The loop's design goal is: "any error that can recover itself, recovers itself — only the truly unrecoverable ones get surfaced to the user."** This is consistent with what Anthropic's official blog says: Claude Code is a **recovery engine**, not an **error handler**.

At the loop state machine level, these recoveries correspond to different transitions — covered in the loop 07 article.

## MaxTurns — the Hard Safety Net

With all this recovery keeping the loop running — could the loop **run forever**?

In theory, yes. For instance:
- The LLM gets stuck in a cycle — every turn calls a tool, and every turn's tool result never satisfies it
- max_tokens recovery keeps triggering repeatedly — every time it raises the ceiling, it hits the ceiling again
- context_window triggers compact, and right after compacting it exceeds the limit again — an infinite doll-within-a-doll

**Claude Code has one hard safety net: `maxTurns`.**

Within a single loop (from the user pressing enter to the loop ending), once the cumulative number of LLM calls exceeds `maxTurns`, it forcibly exits. The SDK layer lets the user configure a default when starting Claude Code; the interactive REPL has a fairly high default value.

After hitting maxTurns:
- A system message `[max_turns_reached]` gets appended to messages
- The SDK layer returns `{ subtype: 'error_max_turns' }`
- The user sees a clear notice, making it obvious the loop was forcibly stopped

**maxTurns is one layer of insurance built on the premise of "no one participating mid-loop"** — keeping the loop from running forever even when unsupervised. [Article 08](08-interrupt.md) will sum up this layer together with the other safety nets.

## The Stop Hook's Final Block

Following the logic above, once the loop reaches "content has no tool_use → completed," it should exit. But there's one more gate — the **Stop hook**.

Loop article 02 covered this: hooks have a `Stop` event, hung right at the moment the loop is about to end. If the Stop hook returns `decision: block`, **the loop is not allowed to actually end** — it must run one more turn.

This capability is used for things like:
- "Don't allow ending before tests have run" (the hook checks whether tests ran)
- "There are uncommitted changes — force the LLM to finish handling them"

**A loop turn only truly ends after clearing three gates**:
1. No tool_use in the content (content criterion)
2. stop_reason isn't a type that needs recovery
3. The Stop hook doesn't block

Only once all three gates are cleared does the loop hit `completed`, the result gets shown to the user, and the user takes back over.

## The Complete Turn-Ending Logic

Putting all the branches above together, here's what it looks like as loop-state-machine pseudocode:

```
After each LLM call, check:

if content contains a tool_use block:
    → execute_tools, append tool_result, move to next turn
elif stop_reason == "max_tokens":
    → max_output_tokens recovery (escalate → inject continue → retry)
    → at most 3 times, then give up and surface to the user
elif stop_reason == "model_context_window_exceeded":
    → reactive-compact, compress and retry
elif stop_reason == "refusal":
    → generate an error message, loop ends
elif turnCount > maxTurns:
    → maxTurns safety net, forced end
elif Stop hook returns block:
    → ignore the ending, forcibly run one more turn
else:
    → completed, the loop truly ends
```

**7 kinds of stop_reason, 5 branches of handling** — stop_sequence and pause_turn don't actually enter this flow. The loop's decision depends on a combination of four signals: content + special stop_reason + turnCount + hook.

## Summary

- **The criterion for a turn ending is "whether content has a tool_use"** — stop_reason is unreliable, and is only used for error UX
- **7 kinds of stop_reason**: `end_turn` / `tool_use` / `max_tokens` / `stop_sequence` / `refusal` / `pause_turn` / `model_context_window_exceeded`
- **max_tokens and context_window_exceeded trigger recovery** — not termination, but automatic recovery followed by retry
- **refusal ends things directly** — no retry (retrying would be pointless)
- **pause_turn is entirely unhandled** — a gap in the source that will need filling once long-thinking models are wired in
- **maxTurns is the hard safety net** — forced exit once the cumulative call count within one loop exceeds the ceiling
- **The Stop hook is the final block** — hung right before ending, it can force one more turn
- **A turn only truly ends after clearing three gates**: the content criterion, the stop_reason criterion, and the Stop hook criterion

Next up, [05 · QueryEngine Main Loop · A State Machine Overview](05-query-engine.md) unifies everything from the first four articles — permissions / hooks / parallel scheduling / stop_reason handling / recovery — all as parts of the main loop's state machine. The main loop relies on `state.transition.reason`, a 7-value union, to decide which path to take on every tick.

---

## References

**Primary file locations** (v2.1.220):
- `src/services/api/claude.ts` — stop_reason handling in the `message_delta` branch
- `src/services/api/errors.ts` — `getErrorMessageIfRefusal` detects refusal
- `src/query.ts` — `queryLoop` main loop — turn determination, maxTurns, recovery branches
- `src/query/stopHooks.ts` — `Stop` hook blocking logic
- `src/QueryEngine.ts` — the SDK layer's `error_max_turns` result type

**Related articles**:
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) — the single-step interception safety net
- [02 · Hooks · Programmable Intervention Points on the Loop](02-hooks.md) — the Stop hook
- [03 · From Reading a File to Parallel Scheduling](03-parallel-scheduling.md) — the concrete detection behind the tool_use content criterion
- [05 · QueryEngine Main Loop · A State Machine Overview](05-query-engine.md) — next article — unifying the recovery branches
- [04 · The Six Siblings of Compaction](../context-management/04-compaction.md) — reactive-compact in detail

**Anthropic official**:
- [Messages API — stop_reason](https://platform.claude.com/docs/en/api/messages#response-body-stop-reason) — semantics of stop_reason values
