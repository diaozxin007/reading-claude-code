# 08 · Lifecycle · From a Single Load to Compaction

> **TL;DR**: A Skill has four easily-confused states: the on-disk source, the candidate metadata, the rendered content produced by a given invocation, and the preserved copy reattached after compaction. Editing `SKILL.md` affects future discovery and invocation, but does not rewrite instructions that have already entered the conversation. Inline Skill body content persists across turns within the current session, but permission grants do not persist with it. Compaction preserves only the most recent invocations, within a per-item and total budget — it does not re-read the full source file.

The previous piece, [07 · Permission Governance · From Callable to Safely Executable](07-permissions.md), already pointed out one place where the lifecycle splits: Skill instructions may remain in context while the `allowed-tools` grant clears on the next user message.

That is not the only split. Users commonly assume:

```text
A Skill is just the SKILL.md file on disk
```

Once it's actually running, there are at least four distinct objects to distinguish.

## Four States, Four Update Moments

```text
A · Source file
  SKILL.md and supporting files on disk
        ↓ discovery

B · Candidate metadata
  name + description known to the current session
        ↓ invocation + rendering

C · Rendered invocation
  the body with arguments, variables, and dynamic context expanded
        ↓ conversation growth / compaction

D · Post-compact preserved copy
  the most recent Skill content reattached within budget
```

Each is updated by a different event:

| State | When it's produced | What changes it |
|---|---|---|
| Source | Skill created or installed | Editing, Plugin updates, version switches |
| Metadata listing | Session discovers the Skill | Live detection, scope / visibility changes |
| Rendered invocation | User or Claude invokes the Skill | New arguments, new dynamic output, re-invocation |
| Post-compact copy | Conversation compaction | Retention budget, invocation ordering |

Without naming these states first, sentences like "the Skill has been updated," "the Skill has been loaded," and "the Skill is still in effect" all collapse into ambiguity.

## At Session Start, Only a Candidate Index Exists

At the start of an ordinary Claude Code session, the names and descriptions of model-invocable Skills go into a candidate capability listing. At this point:

- Claude knows what capabilities exist;
- it can select among them based on description;
- the full `SKILL.md` body has not entered the conversation;
- references, scripts, and assets have not been auto-loaded either.

This is Level 1 from piece 02. The candidate listing is the earliest part of the Skill lifecycle to enter context, and it's a fixed cost paid on every capability discovery.

Skills restricted to user-only invocation don't need their description matched by the model, so they don't need to expose full discovery information to Claude long-term. Visibility settings can also downgrade a Skill to name-only or hide it entirely.

"Installed" only tells you the source exists; "listed as a candidate" tells you the current model actually has a chance to select it.

## First Invocation: Rendered Content Enters the Conversation

Once a user or Claude activates a Skill, Claude Code fetches the source, substitutes arguments, runs any permitted dynamic context, and produces rendered content.

The official documentation describes this as a single complete message entering the conversation. From that point on, it doesn't just influence the answer at the moment of invocation — it stays in the current session's subsequent context.

```text
Turn 1
  User invokes /release-check
  → Full instructions enter the messages array

Turn 2
  User adds "just check staging"
  → The earlier Skill instructions are still in history

Turn 3
  Claude continues the check
  → No need to re-read the source to know the main flow
```

This is what lets a Skill sustain a multi-turn workflow. The cost is that every token of the body is no longer just a one-time cost at invocation — it keeps being carried forward by subsequent requests as the conversation grows.

## The Skill Persists, but Permissions Don't Persist Along with It

This is a particularly easy state to misjudge:

```text
Turn 1
  /commit Skill activates
  allowed-tools temporarily pre-approves git commands

Turn 2
  Skill instructions are still in context
  The allowed-tools grant has already cleared
```

So on the second turn, Claude still knows the commit workflow, but a sensitive Tool call may prompt for approval again.

This isn't the product forgetting the Skill — instruction lifecycle and permission lifecycle are deliberately different:

- knowledge needs to keep guiding the task over time;
- temporary authorization only serves the moment the user explicitly activated.

If you want long-lived authorization, use session or project permission rules. If you want temporary authorization restored, re-invoke the Skill.

## Editing the Source Does Not Rewind the Current Conversation

Claude Code supports live detection. If the author edits `SKILL.md` mid-session, the candidate description and future invocations can update.

But rendered content that has already entered the messages array is part of the conversation history. The runtime does not go back and replace that message with the new file.

```text
T0 · v1 Skill invoked
  rendered v1 enters context

T1 · disk changes to v2
  source = v2
  candidate metadata can refresh

T2 · normal conversation continues
  rendered v1 is still in messages
```

This is consistent with the fundamental append-only constraint of the message array. History records what was actually loaded at the time — it shouldn't be silently rewritten by future file changes.

There are three options when a new version is needed:

- re-invoke the Skill so v2 enters as new content;
- start a new session so it begins from a fresh candidate state;
- if the current task has already been deeply shaped by the old instructions, explicitly tell Claude to follow the new version going forward.

Live reload updates the definition — it's not a time machine.

## Re-invocation: Compare Rendered Content First

The same Skill might get invoked more than once in a session:

```text
/fix-issue 123
...
/fix-issue 123
```

If the second rendering matches a copy already present in context, appending the full body again just wastes tokens. Claude Code will note with a short message that it's already loaded, rather than duplicating the same content.

But the following cases will produce different rendered content:

- arguments change;
- dynamic shell output changes;
- the source file has been modified;
- session variables or the environment snapshot have changed.

```text
/fix-issue 123
  → rendered A

/fix-issue 456
  → rendered B
```

Even with the same Skill name, A and B are still two different task inputs. The new body needs to enter context, or Claude will only be able to see the old issue.

So the deduplication key isn't "is this the same Skill name," it's "does this rendered content already exist."

## Dynamic Context Means Same-Name Invocations May Naturally Differ

A Skill contains:

```markdown
!`git status --short`
```

The first invocation happens with a clean working tree; the second happens with 5 modified files. The source hasn't changed, but the rendered content has.

This explains two phenomena:

1. re-invocation can refresh an environment snapshot;
2. frequent re-invocation can also repeatedly add large blocks of new output.

Authors should keep dynamic output compact and inject only state that genuinely affects the workflow. Otherwise "refreshing a Skill" becomes a context growth mechanism.

## Supporting Resources Have No Automatic Residency Guarantee

`SKILL.md` guides Claude to read a reference, and the read result enters the conversation as an ordinary Tool result. Its lifecycle follows the same messages and compaction rules — it doesn't get special persistent status just because the file lives in the Skill's directory.

Likewise:

- an unread script source → not in context;
- an executed script → its output enters the Tool result;
- a read asset → its content enters history;
- a file still on disk → can be accessed again next time it's needed.

The Skill folder is the durable source; the current conversation only retains the parts that were actually expanded — this is exactly the long-run shape of progressive disclosure: the on-disk capability package can be large, while the session only remembers the path it actually took this time.

## Forked Skills: The Body Mostly Lives in the Subagent's Context

An inline Skill's rendered content enters the main conversation. `context: fork` instead places the body as a subagent task in an independent context: the main conversation initiates the Skill invocation, the subagent carries the rendered Skill and the intermediate work, and only the final result is brought back into the main conversation.

So the main conversation typically doesn't receive the subagent's full working history — it receives the returned result. A forked Skill's full body and intermediate Tool results mostly consume the subagent's own context.

This is also why forking suits lengthy, process-heavy tasks, but is a poor fit if you expect the Skill to serve as a long-term reference for the main conversation. If the main agent needs to keep following that body of knowledge step by step, inline invocation — or explicitly returning the necessary rules — is more appropriate.

## Compaction: Summaries Alone Can't Preserve a Working Method

As a conversation grows longer, Claude Code performs compaction: replacing large stretches of earlier history with a summary.

If it relied purely on a generic summary, Skill instructions could get compressed down to a single line:

```text
The user invoked release-check.
```

The name survives, but the specific steps, constraints, and resource navigation are lost. Claude afterward can't continue following the original workflow.

For this reason, Claude Code reattaches the content of invoked Skills after compaction. It doesn't re-read every Skill's source in full — it preserves the most recent rendered copy from the Skills the session has already recorded as invoked.

```text
compact summary
  + project context restored
  + invoked Skill preserved content
  → new post-compact context
```

Skills therefore have a stronger recovery path here than ordinary early chat history — but recovery is still budget-constrained.

## Two-Level Budget: 5K per Item, 25K Total

The official documentation gives the current compaction retention rule:

- each Skill retains at most its first 5,000 tokens;
- all reattached Skills together are capped at 25,000 tokens total;
- filling starts from the most recently invoked Skill toward the total budget;
- older Skills may be dropped entirely.

```text
Most recent
  skill-E  5K
  skill-D  5K
  skill-C  5K
  skill-B  5K
  skill-A  5K
  ---------------- 25K
Older Skills
  may no longer be reattached
```

This has three consequences:

1. a `SKILL.md` over 5K tokens may lose its tail after compaction;
2. invoking many Skills means older capabilities may not be restored;
3. critical constraints placed at the end of a body are more likely to be lost after truncation than ones placed near the top.

The open specification recommends keeping instructions to roughly 5K tokens or less, which echoes the product's per-Skill compaction retention cap. It's not that a Skill file absolutely cannot be longer — it's a reminder that recovery reliability drops for longer bodies.

## Compaction Preserves the Rendered Snapshot, Not the Latest Source

Consider:

```text
T0 · Skill v1 invoked
T1 · disk changes to v2
T2 · conversation compacts
```

Compaction needs to keep the conversation semantically continuous, so it should restore the v1 rendered content actually invoked at that time — not silently rewrite past task constraints with v2.

This is consistent with the principle that editing the source doesn't rewind history: the source file governs future invocations; the invocation record captures what rendered content was actually loaded at the time; compaction preservation only continues that invocation record — it doesn't re-bind to the current source. If the user wants v2 adopted after compaction, they should re-invoke v2. Don't treat a disk update as a hot-swap for already-activated instructions.

## The Listing Has Its Own Budget Too

Just as compaction manages the budget for invoked bodies, the session-start candidate listing has its own context budget.

The official Claude Code documentation notes that Skill listing size is controlled as a proportion of the model's context window. When there are many Skills:

- names tend to be preserved;
- descriptions may be shortened;
- less frequently used Skills are more likely to be reduced to just a name;
- `/context` and `/doctor` can help observe the cost of the Skills listing.

This means installing 500 Skills doesn't get you 500 equally clear, auto-matchable capabilities. Disk capacity isn't the bottleneck — metadata visibility is.

Visibility settings offer four typical states:

| State | Claude listing | User `/` menu |
|---|---|---|
| on | name + description | shown |
| name-only | name only | shown |
| user-only | hidden | shown |
| off | hidden | hidden |

This lets users locally reduce noise for shared project Skills without needing to modify the repository's `SKILL.md`.

## After `/clear`: The Source Lives On, the Activated State Ends

The Skill folder is a durable on-disk capability; the rendered invocation is session context. Once a new conversation starts:

- the source remains in its original scope;
- Skill metadata can be rediscovered;
- body content activated in the previous conversation does not automatically remain in effect just because the file still exists;
- it needs to be invoked again when relevant to the new task.

This differs from what Memory does. Memory is responsible for preserving non-derivable background across sessions; a Skill is responsible for preserving a reusable method. A Skill's source persists across sessions, but "what step the previous session had reached in execution" shouldn't automatically become state in the new session because of that.

If work needs to continue, use session resume, task state, or a handoff note — don't write execution progress into the Skill definition.

## A Complete Lifecycle Diagram

```text
Install / create on disk
  SKILL.md + resources
        ↓
Session discovery
  name + description listing
        ↓ matched
Invocation
  args + vars + dynamic context
        ↓
Rendered content
  enters inline context as a single complete instruction block
  or as a forked subagent task
        ↓
Subsequent turns
  instructions persist
  permission grants expire independently
        ↓
Compaction
  5K per item cap · 25K total cap · most recent first
        ↓
New session
  source rediscovered · invocation must happen again
```

A Skill is not a file that maps live onto disk within context in real time: **the source determines how it can be invoked in the future; the rendered content records what was actually loaded this time; compaction only continues that invocation snapshot within budget.**

## Coming Up Next

Once a Skill has matured in a personal directory, it may need to be shared across a project and eventually become a Plugin distributed via a marketplace. Copying files can propagate content, but it can't solve namespace, versioning, dependency, and cross-surface differences. The next piece, [09 · Distribution · From a Personal Folder to a Team Plugin](09-distribution.md), will address how a capability evolves from a local experiment into an installable component.

## References

- Anthropic Claude Code official documentation: [Skill content lifecycle](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Override skill visibility from settings](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Skill descriptions are cut short](https://code.claude.com/docs/en/slash-commands)
- Agent Skills open specification: [Progressive disclosure](https://agentskills.io/specification)
- Previous piece: [07 · Permission Governance · From Callable to Safely Executable](07-permissions.md)
- [04 · The Six Siblings of Compaction · From Manual to Ubiquitous Compression](../context-management/04-compaction.md)
- [08 · After Compaction · Which Memories Come Back Automatically](../memory/08-post-compaction.md)
