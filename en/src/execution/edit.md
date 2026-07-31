This is the sixth article in the Claude Code tools research series. The previous five articles covered the "interaction primitive trio" (Ask / EnterPlanMode / ExitPlanMode) and the first two links of the execution primitive chain — the location tool [Grep + Glob](grep-glob.md) and the perception tool [Read](read.md). The former tells Claude "where the relevant files are," while the latter tells Claude "what the file currently looks like."

This article continues from Read to discuss its partner — **Edit**. If Grep + Glob is about "finding coordinates" and Read is about "knowing what the file looks like," then Edit is about "making precise changes based on that knowing." Read and Edit share the same harness-tracked state, forming a complete closed loop for "safely modifying code."

> For this series, first read the [prerequisite article](../tool-mechanism.md) — which clarifies what a tool is and how Claude uses it. This article unfolds along the 4-layer skeleton laid out in the prerequisite.

## Edit

If Ask / EnterPlanMode / ExitPlanMode are the "etiquette of collaboration," then Edit is the "craftsmanship of labor" — every code change goes through it. This tool has **a daily invocation count far exceeding all interaction tools combined**, yet its design is more "blade-turned-inward" than the interaction tools — every constraint is designed to prevent AI from making low-level mistakes.

### Purpose

Edit is Claude Code's built-in **precise string replacement tool**. What it does is simple: in a known file, replace one exact piece of text (`old_string`) with another piece of text (`new_string`).

The core problem it solves is "how AI can **safely, precisely, and auditably** modify code":

1. **Only change what needs to be changed** — incremental replacement rather than whole-file rewriting, minimizing the surface of damage
2. **Force basis on real files** — must Read first before Edit, forbidding hallucination-based modifications
3. **Uniqueness protection** — the target text must be unique in the file (unless batch operation is explicitly declared), preventing collateral damage
4. **Auditable diff** — the tool call itself makes changes clear, no need to compare the whole file

### A concrete example

**Scenario**: The user says **"Rename the function `handleClick` to `handleSubmit` — it better matches its actual semantics."**

Suppose there's a `LoginForm.tsx` file, 600 lines long, where `handleClick` appears 4 times: 1 function definition, 2 occurrences in JSX as `onClick={handleClick}`, and 1 in a comment "handleClick will...".

#### Counterexample: If there were no Edit (only Write)

Claude could only use the Write tool to **rewrite the whole file** to complete this rename:

- First Read the 600 lines to get the current content
- Do the 4 replacements in its head
- Use Write to save the modified 600 lines back to the file

The user would encounter several problems:

1. **Severe token waste** — the 600 lines of content are fully transmitted twice in tool calls (Read input + Write output), while actual changes are only in 4 places
2. **Uncontrolled damage surface** — Write overwrites the entire file; if Claude drops a space during transmission / replaces a wrong quote / misses copying a line, the entire file is polluted by this bug
3. **Diff hard to audit** — what the user sees in the tool call log is "whole file 600 lines → whole file 600 lines," and has to run a diff to see what Claude actually changed
4. **Hallucination risk** — if Claude's memory of the file diverges from what's on disk (e.g., user just edited it in the middle), whole-file rewriting effectively **overwrites Claude's memorized version onto disk**, swallowing the user's changes
5. **Concurrent conflicts** — if the user just saved a change in another editor, Claude's whole-file write overwrites it, without even a prompt

**Core pain point**: whole-file rewriting amplifies the cost of "changing one place" to "changing everything," expanding the risk surface from 4 places to 600 lines.

#### How Edit solves this

Claude first Reads to get the file, then calls Edit with three parameters:

- `file_path`: absolute path of `LoginForm.tsx`
- `old_string`: `"handleClick"`
- `new_string`: `"handleSubmit"`
- `replace_all`: `true` (rename semantic requires all replacements)

**What happens at runtime**:

- Runtime check: was this file Read in the current session? If not, error immediately
- Runtime check: if `replace_all=false`, the number of `old_string` occurrences in the file **must be exactly 1**; otherwise error
- Runtime execution of replacement: find all `handleClick`, replace all with `handleSubmit`
- Runtime writes only the **diff portion** back to the file, leaving the other 596 lines untouched

What the user sees in the tool call log:

```
Edit(file_path: LoginForm.tsx, old_string: "handleClick", new_string: "handleSubmit", replace_all: true)
→ 4 replacements
```

**Crystal clear, no side effects, no token waste.**

#### Comparing which pain points from the counterexample are resolved

| Counterexample pain point | Edit's solution |
|---|---|
| Severe token waste | tool call only transmits the diff portion, not the whole file |
| Uncontrolled damage surface | only replaces at `old_string` matches; other 596 lines untouched |
| Diff hard to audit | tool call parameters *are* the diff, visible at a glance |
| Hallucination risk | Read prerequisite enforced: error if not read, no memory-based modifications allowed |
| Concurrent conflicts | only changes 4 places · doesn't overwrite the whole file · user's other edits unaffected |

### Trigger conditions

The tool's official description reads firmly: **"ALWAYS prefer editing existing files · NEVER create new files unless explicitly required"**. Behind this principle is a value: **reduce unnecessary artifacts · modify in place whenever possible**.

**Scenarios where Edit should be used**:

- **Modifying a known piece of code** — fixing bugs, renaming, adjusting logic
- **Fine-tuning configuration files** — changing a field value, adding a line, deleting a line
- **Modifying documentation** — updating a section of README, fixing typos
- **Batch renaming** — a variable appears in multiple places, use `replace_all`

**Scenarios where Edit shouldn't be used** (should use Write or other tools):

- **Creating new files** — Edit can't create files, must use Write
- **Completely rewriting a file** — if changes cover 80%+ of the file, the old_string in Edit becomes long and fragile; better to Write in one go
- **When fuzzy matching is needed** — Edit is exact string matching; if you want to "find all `console.log(...)` regardless of what's inside the parens," Edit can't do it, you need a script

A **crucial mental model**: **Edit only handles strings you already fully know**. If you're unsure what that piece of code in the file looks like, you shouldn't be calling Edit at all — you should Read first to see clearly, or use Grep to find context. **Edit is not an "exploration tool" · it's an "execution tool"**.

### Technical implementation

#### 1 · Naming

`Edit`

A single verb summarizing all responsibilities. Not called `Replace` / `Modify` / `Patch` — "Edit" carries editor semantics; the first thing Claude thinks upon seeing this word is "modify a piece of content in an existing file," not "create a new file" or "append content." Field names `file_path` / `old_string` / `new_string` / `replace_all` are all self-explanatory.

#### 2 · Tool-level description

Edit's description revolves around four things: **semantic positioning / Read-first / uniqueness and remediation / taste constraints**.

**Opening sentence, setting the tone**

> Performs exact string replacements in files.

The word "exact" sets the tone for the entire tool — not fuzzy, not similar, not approximate; it's **verbatim** replacement. This one word pulls Edit from "AI intelligently modifying code" back to the positioning of "text processor."

**Enforcing Read-first**

> You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.

Key phrase **will error** — not "recommended" or "preferably," but a hard block at the runtime layer. This prompt trains Claude to build a reflex: **Want to Edit? Read first.**

**Line number prefix trap**

> When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: line number + tab. Everything after that is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.

This entire paragraph specifically warns about one concrete pitfall. Interestingly, the official text explicitly states "Everything after that is the actual file content" — you can tell the team has been bitten by this bug many times. This is a **prompt grown from bloody lessons**.

**Prefer editing over creating**

> ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.

Key words **ALWAYS / NEVER** — uppercase + extreme quantifiers. This isn't just a "suggestion"; it's a values statement: **Claude should behave like an engineer who respects the existing code structure, not casually spawning new files**.

This also guards against a class of AI anti-patterns: **hallucinatory production** — the AI thinks "I should create a new utility class" when in fact the project already has one that suffices, resulting in a pile of scattered new files.

**Emoji prohibition**

> Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.

A constraint that looks strange at first glance, added specifically for Edit. Why? Because AI (especially early-training models) loves to stuff emojis into comments / commit messages / documentation — but **most codebases don't welcome this style**. This constraint is an explicit expression of "codebase taste," making Claude's output better align with professional engineering conventions.

**Uniqueness failure and replace_all**

> The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.

Gives **two remediation paths**: expand context / use replace_all. This one is particularly considerate — not just saying "it will fail," but telling Claude **what to do** after failure. This is a hallmark of a good prompt: error paths must also be designed.

**Legitimate use of replace_all**

> Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.

Explicitly states that `replace_all` is **designed for scenarios like "variable renaming"**. Providing a concrete use case is far more useful than generically saying "set to true to replace all" — Claude reads this and immediately builds a mental mapping: "Oh, for renaming I use this flag."

#### 3 · Field-level description

Edit has 4 fields:

- `file_path` — the target file's **absolute path** (relative paths not accepted)
- `old_string` — the exact text to be replaced
- `new_string` — the text after replacement (must differ from `old_string`)
- `replace_all` — boolean, defaults to `false`; when `true`, replaces all matches

Few fields, but each has non-trivial design behind it:

**Exact string matching · not AST / LSP / fuzzy diff**

The Claude Code team chose the **most primitive yet most robust** approach — pure string matching. Reasons:

- **Language-agnostic** — no need to maintain a parser for every language; Python / Rust / YAML / Markdown all supported
- **Simple implementation** — no need to introduce tree-sitter / LSP dependencies
- **Explicit failures** — no match means error; won't "approximately match somewhere close enough"
- **Claude-controllable** — whatever string Claude outputs is what gets replaced; won't be silently rewritten by an AST normalizer

The cost: Claude must provide `old_string` **verbatim**, including spaces, indentation, and newlines. This outsources the "complexity of parsing files" to Claude itself — and Claude is naturally good at handling exact strings.

**Read-first harness constraint**

If a file hasn't been Read in the current session, Edit will error immediately. Why? To prevent hallucination.

Claude may "remember" what a file looked like the last time it edited it, but **last time is last time** — the file on disk may have been modified by user / other agents / other tools. The essence of forcing Read-first is: **every Edit is based on current disk state, not the version in Claude's memory**.

This constraint doesn't rely on self-discipline; it relies on runtime tracking: "Has this file_path appeared in any Read tool calls in the current session?" If not, reject.

**Value of the uniqueness check**

If `replace_all=false` (the default), Edit requires `old_string` to appear in the file **exactly once**. This constraint prevents a class of insidious bugs:

- Claude wants to change `return null` in function A, but another function B in the file also has `return null`
- Edit finds the first match and replaces it, possibly modifying the wrong function

The uniqueness enforcement exposes this ambiguity as an **edit failure**, forcing Claude to provide **enough context** to disambiguate — for instance, letting `old_string` include the function signature and surrounding lines to make it unique.

**replace_all is a first-class citizen for the rename scenario**

The same tool can handle both single-place changes and full-file changes, switched via a flag:

- Renaming a variable takes one call
- No need to loop Edit calls to replace one by one
- No need to write regular expressions (easy to mess up)

**line number prefix trap**

When the Read tool outputs content, it adds line number prefixes (format: number + tab + actual content). Edit's official description specifically warns: **never include line number prefixes in old_string** — those are Read's display format, not the file's real content.

This trap is subtle, and beginners are most likely to step on it:

```
Read output: 42	  const x = 1;
```

Claude might want to stuff `42	  const x = 1;` directly into old_string — wrong; those `42	` characters don't exist on disk at all. The correct approach is to take the portion after the tab: `  const x = 1;`.

The line number prefix is Read's **necessary output** (giving Claude a coordinate system), while also being Edit's **necessary filter**. This phenomenon of "the same thing carrying two contradictory roles" is the root of the deep coupling between Read and Edit.

#### 4 · schema validation rules

Edit's schema is minimal:

| Field | Type | Constraint |
|---|---|---|
| `file_path` | string | required · must be absolute path |
| `old_string` | string | required · uniqueness check by default |
| `new_string` | string | required · must ≠ old_string |
| `replace_all` | boolean | optional · defaults to false |

The critical **hard blocks are not in the schema**, but at the harness layer:

1. **Read prerequisite** — error if not previously Read
2. **Uniqueness** — error if old_string matches > 1 place (unless replace_all=true)
3. **Match failure** — error if old_string not found
4. **No-op detection** — error if old_string == new_string

These validations are all **loud fails**: Claude receives explicit error messages and can immediately correct; there's no silent degradation (like "fuzzy matching to something close enough"), avoiding bug accumulation downstream.

This also explains why Edit's schema layer is so simple — **the real constraints all live in the runtime state machine**, not in the parameter structure.

---

### Division of labor with neighboring tools

Edit forms a contrast with the previous five tools:

| Dimension | Three interaction primitives | Grep + Glob | Read | Edit |
|---|---|---|---|---|
| Position | Collaboration alignment | Locate coordinates | Perceive external state | Precise execution |
| Frequency | Key moments | Daily high-frequency | Daily high-frequency | Daily high-frequency |
| Parameters | Structured (Ask) / empty (both PlanModes) | pattern (no need for path) | file_path + pagination | 4 fields (including old_string) |
| Semantics | Intent signals | Locate coordinates | Perception commitment | Data operation |
| Failure modes | User rejection | Empty match / head_limit truncation | File not found / PDF exceeds pages without spec | Match failure / uniqueness conflict / not Read |
| Conservative bias | "When uncertain, plan" | "Search on demand before full read" | "When uncertain, read a bit" | "When uncertain, Read" |

**Edit's deep coupling with the first two links** is most obvious in this table — half of Edit's conservative bias ("when uncertain, Read") is **outsourced to Read**; and Read in turn depends on the coordinates provided by Grep+Glob. The three links form a trust chain through harness-tracked state:

- Grep / Glob locate: "which files are relevant to this task"
- Read establishes "perception commitment": "I know what this file currently looks like"
- Edit consumes the commitment: precise replacement based on the accurate content in Claude's memory
- Shared pitfalls: line number prefix is Read's necessary output and Edit's necessary filter
- State machine collaboration: harness tracks Read state → validates on Edit → errors if missing

---

### Summary

The elegance of Edit lies not in its feature of "letting AI modify code," but in its signal distribution being **extremely biased toward the runtime state machine**:

- **Naming** — minimal, a single verb
- **Tool-level description** — long, 7 paragraphs of constraints covering semantic positioning / Read-first / uniqueness and remediation / taste
- **Field-level description** — 4 fields, each backed by non-trivial decisions (pure strings / harness Read state / uniqueness / replace_all / line number trap)
- **Schema validation** — minimal; the real hard blocks all live at the runtime layer (Read state / uniqueness / match failure / no-op)

What makes Edit unique is that it **shifts the center of gravity for "safely modifying code" from parameter validation to the state machine**: Edit itself has almost no schema constraints, but by sharing the harness-tracked state with Read, it constructs a strong guarantee that "every edit is based on the current disk truth." It effectively converges the generic capability of "AI precisely modifying code" into a **language-agnostic, hallucination-proof, auditable, batch-supporting** execution primitive.

The next article continues to dissect [Write](write.md) — Edit's sibling tool · handling the two things Edit can't: **creating new files · completely rewriting**. Let's see how Write finds a balance between "necessity" and "danger."
