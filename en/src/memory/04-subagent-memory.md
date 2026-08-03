# 04 · Subagent Memory · From Agent Type to a 3-Layer Persistent Directory

> **TL;DR**: An ordinary subagent gets its own independent context by default — but "independent" doesn't mean "permanently amnesiac." An agent definition can opt into one of three persistent memory scopes: `user`, `project`, or `local`. Each agent type has its own directory and its own `MEMORY.md`, read at spawn time and maintained by that agent during its run. A snapshot is not a live mirror of the parent conversation — it's a project-provided initialization template and explicit update source.

The previous article, [03 · Anthropic API Memory Tool · The memory_20250818 Client-Side Memory Primitive](03-api-memory-tool.md), drew the line between protocol-level memory tools and Claude Code's own file-based memory. This article keeps pursuing that question: when a task is handed off to a subagent, how does long-term experience cross the boundary of a single spawn?

## First, Correct an Intuition — the Parent Agent Doesn't Just Hand Its MEMORY.md to the Child

The parent agent and its subagents have isolated contexts by default. Persistent agent memory is likewise partitioned by **agent type** — it's not a wholesale copy of the parent's auto memory. A code-review agent and a research agent, even running in the same repo, end up with separate memory spaces.

```text
Agent definition (memory: project)
        ↓ spawn
.claude/agent-memory/<agentType>/MEMORY.md
        ↓ builds a dedicated memory prompt
subagent's independent context
        ↓ Read / Edit / Write
next spawn of the same agent type reads it back
```

So what actually crosses the boundary here isn't the parent→child message history — it's **the accumulated experience of a single agent identity across multiple runs**.

## Three Scopes, Three Different Lifecycles

The source code fixes the scope as a three-value union type: `user | project | local`. See `tools/AgentTool/agentMemory.ts:12-14`.

| scope | directory | shared across | typical use |
|---|---|---|---|
| `user` | `<memoryBase>/agent-memory/<agentType>/` | the same user, across projects | general reviewer methodology, personal collaboration preferences |
| `project` | `<cwd>/.claude/agent-memory/<agentType>/` | shareable across project members via version control | project-specific review rules, domain background |
| `local` | `<cwd>/.claude/agent-memory-local/<agentType>/` | current project and machine only | local environment experience unsuited for committing |

When a remote persistent directory exists, `local` moves under the remote mount and is namespaced by the canonical project root; `project` stays cwd-based. See `tools/AgentTool/agentMemory.ts:24-64`.

`user` is not a synonym for "the parent agent's user memory." It's still partitioned by agent type — only its lifecycle spans across projects. The `project` prompt explicitly tells the agent this memory will be shared via version control; `local` explicitly states it will not enter version control. See `tools/AgentTool/agentMemory.ts:138-176`.

## Agent Type Is Also a Security Boundary

Plugin agents commonly use names like `plugin-name:agent-name`. A colon is illegal in a Windows directory name, so the source code replaces it with a hyphen. See `tools/AgentTool/agentMemory.ts:15-22`.

Path checking doesn't just concatenate strings and blindly trust the result. `isAgentMemoryPath()` first normalizes the path, then checks it against the user, project, and local roots separately; for remote local paths, it additionally requires the path to sit under `projects/` in remote memory and to contain an `agent-memory-local` segment. See `tools/AgentTool/agentMemory.ts:67-104`.

The point of this check is to give the FileWrite/Edit permission system an explicit carve-out: an agent can maintain its own memory directory, but "having memory" doesn't grant it arbitrary file-write access.

## What Happens at Spawn Time

`loadAgentMemoryPrompt()` is part of the synchronous prompt-construction path. It does three things:

1. computes the directory from the agent type and scope;
2. fire-and-forgets directory creation;
3. calls `buildMemoryPrompt()` to read that directory's `MEMORY.md` and append scope guidance.

Directory creation doesn't block the spawn. Even if the mkdir hasn't finished, FileWriteTool will create parent directories on its own. This choice avoids letting the React render / synchronous system-prompt callback get stalled by the async filesystem. See `tools/AgentTool/agentMemory.ts:131-176`.

Agent memory reuses auto memory's "index + topic file" structure and its four-category taxonomy, but the entry content goes straight into the agent's prompt — there's no unified loading path here like the main session's `getClaudeMds()`. See `memdir/memdir.ts:268-315`.

## What a Snapshot Actually Is

The snapshot directory lives at:

```text
<cwd>/.claude/agent-memory-snapshots/<agentType>/
├── snapshot.json
└── *.md
```

`snapshot.json` only stores `updatedAt`; each actual scope directory separately has a `.snapshot-synced.json` recording the last synced snapshot time. See `tools/AgentTool/agentMemorySnapshot.ts:10-41`.

There are three possible check outcomes:

| action | condition | behavior |
|---|---|---|
| `none` | no snapshot, or already synced with nothing new | no action |
| `initialize` | snapshot exists but the local side has no `.md` files at all | first-time copy |
| `prompt-update` | local memory already exists, but the snapshot has been updated | leave it to the interaction layer to decide whether to replace |

Initialization copies all regular files from the snapshot except `snapshot.json`, and writes the sync metadata. A replace operation first deletes the `.md` files currently in the target directory, then copies the snapshot over, so old files don't become orphans. If the user chooses to keep the local version, only the sync marker gets updated. See `tools/AgentTool/agentMemorySnapshot.ts:56-196`.

So a snapshot is not "freeze the parent's live memory, discard it once the subagent exits." It's closer to **a seed / upgrade package a project prepares for a given class of agent**. The actual persistent state still lives in the scope directory, to be read and written by future spawns of the same agent type.

## Isolation vs. Inheritance — the Precise Account

| question | answer |
|---|---|
| Can the child agent see all of the parent's conversation? | No, by default — fork agents are a separate mechanism |
| Does the child agent inherit the main auto memory? | Not as a whole — it loads its own agent-type memory |
| Can the child agent write persistent memory? | Yes, once a scope is enabled, into its own directory |
| Does that write flow back into the current parent context? | No — it doesn't automatically become a parent message; future spawns read it back from disk |
| Does a project snapshot automatically overwrite local content? | It can initialize on first use; when local content already exists, it triggers an update decision, not a silent overwrite |

## Decisions, Anti-Patterns, Evolution Signals

### Decisions

- Partition by agent type rather than session ID, so experience is bound to "role capability."
- Use three scopes to express the three lifecycles: cross-project, team-shared, and local-private.
- Snapshots only handle versioned initialization — they don't turn the live directory into shared mutable state.

### Anti-Patterns

- Treating `user` scope as a full inheritance of the parent agent's user profile.
- Storing secrets or machine-specific paths in `project` scope — it may enter version control.
- Using a snapshot as a bidirectional sync directory — replace semantics delete old `.md` files.
- Reusing the same type name for multiple agents with entirely different responsibilities — their memories will contaminate each other.

### Evolution Signals

- The same agent writes conflicting rules across different projects → sink it from `user` down to `project`.
- Project memory fills up with personal preferences → move it to `local` or the main auto-memory's private scope.
- Every snapshot update demands manual judgment → the seed is changing too frequently; shrink the snapshot's content.
- An agent needs to read the parent's decisions from the current turn in real time → that's a message hand-off problem, not a persistent-memory problem.

## Summary

The design focus of subagent memory isn't "how to copy the parent context over" — it's **how a specialized role can accumulate experience across multiple runs without breaking context isolation between agents**. Scope determines how long the experience lives and who it's shared with; agent type determines which role the experience belongs to; snapshot determines how that role obtains versionable initial knowledge.

The next article, [05 · Memory Extraction Pipeline · From Turn End to a Restricted Fork](05-extraction-pipeline.md), digs into auto memory's background gap-filler: how it reuses the main session's cache, restricts its tools, merges concurrent triggers, and reports results back to the UI.

## References

- Claude Code source: `tools/AgentTool/agentMemory.ts:12-176`
- Claude Code source: `tools/AgentTool/agentMemorySnapshot.ts:10-196`
- Claude Code source: `tools/AgentTool/loadAgentsDir.ts`
- Claude Code source: `memdir/memdir.ts:268-315`
- Sister article: [06 · Sub-agent Isolation · From Independent Context to the .output Trap](../context-management/06-sub-agent.md)
