# 02 · Auto Memory · From One Correction to MEMORY.md

> **TL;DR**: Auto memory isn't about stuffing a whole chat transcript into one file. Claude Code splits persistent memory into two layers: `MEMORY.md` is a short index only, while the actual content lives in topic files with frontmatter. The main agent can write on the spot; if it doesn't, there's still a bounded fork subagent that fills the gap at the end of every complete query loop. The two write paths are made mutually exclusive by a cursor plus a write-detection check, so it's never two agents fighting over the same file at once.

The previous article, [01 · The CLAUDE.md Family: 5-Layer Hierarchy and 3 Mixing Patterns](01-claude-md-family.md), covered long-lived instructions the user actively writes for Claude. This article flips the question: when the user hasn't maintained a rules file, how does Claude carry a single correction forward into the next session?

## Drawing the Boundary First: MEMORY.md Is Not CLAUDE.md

| | CLAUDE.md | Auto memory |
|---|---|---|
| Source of information | Explicitly stated by the user, team, or admin | Extracted by Claude from the collaboration |
| Typical content | Commands, constraints, project conventions | User preferences, corrections, project context, external pointers |
| Write responsibility | Maintained by a human | Written proactively by the main agent + backfilled by an extraction agent |
| File shape | Hierarchical instruction files | `MEMORY.md` index + topic files |
| Distortion risk | Rules go stale | Model mis-extracts, duplicates, or memory drifts |

This boundary explains why the source code explicitly excludes code structure, architecture, git history, and file layout: that information can be re-read at any time, so it's not worth occupying persistent memory. What auto memory preserves is information that **cannot be derived from the current project state** but remains useful for future collaboration. The four permitted types are `user`, `feedback`, `project`, and `reference`. See `memdir/memoryTypes.ts:4-19`.

## Two-Layer File Structure: The Index Isn't the Body

The default directory is derived from the canonicalized git root:

```text
~/.claude/projects/<sanitized-git-root>/memory/
├── MEMORY.md
├── feedback-testing.md
├── user-role.md
└── project-release-context.md
```

`MEMORY.md` isn't a running log — it's an entry point, one link per line:

```markdown
- [Testing policy](feedback-testing.md) — integration tests use a real database
```

The actual content lives in topic files, each carrying `name`, `description`, and `type` frontmatter. That way session startup only needs to load a very short routing table; when details are needed, the topic file gets Read or searched. The source prompt explicitly requires each index entry to stay under roughly 150 characters, and warns that anything past 200 lines gets truncated. See `memdir/memdir.ts:219-233` and `services/extractMemories/prompts.ts:68-81`.

There's a number here that's easy to conflate:

- `MEMORY.md`'s context entries are bounded by line count and byte budget;
- a topic-file scan returns at most 200 files, reading only the first 30 lines of frontmatter from each, sorted by modification time descending.

The latter is a cap on the retrieval listing, not a statement that the whole memory directory can only ever hold 200 files. See `memdir/memoryScan.ts:21-73`.

## Why the Path Is Bound to the Canonical Git Root

`getAutoMemBase()` prefers the canonical git root, falling back to the project root only when there's no git. As a result, subdirectories and worktrees of the same repo all map onto the same auto-memory directory. See `memdir/paths.ts:198-232`.

This is a deliberate product choice: a worktree is a parallel working copy of the same project, and project context or user feedback shouldn't fragment just because the checkout location differs. But it also means different worktrees read and write the same batch of memories, so short-lived branch progress doesn't belong in auto memory — that's better suited to a task, a plan, or in-session messages.

The path can be overridden via `autoMemoryDirectory` from a trusted settings source. Project settings inside the repo itself are deliberately excluded — otherwise a malicious repo could redirect the directory to a sensitive location like `~/.ssh` and exploit memory's write-permission exemption. The source only accepts policy, flag, local, and user settings sources, and rejects relative paths, root directories, UNC paths, null bytes, and other dangerous inputs. See `memdir/paths.ts:95-185`.

## Who Writes: the Main Agent Writes First, a Background Agent Backfills

Auto memory has two production paths.

### Path One: the Main Agent Writes on the Spot

The main prompt itself contains the full memory classification and saving instructions. When the user explicitly says "remember this," the main agent doesn't need to wait for the session to exit — it can write the topic file and update the index directly.

### Path Two: Extraction Backfills After a Complete Turn

When the main agent hasn't written anything, `handleStopHooks` launches `extractMemories` fire-and-forget once the main thread finishes a final reply with no tool calls. It doesn't run only "when the terminal exits" — it has a chance to run at **the end of every complete query loop**. In `--print` mode, once output has been flushed, the process waits for any pending extraction so it doesn't get killed by process exit. See `query/stopHooks.ts:133-153` and `cli/print.ts:959-969`.

The extraction agent is a perfect fork of the main session: it inherits the same system prompt, tool declarations, and message prefix, so it reuses the prompt cache; a dedicated instruction — "analyze the most recent N messages" — is then appended at the tail. See `services/extractMemories/extractMemories.ts:1-13` and `services/extractMemories/prompts.ts:1-9`.

## Why It Doesn't Write Duplicates

The extractor maintains a `lastMemoryMessageUuid` cursor, and each run only looks at new messages after that cursor. Before starting, it also scans that range for assistant `tool_use` calls: if it finds an Edit or Write targeting the auto-memory directory, that means the main agent has already completed a memory write, so the background extractor skips and advances the cursor to the latest message anyway.

```text
Turn ends
  ├─ Main agent already wrote memory → skip extraction · advance cursor
  └─ Main agent didn't write memory  → fork extraction · advance cursor on success
```

This isn't a simple time-based debounce — the mutual-exclusion condition is "did a memory write happen in this message range." If extraction fails, the cursor doesn't advance, and the same batch of messages is reconsidered next time. See `services/extractMemories/extractMemories.ts:112-148,345-359,429-435`.

## Four Memory Types: What Gets Saved Is What Can't Be Derived

| Type | Good to save | Should not save |
|---|---|---|
| `user` | Role, experience level, explanation preferences | Negative judgments about the user, work-irrelevant profiling |
| `feedback` | User corrections and confirmed ways of collaborating | Ad-hoc instructions valid for only the current step |
| `project` | Deadlines, incident context, cross-system motivations | Structure that's directly visible from code or git |
| `reference` | Pointers to external locations like Linear, Grafana, Slack | Copying an entire external system's content in |

`feedback` specifically captures both failures and successes. If it only records corrections, the agent gradually becomes over-cautious; recording the user's confirmation of a non-obvious approach is what preserves judgment that's already been validated. When team memory is enabled, the type also drives scope routing: user profiles are always private, project strongly leans toward team, and feedback only goes to team when it's clearly a project-wide convention. See `memdir/memoryTypes.ts:37-106`.

## The Switch Isn't a Single Boolean

The priority chain for `isAutoMemoryEnabled()` is:

1. the `CLAUDE_CODE_DISABLE_AUTO_MEMORY` environment variable;
2. `--bare` / `CLAUDE_CODE_SIMPLE`;
3. whether remote mode provides a persistent memory directory;
4. the `autoMemoryEnabled` setting;
5. on by default.

Explicitly setting the environment variable to a falsy value can re-enable it — it's not simply "the variable existing means disabled." The extraction agent also has its own separate feature gate plus interactive/non-interactive gates, so "auto memory is enabled" and "the background extractor is guaranteed to run this turn" are not the same statement. See `memdir/paths.ts:21-76`.

## Decisions · Anti-Patterns · Evolution Signals

### Decisions

- Use `MEMORY.md` as an index and topic files as the body, decoupling startup cost from memory capacity.
- The main agent handles immediate, explicit memory; a background fork backfills; the two are made mutually exclusive by write detection.
- The canonical git root lets worktrees share long-term context, avoiding multiple memory silos for the same project.

### Anti-Patterns

- Turning `MEMORY.md` into a running log — the 200-line budget gets exhausted fast.
- Saving code structure or git-derivable facts — memory goes stale while the source code is the actual ground truth.
- Writing the current session's execution steps into memory — task and plan are the right carriers for short-term working state.
- Allowing an arbitrary `autoMemoryDirectory` in project settings — that turns repo configuration into a silent write-permission escalation.

### Evolution Signals

- The index approaches 200 lines → merge duplicate topics and shorten entries, rather than keep piling on body content.
- The same feedback gets added repeatedly → the frontmatter description or dedup strategy isn't retrievable enough.
- Cross-contamination shows up between worktrees → short-lived branch state got saved and should move back to task/session.
- The main agent and the extraction agent produce near-identical content → check whether write-path detection or cursor advancement is broken.

## Summary

The core of auto memory isn't "automatically writing Markdown" — it's a bounded pipeline of accumulation: **non-derivable information → four-way classification → topic file → MEMORY.md routing → recalled on demand in the next session.** It layers the main agent's proactiveness on top of a background agent's backfilling capability, and keeps the whole thing from spiraling out of control using path permissions, write detection, and a cursor.

The next article, [03 · The Anthropic API Memory Tool: the memory_20250818 Client-Side Memory Primitive](03-api-memory-tool.md), moves to the protocol layer: why the memory tool that the Anthropic API offers to applications and this auto-memory setup in Claude Code are two entirely separate implementations.

## References

- Claude Code source: `memdir/paths.ts:21-278`
- Claude Code source: `memdir/memdir.ts:187-315,409-506`
- Claude Code source: `memdir/memoryTypes.ts:4-106`
- Claude Code source: `memdir/memoryScan.ts:21-93`
- Claude Code source: `services/extractMemories/extractMemories.ts:1-13,112-148,329-586`
- Claude Code source: `services/extractMemories/prompts.ts:29-153`
- Claude Code source: `query/stopHooks.ts:133-153`
- Claude Code source: `cli/print.ts:959-969`
- Claude Code official docs: [Manage Claude's memory](https://code.claude.com/docs/en/memory)
