This is the eighth article in the Claude Code tools research series. The first seven articles covered two main threads:

- **Interaction primitives trio** ([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md)) — solving "how do AI and user align"
- **Execution primitives chain** ([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md)) — solving "how to locate, perceive, and modify files"

These tools are all **built around the filesystem**: locate a file, read a file, modify a file. But in real projects, "changing code" is only part of the work. There's a whole class of tasks that "operating on files" cannot cover:

- Running tests
- Installing an npm package
- Executing `git commit`
- Checking CI status
- Starting a dev server
- Generating a build

What these have in common is: **they require executing a command, not modifying a file**. This is the reason Bash exists.

> This series builds on the [prerequisite article](../tool-mechanism.md) — which explains what a tool is and how Claude uses them. This article follows the 4-layer skeleton proposed there.

## Bash

Among all Claude Code tools, **Bash is the most powerful, most flexible, and most dangerous**. It essentially hands the entire operating system's shell to Claude — in theory, anything you can do in a terminal, Claude can do through Bash.

Bash's existence upgrades Claude Code from "an AI that edits code" to "an AI that can truly drive engineering tasks forward." But at the same time, it has **the most complex prompt and the most constraints in the entire tool ecosystem** — because "omnipotence" means "danger," and danger needs rules to contain it.

### Purpose

Bash is Claude Code's built-in **command execution tool**. What it does is straightforward: execute a bash command, return stdout / stderr / exit code. But beneath this "straightforwardness" lie several layers of design intent:

1. **Capability catch-all** — whatever the previous tools can't solve, Bash catches
2. **Persistent CWD** — within a session, the shell's working directory state persists
3. **Background execution** — long tasks (dev server / long tests) don't block the conversation
4. **Timeouts** — every command has a timeout to prevent hangs
5. **Sandboxing** — there are security boundaries; it's not "Claude does whatever it wants"

What makes Bash special is that it's **the only tool whose capability surface within its boundary is infinite**. Other tools have bounded capabilities (Read can only read, Edit can only replace); Bash's capability surface equals the combination of "every CLI tool installed on your system."

### A Concrete Example

**Scenario**: The user says **"Run the tests, and if they all pass, commit and push for me."**

This is a typical **multi-step command-line workflow** where none of the steps involve "modifying a file" — they're all "executing commands."

#### How Bash Solves This

Claude calls Bash sequentially, each time with a `description` (describing the purpose, not shell jargon):

**Step 1 - Run tests**

```
Bash(command: "pnpm test", description: "Run project test suite")
-> All green returns / failures print error details
```

**Step 2 - Check current changes**

```
Bash(command: "git status", description: "Show working tree status")
-> Compact output / only shows changed file list
```

**Step 3 - Check diff to confirm nothing unwanted is included**

```
Bash(command: "git diff", description: "Show unstaged changes")
-> Compact diff / Claude can see at a glance what changed
```

**Step 4 - Selectively add files**

```
Bash(command: "git add src/auth/middleware.ts src/auth/routes.ts", description: "Stage auth-related changes")
```

**Note**: Following the workspace boundary discipline in CLAUDE.md, not using `git add -A` — only adding files it changed.

**Step 5 - Commit**

```
Bash(command: "git commit -m \"$(cat <<'EOF'\nfix(auth): Fix JWT verify not stripping Bearer prefix\n\nBackground: middleware passed Authorization header directly to jwt.verify, causing all requests to 401\nChange: strip Bearer prefix before verification\nMetrics: 4 new tests added, all green\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"", description: "Commit auth fix")
```

**Note**: Using HEREDOC to pass the message — preserves formatting and newlines — appends Co-Authored-By tag.

**Step 6 - Push**

```
Bash(command: "git push origin main", description: "Push to GitHub")
-> Brief push confirmation
```

All the way through — **6 Bash calls, each with a description, each respecting working tree boundaries**. The entire flow can be reviewed step by step in the tool call log.

#### If Bash Had No Design Constraints

Imagine Bash were just a bare tool that "takes a command, returns a result" with no prompt constraints. What would happen:

1. **Jargon everywhere** — tool call descriptions are all `git status` / `pnpm test`, no context, users have no idea what Claude is doing
2. **`git add .` sweeps everything** — Claude commits the user's other uncommitted changes together, stepping on a landmine
3. **--no-verify bypasses hooks** — when pre-commit hooks fail, Claude forces past them, pushing contaminated code
4. **`rm -rf` runs freely** — Claude decides "cleanup is well-intentioned," deletes first, thinks later
5. **Uses `cat` when Read exists** — Bash is the catch-all, Claude does everything with it, wasting the normalized output of dedicated tools
6. **Commands hang until timeout** — a `curl` gets stuck, entire conversation blocks

**Core insight**: Bash's power lies in "being able to do anything" — and its danger lies in "being able to do anything." The entire set of Bash prompt constraints exists to channel this power into a "safe + auditable + cooperative with other tools" execution primitive.

### Trigger Conditions

**Scenarios where Bash should be used**:

- **Running tests / builds / lint** — `pnpm test` / `cargo build` / `tsc`
- **git operations** — status / diff / add / commit / push / branch / stash, etc.
- **GitHub CLI** — `gh pr create` / `gh pr view` / `gh run list`
- **Package management** — `pnpm install` / `npm run xxx`
- **Filesystem operations** — `mkdir -p` / `mv` / `cp` (carefully distinguished from file content operations)
- **Network operations** — `curl` / `gh api`
- **Process management** — starting a dev server (with `run_in_background=true`)
- **Complex pipelines not covered by dedicated tools** — `find ... -exec ...` combinations

**Scenarios where Bash should NOT be used** (dedicated tools should be used instead):

| Bash Usage | Should Use | Why |
|---|---|---|
| `cat file.md` | Read | Read has pagination, multimodal support, harness tracking |
| `sed -i 's/foo/bar/g'` | Edit | Edit has uniqueness checking, Read prerequisite |
| `echo "..." > file.txt` | Write | Write has harness tracking, parent directory checking |
| `grep -r "pattern" .` | Grep | Grep has output_mode, head_limit |
| `ls src/**/*.ts` | Glob | Glob has mtime sorting, path specialization |
| `echo "message"` | Output text directly | echo is for shells — Claude should just speak directly |

A **principle running throughout this article**: **Bash is the fallback, not the first choice**. If a dedicated tool can do something, the dedicated tool always takes priority. This is because dedicated tools have:

- Runtime tracking (harness state)
- Normalized output (no text parsing needed)
- Semantic constraints (like Edit's uniqueness)
- Prompt constraints (like Write not proactively producing md files)

Bash has none of these — it's an **escape hatch**, not the main entrance.

### Technical Implementation

#### 1 - Naming

`Bash`

One word encoding all responsibilities. Not called `Shell` / `Exec` / `RunCommand` — `Bash` is simply the most mainstream shell interpreter name. When Claude sees this word, its first reaction is "run a command, like I normally would in a terminal." Not called `Exec` because `Exec` would imply you can pass a structured argv array; `Bash` makes clear that **this is a string, handed to a real shell for parsing**, including variable substitution, pipes, and HEREDOCs.

Field names are also self-explanatory: `command` / `description` / `timeout` / `run_in_background` / `dangerouslyDisableSandbox`. Especially the last one — **the `dangerously` prefix is carved right into the field name**. Not called `disableSandbox` / `noSandbox` — making Claude think twice every time it sees it. This is a deterrent at the naming level.

#### 2 - Tool-Level Description

Bash's tool-level description is **the longest passage in the entire tool suite**. The original text, when divided by information type, splits into five blocks: **one-sentence core positioning -> a counter-example allowlist -> an entire section of general notes -> an entire section of git safety protocol -> an entire section on PR creation workflow**. The counter-examples and hard rules are ten times longer than the core positioning.

This is the core characteristic of this tool — **boundless capability, can only be guided through description**.

**Core positioning in one sentence**

> Executes a given bash command and returns its output.
> The working directory persists between commands, but shell state does not. The shell environment is initialized from the user's profile (bash or zsh).

One sentence explaining what Bash is. The second sentence is **the only implicit state promise**: CWD persists, shell variables don't. This isn't enforced through validation — it's self-disclosure of actual harness behavior — letting Claude know that after `cd project`, the next command is still in `project/`, but after `export FOO=bar`, the next command can't see `$FOO`. Persistent CWD makes workflows composable; non-persistent shell state prevents session contamination.

**Prefer dedicated tools: a counter-example allowlist**

> IMPORTANT: Avoid using this tool to run `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:
>
>  - Read files: Use Read (NOT cat/head/tail)
>  - Edit files: Use Edit (NOT sed/awk)
>  - Write files: Use Write (NOT echo >/cat <<EOF)
>  - Communication: Output text directly (NOT echo/printf)
> While the Bash tool can do similar things, it's better to use the built-in tools as they provide a better user experience and make it easier to review tool calls and give permission.

This section is the soul of the tool. It acknowledges a fact: **half of what can be done in Bash overlaps with dedicated tools**. cat can read files, sed can modify files, echo can create files, echo can output text — each has a corresponding dedicated tool.

So the official approach chose "deterrence through description": **list a counter-example allowlist, providing alternatives one by one**. Why not implement hard blocking? Because Bash is a general-purpose tool — whether `cat` is meant to read a file or join a pipeline (like `cat < file | jq ...`) cannot be determined at the schema level; it can only rely on Claude's own judgment.

The cost is obvious — the "An Interesting Footnote" section at the end of this article documents a live failure: while writing the thirteenth article in the series, the author was still letting Claude use `bash grep` instead of the Grep tool. **With prompt constraints alone, facing training data inertia, every call will have leaks**.

**Quotes / cd / find / sleep / long commands: an entire section of general notes**

> - Always quote file paths that contain spaces with double quotes in your command (e.g., cd "path with spaces/file.txt")
> - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it. In particular, never prepend `cd <current-directory>` to a `git` command — `git` already operates on the current working tree, and the compound triggers a permission prompt.
> - Avoid unnecessary `sleep` commands: ...
> - When running `find`, search from `.` (or a specific path), not `/` — scanning the full filesystem can exhaust system resources on large trees.
> - When using `find -regex` with alternation, put the longest alternative first. Example: use `'.*\.\(tsx\|ts\)'` not `'.*\.\(ts\|tsx\)'` — the second form silently skips `.tsx` files.

The signal across this entire section is concentrated: **every rule is not a shell best practice, but rather "a specific pitfall encountered when running shell within the Claude Code harness."**

- **Path quoting** — paths with spaces break without quotes; the most basic constraint
- **Avoiding cd** — worktrees / subagents / multiple triggers for CWD changes coexist; after cd, Claude misjudges, while **absolute paths are always precise**
- **Anti-polling** — there's a background + notification mechanism; sleep-based polling shouldn't be used. "Waiting for something" has `run_in_background`; "waiting for multiple events" has the Monitor tool; "retrying failures" should fix the root cause rather than loop-retry
- **find from current directory** — searching from `/` scans the entire disk; large directories exhaust memory
- **find -regex longest first** — a very specific GNU find pitfall: `\(ts\|tsx\)` misses all `.tsx` files; you must write `\(tsx\|ts\)`

The last rule is particularly interesting — **it grew from a painful lesson**. Someone once wrote `find . -regex '.*\.\(ts\|tsx\)'` and all `.tsx` files were missed entirely, with find not reporting any error (silently skips). This kind of "silent failure" is the hardest to debug, hence a dedicated entry in the prompt.

**git safety protocol: an entire section of dedicated rules**

> Git Safety Protocol:
> - NEVER update the git config
> - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly requests these actions. ...
> - NEVER skip hooks (--no-verify, --no-gpg-sign, etc) unless the user explicitly requests it
> - NEVER run force push to main/master, warn the user if they request it
> - CRITICAL: Always create NEW commits rather than amending, unless the user explicitly requests a git amend. When a pre-commit hook fails, the commit did NOT happen — so --amend would modify the PREVIOUS commit, which may result in destroying work or losing previous changes. Instead, after hook failure, fix the issue, re-stage, and create a NEW commit
> - When staging files, prefer adding specific files by name rather than using "git add -A" or "git add .", which can accidentally include sensitive files (.env, credentials) or large binaries
> - NEVER commit changes unless the user explicitly asks you to. ...

Every rule in this large section could independently serve as a postmortem. Let's examine the three most typical to understand the design intent:

- **The amend rule** provides a complete causal chain: "pre-commit hook fails -> commit did NOT happen -> --amend would modify the PREVIOUS commit -> could destroy previous work." Why so detailed? Because hook failure is a scenario where AI is particularly prone to getting confused — it sees the hook error, assumes the commit it just made exists but is dirty, then `--amend`s to fix it. In reality, it's modifying the old commit from before the hook fired, contaminating the user's previous clean work. This is **a causal chain grown from painful lessons**, not an abstract principle.
- **The `git add -A` ban** also prevents real incidents: AI inadvertently `git add .`s and pushes `.env` / `credentials.json` / binaries from node_modules. Adding the "specific files by name" hard rule turns "what to stage" into an explicit decision rather than a default grab-all.
- **"NEVER commit unless explicitly asked"** is a courtesy rule — it doesn't prevent bad things, it prevents being too proactive. If Claude automatically commits after changing some code, it makes users feel "upstaged," disrupting the collaborative rhythm.

**PR creation workflow: an entire section of workflow rules**

> Analyze all changes that will be included in the pull request, making sure to look at all relevant commits (NOT just the latest commit, but ALL commits that will be included in the pull request!!!), and draft a pull request title and summary:
> - Keep the PR title short (under 70 characters)
> - Use the description/body for details, not the title
>
> Important:
> - DO NOT use the TaskCreate or Agent tools
> - Return the PR URL when you're done, so the user can see it

Four signal points in this section: (1) **the complete workflow from changes to PR** is in the prompt (diff -> analyze all commits -> generate title/summary -> gh pr create); (2) **PR title 70-character hard limit** — clearly burned by GitHub UI line-wrapping before; (3) **"ALL commits, NOT just the latest!!!" with three exclamation marks** — obviously bitten by "only looking at the last commit when writing PR descriptions"; (4) **ending reminder to return the PR URL** — so the user can open it immediately.

This isn't "shell usage best practices" — it's **"best practices for completing software engineering tasks using shell."** Similarly hardcoded into the prompt, making every `gh pr create` naturally conform to collaboration norms.

**HEREDOC for commit messages**

> In order to ensure good formatting, ALWAYS pass the commit message via a HEREDOC, a la this example:

Singled out for explanation, this rule prevents a very specific failure mode: passing multi-line commit messages with `-m "..."` causes the shell to fold newlines into one line, turning the commit message into a blob. HEREDOC syntax `git commit -m "$(cat <<'EOF' ... EOF)"` is the only way to preserve formatting.

#### 3 - Field-Level Description

Bash has 5 fields. Naming is minimal — all self-explanatory:

| Field | Type | Purpose |
|---|---|---|
| `command` | string | The bash command to execute (required) |
| `description` | string | Describes what this command does (strongly recommended) |
| `timeout` | number | Timeout in milliseconds (default 120000, max 600000) |
| `run_in_background` | boolean | Whether to run in background (default false) |
| `dangerouslyDisableSandbox` | boolean | Disable sandbox (not used by default) |

Few fields, but each has non-trivial design behind it. Let's expand on 3 key design points:

**description: dual-channel expression making tool calls readable**

description is not for Bash — it's **for the user and Claude's future self to read**. The tool call log doesn't show `git status` (users can't understand Claude's intent), but rather `Show working tree status` (users understand at a glance).

How to write description is also tightly constrained. The tool description provides very specific examples in two groups:

- **Simple commands** (git / npm / standard CLI): 5-10 words, brief
  - `ls` -> "List files in current directory"
  - `git status` -> "Show working tree status"
  - `npm install` -> "Install package dependencies"
- **Complex commands** (pipelines / obscure flags): add enough context
  - `find . -name "*.tmp" -exec rm {} \;` -> "Find and delete all .tmp files recursively"
  - `git reset --hard origin/main` -> "Discard all local changes and match remote main"
  - `curl -s url | jq '.data[]'` -> "Fetch JSON from URL and extract data array elements"

Even forbidden words are defined: **Never use words like "complex" or "risk" in the description**. Don't scare people, don't exaggerate risk — just state what the command does.

This separates "command" from "intent" — **commands are for machine execution, intent is for human review**. The tool call log thus becomes a readable operation checklist, not a pile of shell instructions.

**run_in_background: the entry point for non-blocking async**

If a command is expected to run for a long time (dev server / training / waiting for CI), set `run_in_background=true`: the command returns immediately with a shell/task ID, Claude continues the conversation without blocking, and upon completion is notified via `<task-notification>`. Output can be retrieved or the task killed using BashOutput / TaskStop.

This flag turns Bash into Claude's "non-blocking IO": start a dev server then continue editing code, rather than waiting idly. It's also the downstream support for the "anti-polling principle" — why does the official stance dare tell Claude not to use sleep for polling? Because `run_in_background` + the notification mechanism serve as the safety net.

**dangerouslyDisableSandbox: naming as deterrent**

By default, Bash runs in a sandbox — certain operations are blocked (like system-level configuration changes). This flag can disable the sandbox. But the `dangerously` prefix in the field name isn't decoration — it's **a deterrent at the naming level**, making Claude think twice every time it fills this field: "Do I really need to disable the sandbox?"

Compare with Edit / Write's field names, which are all neutral (`file_path` / `old_string` / `content`). Having a field with a `dangerously` prefix appear in Bash — this asymmetry itself is a signal: **the greater the capability, the more vigilant the naming**.

#### 4 - Schema Validation Rules

Bash's schema-level validation is minimal:

| Field | Constraints |
|---|---|
| `command` | Required, string |
| `description` | Optional, string (but description strongly recommends filling it) |
| `timeout` | Optional, number, max 600000 (10 minutes) |
| `run_in_background` | Optional, boolean |
| `dangerouslyDisableSandbox` | Optional, boolean |

**Bash's real constraints are entirely outside the schema**, living in two places:

1. **A large section of natural language constraints in the tool description** (prefer dedicated tools / quoting / avoid cd / anti-polling / git safety protocol / PR workflow / HEREDOC) — all relying on prompt persuasion
2. **Execution boundaries at the harness runtime layer** (sandbox blocking / timeout kill / permission prompts / background task lifecycle) — relying on environment safety nets

Compare with Edit / Read's schemas: Edit has uniqueness checking / Read prerequisite state machine; Read enforces absolute paths — all **concrete constraints that can be blocked by schema + runtime state machines**. Bash's input is "a string that can contain any command" — schema validation cannot exhaustively enumerate "which commands are dangerous," so the tool description is forced to carry the vast majority of constraints.

---

### An Interesting Footnote

During the writing of this series, there was a particularly instructive live failure. Recording it here as a counter-example.

**Scenario**: While writing the thirteenth article on Monitor, I needed Claude to cross-reference the locations of 8 prompt constraints in an already-written chapter. The first reaction — let's see what tool Claude called:

```
Bash(command: 'grep -n "constraint 2\|constraint 3\|constraint 4\|constraint 5\|..." "thirteen Monitor.md" | head -20')
```

**Used `bash grep`. Not the dedicated Grep tool.**

**The triple irony of this counter-example**:

1. **This very article covered it earlier**: The "Trigger Conditions" section of this Bash article has an explicit "should NOT use Bash" comparison table — the first row is `grep -r "pattern" .` -> should use **Grep tool**. Reason: Grep has output_mode, head_limit; dedicated tools are normalized, no shell escaping.
2. **Series article (4) on Grep+Glob is entirely about this**: "dedicated tools avoid Bash pitfalls" is one of the core arguments of that article.
3. **The series was at article 13**: in other words, "Bash is the fallback, not the first choice" had been restated 13 times — **knowledge and action completely disconnected**.

**Why does this happen?**

I asked Claude and got this explanation:

> Honestly, three reasons:
>
>- **Training data inertia** — `bash grep` is the muscle memory of command-line engineers. Real-world grep usage appears in training corpora at far higher frequency than "Grep tool parameterized calls." AI's first reaction follows high-frequency patterns in training data, not rules just learned.
>- **The illusion of convenience with short commands** — `grep -n xxx file | head -20` is a one-liner; it feels like "no need to construct tool call parameters." This is an illusion: constructing `Grep(pattern, path, output_mode, ...)` is actually very low cost, but **the psychological resistance of "typing a few more fields"** is overestimated in AI decision chains.
>- **Shell escaping pitfalls are themselves Bash's problem** — that grep line used `\|` escaping, which is exactly what the Grep+Glob article warned about. In the Grep tool, you'd just write `"constraint [2-8]"` — much cleaner. But shell inertia led the AI into the very pit the series had already dissected.

**The core lesson of this footnote**:

**Prompt constraints alone are not enough — facing deep-rooted inertia in AI training data, only runtime hard blocks can truly override.**

Looking back at which constraints in Claude Code are **actually followed**:

- **Edit requires Read first** — runtime hard block, error without reading
- **Plan mode narrows the tool allowlist** — runtime hard block, Edit / Write simply unavailable
- **Read enforces absolute paths** — runtime hard block, relative paths error immediately
- **CronCreate only within session** — runtime hard block, everything cleared when session ends

What these constraints have in common: **AI couldn't violate them even if it tried.**

Conversely, **"prefer dedicated tools over Bash" is a pure prompt constraint** — no runtime hard block, no tool-level validation. "Recommend using Grep" but grep still works fine inside Bash. This kind of "self-discipline" constraint, facing training data inertia, **is a self-discipline judgment by Claude on every single call, and self-discipline will always have leaks**.

**Corollary**: If Anthropic truly wants Claude to stop using Bash for things dedicated tools can do, the most effective approach isn't more prompt text, but **intercepting grep/cat/sed/echo/ls within the Bash sandbox, making them error out with a suggestion to use the dedicated tool**. **Physical impossibility** is the only true impossibility.

**This is also a counter-proof of the assertion from the beginning of this article**: "the greater the capability, the more constraints needed." **The greater Bash's capability, the harder it is to constrain through prompts** — because so much can be done inside Bash that exhaustively listing "what should use dedicated tools" simply can't be completed in a prompt. The series author leaked during the writing process; let alone other AI usage scenarios.

**Question for the reader**: Have you observed when Claude "clearly has a dedicated tool but falls back to Bash"? These scenarios are worth writing into your CLAUDE.md, using **hard constraints** (like hook interceptions) to cage these habits.

---

### Division of Labor with Neighboring Tools

Bash forms a complete contrast with the previous seven tools:

| Dimension | Three Interaction Primitives | Grep + Glob | Read | Edit | Write | Bash |
|---|---|---|---|---|---|---|
| Positioning | Collaborative alignment | Locating coordinates | Perceiving externals | Precise execution | Full execution | Command execution |
| Capability boundary | Limited, structured | Limited, search | Limited, read | Limited, replace | Limited, overwrite | **Infinite** |
| Primary role | Aligning with user | Locating files | Perceiving files | Modifying files | Writing files | **Changing the real world** |
| Risk surface | Low | Low | Low | Medium | Medium-high | **High** |
| Constraint style | Interaction rules | Parameter constraints | Prerequisite constraints | Uniqueness + Read | Read + directory | **Massive hard constraints at prompt level** |

The first seven tools are all primitives for "operating on files." Bash is the only tool that can take changes and **send them into the real world** for validation and delivery — running tests, committing, pushing, PRs, deploying all depend on it. A typical workflow is `Glob -> Grep -> Read -> Edit -> Bash run tests -> Bash commit -> Bash push`: the first five steps modify the filesystem; Bash is responsible for closing the loop into engineering processes.

---

### Summary

Bash's signal distribution is **extremely skewed toward the tool-level description**:

- **Naming** — one word; `Bash` makes clear "hand to a real shell for parsing," not called `Exec` to avoid implying structured argv. At the field level, one `dangerouslyDisableSandbox` appears, with the prefix carved right into the name as a deterrent
- **Tool-level description** — **the longest layer of this tool**. One-sentence core positioning + counter-example allowlist (cat/head/tail/sed/awk/echo) + general notes (quoting / avoid cd / anti-polling / find pitfalls) + git safety protocol (amend / add -A / commit timing) + PR creation workflow (all commits / 70 characters / return URL) + HEREDOC convention
- **Field-level description** — 5 fields, each with non-trivial design behind it (description dual-channel expression / run_in_background non-blocking async / dangerously naming deterrent)
- **Schema validation** — minimal; only basic type constraints like timeout upper bound, booleans, strings. Real constraints are half persuaded in the tool description, half caught by harness runtime

This distribution forms a stark contrast with Edit / Read — Edit / Read "block through runtime state machines," Bash "persuades through natural language." And as "An Interesting Footnote" revealed: **prompt constraints alone are not enough** — facing deep-rooted inertia in AI training data, every call is Claude's self-discipline judgment, and self-discipline will always have leaks. To truly cage these habits, you can only rely on runtime hard constraints like hooks / sandbox interception. This is the core insight that Bash, as a catch-all general-purpose tool, leaves to the entire tool ecosystem.

And as "An Interesting Footnote" revealed: **prompt constraints alone are not enough** — facing deep-rooted inertia in AI training data, every call is Claude's self-discipline judgment, and self-discipline will always have leaks. To truly cage these habits, you can only rely on runtime hard constraints like hooks / sandbox interception. This is the core insight that Bash, as a catch-all general-purpose tool, leaves to the entire tool ecosystem.

The next article continues with [Agent](agent.md) — the most unique tool in Claude Code: **letting Claude dispatch another Claude to do work**. If Bash breaks Claude past the boundary of "can only edit code," Agent breaks Claude past the boundary of "a single context." Let's see how this "spawn subagent" capability is designed.
