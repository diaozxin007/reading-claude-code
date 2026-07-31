This is the seventh installment of the Claude Code tools research series. The previous six covered the "interaction primitive trio" (Ask / EnterPlanMode / ExitPlanMode), the search duo [Grep + Glob](grep-glob.md), and the perception + precision execution pair [Read](read.md) / [Edit](edit.md). This one discusses Edit's sibling tool — **Write**.

Grep + Glob + Read + Edit together handle the vast majority of "locate first, then read, then precisely modify" scenarios. But there are two things Edit cannot do: **creating new files · completely rewriting files**. These two tasks can only be accomplished with Write.

Write appears simple (it's just "write content to a file"), but its design has a particular tension — **it is both necessary (the only tool that can create new files) and dangerous (it can overwrite any existing file)**. The entire Write prompt addresses this tension.

> This series begins with the [prerequisite article](../tool-mechanism.md) — explaining what tools are and how Claude uses them. This article follows the 4-layer skeleton proposed there.

## Write

### Purpose

Write is Claude Code's built-in **full file write tool**. What it does is straightforward: given an absolute path and text content, it writes that content to the file. If the file already exists, it **overwrites entirely**; if it doesn't exist, it **creates** it.

The core problem it solves is "how can AI **safely and explicitly** produce new files or perform complete rewrites":

1. **The only execution tool that can create new files** — Edit cannot create, Bash can but isn't subject to review
2. **The most economical path for complete rewrites** — when changes exceed 80% of the file, Write is more efficient than a bunch of Edits
3. **Forces overwrites based on real state** — existing files must have been Read first before Write, preventing hallucinated overwrites
4. **Reviewable complete artifacts** — the tool call contains the full text about to be written to disk, clearly visible

### A Concrete Example

**Scenario**: The user says **"Add a `UserBadge` component for me that displays user avatar + name + status indicator, put it at `src/components/UserBadge.tsx`"**.

This is a typical scenario for **creating a new file from scratch**. There's no UserBadge in the project, and after Claude explores the project's style, it's ready to write out the new file.

#### How Write Solves This

Claude calls Write directly with two parameters:

- `file_path`: `/Users/xxx/project/src/components/UserBadge.tsx` (absolute path)
- `content`: the complete component code (dozens of lines)

**What happens at runtime**:

- Runtime check: does the parent directory of the target path exist? If not, it errors
- Runtime check: if the file already exists, was it Read in this session? If not, it errors (**same harness tracking mechanism as Edit**)
- Runtime executes the write: writes `content` completely to disk
- If creating new, it creates the file; if overwriting, it replaces the entire content

What the user sees in the tool call log:

```
Write(file_path: src/components/UserBadge.tsx, content: [full 40-line component])
→ File created
```

**Done in one shot, no side effects**.

#### Counter-example: What If Write Were Used for Edit's Job

Continuing from the Edit scenario in the previous article — the user says "rename `handleClick` to `handleSubmit`". The file already exists, is 600 lines, and only needs 4 changes.

**If Claude stubbornly uses Write instead of Edit**:

- First Read to get all 600 lines
- Mentally make the 4 replacements
- Use Write to write back all 600 modified lines

This runs into several problems:

1. **Severe token waste** — 600 lines of content are fully transmitted in the tool call (Write's content parameter), while the actual changes are only in 4 places
2. **Uncontrolled blast radius** — Write overwrites the entire file; if Claude drops a space / swaps a quote / misses a line during transmission, the entire file is polluted by this bug
3. **Hard to review diffs** — the user sees 600 lines of content in the tool call log and needs to run a diff against the old version to see what Claude actually changed
4. **Amplified concurrency conflicts** — if the user just saved other changes in another editor, Write overwrites everything without even a warning
5. **Accidental overwrite risk** — Write does "whole replacement" without Edit's safety net of "old_string must match"; writing wrong content won't produce an error

**Core insight**: **Write and Edit are not substitutes — they have a division of labor**. Write handles creation / complete rewrites; Edit handles incremental modifications. Mixing them up loses each tool's unique safety guarantees.

#### When to Write vs. When to Edit

| Scenario | Choose Write | Choose Edit |
|---|---|---|
| Creating a new file from scratch | ✅ Only option | ❌ Cannot create |
| Changes cover 80%+ of the file | ✅ Full rewrite is more economical | ⚠️ old_string would be very long and fragile |
| Changes cover under 20% of the file | ⚠️ Token waste · large blast radius | ✅ Precise replacement |
| Renaming a variable / function | ❌ Not recommended | ✅ Use replace_all |
| Fixing a typo | ❌ Using a cannon to kill a mosquito | ✅ One replacement does it |
| Generating config files / boilerplate | ✅ Write it all at once | ❌ Can't Edit an empty file |

A rough **mental model**: if most of the content in your `new_string / new_content` is **copied from the old file**, use Edit; if **most of the content is newly written**, use Write.

### Trigger Conditions

The tool's official description is very restrained: **"Prefer editing existing files — unless explicitly required, don't create new ones"**. This is the **explicit arbitration** of the default competitive relationship between Write and Edit.

**Scenarios where Write should be used**:

- **User explicitly requests creating a new file** — "add a xxx component for me" / "generate a xxx config"
- **Code needs a new module** — creating new files when splitting existing code
- **Complete rewrite** — when changes exceed 80%, Edit's old_string would be too long, actually increasing fragility
- **Generating boilerplate** — scaffolding, test templates, migration files

**Scenarios where Write should NOT be used**:

- **Fine-tuning existing files** — use Edit; precise replacement is its strength
- **Writing docs / README unless the user explicitly asks** — official hard constraint, see section 2 · Tool-level Description below
- **Adding emoji unless the user explicitly asks** — official hard constraint, see section 2 · Tool-level Description below
- **"Validating" from hallucination** — same anti-waste principle mentioned in the Read article; don't Read back after Write to verify

An interesting **anti-auto-production principle**: the official prompt states `NEVER create documentation files (*.md) or README files unless explicitly requested by the User` — capitalized NEVER. The constraint behind this is a **hard-won lesson**: early AI tools would often "helpfully" auto-generate piles of README / CHANGELOG / API.md files, and project owners would find the ground littered with markdown that appeared without permission — awkward to delete, so it just stays. **Write's constraint nails down this anti-pattern**.

### Technical Implementation

#### 1 · Naming

`Write`

The naming is extremely straightforward — a single verb, the most basic "write" in English. Together with `Edit` and `Read`, they form a sibling trio that's self-explanatory:

- **Read** — read · perceive the external
- **Edit** — edit · incremental modification
- **Write** — write · full write to disk / create new

All three verbs point to "file" as the operation target, but with clear semantic boundaries: Read only inputs, never outputs; Edit is "existing content → change part of it"; Write is "whether it exists or not → overwrite entirely / create new". **The granularity of the verb directly encodes the danger level** — Write is the heaviest action among the three, and the name itself signals this.

The field names are equally plain: `file_path` + `content`. No old_string / new_string / replace_all or any "matching" concept, because Write doesn't do matching at all — the semantics are simply "put this content onto disk". Fewer fields is actually a form of candor: **Write has no safety net, and doesn't pretend to have one**.

#### 2 · Tool-level Description

Write's tool-level description is short and sharp. Let's break down each constraint:

**Constraint 1: Transparency of overwrite behavior**

> This tool will overwrite the existing file if there is one at the provided path.

The keyword is **will overwrite** — no softening with "be careful / please note", just stating it clearly. This description makes Claude fully aware of Write's destructive nature — there's no illusion of "I thought it would merge."

**Constraint 2: Read-first enforcement**

> If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.

Keywords **MUST / will fail** — hard block. Exactly the same constraint as Edit. This description establishes the Read → Edit / Write trust chain in Claude's intuition: the runtime records which files have been Read in this session, and validates when Write targets an existing file. The purposes:

- **Prevents hallucinated overwrites** — Claude might "remember" what a file looks like, but what's on disk may have already changed
- **Forces a perception commitment** — "You want to overwrite this file? First prove you know what's currently in it"
- **Shares trust chain with Edit** — Read → Edit and Read → Write run through the same state machine

Creating new files doesn't require Read-first (because the file doesn't exist yet), but once a file exists, Read is required. **This is "Write's dual nature" manifested at the harness layer**.

**Constraint 3: Prefer Edit over Write**

> Prefer the Edit tool for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.

Keywords **Prefer / Only** — one encouraging, one restricting, **narrowing Write's legitimate use cases to two**:

- Creating new files
- Complete rewrites

This constraint is the **authoritative arbitration** of the Write vs. Edit division of labor. It prevents Claude from abusing Write just because "Write's semantics are simpler."

**Constraint 4: Don't proactively create documentation**

> NEVER create documentation files (*.md) or README files unless explicitly requested by the User.

Keywords **NEVER / unless explicitly requested** — uppercase + extreme quantifier. This is particularly close to **user experience**: preventing Claude from being overly clever and producing piles of unwanted markdown. Behind it is a **hard-won lesson**: early AI tools would often "helpfully" auto-generate README / CHANGELOG / API.md files, and project owners would find the ground littered with markdown that appeared without permission — awkward to delete, so it just stays.

Interestingly, this constraint **targets only Write** (Edit has a similar principle but not this extreme) — because Write is the entry point for "creating new files," and creating new md files is more likely to cause noise pollution than editing existing ones.

**Constraint 5: Emoji prohibition**

> Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.

Same constraint as Edit, for the same reason: AI training models naturally love inserting emoji into code / comments / commit messages, and most professional codebases don't welcome this style.

**Constraint 6: Error recovery path**

> This tool will fail if you did not read the file first.

It doesn't just say it will fail; it implies the correction path: **after the error, Read first, then retry Write**. This is the same hallmark of "good prompt design" as Edit's "uniqueness failure → expand context / use replace_all" — error paths must also be designed.

**The "don't proactively produce" value synthesis**

Constraints 3 + 4 + 5 together constitute Write's **"don't proactively contribute noise" principle**: unless the user explicitly asks, Claude should not:

- Proactively generate README / CHANGELOG / docs
- Proactively create new files (edit if possible)
- Proactively add emoji

These three are not runtime hard blocks (Write's parameters don't validate md suffixes / emoji), but rather **behavioral training at the description layer**. They hardcode the value of "AI should produce cautiously and should not automatically contribute markdown and emoji" into Claude's default behavior.

#### 3 · Field-level Description

Write's input schema is extremely simple, with only two fields:

- **file_path** — the target file's **absolute path**
- **content** — the complete content to write

Seemingly unremarkable, but each field has its considerations:

**`file_path` — Why force absolute paths**

Same design as Read / Edit: eliminating CWD dependency so every call is **self-explanatory**. Across sessions, across subagents, across worktrees, absolute paths are never ambiguous.

**`content` — Why it's just "complete content"**

Compared to Edit's 4 fields (file_path + old_string + new_string + replace_all), Write has only 2 fields, missing the concepts of "matching" and "batch." The reasons:

- **The semantics are "use this content to overwrite disk"** — no need for "match what," because it's not replacement
- **No "batch" concept** — one Write is one complete write; there's no partial matching
- **Simple failure modes** — either write succeeds or write fails (permissions / disk / path); there's no intermediate state like "match failure"

Write's simplicity conversely means it **lacks Edit's safety nets** — no match validation, no uniqueness check, no replace_all branching. **Larger risk surface, but clearer semantics**. This is "danger + necessity coexisting" manifested at the field level: fewer fields doesn't mean weaker capability; it's **deliberately not giving Claude the illusion of "fine-grained adjustment,"** forcing it to realize that "pressing Write means overwriting everything."

#### 4 · Schema Validation Rules

Write has almost **no hard constraints at the schema layer** — no length limit, no format validation, no content blocklist. Just two required fields, and that's it.

The real constraints are all in the **runtime**, forming a state machine:

| Check | Timing | Failure behavior | Intent |
|---|---|---|---|
| Parent directory exists | Before write | Error, refuses to write | Prevent typos from creating scattered directories |
| File exists → Read in this session | Before write | Error, refuses to write | Prevent hallucinated overwrites (harness tracking) |
| File doesn't exist → allow directly | Before write | Creates directly | New file path doesn't need Read |
| Permissions / disk / path legality | During write | Error, refuses to write | Fallback for OS-level failures |

**Why parent directories aren't auto-created**: if the path Write receives is `foo/bar/baz.ts` but the `foo/bar/` directory doesn't exist, Write errors directly and **will not auto-create the directory**. The reasons:

- **Prevents typos from creating scattered directories** — if Claude misspells the path as `srcc/component.tsx` and Write auto-creates `srcc/`, it pollutes the project structure
- **Forces Claude to be aware of directory structure** — want to write a file in a new directory? First use Bash `mkdir -p` to explicitly express intent; you can't silently pull out a new directory
- **Explicit failure** — an error is better for correction than "silently succeeding"

**Harness state sharing for Read-first**: Read establishes a "perception commitment," and Edit / Write consume that commitment:

- Read's harness state is **shared by both execution tools**
- Edit consumes: "I know what old_string looks like in the file"
- Write consumes: "I know what I'm overwriting"

This sharing allows a single Read call to provide the perceptual foundation for multiple subsequent Edit / Write operations, without re-reading every time.

Empty schema layer + state machine at runtime layer — this division tells us: **Write's risk lies mainly not in parameter format, but in timing and perception**. Can parameter format be automatically validated? Yes. But "have you first perceived the file's current state" — that can only be tracked by the runtime. The schema keeps the simple work for itself and leaves the hard work to the runtime.

---

### Division of Labor with Neighboring Tools

Write contrasts with the tools from the previous six articles:

| Dimension | Three Interaction Primitives | Grep + Glob | Read | Edit | Write |
|---|---|---|---|---|---|
| Positioning | Collaborative alignment | Locating coordinates | Perceiving external | Precise execution | **Full execution** |
| Frequency | Key junctures | High daily frequency | High daily frequency | High daily frequency | Medium frequency |
| Parameters | Structured / empty | pattern | file_path + pagination | 4 fields (incl. old_string) | **2 fields (file_path + content)** |
| Semantics | Intent signals | Locating coordinates | Perception commitment | Incremental replacement | **Full overwrite / create new** |
| Safety net | User approval | head_limit truncation | Pagination / PDF forced page numbers | Uniqueness / Read / match failure | **Only Read + parent dir exists** |
| Conservative bias | "When uncertain, plan" | "Search on demand before full read" | "When uncertain, read" | "When uncertain, Read" | **"Edit if possible · don't create new"** |

**Write is Edit's sibling tool, not its replacement**. Their division of labor:

- Edit handles **incremental modifications** — old_string / new_string / replace_all, based on the assumption "file exists + only changing part of it"
- Write handles **creation / complete rewrites** — content written all at once, based on the assumption "either the file doesn't exist / or overwrite entirely"

Mixing them up loses each tool's unique safety guarantees: using Write for Edit's job wastes tokens + creates uncontrolled blast radius + makes diffs hard to review; using Edit for Write's job simply can't work (Edit cannot create new files).

**Grep+Glob → Read → Edit / Write** — these four categories and five tools share a single harness tracking state, linked through the "Read-first" hard constraint. Core philosophy: **any write to disk must be built upon perception of the current disk state**. Not by relying on AI self-discipline, but by runtime enforcement.

---

### Summary

Write's elegance lies not in the "write content to a file" functionality itself, but in how its signal distribution **depends heavily on description-layer values + runtime state machine**:

- **Naming** — minimalist, a single verb (Read / Edit / Write sibling family); plain field names without matching / batch concepts, directly mapping to "overwrite" semantics
- **Tool-level description** — 6 constraint paragraphs covering: overwrite behavior transparency, Read-first hard block, explicit preference for Edit, don't proactively produce documentation, emoji prohibition, error recovery path; three soft constraints synthesize the "don't proactively contribute noise" value
- **Field-level description** — only 2 fields (file_path + content); fewer fields doesn't mean weaker capability, it's **deliberately not giving Claude the illusion of "fine-grained adjustment,"** forcing it to realize Write = overwrite everything
- **Schema validation** — schema layer is nearly empty; real constraints are in the runtime state machine: parent directory must exist (not auto-created), existing files must have been Read in this session, shares the same harness tracking state with Edit

Write's uniqueness lies in being **the only tool that can create new files / completely overwrite files, where "necessity" and "danger" coexist**: on the necessity side, creation and complete rewrites can only be done by Write — Edit can't step up; on the danger side, it lacks Edit's matching safety net, and a single call can overwrite any position in a 596-line file. This tension is resolved through a three-layer design — **description layer explicitly prefers Edit (narrowing Write to "create / complete rewrite"), runtime state machine forces Read-first (eliminating hallucinated overwrites), three soft constraints nail down AI anti-patterns (don't proactively build docs / don't create new files / don't add emoji)**. It effectively takes "AI writing entire files" — an inherently dangerous capability — and converges it into an execution primitive that is **use-case-restricted, perception-enforced, and noise-averse**.

The next article continues with [Bash](../power/bash.md) — the most special piece in the entire tool ecosystem: **the only fallback tool with no boundaries**. The previous 7 tools all focus on "letting AI do limited things," while Bash lets AI "do anything." Let's see how the Claude Code team balances "unlimited capability" with "safety."
