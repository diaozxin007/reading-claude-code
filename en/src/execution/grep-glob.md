This is the fourth installment of the Claude Code tools research series. The first three covered the "interaction primitive trio" -- [AskUserQuestion](../interaction/ask-user-question.md), [EnterPlanMode](../interaction/enter-plan-mode.md), and [ExitPlanMode](../interaction/exit-plan-mode.md). Those three tools solve "how AI and users align."

Starting from this article, we enter the world of **execution primitives** -- how Claude actually makes code changes after arriving at a plan. But before reading, editing, or writing, it first needs to **know where to read, edit, and write**. So the first execution primitive to dissect is the **search duo**: Glob finds by path, Grep finds by content.

> This series assumes you've read the [prerequisite article](../tool-mechanism.md) -- which explains what tools are and how Claude uses them. This article follows the 4-layer framework proposed there.

## Grep + Glob

When Claude first enters a new project, it has no idea about file paths -- "Where's the auth-related code?" "Which files use useState?" "Which files were recently modified?" Without search tools, Claude can only guess from training memory (inaccurate) or ask the user to list files manually (tedious).

Search in Claude Code is a duo: **Glob finds by path, Grep finds by content**. This article covers both together because they are highly coupled in functionality, frequently used in combination, and separating them would create redundancy.

They share a core philosophy: **perceive on demand -- only send what Claude actually needs to see into the context**. They also serve as prerequisites for the [Read](read.md) / [Edit](edit.md) / [Write](write.md) "file operation primitives" we'll dissect next.

### Purpose

**Glob** is a tool for **finding files by path pattern** -- input a shell glob (`**/*.ts` / `src/**/api-*.js`), get back a list of matching file paths sorted by modification time in descending order.

**Grep** is a tool for **finding files/lines by content** -- powered by ripgrep under the hood, input a regex pattern, get back matching file paths / matching lines / match counts (three output modes available).

Together they solve the core problem of "how Claude **locates the files it needs to look at** in a massive codebase":

1. **No need to read the entire project** -- locate relevant files first, then Read, saving context
2. **No need to guess where files are** -- compared to training memory, search gives disk truth
3. **No need to craft Bash commands** -- a dedicated tool avoids shell escape / path dependency / permission issues
4. **Controllable output modes** -- especially Grep's three-tier output_mode lets Claude fetch data on demand

### A Concrete Example

**Scenario**: The user says **"Help me look at how the auth-related code is organized -- I want to refactor it."**

Claude has no idea where auth code lives: could be in `src/auth/`, `server/middleware/`, `lib/security/`, or scattered across `pages/api/login.ts`.

#### Counter-example: With Only Read

Without search tools, Claude can only:

- **Guess from training memory** -- "Node.js projects usually put auth in `src/middleware/auth.js`", Read it and find it doesn't exist
- **Ask the user to list files** -- "Can you tell me the auth-related file paths?" User manually lists a bunch, tedious
- **Read everything under src/** -- A medium project has 200+ files, hundreds of thousands of tokens, context blown immediately

**Pain point**: No search = Claude **can't see the shape of the codebase** -- can only rely on indirect information or brute-force reading everything.

#### How Grep + Glob Solves This

**Step 1: Use Glob to survey the file landscape**

Claude calls Glob:

- `pattern`: `**/*{auth,login,session,jwt}*` (matches paths/filenames containing these keywords)

Returns:
```
src/auth/middleware.ts    (2h ago)
src/auth/routes.ts        (2h ago)
src/lib/session-store.ts  (3d ago)
src/pages/api/login.ts    (1w ago)
tests/auth.test.ts        (2h ago)
```

Sorted by modification time descending -- **most recently modified files appear first**, usually the main battlefield.

**Step 2: Use Grep to dig deeper into specific usages**

Claude wants to know "where is `jwt.verify` being used":

- `pattern`: `jwt\.verify`
- `output_mode`: `content` (returns matching lines + file paths + line numbers)
- `-C`: `2` (2 lines of context before and after)
- `type`: `ts`

Returns:
```
src/auth/middleware.ts:8:      const decoded = jwt.verify(token, process.env.JWT_SECRET);
src/auth/middleware.ts:9:      req.user = decoded;
--
src/services/api-client.ts:42:  return jwt.verify(token, PUBLIC_KEY);
--
```

**Each result is a precise coordinate -- immediately ready for Read or Edit**.

**Step 3: Combined usage**

If Claude only wants to know **how many files use jwt.verify** (not where exactly):

- `pattern`: `jwt\.verify`
- `output_mode`: `count`

Returns `4 files`. This call costs only a few dozen tokens, no need to pull all matching lines into context.

If it only wants to know **which files use it** (path list, no specific lines):

- `pattern`: `jwt\.verify`
- `output_mode`: `files_with_matches`

Returns a list of file paths.

**Core insight**: Grep's three-tier output_mode (**content / files_with_matches / count**) lets Claude **fetch data at the precision it needs** -- dig deep with matching lines, narrow scope with path lists, estimate scale with counts.

### Trigger Conditions

**When to use Glob**:

- **Finding by filename / path** -- "all `.tsx` files" / "all files under `src/api/`" / "where are the test files"
- **Finding by modification time** -- "recently modified files" (Glob defaults to mtime descending)
- **Narrowing scope before combining with Grep** -- Glob first to narrow to relevant files, then Grep to dig deeper

**When to use Grep**:

- **Finding files/lines by content** -- "where is useEffect used" / "where is UserBadge defined"
- **Investigating API usage surface** -- "all places that call `db.query`"
- **Searching error messages** -- user pastes an error, search the codebase for where it might be thrown

**When to combine both**:

- **Locating modules in a large codebase** -- Glob first to narrow to `**/*auth*` related files, then Grep for specific calls
- **Restricting by language/type** -- only search in `.ts` files -- Grep's `type: "ts"` handles this directly, no need for Glob as a prerequisite

**When NOT to use them**:

- **Reading a known exact path** -- just Read directly, don't detour through Grep/Glob
- **Listing a directory** (not finding a pattern) -- use Bash `ls`; Glob does pattern matching, not directory browsing
- **Fuzzy semantic search** (like "find all code that does authentication") -- Grep can only do literal/regex matching, it doesn't understand semantics; use the Agent tool to dispatch a subagent for investigation

### Technical Implementation

Grep and Glob are **sibling tools** -- clear division of labor but shared design philosophy. We'll dissect each through the 4 layers, then look at their duality one more time.

---

## Glob

#### 1. Naming

`Glob`

The naming directly borrows from the industry convention of shell / Python glob libraries -- "glob" is the universal term for "find files by path pattern." The fields `pattern` / `path` are names that any shell user intuitively understands.

If it were called `FindByPath` or `SearchFiles`, it would dilute the core promise of "using glob syntax, not regex." The name itself hints at the syntax.

#### 2. Tool-level Description

Glob's description is extremely brief -- just 5 bullet points, focused on two things: **usage constraints and boundary delegation**.

**pattern uses glob syntax, not regex**

> Supports glob patterns like "**/*.js" or "src/**/*.ts"

Only two examples, no regex examples. **Demonstration over prohibition** -- rather than writing "don't use regex," let Claude see the typical glob form like `**/*.js`. This prevents Claude from stuffing `.*\.ts` into the pattern field.

**Results sorted by modification time descending**

> Returns matching file paths sorted by modification time

Declares the total order of the output. This description builds Claude's intuition: **Glob's first result is the most recently modified file**. For tasks like "find the project's main battlefield" or "find the module that was just refactored," the top few entries are usually sufficient.

**Explicit purpose: finding by filename**

> Use this tool when you need to find files by name patterns

Although Grep also has a `glob:` field for filtering paths, that's **filtering** not **searching**. Glob is the first-class citizen tool for filenames.

**Open-ended search delegates to Agent -- don't force it**

> When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead

This is the most interesting one: **proactively acknowledging its own boundaries**. If a task requires multiple rounds of glob + grep alternation (like "find which module recently broke"), the description proactively tells Claude to switch to the Agent tool rather than struggling within a single Glob call.

#### 3. Field-level Description

- `pattern` -- shell glob expression (`**/*.js` / `src/**/*.{ts,tsx}`), not regex
- `path` -- optional, restricts search directory (defaults to CWD)

Fields are minimal. **Modification time sorting** is a hidden gem of design: when human programmers think "what have I been working on lately," the instinct is `ls -lt`. Glob defaults to mtime descending output, **letting Claude see the project's main battlefield at a glance**. Cold code sinks to the bottom; hot code floats to the top.

#### 4. Schema Validation Rules

**Minimal**. Only `pattern` is required, `path` is optional, no additional numeric constraints.

Glob's signals are almost entirely in **naming + tool description**. The schema layer adds no restrictions because glob syntax itself is already convergent enough.

---

## Grep

#### 1. Naming

`Grep`

Again borrowing industry convention -- "grep" is the universally recognized "match by content" operation in the Unix world. But note that under the hood, the tool uses **ripgrep** (rg), not traditional grep. The naming preserves the most familiar name to lower cognitive barriers while internally upgrading to a faster engine.

#### 2. Tool-level Description

Grep's description is one level more detailed than Glob's -- 7 bullet points + one declaration, focused on four things: **bidirectional lock-in of usage, syntax explanation, filter dimensions, and boundary delegation**.

**ALWAYS / NEVER -- bidirectional lock-in**

> ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.

**The heaviest sentence in the entire Grep description**. ALWAYS + NEVER bidirectional lock-in: the positive side says what to use, the negative side prohibits which shortcut, plus a "has been optimized for permissions and access" sentence that answers "why." This guards against Claude's instinct -- being proficient with shell, it naturally wants to take the `Bash("rg foo")` path -- but rg output in bash isn't structured, and it won't pass the permission layer either.

**pattern is ripgrep regex**

> Supports full regex syntax (e.g., "log.*Error", "function\s+\w+")

In explicit contrast to Glob -- Grep's pattern is **regex**. Two highly realistic examples: `log.*Error` (finding log errors) and `function\s+\w+` (finding function definitions); Claude immediately knows the syntax style.

**Two filter dimensions: glob vs type**

> Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")

Gives Claude two parallel paths: use `glob:` (precise path pattern) or `type:` (language shortcut, ripgrep's built-in table). Type is a ripgrep specialty -- a single `type:rust` replaces writing something like `**/*.{rs,toml}`.

**output_mode defaults to files_with_matches**

> Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts

**Notice "(default)" is on files_with_matches**. Why not `content`? Because **content is the most context-expensive**; making it the default could easily cause blowouts. Default to the path list, let Claude decide whether to dig deeper. This is a **default that respects the token budget**.

**Open-ended search delegates to Agent (symmetric with Glob)**

> Use Agent tool for open-ended searches requiring multiple rounds

Perfectly symmetric with Glob. Both tools **declare their boundaries in pairs** -- when facing multi-round iteration scenarios, switch to Agent.

**ripgrep is not grep -- literals need escaping**

> Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\{\}` to find `interface{}` in Go code)

A **specific gotcha example**: to find `interface{}` in Go code, you must write `interface\{\}`. Why specifically mention this? Because `{}` in ripgrep is a **quantifier range** (`a{2,3}` means repeat 2-3 times); if Claude writes `interface{}` following grep intuition, it will get a regex error. **One real example replaces lengthy syntax lectures**.

**multiline defaults to off -- explicit opt-in**

> Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \{[\s\S]*?field`, use `multiline: true`

**Default single-line matching** -- this guards against Claude writing a cross-line regex and getting no matches without knowing why. A concrete example: finding a `field` declaration inside a Go struct requires `multiline: true`. The **default off + explicit opt-in** pattern is used twice (here and Read's pages parameter), both for "expensive" behaviors that require an explicit switch.

#### 3. Field-level Description

Grep's fields are far richer than Glob's:

- `pattern` -- regex (ripgrep syntax)
- `path` -- optional, restricts search directory
- `glob` -- optional, only search files matching the glob (e.g., `"*.ts"`)
- `type` -- optional, only search specific languages (`ts` / `py` / `rust`)
- `output_mode` -- `content` / `files_with_matches` (default) / `count`
- `head_limit` -- limits output line count
- `-i` -- case insensitive
- `-n` -- show line numbers (added by default in content mode)
- `-A` / `-B` / `-C` -- lines of context after / before / around (content mode only)
- `multiline` -- allow pattern to match across lines
- format flags (`-c`, `-l`, `-L`, `-o`, `-Z`) -- let grep run natively without wrapping

**Several key design points**:

**Three-tier output_mode design** -- This is Grep's most elegant aspect. The same search can produce three levels of precision:

- `content` (full matching lines) -- when you need to see exactly where and what the context looks like
- `files_with_matches` (file paths only) -- when you just want to know which files are involved
- `count` (count only) -- when you just want to know the scale

These correspond to three typical intents: "I need to fix" (content) / "I need to refactor" (files_with_matches) / "I need to assess" (count). Grep lets Claude **choose precision by intent**, avoiding pulling full data every time and wasting context.

**head_limit as a safety net** -- A `console.log` search might return 1000 lines; without limits it would flood the context. `head_limit: 50` makes Grep return only the first 50 results, **sufficient without explosion**. Note that the sort order before head_limit is **alphabetical by file path** for Grep and **descending by modification time** for Glob -- it's not relevance ranking, just truncation.

**type vs glob -- two ways to narrow scope** -- type is ripgrep's language recognition based on file content/extensions, recognizing `.py` `.rs` `.ts` and such; glob is pure path matching, able to handle special paths (like `**/legacy/**/*.js` to exclude a certain directory). Type is more concise; glob is more flexible.

**"format flags pass through as-is" as a fallback channel** -- When the tool's normalized output isn't enough, Claude can "drop down" to raw ripgrep capabilities. The designers know their wrapper isn't perfect and left an escape hatch.

#### 4. Schema Validation Rules

Grep's schema layer also has **almost no hard constraints** (no numeric limits, no character length), all constraints are **enumerations**:

| Field | Type | Constraint |
|---|---|---|
| `output_mode` | string | Enum `content` / `files_with_matches` / `count`, default `files_with_matches` |
| `-i` / `-n` / `multiline` | boolean | Default false |
| `-A` / `-B` / `-C` | integer | Only effective when output_mode = content |
| `head_limit` | integer | No default; unlimited if omitted |

**Default values are Grep's core design** -- output_mode defaults to `files_with_matches`, multiline defaults to off, i/n default to off. **Every default leans toward "less output, simpler mode"**, ensuring Claude's default behavior is already at the most context-efficient tier.

---

### Why Build Dedicated Grep/Glob Instead of Letting Claude Use Bash + rg?

Bash is a catch-all that can theoretically do anything. But calling rg directly has a pile of problems:

- **Shell escaping** -- `$` `!` `(` in regex can all be expanded by the shell
- **Path dependency** -- Is rg even installed? What version?
- **Output parsing** -- Bash returns a wall of text that Claude has to parse itself
- **No output_mode tiers** -- rg has too many flags for Claude to remember

A dedicated tool solves all these pain points: parameters are typed, output is normalized, no shell traps, Claude gets it done in one shot. This is also the **technical foundation** for that sentence in Grep's description: "ALWAYS use Grep... NEVER invoke grep or rg as a Bash command."

---

### Division of Labor with Neighboring Tools

**Where Grep + Glob sit in Claude Code's execution primitive system** -- providing a "map" in advance; subsequent articles will fill in each piece:

| Dimension | Three Interaction Primitives (covered) | Grep + Glob (this article) | Read (next) | Edit (sixth) | Write (seventh) |
|---|---|---|---|---|---|
| Role | Collaboration alignment | Locating coordinates | Perceiving content | Precise execution | Full execution |
| Frequency | Critical junctures | Daily high-frequency | Daily high-frequency | Daily high-frequency | Medium frequency |
| Input | Structured / empty | pattern (no path knowledge needed) | Known path | Known path + old_string | Known path + full content |
| Output | User decision | Path list / matching lines / count | Full file content | Modified diff | New file / overwrite |
| Conservative bias | "If unsure, plan" | "Search on demand before full read" | "If unsure, read" | "If unsure, Read first" | "If Edit works, Edit" |

**Complete investigation chain** (combining the execution primitives from subsequent articles):

```
User: Help me refactor auth-related code
    |
Glob (**/*{auth,login,session}*)              <- This article
    -> Get relevant file path list (sorted by mtime)
    |
Grep (pattern: "jwt\.verify", output_mode: files_with_matches)  <- This article
    -> Get files that specifically use the API
    |
Read (each relevant file)                      <- Next article
    -> Get full content, establish perception commitment
    |
Edit / Write                                   <- Later articles
    -> Make precise / full modifications based on perception commitment
```

**Trust chain of execution primitives**:

- **Glob / Grep** -- Locate: "which files are relevant to this task"
- **Read** -- Perceive: "what do these files currently look like"
- **Edit / Write** -- Execute: "make precise / full modifications based on perception"

Every step is runtime-enforced, parameters are typed, output is normalized. **From a vague user request, converging to a precise file modification** -- the entire process is predictable, auditable, and composable.

---

### Summary

The elegance of Grep + Glob lies not in the "letting AI search" functionality itself, but in how their signal distribution is **extremely symmetric yet each has its own emphasis**:

- **Glob** -- naming carries the core semantics (directly using industry convention), minimal fields, no schema constraints. The tool's entire complexity is just "find paths by glob syntax" -- one single thing
- **Grep** -- the richest fields of all (11 fields/flags), yet the schema layer has no hard numeric constraints; it relies entirely on **defaults converging to the most context-efficient tier**

The most brilliant symmetry between the two tools: **both proactively acknowledge their boundaries at the description level** -- when facing "multiple rounds of glob + grep alternation" scenarios, they proactively tell Claude to switch to Agent. **Tools that know what they're good at and what they're not** -- this is a very restrained, very mature design in Claude Code's tool ecosystem.

This also embodies the core philosophy of Claude Code's tool ecosystem -- **rather than giving AI an all-powerful shell and letting it figure things out, every step is made into a "sufficient + safe + composable" primitive**.

The next article continues with [Read](read.md) -- after obtaining coordinates, how Claude precisely perceives a file's current state, building the "perception commitment" trust chain for Edit / Write.
