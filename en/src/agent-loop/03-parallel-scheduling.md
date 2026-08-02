The previous two chapters covered the two layers of interception between "the LLM says to call a tool" and "the tool actually executes" — [01 Permission Approval](01-tool-permission.md) and [02 Hooks](02-hooks.md). Once both layers pass, the tool is finally about to **actually execute**.

But a single assistant message may declare **multiple tool_use** blocks. The harness faces a decision: **start them all at once, or run one to completion before starting the next?** Parallel is faster — but if two tools both want to modify the same file, running them in parallel can cause them to overwrite each other.

This chapter covers execution scheduling: how multiple tool_use blocks get batched, which can run in parallel, which must run serially, and what happens when a tool crashes. Throughout the discussion, we'll repeatedly reference the second invariant from the Context series' [02 · Three Invariants of the Message Array](https://diaozxin007.github.io/reading-claude-code/zh/context-management/02-message-invariants.html) — **every tool_use must have a corresponding tool_result** — because parallel scheduling, error handling, and interruption all have to operate while preserving this invariant.

## The Simplest Possible Tool Call

Start with the smallest example: the LLM decides to read a file.

The assistant message it outputs contains a tool_use block:

```
{ role: 'assistant', content: [
    { type: 'text',     text: 'Let me look at auth.py first' },
    { type: 'tool_use', id: 'toolu_A3f2',
                        name: 'Read',
                        input: { file_path: 'auth.py' } }
  ] }
```

The tool_use block has three key fields: id (the unique identifier for this tool call, used later to pair it with a tool_result), name (which tool to call — Read / Edit / Bash, etc.), and input (the arguments, a JSON object).

The harness looks up the corresponding tool implementation from name, passes in input, executes it, gets a result, and packages it as a tool_result appended to messages:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_A3f2',
                           content: '<200 lines of auth.py content>' }
  ] }
```

tool_use_id fills back in — **the round trip of a single tool call closes the loop**. The next time the LLM is called, this tool_result gets sent along with everything else, and the LLM "sees" the file's contents.

## A Single Message Can Contain Multiple tool_use Blocks

The LLM can declare multiple tool_use blocks within **a single assistant message**:

```
{ role: 'assistant', content: [
    { type: 'text',     text: 'I'll read two files in parallel' },
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file: 'auth.py' } },
    { type: 'tool_use', id: 'toolu_B', name: 'Read', input: { file: 'login.py' } }
  ] }
```

At this point the harness faces a choice: **should these two Reads start at the same time, or should one run to completion before the next starts?**

Technically, either is possible:
- **Start simultaneously** (parallel): both Reads run together — fast
- **Run one to completion before the next** (serial): safe, but slow

Claude Code uses a **hybrid strategy** — it lets the LLM declare any number of tool_use blocks, and **the harness itself decides whether to run them in parallel or serially**. The LLM's job is only to say what to call; how exactly to call it is the harness's business.

## The Basis for the Parallelism Decision — Each Tool Declares It Itself

The naive approach: the harness maintains an internal table — `Read` can be parallelized, `Edit` cannot, `Bash` depends on the command...

**Claude Code does the opposite**: **it lets each tool declare it itself**.

Every tool implements a judgment of "can I safely run in parallel this time":

- **Read** — only reads a file, changes no state — **always says "yes"**
- **Grep / Glob** — only search the filesystem — **always say "yes"**
- **Edit / Write** — modify files — **always say "no"** — because two Edits in parallel might touch the same file
- **Bash** — depends on the specific command — read-only commands like `git status` can run in parallel, but commands like `rm` must be serial

**The judgment logic lives inside each tool** — because only the tool itself knows its own side effects. This decision is **not declared by the LLM, nor guessed by the harness** — it's **each tool's own self-declaration**.

**This design pushes the knowledge of "can I run in parallel" down to the tool itself** — when a tool adds a new command or gains a new side effect, there's no need to touch the harness's scheduler; the tool just updates its own judgment.

## The Batching Rule

The harness receives N tool_use blocks, scans through them in declaration order, and groups **consecutive blocks that all say "yes"** into a single batch, cutting the batch whenever it hits one that says "no."

For example, the LLM declares 4 tool_use blocks:

```
1. Read auth.py         → can parallelize
2. Read login.py        → can parallelize
3. Edit auth.py         → cannot parallelize
4. Read session.py      → can parallelize
```

Batching result:

```
Batch 1: [Read auth.py, Read login.py]   ← both can parallelize → grouped into one batch
Batch 2: [Edit auth.py]                   ← cannot parallelize → its own batch
Batch 3: [Read session.py]                ← can parallelize, but separated from Batch 1 by an unsafe call → its own batch
```

**Batches run strictly serially with respect to each other; within a batch, calls run in parallel**. This guarantees:

- The two Reads don't wait on each other (Batch 1 runs in parallel)
- All the Reads before the Edit have already finished (Batch 1 completes before Batch 2 starts)
- The Reads after the Edit won't see pre-Edit state (Batch 2 completes before Batch 3 starts)

**There's a cap on the degree of parallelism within a batch** — by default, up to 10 tools run at once; beyond that, they queue up (to avoid overwhelming local resources).

## The Judgment Itself Can Also Crash

A subtlety: the tool's "can I run in parallel" judgment **can itself throw an exception**. For instance, the Bash tool's judgment needs to parse the command line, using shell-quote to parse it — if the command line has unusual quoting, the parser might crash.

**Claude Code's handling**: catch every exception, and **fall back to assuming "cannot parallelize."**

**Design rationale**: when a tool's judgment has a bug, the system's behavior should be to **degrade to the most conservative strategy** — slower, but never wrong. Better to have less parallelism than to let an unsafe tool sneak into parallel execution.

**This is "conservative over aggressive"** — when you're not sure, take the safe path. It's the same design orientation as sub-agent permissions not being inherited (a conservative default) in [Chapter 01](01-tool-permission.md).

## A More Aggressive Optimization: Starting a Tool While Streaming-Parsing Its JSON

The batching described above happens **after the LLM finishes a message** — only then does the harness start scanning. But from a streaming perspective (see [Chapter 06](06-streaming.md)), the LLM is actually sending things **frame by frame** — the tool_use's name arrives first, and the arguments stream in as **fragments of a JSON string**:

```
Frame 1: tool_use begins · name = 'Read'
Frame 2: input JSON fragment: '{"file'
Frame 3: input JSON fragment: '_path":"'
Frame 4: input JSON fragment: 'auth.py"}'
Frame 5: tool_use ends
```

**The naive approach**: wait for frame 5 to finish, get the complete JSON, then start Read.

**Claude Code's approach**: **parse while streaming** — as soon as the key argument can be inferred ahead of time (e.g., file_path is complete), immediately start Read, without waiting for frame 5.

**Benefit**: while the LLM is still streaming out the next chunk of text, Read is already reading the file — the two latencies run in parallel. For one tool call, Read might take 100ms while the LLM's next text output takes 2s. Serially, the user sees 2.1s of latency; in parallel, it's max(2s, 100ms) = 2s. Across dozens of tool calls in a single session, this adds up to 5-10 seconds saved.

**Cost**: the JSON parser needs to handle partial input (inferring values even with a missing `}`) — the harness hand-wrote a parser tolerant of incomplete JSON to do this.

## What Happens When a Tool Crashes

Scenario: the LLM declares `Read /path/to/does_not_exist.py` — the file doesn't exist. Or `Bash rm -rf /` — the permission system refuses to execute it.

**The naive approach**: the tool throws an exception, the loop crashes, and the user sees a red error.

**Claude Code's approach**: **the tool never throws up to the loop** — it catches the exception and converts it into a tool_result with `is_error: true`:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_X',
                           content: '<tool_use_error>File does not exist</tool_use_error>',
                           is_error: true }
  ] }
```

**Design philosophy**: a tool execution failure is just another state of the loop, not an exception that interrupts it. It gets converted into feedback delivered to the LLM, and the LLM decides what to do next.

Reasons:
- The LLM is perfectly capable of understanding "file doesn't exist" — on its next call it can decide to retry, or try a `Glob` to search, or give up and tell the user
- If the tool threw up to the loop, the loop could only crash or swallow it — neither is better than letting the LLM see the error itself and judge accordingly

**A few typical sources of is_error**:

- **The tool itself throws internally** — file not found, permission denied, a bash command with a nonzero exit code — converted into `<tool_use_error>...</tool_use_error>` content, with is_error: true
- **Unknown tool name** — the LLM declares a tool that isn't implemented — also converted to is_error, with content like "Tool 'XXX' not found"
- **User interruption** — Ctrl-C, see [Chapter 08](08-interrupt.md) — synthesizes content: 'Interrupted by user', is_error: true
- **A patched-in synthetic tool_result** — content: '[Tool result missing due to internal error]', is_error: true

**is_error is an explicit signal** — telling the LLM "this tool execution didn't succeed." The LLM was trained to recognize this field — seeing is_error automatically puts it into an "I need to handle this error" state.

## The Ultimate Guardian of the Pairing Invariant

The two designs above combined — **crashed tools convert to is_error instead of throwing** + **unknown tool names also convert to is_error** — result in this:

**As long as the LLM declares a tool_use, no matter what happens afterward, a corresponding tool_result is guaranteed to be generated.**

This is the tool system's **strongest guarantee** for the second invariant from [Context 02 · Three Invariants of the Message Array](https://diaozxin007.github.io/reading-claude-code/zh/context-management/02-message-invariants.html) — "every tool_use must be paired with a tool_result":

- Tool crashes → an is_error tool_result
- Tool not found → an is_error tool_result
- User interrupts → an is_error tool_result

Tool execution **never** leaves an orphaned tool_use behind. Violations of the pairing invariant can only come from higher-level mechanisms (compaction squashing away the assistant message containing the tool_use, or rewind truncating the message array) — those violations are backstopped by the message-patching mechanism covered in Context series Chapter 04.

**The tool system guards its own segment; higher-level mechanisms guard against violations that cross its boundary** — a clean separation of layers.

## Summary

- **A single tool call**: the LLM outputs a tool_use → the harness dispatches to the implementation → executes → packages a tool_result and appends it
- **A single turn may contain multiple tool_use blocks** — the harness decides whether to run them in parallel or serially; the LLM doesn't care
- **Each tool self-declares whether it can be parallelized** — this is knowledge internal to the tool, not something the harness guesses
- **The batching rule**: consecutive safe calls are grouped into one parallel batch; an unsafe call cuts the batch, preserving declaration order
- **The judgment itself can also crash** — falling back to the conservative choice of running serially (degrading to the safest option)
- **Starting a tool while streaming-parsing its JSON** — lets the tool's latency run in parallel with the LLM's output latency, saving seconds to tens of seconds per session
- **A crashed tool converts to an is_error tool_result** — a tool error is feedback for the LLM, not an exception for the loop
- **The tool system provides the strongest guarantee** of the pairing invariant — as long as the LLM declares a tool_use, a tool_result is guaranteed to follow

The next chapter, [04 · From "Done Answering" to the 7 Meanings of stop_reason](04-stop-reason.md), covers the other end of the loop — after tool execution finishes and the tool_result is filled back in and the LLM is called again, when does the LLM count as "done talking"?

---

## References

**Primary file locations** (v2.1.220):
- `src/services/tools/toolOrchestration.ts` · main `runTools` flow · `runToolsSerially` / `runToolsConcurrently` batching
- `src/services/tools/toolOrchestration.ts` · `isConcurrencySafe` interface · `partitionToolCalls` batching logic
- `src/query.ts` · `StreamingToolExecutor` · tool pre-launch under streaming JSON parsing
- `src/services/tools/toolExecution.ts` · single tool execution · the wrapper that converts crashed exceptions into is_error tool_results

**Related chapters**:
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) · permission interception before tool execution
- [02 · Hooks · Programmable Intervention Points on the Loop](02-hooks.md) · hooks before and after tool execution
- [04 · From "Done Answering" to the 7 Meanings of stop_reason](04-stop-reason.md) · next chapter · how the loop decides to continue after tool execution
- [06 · Streaming · From SSE Events to Character-by-Character Display](06-streaming.md) · the complete mechanism of streaming JSON parsing
- [08 · Interrupt · From Ctrl-C to Synthesized tool_result](08-interrupt.md) · synthesizing an is_error tool_result on user interruption
- [02 · From a Single Message to the Three Invariants of the Message Array](https://diaozxin007.github.io/reading-claude-code/zh/context-management/02-message-invariants.html) · the definition of the pairing invariant

**Anthropic official docs**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) · the API contract for tool_use / tool_result
