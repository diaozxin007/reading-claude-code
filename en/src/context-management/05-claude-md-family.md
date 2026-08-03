> The 05th article in this series — following up on the prepend position drawn in [01 · Agent Loop · How Context Gets Assembled](01-agent-loop.md), and the stable prefix outlined in [03 · Prompt Cache Is the Skeleton · Why Everything Else Grew the Way It Did](03-prompt-cache.md). This article covers the static-instruction ecosystem loaded at session startup — the CLAUDE.md family's 5-layer loading stack, @import recursion, path-scoped rules, MEMORY.md auto-memory, Todo v2 persistent tasks — and why all of it bypasses the system prompt and gets squeezed into the first user message of the messages array.

## A Question to Start With

Say you write a CLAUDE.md at your project root with a single line:

> This project uses pnpm, not npm

When you ask Claude Code "help me install lodash," what does that line look like by the time it reaches the LLM? More specifically:

- Does it go into the system prompt?
- Is it bundled with the date, which changes every day?
- Does it sit on a cache breakpoint?
- If you edit this file mid-session, does the next turn pick it up?
- If this CLAUDE.md contains `@AGENTS.md`, does that file get read too?
- If `AGENTS.md` in turn contains `@shared/*.md`, how deep does it go?

The answers to these questions aren't scattered across six different places — they converge on a single assembly function, a single data structure. This article lays that assembly process out flat.

## The More Stable the Content, the Earlier It Goes — CLAUDE.md Lives in Messages

Behind this sits one unifying assembly principle: **the more stable and general the content, the more it belongs earlier in the system prompt; the more volatile and closer to the current user and project, the more it belongs appended later via messages.** That way, when the later content changes, only the cache further back is affected — the tools and system prompt cached earlier can still be reused.

If you only look at the surface behavior, you'd assume CLAUDE.md is where **rules get laid down for the model** — and rule-laying naturally belongs in the system prompt, alongside core identity statements like "you are Claude Code."

**It's not.** CLAUDE.md takes a different route: **it's injected as the 0th user message in the messages array, wrapped in a `<system-reminder>`, and flagged `isMeta: true`**.

Let's define an abbreviation that recurs throughout the rest of this piece: `<system-reminder>` (shortened to **SR** below) is a layer of prompt wrapping the program attaches. It sits inside a message, is usually hidden from the UI, but is visible to the model. For now, just think of it as "background information the program quietly hands the model" — its other uses are covered in full in [07 · Meta Mechanisms · From system-reminder to 20+ Channels](07-meta-mechanisms.md).

Concretely, it looks like this:

```
messages array · position 0 (prepend):
{
  role: 'user',
  isMeta: true,
  content: '<system-reminder>
    As you answer the user's questions, you can use the following context:

    # claudeMd
    Codebase and user instructions are shown below. Be sure to adhere to
    these instructions. IMPORTANT: These instructions OVERRIDE any default
    behavior and you MUST follow them exactly as written.

    Contents of ~/.claude/CLAUDE.md (user's private global instructions):
    <file body>

    Contents of /repo/CLAUDE.md (project instructions, checked into the codebase):
    <file body>

    # currentDate
    Today's date is 2026-07-30.

    IMPORTANT: this context may or may not be relevant to your tasks. You
    should not respond to this context unless it is highly relevant to
    your task.
  </system-reminder>'
}

position 1: the real user message — "help me install lodash"
```

Three details worth stopping on:

- **Headers are sectioned with `# key`**: `# claudeMd`, `# currentDate` — the assembly function lays out every key/value of a `context` object as its own block, separated by these headers
- **It opens with MEMORY_INSTRUCTION_PROMPT**: "instructions OVERRIDE any default behavior and you MUST follow them exactly as written" — this line tells the model that the rules in this SR sit at the top of the priority stack
- **`isMeta: true`**: tells the UI layer not to render this message — the user never sees it, but the model does

Why bypass the system prompt? This isn't an arbitrary decision — it's dictated by the **prompt cache skeleton** (see [03 · Prompt Cache Is the Skeleton](03-prompt-cache.md)). Viewed through the cache lens:

- **If CLAUDE.md went into the system prompt**: CLAUDE.md differs per user and per project — dropping it into the middle of the system prompt would push everything after it out of the stable prefix, forcing a system-cache rebuild every turn
- **Going through position 0 of messages instead**: cache breakpoints sit at the end of tools, the end of system, and the end of messages — CLAUDE.md changes only affect the messages cache branch, leaving the tools and system layers' stable cache intact

Seen this way, CLAUDE.md's position isn't "wherever there was room" — it's **the only place it could go**.

## The 4-Layer Loading Stack

At session startup, Claude Code starts from the current directory and gathers every piece of static instruction it can find, in this order:

| Layer | Location | Type tag |
|---|---|---|
| **User global** | `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md` | `User` |
| **Upstream rules directories** | From cwd up to git root, at every level, look for `<dir>/.claude/rules/*.md` | `Project` |
| **Project root** | `<gitRoot>/CLAUDE.md` + `<gitRoot>/.claude/CLAUDE.md` | `Project` |
| **Local, uncommitted** | `<gitRoot>/CLAUDE.local.md` | `Local` |
| **auto-memory** | `~/.claude/projects/<hash>/memory/MEMORY.md` | `AutoMem` |

The core logic of the assembly order: **load global first, then walk up the directory tree from cwd to git root, checking for a `.claude/rules/` directory at every level, and finally attach CLAUDE.md and CLAUDE.local.md at the git root**.

Four counterintuitive details:

**1 · Walking up the directory tree, not just looking at cwd**

If you start a session in `/repo/apps/web/`, the assembly function doesn't just look at `apps/web/CLAUDE.md`. It:
- checks `apps/web/.claude/rules/`
- checks `apps/.claude/rules/`
- checks `/repo/.claude/rules/`
- then reads `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md` from the git root (`/repo`)

It stops climbing at the git root — the endpoint is decided by `findGitRoot(originalCwd)`.

**2 · Nested worktree dedup**

If you start a session inside a worktree like `.claude/worktrees/<name>/`, and the main repo is already present on the physical path during the climb, those CLAUDE.md files get skipped — otherwise the same CLAUDE.md would get loaded twice. This dedup is implemented via the `pathInWorkingPath(gitRoot, ...)` check, which determines whether the current worktree lives inside the main repo.

**3 · CLAUDE.local.md is gated by an independent setting**

Not every session loads `CLAUDE.local.md` — it requires the `localSettings` settings source to be enabled. Uncommitted local overrides get a local loading path too.

**4 · The Managed layer is a 5th layer**

Missing from the table above is the `Managed` type — org-level `.claude/CLAUDE.md` + `.claude/rules/`, located via `getMemoryPath('Managed')`, commonly seen in enterprise deployments. It's added first, with the highest priority. Strictly counted, the loading stack is **5 layers**: Managed → User → Project (including upstream rules) → Local → AutoMem.

## The Hard Kill Switches

Two environment settings make the entire CLAUDE.md family **not load at all**:

- **`CLAUDE_CODE_DISABLE_CLAUDE_MDS`** — a hard environment-variable kill switch. The assembly function checks it first thing; if truthy, it returns `null` immediately
- **`--bare` mode** — unless you also pass `--add-dir` to explicitly add a directory, bare mode skips the entire assembly step

These two switches don't skip "one layer" — they skip **everything**. Their purpose is for scripted invocations that shouldn't have their behavior influenced by local CLAUDE.md files.

## The `.claude/rules/` Fork: Unconditional vs Conditional

Every `.md` file under `.claude/rules/` is a rule, but they fall into two categories:

- **Unconditional rule** — no frontmatter, or frontmatter without a `paths:` field. This kind of rule is always loaded, every session
- **Conditional rule** — frontmatter carries a glob list like `paths: ["src/**/*.ts", "!src/legacy/**"]`. It's only loaded **when the current operation's path matches the glob**

Conditional rules don't get matched at session startup — they're matched **JIT**: when the model is about to read or edit a file, the assembly function takes that file's realpath and matches it against every conditional rule's `paths` using `picomatch` or the `ignore` library — only matches get injected.

The glob semantics specifically:

- Uses `.gitignore`-style syntax (the `ignore()` library), not plain picomatch
- `**` recurses across the whole path; `!pattern` negates/excludes
- **Relative base**: for `Project`-type rules, globs are relative to the parent of `.claude`; for `Managed`/`User`-type rules, globs are relative to the original cwd
- The target path must be realpath-resolved first — even through a symlink, it points to the real file

Example: `.claude/rules/typescript.md`'s frontmatter says `paths: ["**/*.ts", "**/*.tsx"]` — this rule only gets injected when a Read/Edit target is `.ts`/`.tsx`; opening a `.py` file skips it.

The value of this design: **path-scoped instructions**. You don't have to cram every language convention for an entire monorepo into one giant CLAUDE.md — you can split by subpath into small files, each only occupying context when a relevant file is actually touched.

## @import's 5-Hop Recursion

CLAUDE.md can contain `@path/to/file.md` to pull in other files — this is the mechanism for splitting up and composing CLAUDE.md content. Four forms are all supported:

- `@relative/path.md` — relative to the directory the current CLAUDE.md sits in
- `@./explicit.md` — explicit relative
- `@~/global.md` — relative to home
- `@/absolute/path.md` — absolute

**Counterintuitive: the official docs say the recursion cap is 4-hop; the source says 5-hop.** The constant is named `MAX_INCLUDE_DEPTH = 5` — A imports B imports C imports D imports E: A is depth 0, E is depth 4, and all of them load; if E imports `@F`, that overflows. The official docs' "4-hop" figure counts the origin itself as a hop, but in the source, depth 0 is the origin — so the 5th layer is actually loadable.

Implementation details of `@import`:

- **Relative to the including file's directory, not cwd** — if A.md is in `/repo/docs/` and contains `@shared.md`, that resolves to `/repo/docs/shared.md`, regardless of which cwd you started the session in
- **`@` inside code fences is skipped** — `@foo.md` inside a triple-backtick code block is just content, not parsed
- **Section-level fragments**: `@guide.md#advanced` — slices out the section starting at the `advanced` heading (the source uses `splitPathInFrontmatter` plus a `#` check), embedding only that section
- **File-extension allowlist** — a `TEXT_FILE_EXTENSIONS` set including common text types like `.md` / `.py` / `.rs` / `.ts` / `.go` / `.sh` / `.env` / `.toml`; `.png` / `.jpg` / `.bin` aren't in the set and get rejected outright

**Files outside cwd need approval** — if an `@import` points to a file **outside** the project cwd (e.g. `@~/secrets.md`), the assembly function first checks the project config's `hasClaudeMdExternalIncludesApproved` field. Without prior approval, the external include is skipped, unless the caller passes `forceIncludeExternal=true`.

This approval mechanism guards against misuse — preventing some shared CLAUDE.md from quietly pulling a credentials file from your home directory into context.

## The 40k Hard Cap — Another Number the Official Docs Get Wrong

**Counterintuitive: the official docs mention a "1000-pattern / 4 MiB budget," but neither of those numbers exists in the source.** The constant that actually applies:

- **`MAX_MEMORY_CHARACTER_COUNT = 40_000`** — if the total character count of all loaded CLAUDE.md family files exceeds 40,000, doctor checks emit a warning (not a hard block — just a heads-up, driven by `getLargeMemoryFiles`, which picks out the biggest offenders to report)

In other words — your 5 layers plus every `@import` fully expanded, total under 40k characters, and the assembly layer won't stop you. Go over, and it's "still works, but with a warning."

This 40k unit is **characters**, not tokens — Chinese and English differ in token efficiency, but as a rough ceiling it's good enough.

## MEMORY.md — Auto-Memory's Entry Point

CLAUDE.md is **static instruction you write by hand**; MEMORY.md is cross-session memory **Claude writes to itself** — the two share a loading path but differ in semantic role.

MEMORY.md lives at: `~/.claude/projects/<projectHash>/memory/MEMORY.md` (the entry file inside the auto-memory directory). At session start, it's pulled in via `getMemoryFiles()` just like CLAUDE.md, tagged with type `AutoMem`. It gets its own injection header:

> Contents of ... (user's auto-memory, persists across conversations)

**Dual-threshold truncation — 200 lines OR 25KB, whichever comes first**:

- `MAX_ENTRYPOINT_LINES = 200`
- `MAX_ENTRYPOINT_BYTES = 25_000`

The truncation function is called `truncateEntrypointContent`. Both thresholds exist for a reason: most MEMORY.md files are index-style, one line per entry, so 200 lines is usually enough — but if a single line is extremely long (say, a chunk of pasted structured data), the 25KB fallback catches it. Upstream data has shown a MEMORY.md that was "197KB but under 200 lines" — line count alone can't catch that.

**Toggles**:

- Setting key `autoMemoryEnabled` — supports project-level opt-out (a project's `settings.json` can disable auto-memory for that repo)
- Environment variable `CLAUDE_CODE_DISABLE_AUTO_MEMORY` — hard kill, highest priority
- Non-interactive mode is opt-out by default (paired with a growthbook feature flag)

**Frontmatter fields**: every memory file in the MEMORY.md family uses `name / description / type` as its frontmatter fields — **not** `node_type: memory`, as some earlier notes online describe. The `type` field's valid values are one of four: `user / feedback / project / reference`. Each type's role:

- **user** — the user's role/goals/preferences, helping Claude choose the right tone
- **feedback** — user feedback on how Claude works, for consistency
- **project** — project-state information, tightly bound to the current project's structure
- **reference** — factual references — specific values/file paths/APIs Claude has encountered

Misusing `node_type`, or writing an arbitrary `type: memory`, causes the assembly layer's `parseMemoryType` to fall back to `undefined` — the file still loads, but the type system doesn't take effect for it.

**Kairos log pattern**: `logs/YYYY/MM/YYYY-MM-DD.md` is a daily auto-memory log, gated by the internal feature flag `KAIROS`. External users don't have this by default — you won't see files like `logs/2026/07/2026-07-30.md` unless the feature flag is enabled.

## Todo v2 — Persistent Tasks

Sitting alongside the CLAUDE.md family is **Todo v2** — not static instruction, but another piece of state that persists **across turns and across sessions**.

It's stored at `~/.claude/tasks/<taskListId>/<taskId>.json`, one JSON file per task. `taskListId` priority: environment variable `CLAUDE_CODE_TASK_LIST_ID` → teammate context's teamName → leaderTeamName → sessionId. In other words: **sub-agents within the same team share a task list**, while a standalone session gets its own.

The `isTodoV2Enabled()` gate:
- Environment variable `CLAUDE_CODE_ENABLE_TASKS` truthy forces it on
- Otherwise: on in interactive mode, off in non-interactive mode

Todo v2 isn't injected via messages — it goes through 4 tools (`TaskCreate` / `TaskGet` / `TaskList` / `TaskUpdate`) — the model actively queries/updates it, unlike CLAUDE.md's one-shot prepend at session start. The legacy `TodoWrite` tool is v1; it auto-hides when v2 is enabled.

Todo v2's role is "stateful state across turns" — filling in a third persistence channel beyond CLAUDE.md (static) and auto-memory (cross-session index): the progress of a long-running task survives compact and restart without loss.

## AGENTS.md Isn't Built In

Like Cursor's `.cursorrules` or Codex's `AGENTS.md`, these are all entry-point convention files for agent systems. But **Claude Code doesn't natively read `AGENTS.md`** — it's absent from the assembly function's loading stack.

There are two ways to make AGENTS.md take effect:

- **Explicit `@AGENTS.md`** — write a line `@AGENTS.md` in the project's `CLAUDE.md`, pulling it in via `@import` recursion
- **Symlink** — `ln -s AGENTS.md CLAUDE.md` so both entry points point to the same file

The intent behind this design choice: Claude Code treats CLAUDE.md as the single entry point, and doesn't do implicit "auto-merge multiple entry points" behavior. Reusing docs across tools has to go through explicit `@import` or symlinking.

Searching the source, `AGENTS.md` only shows up in the `/init` command's subagent prompt — that's the subagent, while researching a repo, also scanning for AGENTS.md — not the runtime auto-loading it.

## At Post-Compact Time — Who Gets Rehung and Who Doesn't

Compact truncates the messages array, but does the CLAUDE.md family's prepend user message get rehung at the same time? **This is a counterintuitive fork** (see the compact taxonomy in [04 · Compaction's Six Siblings · From Manual to Everywhere](04-compaction.md) for details).

Answer: **when compact fires, the getMemoryFiles cache gets cleared, and the next turn reassembles from scratch**. Concretely, in `postCompactCleanup.ts`:

- clears the `getUserContext` cache
- calls `resetGetMemoryFilesCache('compact')` to clear the underlying memory cache
- clears the skill-already-sent list, the classifier, sessionMessages, and so on

**Why it needs to be rehung**: compact collapses the current conversation into a summary message, restarting the messages array as a new chain. If the CLAUDE.md prepend weren't rehung, the new chain would come up without that SR layer, and the model would lose track of project rules. So root/project-level CLAUDE.md must be rehung on post-compact.

**But conditional rules don't get rehung**: conditional rules are JIT-triggered (injected only when a particular file is read) — they aren't part of the SR that gets prepended once at session start. After post-compact, the next time a file is read, matching happens fresh — that "fresh read" is itself a full re-match, not a rehang but a fresh evaluation.

**Nested rules have their own dedup**: if the rules directories are nested (a project-level rules directory that itself `@import`s another rules directory), post-compact injection relies on a `processedPaths` set to avoid duplicate injection. This set is rebuilt after every compact — each full assembly pass is "no duplicates within this pass," not "no duplicates across turns."

## The Full Journey of One CLAUDE.md Line

Back to the opening question — what does the line "this project uses pnpm, not npm" look like by the time it reaches the LLM? Now we can walk through it in full:

1. **Session start** — Claude Code starts from cwd, `findGitRoot()` finds the project root, gets `/repo`
2. **Assemble 5 layers** — `~/.claude/CLAUDE.md` (empty), `/repo/.claude/rules/` (empty), `/repo/CLAUDE.md` (has the pnpm line), `/repo/CLAUDE.local.md` (absent), `~/.claude/projects/<hash>/memory/MEMORY.md` (present)
3. **@import recursion** — `/repo/CLAUDE.md` has no @import, stops at depth 0
4. **Conditional rules check** — not checked at session start, waits for JIT
5. **Total character count** — 30 characters + MEMORY.md's 2KB ≈ just over 2KB, well under the 40k hard cap
6. **Assemble the SR** — each file laid out as `Contents of <path> (<description>):\n\n<content>`, opening with MEMORY_INSTRUCTION_PROMPT
7. **Prepend to messages[0]** — `role: user`, `isMeta: true`, wrapped in SR, with a `# currentDate` header attached
8. **Cache breakpoint** — placed at the end of the messages segment, doesn't touch the tools/system cache
9. **What the model sees** — the first user message is this SR, followed by what you actually asked: "help me install lodash"

**Next turn, "install axios too"**:
- The CLAUDE.md family hasn't changed, the getMemoryFiles cache hits, the same prepend gets reused
- A new user message is appended to the messages segment, the cache breakpoint shifts to the latest one
- That pnpm instruction stays hanging at position 0 of the array, visible to the model every turn

**Editing CLAUDE.md mid-session**:
- The assembly function is memoized, needs `resetGetMemoryFilesCache()` to invalidate
- Nothing calls reset proactively — editing the file doesn't get rehung this turn, only triggering compact or restarting the session does
- Exception: if you edit a conditional rule under `.claude/rules/`, the next time a matching file is read, the new version is picked up (each JIT read hits disk fresh)

**Triggering compact**:
- postCompactCleanup clears the cache, the next turn rehangs — that's when your edited file finally takes effect

That completes the journey of one line, "use pnpm" — it never enters the system prompt, it's bundled into the same SR as the day's date, it occupies position 0 of messages to claim the model's attention, it's memoized so it doesn't refresh live, and it gets rehung at compact. Every one of these design choices traces back to the prompt cache skeleton and the messages array invariants.

## Summary

The CLAUDE.md family isn't one file — it's a **loading stack**:

- **5 layers**: Managed → User → Project (including upstream rules lookup) → Local → AutoMem
- **Injection position**: the 0th user message of the messages array, wrapped in an SR, `isMeta: true`, on the messages cache branch rather than the system cache
- **Load timing**: full assembly at session start, fully memoized, cache cleared and rehung on post-compact
- **@import**: 5-hop recursion (not the officially stated 4-hop), relative to the including file's directory, skipped inside code fences, files outside cwd require approval
- **Path-scoped**: `.claude/rules/*.md` frontmatter with `paths:` uses gitignore semantics, matched JIT — determined by the Read/Edit target path
- **40k characters**: the total hard cap — the official docs' "1000 pattern / 4MiB" figure doesn't exist in the source
- **MEMORY.md**: dual-threshold truncation at 200 lines OR 25KB, frontmatter fields are `name/description/type`, 4 memory types, Kairos logs gated by feature flag
- **Todo v2**: a third persistence channel, driven by tools rather than prepend, on by default in interactive mode
- **AGENTS.md**: not built in, wired in explicitly via @import

None of these mechanisms are scattered options — they're the product of a single **assembly function**. That function lives in `src/utils/claudemd.ts`, and one call sweeps all 5 layers, expands the 5-hop recursion, dedups, truncates, concatenates strings, and memoizes the result — once at session start, once again post-compact, stable in between.

The next article covers sub-agent context isolation — does the 5-layer loading described here get inherited by sub-agents? What does a forked sub-agent actually see? See [06 · Sub-agent Isolation · From Independent Context to the .output Trap](06-sub-agent.md).

---

## References

**Source locations** (Claude Code v2.1.220):

- 5-layer loading main function: `src/utils/claudemd.ts` `getMemoryFiles` `:790-1050`
- SR prepend assembly: `src/utils/api.ts` `prependUserContext` `:449-474`
- MEMORY_INSTRUCTION_PROMPT definition: `src/utils/claudemd.ts` `:89-90`
- MAX_INCLUDE_DEPTH = 5: `src/utils/claudemd.ts` `:537`
- MAX_MEMORY_CHARACTER_COUNT = 40_000: `src/utils/claudemd.ts` `:91`
- @import parsing: `src/utils/claudemd.ts` `extractIncludePathsFromTokens` `:451-535`
- Conditional rules matching: `src/utils/claudemd.ts` `processConditionedMdRules` `:1354-1396`
- Nested worktree dedup: `src/utils/claudemd.ts` `:857-870`
- External include approval: `src/utils/config.ts` `hasClaudeMdExternalIncludesApproved` `:115`
- CLAUDE_CODE_DISABLE_CLAUDE_MDS + bare mode: `src/context.ts` `:162-172`
- MEMORY.md thresholds: `src/memdir/memdir.ts` `MAX_ENTRYPOINT_LINES=200` / `MAX_ENTRYPOINT_BYTES=25_000` `:35-38`
- Truncation implementation: `src/memdir/memdir.ts` `truncateEntrypointContent` `:57-90`
- Memory type definition: `src/memdir/memoryTypes.ts` `MEMORY_TYPES` `:14-21`
- Auto-memory toggle: `src/memdir/paths.ts` `isAutoMemoryEnabled` · `src/tools/ConfigTool/supportedSettings.ts` `autoMemoryEnabled:59`
- Todo v2 gate: `src/utils/tasks.ts` `isTodoV2Enabled` `:133-139`
- Todo v2 storage: `src/utils/tasks.ts` `getTaskListId` `:200-227`
- Post-compact rehang: `src/services/compact/postCompactCleanup.ts` `resetGetMemoryFilesCache('compact')`

**External references**:

- Anthropic docs: [Manage Claude's memory](https://code.claude.com/docs/en/memory) — the official docs say @import is 4-hop; the source says 5-hop
- Simon Willison: the `node_type: memory` note — outdated; the source uses `type: user/feedback/project/reference`
- GitHub issue #29599 — background on the nested worktree dedup

**Related notes in the vault**:

- 00 · Discovery report · the 4 major strategies and 20+ mechanism checklist · the note-taking section of strategy two
- [01 · Agent Loop · How Context Gets Assembled](01-agent-loop.md) · the messages prepend position
- [02 · Three Invariants from a Single Message to the Messages Array](02-message-invariants.md) · isMeta / SR channel
- [03 · Prompt Cache Is the Skeleton · Why Everything Else Grew the Way It Did](03-prompt-cache.md) · why it goes through messages instead of system
- [04 · Compaction's Six Siblings · From Manual to Everywhere](04-compaction.md) · rehang vs no-rehang at post-compact
- [07 · Meta Mechanisms · From system-reminder to 20+ Channels](07-meta-mechanisms.md) · a typology of SR channels · CLAUDE.md is one of its uses
- Study notes_s09 · the store/select/extract/consolidate cycle of the memory system (reference only)
