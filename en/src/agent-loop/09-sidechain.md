The previous 8 articles all covered **one** loop — the user hits Enter once, the loop spins up, runs to completion, and hands control back to the user. One user, one loop.

But Claude Code also has a counter-intuitive scenario — **a loop nested inside a loop**.

At some point in the main conversation, the LLM decides to call the `Agent` tool — which means "let another AI go do something independent, and just tell me the result." The main loop then spins up a **sub-agent** — the sub-agent runs its own complete loop from start to finish, and when it's done, stuffs the result back into the main loop as a single tool_result.

From the main loop's point of view: this just looks like "some tool ran for a while and returned some text." From the sub-agent's point of view: it's a full-blown loop — with its own messages array, its own tool execution, its own stop_reason judgment.

This article covers sub-agents — specifically one question: **does a sub-agent run through "a separate loop implementation," or "the same loop with a different context"?**

## A Question Where Intuition Gets It Wrong

The naive design: a sub-agent has its **own independent loop implementation** — a dedicated `SubagentLoop` class. The main loop uses `MainLoop`. Each maintains its own state, each processes its own messages array.

**Claude Code does the opposite** — a sub-agent runs through the exact **same** `queryLoop`. One while-true loop covering both scenarios.

The concrete mechanics of starting a sub-agent:

```
Main loop encounters an Agent tool_use
    ↓
Builds a new toolUseContext
    ├─ agentId = a freshly generated id
    ├─ messages = [] (brand new)
    ├─ system prompt = the subagent's own prompt
    └─ other fields...
    ↓
Recursively calls queryLoop(newToolUseContext)
    ↓
Sub-agent loop runs to completed · returns a result
    ↓
The result is stuffed back into the main loop's messages array as a tool_result
```

**Same function, recursive call.** In the main loop, the sub-agent is just one tool call; inside a sub-agent, it can spin up a sub-sub-agent — that's just another level of recursion.

**Why this design**: one codebase covers both scenarios. Fix a bug once, and both the main line and sub-agents benefit. Want to add a new recovery transition? No need to write it twice.

## `agentId` Routing

Covering two scenarios with one codebase means the code needs a way to **distinguish "am I the main loop or a sub-agent."**

Claude Code's solution: a single flag — `toolUseContext.agentId`.

- **Main loop** — `agentId === undefined`
- **Sub-agent** — `agentId === '<generated UUID>'`

The loop has dozens of places checking `if (!toolUseContext.agentId)` — meaning "only do this in the main loop":

**Behaviors that get routed**:

- **MemoryPrefetch** — loading user memory at session startup, main loop only; sub-agents use their own subagent-specific prompt
- **Mobile UI summary** — after the main loop finishes, a Haiku summarization pass runs for mobile display — sub-agents don't summarize when they finish
- **MCP state cleanup** — the main loop cleans up MCP connections when it ends; sub-agents don't (doing so would affect the main loop's reuse of those connections)
- **Stop hook re-entrancy lock** — the Stop hook only fires in the main loop; a sub-agent finishing doesn't trigger it
- **Cadence reminders** — things like the TodoWrite reminder that fires every 10 turns — only the main loop counts turns
- **CLAUDE.md loading** — the main loop loads CLAUDE.md at startup; sub-agents use their own subagent-specific prompt and don't load the user's CLAUDE.md
- **Session storage message appending** — the main loop appends messages to the main sessionId's JSONL; sub-agents append to their own independent JSONL

**Every routing check is `if (!agentId)`** — one flag covers a dozen-plus distinct decision points. Simple, but it comes at a cost to readability — you have to understand why each branch exists when reading the code. What you get in exchange is the benefit of **shared loop code**.

## Sidechain Transcript — an Independent File

The main loop's messages are all persisted to:

```
~/.claude/projects/<encoded project name>/<sessionId>.jsonl
```

One line per message, each carrying a `parentUuid` pointing to the previous one (see [Context 02](../context-management/02-message-invariants.md)).

**A sub-agent's messages don't go into this file.** They're written to:

```
.claude/subagents/agent-<agentId>.jsonl
```

**An independent file, appended independently.**

**Why a separate file**:

- The main loop's and the sub-agent's messages arrays are **separate** — a sub-agent's messages never enter the main loop
- If both were written to the same file, how would you tell which messages are main-loop and which are sub-agent when resuming a session?
- With a separate file, **the main sessionId.jsonl stays clean** — only main loop messages — resume logic stays simple
- Sub-agent messages are kept around as **debugging information** — you can open this separate file to inspect them when needed

**What trace of a sub-agent remains in the main sessionId.jsonl**: only the **final tool_result** the main loop received (the sub-agent's final output), matched by `tool_use_id`. None of the intermediate process ever enters the main log.

## How the `parentUuid` Tree Works in the Sub-agent Scenario

The main loop's messages form a `parentUuid` chain — a tree, rooted at session start — and tracing back from a leaf gives you the current conversation.

A sub-agent's messages also form a `parentUuid` chain — but it's a **separate** tree, stored in its own JSONL file.

**Cross-file continuity**: for a sub-agent's message tree, the first message's `parentUuid` points to the **uuid of the tool_use message in the main loop that launched the sub-agent**. In other words:

```
Main tree:
  msg 1 (root)
    └── msg 2 (user input)
          └── msg 3 (LLM says it wants to call the Agent tool)
                └── msg 4 (tool_result: sub-agent's result)

Sub tree (separate file):
  msg S1 (parentUuid = uuid of msg 3)
    └── msg S2
          └── msg S3
                ...
```

**The sub tree logically hangs off msg 3 in the main tree.** If you need "the full conversation, including the sub-agent's process" — there's tooling to merge the two trees. By default you only see the main tree — clean.

## Sub-agent Permission System Reset

Echoing a point from [Article 01](01-tool-permission.md): when a sub-agent starts, the main loop's session-level `alwaysAllow` rules are **wiped clean** — only the CLI-argument-level rules (fixed at startup) survive — and the session-level rules are replaced with the sub-agent's own `allowedTools`.

**The reasoning behind this**: a sub-agent is **another AI** — the user's trust in the main loop (e.g. "always allow Bash") doesn't automatically extend to a sub-agent. Default to conservative.

The cost: a sub-agent may have to re-request approvals that were already granted in the main loop. The benefit: a safe default.

**The deeper rationale behind this design**: because a sub-agent runs through the same queryLoop code, it inherently **inherits all of the main loop's capabilities** (every tool, every recovery path, every hook). Wanting a sub-agent to **have fewer capabilities** can only be achieved through **context restriction**:

- **Wiping permission rules** — reduces what's already been approved
- **`allowedTools` whitelist** — explicitly lists what the sub-agent is allowed to call
- **Independent CLAUDE.md** — overrides any "always let the LLM do X" instructions from the user's CLAUDE.md

All of these are **isolation at the context layer**, not the code layer. The code is shared, the capability is complete — but the context each sub-agent sees is **exclusively its own**.

## Fork — a Special Form of Sub-agent

Beyond ordinary sub-agents, Claude Code also has a mechanism called **fork** (covered in detail in [Context 06 · Sub-agent Isolation](../context-management/06-sub-agent.md)).

The key differences between fork and an ordinary sub-agent:

- **Ordinary sub-agent** — a brand-new context, knowing only the subagent-specific prompt and the single instruction it was given. No idea what happened earlier in the main loop
- **Fork** — **inherits the main loop's complete messages array**, but every tool_result is **replaced with a placeholder** (a fixed string: `Fork started — processing in background`)

**Why fork replaces tool_result**: fork is typically used for "batch-launching many similar sub-agents" — each fork handling one piece of a larger job. If every fork kept its full tool_result history, every fork's history would differ, and **prompt cache would never hit at all** (see [Context 03 · Prompt Cache](../context-management/03-prompt-cache.md)). Swap in a placeholder instead — every fork's history is byte-for-byte identical — **cache hits massively** — and the cost of batch forking drops sharply.

**How this connects to the loop theme**: fork is an extreme application of "sharing queryLoop code" — one call, 100 forks, each running a full loop, but because the histories are identical, most requests hit cache. The loop architecture supports this kind of batch invocation without any extra code — they're all just ordinary sub-agents.

## How Interrupting a Sub-agent Works

The previous article covered interrupt — the user hits Ctrl-C once, and the `AbortController` notifies the entire loop.

**Does a sub-agent have its own independent AbortController?**

**No** — a sub-agent uses the one **handed down from the main loop**. The main loop's abort controller is passed to the sub-agent via `toolUseContext.abortController`. When the main loop is interrupted, the sub-agent is interrupted too.

**This is a natural consequence of the "shared loop" design** — one controller covers both main and sub. The user hits Ctrl-C, and every currently-running sub-agent stops along with it.

**But conversely**: an error inside a sub-agent — say the sub-agent hits prompt_too_long — **does not interrupt the main loop**. The sub-agent's error is handled through recovery inside its own loop (see [Article 07](07-retry-recovery.md)); only if it can't be recovered does it get returned to the main loop as a tool_result with is_error, and the main loop decides what to do about it.

**This is good isolation**: problems inside a sub-agent are resolved inside the sub-agent — they don't affect the main loop's stability.

## Wrap-up — the Mechanisms from the First 8 Articles All Hold for Sub-agents

Because a sub-agent runs through the **same queryLoop**, everything covered in the first 8 articles **holds true for sub-agents too**:

- **[01](01-tool-permission.md)** — sub-agents also declare tools and go through permission approval (but with an independent rule set)
- **[02](02-hooks.md)** — most hooks fire for sub-agents too (except main-thread-only ones like the Stop hook)
- **[03](03-parallel-scheduling.md)** — tools inside a sub-agent are also batched and parallelized by isConcurrencySafe
- **[04](04-stop-reason.md)** — sub-agents also judge stop_reason to decide whether to continue or exit
- **[05](05-query-engine.md)** — the same 7-transition state machine applies to sub-agents
- **[06](06-streaming.md)** — a sub-agent's API calls are also SSE streams (though by default not shown to the UI layer)
- **[07](07-retry-recovery.md)** — sub-agents also have the 8-layer recovery
- **[08](08-interrupt.md)** — sub-agents share the AbortController and can be interrupted

**The same loop, two contexts** — this is the final insight the Loop series wants to leave with the reader. The loop isn't "the mechanism for a user to talk to an LLM" — it's the **general-purpose mechanism inside Claude Code for "an AI autonomously advancing a task."** User conversations, sub-agents, forks — they're all instances of it.

## Summary

- **A sub-agent runs through the same queryLoop** — recursive call, routed by the `agentId` flag
- **A dozen-plus `if (!agentId)` routing points** — MemoryPrefetch / summarization / MCP / Stop hook / cadence / CLAUDE.md / storage, etc.
- **An independent transcript file** — `.claude/subagents/agent-<id>.jsonl`, keeping the main sessionId.jsonl clean
- **`parentUuid` links across files** — the root of a sub-tree hangs off the corresponding tool_use message in the main tree
- **Permission system is wiped clean** — the user's trust in the main loop is not trust in a sub-agent
- **Context isolated, code shared** — full capability, but each sub-agent only sees the context that's exclusively its own
- **Fork is a special form of sub-agent** — inherits history but replaces tool_result with a placeholder, to preserve prompt cache
- **Sub-agents share the main loop's AbortController** — a main-loop interrupt affects sub-agents; a sub-agent error doesn't affect the main loop
- **The mechanisms from the first 8 articles all hold for sub-agents** — the loop is the general-purpose mechanism for "an AI autonomously advancing a task," not just "user conversation"

Next article: [10 · Wrap-up · From an Automatic Loop to a General-Purpose Agent Loop](10-conclusion.md), which closes out the whole series by distilling 5 core insights and stitching the first 10 articles back into one complete map.

---

## References

**Primary file locations** (v2.1.220):
- `src/query.ts` — the `queryLoop` main loop, with recursive-call support for sub-agents
- `src/tools/AgentTool/AgentTool.tsx` — the Agent tool, sub-agent launch entry point
- `src/tools/AgentTool/runAgent.ts` — sub-agent execution, permission reset, independent storage
- `src/utils/sessionStorage.ts` — the independent file path for sidechain transcripts
- `src/tools/AgentTool/forkSubagent.ts` — the fork mechanism, tool_result placeholder replacement

**Related articles**:
- [00 · Opening · From Chat Window to Loop](00-intro.md) — where the Loop series starts
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) — echoes the sub-agent permission reset
- [05 · QueryEngine Main Loop · Full State Machine Picture](05-query-engine.md) — the mechanism behind agentId flag routing
- [08 · Interrupt · From Ctrl-C to Synthesized tool_result](08-interrupt.md) — sub-agents sharing the AbortController
- [02 · From a Single Message to the Three Invariants of the Messages Array](../context-management/02-message-invariants.md) — the parentUuid tree structure
- [03 · Prompt Cache Is the Skeleton — Why Everything Else Looks the Way It Does](../context-management/03-prompt-cache.md) — the fork placeholder's role in preserving cache
- [06 · Sub-agent Isolation](../context-management/06-sub-agent.md) — the full context-perspective discussion of sub-agents

**Anthropic official**:
- [Agent tool](https://code.claude.com/docs/en/sub-agents) — sub-agent usage from the user's perspective
