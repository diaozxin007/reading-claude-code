Earlier articles treated "calling the LLM" as **one atomic operation**:

```
response = call_llm(messages)
```

That's not actually true. The Anthropic API streams its response back via **Server-Sent Events (SSE)** — the LLM generates output while sending it to the client **in fragments**. When you see text appear character by character in Claude Code, it's not "the whole thing gets generated, then displayed" — it's SSE fragments streaming in and being rendered in real time.

This article covers how that streaming works:

- In one response, how many events does the Anthropic API send, and what are they?
- How does Claude Code merge these fragments back into one complete assistant message?
- The JSON parameters inside `tool_use` are sent as partials — how does the client parse them incrementally?
- How does the UI layer consume these events to make text appear character by character?

## One Call, Six Kinds of Events

The SSE stream of a single LLM call looks like this (simplified):

```
event: message_start           ← start of a response
event: content_block_start     ← a content block begins (text or tool_use)
event: content_block_delta     ← incremental content for this block (text char by char · tool_use params JSON fragment by fragment)
event: content_block_delta     ← (there can be many of these)
event: content_block_delta
event: content_block_stop      ← this block ends
event: content_block_start     ← next block begins
...
event: message_delta           ← message-level metadata update (stop_reason · usage etc.)
event: message_stop            ← the whole response ends
```

**Six kinds of events in total**:
- **`message_start`** — meta-info for the response (id, model, role, etc.; the content array is still empty)
- **`content_block_start`** — a content block begins, declaring its type (`text` / `tool_use` / `thinking`, etc.)
- **`content_block_delta`** — a small increment of content for this block
- **`content_block_stop`** — this block ends
- **`message_delta`** — message-level metadata (stop_reason / usage counts), usually sent once right before message_stop
- **`message_stop`** — the response ends

**Key point**: a single response can have **multiple content blocks**. For example: one text segment + one tool_use is 2 blocks, each going through its own start / delta / stop.

## How the Client Merges This into One Complete Message

Claude Code maintains a `contentBlocks` array:

```
contentBlocks = []
```

It accumulates in event order:

```
event: message_start
    → create an assistant message skeleton
      { id: '...', role: 'assistant', content: [] }

event: content_block_start (index=0, type=text)
    → contentBlocks[0] = { type: 'text', text: '' }

event: content_block_delta (index=0, delta: { type: 'text_delta', text: 'Let me first' })
    → contentBlocks[0].text += 'Let me first'

event: content_block_delta (index=0, delta: { type: 'text_delta', text: ' read auth.py' })
    → contentBlocks[0].text += ' read auth.py'
      # now contentBlocks[0].text === 'Let me first read auth.py'

event: content_block_stop (index=0)
    → block 0 is complete

event: content_block_start (index=1, type=tool_use, name='Read')
    → contentBlocks[1] = { type: 'tool_use', name: 'Read', input: '' }

event: content_block_delta (index=1, delta: { type: 'input_json_delta', partial_json: '{"file' })
    → contentBlocks[1].input += '{"file'

event: content_block_delta (index=1, delta: { partial_json: '_path":"auth.py"}' })
    → contentBlocks[1].input += '_path":"auth.py"}'
      # now the concatenated input is '{"file_path":"auth.py"}'

event: content_block_stop (index=1)
    → block 1 is complete · JSON parse input · tool_use is ready

event: message_delta (delta: { stop_reason: 'tool_use' }, usage: {...})
    → update message.stop_reason and usage

event: message_stop
    → message is complete · appended to the messages array · move on to the next loop step
```

**Core action**: each event type updates a specific field on `contentBlocks[part.index]`. Text goes through `text += delta.text`; tool_use goes through `input += delta.partial_json`.

**Why use `text +=` instead of replacing** — because the API guarantees deltas are **strictly incremental** and never resent. So the client accumulates with append, until content_block_stop.

## tool_use's JSON Is Sent in Fragments

The `input` field of `tool_use` — the tool's parameters — is a **JSON object**. But over SSE it arrives as **string fragments**:

```
delta 1: partial_json: '{"file'
delta 2: partial_json: '_path":"'
delta 3: partial_json: 'auth.py"}'
```

Only once all three fragments are stitched together do you get the complete `{"file_path":"auth.py"}`.

**The naive approach**: wait until content_block_stop, then parse the JSON all at once.

**What Claude Code does**: parse incrementally as data arrives — as soon as the **key parameters** can be inferred from the partial JSON, it can kick off downstream action without waiting for stop. This is what `StreamingToolExecutor` does (see [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md)) — letting a tool start running while the LLM is still streaming its output.

**The cost**: the JSON parser has to handle partial input (e.g. a missing `}`). Claude Code hand-wrote a parser tolerant of incomplete JSON to do this.

## A Counterintuitive Detail: "Resent" Text in Deltas

The Anthropic SDK has a somewhat non-obvious behavior — for a `content_block_start` event on a text-type block, it **carries a small piece of initial text**, and then **the next delta event repeats that same piece of text**.

In pseudocode:

```
event: content_block_start (block: { type: 'text', text: 'Hello' })
event: content_block_delta (delta: { text_delta: 'Hello, I am' })   ← "Hello" shows up again!
```

If the client naively does `contentBlocks[0].text = block.text` and then `contentBlocks[0].text += delta.text`, the result becomes `HelloHello, I am` — duplicated.

**What Claude Code does**: it **deliberately ignores** the text field in content_block_start, and only accumulates from deltas. The source has a comment stating outright that this is an SDK quirk.

**This is a classic small pitfall in SSE integration** — the API's surface semantics look clean, but real-world integration always has non-standard behaviors to handle.

## A Subtler Pitfall: Mutating in Place Instead of Replacing

After an assistant message has been appended to the `messages` array, it **still needs to receive further delta updates**. Concretely:

- At content_block_stop, Claude Code immediately appends this assistant message to messages (so the UI can see it as early as possible)
- Then the message_delta event arrives, carrying stop_reason and usage
- Claude Code needs to write stop_reason and usage into **that same message that's already sitting in the messages array**

**The naive approach**: `messages[last] = { ...messages[last], stop_reason: '...' }` (create a new object to overwrite it)

**What Claude Code does**: **mutate the original object directly** — `messages[last].message.stop_reason = '...'`.

Why not replace? Because that message in the messages array has **already been referenced elsewhere** — for example, the "transcript persistence queue" has saved a reference to this exact message, waiting to asynchronously stringify it into a JSONL file. If replace were used, the persistence queue would still be holding the old object, and the stop_reason written to disk would be null. With mutate, every reference reads the latest stop_reason.

**This detail exposes a design choice**: Claude Code shares message references across multiple places (the in-memory array / the UI layer / the persistence queue), and relies on mutating the original object to guarantee everyone sees the same state. It goes against functional-programming instincts, but **buys simple, reliable reference consistency**.

## How the UI Layer Consumes the Stream

How does the UI layer "know" where the stream currently is and when it should re-render?

The answer: **a hand-rolled store**. The entire implementation is 34 lines of code, providing a minimal interface (setState / getState / subscribe) — no popular state management library involved.

Consuming stream events from this store:
- Every time a new delta arrives, update the field for the "current streaming message" in the store
- UI components subscribe to that field, and re-render whenever it changes
- Wherever the text has accumulated to, that's where the UI renders to

**This is how "text appears character by character" is implemented.**

**Why keep it this simple**: a CLI scenario doesn't need complex time-travel, devtools, or a middleware ecosystem. A hand-rolled store gives **fewer dependencies, faster startup, controllable behavior** — a textbook example of "good enough, don't pull in a popular library."

## QueryGuard — a 3-State Guard Against Concurrent Queries

The UI layer also has a dedicated **concurrency guard**:

```
States: idle / dispatching / running
- idle: not querying · can accept new user input
- dispatching: the user pressed enter · the message is being sent out
- running: the LLM is currently streaming a response
```

What happens if the user presses enter again while in the running state? The message **gets queued** — not processed immediately, but stored in a `commandQueue` array, drained one at a time once the loop returns to idle.

**Why this guard is needed**:
- Only one loop can be running at a time
- User input must not overwrite the state of the current loop
- But the user shouldn't be locked out of the keyboard by a "spinner"

**Why a state machine instead of a boolean** — because "dispatching" and "running" need to be distinguished:
- dispatching is brief, a few dozen milliseconds — but what should Ctrl-C do during it? (Not interrupt the loop, but cancel the dispatch)
- running is long (a few seconds to tens of seconds) — Ctrl-C should interrupt the current loop

The 3 states cover these two different Ctrl-C semantics; a boolean can't express that.

## Summary

- **A single LLM call is an SSE stream** — 6 kinds of events: `message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop`
- **The client accumulates via a contentBlocks array** — text deltas go through `text +=`, tool_use deltas go through `input += partial_json`
- **tool_use's JSON is streamed in fragments** — it can be parsed as it arrives, which underpins the extreme optimization of StreamingToolExecutor
- **Two SDK quirks need handling**: the text field in content_block_start must not be appended (it would duplicate), and message updates must mutate rather than replace (to preserve reference consistency)
- **The UI layer uses a hand-rolled 34-line store** — no popular state management library, fewer dependencies, controllable behavior
- **QueryGuard has 3 states** — idle / dispatching / running, covering different user-input semantics

The next article, [07 · Retry and Error Recovery](07-retry-recovery.md), covers the concrete recovery flow when the loop hits an error: withRetry exponential backoff, the three-tier `prompt_too_long` recovery, fallback model swap, and special handling for 529 overloaded.

---

## References

**Primary file locations** (v2.1.220):
- `src/services/api/claude.ts` · `queryModelWithStreaming` · the switch over the 6 event kinds
- `src/QueryEngine.ts` · the SDK layer consuming stream_event
- `src/state/store.ts` · the hand-rolled 34-line store
- `src/state/AppState.tsx` · UI components consuming the store
- `src/utils/QueryGuard.ts` · the idle / dispatching / running 3-state guard

**Related articles**:
- [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md) · StreamingToolExecutor depends on streaming JSON parsing
- [05 · The QueryEngine Main Loop · A State Machine Overview](05-query-engine.md) · the expanded view of the "call the LLM" step inside the main loop
- [07 · Retry and Error Recovery](07-retry-recovery.md) · next article · what happens when a stream is truncated or fails

**Anthropic official**:
- [Messages API — streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · the official definition of the 6 event kinds
