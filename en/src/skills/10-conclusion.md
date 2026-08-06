# 10 · Wrap-up · Where Should a Capability Live

> **TL;DR**: Put stable, universally-applicable rules in CLAUDE.md / Rules. Put reusable knowledge and multi-step procedures in a Skill. Put actions that must fire on a fixed event in a Hook. Build an atomic execution interface as a Tool. Connect to external system capabilities through MCP. Hand off work that needs its own context to a Subagent. Bundle multiple extensions installed together as a Plugin. Skill sits in the middle: it doesn't provide new execution primitives directly — instead, it loads on demand "how to combine existing capabilities to accomplish a class of work."

The previous piece, [09 · Distribution · From Personal Folder to Team Plugin](09-distribution.md), carried Skill from a personal folder all the way to project, Plugin, and managed scope. By this point, a Skill has gone through its full lifecycle:

```text
Folder format
  ↓
Metadata discovery
  ↓
User / model invocation
  ↓
Prompt rendering
  ↓
Inline / fork execution
  ↓
Permissions / hooks / sandbox
  ↓
Compaction recovery
  ↓
Project / Plugin / managed distribution
```

This final piece doesn't add any new mechanism. It only answers a practical question:

> **When you notice Claude is missing a capability, should you add it to CLAUDE.md, a Skill, a Tool, a Hook, a Subagent, MCP, or a Plugin?**

## Don't Ask "Which Folder" First

Suppose a user says:

```text
From now on, before every release: run the tests, check the
changelog, confirm the version number, summarize the risks,
and don't ship until I approve.
```

This passage can be broken down into different natures:

- "This project uses pnpm" — a stable project fact;
- "The order of pre-release checks" — a reusable workflow;
- "Any push to production must be blocked pending approval" — enforcement;
- "Read deployment status" — an external action;
- "A full audit reads a lot of files" — context isolation;
- "Want the whole team to install it with one click" — distribution.

If this entire passage were dumped as-is into a single Skill, it would technically work, but different responsibilities would end up mixed into one layer. The right question isn't "does this sentence feel like a Skill," but to judge each item individually:

```text
Is it a standing fact, an on-demand procedure, an atomic action,
a fixed trigger, an isolated worker, or a distribution wrapper?
```

## First Cut · Should Every Task Know This

### Yes · CLAUDE.md or Rules

Suitable content:

- Package manager, build commands, and project conventions;
- Directory boundaries and non-negotiable collaboration conventions;
- Naming, testing, or architecture rules that every related piece of work should follow;
- Path-related instructions that are still project rules at heart.

```text
"This repo only uses pnpm"
  → CLAUDE.md

"Backward compatibility must be preserved when editing migrations/**"
  → path-scoped Rule
```

The defining trait of CLAUDE.md / Rules is that they're **loaded standing by, or the moment a path is touched**. If a piece of content is irrelevant in 90% of tasks, making it standing-by only adds noise.

### No · Ask Whether It's a Reusable Procedure

Workflows for release, review, incident, migration, doc generation, etc. only surface for specific tasks — suited to on-demand loading.

```text
"Follow these 8 steps when preparing a release"
  → Skill
```

Both CLAUDE.md and Skill can hold instructions — the real dividing line is applicability frequency and load timing:

> **Needed to know every time → CLAUDE.md; needed only for a class of task → Skill.**

## Second Cut · Is What's Missing "How to Do It" or "The Ability to Do It"

### Missing procedure · Skill

A Skill provides:

- Domain knowledge;
- Checklists;
- Multi-step workflows;
- Judgment criteria;
- Tool orchestration order;
- Navigation across reference, script, and asset material.

```text
"How to review a database migration"
  → Skill
```

### Missing action · Tool

A Tool provides an atomic execution interface the model can call:

- Read a data source;
- Create a ticket;
- Query deployment status;
- Modify a specific object;
- Run an operation with a stable input/output contract.

```text
"Query the currently deployed version on staging"
  → Tool
```

The two combine:

```text
release-check Skill
  1. Call the deployment-status Tool
  2. Call test-related Tools / Bash
  3. Read the changelog
  4. Decide whether release conditions are met
```

The Skill doesn't need to reimplement the Tool, and the Tool doesn't need to know the full release policy.

The core dividing line:

> **Tool exposes an affordance · Skill organizes affordances.**

## Third Cut · Is the Tool Local or an External System

Claude Code ships with Read, Edit, Bash, and other Tools built in. When new local deterministic logic is needed, a simple script may suffice; when the model needs a structured interface to call a new external capability, that's usually connected via MCP.

### Skill-bundled Script

Suited to:

- Serving only this one Skill;
- Timing decided by the instructions;
- Using existing Bash / code execution;
- Not needing to be discoverable as a global standalone capability by other workflows.

```text
release-check/scripts/validate-version.py
```

### MCP Tool

Suited to:

- Capability that comes from an external service or independent process;
- Multiple Skills and ordinary tasks might call it;
- Structured schema and tool result required;
- Independent authentication, deployment, and lifecycle needed;
- Shouldn't require Claude to hand-assemble CLI arguments.

```text
deployment server
  ├─ get_status(environment)
  ├─ deploy(version, environment)
  └─ rollback(deployment_id)
```

The Skill can know "when to query, under what conditions to deploy, how to roll back on failure" — the MCP server provides the actual action.

Judgment criteria:

```text
Logic belongs only to one capability package?
  → bundled script

An independent action needed by multiple workflows?
  → Tool / MCP
```

## Fourth Cut · Model Judgment, or Must-Happen Fixed Events

Skill instructions are interpreted by the model. If the requirement is:

```text
"Formatter must run after every Edit"
```

putting this into a Skill means Claude has to remember to, and choose to, execute it. A more direct mechanism is a PostToolUse Hook — once the Edit event fires, the formatter is triggered deterministically, no model judgment involved.

Hook is suited to:

- Fixed lifecycle events;
- Something that must run on every hit;
- Needing to block or auto-handle;
- Not wanting to rely on the model actively remembering.

Skill is suited to:

- Needing to understand context before choosing steps;
- Different outcomes taking different branches;
- Workflows requiring reasoning, collaboration, and explanation.

The two can combine:

```text
security-review Skill
  guides the full review methodology

PreToolUse Hook
  ensures dangerous commands always go through validation
```

In one line:

> **Needs Claude to judge how to do it → Skill; must happen the moment the event fires → Hook.**

## Fifth Cut · Current Context or Independent Worker

Once there's a reusable workflow, it still has to be decided where it executes.

### Inline Skill

Suited to:

- Needing the full history of the main conversation;
- Continuous back-and-forth with the user;
- Planning, implementation, and verification sharing context tightly;
- Reference knowledge needing to keep influencing the current task.

### Forked Skill / Subagent

Suited to:

- Heavy intermediate search and logging;
- A task that can be self-contained;
- Only needing a summarized result returned;
- Needing dedicated tools, model, or permissions;
- Not wanting to pollute the main context.

### Custom Subagent

When "which role does this" is more stable than "what is this particular workflow," build a custom subagent:

```text
code-reviewer agent
  system prompt · tools · model · permissions
  + preloaded review Skills
```

The dividing line between Skill and Subagent:

> **Skill stores reusable content · Subagent provides independent context and an execution identity.**

A Skill can fork an agent, and an agent can also preload Skills. Don't create an agent just to store a piece of prompt, and don't limit yourself to an inline Skill just to isolate a large amount of work.

## Sixth Cut · Single Config or Installation Unit

Once a Skill has matured, it's still necessary to decide how to distribute it.

```text
Shared across one repo
  → .claude/skills/ · Project Skill

Used personally across projects
  → ~/.claude/skills/ · Personal Skill

Installed across projects together with agents / hooks / MCP
  → Plugin

Deployed uniformly by an organization with approved versions
  → Managed
```

Plugin doesn't provide a new behavior layer. It turns existing Skills, agents, hooks, MCP servers, and other components into a namespaced, versioned installation unit.

So don't turn a single-project Skill into a Plugin prematurely just to make it "look official." And don't let ten projects each copy the same multi-component capability just because it started out standalone.

## The Full Decision Tree

```text
A new capability requirement lands on your desk
  │
  ├─ A fact / rule every relevant task should know?
  │    ├─ Project-wide → CLAUDE.md
  │    └─ Path-specific → Rules / nested CLAUDE.md
  │
  ├─ Knowledge / multi-step procedure needed only for one class of task?
  │    └─ Skill
  │         ├─ Shares the main history → inline
  │         └─ Self-contained and independent → context: fork
  │
  ├─ Must execute the moment a fixed event happens?
  │    └─ Hook
  │
  ├─ The model is missing one atomic action?
  │    ├─ Private deterministic logic for one Skill → bundled script
  │    ├─ Local general-purpose capability → custom Tool / executable
  │    └─ External system / independent process → MCP Tool
  │
  ├─ Needs independent context, role, model, tools?
  │    └─ Subagent
  │
  └─ Multiple extensions need unified install, versioning, and updates?
       └─ Plugin / Managed distribution
```

A single complete capability often hits several branches at once — that's not a conflict, it's layered composition.

## A Complete Example · Production Release

Breaking the opening release requirement down into a capability stack:

### CLAUDE.md

```text
- This project uses pnpm
- Production releases require explicit user approval
- Changelog follows the Keep a Changelog format
```

These are broadly applicable project rules.

### Skill

```text
release-check
1. Confirm target version and environment
2. Check working tree and tests
3. Validate changelog and version
4. Query current deployment status
5. Summarize blocking issues
6. Wait for user decision
```

This is an on-demand workflow.

### Scripts

```text
validate-version.py
check-changelog.py
```

Handle deterministic validation.

### MCP Tools

```text
get_deployment_status
deploy_release
rollback_release
```

Connect to the deployment platform.

### Hooks

```text
PreToolUse
  validate approval token and target environment before a production deploy
```

Establishes a deterministic checkpoint.

### Subagent

```text
release-auditor
  independently reads a large volume of changes and test results
  returns a risk summary
```

Isolates the audit process.

### Plugin

```text
acme-release/
  skills + agents + hooks + MCP config + scripts
```

Hands the whole capability package off for installation across multiple repos.

If all of this were written into a single `SKILL.md`, every layer would depend purely on the model's self-discipline. Split apart, each mechanism handles the constraint it's best suited for.

## Skill's Own Design Decision Tree

Once "this should be a Skill" is settled, the next questions are:

```text
Is the content mostly knowledge or action?
  ├─ Reference → default inline · optionally user-invocable: false
  └─ Task workflow
       │
       ├─ Must the user control the timing?
       │    └─ disable-model-invocation: true
       │
       ├─ Needs the main conversation history?
       │    ├─ Yes → inline
       │    └─ No · process is lengthy → context: fork
       │
       ├─ Large, low-frequency reference material?
       │    └─ references/
       │
       ├─ Deterministic processing?
       │    └─ scripts/
       │
       └─ Final templates / assets?
            └─ assets/
```

This tree maps directly onto the format, discovery, invocation, rendering, and execution boundaries established in the previous nine pieces.

## Quality Checks · Test Trigger First, Then Outcome

Once a Skill is written, it should be tested against at least two kinds of quality.

### Trigger Eval

Prepare three groups of prompts:

```text
Should trigger
  "Is this version ready to ship?"
  "Help me do a release readiness check"

Should not trigger
  "Explain what semver is"
  "Just fix a typo in the README, nothing else"

Boundary case
  "Generate the changelog, but skip the full release check for now"
```

Observe the precision and recall of the description. Only testing `/release-check` manual invocation doesn't prove automatic discovery is working.

### Outcome Eval

In a fresh session, compare:

```text
Same task + Skill enabled
vs
Same task + Skill disabled
```

Check:

- Whether the workflow is actually followed;
- Whether omissions are reduced;
- Whether references / scripts / Tools are used correctly;
- Whether it produces excessive context or unnecessary calls;
- Whether it meets the output and verification contract;
- Whether it introduces new side-effect risk.

Being invoked only proves routing succeeded — a result better than baseline is what proves the capability is actually effective.

## Skill Maturity Isn't the Body Text Getting Longer and Longer

A Skill's evolution should generally look like this:

```text
v0 · a repeatedly copy-pasted prompt
  ↓
v1 · a clear description + core workflow
  ↓
v2 · references / scripts / assets layered in
  ↓
v3 · invocation control + permissions + verification
  ↓
v4 · evals + versioned distribution
```

If every failure only results in another warning tacked onto `SKILL.md`, what you end up with is a bloated prompt, not a mature capability.

Different failures should go to different layers:

| Failure | Better fix |
|---|---|
| Doesn't trigger | description |
| Triggers by mistake | what / when boundaries, paths |
| Steps get missed | core workflow |
| Rare detail errors | reference |
| Deterministic operation is unstable | script / Tool |
| Required action occasionally doesn't happen | Hook / CI |
| Permissions too broad | permission / sandbox / auth |
| Main context gets swamped | forked subagent |
| Team version drift | Project / Plugin / managed |

Sending the problem back to the right layer keeps a Skill from becoming a dumping ground for every defect.

## Anti-pattern Summary

| Anti-pattern | Consequence | Fix |
|---|---|---|
| Cramming occasional workflows into CLAUDE.md | Standing noise in every session | Push down to Skill |
| Skill simulating a structured atomic API | Fragile arguments · unstable output | Tool / MCP |
| Skill demands "must happen every time" with no Hook | Relies on the model remembering | Fixed lifecycle trigger |
| Creating a subagent for reference material | There's knowledge but no task | inline / preload |
| Treating `allowed-tools` as an allowlist | Unlisted Tools may still be called | disallow / deny / agent tool list |
| Dynamic shell secretly does the real work | Claude reads it only after side effects already happened | normal Tool loop |
| Cramming all material into `SKILL.md` | Activation and compaction cost too high | progressive disclosure |
| Writing task progress into the Skill | Stale state pollutes future invocations | task / session / memory |
| Copying a folder as team distribution | Version and source drift | Project Git / Plugin |
| Treating Plugin as a security guarantee | Malicious scripts and dependencies still exist | audit + version + sandbox |

## Evolution Path · Capabilities Can Migrate

The carrier isn't fixed forever once chosen the first time:

```text
A repeatedly copy-pasted prompt
  → Personal Skill

A personal process becomes project consensus
  → Project Skill

Multiple repos need it
  → Plugin

One step of the Skill becomes stable and general
  → Script / Tool / MCP

A check goes from "recommended" to "mandatory"
  → Hook / CI / policy

A section of the Skill ends up always loaded
  → CLAUDE.md / Rule

The inline process keeps polluting the main context
  → Forked Skill / Subagent
```

Reverse migration holds too:

- A global rule that only serves release → demote from CLAUDE.md to Skill;
- A Plugin used by only one repo → move back to project;
- A forked task that always depends on the full chat history → move back to inline;
- A Tool used only internally by one Skill with no reuse value → pull back into a bundled script.

Architectural trustworthiness comes from continually putting responsibility back at the right layer, not from chasing extension counts.

## The Final Conclusion of This Series

Skill is most easily misunderstood as one of three things:

- A longer prompt;
- A more convenient slash command;
- A Tool that doesn't need a schema.

It inherits a bit of the character of all three, yet has a complete position of its own:

```text
Prompt
  provides instructions
       ↓ made reusable + turned into a folder
Skill
  discovered · loaded on demand · orchestrates capabilities
       ↓ invokes
Tools / MCP
  execute atomic actions
```

It can also enter different contexts:

```text
Skill inline
  → extends the current agent's approach

Skill fork
  → turns the approach into an independent worker's task
```

And it can be governed and distributed by different layers:

```text
Permissions / Hooks / Sandbox
  → control execution

Project / Plugin / Managed
  → control propagation
```

One line to close out the whole series:

> **Skill is an on-demand-loaded package of operational knowledge: metadata makes it discoverable, instructions tell Claude how to do it, resources and scripts supply the material, Tools turn the approach into action, and the runtime decides which context it executes in and with what permissions.**

## Preview of the Next Series

Skill has explained "how to organize existing capabilities into a workflow." The next natural question is: how does Claude Code acquire external Tools and data that didn't exist before? That leads into the **MCP research series** — starting from the tool schema a server exposes, tracing connection, discovery, invocation, permissions, transport, and external lifecycle.

## References

- Anthropic Claude Code official docs: [Extend Claude Code](https://code.claude.com/docs/en/features-overview)
- Anthropic Claude Code official docs: [Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official docs: [Tools reference](https://code.claude.com/docs/en/tools-reference)
- Anthropic Claude Code official docs: [Create custom subagents](https://code.claude.com/docs/en/sub-agents)
- Anthropic Claude Code official docs: [Hooks reference](https://code.claude.com/docs/en/hooks)
- Anthropic Claude Code official docs: [Create plugins](https://code.claude.com/docs/en/plugins)
- Agent Skills Open Specification: [Specification](https://agentskills.io/specification)
- [00 · Opening · From Repeated Copy-Paste to Callable Capability](00-intro.md)
- [01 · Capability Format · From a Single Markdown File to a Portable Folder](01-format.md)
- [02 · Progressive Disclosure · From Description to Full Instructions](02-progressive-disclosure.md)
- [03 · Capability Discovery · From a Directory to Claude's Candidate List](03-discovery.md)
- [04 · Capability Invocation · From User Request to Skill Activation](04-invocation.md)
- [05 · Prompt Rendering · From Arguments to Dynamic Context](05-prompt-rendering.md)
- [06 · Execution Boundary · From Inline to Forked Subagent](06-execution-boundary.md)
- [07 · Permission Governance · From Callable to Safely Executable](07-permissions.md)
- [08 · Lifecycle · From a Single Load to Compaction](08-lifecycle.md)
- [09 · Distribution · From Personal Folder to Team Plugin](09-distribution.md)
- Previous: [09 · Distribution · From Personal Folder to Team Plugin](09-distribution.md)
