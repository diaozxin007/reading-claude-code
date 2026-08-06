# 04 · Capability Invocation · From User Request to Skill Activation

> **TL;DR**: A user typing `/release-check` and Claude proactively choosing `release-check` are different entry points — yet both must expand a Skill from candidate metadata into the full instructions for the current task. The direct result of a Skill invocation isn't "release completed" — it's "this working method entering the execution scene." `disable-model-invocation` and `user-invocable` control who can open this door; they don't guarantee that every step behind it actually gets executed.

The previous piece, [03 · Capability Discovery · From a Directory to Claude's Candidate List](03-discovery.md), explained how a Skill enters the candidate capability view through scope, directory, namespace, and path conditions.

Now assume the candidate list already contains:

```text
release-check · Checks whether the code version is ready for release
```

When does it go from a one-line description to instructions that actually shape the task? There are two entry points:

```text
Explicit user invocation
  /release-check

Model invocation
  "Can this version ship?"
      ↓ description match
  Selects release-check
```

Both are called "invoking a Skill" — but the initiator, the degree of control, and the applicable scenarios differ.

## Manual Invocation · The User Directly Selects a Capability

The user types:

```text
/release-check
```

This isn't mentioning a filename in casual chat — it's explicitly specifying "please load and adopt this Skill." The user has already completed capability selection; Claude doesn't need to guess which of dozens of descriptions is most relevant.

Manual invocation suits three kinds of tasks:

1. **The user controls the timing** — only the user knows it's time to formally enter the release phase;
2. **The action may have side effects** — deploy, commit, sending messages, updating external systems;
3. **The workflow has a high cost** — deep review, full verification, batch processing — things you don't want the model triggering incidentally.

Users can also attach arguments:

```text
/release-check v2.4.0
```

The runtime renders the argument into the Skill instructions — Claude receives not just "use release-check" but a concrete task targeted at `v2.4.0`. How the argument substitution and dynamic context injection work is left for the next piece.

What manual invocation provides is **entry-point control**. It doesn't mean the Skill becomes a traditional CLI command: once loaded, Claude still reads the instructions, assesses the environment, and uses Tools to move things forward.

## Model Invocation · Claude Selects from the Candidate List

The user might also have no idea what the Skill is called:

```text
Can you check whether this version is ready to release, and what's blocking it?
```

If `release-check`'s description matches the request, Claude can proactively select this Skill. Here the model first completes a round of capability routing: starting from the user's intent, it compares candidate names and descriptions, selects `release-check`, and then requests to load the full Skill.

This entry point most resembles ordinary Tool selection. Claude sees the capability description, judges relevance, then issues a structured call. But an ordinary Tool call immediately enters its corresponding executor, whereas a Skill invocation first yields instructions.

Model invocation suits cases where:

- The user only describes a goal and shouldn't have to memorize internal capability names;
- A piece of knowledge should naturally participate in relevant tasks;
- Multiple Skills may combine depending on context;
- The capability itself has no high-risk timing that the user must control.

Automatic selection upgrades a Skill from "a saved command" to "a capability Claude can discover on its own."

## Two Entry Points · One Convergence Point

The invocation process can be simplified as: the user types `/release-check v2.4.0`, or Claude proactively selects `Skill(release-check)` — the two paths converge here, both needing to locate the Skill definition first, then render arguments and dynamic context to obtain the full instructions before entering the task, and finally have Claude orchestrate the existing Tools.

Before convergence, the two differ:

- Manual invocation is completed by the user's selection;
- Model invocation is completed jointly by the description and the current request.

After convergence, both must solve the same problems:

- Locate the corresponding Skill;
- Obtain the full `SKILL.md`;
- Process arguments and dynamic content;
- Place the final instructions into the correct context;
- Let Claude continue the workflow.

So "the user can type `/name`" and "Claude can proactively use it" are two independent capabilities — not two expressions of the same switch.

## What a Skill Invocation Actually Accomplishes

Compare these two actions:

```text
Read(file)
  → returns file contents

Skill(release-check)
  → loads release-check instructions
```

The tool result of `Read` is the action's output. The direct output of `Skill` is merely new operational knowledge. The actual release check hasn't happened yet — Claude next might go on to:

1. Read the git status;
2. Run the tests;
3. Check the version file;
4. Read the changelog;
5. Output a risk report.

This reveals the key difference between Skill and Tool:

> **An ordinary Tool call changes or observes external state. A Skill call changes how the current agent works from this point forward.**

Of course, a Skill can also fork into a subagent to independently complete a task and return a result. But that's a change in the execution context — it doesn't alter the essential nature of a Skill as instructions-driven work.

## `/name` Is Just a Shared Entry Point — What's Behind It May Not Be the Same Thing

In the Claude Code interface, `/compact`, `/release-check`, and bundled skills all appear via slash names. This shared input form makes it easy to assume they're all Markdown prompts.

In fact, at least three categories need distinguishing:

| Type | Core content | What happens on invocation |
|---|---|---|
| Built-in command | Product-internal logic | Directly executes a Claude Code feature |
| Bundled Skill | Anthropic-provided prompt-based workflow | Loads instructions · orchestrates Tools |
| Custom Skill | A capability package from a user, project, or Plugin | Loads custom instructions and resources |

A built-in command may switch modes, manage the session, or open a product UI — it doesn't need to hand a working method to the model. Bundled Skills and custom Skills, on the other hand, mainly guide Claude through instructions to complete tasks.

So judging the nature of a `/name` can't rely solely on whether it has a slash. The real dividing line is whether it directly triggers fixed product logic (→ command) or loads instructions for Claude to orchestrate work (→ Skill). The user-facing entry point is unified; the execution semantics are not.

## Why Custom Commands Still Keep Working

Legacy custom commands were also just a piece of Markdown expanded via `/name`. Claude Code has merged this kind of prompt-based command into the Skills capability model — the legacy directory remains compatible.

The core path shared by both is: user or model selects the name → prompt-based content expands → Claude continues execution.

Skills add supporting files, automatic discovery, invocation control, and more execution options on top of this. So the direction of migration isn't "command syntax deprecated" — it's "single-file prompts gradually upgraded into full capability packages."

If a Skill and a legacy custom command with the same name coexist, Claude Code prioritizes the Skill. Keeping two definitions with the same name around only makes it harder for maintainers to judge which one is actually in effect — the more reliable approach is to remove the duplicate entry once migration is complete.

## Who Can Invoke · Two Independent Switches

By default, both the user and Claude can invoke a Skill:

| Configuration | User-invocable | Claude-invocable | Typical use |
|---|---:|---:|---|
| Default | Yes | Yes | Ordinary reusable workflows |
| `disable-model-invocation: true` | Yes | No | Workflows like deploy or commit whose timing the user must control |
| `user-invocable: false` | No | Yes | Background knowledge, internal conventions, and other content the model loads on demand |

The two fields address different questions:

- `disable-model-invocation` asks: can Claude proactively select it?
- `user-invocable` asks: should it appear as a user command at all?

### User-Only Invocation

```yaml
---
name: deploy-production
description: Deploys the current version to production
disable-model-invocation: true
---
```

The deploy Skill can still contain a full checklist workflow — but it won't self-activate just because Claude judges "the code looks ready." The user must explicitly type the command.

### Claude-Only Invocation

```yaml
---
name: legacy-system-context
description: Domain constraints for the legacy order system · use when working on legacy order code
user-invocable: false
---
```

This kind of Skill functions more like on-demand reference material. The user doesn't need to type a `/legacy-system-context` that has no action semantics — Claude loads it when relevant during a task.

The direction of invocation should follow the nature of the capability, not default settings left unexamined.

## Why "User-Invocation-Only" Reduces Discovery Cost

For the model to proactively invoke a Skill, it must see that Skill's name and description in the candidate context. If a Skill explicitly forbids model invocation, continuing to expose its description to the model long-term serves no purpose.

Claude Code therefore ties invocation control to capability exposure as well: for Skills the model can invoke, the metadata needs to stay in the candidate list long-term; for Skills that are user-invocable only, the user has already located it via `/name`, so the metadata no longer needs to bear the burden of model matching.

This shows that invocation control isn't just a permission semantic — it also affects the context cost of the first layer of progressive disclosure.

Conversely, `user-invocable: false` only hides the user entry point — Claude still needs the description in order to proactively select it.

## User Invocation Doesn't Mean the User Has Approved All Subsequent Actions

When a user types `/release-check`, they've only explicitly approved "adopting this checking workflow." It doesn't necessarily mean:

- Permission to execute arbitrary shell commands;
- Permission to modify all files;
- Permission to release to production;
- Permission to bypass workspace trust;
- Permission to bypass the sandbox.

A Skill can declare that certain tools are pre-authorized, and Claude Code can also set permission rules for a Skill — but these belong to a separate governance layer. Invocation identity only answers "who can start the capability" — it shouldn't be misread as "once started, the capability has unlimited permissions."

Likewise, `disable-model-invocation` isn't a complete security boundary either. It prevents Claude from proactively activating the Skill through the normal invocation entry point — but the Skill file still sits on disk, and its associated scripts and external systems still need their own permissions and isolation.

## User Invocation Doesn't Mean Deterministic Execution

A Skill might state:

```markdown
1. Run tests
2. Check the version number
3. Output a report
```

Even if the user explicitly types `/release-check`, the model still interprets the instructions from there. If the environment lacks a test command, if the context contains conflicts, or if a tool call fails, Claude has to judge how to recover.

So what manual invocation provides is a **deterministic choice**, not a **deterministic execution trace**.

If a step must be executed unconditionally and mechanically, consider:

- Hardcoding the step with a script;
- Triggering it via a Hook on a fixed event;
- Blocking disallowed actions via permissions;
- Verifying the final result through CI or an external system.

A Skill is responsible for guiding behavior — it shouldn't be expected to shoulder enforcement on its own.

## A Skill Can Combine with Other Skills

Invoking a Skill doesn't switch the session into a mutually exclusive mode. A single task might require:

```text
release-check
  + security-review
  + changelog-style
```

Their instructions will jointly shape subsequent work. This is the source of Skill composability — and also the source of conflict risk:

- Do two Skills demand different output formats?
- Do they give contradictory tool-usage orders?
- Do both assume they own the entire main workflow?
- Which one should merely provide reference, and which is actually the task workflow?

Composing capabilities isn't simply adding more prompts together. The clearer a Skill's boundaries, the easier it is for instructions to cooperate. If every Skill claims to own the entire task, they'll compete with each other once activated simultaneously.

`disable-model-invocation` and `user-invocable` first determine who initiates a Skill — they don't yet determine whether it runs in the main conversation or a subagent, which belongs to execution context and is left for piece 06. The essence of Skill invocation, then, isn't executing a saved macro — it's bringing a set of on-demand operational knowledge into the current task: **user invocation provides a deterministic choice, model invocation provides automatic routing, and both ultimately hand the instructions to Claude, who then lets the Tools turn the method into action.**

## Coming Up Next

Once a Skill is selected, the body of text on disk still isn't the final content Claude sees. `$ARGUMENTS`, positional arguments, Skill directory variables, and dynamic shell output all modify the prompt before it enters the context. The next piece, [05 · Prompt Rendering · From Arguments to Dynamic Context](05-prompt-rendering.md), will unpack this preprocessing layer and answer a security question: **why might a command Claude never saw already have been executed?**

## References

- Anthropic Claude Code official documentation: [Control who invokes a skill](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Restrict Claude's skill access](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Bundled skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Commands](https://code.claude.com/docs/en/commands)
- Previous piece: [03 · Capability Discovery · From a Directory to Claude's Candidate List](03-discovery.md)
- [Tool Mechanism: How Claude Uses Tools](../tool-mechanism.md)
- [01 · From Tool Declaration to Pre-Execution Approval](../agent-loop/01-tool-permission.md)
