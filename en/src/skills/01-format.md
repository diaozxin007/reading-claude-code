# 01 · Capability Format · From a Single Markdown File to a Portable Folder

> **TL;DR**: The Agent Skills standard defines a portable folder: `SKILL.md` handles discovery and core instructions, `references` hold on-demand knowledge, `scripts` handle deterministic operations, and `assets` provide templates and output materials. Claude Code adopts this core format while adding fields related to invocation, execution, permissions, and paths. When designing a Skill, write the portable core first, then be explicit about which behaviors depend on Claude Code.

The previous piece, [00 · Opening · From Repeated Pasting to Callable Capability](00-intro.md), placed Skill back into the capability stack: it participates in selection like a Tool, but once activated it doesn't enter an independent executor — instead it loads a set of operational knowledge to orchestrate existing Tools.

Now let's turn to disk. Why isn't a Skill a single `deploy.md` file, but instead a whole folder?

## A Single Markdown File Quickly Runs Into Three Kinds of Content

Suppose you're building a `release-check` Skill. At first it's just four steps:

```markdown
1. Check the workspace
2. Run tests
3. Verify the changelog
4. Summarize risks
```

Keep using it, and three new categories of content quickly show up:

- A detailed versioning specification that Claude needs to consult;
- A script that checks the version number, which Claude needs to execute;
- A release report template that Claude needs to copy and fill in.

If all of this gets crammed into a single Markdown file, the specification, procedure, and template all get loaded alongside the core workflow. Readers struggle to tell which parts are the main thread to follow every time, and which are just materials needed only in specific situations.

Agent Skills doesn't define a Skill as "a Markdown file" — it defines it as "a folder with `SKILL.md` as its entry point":

```text
release-check/
├── SKILL.md
├── scripts/
│   └── validate-version.sh
├── references/
│   └── version-policy.md
└── assets/
    └── release-report.md
```

These four locations aren't simply organized by file extension. They represent four distinct roles:

| Location | Role | How Claude uses it |
|---|---|---|
| `SKILL.md` frontmatter | Capability index | Determines whether this capability is relevant |
| `SKILL.md` body | Core instructions | Enters context upon activation |
| `references/` | On-demand knowledge | Read when the corresponding issue arises |
| `scripts/` | Deterministic operations | Executed when needed, without loading full source into context |
| `assets/` | Templates and resources | Copied, transformed, or used in the final deliverable |

The folder is thus simultaneously a **capability manual** and a **package of working materials**.

## `SKILL.md` Is the Entry Point, Not the Repository

`SKILL.md` shoulders at least three responsibilities:

1. Using metadata to state "who am I, when should I be used";
2. Using the body to state "what to do first upon activation, how to judge";
3. Providing navigation for supporting files, telling Claude when to read or execute them.

The third point is easy to overlook. Placing `version-policy.md` under `references/` doesn't automatically make Claude understand its purpose. The entry file still needs to spell it out:

```markdown
## Supporting resources

- When judging whether a version number is valid, read `references/version-policy.md`
- When mechanical validation is needed, run `scripts/validate-version.sh`
- When generating the final report, use `assets/release-report.md`
```

The key here isn't listing the directory contents — it's providing the **reading conditions**. A Skill's progressive disclosure depends on navigation: only the entry point knows what resources exist, and only then can Claude continue expanding at the right moment.

So `SKILL.md` shouldn't turn into a repository of all knowledge — it's more like a map. `description` decides when someone opens it; the body tells you where to start, which fork in the road requires which resource; `references`, `scripts`, and `assets` are just the side roads marked on the map — they don't need to be moved into the body ahead of time. A map that's too short leaves Claude not knowing how to proceed; a map that draws in every roadside detail defeats the purpose of progressive disclosure.

## The Open Standard Only Locks Down the Portable Core

The Agent Skills open specification requires `SKILL.md` to consist of YAML frontmatter and a Markdown body. The standard core is small:

```yaml
---
name: release-check
description: Checks whether a version is ready for release — used when preparing a release
---
```

Where:

- `name` provides a stable identity;
- `description` explains both what it does and when to use it;
- The Markdown body holds the instructions;
- `scripts/`, `references/`, `assets/` are conventional roles that can exist as needed.

The standard also provides optional metadata like `license`, `compatibility`, `metadata`, and the experimental `allowed-tools`. These address problems that remain meaningful across clients: licensing, runtime environment requirements, additional identifiers, and tool pre-authorization.

The open specification deliberately doesn't define Claude Code's interface, subagent types, or session lifecycle. The same `release-check` folder, dropped into a different agent product, can still tell it "how to do this" — but where to discover this folder, how to surface the metadata to the model, how to trigger activation, what environment `validate-version.sh` runs in, and how to handle its output — the specification doesn't govern any of that; each host decides for itself.

This is the boundary between **format standard** and **product runtime**.

## What Claude Code Adds on Top of the Standard

Claude Code doesn't just read a generic `SKILL.md` — it wires it into its own commands, Tools, subagents, hooks, and permissions system. As a result, more product-specific fields show up in the frontmatter.

These extensions can be grouped into four categories by the problem they solve:

| Problem | Direction of Claude Code's extension |
|---|---|
| Who can invoke it | User invocation, model invocation, and visibility control |
| Where it executes | Current conversation or forked subagent |
| What input it carries | arguments, dynamic context, shell selection |
| What it's allowed to do | Tool pre-authorization, tool exclusion, hooks and path conditions |

For instance, a deployment Skill might require that it only be triggered manually by the user; a code research Skill might run in an independent subagent context; a Skill that only serves a frontend directory might set path conditions. All of these are useful, but they are not behaviors guaranteed uniformly across all Agent Skills clients.

So the same file actually contains two layers of protocol:

```text
Agent Skills standard core
  name · description · instructions · supporting files
        ↓ interpreted by the host
Claude Code product extensions
  invocation · fork · paths · hooks · permissions · shell ...
```

Writers need to know which layer they're depending on. Otherwise "works in Claude Code" is easily miswritten as "this is standard Agent Skills behavior."

## A Seemingly Contradictory `name`

The open specification treats `name` as required metadata and requires it to match the parent directory name. Claude Code's local Skills, by contrast, can derive their command identity from the directory name, so the official product documentation allows `name` to be omitted — treating it more as a display field.

This isn't a matter of one being right and the other wrong — the two are asking different questions:

- The open format asks: once this folder leaves its current host, how does it retain a verifiable identity?
- Claude Code asks: within a known local directory structure, which `/skill-name` should the user type?

A personal Skill that only serves Claude Code can rely on directory-name derivation. A Skill meant for cross-client distribution should still explicitly write out a `name` and `description` that conform to the open specification.

This principle also applies to other extension fields:

> **Write the portable core explicitly, add product extensions as needed, and don't let extension fields carry core semantics.**

For example, "must wait for user confirmation before deploying" should appear in the body instructions — it shouldn't rely solely on some host's manual-invocation toggle. The invocation toggle provides additional protection; the instructions retain the semantics of the workflow itself.

## Scripts Don't Turn a Skill Into a Tool

A Skill can carry scripts, but that doesn't mean the boundary between Skill and Tool disappears.

A Tool is typically registered by the host, with a clear invocation interface, permission identity, and return protocol. A script inside a Skill is implementation material bundled with that capability — Claude still needs to decide, based on the instructions, when to run it through an existing code execution capability.

The relationship is closer to this:

```text
Skill instructions
  "First check the version file"
        ↓
Existing execution capability
  Bash / code execution
        ↓
Skill bundled script
  scripts/validate-version.sh
```

Scripts are well suited to steps with clear inputs and outputs, where repeated runs should produce stable results. Instructions are better suited to contextual judgment, exception handling, and workflow orchestration.

If all deterministic logic is written as natural language, every execution depends on the model re-interpreting it. If the entire workflow is hardcoded into a single script, Claude loses the ability to handle context and exceptions. The Skill folder allows the two to be combined, rather than forcing a choice between them.

## Assets Are Not References for Claude to Read

Both `references/` and `assets/` may hold Markdown, JSON, images, or templates — the distinction isn't file format, but purpose:

- A reference is material read **to help Claude make a judgment**;
- An asset is material used **to produce the final deliverable**.

For example, an API specification belongs in references; a report template belongs in assets. Claude may read both, but the former feeds into reasoning, while the latter feeds into producing the output.

This distinction helps when reviewing a Skill:

- Updating a reference may change Claude's judgment;
- Updating an asset mainly changes the shape of the output;
- Updating a script may change deterministic operations;
- Updating `SKILL.md` may change the entire invocation and execution flow.

A folder thereby gains change boundaries far clearer than "a prompt version number."

## Why Custom Commands Are Merging Into Skills

An old-style custom command could already expose a Markdown file as `/deploy`. From a user's perspective, it already had the core capability of "saving a reusable prompt."

Skills build on top of that by adding three structural elements:

1. The description participates in automatic model discovery;
2. The folder can carry supporting files;
3. The frontmatter can express a more complete invocation and execution model.

So Claude Code continues to support the old commands while positioning Skills as the recommended direction going forward. This isn't renaming the slash command — it's expanding "the user actively expands a prompt" into "a capability package that either the user or the model can discover."

But not every built-in command can be fully equated with a Skill. Some commands directly trigger internal product logic, whereas bundled skills mainly provide instructions and orchestrate Tools. The two may share a `/name` entry point while their underlying execution semantics remain different.

The open standard makes a capability package recognizable; the product runtime makes it actually participate in a session — this boundary runs through every comparison made in this piece: which parts of the folder are the portable core, and which parts Claude Code has added on its own. Both layers matter, and they shouldn't be conflated into one.

## Next Up

The folder structure solves "where content lives," but not yet "why Claude doesn't read everything at the start of a session." The next piece, [02 · Progressive Disclosure · From Description to Full Instructions](02-progressive-disclosure.md), continues along the three layers of metadata, instructions, and resources, examining how a Skill trades off context cost against capability visibility through different loading moments.

## References

- Agent Skills open specification: [Specification](https://agentskills.io/specification)
- Anthropic Platform official documentation: [Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Anthropic Claude Code official documentation: [Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Previous piece: [00 · Opening · From Repeated Pasting to Callable Capability](00-intro.md)
- [Tool Mechanism: How Claude Uses Tools](../tool-mechanism.md)
