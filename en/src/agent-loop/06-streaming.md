The previous chapters treated “calling the LLM” as **an atomic operation**:

```
response = call_llm(messages)
```

In reality, it is not. The Anthropic API streams responses using **Server-Sent Events (SSE)**—as the LLM generates output, it sends the result to the client in **chunks**. When users see text appearing character by character in Claude Code, the full response has not been generated before being displayed; SSE chunks arrive and are rendered in real time.

This chapter explains how streaming works:

- How many event types does a single Anthropic API response emit, and what are they?
- How does Claude Code merge these fragments into a complete assistant message?
- The JSON arguments in `tool_use` are sent incrementally—how does the client parse them as they arrive?
- How does the UI layer consume these events and make text appear character by character?

## One Call, Six Event Types

The SSE stream for a single LLM call looks like this (simplified):

```
event: message_start           ← start of a response
event: content_block_start     ← start of a content block (text or tool_use)
event: content_block_delta     ← incremental content for this block (text character by character; tool_use arguments in JSON fragments)
event: content_block_delta     ← (there may be many of these)
event: content_block_delta
event: content_block_stop      ← end of this block
event: content_block_start     ← start of the next block
...
event: message_delta           ← message-level metadata update (stop_reason, usage, etc.)
event: message_stop            ← end of the entire response
```

There are **six event types**:

- **`message_start`** — Response metadata (`id`, `model`, `role`, and so on; the `content` array is still empty)
- **`content_block_start`** — A content block begins, declaring its type (`text`, `tool_use`, `thinking`, and so on)
- **`content_block_delta`** — A small increment of content for the block
- **`content_block_stop`** — The block ends
- **`message_delta`** — Message-level metadata (`stop_reason` and `usage` counts), usually emitted once before `message_stop`
- **`message_stop`** — The response ends

**The key point:** a single response can contain **multiple content blocks**. For example, a piece of text followed by a `tool_use` produces two blocks, each with its own start, delta, and stop events.

## How the Client Merges Events into One Complete Message

Claude Code maintains a `contentBlocks` array:

```
contentBlocks = []
```

It accumulates data in event order:

```
event: message_start
    → create an assistant message skeleton
      { id: '...', role: 'assistant', content: [] }

event: content_block_start (index=0, type=text)
    → contentBlocks[0] = { type: 'text', text: '' }

event: content_block_delta (index=0, delta: { type: 'text_delta', text: 'First, I’ll ' })
    → contentBlocks[0].text += 'First, I’ll '

event: content_block_delta (index=0, delta: { type: 'text_delta', text: 'read auth.py' })
    → contentBlocks[0].text += 'read auth.py'
      # contentBlocks[0].text is now 'First, I’ll read auth.py'

event: content_block_stop (index=0)
    → block 0 is complete

event: content_block_start (index=1, type=tool_use, name='Read')
    → contentBlocks[1] = { type: 'tool_use', name: 'Read', input: '' }

event: content_block_delta (index=1, delta: { type: 'input_json_delta', partial_json: '{"file' })
    → contentBlocks[1].input += '{"file'

event: content_block_delta (index=1, delta: { partial_json: '_path":"auth.py"}' })
    → contentBlocks[1].input += '_path":"auth.py"}'
      # the assembled input is now '{"file_path":"auth.py"}'

event: content_block_stop (index=1)
    → block 1 is complete; parse input as JSON; tool_use is ready

event: message_delta (delta: { stop_reason: 'tool_use' }, usage: {...})
    → update message.stop_reason and usage

event: message_stop
    → the message is complete; append it to the messages array; proceed to the next step in the loop
```

**The core operation:** each event updates a specific field in `contentBlocks[part.index]`. Text uses `text += delta.text`; `tool_use` uses `input += delta.partial_json`.

**Why use `text +=` instead of replacement?** Because the API guarantees that each delta contains only new content and does not resend previous deltas. The client appends each increment until `content_block_stop`.

## `tool_use` JSON Is Sent in Fragments

The `input` field of `tool_use`—the tool arguments—is a **JSON object**. In the SSE stream, however, it arrives as **string fragments**:

```
delta 1: partial_json: '{"file'
delta 2: partial_json: '_path":"'
delta 3: partial_json: 'auth.py"}'
```

Only after joining all three fragments do you get the complete `{"file_path":"auth.py"}`.

**The naive approach:** wait for `content_block_stop`, then parse the JSON all at once.

**Claude Code’s approach:** parse as data arrives. As soon as it can **infer the key arguments** from the partial JSON, it can start the next action without waiting for the stop event. This is how `StreamingToolExecutor` works (see [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md))—it lets a tool begin running while the LLM is still streaming its output.

**The cost:** the JSON parser must handle partial input, such as a missing `}`. Claude Code implements a custom parser that tolerates incomplete JSON for this purpose.

## A Counterintuitive Detail: Text Deltas Contain “Replayed” Content

The Anthropic SDK has a non-obvious behavior: when the block is text, the `content_block_start` event **includes a small initial piece of text**, and the **next delta event repeats that text**.

In pseudocode:

```
event: content_block_start (block: { type: 'text', text: 'Hello' })
event: content_block_delta (delta: { text_delta: 'Hello, I am' })   ← "Hello" appears again!
```

If the client simply runs `contentBlocks[0].text = block.text` followed by `contentBlocks[0].text += delta.text`, the result becomes `HelloHello, I am`—duplicated content.

**Claude Code’s handling:** it **deliberately ignores** the `text` field in `content_block_start` and accumulates content only from deltas. A source-code comment explicitly identifies this as an SDK quirk.

**This is a typical class of subtle SSE integration bug:** the API’s surface semantics look clear, but real integrations invariably have nonstandard behavior that must be handled.

## A More Subtle Trap: Mutate Instead of Replace

After an assistant message has been appended to the `messages` array, it **must still receive subsequent delta updates**. Specifically:

- At `content_block_stop`, Claude Code immediately appends the assistant message to `messages` so the UI can see it as early as possible.
- The `message_delta` event then arrives with `stop_reason` and `usage`.
- Claude Code needs to insert `stop_reason` and `usage` into **the message already stored in the `messages` array**.

**The naive approach:** `messages[last] = { ...messages[last], stop_reason: '...' }` (create a new object and replace the old one).

**Claude Code’s approach:** **mutate the original object directly**—`messages[last].message.stop_reason = '...'`.

Why not replace it? Because the message in the `messages` array is **already referenced elsewhere**. For example, the transcript persistence queue may hold a reference to it, preparing to stringify it asynchronously and write it to JSONL. If the object is replaced, the persistence queue still holds the old object and writes a null `stop_reason` to disk. With mutation, every reference sees the latest `stop_reason`.

**This detail reveals a design choice:** Claude Code shares message references across several places—the in-memory array, the UI layer, and the persistence queue—and relies on mutating the original object so they all observe the same state. This runs against functional-programming intuition, but **provides simple, reliable referential consistency**.

## How the UI Layer Consumes the Stream

How does the UI layer “know” how much of the response has arrived and when to render again?

The answer is **a hand-written store**. The entire implementation is 34 lines and exposes only a minimal interface (`setState`, `getState`, and `subscribe`), without using any popular state-management library.

The UI consumes stream events through this store:

- Whenever a new delta arrives, update the fields of the “currently streaming message” in the store.
- UI components subscribe to that field and rerender whenever it changes.
- The UI renders exactly as much text as has accumulated.

**That is how text appears character by character.**

**Why is it so simple?** A CLI does not need sophisticated time travel, devtools, or middleware ecosystems. A hand-written store means **fewer dependencies, faster startup, and controllable behavior**. It is a textbook “use only what is necessary; do not pull in a popular library” decision.

## QueryGuard—Three States to Prevent Concurrent Queries

The UI layer also has a dedicated **concurrency guard**:

```
States: idle / dispatching / running
- idle: no query is active; new user input can be accepted
- dispatching: the user pressed Enter; the message is being sent
- running: the LLM is currently streaming its response
```

What happens if the user presses Enter again while in the `running` state? The message is **queued**—it is not processed immediately, but stored in a `commandQueue` array and drained one by one when the loop returns to `idle`.

**Why is this guard necessary?**

- Only one loop can run at a time.
- User input must not overwrite the current loop’s state.
- But users should not have their keyboards locked by a loading spinner.

**Why use a state machine instead of a boolean?** Because `dispatching` and `running` must be distinguished:

- `dispatching` lasts only tens of milliseconds, but what should Ctrl-C do during that interval? It should cancel dispatching, not interrupt the loop.
- `running` lasts longer—from a few seconds to tens of seconds—and Ctrl-C should interrupt the current loop.

The three states cover these two distinct Ctrl-C semantics; a boolean cannot express them.

## Conclusion

- **A single LLM call is an SSE stream** with six event types: `message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop`
- **The client accumulates data in a `contentBlocks` array**—text deltas use `text +=`, while `tool_use` deltas use `input += partial_json`
- **The JSON for `tool_use` arrives as a fragmented stream**—it can be parsed incrementally, enabling the aggressive optimization performed by `StreamingToolExecutor`
- **Two SDK pitfalls must be handled:** the `text` field from `content_block_start` must not be appended because it would create duplicates; messages must be mutated rather than replaced to preserve referential consistency
- **The UI layer uses a 34-line hand-written store**—no popular state-management library, fewer dependencies, and controllable behavior
- **QueryGuard has three states**—`idle` / `dispatching` / `running`—covering distinct user-input semantics

The next chapter, [07 · Retries and Error Recovery](07-retry-recovery.md), explains the loop’s concrete recovery flow when errors occur: exponential backoff with `withRetry`, three-stage recovery from `prompt_too_long`, fallback model swapping, and special handling for 529 overloaded errors.

---

## References

**Primary file locations** (v2.1.220):

- `src/services/api/claude.ts` · `queryModelWithStreaming` · the switch over the six event types
- `src/QueryEngine.ts` · consumption of `stream_event` at the SDK layer
- `src/state/store.ts` · the 34-line hand-written store
- `src/state/AppState.tsx` · UI components consuming the store
- `src/utils/QueryGuard.ts` · the three states: `idle` / `dispatching` / `running`

**Related chapters:**

- [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md) · `StreamingToolExecutor` depends on streaming JSON parsing
- [05 · The QueryEngine Main Loop · A Complete View of the State Machine](05-query-engine.md) · expanding the “call the LLM” step in the main loop
- [07 · Retries and Error Recovery](07-retry-recovery.md) · the next chapter · handling interrupted or failed streams

**Official Anthropic documentation:**

- [Messages API—streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · official definitions of the six event types
