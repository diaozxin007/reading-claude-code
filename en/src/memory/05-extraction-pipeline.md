# 05 · Memory Extraction Pipeline: From End-of-Turn to a Restricted Fork

> **TL;DR**: `extractMemories` is a background fork that may launch at the end of every complete main turn. It inherits the main session's stable prefix to hit the prompt cache, but its permissions are narrowed to reads, read-only shell, and writes within the memory directory only — capped at 5 turns. A cursor ensures only newly added messages are processed; write detection avoids duplicating the main agent's work; trailing runs merge concurrent triggers; and on failure the cursor is held back to wait for the next compensating run.

The previous article, [04 · Sub-agent Memory: From Agent Type to a Three-Tier Persistent Directory](04-subagent-memory.md), covered how a specialized agent preserves experience across runs. This article dissects a specific sub-agent: `extractMemories`. It isn't an agent the user explicitly creates — it's a background clerk the harness dispatches at the end of a main turn.

## The Trigger Point: Not "Extraction on Exit"

The source comments give a precise definition: when the model produces a final response with no tool call — i.e. a complete query loop has ended — `handleStopHooks` kicks off extraction. The main thread doesn't wait on it; the interactive response is never blocked by memory extraction. See `services/extractMemories/extractMemories.ts:1-13` and `query/stopHooks.ts:141-153`.

It also has to pass through several gates:

- Only runs on the main agent — a sub-agent's stop hook never triggers it
- auto memory must be enabled
- remote mode skips it
- both the `EXTRACT_MEMORIES` build feature and the runtime gate must be on
- `--bare` skips background bookkeeping
- available frequency is controlled by a remote value, defaulting to once per eligible turn

See `services/extractMemories/extractMemories.ts:374-386,527-566`.

So "end of every turn" is a candidate opportunity, not an unconditional guarantee.

## Perfect Fork: Why Not Start from a Blank Agent

The extraction agent needs to understand "of everything in this recent conversation, what's worth keeping long-term." If you hand only the last few lines to a fresh agent, it loses the user's role, the project background, and the lead-up to whatever correction just happened. The source picks `runForkedAgent`: the system prompt, tool schemas, and history-message prefix are aligned with the parent, and only the extraction prompt is appended at the tail.

This also solves a cost problem. An identical request prefix can hit the parent's prompt cache; if the fork were given a different tool declaration set for safety, a change to the tools segment would break the cache prematurely. So the code keeps declarations like the REPL, then intercepts actual actions one by one at the `canUseTool` layer. See `services/extractMemories/extractMemories.ts:171-180,371-427`.

## The Permission Cage: Able to Understand History, Not to Keep Working

The extractor is permitted to:

- Read / Grep / Glob
- run shell commands that BashTool judges to be read-only
- Edit / Write, but only within the auto-memory directory
- use the REPL shell — though its internal primitives still go through the same permission check every time

It is denied Agent, MCP, writable Bash, and any file modification outside the memory directory. The prompt also explicitly instructs it not to grep the source code, not to run git, and not to verify conversation content — it should extract only from the most recent N messages. See `services/extractMemories/extractMemories.ts:150-221` and `services/extractMemories/prompts.ts:29-43`.

This is a textbook "keep declarations cache-safe, close off execution permissions separately" design.

## The Ideal Two-Turn Path — Capped at Five

Before launch, the harness has already scanned the memory directory and produced a manifest:

```text
- [feedback] feedback-testing.md (timestamp): real database policy
- [user] user-role.md (timestamp): senior backend engineer
```

So the agent doesn't need to `ls` first. The prompt's recommended ideal rhythm is:

1. Read all files that might need updating, in parallel
2. Edit / Write, in parallel

A normal extraction is expected to take 2–4 turns, with a hard ceiling of 5. Edit requires reading the same file first, so this scheduling satisfies both the file-state constraint and the turn budget at once. See `services/extractMemories/prompts.ts:29-43` and `services/extractMemories/extractMemories.ts:395-427`.

## The Cursor: Every Message Falls Into Exactly One Extraction Window

A closure holds `lastMemoryMessageUuid`. Each run counts the model-visible user/assistant messages after the cursor; progress, system, and attachment messages don't count. If compaction has already trimmed away the message the cursor points to, the counter falls back to all currently visible messages, rather than returning 0 and stalling permanently. See `services/extractMemories/extractMemories.ts:74-110`.

The cursor advances only on success. If the fork errors out, the cursor stays where it was, so the next run can reprocess the same window. This turns failure into an at-least-once retry; the resulting duplication risk is mitigated by the manifest and by the prompt's constraint to prefer updating existing files.

## Mutual Exclusion With the Main Agent

If the main agent has already issued an Edit/Write against an auto-memory path this turn, the background agent simply skips and advances the cursor. Note that what's being detected is the assistant's `tool_use`, not a filesystem watcher guessing at the outcome of a write. See `services/extractMemories/extractMemories.ts:112-148,345-359`.

This forms a clear priority order:

```text
Main agent's explicit memory > background extraction filling the gaps
```

When the user explicitly asks to be remembered, there's no need to wait for the background pass; the background agent is only responsible for catching what the main agent missed.

## Concurrent Triggers: Only the Latest Snapshot Is Kept

If the previous extraction run hasn't finished and a new one is already complete, the source code doesn't spin up a second writer in parallel. It stashes the latest context into `pendingContext`; a later trigger overwrites an earlier pending one, since the newer context already includes more messages. Once the current extraction finishes, a `finally` block immediately runs one trailing extraction.

The trailing run skips the frequency throttle, and processes only the new window based on the cursor that was just advanced. See `services/extractMemories/extractMemories.ts:312-325,503-520,554-566`.

This is a single-flight-plus-latest-wins merge pattern:

```text
run A in progress
  B arrives → stash B
  C arrives → C overwrites B
run A completes
  → run one trailing run from A's new cursor to the end of C
```

B isn't lost — it's already contained within C's full context.

## What Happens Back on the Main UI After Writing

The fork's transcript is never persisted to disk, so background messages don't compete with the main thread's transcript. Once the run finishes, the harness extracts Edit/Write paths from the assistant's `tool_use` calls, filters out mechanical updates to `MEMORY.md`, and counts only topic files as memories actually saved. If there are results, it builds a memory-saved system message and hands it to `appendSystemMessage`; when team memory is enabled, it also carries a team count. See `services/extractMemories/extractMemories.ts:415-496`.

So the main agent never ingests the fork's entire conversation — it only receives a small meta-event about which memory files were saved.

## Why Non-Interactive Mode Has to Drain

An interactive TUI can let the background task keep running; a one-shot `--print` invocation exits the process right after producing output. The print path writes the final answer to stdout first, then calls `drainPendingExtraction()` to wait on the in-flight promise, and only then performs a graceful shutdown. By default, draining waits up to 60 seconds. See `services/extractMemories/extractMemories.ts:579-586` and `cli/print.ts:959-969`.

This achieves a subtle property: memory extraction can delay process exit, without adding to the latency before the user sees their answer.

## Decisions, Anti-Patterns, and Evolution Signals

### Decisions

- The perfect fork preserves the history needed for understanding while reusing the cache.
- Tool declarations stay unchanged; execution permissions are narrowed via `canUseTool`.
- The cursor advances only on success — failure doesn't advance it — trading for compensability.
- Single-flight plus latest-wins avoids two background agents writing to the same directory concurrently.

### Anti-Patterns

- Putting extraction on the critical path of the main response — users would have to wait for extraction to finish every turn.
- Giving the fork a smaller tool schema — safety looks more intuitive this way, but it breaks the shared cache prefix.
- Allowing the extraction agent to verify code and git state — it would burn turns on facts that are already derivable.
- Advancing the cursor even on failure — a single transient error would permanently lose candidate memories.

### Evolution Signals

- Frequently hitting the 5-turn cap → the manifest isn't sufficient, topics are too fragmented, or the prompt permits too much investigation.
- Trailing runs staying persistently frequent → extraction is taking longer than the pace of user interaction, and scan/write costs should be reduced.
- Persistently low cache hit rate → the fork's parameters or stable prefix have drifted from the parent's.
- An extremely low "no memories saved" ratio → extraction criteria are too loose, and the memory directory will quickly become noisy.

## Summary

The memory extraction pipeline is a miniature agent loop, but its autonomy is precisely bounded: it can understand the full history, but can only operate on the memory directory; it processes only the new window; it must not investigate derivable facts; and it's capped at five turns. It demonstrates that "background agent" doesn't mean turning a second Claude loose to work freely — reliability comes from five boundaries holding simultaneously: trigger, permission, cursor, concurrency, and backfill.

The next article, [06 · Team Memory Sync: From Two Local Directories to Server-Side Sync](06-team-memory-sync.md), continues down the pipeline after persistence: once a memory is judged to be team-scoped, how does it sync from the local directory to other organization members on the same GitHub repository.

## References

- Claude Code source: `services/extractMemories/extractMemories.ts:1-13,74-221,271-586`
- Claude Code source: `services/extractMemories/prompts.ts:1-153`
- Claude Code source: `memdir/memoryScan.ts:21-93`
- Claude Code source: `query/stopHooks.ts:133-157`
- Claude Code source: `cli/print.ts:959-969`
- Sister article: [03 · Prompt Cache Is the Skeleton — Why Everything Else Is Shaped the Way It Is](../context-management/03-prompt-cache.md)
