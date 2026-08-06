# 09 · Distribution · From Personal Folder to Team Plugin

> **TL;DR**: Personal, project, Plugin, and managed are not a four-level inheritance stack for the same Skill — they are four distribution contracts. Personal suits fast local iteration, project lets a capability travel through repository review, Plugin provides namespacing, versioning, and multi-component packaging, and managed handles unified organizational deployment. The Agent Skills format is recognizable across products, but storage, runtime environment, and sharing scope remain independent across Claude Code, the Claude API, and claude.ai.

The previous piece, [08 · Lifecycle · From a Single Load to Compaction](08-lifecycle.md), looked at how a Skill survives within a session. This piece stretches the timeline further: how does a personal workflow written today at `~/.claude/skills/` get handed to a team tomorrow, and turned into an installable component the day after?

The simplest approach is to copy the folder:

```text
cp -r ~/.claude/skills/release-check teammate-machine/
```

The content does make it across, but new problems appear quickly:

- Which copy is the authoritative version?
- Who is responsible for updates?
- How do same-named Skills avoid colliding?
- What environment do the scripts depend on?
- How do Hooks, agents, and MCP configuration get installed together?
- How does the team review permission changes?
- Can a Claude Code version be uploaded directly to the API or to claude.ai?

The object of distribution isn't a folder copy — it's the **maintenance and trust relationship** around a capability.

## Four Distribution Contracts

| Approach | Source of truth | How it updates | Best for |
|---|---|---|---|
| Personal | User's local directory | Personal edits | Experiments, personal habits, private cross-project workflows |
| Project | Git repository `.claude/skills/` | Project PRs / commits | Repo-specific capabilities shared by the team |
| Plugin | Plugin package and version | Install, upgrade, marketplace | Cross-project, cross-team, multi-component capabilities |
| Managed | Organization-managed configuration | Centralized admin deployment | Organization-wide capabilities and governance requirements |

They aren't necessarily a ladder to climb rung by rung. A migration Skill specific to one repo can stay at project forever; a Skill for a public tool can be designed as a Plugin from day one.

The real question to ask is:

```text
Who is the author?
Who are the users?
Who approves updates?
How are new versions obtained?
What other components does the capability depend on?
```

## Personal · The Fastest Test Bed

A personal directory is a good place to distill a first version of a Skill out of repetitive work:

```text
~/.claude/skills/release-check/
├── SKILL.md
└── scripts/
```

Advantages:

- Fast to modify;
- Doesn't affect the team;
- Description can be tested across multiple local projects on the same machine;
- Good for observing actual triggering behavior and output quality.

The drawbacks are equally clear:

- Teammates don't have it;
- It may not exist when you switch machines;
- No natural PR review;
- Easy to accidentally depend on the author's local CLIs, paths, and credentials;
- Update history may only live in file modification timestamps.

A Personal Skill should be treated as a personal capability configuration, not an invisible project dependency. If the team's work visibly breaks without it, the scope has already been chosen wrong.

## Project · Letting a Capability Enter Code Review with the Codebase

Placing a Skill at:

```text
repo/.claude/skills/release-check/
```

and committing it to Git makes it part of the project. New contributors get the same workflow after cloning the repo, and Skill changes can go through code review.

The most important benefit of project distribution isn't "automatic copying" — it's establishing an auditable history:

```text
Why was the release checklist changed?
  → commit / PR context

Who expanded allowed-tools?
  → visible in the diff

Which version started depending on a new CLI?
  → repository history
```

Project Skills suit capabilities tightly bound to facts about the repository itself. If the same Skill is copied into ten repos and each evolves independently, Git can only record ten diverging histories — it can't provide a unified upgrade path.

That's the point at which Plugin should be considered.

## Iterate as Standalone First, Productize as Plugin Later

Anthropic's official Claude Code documentation recommends using standalone configuration for:

- Single-project customization;
- Personal workflows;
- Quick experiments;
- Skills and Hooks that aren't yet stable.

When a capability starts to need:

- Reuse across multiple projects;
- Sharing with a team or community;
- Independent versioning and updates;
- Installation alongside agents, hooks, and MCP servers;
- Marketplace distribution;

it's time to convert it into a Plugin.

This is a maturity path:

```text
Repeated prompt
  ↓
Personal Skill
  ↓ iterated through real tasks
Project Skill
  ↓ boundaries stabilize · reused across projects
Plugin
```

But "becoming a Plugin" isn't a quality certification. It's just switching to a more formal packaging and distribution contract. The content, tests, and security remain the author's responsibility.

## Plugin · More Than a Zipped Bundle of Skills

A Claude Code Plugin can include:

```text
my-plugin/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── release-check/
│       ├── SKILL.md
│       └── scripts/
├── agents/
├── hooks/
├── .mcp.json
├── .lsp.json
├── bin/
└── README.md
```

`.claude-plugin/` holds only the manifest. Skills, agents, hooks, and other components live at the Plugin root — they aren't all stuffed into `.claude-plugin/`.

This structure expresses a higher-level capability:

```text
Skill
  Defines a workflow

Agent
  Defines a specialized worker

Hook
  Defines a deterministic lifecycle action

MCP / LSP
  Provides external and code-intelligence capabilities

Plugin manifest
  Turns them into an installable version
```

Plugin, then, is the packaging layer; Skill remains the operational-knowledge layer within it.

## Namespace · Resolving Name Ownership Before Distribution

A standalone Skill can be invoked as:

```text
/release-check
```

A Plugin Skill carries the Plugin's namespace:

```text
/acme-release:release-check
```

The namespace looks like extra typing, but it solves two distribution problems:

1. Different Plugins can each own a `review` or `deploy` name;
2. Users can see where a capability comes from, rather than mistaking a third-party Skill for a local project workflow.

The Plugin name therefore becomes part of the capability's namespace. Renaming a Plugin casually isn't just a branding change — it changes the user's invocation entry point and the permission rules.

Namespacing is the price of a composable ecosystem. A personal shortcut can be short; a public capability must avoid squatting on global names.

## Manifest · Giving a Capability Package a Version Identity

A Plugin manifest can declare metadata such as name, description, version, author, repository, and license.

Version establishes an important boundary:

```text
Skill file changed
  ≠
User has already received the update

Plugin version changed
  → distribution systems can recognize a new release
```

Official documentation states that when an explicit version is present, publishers need to bump it for users to receive the corresponding update; if distributing via Git and omitting version, the commit SHA can serve as the version identity.

Whichever strategy is used, the following changes should remain visible:

- Changes to description and trigger scope;
- Changes to workflow semantics;
- Changes to the permission surface (`allowed-tools` / hooks);
- Changes to scripts and dependencies;
- Changes to output format or compatibility.

A release that only touches the prompt can still be a breaking change. The model behavior contract shouldn't skip version management just because the file happens to be Markdown.

## Plugin Development · Loading Locally Isn't the Same as a Formal Install

Claude Code supports loading a local Plugin directly with `--plugin-dir`, which is convenient for development and testing. After modifications, components can be reloaded without going through a marketplace release each time.

This development path suits the following flow:

```text
Local modification
  ↓
Test with --plugin-dir
  ↓
Reload Skills / agents / hooks / MCP
  ↓
Verify discovery and execution in a fresh session
  ↓
Bump version / publish
```

A local copy may override an installed Plugin with the same name, which is useful for testing upgrade compatibility. But components that managed policy forces on or off shouldn't be treated as bypassable configuration via a development flag.

A successful test of the local directory only proves it runs in the author's environment. Before release, it still needs to be validated on a clean machine, including dependencies, permissions, and upgrade paths.

## Managed · What an Organization Distributes Is an Approved Version

Managed Skills are deployed centrally by an organization, and suit:

- Company-wide security review;
- Compliance and data-handling processes;
- Internal system operating guides;
- Organization-approved scripts and references;
- Development workflows that need unified updates.

Compared to Plugin, the core of managed isn't the marketplace install experience — it's administrators controlling the source and the scope of availability.

Organizational governance typically requires:

```text
Author submits a capability update
  ↓
Security / compliance / platform team review
  ↓
Approved version released
  ↓
Administrator deploys it
  ↓
Monitoring and rollback
```

Managed still can't turn prompt instructions into hard enforcement, but it can ensure organization members receive the same approved workflow, combined with managed permissions, shell policy, and hooks.

## Open Format · Portable Doesn't Mean Automatically Synced

Agent Skills use an open folder format, letting different agent products recognize the same core:

```text
name + description
SKILL.md instructions
scripts / references / assets
```

This provides **format portability**. But Anthropic's official documentation clearly distinguishes three surfaces:

| Surface | How the Skill exists | Sharing scope |
|---|---|---|
| Claude Code | Local personal / project / Plugin / managed | Local machine, Git project, or Plugin install scope |
| Claude API | Uploaded Skill, used in a code execution container | API workspace |
| claude.ai | Uploaded by the user in product settings | The corresponding user account |

They don't sync automatically:

- A Claude Code personal Skill doesn't automatically appear on claude.ai;
- An API workspace Skill doesn't automatically install to local `.claude/skills/`;
- A claude.ai upload isn't a project Git file either.

The more accurate meaning of "write once" is that the core folder can migrate — not that every surface shares the same storage and version state.

## Different Runtimes · The Same Skill May Not Run Directly Elsewhere

A Claude Code Skill executes on the user's local machine, can use local tools and network access, and is constrained by the user's environment, permissions, and sandbox.

Claude API Skills run inside a code execution container; official documentation notes that their network and runtime dependencies are constrained by the container. Claude.ai has its own code execution and admin settings as well.

So migrating across surfaces requires checking two layers:

### Portable instructions

- Does the workflow still make sense?
- Are references and assets complete?
- Is the output contract generic?

### Runtime dependencies

- What language and packages do the scripts use?
- Does it assume the ability to install dependencies?
- Does it need network access?
- Does it depend on a local CLI, credential, or absolute path?
- Is Claude Code's private frontmatter supported on the target client?

The open format guarantees that others can read the folder — it doesn't guarantee the target runtime can perform every action.

## `compatibility` · Turning Implicit Environment Assumptions into a Distribution Contract

The Agent Skills spec provides `compatibility` metadata to describe requirements such as host, system packages, and network access.

If a Skill depends on:

- Claude Code's dynamic context;
- `gh`, `kubectl`, or a custom CLI;
- PowerShell;
- Network access;
- A specific MCP server;
- A `bin/` provided by the Plugin;

users shouldn't have to discover this only after a script fails.

Compatibility isn't an installer, but it elevates "happens to exist on the author's machine" into a reviewable precondition.

Likewise, `license` and author metadata aren't decoration. A Skill can include code, templates, and third-party references, and distributors need to know whether they have the right to propagate and modify them.

## Dependency · Supply Chain Beyond the Skill Folder

Even if a Skill itself passes review completely, it may still call at runtime:

- `npx package@latest`;
- An unpinned Python package;
- A script hosted at an external URL;
- A third-party MCP server;
- A remote template;
- An identically named executable on the user's PATH.

These dependencies can change behavior even while the Skill itself stays unchanged.

Secure distribution should consider at least:

- Pinning or constraining dependency versions;
- Recording checksums / release provenance;
- Avoiding runtime downloads of code from arbitrary URLs;
- Applying least-privilege explicitly to external MCP servers and credentials;
- Recording permission-surface changes in a changelog;
- Providing a way to uninstall and roll back.

A Skill is part of the software supply chain — not just an instruction supply chain.

## Migrating from Standalone to Plugin

Migration shouldn't just be copying a directory. It can be done in five steps:

```text
1. Lock down the Skill contract
   description · inputs · outputs · side effects

2. Clean up local-machine assumptions
   absolute paths · private credentials · undeclared CLIs

3. Build the Plugin structure
   manifest · skills/ · agents/ · hooks/ · MCP

4. Establish namespace and version
   invocation name · permission rules · changelog

5. Validate in a clean environment
   discovery · invocation · permissions · scripts · upgrade
```

If, after migration, `.claude/skills/` has simply been wrapped as-is, the Plugin form is complete — but productization is not.

## The Quality Gate Before Distribution

A Skill that performs well in the author's own conversation history may simply be benefiting from a lot of implicit help already present in the main context. Before distribution, it should be validated in a fresh session:

1. **Discovery** · Does it trigger for requests it should trigger for?
2. **Precision** · Does it wrongly fire on adjacent but unrelated requests?
3. **Execution** · Can it complete the task without the author's implicit background context?
4. **Environment** · Does it give a clear error when a dependency is missing?
5. **Permissions** · Do the actual requests match the documentation?
6. **Output** · Does the result meet the agreed format and quality?
7. **Upgrade** · Is it compatible after updating from the previous version?

Two metrics need to be kept separate here:

```text
Trigger quality
  Whether the Skill gets selected at the right moment

Outcome quality
  Whether being selected actually improves the task result
```

Seeing the Skill badge appear doesn't prove the capability is effective. Skill distribution, then, isn't about moving files — it's about choosing a maintenance contract: **Personal optimizes for iteration speed, Project optimizes for repository consistency, Plugin optimizes for installable and versioned composition, Managed optimizes for organizational control; the open format connects them, but doesn't sync them for you.**

## Coming Up Next

At this point, a Skill has traveled through format, discovery, invocation, rendering, execution, security, lifecycle, and distribution. What remains is the most practical question: given a rule, a workflow, an external action, or a specialized worker in hand, what should it actually be built as? The next piece, [10 · Wrap-up · Where Should a Capability Live](10-conclusion.md), will use a decision tree to draw the boundaries between CLAUDE.md, Rules, Skill, Tool, Hook, Subagent, MCP, and Plugin.

## References

- Anthropic Claude Code official documentation: [Share skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Create plugins](https://code.claude.com/docs/en/plugins)
- Anthropic Claude Code official documentation: [Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- Anthropic Platform official documentation: [Cross-surface availability](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Agent Skills open specification: [Compatibility and metadata](https://agentskills.io/specification)
- Previous piece: [08 · Lifecycle · From a Single Load to Compaction](08-lifecycle.md)
