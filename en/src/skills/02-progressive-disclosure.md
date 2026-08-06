# 02 · Progressive Disclosure · From `description` to Full Instructions

> **TL;DR**: A Skill doesn't save context just because its files sit on disk — it achieves progressive disclosure through three distinct loading decisions. First, every Skill competes to be discovered using only its metadata. Once selected, the full `SKILL.md` is loaded. Only when the actual work demands it does Claude go on to read references or run scripts. Each layer must give the next layer a clear trigger condition, or content gets loaded too early — or worse, a capability exists but is never invoked at all.

The previous post, [01 · Capability Format · From a Single Markdown File to a Portable Folder](01-format.md), broke a Skill down into entry point, references, scripts, and assets. The files are separated — but splitting files by itself saves no tokens.

What actually determines cost is **which content enters Claude's view, and when.**

## What If Everything Loaded at Startup

Suppose a team has installed 40 capabilities:

- release checks;
- API design conventions;
- incident investigation;
- database migrations;
- frontend accessibility review;
- PDF, spreadsheet, and slide-deck processing;
- plus operational procedures for various internal systems.

If Claude read all 40 `SKILL.md` files and every reference at the start of every session, then even a task as small as tweaking a button would drag along the release process, the database manual, and the incident runbook.

This creates two problems:

1. **Cost** — content unrelated to the current task occupies context up front.
2. **Attention** — with multiple procedures present at once, the model has a harder time judging which one actually applies right now.

The opposite extreme is telling Claude nothing at startup and waiting for the user to type `/skill-name` exactly. That saves context, but Claude has no idea the capability exists and can't proactively use it on a relevant task.

Agent Skills takes the middle path: give Claude a capability catalog up front, then expand progressively based on relevance.

## Three Layers Aren't Three Directories — They're Three Decisions

The official docs describe Skill progressive disclosure as three layers:

```text
Level 1 · Metadata
  name + description
  Discovery info for every candidate Skill
          ↓ Does this capability match the current task?

Level 2 · Instructions
  Full SKILL.md body
  Operational knowledge to follow once activated
          ↓ Does the current step need more material?

Level 3 · Resources and code
  references / scripts / assets
  Read, executed, or used on demand
```

"Three layers" doesn't mean files must sit in three fixed directories — it means one act of using a capability is broken into three decisions made at different granularities:

1. Select the relevant Skill from among all capabilities;
2. Obtain the core working method from the relevant Skill;
3. Select, from within the capability package, the specific material the current step needs.

Each step down adds more information — and more context cost. So each layer must give Claude enough clues to decide whether expanding further is worthwhile.

## Layer One · `description` Is a Router, Not a Summary

`description` is often written like marketing copy:

```yaml
description: Helps you do releases better
```

A human can infer the meaning from the Skill's name and the team's context. Claude, facing dozens of candidate capabilities, has no such basis for matching. "Better" doesn't say what the Skill does; "releases" doesn't say which requests should trigger it.

An effective description must answer at least two questions: **what can this Skill accomplish, and when — what tasks or user phrasing — should it be used?** For example:

```yaml
description: Checks whether a code version is ready for release. Use when the user is preparing a release, requesting a pre-release check, or asking about version risk.
```

It doesn't cram the full process into metadata, but it does give a matchable task and trigger context — when a user asks "is this version ready to ship," this description is the matching condition that routes that sentence to release-check and expands the full instructions.

So the goal of a description isn't "accurately summarize the whole document" — it's **routing the right request to the right capability.**

### Two Ways a Description Can Fail

**Too narrow**:

```yaml
description: Use when the user types "run release-check"
```

Only near-exact phrasing triggers it, and automatic discovery loses its value.

**Too broad**:

```yaml
description: Use when related to code quality
```

Nearly every coding task could trigger it, turning an occasionally-used capability into constant noise.

A good description isn't a pile of keywords — it draws the boundary between recall and precision: don't miss relevant tasks, but don't let adjacent-but-different tasks slip in either.

## Metadata Cost Is Small, but Not Zero

Progressive disclosure is often oversimplified as "no cost until invoked." A more accurate statement is:

> **When not invoked, you only pay the discovery cost — not the cost of the full instructions and supporting resources.**

Claude must see the name and description of every candidate Skill to make a selection. So the more Skills installed and the longer each description, the larger the capability catalog itself grows.

This shapes how metadata should be written:

- put the most critical use case first;
- don't explain background history in the description;
- don't copy the full procedure into it;
- avoid multiple Skills using near-identical broad descriptions;
- use stable, task-oriented language — not internal team slogans only the author understands.

Metadata is a long-standing **indexing tax**. Each entry is small, but as the count grows, it becomes an architectural concern.

## Layer Two · `SKILL.md` Is the Control Surface After Activation

Once a Skill is selected — by the user or by Claude — the full `SKILL.md` body enters the current work. At that point it's no longer responsible for "attracting invocation"; it needs to take charge of execution direction.

The core body is a good place for:

1. this Skill's goal and completion criteria;
2. constraints that must be respected;
3. the main workflow and key decision points;
4. when to read which reference;
5. when to run which script;
6. output format and how to verify it.

For example:

```markdown
## Workflow

1. Check the workspace for unexpected changes
2. Run the project's standard tests and build
3. Read the version file and changelog
4. If the version format is unclear, check `references/version-policy.md`
5. Summarize blocking issues and non-blocking risks
6. Wait for user confirmation — do not release directly
```

The value of the body isn't "write it in as much detail as possible" — it's establishing a decision skeleton stable enough to rely on. Cramming every edge case into the body lets a handful of rare situations hijack every activation. Writing only a one-line goal leaves Claude to improvise the workflow on the spot.

So `SKILL.md` is better thought of as a control surface — goal, main workflow, decision points, resource navigation, and verification. Getting those five things clear is enough; it doesn't need to be an exhaustive manual.

## Activation Cost Can Span Beyond the Current Step

An ordinary prompt usually serves only the current user message. Once a Skill's instructions are loaded, they may need to keep influencing the task across several subsequent turns.

That means every paragraph in the body can't be measured purely as "cost of a single read." If a Skill stays active for the rest of the conversation, verbose background, repeated examples, and irrelevant explanations keep consuming context as the task continues.

So the body and the description optimize for opposite goals:

| Layer | Primary goal | Should not carry |
|---|---|---|
| description | Precisely identify when to activate | Full execution steps |
| SKILL.md body | Reliably guide the work after activation | Every low-frequency detail |
| supporting files | Provide details needed for specific branches | Global trigger judgment |

If the same sentence shows up in all three layers, that usually means the boundaries haven't been drawn clearly yet.

## Layer Three · Supporting Resources Need Their Own Second-Pass Routing

Once a Skill is activated, Claude already knows it's doing a release check. But it may not need to read the full version spec:

- the version number clearly follows the existing format → don't read it;
- there's a prerelease marker or a special branch → read it;
- only a report needs to be generated → use the template;
- a mechanical check is needed → run the script.

This is the Skill's internal second layer of routing:

```text
SKILL.md decision points
  ├─ Format is ambiguous → references/version-policy.md
  ├─ Mechanical validation needed → scripts/validate-version.sh
  └─ Generate deliverable report → assets/release-report.md
```

The value of references isn't "you can put unlimited content there" — it's deferring large content to the correct branch. If the entry point just says "see references for more" without specifying which content applies to which task, Claude still won't know what's relevant.

Good resource navigation should answer:

- what does this file contain;
- under what condition should it be read;
- how should it be applied once read;
- does the task need only a partial lookup, rather than loading the whole file.

Supporting files don't automatically become on-demand just because they're split out of the body. **On-demand loading comes from clear decision boundaries, not from directory names.**

## What a Script Saves Is Instruction Ambiguity — Not a Guarantee of Cheap Results

A script lets Claude perform a stable operation without reading the implementation source. This is usually more reliable than re-deriving an algorithm from natural language.

But executing a script still produces output. If a validation script prints a hundred thousand lines of logs, even though the source code never entered context, the output alone can still drown out the current task.

So scripts must also follow progressive disclosure:

- default to summary output, with details written to a file;
- on failure, give localized diagnostic info rather than dumping the entire intermediate state;
- support narrowing scope by target, file, or phase;
- let Claude decide, based on the result, whether to read further detail.

Progressive disclosure governs not just "which files get read," but also "how much information gets returned after execution."

## Directory Size Doesn't Equal Context Size

A Skill folder can be large without immediately consuming much context:

```text
20 MB of references on disk
  ≠
20 MB of context in the current request
```

As long as the entry point navigates accurately, unread material stays on disk. Conversely, a `SKILL.md` that's only 30 KB but is fully loaded into the conversation on every activation can actually cost more than a large-but-on-demand capability package.

So auditing a Skill can't be based on folder size alone. At minimum, look at these separately:

| Metric | Corresponding risk |
|---|---|
| Total metadata size | Fixed cost of every discovery pass |
| `SKILL.md` size | Baseline cost of every activation |
| How references are read | Incremental cost of specific branches |
| Script output volume | Cost of the execution result |
| Number of simultaneously active Skills | Competition and accumulation of multiple sets of instructions |

This is a layered ledger — not a single "how many KB is the whole folder" number.

## Loading Timing Compared with CLAUDE.md

CLAUDE.md and Skill can both hold instructions, but the first difference isn't content type — it's default loading timing:

| Carrier | Default timing | Suited content |
|---|---|---|
| CLAUDE.md | At session start or on path access | Broadly applicable project rules and facts |
| Skill metadata | Discovery phase for candidate capabilities | What this capability does and when to use it |
| Skill body | After Skill activation | The complete method for a class of tasks |
| Skill resources | When the workflow needs it | Large references, templates, scripts |

If a section of CLAUDE.md keeps growing into a multi-step procedure, that's often a sign it doesn't need to be resident for every task — it can be migrated into a Skill. If a Skill is inevitably activated on every single task, that may signal some of its constraints should actually be promoted to standing project rules.

The choice of carrier isn't about Markdown syntax — it's about **whether the scope of applicability matches the loading timing.**

## Progressive Disclosure Isn't "Splitting a Long Document into Multiple Files"

It lets each layer solve exactly one selection problem:

```text
description
  Choose which capability

SKILL.md
  Choose how to move the task forward

supporting resources
  Choose the material and execution needed for the current branch
```

Only when there's a clear entry condition between all three layers can a Skill remain **discoverable, executable, and low-cost to keep resident.**

## Coming Up Next

Progressive disclosure assumes Claude already has a candidate capability catalog in hand. But personal, project, parent, nested, and additional directory Skills — plus Plugin Skills — don't all come from the same place. The next post, [03 · Capability Discovery · From a Directory to Claude's Candidate List](03-discovery.md), will answer: **which Skills show up in the current session, and how is scope determined when Skills share a name or depend on path?**

## References

- Agent Skills official overview: [How do Agent Skills work?](https://agentskills.io/home)
- Agent Skills open specification: [Progressive disclosure](https://agentskills.io/specification)
- Anthropic Platform official docs: [How Skills work](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Anthropic Claude Code official docs: [Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Previous post: [01 · Capability Format · From a Single Markdown File to a Portable Folder](01-format.md)
- [00 · Introduction · Claude Code's 200K Ledger](../context-management/00-intro.md)
