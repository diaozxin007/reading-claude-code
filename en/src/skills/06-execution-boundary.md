# 06 · Execution Boundaries · From Inline to Forked Subagent

> **TL;DR**: An inline Skill adds its instructions to the main conversation — sharing the existing history and continuing to work on the same loop. `context: fork`, on the other hand, turns the Skill body into a task for a new subagent — using an independent context, agent configuration, and tool boundaries — and only brings the result back to the main conversation at the end. The former suits knowledge and workflows that need ongoing collaboration; the latter suits self-contained tasks that involve a lengthy process but only need to return a summary.

The previous post, [05 · Prompt Rendering · From Parameters to Dynamic Context](05-prompt-rendering.md), covered how `SKILL.md` is rendered into instructions tailored to a specific invocation. The next step isn't to immediately execute some fixed function — it's to decide: **should these instructions go to the current Claude, or to a new worker?**

Claude Code offers two execution contexts:

```text
inline
  rendered Skill
      ↓
  current conversation

fork
  rendered Skill
      ↓
  new subagent context
      ↓
  result returned to current conversation
```

Both use the same Skill file format, yet produce completely different information flows.

## Inline · Adding a Method to Ongoing Work

By default, a Skill unfolds within the current conversation. Suppose the main conversation has already reached this point:

1. The user has explained the release background;
2. Claude has read the current diff;
3. Both sides have confirmed only staging needs to be checked;
4. The user invokes `/release-check v2.4.0`.

An inline Skill can directly draw on all this existing information: the user's goal, files already read, decisions made earlier, and tool results are all still in the same conversation — the release-check instructions are simply a new addition. Claude doesn't need to re-understand the task; the Skill just adds a set of methods to the current agent's work.

Inline is a good fit for:

- Reference-type Skills that supplement the current work with domain knowledge;
- Workflows that need ongoing back-and-forth with the user;
- Tasks where earlier and later phases share a lot of context;
- Skills that are just part of the current work, not an independently delegated task;
- Execution that needs to keep referring back to decisions and tool results from the main conversation.

Its advantage is continuity of context; the cost is that the Skill body, subsequent reads, and execution results all keep growing the main context.

## Fork · Turning the Skill Body into a Delegated Task

Set this in the frontmatter:

```yaml
---
name: deep-release-audit
description: Deeply audit a candidate release version
context: fork
agent: Explore
---
```

Once invoked, Claude Code creates an independent subagent. The rendered `SKILL.md` is no longer supplementary material for the main conversation — it becomes the task the subagent needs to complete.

```text
Main conversation
  "Audit v2.4.0"
        ↓ invoke forked Skill

Subagent context
├─ agent system prompt
├─ Skill rendered content ← task
├─ files it reads on its own
├─ tool results it produces on its own
└─ final conclusion
        ↓
Main conversation
  receives result / summary
```

Forking here doesn't mean copying the main messages array. The subagent gets a new context window — it doesn't automatically see the full history of the main conversation, all the files the main agent has already read, or other Skills it has already invoked.

What it receives is the Skill task, the execution environment of the selected agent, and the baseline project context defined by the product.

## `context: fork` First Requires the Skill to Be a Complete Task

Consider a reference Skill:

```markdown
This project's APIs should use a consistent error format · list endpoints must be paginated ...
```

Loaded inline, the current Claude can apply these conventions to the endpoint it's currently writing.

If this is set to `context: fork`, the new subagent only gets a set of API conventions — it has no idea which file to review, which interface to design, or what result to deliver. It has knowledge, but no task.

So a forked Skill needs to explicitly spell out:

- What object to operate on;
- What action to complete;
- Where to get available inputs;
- What counts as done;
- What to return at the end.

```markdown
Review the API file specified by `$ARGUMENTS`:

1. Locate the endpoints and schema
2. Check them against this project's API conventions
3. Check compatibility, error format, and pagination
4. Return a list of issues sorted by severity
```

In one sentence:

> **An inline Skill can offer knowledge alone; a forked Skill must be able to independently constitute a task.**

## Forking Doesn't Inherit the Conversation — Arguments Must Carry the Handoff

The main conversation may have already stated:

```text
Only check staging, not production — target version is v2.4.0.
```

A forked subagent won't naturally know this just because it appears in the main history. Necessary information must cross the delegation boundary:

- Passed in via `$ARGUMENTS`;
- Gathered in advance via dynamic context;
- Written into the Skill's fixed instructions;
- Or assembled into a clear task input by the main agent at invocation time.

This is similar to a function call:

```text
Implicit state of the main conversation
  ≠
Explicit input of the subagent
```

If a forked Skill always relies on "you should remember what I said earlier," that's a sign the task boundary hasn't been encapsulated properly — it may be better suited to inline.

## The `agent` Field Determines the Work Environment

`context: fork` only indicates that an independent context is needed. `agent` then determines which type of subagent performs the work:

- `Explore` — suited to read-only code research;
- `Plan` — suited to forming an implementation plan;
- `general-purpose` — suited to tasks requiring a comprehensive toolset;
- A custom agent — using project-defined model, tools, and system prompt.

```yaml
context: fork
agent: Explore
```

The division of labor between Skill and agent is:

```text
Skill
  What exactly to do this time · workflow and delivery standards

Agent
  What role performs it · what model, Tools, and permissions are used
```

The same "deep research" workflow can be handed to different agent environments, and the same class of reviewer agent can execute different Skill tasks.

This avoids mixing role identity and one-off task specification into the same Markdown.

## The Lightweight-Context Exception for Explore/Plan

Official documentation notes that, generally, a forked Skill also receives the project's CLAUDE.md in addition to the agent prompt and Skill task; however, the built-in Explore and Plan agents, in order to keep their context lean, don't load CLAUDE.md and git status the way other agents normally would.

This means choosing `agent: Explore` can't be judged solely on "it has file-reading tools." If a Skill's key constraints exist only in CLAUDE.md, the task may not receive those rules at all.

A safe rule of thumb:

- Rules that the whole project should follow, and that the agent environment does load → keep them in CLAUDE.md;
- Constraints essential to the success of a forked task → spell them out explicitly in the Skill;
- Don't rely on any given agent implicitly inheriting from the main conversation.

The more isolated the execution context, the clearer the task contract needs to be.

## Forking Isolates the Process — It Doesn't Make the Cost Disappear

Suppose an audit needs to read 80 files and produces a large volume of search results. Running inline would keep piling all this intermediate information into the main conversation.

After forking:

```text
Subagent context
  80 files + search results + reasoning process
        ↓ condensed
Main context
  a list of issues and a summary of evidence
```

The main context is protected, but the total computation hasn't gone away:

- The subagent needs its own input tokens;
- It has to re-read project material it doesn't already know;
- Startup and result aggregation add latency;
- If the returned content is too long, it still consumes main context.

The value of forking is **placing the process in a more appropriate context**, not getting a second brain for free.

## The Reverse Direction · Preloading Skills into an Agent

Skills and subagents can be composed in both directions. What's been discussed so far is the `context: fork` direction — the Skill determines the task, the agent determines the worker environment. The other direction is using the `skills` field in a subagent definition:

```yaml
---
name: code-reviewer
description: Review the current changes
tools: Read, Grep, Glob
skills:
  - api-conventions
  - security-guidelines
---
```

In this case:

```text
Subagent definition
  determines the role and system prompt

Delegation message
  determines this specific task

Preloaded Skills
  provide the knowledge the role needs from the moment it starts up
```

The difference between the two combinations can be summarized in a table:

| Approach | System prompt comes from | This task comes from | Role of the Skill |
|---|---|---|---|
| Skill `context: fork` | Selected agent | `SKILL.md` rendered content | Defines this workflow |
| Subagent `skills` | Subagent body | Delegation from the main agent | Preloads knowledge for the role |

The former expresses "this capability needs to be handed to a worker to execute"; the latter expresses "this worker needs this knowledge no matter which task it takes on."

## Preloading the Full Body — No Longer Routed via Metadata

In a normal main session, a Skill first exposes its description, and only loads its full body once activated. The `skills` field on a subagent expresses a stronger judgment: the author has already decided this agent needs these Skills every time it starts up.

So what's preloaded is the complete Skill content — not just the name and description.

This improves consistency for specialized roles, but comes with a fixed context cost:

- If a reviewer uses security guidelines every time → suitable for preloading;
- If PDFs are only handled occasionally → shouldn't be preloaded for every reviewer;
- If a dozen large Skills are all preloaded → a new agent will already be using up a large amount of context before it even takes on a task.

Subagent preloading upgrades a Skill "from an on-demand capability to knowledge the role carries at all times." It should be based on stable responsibilities, not on avoiding the occasional case where Claude forgets to invoke it.

## Preloading Is Not the Same as a Skill Tool Allowlist

Official documentation distinguishes two separate things:

- The `skills` field — injects the full body of the specified Skills into the subagent's startup context;
- Skill tool availability — whether the subagent can still invoke other visible Skills on demand.

A preload list isn't naturally a "these Skills only" sandbox. If tools and capabilities need to be restricted, that still requires configuring agent tools, permissions, or Skill access rules.

Similarly, preloading a Skill into an agent doesn't automatically grant all the system permissions involved in that Skill. Knowledge preload and capability enforcement remain two separate layers.

## Table · Choosing Between Inline and Fork

| Question | Inline | Forked subagent |
|---|---|---|
| Needs the full main conversation history | Suitable | Not automatically available |
| Needs frequent back-and-forth with the user | Suitable | Higher cost |
| Lots of intermediate reads and logs | Pollutes main context | Can be isolated |
| Can the task be self-contained | Doesn't need to be fully self-contained | Must be clearly encapsulated |
| Only a final summary is needed | Possible, but the process still stays on the main thread | Suitable |
| Needs specialized tools/model | Constrained by the current agent environment | Optional agent configuration |
| Reference-type knowledge | Suitable | Forking alone often lacks a task |
| Latency-sensitive small edits | Suitable | Startup cost is relatively high |

What a Skill determines isn't just "what to do" — it can also determine "where this method unfolds": **inline adds a capability to the current train of thought; forking hands the task off to an independent worker. Skill-calls-Agent is task-driven; Agent-preloads-Skill is role-driven.**

## Coming Up Next

Whether inline or forked, execution eventually calls Tools. A Skill can pre-approve certain actions, exclude certain Tools, register lifecycle hooks — and project Skills are also affected by workspace trust. The next post, [07 · Permission Governance · From Callable to Safely Executable](07-permissions.md), will draw four clear boundaries: **being able to call a Skill, being able to call a Tool, being exempt from confirmation prompts, and truly being isolated are not the same thing.**

## References

- Anthropic Claude Code official documentation: [Run skills in a subagent](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Create custom subagents](https://code.claude.com/docs/en/sub-agents)
- Anthropic Claude Code official documentation: [Preload skills into subagents](https://code.claude.com/docs/en/sub-agents)
- Previous post: [05 · Prompt Rendering · From Parameters to Dynamic Context](05-prompt-rendering.md)
- [06 · Sub-agent Isolation · From Independent Context to the .output Trap](../context-management/06-sub-agent.md)
- [09 · Sidechain · From Sub-agent to agentId Routing](../agent-loop/09-sidechain.md)
