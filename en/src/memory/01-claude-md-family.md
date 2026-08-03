# 01 · The CLAUDE.md Family · 5-Layer Hierarchy and 3 Mixing Patterns

> Article 01 of this series — follows 00 · Discovery Report · The Full Inventory of 5 Memory Carriers, from CLAUDE.md to memories, expanding on the "Carrier A · The CLAUDE.md Family (Static Instruction Layer)" section. This article covers the first layer of the memory stack from the **disk perspective**.
>
> Its sister article [05 · The CLAUDE.md Family · From One Line "Use pnpm" to a 5-Layer Loading Stack](../context-management/05-claude-md-family.md) covers the "messages array perspective" — how CLAUDE.md gets prepended as a system-reminder, how it gets tagged isMeta, and how the 40 KB hard ceiling gets split. **05 is the entry point, this article is the exit point**: that article covers the loading path, this article covers **who writes these files, where they live, who can override whom, and under what conditions they load**.

## TL;DR

| 6 key facts about the first layer of the memory stack | Conclusion |
|---|---|
| CLAUDE.md **is not a single file** | It's 5 layers — Managed / User / Project / Local / Nested — maintained by different roles |
| The override mechanism is **appending**, not replacing | Every layer goes into the messages array; a later-loaded layer doesn't semantically override an earlier one, it just "adds another line" |
| The Managed layer **cannot be excluded** | `claudeMdExcludes` can be configured at any of the user/project/local/policy layers, but the policy's managed CLAUDE.md is a hard constraint |
| `.claude/rules/*.md` files with a `paths` frontmatter are **loaded on demand** | Injected only when a matching glob is hit — not re-evaluated on every tool use — with a combined budget of 1,000 patterns and 4 MiB |
| `@import` allows a maximum of **4 hops**, skips code fences, and resolves relative paths **relative to the importing file** | Not relative to `cwd` — this is the most common pitfall |
| Claude Code **does not read AGENTS.md directly** | You either import it explicitly via `@AGENTS.md`, symlink it with `ln -s AGENTS.md CLAUDE.md`, or maintain the two files separately |

## 1 · Starting from a Single CLAUDE.md at the Repo Root

Suppose a project has a `CLAUDE.md` at the repository root containing:

- Use `pnpm` for installing dependencies, not `npm`
- Run `pnpm test` after modifying code
- Put new components under `src/components/`
- Don't directly modify auto-generated files

Once the user starts Claude Code, these project conventions get loaded; whenever Claude is later asked to install dependencies, modify a component, or run tests, it consults these rules.

Looking only at this example, it's easy to assume CLAUDE.md is simply "a project README at the repo root." But it's actually only the **Project layer** of the CLAUDE.md family. Beyond that, there are also rules pushed down uniformly by an organization, a user's preferences that apply across all their projects, an individual's private rules for the current project, and local rules that only load once you've entered a particular subdirectory.

So **"what CLAUDE.md actually is" can't be answered by looking at a single file — it has to be understood as the composite result of 5 layers**. Let's break down those 5 layers below.

## 2 · The 5-Layer Hierarchy, Full Picture

Claude Code's official docs ([https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)) split the static instruction carrier into 5 layers. Their locations, who can write to them, and when they load all differ:

| Layer | Disk location | Who can write | When it loads | Can it be excluded via `claudeMdExcludes`? |
|---|---|---|---|---|
| **Managed** | The `claudeMd` field of `managed-settings.json` | Organization admins (policy layer) | At session start, always loaded | **No** |
| **User** | `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md` | A single user, globally | At session start, loaded unless `userSettings` is disabled | Yes |
| **Project** | `./CLAUDE.md` or `./.claude/CLAUDE.md` + `./.claude/rules/*.md` | The team (git repo consensus) | At session start, loaded unless `project` is disabled | Yes |
| **Local** | `./CLAUDE.local.md` (should be gitignored) | A single user, within the project | At session start, loaded unless `local` is disabled | Yes |
| **Nested** | `CLAUDE.md` in a subdirectory | The submodule's team | **Loaded only when that subdirectory's files are reached** (lazy) | Yes (by path) |

### 2.1 · Managed (Organizational Control Layer)

Straight from the official docs: "The `claudeMd` key lets you put managed CLAUDE.md content directly inside `managed-settings.json`" (source: [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)). Example:

```json
{"claudeMd":"Always run `make lint` before committing.\nNever push directly to main."}
```

Key properties:

- **Scope**: per the docs, "every Claude Code session on machine, in every repository" — every session on the machine, every repository, must obey this
- **Load order**: per the docs, "Loads before user project CLAUDE.md"
- **Cannot be overridden**: per the docs, "Setting `claudeMd` in user, project, or local settings has no effect"

This is the **only layer that cannot be excluded by the user** — organizational compliance requirements (no leaking internal secrets, no direct pushes to main, sensitive operations must go through approval) get anchored here. The source confirms this: `src/utils/claudemd.ts:547-550`'s `isClaudeMdExcluded` function opens with "Only applies to User, Project, and Local memory types. Managed, AutoMem, and TeamMem types are never excluded."

The Managed layer also has a twin role — `getManagedClaudeRulesDir()` (`src/utils/claudemd.ts:814`) — supporting managed-policy `.claude/rules/*.md` files. This means an organization can split its security rules across multiple files loaded on demand, but every one of them is still a hard constraint.

### 2.2 · User (Global User Layer)

Location: `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md`.

This is where "preferences common across every project on this machine" live. For example, git commit timing, workspace boundaries, and fact-checking requirements are all suited to the User layer; rules that only apply to a single repo should stay at the Project layer.

Straight from the official docs: "User-level rules — Personal rules in `~/.claude/rules/` apply to every project on your machine. Use them for preferences that aren't project-specific."

**Load order**: per the docs, "User-level rules are loaded before project rules, giving project rules higher priority" — user loads first, project loads after, and the latter, being "closer to the conversation," is semantically prioritized (see the discussion on override mechanics in §3).

**Independent toggle**: if `--setting-sources` excludes `userSettings` at startup, the User layer doesn't load at all (`src/utils/claudemd.ts:826`, `if (isSettingSourceEnabled('userSettings'))`). CI environments running Claude Code typically disable the User layer to keep personal preferences from leaking in.

### 2.3 · Project (Project Layer)

Straight from the official docs: "A project CLAUDE.md can be stored in either `./CLAUDE.md` or `./.claude/CLAUDE.md`."

**Both locations are valid.** The former sits at the repo root, immediately visible; the latter is tucked under `.claude/`, alongside the other Claude Code config (`.claude/settings.json`, `.claude/rules/`), keeping the directory tidier. Teams can choose:

- If CLAUDE.md should be the first thing the whole team sees → put it at `./CLAUDE.md`
- If CLAUDE.md is just an internal "note for the AI" that shouldn't clutter the repo root → put it at `./.claude/CLAUDE.md`

The matching `.claude/rules/*.md` files can only live under `./.claude/rules/` — the official docs designed this as "splitting files for larger projects," expanded further in §4.

### 2.4 · Local (Single-User-Within-Project Layer)

Straight from the official docs: "For private per-project preferences checked into version control, create a `CLAUDE.local.md` at the project root. It loads alongside `CLAUDE.md`," immediately followed by "Add `CLAUDE.local.md` to your `.gitignore` so it isn't committed."

**Semantics**: this is the layer for "my own preferences on this specific project, not shared with the team." Typical cases:

- I run local Postgres on port 5432 for project A, my teammate uses 5433 — the port preference goes here
- My personal build shortcut aliases, which the team doesn't want to standardize — goes here
- My personal API key sandbox name — goes here

**Key point**: this layer should be added to `.gitignore` by default, or it'll pollute the repo. The docs don't enforce this, but designing it as a "per-project personal preference" carrier is clearly meant to be paired with gitignore.

If `--setting-sources` excludes `local`, then CLAUDE.local.md doesn't load at all (see the discussion of additional directories in §5.3).

### 2.5 · Nested (Lazy Nested Layer)

Key property: **lazy loading**. A CLAUDE.md in a subdirectory only loads when Claude Code **reaches a file in that subdirectory**.

The official docs give a decisive contrast when discussing compaction: "Nested CLAUDE.md files in subdirectories are not re-injected automatically; they reload the next time Claude reads a file in that subdirectory. If an instruction disappeared after compaction, the conversation or lives in a nested CLAUDE.md that hasn't reloaded yet" (source: [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)).

This gives nested CLAUDE.md two counterintuitive runtime properties:

1. **Not read in full at session start** — a monorepo with 30 submodules and 30 nested CLAUDE.md files won't all get stuffed into context just because you `cd` into the root
2. **Not automatically restored by compaction** — after `/compact`, the project-root CLAUDE.md gets automatically re-injected, but a nested one doesn't — it only comes back the next time a file in that subdirectory is read

This "lazy loading vs. compaction survival" gap is the first case in the §6 counterintuitive-design discussion, expanded further below.

## 3 · Load Order, Override Rules, Exclusion Rules

Each of the 5 layers above loads at a different time — what order do they end up in within the messages array, and how do the exclusion rules actually work?

### Load order: Managed → User → Project → Local → Nested

Per the implementation at `src/utils/claudemd.ts:800-847`:

```
1. Process Managed file first (always loaded - policy settings)     :804
2. Process Managed .claude/rules/*.md files                          :814
3. Process User file (only if userSettings is enabled)               :826-834
4. Process User ~/.claude/rules/*.md files                           :837
5. Then process Project and Local files (each dir walked from cwd)   :849-857
6. Nested = lazy on Read tool file access                            (elsewhere)
```

The official docs confirm this too: "User-level rules are loaded before project rules, giving project rules higher priority" — implying that **load order is not the same as priority order** (whatever loads later has higher priority).

### Override mechanism: append, not replace

A very counterintuitive point: **Claude Code does not resolve rule conflicts.** Once all 5 layers are loaded, they're stuffed verbatim into the system-reminder in entry 0 of the messages array (see the sister article [05 · The CLAUDE.md Family · From One Line "Use pnpm" to a 5-Layer Loading Stack](../context-management/05-claude-md-family.md) for the full message shape).

If the User layer says "use pnpm" and the Project layer says "use npm," what Claude actually sees is:

```
Contents of ~/.claude/CLAUDE.md: ... use pnpm ...
Contents of ./CLAUDE.md: ... use npm ...
```

**Both lines are there — it's left to the LLM to resolve the conflict.** Empirically, the Project layer sits closer to the conversation body, so the LLM tends to favor it — but that's a matter of the LLM's semantic interpretation, not something the loader enforces.

### Exclusion rules: `claudeMdExcludes` merges across layers, Managed is immune

Straight from the official docs:

```json
{"claudeMdExcludes":["**/monorepo/CLAUDE.md","/home/user/monorepo/other-team/.claude/rules/**"]}
```

Along with the explanation: "Patterns are matched against absolute file paths using glob syntax. You can configure `claudeMdExcludes` at any layer: user, project, local, or policy. Arrays merge across layers. Managed policy CLAUDE.md files cannot be excluded."

What "merge across layers" means:

- User-layer settings exclude `**/experiments/CLAUDE.md`
- Project-layer settings exclude `**/vendor/CLAUDE.md`
- The merged result: both get excluded

**Managed immunity** is very explicit in the source — `src/utils/claudemd.ts:547-550`:

```
if (type !== 'User' && type !== 'Project' && type !== 'Local') {
  return false
}
```

Managed / AutoMem / TeamMem types short-circuit directly to false — exclusion patterns **don't even participate in the decision** for them. This is the payoff of the "policy layer" design: rules an admin configures for compliance can't be sidestepped by the user through a setting (you can uninstall Claude Code, but you can't "use Claude Code while ignoring this rule").

## 4 · `.claude/rules/*.md` · Conditional Loading by Path

The 5 layers above deal with "the whole CLAUDE.md file." But a large project's rules might number in the dozens, and cramming them all into one CLAUDE.md would blow past the 40 KB ceiling (see the `MAX_MEMORY_CHARACTER_COUNT = 40_000` discussion in [05 · The CLAUDE.md Family · From One Line "Use pnpm" to a 5-Layer Loading Stack](../context-management/05-claude-md-family.md)). Claude Code's answer is `.claude/rules/*.md`, loaded on demand.

### `paths` frontmatter · glob syntax

Straight from the official docs' example:

```yaml
---
paths:
  - "src/api/**/*.ts"
---
# API Development Rules
- All API endpoints must include input validation
- Use the standard error response format
- Include OpenAPI documentation comments
```

Key rules (all verbatim from [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)):

- "Rules without a `paths` field are loaded unconditionally and apply to all files" — rules without a `paths` field load immediately at startup, effectively acting as split-off pieces of CLAUDE.md
- "Path-scoped rules trigger when Claude reads files matching the pattern, not on every tool use" — **not re-evaluated on every tool use** (avoiding an O(pattern × tool_call) CPU cost), but rather loaded **when a matching file is read**
- "Path-scoped matching also works when Claude reaches a file through a symlinked path to the project directory" — matching also works through a symlinked path into the project directory

### Budget: 1,000 patterns · 4 MiB

Straight from the official docs: "`paths` list shares one budget of 1,000 expanded patterns and 4 MiB, and patterns without braces don't count against it. Claude Code uses any pattern that would exceed the budget unexpanded, so literal braces match no files."

Breaking that down:

- 1,000 is the pattern count **after expansion** — `src/**/*.{ts,tsx}` expands to 2, `{a,b}/{c,d}/*.{ts,tsx}` expands to 8
- Patterns without braces **don't count against the budget** — because they don't need expanding
- 4 MiB is the total byte ceiling
- A pattern exceeding the budget gets "used unexpanded" — meaning the `{}` is treated as a literal character, which usually matches nothing — this is **graceful degradation, not a hard error**

### Version notes

All three version boundaries are verbatim from the same official docs page:

- **Min version 2.1.217**: "Before v2.1.217, a `paths` value with many brace groups stalled or crashed the CLI" — before 2.1.217, a large number of brace-group combinations could bog down or crash the CLI
- **Min version 2.1.207**: "Before v2.1.207, one invalid pattern made the Read tool fail for every file the rule was evaluated against, instead of matching nothing" — before 2.1.207, a single invalid pattern would fail the Read tool for the entire rule
- **Min version 2.1.211**: "Before v2.1.211, rules that load on demand, including path-scoped rules and rules in nested `.claude/rules/` directories, loaded even when `project` was excluded" — before 2.1.211, path-scoped rules could bypass the `project` exclusion set via `--setting-sources`

All three point the same direction — newer versions are more conservative, older ones more permissive (so older versions carry a bypass risk, a crash risk, and a rule-propagation-failure risk). **If an organization's compliance heavily relies on setting-sources exclusion, it must pin to 2.1.211+.**

## 5 · Three Common Mixing Patterns

The above covers the "official 5 layers." In practice there are also 3 common mixing patterns:

### 5.1 · Swapping with AGENTS.md

Background: many projects already maintain an AGENTS.md (a generic instruction file meant for other coding agents like Cursor / Copilot / Windsurf). How does Claude Code reuse it?

The official docs are explicit: "Claude Code reads `CLAUDE.md`, not `AGENTS.md`" — **Claude Code only reads CLAUDE.md, it does not read AGENTS.md directly**.

Three approaches:

**Approach A · explicit `@import`** (officially recommended):

```markdown
@AGENTS.md

## Claude Code
Use plan mode for changes under `src/billing/`.
```

Benefit: AGENTS.md remains the single "generic rule base," with Claude-specific instructions appended underneath in CLAUDE.md.

**Approach B · symlink**:

```bash
ln -s AGENTS.md CLAUDE.md
```

Per the docs: "A symlink also works if you don't need to add Claude-specific content," with a Windows caveat attached: "On Windows, symlink requires Administrator."

**Approach C · maintain them separately**: keep the two files independent. Downside: double the maintenance cost.

**Verification method**: the docs offer a one-liner — "run `/context` and confirm `CLAUDE.md` appears under **Memory files**" — run `/context` after startup and check whether CLAUDE.md shows up under Memory files.

### 5.2 · `@import` Syntax · 4-Hop Depth · Skipping Code Fences

CLAUDE.md can use an `@` prefix to import other markdown files. The official rules, verbatim:

1. **Relative vs. absolute paths**: "Both relative and absolute paths are allowed."
2. **What are relative paths resolved against?**: "Relative paths resolve relative to the file containing the import, not the working directory." — **not `cwd`, but the file doing the importing** — this is the most common pitfall
3. **Recursion, 4 hops**: "Imported files can recursively import other files, with a maximum depth of four hops."
4. **Skipping code fences**: "Import parsing skips Markdown code spans and fenced code blocks."

A verbatim example for point 4: writing `` `@README` `` (wrapped in backticks) makes `@README` a literal string that doesn't trigger an import; writing `@README` plain does trigger one.

There's a subtlety about point 3: the docs say "maximum depth of four hops," but the source at `src/utils/claudemd.ts:537` sets `const MAX_INCLUDE_DEPTH = 5`. The gap between "hop" and "depth" is a common off-by-one convention: the originating file counts as depth 1, so 4 hops = depth 5. The sister article [05 · The CLAUDE.md Family · From One Line "Use pnpm" to a 5-Layer Loading Stack](../context-management/05-claude-md-family.md) has already verified this correspondence.

**A pattern for importing personal preferences**: at the end of the "CLAUDE.local.md" section, the official docs suggest an alternative — importing `~/.claude/my-project-instructions.md` directly inside CLAUDE.md:

```markdown
# Individual Preferences
- @~/.claude/my-project-instructions.md
```

This way CLAUDE.md stays version-controlled and shared by the team, while `~/.claude/my-project-instructions.md` is personal and differs per individual — sidestepping the manual step of gitignoring CLAUDE.local.md.

### 5.3 · Additional Directories · `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` + `--add-dir`

Straight from the official docs' example command:

```bash
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir ../shared-config
```

Immediately followed by: "This loads `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/*.md`, and `CLAUDE.local.md` from additional directory. `CLAUDE.local.md` is skipped if you exclude `local` from `--setting-sources`."

Scenario: two subprojects in a monorepo share a common `shared-config`, but the working directory can only be one of them at a time. Using `--add-dir` plus the environment variable lets Claude Code load the CLAUDE.md and rules from `shared-config` as well.

**Note**: this is **loading**, not **replacing** — the `shared-config` rules and the current project's rules **both** end up in the messages array (see the override mechanism in §3).

**Key detail**: when `--setting-sources` excludes `local`, the CLAUDE.local.md in the additional directory gets skipped too. This linkage is the natural consequence of setting-sources' "exclude by category" design — it excludes a "layer type," not a "location."

## 6 · Three Counterintuitive Design Choices

Digging through the source and docs turns up a few designs that seem odd at first glance, but make sense once you think through the reasoning:

### Case 1 · Nested CLAUDE.md loads lazily, not at startup

**The intuition**: once we're inside a project, shouldn't everything load at startup anyway — since it'll have to be read eventually, why not read it sooner rather than later?

**The reality**: the official docs, while discussing compaction, state explicitly that "Nested CLAUDE.md files in subdirectories are not re-injected automatically; they reload the next time Claude reads a file in that subdirectory." In other words, it loads **when a file in that subdirectory is read** — not at session start.

**Why**: a monorepo with 30 submodules, each with its own 5-10 KB CLAUDE.md — loading them all at startup would eat 200 KB right off the bat, swallowing more than half of a 200K window. The cost of lazy loading is that "some tool call, the first time it enters a subdirectory, temporarily attaches that subdirectory's nested CLAUDE.md" — but the payoff is that "session-start context is the minimal possible set."

**The side effect** (the counterintuitive part): during compaction, the project-root CLAUDE.md gets re-injected — **the nested one doesn't**. If a rule lives in a nested CLAUDE.md and the conversation has already gone through `/compact`, that rule **temporarily disappears** until the next time that subdirectory is read. This is exactly what the official docs warn about: "If an instruction disappeared after compaction, ... lives in a nested CLAUDE.md that hasn't reloaded yet."

### Case 2 · rules/*.md uses `paths` frontmatter as a gate, rather than loading everything at startup

**The intuition**: shouldn't everything under `.claude/rules/` just get read once at startup — the rules aren't that many anyway, 20-30 of them isn't much text to stuff into context.

**The reality**: the official docs draw a clear line — "Rules without a `paths` field are loaded unconditionally," **but** rules **with** a `paths` frontmatter don't get loaded that way — they only load when a matching file is read.

**Why**: at scale, a project's rules can number in the hundreds (frontend rules, backend rules, testing rules, security rules, migration rules, deployment rules). Cramming them all into context both blows the window and distracts the LLM's attention. The design of "matching file paths against a glob" is a way of **using filesystem semantics to infer rule relevance** — if I'm reading `src/api/user.ts`, that likely means I'm dealing with API logic, so a rule with `paths: ["src/api/**/*.ts"]` is the appropriate one to load right now.

**When it actually loads** (the counterintuitive part): it isn't triggered by tool use — it's triggered by the **Read tool, when a matching file gets read**. So a rule's "activation moment" tracks the LLM's **current context**, rather than being re-evaluated every time a tool is invoked. The source entry point is `getManagedAndUserConditionalRules(targetPath, ...)` at `src/utils/claudemd.ts:1205` — its argument is `targetPath`, i.e. "which file are you about to read," and that's what decides which rules get loaded.

### Case 3 · Managed CLAUDE.md's inability to be excluded is deliberate

**The intuition**: shouldn't users be able to manually exclude it via user settings? After all, excludes already exist as a mechanism.

**The reality**: the official docs enforce a hard constraint — "Managed policy CLAUDE.md files cannot be excluded" — no matter what `claudeMdExcludes` a user writes at the user/project/local layer, none of them can **exclude** the Managed layer. The source at `src/utils/claudemd.ts:547-550` short-circuits directly.

**Why**: the entire point of managed CLAUDE.md is **organizational compliance**. If a user could sidestep it with a single `claudeMdExcludes` line, the policy would be hollowed out — it would be like "a lock that can be bypassed by whoever it's locking out is no lock at all." This is a hard constraint, not a soft one.

**The twin division of labor** (the counterintuitive part): the official docs specifically distinguish managed CLAUDE.md from managed settings — "A managed CLAUDE.md and managed settings serve different purposes." What's in managed settings — `permissions.deny` / `sandbox.enabled` / `env` / `forceLoginMethod` — is a **hard block** (enforced directly at the tool layer and sandbox layer); managed CLAUDE.md is a **behavioral nudge** (shaping behavior by showing the LLM rules, not by intercepting anything). Per the docs: "CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer" — so things like "code style" and "quality guidelines" belong in managed CLAUDE.md, while things like "never run rm -rf" or "never access /etc" belong in managed settings' `permissions.deny`. The division of labor is deliberate.

## 7 · What to Do When a Project's CLAUDE.md Gets Too Long

At the start of a project, the root `CLAUDE.md` might just hold a few commands and coding conventions. As the project grows, it's easy to keep piling in module rules, one-off tasks, historical decisions, and personal preferences, until it turns into an ever-longer mixed-bag document.

At that point, the question shouldn't be "how do I keep adding to it," but rather "which layer, which carrier, does each type of content actually belong to."

### Long-term, universal rules stay at the root

The root `CLAUDE.md` is a good place to keep rules that hold true for the whole project long-term, for example:

- Which package manager the project uses
- Which checks must run before committing
- Which directories or generated files must not be edited directly
- Architectural boundaries the whole project agrees on

These apply to the entire repo, and are worth loading at the start of every session.

### Module rules sink down into rules or the Nested layer

If a rule only applies to a certain class of files, it can be split off into `.claude/rules/*.md` and loaded on demand via a `paths` frontmatter. If a subdirectory represents an independent module, a nested CLAUDE.md can be placed there too.

This way, frontend, backend, test, and deployment rules don't all load into context on every startup — they show up only once Claude reaches the corresponding files.

### Don't mix personal preferences into team rules

Habits that are personal and span multiple projects should go into the User layer; preferences that are personal and only apply to the current project should go into `CLAUDE.local.md`. The Project layer at the root should be reserved for conventions the team is willing to jointly maintain through version control.

Drawing this boundary keeps personal preferences out of the repo, and avoids the same universal rule getting copy-pasted across multiple projects over and over.

### Move transient progress and historical records out of static instructions

"What to do next" and "what decisions were made last month" aren't long-term behavioral rules. The former fits better in a task system or auto memory; the latter fits better in a standalone design doc, changelog, or archive file.

If CLAUDE.md is temporarily the only available place to stash short-term progress, it should still be treated as a fallback: carve out a dedicated temporary section, clean it up regularly, and leave only the necessary index in the root file. Claude Code won't automatically clean up an ever-growing CLAUDE.md on your behalf, and the loaded content itself is still subject to a character ceiling.

### The end goal of splitting things up

Splitting isn't about producing more files — it's about letting different content settle according to its own scope and lifecycle:

- Long-term, project-wide → Project CLAUDE.md
- Only applies to specific paths → path-scoped rules or Nested CLAUDE.md
- Personal preference → User or Local layer
- Transient progress → task / auto memory
- Historical material → ordinary docs or archives

In the end, the root CLAUDE.md should hold only **the minimal rule set that's worth loading every single startup**.

## 8 · Decisions, Anti-Patterns, Evolution Signals

### Decision · the **fundamental reason** for the 5-layer design is "each layer is maintained by a different role"

Looking back at who **produces** each of the 5 layers:

| Layer | Produced by | Change frequency | Change approval |
|---|---|---|---|
| Managed | Organization admins | Very low (quarterly) | Organizational process |
| User | A single user | Medium (weekly) | None |
| Project | The team (git consensus) | Medium (weekly) | PR review |
| Local | A single user, within the project | High (daily) | None |
| Nested | The submodule's team | Low (monthly) | Submodule PR |

**The 5 layers aren't a "technical stratification" — they're an "approval stratification."** Each layer has a different owner, a different process, a different review cadence. If all the rules were crammed into one CLAUDE.md, you'd end up with disasters like "changing my own habit requires filing a request to the admin" or "changing a team convention means editing everyone's dotfiles" — the layering exists precisely to separate concerns.

### Anti-patterns

- **Writing behavioral nudges in the Managed layer while expecting a hard block** — per the docs, "CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer"; hard blocks belong in managed settings' `permissions.deny` / `sandbox.enabled`
- **Letting CLAUDE.md grow without bound, never splitting or archiving it** — once it hits the loading ceiling it may get truncated; module rules should sink down, transient progress and historical records should move to their proper carriers
- **Writing all rules without `paths`, loading everything at every startup** — large-project rules should carry `paths` and load on demand, to cut down on the context footprint of every startup
- **Putting "cross-project generic preferences" inside `.claude/rules/*.md`** — these should go into `~/.claude/rules/*.md` (the User layer) instead, or every new project ends up copying them again
- **Not gitignoring CLAUDE.local.md** — this pollutes the repo, and it's awkward for teammates to see a personal preferences file
- **Putting "must-survive-compaction" instructions in a nested CLAUDE.md** — these don't come back automatically after compaction; critical rules should move up to the project-root CLAUDE.md

### Evolution signals · when it's time to promote to the next layer

- **I've written the same rule in 3 different projects now** → promote it to the User layer (`~/.claude/CLAUDE.md`)
- **My personal habit at the project layer keeps getting reverted by teammates** → move it down to the Local layer (CLAUDE.local.md), or import a personal preference via `@~/.claude/my-project-instructions.md`
- **A rule only applies within `src/api/**/*.ts`, and it distracts the LLM elsewhere** → move it out of CLAUDE.md into `.claude/rules/api.md` with a `paths` frontmatter
- **Organizational compliance requires it, and users must not be able to bypass it** → promote it from the Project layer to the Managed layer (the `claudeMd` field of managed-settings.json)
- **A submodule's team has its own independent code style that doesn't affect other modules** → split it off into a Nested CLAUDE.md in that subdirectory
- **CLAUDE.md is closing in on 40 KB and the loader is about to truncate it** → split it into `.claude/rules/*.md`, or archive parts of it into a history file

## References

### Official docs

- Claude Code Memory · [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory) (the 5-layer hierarchy, `@import`, `paths` frontmatter, `claudeMdExcludes`, managed CLAUDE.md, swapping with AGENTS.md, `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`, and all three min-version notes are quoted verbatim from this page)

### Source

- `src/utils/claudemd.ts:537` — `MAX_INCLUDE_DEPTH = 5` (the correspondence with the docs' "4 hops")
- `src/utils/claudemd.ts:540-573` — the `isClaudeMdExcluded` function, the hardcoded short-circuit for Managed immunity
- `src/utils/claudemd.ts:800-847` — the 5-layer load order, Managed → User → Project → Local
- `src/utils/claudemd.ts:1020-1039` — independent telemetry counters for the 5 layers, confirming they're 5 distinct types
- `src/utils/claudemd.ts:1205-1237` — `getManagedAndUserConditionalRules(targetPath, ...)`, the entry point for path-scoped rules, keyed on targetPath rather than the tool call name

### Sister articles · in-series cross-references

- 00 · Discovery Report · The Full Inventory of 5 Memory Carriers, from CLAUDE.md to memories · the full carrier landscape this article builds on
- [05 · The CLAUDE.md Family · From One Line "Use pnpm" to a 5-Layer Loading Stack](../context-management/05-claude-md-family.md) · sister article · covers how CLAUDE.md enters the prompt from the messages-array perspective, the isMeta marker, and the 40 KB hard ceiling
- [03 · Prompt Cache Is the Skeleton — Why Everything Else Is Shaped the Way It Is](../context-management/03-prompt-cache.md) · where CLAUDE.md lands within the prompt cache
- [06 · Sub-agent Isolation · From Independent Context to the .output Trap](../context-management/06-sub-agent.md) · whether sub-agents inherit CLAUDE.md (ties into article 04 of this series)
