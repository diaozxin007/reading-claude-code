The previous article covered how the loop self-heals when it hits infrastructure errors — 8 layers of recovery stacked on top of each other. But there's one situation the loop can never handle on its own: **the user changes their mind**.

The user sees the loop spend half a minute reading an irrelevant file, or feels the LLM has gone off track, or just wants to interject with a bit of extra information — in all these cases, the loop has to be **interruptible**.

From a product point of view this looks simple: press Ctrl-C. But from the loop's point of view things get complicated — the loop could be in 3 different states when this happens:

- The LLM is mid-stream, halfway through an SSE
- Tools are running in parallel, some still pending
- A permission approval is in flight, a Promise is being awaited

**Whichever state gets forcibly interrupted, the structure of the messages array can be damaged.** For example, if a tool is halfway through execution and gets interrupted, the `tool_use` is already in messages, but the `tool_result` was never generated — **the pairing invariant is broken** (see [Context 02](../context-management/02-message-invariants.md)). The next LLM call fails with a 400.

This article covers how to interrupt **without letting the messages array break**. The core questions:

- How does Ctrl-C / Esc travel from the keyboard, through the UI layer, into the loop?
- Once the loop receives the interrupt signal, how does it clean up in-flight state?
- How does it patch the missing `tool_result`?
- Is "interrupt" the same thing as "interrupt and then keep typing"?

## One AbortController Runs Through the Whole Loop

Every time a Claude Code loop starts, it **creates a new `AbortController`** — a built-in Node.js abstraction that provides two things:

- **`signal`** — can be passed down to downstream functions, so they know "has this been aborted yet"
- **`abort()`** — triggers the abort, flipping every signal into the aborted state

Claude Code keeps this one controller on the `QueryEngine`, shared across the whole loop:

```
QueryEngine
    ├── this.abortController = new AbortController()
    ├── interrupt() → this.abortController.abort()
    └── inside the loop · toolUseContext.abortController.signal passed down
```

When the user presses Ctrl-C, the UI layer calls `QueryEngine.interrupt()`, which triggers `abort()`. In an instant, **every place in the loop that holds a reference to the signal flips into the aborted state**.

**Key design: one controller, not several.** Why? Because the loop has a lot of things happening **in parallel**:

- The streaming API request
- Multiple tools running in parallel
- The permission-approval Promise
- Hook subprocesses

With one controller, a single `abort()` call notifies **all parallel actions** at once. With several controllers, you'd have to abort them one by one — and it's easy to miss one.

## Three Checkpoints

Three key spots in the loop **check `signal.aborted`**:

**Checkpoint 1 · The HTTP request layer**

When calling the LLM, the `signal` is passed down to the underlying fetch:

```
fetch(url, { signal: toolUseContext.abortController.signal })
```

`fetch` is signal-aware — once the signal is aborted, fetch immediately rejects. In an instant, an in-flight streaming API request is **physically cut off**, and no further SSE events arrive.

**Checkpoint 2 · Between the end of streaming and the start of tool execution**

Once an API call completes and the full assistant message is in hand (possibly with a `tool_use`), **right before starting to run the tool** — the loop checks `signal.aborted`.

If it's already aborted, the tool doesn't get started; the loop goes straight into cleanup.

**Checkpoint 3 · Between tool batches**

When multiple tools run in parallel and one batch finishes before the next batch starts — that gap is where the check happens. If aborted, the next batch doesn't start.

**Why these three spots** — because the signal is **cooperative**: IO operations like fetch can respond immediately, but **non-IO operations** must **actively check** the signal to be interrupted. A pure computation loop — say, a plain `for` loop — will run to completion even if the signal has already been aborted. The checkpoints are placed at every spot **about to start new work** — once something already running finishes, only then does it check whether to start the next thing.

## Synthesizing a Missing tool_result

Once an interrupt fires, the messages array might look like this:

```
[
  msg 1: user message
  msg 2: assistant message with 3 tool_use blocks (A, B, C)
  msg 3: user message with tool_result A and B already appended, both done
    ← but C is still running · got aborted · no tool_result was generated
]
```

**This array is now broken** — `tool_use` C exists, but has no matching `tool_result`. Next time a new user message gets appended, the array still carries the orphaned `tool_use` C, and the next LLM call fails with a 400.

**Claude Code's handling**: once abort fires, the loop scans for any in-flight `tool_use` and **synthesizes a fake `tool_result`**:

```
{
  type: 'tool_result',
  tool_use_id: 'toolu_C',
  content: 'Interrupted by user',
  is_error: true
}
```

**This synthetic fake `tool_result`** keeps the messages array structurally intact, so the next LLM call won't 400. Semantically, the LLM can also understand from it that "this tool was interrupted."

This synthesis logic is called `yieldMissingToolResultBlocks` in the source. It was originally written just to handle interrupts, but the `ensureToolResultPairing` patching mechanism covered in [Loop 03](03-parallel-scheduling.md) later turned out to share the same idea — **pairing is a hard constraint, and once broken, it must be patched.**

## Two Different Meanings of "Interrupt"

In actual use, when the user hits Ctrl-C, there are two different underlying intents:

**Intent A · A plain interruption — "I don't want the loop to keep going, let me think for a second"**

The user wants to stop the loop and look at the progress so far. They may or may not type a new message afterward.

**Intent B · Interrupting to submit a new message — "I want to add something mid-flight"**

The user wants to stop the loop and **immediately** give the LLM a new message (e.g. "oh no, you've gone off track, you should be looking at auth_v2.py"). The LLM should then keep going, taking this new message into account.

**These two intents trigger `abort` the same way, but they expect different follow-up behavior**:

- Intent A: synthesize "Interrupted by user" and append it to messages, then end the loop, waiting for the user's next input
- Intent B: the user has already **typed the new message into the UI**; once the loop ends, that new message is immediately used as the input for the next loop iteration

**Claude Code's handling**: distinguish the two via `signal.reason`.

- A plain abort: `signal.reason === 'ctrl-c'` (or similar) — follows intent A, synthesizes "Interrupted by user"
- A submit abort: `signal.reason === 'interrupt'` (carrying the semantics of "about to submit a new message") — follows intent B, and **does not** synthesize the "Interrupted by user" message

**Why intent B skips the synthesis**: because the new message the user is about to submit already *is* the "context addition" — synthesizing another "Interrupted by user" on top of it would be redundant. Let the user's new message **explain for itself** why this loop got interrupted.

**One signal, two meanings** — split via `signal.reason` — **this is a clever piece of design**. From a UX standpoint, intent B is the more common case (the user wants to interject); intent A happens occasionally (the user really just wants to stop). Making B feel natural — without appending a redundant message — matters more.

## Interrupting Mid-Stream

The above covers interrupts during tool execution. What about **an interrupt during streaming**?

During the streaming phase, when the user hits Ctrl-C, `AbortController.abort()` fires. fetch immediately rejects the underlying connection. But **what about the SSE events already received**?

Claude Code's handling: **whatever was received, was received**. Say 3 deltas have already come in, and the client has already accumulated those 3 chunks of text into the assistant message. After the abort, this incomplete assistant message **still gets appended to the messages array** — its content is those 3 chunks of text, with no `tool_use` and no `stop_reason`.

The effect on the loop's state machine:
- The terminal type is `aborted_streaming` — indicating the interrupt happened during the streaming phase
- On the next turn of conversation, this incomplete message is there in the history — the LLM can see that it once said something and stopped halfway

**The trade-off in this design**:
- **Keep** the partial output — the user can look back and see how far the loop had gotten
- **Discard** the partial output — cleaner, but the user loses visibility into progress

Claude Code chooses to keep it. The reason: pressing Ctrl-C usually means "I saw the LLM say something wrong, and I want to cut it off" — those wrong words need to be preserved, so that in the next turn the user can refer back to them ("what you said just now about X was wrong"). Discarding it would lose that context.

## Chicago MCP Cleanup Only Runs on Non-Subagent Interrupts

A small but subtle detail: certain MCP servers (e.g. "chicago" — an internal Anthropic service) need to **clean up connection state** when the loop ends.

Claude Code's handling: **cleanup only runs when the main-thread loop is interrupted** — a sub-agent interrupt does not trigger this cleanup.

**Why**: a sub-agent is spawned from inside the main-thread loop, and it shares the same MCP server connection as the main-thread loop. If the sub-agent gets interrupted, the main-thread loop may still need to keep using MCP — the connection shouldn't be torn down.

**This detail reflects how the boundary between sub-agent and main thread is handled** — see 09 · Sidechain · The Sub-agent Loop. The main thread and the sub-agent **share the same `queryLoop`**, but **branch off** a few behaviors that belong only to the main thread (checked via `if (!toolUseContext.agentId)`). MCP cleanup is one of them.

## Interrupt Is the Second Exception to "No One Participates Mid-Loop"

[Article 01](01-tool-permission.md) covered permission approval as the **first exception** to "no one participates mid-loop" — it lets the user step in when a dangerous operation is about to happen.

**Interrupt is the second exception** — it lets the user step in at any moment, for any reason. Permission approval is **the loop proactively waiting on the user**; interrupt is **the user proactively cutting off the loop**.

Add [article 04](04-stop-reason.md)'s **maxTurns** — an automatic stop when a limit is hit, with no user involvement required — and the three complement each other:

- **Permission approval**: the loop proactively stops, waiting for the user to make the call at a dangerous moment
- **Interrupt**: the user proactively cuts off the loop, stopping whenever they want
- **maxTurns**: a hard safety net, so nothing runs forever even with no one watching

Together the three guarantee that the premise of "the loop runs automatically" never spirals out of control, **under any circumstance**. The 4 downstream mechanisms hooked up in [article 00](00-intro.md) all land here.

## Summary

- **One AbortController runs through the whole loop** — a single Ctrl-C from the user notifies every parallel action at once
- **3 checkpoints** — the HTTP request (fetch is signal-aware), the gap between streaming and tool execution, and the gap between tool batches
- **Synthetic tool_result** — after an interrupt, the loop scans in-flight `tool_use` blocks and patches in a synthesized `is_error: 'Interrupted by user'` result, preserving the pairing invariant
- **Two meanings of "interrupt"** — split via `signal.reason`: a plain interruption synthesizes "Interrupted by user"; an interruption meant to submit a new message does not
- **A streaming interrupt keeps the partial output** — so the user can see how far the loop got and refer back to what it said wrong
- **Chicago MCP cleanup only runs on the main thread** — a sub-agent interrupt doesn't touch the shared MCP connection
- **Interrupt is the second exception to "no one participates mid-loop"** — permission approval, interrupt, and maxTurns complement each other

The next article, 09 · Sidechain · The Sub-agent Loop, covers Claude Code's last major mechanism — how a sub-agent runs through the very same `queryLoop` while branching off from main-thread behavior in 12 different spots, the standalone `.claude/subagents/<agentId>.jsonl` file, and the rules governing how `agentId` drives the branching.

---

## References

**Primary file locations** (v2.1.220):
- `src/QueryEngine.ts` — `abortController`, `interrupt()`
- `src/query.ts` — `yieldMissingToolResultBlocks`, synthesis of in-flight `tool_use`
- `src/query.ts` — the `signal.reason === 'interrupt'` branch
- `src/hooks/useCancelRequest.ts` — Ctrl-C / Esc event capture
- `src/hooks/useCancelRequest.ts` — `chat:cancel` / `app:interrupt` priority

**Related articles**:
- [00 · Intro · From Chat Window to Loop](00-intro.md) — the "no one participates mid-loop" premise
- [01 · From Tool Declaration to Pre-execution Approval](01-tool-permission.md) — the first exception, permission approval
- [03 · From Reading a File to Parallel Scheduling](03-parallel-scheduling.md) — the other scenario `ensureToolResultPairing` patches
- [04 · From "Done Answering" to the 7 Meanings of stop_reason](04-stop-reason.md) — the maxTurns safety net
- 09 · Sidechain · The Sub-agent Loop — next article, special handling of sub-agent interrupts
- [02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md) — the hard constraint of the pairing invariant
