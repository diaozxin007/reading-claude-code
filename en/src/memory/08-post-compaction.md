# 08 · After Compaction · Which Memories Come Back Automatically

> **TL;DR**: compaction doesn't "compress all persistent memory into a summary." It rebuilds the messages array, then reruns the `SessionStart(compact)` hooks to restore the startup context — while also preserving dedicated attachments like the plan, recent files, and invoked skills. auto memory, agent memory, and session memory are three different things: the first two span sessions, while session memory is a session-summary file that compaction can consume directly.

The previous article, [07 · Managed CLAUDE.md · The Enterprise Governance Layer](07-managed-claude-md.md), covered how admin directives must stay effective long-term. But the same session can also go through `/compact` or auto-compact: once the old messages get replaced by a summary, how does disk-based memory make its way back into the new messages array?

## First, tell the three "memories" apart

| Name | Carrier | Time scale | Relationship to compaction |
|---|---|---|---|
| auto memory | project memory directory + `MEMORY.md` | cross-session | a persistent source for startup context |
| agent memory | per-agent-type memory directory | across multiple agent spawns | loaded when constructing that agent's system prompt |
| session memory | the current session's structured summary file | single session / resume | can directly substitute for a traditional compact LLM summary |

Similar names don't mean shared implementation. `services/compact/sessionMemoryCompact.ts` operates on the third kind — it does not treat `~/.claude/projects/.../memory/MEMORY.md` as a compact summary.

## The output of compaction is not a single summary

The new message sequence is roughly assembled from five parts:

```text
compact boundary
→ compact summary
→ tail messages that must be preserved
→ attachments
→ SessionStart(compact) hook results
```

The source's `buildPostCompactMessages()` explicitly assembles things in this order. See `services/compact/compact.ts:302-335`.

This means resistance to compaction isn't a single mechanism. Different information comes back for different reasons:

- historical facts go into the summary;
- the latest interactions keep their original messages, so the summary doesn't swallow details that just happened;
- files, plan, skills, and background agent state travel via attachments;
- startup-level directives like CLAUDE.md travel via the compact session-start hooks.

## Why CLAUDE.md isn't left for the summary to remember

Both traditional compact and session-memory compact call:

```text
processSessionStartHooks('compact', ...)
```

See `services/compact/compact.ts:592`, `:981`, and `services/compact/sessionMemoryCompact.ts:583-586`.

By design, you can't ask the summarizing model to "casually remember all the project rules along the way." A summary is lossy; the rules file is the ground truth. Rerunning the startup hook is equivalent to fetching the current version fresh from disk — it also lets a user who edited CLAUDE.md mid-session have the post-compaction context pick up the new rules.

`postCompactCleanup` also clears the CLAUDE.md file-discovery cache, so subsequent loads aren't locked to stale scan results. See `services/compact/postCompactCleanup.ts:7-34`.

## The difference between root and nested

Root-level CLAUDE.md for a project belongs to the startup context, and is restored after compact via the session-start path. Nested CLAUDE.md, by contrast, is tied to file access: it only enters context lazily, when the corresponding subdirectory is actually read from or acted on.

So after compact, you can't assume every nested rule that was ever touched will automatically reappear. This difference isn't "unimportant" — it exists so that path-specific rules only occupy context when the related work is happening again.

```text
root CLAUDE.md   → session-lifetime scope   → restored on compact via the startup load
nested CLAUDE.md → path-access scope        → loaded again when the directory is entered again
```

## How auto memory comes back

auto memory's behavioral instructions live in the memory section of the system prompt; the `MEMORY.md` index content enters the session via the startup-context assembly. Once compaction rebuilds the session, this assembly chain reruns — it doesn't rely on the summary to recite every index entry.

The body of a topic file usually isn't injected in full. The index only offers a hook; the body is Read/Grep'd again when relevant. So having read a topic before compaction doesn't guarantee its body stays permanently in the new context — if the task still depends on it, the model needs to re-read it based on the index or the summary.

This is exactly the distinction between "persisted" and "resident in context":

- the file is still on disk = the memory isn't lost;
- the file's content is still in the messages = the current context still holds it resident.

## Session memory compact · substituting a ready-made summary for re-summarization

The experimental session-memory compaction path kicks in only when two feature gates are enabled simultaneously. It first waits for any in-progress session-memory extraction, then reads the session memory content; if there's no file, or it's still an empty template, it falls back to traditional compact. See `services/compact/sessionMemoryCompact.ts:400-431,514-543`.

When content exists, it looks for `lastSummarizedMessageId` and computes which tail messages after that ID should be kept. Choosing the boundary must simultaneously satisfy:

- a minimum retention of tokens and text messages;
- a maximum token cap;
- never cutting a tool_use / tool_result pair apart;
- never splitting thinking / tool_use streamed fragments that share the same API `message.id`.

See `services/compact/sessionMemoryCompact.ts:188-397`.

The session memory is then wrapped as a compact user summary. Overly long sections get truncated, with the full session memory file path attached. See `services/compact/sessionMemoryCompact.ts:434-502`.

The value of this path is: **when a usable summary is already being maintained in the background, compact doesn't need to make another dedicated summarization API call.** But if the boundary ID can't be found, the content is empty, the compacted result still exceeds the auto-compact threshold, or an error occurs, it falls back entirely to legacy compact. See `services/compact/sessionMemoryCompact.ts:545-629`.

## The message invariants remain the bottom line

When keeping tail messages from history, the most dangerous outcome is leaving a tool_result behind while cutting its corresponding tool_use. session-memory compact collects the IDs of every tool_result in the retained region, then scans backward for the missing assistant tool_use — and also pulls in any thinking fragment sharing the same `message.id` further back. See `services/compact/sessionMemoryCompact.ts:188-314`.

So memory can't route around the message protocol. However complete the summary is, the new messages must still satisfy [02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md).

## What doesn't come back automatically

- the full body of every topic ever read — needs to be retained by the summary or retrieved again;
- every nested CLAUDE.md — needs the corresponding path to be touched again;
- everything on the application side of the memory tool's `/memories/*` — the protocol layer requires calling `view` again;
- a sub-agent's full private context — the main thread only receives its result/status;
- any disk memory already mis-written or deleted by the model — compaction provides no version recovery.

## Decisions · Anti-patterns · Evolution signals

### Decisions

- the summary preserves historical facts; hooks/attachments restore state from the authoritative source.
- root directives come back automatically; nested rules come back lazily by path.
- session memory is used directly as the summary when reusable, and falls back unconditionally to traditional compact on failure.
- the tail-retention algorithm maintains API invariants first, and only then optimizes for tokens.

### Anti-patterns

- treating auto `MEMORY.md` and session memory as the same file.
- assuming "still on disk" is equivalent to "the model has currently read the body."
- letting the compact summary serve as the sole copy of a rules file.
- slicing tail messages directly to save tokens, cutting a tool pair apart.

### Evolution signals

- rules getting violated frequently after compact → something's wrong with the session-start restore chain or the CLAUDE.md cache reset.
- the model repeatedly re-reading large topic bodies → the index hook is too weak, or the topic granularity is off.
- session-memory compact falling back often → summary extraction, the boundary cursor, or the threshold configuration is unstable.
- nested rules frequently getting forgotten → the rule is actually project-wide, and should be promoted to root/rules rather than left in the path-lazy layer.

## Summary

Compaction isn't "compressing the old brain into a new brain" in one shot — it's a **state rebuild**. The summary only handles historical compression; CLAUDE.md, memory indexes, plan, files, skills, and the rest each come back from their own authoritative carrier. The most important takeaway: cross-session memory, agent memory, and session memory sound similar, but their lifecycles and responsibilities are entirely different.

The next article, [09 · Conclusion · From One Piece of Information to Five Memory Carriers](09-conclusion.md), pulls the whole series together into a single decision tree: given a piece of information worth keeping, should it go into CLAUDE.md, auto memory, agent memory, team memory — or just stay in the current context.

## References

- Claude Code source: `services/compact/compact.ts:302-335,527-616,981-1090`
- Claude Code source: `services/compact/sessionMemoryCompact.ts:188-397,400-629`
- Claude Code source: `services/compact/postCompactCleanup.ts:7-34`
- Claude Code source: `utils/sessionStart.ts`
- Claude Code source: `utils/claudemd.ts`
- Sister chapter: [04 · The Six Siblings of Compaction — From Manual to Everywhere](../context-management/04-compaction.md)
