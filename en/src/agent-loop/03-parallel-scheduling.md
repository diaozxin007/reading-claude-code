The previous two articles covered the two layers of interception between the LLM saying it wants to call a tool and the tool actually executing — [01 · Tool Permission Approval](01-tool-permission.md) and [02 · Hooks](02-hooks.md). Once both layers are passed, the tool is finally ready to **actually execute**.

But a single assistant message can declare **multiple `tool_use` blocks**. The harness faces a decision: **start them all at once, or run one to completion before starting the next?** Parallel is faster — but if two tools both want to modify the same file, running them in parallel can make them overwrite each other instead.

This article covers execution scheduling: how multiple `tool_use` blocks get split into batches, which ones can run in parallel, which must run serially, and what happens when a tool crashes. Along the way we'll keep referring back to the second invariant from Context article [02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md) — **every `tool_use` must have a corresponding `tool_result`** — because parallel scheduling, error handling, and interruption all have to operate while preserving that invariant.

## The Simplest Possible Tool Call

Start with the smallest example: the LLM decides to read a file.

The assistant message it outputs carries one `tool_use` block:

```
{ role: 'assistant', content: [
    { type: 'text',     text: 'Let me look at auth.py first' },
    { type: 'tool_use', id: 'toolu_A3f2',
                        name: 'Read',
                        input: { file_path: 'auth.py' } }
  ] }
```

A `tool_use` block has three key fields: `id` (a unique identifier for this tool call — the later `tool_result` uses it to pair up), `name` (which tool to call — `Read` / `Edit` / `Bash` / etc.), and `input` (the parameters, a JSON object).

The harness looks up the matching tool implementation by `name`, passes in `input`, executes, gets the result, and packages it as a `tool_result` appended to `messages`:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_A3f2',
                           content: '<200 lines of auth.py content>' }
  ] }
```

With `tool_use_id` filled back in, **the round trip of one tool call closes the loop**. On the next call to the LLM, this `tool_result` gets sent along with everything else, and the LLM "sees" the file contents.

## One Message Can Carry Multiple `tool_use` Blocks

The LLM can declare multiple `tool_use` blocks in **the same assistant message**:

```
{ role: 'assistant', content: [
    { type: 'text',     text: 'Let me read two files in parallel' },
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file: 'auth.py' } },
    { type: 'tool_use', id: 'toolu_B', name: 'Read', input: { file: 'login.py' } }
  ] }
```

At this point the harness faces a choice: **should these two `Read` calls start at the same time, or should one finish before the next starts?**

Technically, either works:

- **Start simultaneously** (parallel): both `Read` calls run together — fast
- **One finishes before the next starts** (serial): safe, but slow

Claude Code uses a **hybrid strategy** — the LLM is allowed to declare any number of `tool_use` blocks, and **the harness itself decides whether to run them in parallel or serially**. The LLM is only responsible for saying what it wants to call; how it actually gets called is the harness's business.

## The Basis for Parallelism — Every Tool Declares Its Own Safety

The naive approach: the harness maintains an internal table — `Read` can run in parallel, `Edit` cannot, `Bash` depends on the command...

**Claude Code does the opposite**: **it lets each tool declare its own answer**.

Every tool implements a judgment of "can I safely run in parallel this time":

- **Read** — only reads files, changes no state — **always says "yes"**
- **Grep / Glob** — only search the filesystem — **always say "yes"**
- **Edit / Write** — modify files — **always say "no"** — because two `Edit` calls running in parallel might touch the same file
- **Bash** — depends on the specific command — read-only commands like `git status` can run in parallel, but something like `rm` must run serially

**The judgment logic lives inside each tool** — because only the tool itself knows its own side effects. This decision is **not declared by the LLM, and not guessed by the harness** — it's **each tool's own self-declaration**.

**This is a design that pushes the knowledge of "can I run in parallel" down into the tool itself** — when a tool adds a new command or gains a new side effect, there's no need to touch the harness's scheduler; the tool just updates its own judgment.

## The Batching Rules

The harness takes N `tool_use` blocks, scans them in declaration order, and groups **consecutive blocks that all say "yes"** into a single batch, cutting the batch whenever it hits one that says "no."

For example, say the LLM declares 4 `tool_use` blocks:

```
1. Read auth.py         → can run in parallel
2. Read login.py        → can run in parallel
3. Edit auth.py         → cannot run in parallel
4. Read session.py      → can run in parallel
```

The batching result:

```
Batch 1: [Read auth.py, Read login.py]   ← both can run in parallel · grouped into one batch
Batch 2: [Edit auth.py]                   ← cannot run in parallel · its own batch
Batch 3: [Read session.py]                ← could run in parallel, but is cut off by the unsafe call before it · its own batch
```

**Batches run strictly in sequence; within a batch, calls run in parallel.** This guarantees:

- The two `Read` calls don't wait on each other (Batch 1 runs in parallel)
- All the `Read` calls before the `Edit` finish first (Batch 1 completes before Batch 2 starts)
- The `Read` call after the `Edit` never sees the pre-`Edit` state (Batch 2 completes before Batch 3 starts)

**There's an upper bound on the concurrency within a single batch** — by default, up to 10 tools run at once; beyond that, calls queue up (to avoid overwhelming local resources).

## The Judgment Itself Can Also Crash

A subtlety: the "can I run in parallel" judgment itself **can throw an exception**. For instance, the `Bash` tool's judgment has to parse the command line using shell-quote parsing — an oddly quoted command line can make the parser crash.

**Claude Code's handling**: catch every exception, and **fall back to assuming "cannot run in parallel."**

**Design philosophy**: when a tool's judgment has a bug, the system's behavior should **degrade to the most conservative strategy** — slower, but never wrong. Better to reduce parallelism than to let an unsafe tool quietly run in parallel.

**This is "conservative over aggressive"** — when you're not sure, take the safe path. It's the same design orientation as sub-agent permissions not being inherited (a conservative default) in [article 01](01-tool-permission.md).

## A More Aggressive Optimization — Starting a Tool While Its JSON Is Still Streaming

The batching described above happens **after the LLM finishes a message** — only then does the harness start scanning. But from a streaming perspective (see [article 06](06-streaming.md)), the LLM actually sends output **frame by frame** — the `tool_use`'s `name` arrives first, and the parameters arrive as **fragments of a JSON string** streamed in over time:

```
Frame 1: tool_use begins · name = 'Read'
Frame 2: input JSON fragment: '{"file'
Frame 3: input JSON fragment: '_path":"'
Frame 4: input JSON fragment: 'auth.py"}'
Frame 5: tool_use ends
```

**The naive approach**: wait until frame 5, once the JSON is complete, then start `Read`.

**What Claude Code does**: **parse while streaming** — as soon as the key parameters can be inferred ahead of time (e.g., `file_path` is already complete), it immediately starts `Read`, without waiting for frame 5.

**The payoff**: while the LLM is still streaming out the next chunk of text, `Read` is already reading the file — the two latencies run in parallel. A single tool call's `Read` might take 100ms, while the LLM's next chunk of text output might take 2s. Serially, the user-visible latency is 2.1s; in parallel, it's `max(2s, 100ms) = 2s`. Add that up over dozens of tool calls in a single session, and the savings amount to 5-10 seconds.

**The cost**: the JSON parser needs to handle partial input (it needs to be able to infer values even when the closing `}` is missing) — the harness hand-writes a parser tolerant of incomplete JSON to do this.

## What Happens When a Tool Crashes

Scenario: the LLM declares `Read /path/to/does_not_exist.py` — the file doesn't exist. Or `Bash rm -rf /` — the permission system rejects execution.

**The naive approach**: the tool throws, the loop crashes, the user sees a red error.

**What Claude Code does**: **a tool never throws up to the loop** — it catches the exception and converts it into a `tool_result` with `is_error: true`:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_X',
                           content: '<tool_use_error>File does not exist</tool_use_error>',
                           is_error: true }
  ] }
```

**Design philosophy**: a tool execution failure is just another state of the loop, not an exception that interrupts it. It gets converted into feedback and handed to the LLM, which decides what to do next.

The reasoning:

- The LLM is fully capable of understanding "file doesn't exist" — on its next call it can decide to retry, or run `Glob` to search for it, or give up and tell the user
- If the tool threw up to the loop, the loop could only crash or silently swallow it — neither is as good as letting the LLM see the error itself and judge for itself

**A few typical sources of `is_error`**:

- **The tool itself throws internally** — file doesn't exist, permission denied, a Bash command exits with a nonzero code — converted into `<tool_use_error>...</tool_use_error>` content with `is_error: true`
- **Unknown tool name** — the LLM declares a tool that isn't implemented — also converted to `is_error`, with content like "Tool 'XXX' not found"
- **User interruption** — Ctrl-C, see [article 08](08-interrupt.md) — synthesizes `content: 'Interrupted by user'` with `is_error: true`
- **A patched-in fake `tool_result`** — `content: '[Tool result missing due to internal error]'`, `is_error: true`

**`is_error` is an explicit signal** — it tells the LLM "this tool execution did not succeed." The LLM was trained to recognize this field, and seeing `is_error` automatically puts it into an "I need to handle this error" state.

## The Ultimate Guardian of the Pairing Invariant

Put the two designs above together — **a crashed tool converts to `is_error` instead of throwing** and **an unknown tool name also converts to `is_error`** — and the result is:

**As long as the LLM has declared a `tool_use`, no matter what happens afterward, a corresponding `tool_result` will always be produced.**

This is the tool system's **strongest guarantee** for the second invariant defined in [Context 02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md) — "every `tool_use` must be paired with a `tool_result`":

- Tool crashes — there's an `is_error` `tool_result`
- Tool not found — there's an `is_error` `tool_result`
- User interrupts — there's an `is_error` `tool_result`

Tool execution **never** leaves an orphaned `tool_use` behind. Breaks in the pairing invariant can only come from mechanisms further up the stack (compaction squashing away the assistant message that held the `tool_use`, or rewind truncating the messages array) — and those breaks are backstopped by the **message patching mechanism** covered in Context article 04.

**The tool system guards its own segment; the layers above guard breaks that cross their own boundaries** — the layering is clean.

## Summary

- **One tool call**: the LLM outputs `tool_use` → the harness dispatches to the implementation → executes → packages a `tool_result` and appends it
- **One message can carry multiple `tool_use` blocks** — the harness decides parallel vs. serial; the LLM doesn't concern itself with this
- **Each tool self-declares whether it can run in parallel** — this knowledge lives inside the tool, not guessed by the harness
- **Batching rule**: consecutive safe calls are grouped into one parallel batch; an unsafe call cuts the batch off on its own, preserving declaration order
- **The judgment itself can also crash** — falls back to the conservative choice of serial execution (degrades to the safest option)
- **Starting a tool while its JSON is still streaming** — lets tool latency and LLM output latency run in parallel, saving anywhere from a few to a dozen-plus seconds per session
- **A crashed tool converts to an `is_error` `tool_result`** — a tool error is feedback for the LLM, not an exception for the loop
- **The tool system is the strongest guardian of the pairing invariant** — as long as the LLM declares a `tool_use`, a `tool_result` is guaranteed to follow

The next article, [04 · From "I'm Done Talking" to the 7 Meanings of stop_reason](04-stop-reason.md), covers the other end of the loop — after a tool finishes and its `tool_result` is filled back in and the LLM is called again, how does the loop decide the LLM has "finished talking"?

---

## References

**Primary file locations** (v2.1.220):
- `src/services/tools/toolOrchestration.ts` — the `runTools` main flow; `runToolsSerially` / `runToolsConcurrently` batch dispatch
- `src/services/tools/toolOrchestration.ts` — the `isConcurrencySafe` interface; `partitionToolCalls` batching logic
- `src/query.ts` — `StreamingToolExecutor`; pre-launching tools while JSON is still streaming
- `src/services/tools/toolExecution.ts` — single tool execution; the wrapper that converts a crash into an `is_error` `tool_result`

**Related articles**:
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) — the permission interception before a tool executes
- [02 · Hooks · Programmable Intervention Points on the Loop](02-hooks.md) — hooks before and after tool execution
- [04 · From "I'm Done Talking" to the 7 Meanings of stop_reason](04-stop-reason.md) — next article — how the loop decides to continue after a tool finishes
- [06 · Streaming · From SSE Events to Character-by-Character Display](06-streaming.md) — the full mechanism behind streaming JSON parsing
- [08 · Interrupt · From Ctrl-C to a Synthesized tool_result](08-interrupt.md) — synthesizing an `is_error` `tool_result` on user interruption
- [02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md) — the definition of the pairing invariant

**Anthropic official docs**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) — the API conventions for `tool_use` / `tool_result`
