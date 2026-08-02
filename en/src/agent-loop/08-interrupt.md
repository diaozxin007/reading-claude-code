The previous chapter covered the loop's self-healing mechanisms for infrastructure errors—eight layers of recovery stacked together. But there is one situation the loop can never handle on its own: **the user changes their mind**.

The user may see the loop spending ages reading an irrelevant file, feel that the LLM has gone off track, or simply want to interject with additional information—the loop must be **interruptible**.

From the product perspective, it is simple: press Ctrl-C. But from the loop's perspective, things are more complicated—the loop may be in any of three states:

- The LLM is streaming a response · midway through SSE
- Tools are executing in parallel · several are still pending
- Permission approval · a Promise is being awaited

**Forcibly interrupting any of these states can break the structure of the messages array**. For example, if a tool is interrupted midway through execution, its tool_use is already in messages, but no tool_result has been generated—the **pairing invariant is broken** (see [Context 02](https://readingclaude.club/zh/context-management/02-message-invariants)). The next LLM call immediately returns a 400.

This chapter explains how to interrupt the loop **without corrupting the messages array**. The core questions are:

- How do Ctrl-C and Esc travel from the keyboard through the UI layer to the loop?
- How does the loop clean up in-flight state after receiving an interrupt signal?
- How are missing tool_results filled in?
- Are interrupting and "continuing with new input after an interruption" the same thing?

## One AbortController Across the Entire Loop

Every time Claude Code starts a loop, it **creates a new `AbortController`**—a built-in Node.js abstraction that provides two things:

- **`signal`**—passed to downstream functions so they can determine whether an interruption has occurred
- **`abort()`**—triggers the interruption, putting every signal into the aborted state

Claude Code stores this single controller on `QueryEngine`, where it is shared across the entire loop:

```
QueryEngine
    ├── this.abortController = new AbortController()
    ├── interrupt() → this.abortController.abort()
    └── inside the loop · toolUseContext.abortController.signal is passed downstream
```

When the user presses Ctrl-C, the UI layer calls `QueryEngine.interrupt()`, which triggers `abort()`. In that instant, **every part of the loop holding the signal enters the aborted state**.

**The key design choice: one controller, not several**. Why? Because the loop contains many **parallel** operations:

- Streaming API requests
- Multiple tools executing in parallel
- Permission approval Promises
- Hook subprocesses

With one controller, a single abort sends the signal to **all parallel operations** simultaneously. With multiple controllers, each would have to be aborted individually, making omissions easy.

## Three Checkpoints

The loop **checks `signal.aborted`** at three critical points:

**Checkpoint 1 · HTTP request layer**

When calling the LLM, it passes the `signal` to the underlying fetch:

```
fetch(url, { signal: toolUseContext.abortController.signal })
```

`fetch` is signal-aware—when the signal is aborted, fetch rejects immediately. The streaming API request is **physically interrupted** at once, and no subsequent SSE events arrive.

**Checkpoint 2 · Between the end of streaming and tool execution**

Once an API call completes and the full assistant message has been received—possibly containing tool_use blocks—the loop checks `signal.aborted` **before it begins executing tools**.

If the signal has already been aborted, it does not start any tools and proceeds directly to cleanup.

**Checkpoint 3 · Between tool batches**

When multiple tools execute in parallel, the next batch begins after the current batch completes. The loop checks the signal during this gap. If it has been aborted, the next batch does not start.

**Why these three points?** Because signals are **cooperative**. I/O operations such as fetch can respond immediately, but **non-I/O operations** must **actively check** the signal to be interrupted. A computation-only for loop will run to completion even if the signal has been aborted. The checkpoints are placed wherever **new work is about to begin**—after current work finishes, the loop checks again before starting the next task.

## Synthesizing Missing tool_results

After an interruption, the messages array may look like this:

```
[
  msg 1: user message
  msg 2: assistant message · contains 3 tool_use blocks (A, B, C)
  msg 3: user message · tool_result A has already been appended · B has completed
    ← but C was still executing · it was aborted · no tool_result was generated
]
```

**This array is already corrupted**—tool_use C exists, but there is no corresponding tool_result. If the user's next message is appended, the previous array still contains the orphaned tool_use C, and the LLM call returns a 400.

**Claude Code's solution**: after abort is triggered, the loop scans the in-flight tool_use blocks and **synthesizes fake tool_results**:

```
{
  type: 'tool_result',
  tool_use_id: 'toolu_C',
  content: 'Interrupted by user',
  is_error: true
}
```

**This synthesized fake tool_result** makes the messages array structurally complete, preventing a 400 on the next LLM call. Semantically, the LLM can also understand that the tool was interrupted.

In the source code, this synthesis logic is called `yieldMissingToolResultBlocks`. It was initially used only for interruptions; later, the `ensureToolResultPairing` repair mechanism covered in [Loop 03](03-parallel-scheduling.md) adopted the same principle—**pairing is a hard constraint, and any violation must be repaired**.

## Two Interrupt Semantics

In actual use, pressing Ctrl-C can express two different intentions:

**Intent A · Simply interrupt—"I don't want the loop to continue; let me think for a moment"**

The user wants to stop the loop and review its progress. They may enter another message afterward, or they may not.

**Intent B · Interrupt to submit a new message—"I want to add some information midway through"**

The user wants to stop the loop and **immediately** give the LLM a new message—for example, "No, you've gone off track; you should look at auth_v2.py." The LLM should then continue with that new message in context.

**Both intentions trigger abort in the same way, but their expected follow-up behavior differs**:

- Intent A: synthesize "Interrupted by user" and append it to messages, then end the loop and wait for the user's next input
- Intent B: the user has already **typed the new message into the UI**; when the loop ends, immediately use that message as the input to the next loop

**Claude Code distinguishes them** through `signal.reason`.

- Ordinary abort: `signal.reason === 'ctrl-c'` (or similar) · follows intent A · synthesizes "Interrupted by user"
- Submission abort: `signal.reason === 'interrupt'` (meaning that a new message is to be submitted) · follows intent B · **does not synthesize** an "Interrupted by user" message

**Why intent B does not synthesize one**: because the new message the user is about to submit is itself the contextual update. Synthesizing another "Interrupted by user" would be redundant. Let the user's new message **explain for itself** why the loop was interrupted.

**One signal, two semantics**, dispatched through `signal.reason`—**a particularly elegant design**. From a user-experience perspective, intent B is more common—the user wants to interject—while intent A occurs occasionally, when the user genuinely only wants to stop. Making intent B more natural avoids appending a redundant message.

## Interrupting During Streaming

The discussion above covers interruptions during tool execution. What about **interruptions during streaming**?

If the user presses Ctrl-C during streaming, `AbortController.abort()` is triggered. Fetch immediately rejects the underlying connection. But what happens to **SSE events that have already arrived**?

Claude Code's approach: **everything received is treated as received**. Suppose three delta events have arrived, and the client has already accumulated the three text fragments into the assistant message. After abort, this incomplete assistant message is **still appended to the messages array**. Its content consists of those three text fragments, with no tool_use or stop_reason.

The effect on the loop state machine is:

- The terminal type is `aborted_streaming`, indicating an interruption during streaming
- When the conversation continues, the incomplete message remains in the history, so the LLM can see that it stopped midway through a sentence

**The tradeoff in this design**:

- **Preserve** partial output—the user can look back and see how far the loop got
- **Discard** partial output—the history is cleaner, but the user cannot see the progress

Claude Code chooses to preserve it. The reason is that when users press Ctrl-C, they usually mean, "I saw the LLM saying something wrong and wanted to stop it." Those incorrect words must remain in the history so the user can refer to them in the next turn—"What you just said about X is wrong." Discarding the partial output would remove that context.

## Chicago MCP Cleanup Runs Only for Non-subagent Interruptions

One small but subtle detail: some MCP servers—such as "chicago," an internal Anthropic service—need to **clean up connection state** when the loop ends.

Claude Code's handling: **cleanup runs only when the main-thread loop is interrupted**—a subagent interruption does not trigger it.

**Why**: a subagent is launched from within the main-thread loop and shares the same MCP server connection with it. If the subagent is interrupted, the main-thread loop may still need to use MCP, so the connection must not be cleaned up.

**This detail illustrates how Claude Code handles the boundary between subagents and the main thread**—see 09 · Sidechain · Subagent Loop. The main thread and subagents **share queryLoop**, but some main-thread-only behavior is **dispatched separately** using `if (!toolUseContext.agentId)`. MCP cleanup is one such behavior.

## Interrupt Is the Second Exception to "No Human Participation During the Loop"

[Chapter 01](01-tool-permission.md) described permission approval as the **first exception** to "no human participation during the loop"—it brings the user in at dangerous operations.

**Interrupt is the second exception**—it allows the user to step in at any time. With permission approval, **the loop actively waits for the user**; with interrupt, **the user actively stops the loop**.

Add **maxTurns** from [Chapter 04](04-stop-reason.md)—which stops the loop automatically when it reaches the limit without requiring user participation—and the three mechanisms complement one another:

- **Permission approval**: the loop pauses itself and waits for the user to make the call at a dangerous moment
- **interrupt**: the user actively stops the loop whenever they want
- **maxTurns**: a hard safeguard that prevents the loop from running indefinitely without human participation

Together, the three ensure that the premise of "the loop runs automatically" never gets out of control **under any circumstances**. All four follow-up mechanism hooks introduced in [Chapter 00](00-intro.md) have now been fully realized.

## Conclusion

- **One AbortController spans the entire loop**—one Ctrl-C from the user signals every parallel operation simultaneously
- **Three checkpoints**—the HTTP request (fetch is signal-aware), the gap between streaming and tool execution, and the gap between tool batches
- **Synthesized tool_results**—after interruption, scan in-flight tool_use blocks and add synthesized `is_error: 'Interrupted by user'` results to preserve the pairing invariant
- **Two interrupt semantics**—`signal.reason` distinguishes them: a simple interruption synthesizes "Interrupted by user," while interrupting to submit a new message does not
- **Streaming interruptions preserve partial output**—allowing the user to see how far the loop got and refer to incorrect statements
- **Chicago MCP cleanup runs only on the main thread**—a subagent interruption does not affect the shared MCP connection
- **Interrupt is the second exception to "no human participation during the loop"**—permission approval, interrupt, and maxTurns complement one another

The next chapter, 09 · Sidechain · Subagent Loop, covers Claude Code's final major mechanism: how subagents use the same queryLoop while diverging from main-thread behavior at 12 points, the separate `.claude/subagents/<agentId>.jsonl` files, and the agentId dispatch rules.

---

## References

**Primary file locations** (v2.1.220):

- `src/QueryEngine.ts` · `abortController` · `interrupt()`
- `src/query.ts` · `yieldMissingToolResultBlocks` · in-flight tool_use synthesis
- `src/query.ts` · `signal.reason === 'interrupt'` dispatch
- `src/hooks/useCancelRequest.ts` · Ctrl-C / Esc event capture
- `src/hooks/useCancelRequest.ts` · `chat:cancel` / `app:interrupt` precedence

**Related chapters**:

- [00 · Introduction · From the Chat Window to the Loop](00-intro.md) · the "no human participation during the loop" premise
- [01 · From Tool Declaration to Pre-execution Approval](01-tool-permission.md) · the first exception · permission approval
- [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md) · the other repair scenario for `ensureToolResultPairing`
- [04 · From Completing a Response to the Seven Meanings of stop_reason](04-stop-reason.md) · the maxTurns safeguard
- 09 · Sidechain · Subagent Loop · next chapter · special handling for subagent interruptions
- [02 · From a Single Message to Three Invariants of the Messages Array](https://readingclaude.club/zh/context-management/02-message-invariants) · the pairing invariant as a hard constraint
