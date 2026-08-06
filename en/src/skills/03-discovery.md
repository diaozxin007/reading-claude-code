# 03 · Capability Discovery · From a Directory to Claude's Candidate List

> **TL;DR**: Before a Skill can enter Claude's candidate list, it must pass through filesystem discovery, scope merging and name-collision handling, and then path- and invocation-visibility filtering. Personal, project, managed, and Plugin are not just four installation locations — they express personal habit, project capability, organizational governance, and distributable components, respectively. Nested Skills and `paths` further narrow "available to the project" down to "relevant only when working in a given directory or file."

The previous piece, [02 · Progressive Disclosure · From Description to Full Instructions](02-progressive-disclosure.md), looked inside a single Skill and its three loading layers: metadata for discovery, full instructions that appear on activation, and supporting resources that expand on demand.

But where does the metadata come from? Claude Code doesn't scan every `SKILL.md` on the machine. It first has to answer a more fundamental question:

> **For a session started from the current working directory, which Skills are even eligible to become candidate capabilities?**

## "Discovery" Actually Has Three Gates

A user creating a Skill on disk doesn't mean Claude already knows how to use it. There are at least three layers of judgment in between:

```text
Filesystem discovery
  Is this location a Skill scope that Claude Code actually reads?
        ↓
Candidate capability exposure
  Is this Skill allowed to appear in Claude's capability catalog?
        ↓
Task matching and activation
  Should the current request trigger loading its full instructions?
```

These three layers are often lumped together as "automatic discovery":

- If the file is in the wrong location, the first layer never applies;
- If a Skill is restricted to manual user invocation, the file exists but doesn't need to be exposed to the model;
- If the description doesn't match the current task, Claude knows the Skill exists but simply doesn't choose it;
- If the path conditions aren't met, the Skill exists in the project but isn't relevant to the current file.

So when debugging "why didn't this Skill trigger," repeatedly tweaking the description isn't the right first move. First confirm whether it actually made it into the candidate list.

## Four Scopes, Four Authorship Relationships

Claude Code's official documentation lists four main sources:

| Scope | Typical location | Maintained by | Applies to |
|---|---|---|---|
| Enterprise / Managed | Organization-managed location | Administrators | All users in the organization |
| Personal | `~/.claude/skills/<name>/SKILL.md` | Current user | All of the user's local projects |
| Project | `.claude/skills/<name>/SKILL.md` | Project team | The current project |
| Plugin | `<plugin>/skills/<name>/SKILL.md` | Plugin author | Environments where the Plugin is enabled |

These look like four file paths, but they actually express four different kinds of capability ownership.

### Personal · My General Way of Handling Things

Personal Skills suit capabilities that get reused across projects but don't need to be installed by the whole team:

- A personal code review workflow;
- A self-maintained note-organization method;
- Cross-repo commit message generation;
- Wrapping operations around a toolchain already set up on the local machine.

It follows the user, not the repository. Teammates who clone the project won't automatically get it.

### Project · A Practice the Repository Shares

Project Skills can go into version control alongside the code:

- The current repo's release checklist;
- Project-specific database migration workflows;
- How internal architecture docs get generated;
- Validation workflows tied to the current test framework.

This expresses "anyone working on this project might need this capability." Project scope isn't just convenient sharing — it also lets Skill changes go through review the same way code does.

### Enterprise · A Capability Provided Centrally by the Organization

Managed Skills suit processes, knowledge, and governance requirements that an organization wants to deploy centrally. Its author and its users are separate: users can invoke it, but they can't necessarily modify the source.

This scope isn't solving individual reuse — it's solving organizational consistency. A later piece on permission governance will revisit this: distributing instructions centrally is not the same as achieving enforcement.

### Plugin · Capability Bundled with an Installable Component

Plugins can bundle Skills together with other extensions. This suits fully productized capability packages:

- Skill instructions;
- Supporting scripts and assets;
- Subagents;
- Hooks;
- MCP server configuration or other Plugin content.

A Plugin Skill's name carries the Plugin namespace. It won't collide directly with a bare name from a personal or project Skill, and users can tell which component a capability comes from.

Choosing among the four scopes should start with "who owns this capability," not "which path is most convenient to write to."

## Scope Is Not a Sync Mechanism

Putting a Skill into personal scope only means it's available for the current user's local projects — it does not mean it will automatically sync to other devices or Claude surfaces.

Likewise:

- A project Skill propagates along with the Git repository, provided the file is committed;
- A Plugin Skill propagates through the Plugin's own install and versioning mechanism;
- A local Claude Code Skill does not automatically become a Skill in the Claude API or on claude.ai;
- A cloud session doesn't automatically mean it can read the local machine's `~/.claude/skills/`.

Scope answers "who should see this within a given product environment"; sync answers "how the file gets to that environment." A single personal / project label can't substitute for both.

## Project Discovery Doesn't Just Look at the Current Directory

In a monorepo, or when Claude Code is launched from a subdirectory, only reading the current directory's `.claude/skills/` creates an obvious problem — if the user starts a session in `repo/apps/web/`, should the release Skill at the repo root still be available? Claude Code's answer is yes: it walks upward from the starting directory to look for project Skills, all the way to the repository root:

```text
repo/apps/web/       ← session start
      ↑ walk up parent directories
repo/apps/
      ↑
repo/                ← repository root
└── .claude/skills/release-check/  ← project-level capability
```

This means which subdirectory a session starts from doesn't change the root project's shared capabilities.

But walking upward only solves inheritance. Monorepos also have the opposite need: a specific package may own a Skill that's only relevant to itself.

## Nested Skills · Capability Appears Along with the Subdirectory

Suppose the frontend package has its own independent deployment workflow:

```text
repo/
├── .claude/skills/deploy/
│   └── SKILL.md
└── apps/web/
    ├── .claude/skills/deploy/
    │   └── SKILL.md
    └── src/
```

The root `deploy` represents the project's default workflow, and the same-named Skill under `apps/web` represents the frontend variant. If a session recursively scanned the entire monorepo the moment it started, any dependency directory, sample project, or package could stuff its own capability into the candidate list.

Claude Code discovers nested Skills based on the working path: only when a task starts touching files inside a given subdirectory does it discover the `.claude/skills/` within that path's scope.

This creates a kind of path proximity:

```text
Only editing repo/backend/
  → the apps/web Skill doesn't need to appear

Starting to work on repo/apps/web/src/
  → apps/web/.claude/skills/ becomes a relevant candidate
```

A nested Skill isn't "a higher-priority, project-wide configuration" — it's "local capability that only becomes meaningful once you enter that directory."

## Why Same-Named Capabilities Can't Simply Override Each Other

Same-named Skills across personal, project, and organizational scope need a defined precedence relationship. The official docs give this order:

```text
Enterprise
   ↓ override
Personal
   ↓ override
Project
```

This order reflects the relationship between governance and individual control — but nested project variants face a different problem. A `deploy` Skill at the root and one inside a package can both be valid; you can't just silently eliminate one workflow because it's "farther away."

Claude Code provides directory-qualified names for nested variants. For example, the root can still be invoked as `/deploy`, while a subdirectory variant can be explicitly called through a qualified name like `/apps/web:deploy`.

This preserves an extra layer of information compared to a simple override:

- A bare name represents the project's main entry point;
- A qualified name indicates which directory a capability belongs to;
- Claude can decide whether the related variant is still applicable based on which files it's currently working with.

Same names don't always mean conflict. Sometimes they represent a global workflow being supplemented differently in different packages. The naming mechanism needs to preserve these variants first, and let the current working path determine how they combine.

Plugins avoid competing for bare names with other scopes altogether by using the `plugin-name:skill-name` namespace.

## `paths` · Defining Relevance Without Duplicating Directories

Not every path-relevant capability is worth rebuilding as a separate Skill in a subdirectory. An API review Skill might live at the project root but only be automatically relevant when working with backend interface files:

```yaml
---
name: api-review
description: Review this project's API design and compatibility
paths:
  - "services/api/**"
  - "packages/contracts/**"
---
```

`paths` separates two concerns:

- **Capability ownership**: it's still a Skill maintained by the whole project;
- **Automatic relevance**: it should only activate when a task touches matching paths.

Nested Skills and `paths` therefore solve different problems:

| Mechanism | Suited for |
|---|---|
| Nested Skill | A subdirectory owns an independent capability package or local variant |
| Root Skill + `paths` | Maintained jointly by the project, but only serving a specific file range |

`paths` is not a file access permission. It affects when a capability is considered relevant; it doesn't constitute a sandbox or prevent Claude from reading other files. Treating path activation as a security boundary overestimates how much governance the frontmatter can actually provide.

## The Skill Exception for `--add-dir`

`--add-dir` is normally used to give Claude access to an additional directory. Claude Code applies a special treatment to Skills here: `.claude/skills/` inside an added directory can automatically enter capability discovery.

This suits maintaining shared capabilities separately from the main repo:

```text
product-repo/

shared-engineering/
└── .claude/skills/
    ├── incident-review/
    └── architecture-check/
```

Adding `shared-engineering` at startup lets the session use the Skills inside it. This exception shouldn't be generalized into "everything in an added directory's Claude configuration gets loaded automatically." The official docs explicitly distinguish Skills from other configuration types like CLAUDE.md, subagents, commands, and output styles.

This again shows that Skill discovery is its own capability-registration mechanism, not just ordinary file reading.

## Live Detection · The Candidate List Can Change Mid-Session

When developing a Skill, having to restart Claude Code after every edit would make iteration painfully clumsy. Claude Code watches Skill directories that are already within the discovery scope for:

- New Skills added;
- Changes to `SKILL.md`;
- Skills deleted;
- Updated candidate descriptions.

These changes are usually picked up within the current session. One edge case: if the top-level skills directory didn't exist at all when the session started, and the whole directory is created later, the runtime hasn't pre-watched that location — a restart may be needed.

Live detection solves "updating candidate capabilities after the on-disk definition changes." It doesn't mean old instructions already loaded into the conversation get rewound and replaced. File definition, candidate listing, and current context are three distinct states. Piece 08 will cover Skill lifecycle in detail.

## Symlinks · Shared Files Shouldn't Produce Duplicate Capabilities

Personal, project, and managed Skills can use symlinks pointing to other directories, making it convenient to reuse the same capability package across multiple locations.

But symlinks raise two questions:

1. Do multiple paths actually point to the same Skill?
2. Is the link target still within a trusted and accessible boundary?

Claude Code avoids loading the same target repeatedly just because multiple paths point to it. Symlinks inside a Plugin follow the Plugin's own distribution rules and can't simply be treated like local Skill behavior.

For authors, symlinks are better suited to individual development or a unified source directory. When stable distribution across a team is needed, a Plugin or explicit project version control is usually easier to review.

## The Candidate List Is Not the Disk List

After going through all the above paths, the "Skills that can be found" on disk still won't all be presented to Claude in the same way:

- Skills restricted to manual user invocation don't need to lure the model in through the description;
- Skills whose path conditions aren't yet met are temporarily irrelevant;
- Nested Skills whose directory hasn't yet been touched haven't been discovered yet;
- Some capability may be hidden by a local visibility setting;
- Multiple sources may get reorganized based on precedence, namespace, or qualified names.

So the candidate list is a **capability view** constructed at runtime based on the current session:

```text
Skill definitions on disk
        ↓ scope / parent / nested / add-dir
Discoverable set
        ↓ precedence / namespace / path / visibility
Current candidate list
        ↓ description and the user's request
Actually activated Skill
```

Only by separating these four layers can you tell whether a problem lies with installation, scope, exposure, or matching. Skill discovery is therefore not a single `find SKILL.md` — **scope determines ownership, parent/nested determines where inheritance comes from, namespace determines how things coexist, and paths determines when something is relevant**. Only after entering this list does the description get a chance to complete the first layer of routing discussed in the previous piece.

## Next Up

The candidate list has now been built — the next step brings us back to the part that really behaves "like a Tool": when a user types `/release-check` versus when Claude proactively chooses `release-check`, do they follow the same invocation path? The next piece, [04 · Capability Invocation · From User Request to Skill Activation](04-invocation.md), will break down the boundaries between manual invocation, model invocation, bundled skills, and built-in commands.

## References

- Anthropic Claude Code official documentation: [Where skills live](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Discovery from parent and nested directories](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Skills from additional directories](https://code.claude.com/docs/en/slash-commands)
- Anthropic Platform official documentation: [Cross-surface availability and sharing scope](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Previous piece: [02 · Progressive Disclosure · From Description to Full Instructions](02-progressive-disclosure.md)
- [01 · The CLAUDE.md Family · 5-Layer Hierarchy and 3 Mixing Patterns](../memory/01-claude-md-family.md)
