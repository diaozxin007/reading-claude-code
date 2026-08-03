> This is the 06th article in this series — building on the messages array / cache / compaction / CLAUDE.md family foundation laid by the previous five articles, this one covers how context is isolated when Claude Code spins up **multiple loops within the same process**.
>
> The sister-series article [Loop 09](../agent-loop/09-sidechain.md) covers the **execution-flow perspective** — sub-agents run through the same queryLoop, routed by an `agentId` flag. This article covers the **context perspective** — where a sub-agent's messages array comes from, how it's assembled, how results get carried back to the main loop when it's done, and what pitfalls lie along the way.
>
> The two articles cover different facets of the same subject — read whichever you need.

## Starting Point: The Main Loop Runs Into an "Exploratory" Job

Suppose you ask Claude Code: "Look through every React component in this monorepo that uses `useMemo` — which ones have the wrong dependency array?"

The intuitive approach: have the main loop do it directly — grep the whole repo, get 100-odd candidate files, Read them one by one, analyze them one by one.

**The problem with this path isn't whether the task can be finished — it's what's left in the main context afterward**:

- All 100 grep results sit in the messages array
- All 100 Read file contents sit in the messages array
- All 100 rounds of intermediate reasoning sit in the messages array
- The user's next question is totally unrelated, but the main loop still has to carry the memory of these 100 files with it

The main context gets blown out in one shot by this "exploratory task." No matter how much compaction happens afterward, it's cleaning up **contamination** left behind by this one exploration.

**Sub-agents are the answer to this scenario** — the main loop says "spin up a new AI, let it explore independently, and just tell me the conclusion when it's done." The reading, analysis, and reasoning across 100 files all happen inside **another loop**. The main loop only gets back a paragraph of conclusion.

From the main loop's messages array perspective: the entire exploration leaves behind **exactly one tool_result** (that conclusion paragraph). The messages prefix before and after stays completely stable — the main loop's cache isn't touched at all by this exploration.

This is Anthropic's official **"sub-agent decomposition"**, one of the 4 major strategies. From a context perspective, it's essentially **trading an isolated messages array for a clean main messages array**.

## 1. Independent Context for the Agent Tool — How the Sandbox Gets Started

Inside the main loop, sub-agents are launched through a tool called `Agent` (the production name is Agent; the alias Task is retained — later when we talk about the "Task family," that's a different set of things, covered later in this article).

When calling the Agent tool, the main loop passes three parameters:

1. **`subagent_type`** — pick a sub-agent preset (e.g. `general-purpose` / `code-reviewer`)
2. **`prompt`** — a specific instruction for the sub-agent
3. **`description`** — a one-line summary (used only for UI display)

The main loop then **recursively calls queryLoop** (see [Loop 09](../agent-loop/09-sidechain.md)) — but the `toolUseContext` passed to the sub-agent has **an empty messages array**.

**What the sub-agent's messages array looks like at startup**:

```
[
  { role: 'user', content: <the single prompt from the caller> }
]
```

**Just one entry.** No history from the main loop, no tools run before, no files read before, no prior reasoning.

The system prompt is also **built from scratch**:

- The main loop's system prompt carries all the introduction of the Claude Code main agent / everything related to the user's CLAUDE.md
- The sub-agent's system prompt is **the subagent-definition's Markdown body plus a default sub-agent boilerplate preamble**
- **It does not carry the user's global CLAUDE.md**, and does not carry the project CLAUDE.md — the latter is the main loop's `prependUserContext` behavior (see [Article 05](05-claude-md-family.md)); sub-agents take a different path

**The point of this design**: keep the sub-agent **focused only on the one thing it was assigned**. The main loop's history, the project conventions in CLAUDE.md, prior conversation context — all of that is noise to a sub-agent. The smaller the sandbox, the better.

## 2. What the Main Loop Gets Back After a Sub-agent Finishes

A sub-agent runs a complete loop of its own — its own tool calls, its own stop_reason judgment, its own recovery. It ends when it hits `end_turn` or a user-defined stop condition.

When it finishes, the Agent tool **extracts the last paragraph of text** from the sub-agent's final assistant message — just that one paragraph — and returns it to the main loop as the content of a tool_result.

Roughly, the tool_result structure the main loop sees is:

```
<the last paragraph of assistant text — usually the sub-agent's conclusion>

<usage>
  total_tokens: 88551
  tool_uses: 47
  duration_ms: 42311
</usage>
```

**That usage XML block** is where the `subagent_tokens: N` value visible in the main loop comes from. The main loop has no idea what the sub-agent's internal messages array looks like — it only knows **total token count, total tool call count, and total duration**.

**Counter-intuitive**: the main loop can never see the sub-agent's intermediate process. If the main loop wants to ask "how did you arrive at this conclusion" — it can only infer from the sub-agent's written conclusion. It has no access to the intermediate tool_use / tool_result sequence.

**This is deliberate**: the sub-agent is a "summary generator" — the main loop only consumes the summary, and the intermediate process belongs to **inside the sandbox**. If the main loop could see the entire intermediate process, that would be no different from "the main loop just doing it directly." The whole point of isolation would be lost.

## 3. Fork Is the One Exception — Inherits the Parent but Erases tool_result

Everything above describes the **default sub-agent**: a brand-new context carrying just one user prompt.

**Claude Code also has a launch mode called fork** — triggered when `subagent_type` is empty and `feature('FORK_SUBAGENT')` is enabled (still in gradual rollout, not on in every build).

The key difference with fork: **it inherits the parent's complete messages array.**

But counter-intuitively: **what it inherits is the "messages array structure," not the "messages array content."** Specifically — every tool_result block in the parent's history is **replaced with the same fixed string** in the fork's messages array:

> `Fork started — processing in background`

**Why is it designed this way**:

- Suppose a conversation forks 100 times (e.g. batch-processing 100 URLs), and each fork has to run an independent loop
- If every fork carried the parent's real tool_result content, every fork's history prefix would be different — cache would never hit — all 100 would be cache writes — costs would explode
- Swap in a placeholder instead: all 100 forks' messages prefixes are **byte-for-byte identical** — the first fork builds the cache, the remaining 99 all hit

This is the "cache static ≠ semantically static" mindset from [Article 03](03-prompt-cache.md) taken to the extreme — semantically, a fork wants its sub-agent to "know that the parent ran some tools before," but it only preserves the "structural fact that a tool was run" while flattening the actual tool_result — in exchange for a high cache hit rate.

The fork version of history that a sub-agent receives looks like this:

```
[
  ...all of the parent's user / assistant messages (verbatim)...,
  { role: 'user', content: '<specific instruction for the fork>' }
]
```

The tool_use blocks inside each assistant message are preserved, but the paired tool_result is always that placeholder string. Structure preserved, content erased — that's the core technique of fork.

## 4. Worktree Isolation — Multiple cwds Coexisting in One Process

Beyond context isolation, sub-agents can also opt into **filesystem-level isolation** — specified via the `isolation: worktree` parameter.

Once enabled:

- Claude Code kicks off by running `git worktree add` to create a new worktree, located at `.claude/worktrees/agent-<first 8 chars of agentId>`
- The sub-agent's cwd is this worktree — its Read / Write / Bash all execute here
- When the sub-agent finishes, it's cleaned up with `git worktree remove --force` + `git branch -D`

**At this point you might wonder**: if the main process is running multiple sub-agents at once (e.g. 5 forked out), each sub-agent needs its own independent cwd — how does this even work in Node.js?

**The naive approach**: have each sub-agent call `process.chdir()`. But chdir is **process-scoped** — the entire process shares one cwd — if one sub-agent changes the cwd, every other sub-agent and the main loop change with it. Completely unusable.

**Claude Code's approach**: **AsyncLocalStorage** — a Node.js API that lets you maintain "local variables" scoped to an **async call chain**, where each call chain sees a different value.

Concretely, it looks like this:

```
Main loop's async call chain  ─→  cwd in ALS = /project (original)
Sub-agent A's call chain      ─→  cwd in ALS = /project/.claude/worktrees/agent-abc12345
Sub-agent B's call chain      ─→  cwd in ALS = /project/.claude/worktrees/agent-def67890
```

Every tool reads its cwd from `AsyncLocalStorage.getStore()` — **not** from `process.cwd()`. So within a single process there can be dozens of sub-agents, each believing it has its own independent cwd, without stepping on one another.

**This is a technique normally seen only in server frameworks** (e.g. request-scoped context) — using it in a CLI is one of Claude Code's engineering highlights.

## 5. The Task Family — Two "Tasks" Sharing the Same Word

Claude Code has **two entirely different task stores**, both called task, which readers very easily confuse.

| Store | Purpose | Storage location | Common tools |
|---|---|---|---|
| **Todo v2 · disk** | The user's TODO list, like a checklist | `~/.claude/tasks/<listId>/<taskId>.json` | TaskCreate / TaskGet / TaskList / TaskUpdate |
| **Running-task registry · memory** | Background bash runs, launched sub-agents | `AppState.tasks` · Map · prefixed keys | TaskOutput / TaskStop |

The running-task registry's keys are prefixed — a single letter tells you what kind of task this is:

- `b` — Bash (background bash task)
- `a` — Agent (a launched sub-agent)
- `r` — Remote (a task run remotely)
- `t` — Teammate (another agent in the team)
- `w` — Workflow
- `m` — Monitor (long-task watcher)
- `d` — Dream (experimental)

**These two stores collide in vocabulary** but are **behaviorally unrelated**:

- Todo v2 is **for display to the user** — it remains on disk after the session ends, and can be resumed next time
- Running-task is **for the harness to track what's currently running** — it's gone once the process ends

In one sentence: **Todo v2 is a notebook, Running-task is a process table.** The name collision is historical baggage — internally they're two completely different things.

## 6. TaskOutput Is Deprecated — Points You to Read Instead

Every entry in the running-task registry corresponds to a `.output` file on disk, storing that task's output.

Historically there was a `TaskOutput` tool, used by the main loop to read a given running-task's output. But in the current build:

- The `TaskOutput` tool description explicitly says `[Deprecated] — prefer Read on the task output file path`
- `isEnabled()` returns false — unless the compile-time constant `"external" === 'ant'` holds
- That literal comparison is always false, and Terser dead-code-eliminates the branch

**In other words — in the open-source/leaked build, TaskOutput is turned off.** The main loop is guided to open `.output` files directly with the **Read tool** instead.

**At this point you might think**: fine, just Read the `.output` file and that's the final answer — deprecated is deprecated, no big deal.

**But there's a trap hiding inside `.output`.**

## 7. The `.output` Symlink Trap — Reading It Can Blow Up Your Context

The `.output` file takes **completely different forms** depending on the task type.

### For a local_bash task

`.output` is a **real byte-for-byte file** — it stores the bash process's stdout and stderr. Read it, and you get exactly the log you're after.

It's opened with the `O_NOFOLLOW` flag — refusing to dereference symlinks — guaranteeing you read the real bytes, and that a symlink attack can't redirect you elsewhere.

### For a local_agent task

`.output` is **not a byte file** — it's a **symlink**. It points to:

```
.claude/subagents/<subdir>/agent-<agentId>.jsonl
```

And `agent-<agentId>.jsonl` is the sub-agent's **full sidechain transcript** — the **complete conversation history** — every user / assistant / tool_use / tool_result message is in there, each potentially several KB, and a sub-agent that ran 100 turns could produce a JSONL file several MB in size.

**If the main loop Reads this `.output`**:

- The Read tool defaults to reading 2000 lines — but every line in the JSONL is one complete message — 2000 lines is the full byte content of 2000 messages
- All of it gets stuffed into the main loop's messages array
- The main loop's context instantly gets blown out by the sub-agent's entire conversation history — potentially exceeding 200K in one shot
- And all of this was already conveyed to the main loop via **one paragraph of conclusion text** from the sub-agent — the Read just hauls back into the main loop exactly the contamination the sandbox was set up to avoid in the first place

**This is the origin story behind the output_file-related system-reminder warnings you see in this session's environment** — the harness layer trying to warn the model that "this task's `.output` is agent-type, don't Read it."

Counter-intuitive: the same filename `.output` — **for a bash task it's bytes, for an agent task it's a symlink to a full conversation** — you have to determine the task type before you Read.

## 8. SendMessage — A Mailbox System Across Agents

Everything above describes the one-way parent → sub-agent launch relationship. Claude Code has another sub-agent scenario — **multiple sub-agents running in parallel that need to talk to each other**.

For example: a "researcher" agent looking things up, a "reviewer" agent reviewing — both still running — and the reviewer wants to ask the researcher "did you find X yet?"

This cross-agent communication goes through the `SendMessage` tool, which is backed by a **file-based mailbox system**.

**Key design**: the mailbox is **not in memory** — it lives on disk at `~/.claude/teams/<teamName>/config.json`. The team's member list also lives here — agentName maps to agentId, and it also stores tmuxPaneId and backendType (local / remote / teammate).

Sending splits into two paths:

- **Local delivery** (recipient is in the same process) — goes straight into the recipient's `pendingMessages[]` queue (hung off `LocalAgentTaskState`), consumed on the recipient's next loop iteration
- **Team delivery** (recipient is in a different process / a different machine) — writes to the team directory's mailbox file, which the recipient polls

**Why file-based rather than in-memory**: because in the team scenario, the recipient might be a Claude Code instance running **on another machine**. Using a file directory as the mailbox — one that could even sit on a network share — is the simplest cross-process / cross-machine communication protocol.

**The member list is also file-based**: when a sub-agent joins a team, it writes to the member table; when it leaves, the entry is removed. Team membership is decoupled from an agent's lifecycle — if one agent dies, the team structure stays intact.

## 9. The Workflow Tool Is Currently Just a Name Stub

The Task family also includes a tool called `workflow` — but in the current build it's **just a name constant**, with no real implementation behind it. It requires the `feature('WORKFLOW_SCRIPTS')` gate to activate, and it hasn't shipped yet.

**Why leave behind a name stub**: to reserve a namespace for the tool, so that upstream UI / SDK / official docs can start writing "this tool exists" ahead of time, and swap in the real implementation later — a one-time investment in API stability.

If you run into the name `workflow`, just remember: it has no real implementation right now.

## 10. The Boundaries of Isolation — What's Isolated, What Isn't

Everything covered above adds up to the sub-agent isolation guarantee. But this isolation **isn't total** — understanding the boundary matters.

### Isolated

- **Context** — the messages array is independent (brand-new by default / fork is the special case)
- **cwd** — isolated via AsyncLocalStorage; multiple agents in the same process each have their own independent cwd
- **Session-level permission system** — when a sub-agent starts, the main loop's session-level `alwaysAllow` rules are cleared, replaced with the sub-agent's own `allowedTools` (see [Loop 01](../agent-loop/01-tool-permission.md))
- **Transcript** — a sub-agent's messages land in `.claude/subagents/agent-<id>.jsonl`, keeping the main sessionId.jsonl clean (see [Loop 09](../agent-loop/09-sidechain.md))
- **Skill state** — skill invocation state is keyed by `agentId`; parent and child use disjoint key spaces — a sub-agent clears its own share when it exits
- **CLAUDE.md loading** — sub-agents don't load the user's CLAUDE.md; they use a subagent-specific prompt

### Not Isolated

- **Filesystem** — a sub-agent can read anything the parent has Written — there's no sandbox layer. For real filesystem isolation, you need `isolation: worktree`
- **In-process shared state** — aside from cwd, which goes through AsyncLocalStorage, some process-level shell state (e.g. environment variables, the real `process.cwd()`) is shared
- **API key / rate limit** — everything runs under the same user account; quota spent by the main loop and by sub-agents is counted together
- **AbortController** — sub-agents don't get a new one, they **share the parent's** — if the user hits Ctrl-C once, the main loop and every sub-agent stop together

**This "partial isolation, partial sharing" is deliberate**:

- **What's isolated is context-layer stuff** — because context is the core determinant of what the LLM sees, and it's exactly what the main loop is trying to protect by dispatching sub-agents in the first place
- **What's shared is resource-layer stuff** — filesystem, process resources, AbortController — because isolating these too would cost a lot of extra machinery for little corresponding benefit

## 11. The Sister Article, Loop 09, Covers the Other Side of the Same Story

[Loop 09](../agent-loop/09-sidechain.md) covers the **execution-flow perspective** — focused on "sub-agents run through the same queryLoop, routed by a single flag."

That article's focal points:

- A sub-agent isn't a new loop implementation — it's the same queryLoop called recursively
- A dozen-plus `if (!agentId)` branch points (MemoryPrefetch / MCP / Stop hook / cadence, etc.)
- Sub-agents share the main loop's AbortController
- A sub-agent's parentUuid tree links across files

**This article covers the context perspective** — focused on "where a sub-agent's messages array comes from / what's in it / how the result gets carried back to the main loop when it's done":

- The messages array is brand new by default, carrying only one user prompt
- Fork is the sole exception that inherits from the parent — but with tool_result erased to protect cache
- When the Agent tool finishes, it extracts the last assistant text plus usage and stuffs it back into the main loop's tool_result
- For an agent task, `.output` is a symlink to the full sidechain — reading it blows up the context
- SendMessage runs on a file-based mailbox

**Only together do the two articles form the complete sub-agent picture** — the execution-flow article covers how the code reuses a single loop, this one covers how context stays isolated.

## 12. Summary

- **A sub-agent trades an isolated messages array for a clean main messages array** — every intermediate step of a 100-file exploration happens inside the sandbox, and the main loop only gets one paragraph of conclusion
- **A default sub-agent's messages array starts with exactly one entry** (the user-supplied prompt); the system prompt is the subagent-definition's markdown body, and it doesn't carry the user's CLAUDE.md
- **Fork is the sole exception that inherits the parent's history** — but every tool_result is replaced with the same placeholder string, guaranteeing 100 forks' messages prefixes are byte-identical, for a high cache hit rate
- **Worktree isolation relies on AsyncLocalStorage** — multiple sub-agents in the same process each see an independent cwd, rather than sharing one via process.chdir
- **The Task family's two stores collide in vocabulary** — Todo v2 is the on-disk user TODO list, Running-task is the in-memory process registry — internally unrelated
- **TaskOutput is deprecated** — the main loop is guided to Read `.output` directly, but must distinguish the task type first
- **`.output` is a byte file for a bash task, and a symlink to a sidechain JSONL for an agent task** — Reading the latter hauls the sub-agent's entire conversation history back into the main loop, instantly blowing out the main context
- **SendMessage's mailbox is file-based** — stored under `~/.claude/teams/<teamName>/`, supporting cross-process / cross-machine communication
- **Isolation guarantees have boundaries** — context / cwd / permissions / transcript / skill state / CLAUDE.md are all isolated; filesystem / AbortController / API quota are shared
- **The sister article, Loop 09, covers the execution-flow layer of sub-agents** — this one covers the context layer — together they're the complete picture

In one sentence: **a sub-agent isn't as simple as "having another AI help out."** From a context perspective, it's an entire isolation protocol of "sandbox startup / independent run / conclusion carried back / intermediate process stays in the sandbox without contaminating the main loop" — every detail exists to maintain the one invariant: **keeping the main messages array clean**.

---

## References

**Anthropic official**:
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — sub-agent decomposition is one of the 4 major strategies
- [Sub-agents · Claude Code docs](https://code.claude.com/docs/en/subagents) — official sub-agent usage docs

**Claude Code source locations** (v2.1.220):
- Agent tool main entry: `src/tools/AgentTool/AgentTool.tsx`
- Sub-agent system prompt construction: `getSystemPrompt` in AgentTool
- Result extraction: `finalizeAgentTool` in `agentToolUtils.ts`
- Fork placeholder: `src/tools/AgentTool/forkSubagent.ts` · `FORK_PLACEHOLDER_RESULT`
- Fork trigger gate: `feature('FORK_SUBAGENT')`
- Worktree creation: `src/utils/worktree.ts` · `git worktree add`
- cwd isolation: `src/utils/cwd.ts` · AsyncLocalStorage
- Stale worktree cleanup: `cleanupStaleAgentWorktrees` · 30 days
- Todo v2: `src/utils/tasks.ts` · `~/.claude/tasks/`
- Running-task registry: `src/tools/Task.ts` · `AppState.tasks` · key prefixes
- TaskOutput deprecated: `src/tools/TaskOutputTool.tsx` · `isEnabled()` false
- `.output` symlink: `src/tools/AgentTool/LocalAgentTask.tsx`
- Bash `.output` O_NOFOLLOW: `src/tools/BashTool/diskOutput.ts`
- SendMessage: `src/tools/SendMessageTool.ts` · `queuePendingMessage` / `writeToMailbox`
- Team config: `src/utils/swarm/teamHelpers.ts` · `~/.claude/teams/<teamName>/config.json`
- Workflow stub: `src/tools/WorkflowTool/constants.ts` · `WORKFLOW_TOOL_NAME`
- Skill state isolated by agentId: `src/utils/skills/state.ts` · `${agentId ?? ''}:${skillName}`

**Related notes in this vault**:
- [00 · Opening · Claude Code's 200K Ledger](00-intro.md) — the 4-strategy overview
- [01 · Agent Loop · How Context Gets Assembled](01-agent-loop.md) — messages array basics
- [02 · From a Single Message to the Three Invariants of the Messages Array](02-message-invariants.md) — message structure
- [03 · Prompt Cache Is the Skeleton — Why Everything Else Looks the Way It Does](03-prompt-cache.md) — the cache-side explanation of the fork placeholder
- [09 · Sidechain · From Sub-agents to agentId Routing](../agent-loop/09-sidechain.md) — sister series, execution-flow perspective
- [01 · From Tool Declaration to Pre-Execution Approval](../agent-loop/01-tool-permission.md) — session-level permission clearing for sub-agents
- Claude Code Tools Research Series (9) · Agent — earlier notes on the Agent tool
