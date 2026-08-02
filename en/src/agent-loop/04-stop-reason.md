The first three chapters explained whether tools should be executed inside the loop and how to execute them: permission approval, hooks, and parallel scheduling. Those are the mechanisms that govern **each iteration** of the loop.

This chapter covers **the other end**: when does the loop **stop**?

Using the five-line skeleton from Chapter 00:

```python
while True:
    response = call_llm(messages)
    if response.has_tool_use:
        execute_tools + append
    else:
        break         ← here
```

**“Break when there is no `tool_use`”**—but it is not quite that simple. Each LLM response includes a `stop_reason` field indicating why that invocation stopped: “I’m done speaking”? “I want to call a tool”? “My output was truncated”? “I refuse to answer”? “The context is full”?

Each `stop_reason` requires different handling by the loop. To understand how a turn ends, we need to answer several questions:

- How many `stop_reason` values does the Anthropic API define, and what does each one mean?
- Which signal does Claude Code use to determine that a turn has truly ended?
- Which `stop_reason` values stop the loop, and which keep it running?
- What happens if the loop simply refuses to stop—an infinite loop?

## Complete `stop_reason` List

Each Anthropic API response contains one of the following `stop_reason` values:

| stop_reason | Meaning |
|---|---|
| **`end_turn`** | The model considers its response complete; it is the user’s turn |
| **`tool_use`** | The model emitted a `tool_use` block and wants to call a tool |
| **`max_tokens`** | The output token limit was reached, and the server forcibly truncated the response |
| **`stop_sequence`** | A custom stop sequence was matched |
| **`refusal`** | A safety policy was triggered, and the model refused to answer |
| **`pause_turn`** | The model requested that the turn be paused and resumed later |
| **`model_context_window_exceeded`** | The context limit was exceeded because the input was too long |

There are **seven values**, but Claude Code handles them in **very different ways**.

## The First Counterintuitive Detail: Turn Completion Does Not Depend on `stop_reason`

The intuitive way to write the loop would be:

```
if stop_reason == "end_turn":
    break
elif stop_reason == "tool_use":
    execute_tools
```

**That is not how Claude Code implements it.**

Claude Code determines whether a turn has ended by checking **whether the assistant message contains a `tool_use` block**:

```
if response.content contains a tool_use block:
    execute_tools
else:
    break
```

**Why not inspect `stop_reason`?** Because in practice, `stop_reason === 'tool_use'` is **unreliable**. A source-code comment says so explicitly. Sometimes the model emits a `tool_use` block while `stop_reason` is `end_turn`; at other times, `stop_reason` is `tool_use`, but the content contains no actual `tool_use` block.

**The content itself is the only reliable criterion**: scan the content array, continue if it contains `tool_use`, and exit if it does not.

**The primary purpose of `stop_reason` is error UX**: telling the user that the output was truncated and they should ask the model to continue, or that the model refused to answer and they should rephrase the request. **It is not the basis for dispatching the loop.**

## How Each `stop_reason` Is Handled

**`end_turn`**—Normal completion. The loop checks the content, finds no `tool_use`, enters the `completed` branch, and exits.

**`tool_use`**—The reason itself is **ignored**. Claude Code checks only whether the content contains a `tool_use` block. If it does, it runs `execute_tools`, appends the `tool_result`, and starts the next iteration.

**`max_tokens`**—The output hit its limit and was truncated. This is an error state, so the loop starts the `max_output_tokens` recovery flow:

- First, it attempts to **increase the `max_tokens` limit**—an escalation—and tries again.
- If the output still reaches the limit after escalation, it injects a `[Output token limit hit, continue]` user message so the LLM knows explicitly that it should continue.
- It retries at most three times (`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`); if recovery still fails, it surfaces the error to the user.
- **From the loop’s perspective, the turn is not over, so it keeps running.**

**`model_context_window_exceeded`**—The context exceeded its limit. The loop starts the [reactive-compact](https://diaozxin007.github.io/reading-claude-code/zh/context-management/04-compaction.html) flow, attempts to compress the history, and retries. This is also a **keep-running** branch.

**`refusal`**—The model triggered a safety policy. The loop generates an error message suggesting that the user try another model with `/model`. It **does not retry**: a refusal is an intentional decision by the model, so automatic retries would serve no purpose. The loop **ends**.

**`stop_sequence`**—A custom stop sequence was matched. Claude Code **barely uses** this field because it does not set `stop_sequences`. Processing falls through to the check for a `tool_use` block in the content. Usually there is none, so the loop breaks.

**`pause_turn`**—It is **not handled at all**. There is **no branch anywhere in the source code that handles `pause_turn`**. The SDK layer recognizes it, but the Claude Code loop has no corresponding logic. The likely reason is that `pause_turn` is intended for complex turns that take a long time to run, whereas Claude Code’s main loop typically makes only 3–10 calls per turn, so it has no need for `pause_turn`. This is **a genuine gap in the source code**: support will need to be added if long-reasoning models are integrated in the future.

## The Counterintuitive Philosophy of Error Handling

The `max_tokens` and `context_window_exceeded` paths above reveal a core philosophy in Claude Code:

**An error is not a termination condition; it is a signal to begin recovery.**

- `max_tokens` → Instead of “Sorry, the output was too long; please try again,” automatically raise the limit, inject `continue`, and retry.
- `context_window_exceeded` → Instead of “Sorry, the context is full,” automatically compact the context and retry.
- `overloaded` / rate limit → Automatically fall back to another model and retry.
- Network error → Retry with exponential backoff through `withRetry`.

**The loop is designed to recover automatically from every recoverable error and surface only truly unrecoverable failures to the user.** This aligns with the statement in Anthropic’s official blog that “Claude Code is a **recovery engine**, not an **error handler**.”

At the loop state-machine level, these recovery paths correspond to different transitions. Chapter 07 on the loop will cover them.

## `maxTurns`: The Hard Safety Limit

All these recovery mechanisms can keep the loop running—but could the loop run **forever**?

In theory, yes. For example:

- The LLM enters a cycle, requesting a tool call on every iteration without ever being satisfied by the tool results.
- `max_tokens` recovery triggers repeatedly, with the output reaching the limit again after every escalation.
- The context window triggers compaction, then immediately exceeds the limit again after compaction, creating infinite recursion.

**Claude Code has a hard safety limit: `maxTurns`.**

Within a single loop—from the moment the user presses Enter until the loop ends—if the cumulative number of LLM calls exceeds `maxTurns`, Claude Code forcibly exits. At the SDK layer, users can configure the default when starting Claude Code; the interactive REPL uses a relatively high default.

After `maxTurns` is reached:

- A `[max_turns_reached]` system message is appended to `messages`.
- The SDK layer returns `{ subtype: 'error_max_turns' }`.
- The user sees an explicit message explaining that the loop was forcibly stopped.

**`maxTurns` is one safeguard for the assumption that no one participates while the loop is running**: it prevents the loop from running forever even when unsupervised. [Chapter 08](08-interrupt.md) summarizes this safeguard alongside the others.

## The Stop Hook’s Final Veto

Following the logic above, once the loop reaches “content contains no `tool_use` → `completed`,” it should exit. But there is one final gate: the **Stop hook**.

Chapter 02 on the loop introduced the `Stop` event, which fires when the loop intends to finish. If the Stop hook returns `decision: block`, **the loop cannot actually end**—it must run another iteration.

This capability can enforce rules such as:

- “Do not finish before running the tests” by having the hook check whether tests have been run.
- “There are still uncommitted changes; force the LLM to finish handling them.”

**A loop must pass three gates before it can truly end**:

1. The content contains no `tool_use` block—the content criterion.
2. The `stop_reason` is not a type that requires recovery.
3. The Stop hook does not block completion.

Only after passing all three gates does the loop become `completed`, display the result to the user, and return control to them.

## Complete Turn-Completion Logic

All the branches above reduce to the following pseudocode in the loop state machine:

```
After one LLM call, check:

if content contains a tool_use block:
    → execute_tools · append tool_result · begin the next iteration
elif stop_reason == "max_tokens":
    → max_output_tokens recovery (escalate → inject continue → retry)
    → try at most 3 times · then give up · surface the error to the user
elif stop_reason == "model_context_window_exceeded":
    → reactive-compact · compress and retry
elif stop_reason == "refusal":
    → generate an error message · end the loop
elif turnCount > maxTurns:
    → max_turns safety limit · force the loop to end
elif Stop hook returns block:
    → ignore completion · force another iteration
else:
    → completed · the loop truly ends
```

**Seven `stop_reason` values, five handling branches**—`stop_sequence` and `pause_turn` do not actually enter this flow. The loop’s decision combines four signals: content, special `stop_reason` values, `turnCount`, and hooks.

## Conclusion

- **The criterion for ending a turn is whether the content contains `tool_use`**—`stop_reason` is unreliable and is used only for error UX.
- **There are seven `stop_reason` values**: `end_turn` / `tool_use` / `max_tokens` / `stop_sequence` / `refusal` / `pause_turn` / `model_context_window_exceeded`.
- **`max_tokens` and `model_context_window_exceeded` trigger recovery**—they do not terminate the loop; Claude Code recovers automatically and retries.
- **`refusal` ends the loop immediately**—there is no retry because retrying would be pointless.
- **`pause_turn` is not handled at all**—this is a gap in the source code that must be addressed before integrating long-reasoning models.
- **`maxTurns` is a hard safety limit**—if the cumulative number of calls within one loop exceeds the limit, the loop is forcibly terminated.
- **The Stop hook provides the final veto**—it runs immediately before completion and can force another iteration.
- **A loop must pass three gates before it truly ends**: the content criterion, the `stop_reason` criterion, and the Stop hook criterion.

The next chapter, [05 · The QueryEngine Main Loop: A Complete View of the State Machine](05-query-engine.md), unifies all the mechanisms from the previous four chapters—permissions, hooks, parallel scheduling, `stop_reason` handling, and recovery—as parts of the main-loop state machine. On every tick, the main loop uses the seven-value `state.transition.reason` union to decide which path to take.

---

## References

**Primary file locations** (v2.1.220):

- `src/services/api/claude.ts` · `stop_reason` handling in the `message_delta` branch
- `src/services/api/errors.ts` · `getErrorMessageIfRefusal` refusal detection
- `src/query.ts` · the `queryLoop` main loop, turn checks, `maxTurns`, and recovery branches
- `src/query/stopHooks.ts` · `Stop` hook blocking logic
- `src/QueryEngine.ts` · the SDK-layer `error_max_turns` result type

**Related chapters**:

- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) · per-step interception safeguard
- [02 · Hooks: Programmable Intervention Points in the Loop](02-hooks.md) · Stop hook
- [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md) · the concrete check for the `tool_use` content criterion
- [05 · The QueryEngine Main Loop: A Complete View of the State Machine](05-query-engine.md) · next chapter · unifying the recovery branches
- [04 · The Six Compaction Mechanisms](https://diaozxin007.github.io/reading-claude-code/zh/context-management/04-compaction.html) · a detailed explanation of reactive compacting

**Official Anthropic documentation**:

- [Messages API — stop_reason](https://platform.claude.com/docs/en/api/messages#response-body-stop-reason) · semantics of the `stop_reason` values
