The previous eight chapters all covered **one** loop: the user presses Enter once, the loop starts running, continues until completion, and hands control back to the user. One user, one loop.

But Claude Code also has a counterintuitive scenario: **a loop nested inside another loop**.

At some point in the main conversation, the LLM says it wants to invoke the `Agent` tool—meaning, “Have another AI perform an independent task and report only the result back to me.” The main loop then starts a **subagent**. The subagent runs a complete loop of its own, and when it finishes, its result is inserted into the main loop as a tool_result.

From the main loop's perspective, this is simply “a tool that ran for a long time and returned some text.” From the subagent's perspective, it is a complete loop, with its own messages array, its own tool execution, and its own stop_reason evaluation.

This chapter examines subagents—especially one question: **Does a subagent use a new loop implementation, or the same loop with a different context?**

## A Question That Defies Intuition

The straightforward design would give the sub-agent an **independent loop implementation**—a dedicated `SubagentLoop` class. The main loop would use `MainLoop`. Each would maintain its own state and process its own messages array.

**Claude Code does the opposite**: sub-agents use the **same** `queryLoop`. A single while true loop covers both scenarios.

Here is how a sub-agent is started:

```
The main loop encounters an Agent tool_use
    ↓
Construct a new toolUseContext
    ├─ agentId = generate a new id
    ├─ messages = [] (brand-new)
    ├─ system prompt = the subagent's independent prompt
    └─ other fields...
    ↓
Recursively call queryLoop(newToolUseContext)
    ↓
The sub-agent loop runs to completed and returns its result
    ↓
Insert the result into the main loop's messages array as a tool_result
```

**The same function, called recursively**. In the main loop, a sub-agent is a single tool call; inside the sub-agent, it can start a sub-sub-agent by recursing once more.

**Why design it this way?** One codebase serves both scenarios. Fix a bug, and both the main path and sub-agents benefit. Add a recovery transition, and there is no need to implement it twice.

## Routing with `agentId`

Using the same code for both scenarios means the code must **distinguish between the main loop and a sub-agent**.

Claude Code's solution is a flag: `toolUseContext.agentId`.

- **Main loop** — `agentId === undefined`
- **Sub-agent** — `agentId === '<generated UUID>'`

Throughout the loop, dozens of checks use `if (!toolUseContext.agentId)` to indicate behavior that should occur “only in the main loop”:

**Routed behavior**:

- **MemoryPrefetch** — Loads user memory at the start of a session; only the main loop does this, while sub-agents use their own prompts
- **Mobile UI summary** — Runs a Haiku summary after the main loop ends for display on mobile; sub-agents are not summarized when they finish
- **MCP state cleanup** — Cleans up the chicago MCP connection when the main loop ends; sub-agents do not clean it up, because that would affect reuse by the main loop
- **Stop hook reentrancy lock** — The Stop hook is triggered only by the main loop; a sub-agent finishing does not trigger it
- **Cadence reminder** — Reminders such as TodoWrite run every ten turns; only the main loop tracks the turn count
- **CLAUDE.md loading** — The main loop loads CLAUDE.md at startup; sub-agents use a subagent-specific version and do not load the user's CLAUDE.md
- **Appending messages to session storage** — Main-loop messages are appended to the JSONL file for the main sessionId; sub-agent messages are appended to the subagent's own JSONL file

**Every routing decision uses `if (!agentId)`**: one flag governs more than a dozen distinct behaviors. This is simple, but it comes at a cost to readability—you need to understand why each branch behaves differently. The payoff is **shared loop code**.

## Sidechain Transcript—A Separate File

All main-loop messages are persisted to:

```
~/.claude/projects/<encoded-project-name>/<sessionId>.jsonl
```

There is one message per line, and each message carries a `parentUuid` pointing to the previous one (see [Context 02](https://readingclaude.club/zh/context-management/02-message-invariants)).

**Sub-agent messages are not written to this file**. They are written to:

```
.claude/subagents/agent-<agentId>.jsonl
```

**A separate file, appended independently**.

**Why use a separate file?**

- The main loop and sub-agent have **separate** messages arrays—the sub-agent's messages never enter the main loop
- If both were written to the same file, how would session recovery distinguish main-loop messages from sub-agent messages?
- With separate files, **the main sessionId.jsonl remains clean**—it contains only main-loop messages, which keeps recovery logic simple
- Sub-agent messages are retained as **debugging information** and can be inspected by opening the separate file when needed

**The only trace of the sub-agent in the main sessionId.jsonl** is the **final tool_result** received by the main loop—the sub-agent's final output—paired through `tool_use_id`. None of the intermediate steps enter the main log.

## How the `parentUuid` Tree Works with Sub-agents

The `parentUuid` chain of main-loop messages forms a tree: the beginning of the session is the root, and tracing backward from a leaf reconstructs the current conversation.

Sub-agent messages also have a `parentUuid` chain, but it forms a **separate** tree stored in its own JSONL file.

**Continuity across files**: the first message in the sub-agent's message tree has a `parentUuid` pointing to the uuid of **the tool_use message in the main loop that started the sub-agent**. In other words:

```
Main tree:
  msg 1 (root)
    └── msg 2 (user input)
          └── msg 3 (LLM requests the Agent tool)
                └── msg 4 (tool_result: sub-agent result)

Sub tree (separate file):
  msg S1 (parentUuid = msg 3's uuid)
    └── msg S2
          └── msg S3
                ...
```

**Logically, the sub tree hangs beneath msg 3 in the main tree**. If you need the “complete conversation, including the sub-agent's execution,” tools can merge the two trees. By default, only the clean main tree is shown.

## Clearing the Sub-agent Permission System

As discussed in [Chapter 01](01-tool-permission.md), when a sub-agent starts, the main loop's session-level `alwaysAllow` rules are **cleared**. Only CLI-argument-level rules—the immutable startup configuration—are preserved, while the session-level rules are replaced by the sub-agent's own `allowedTools`.

**The principle behind this**: a sub-agent is **another AI**. The user's trust in the main loop—for example, “always allow Bash”—does not imply the same trust in a sub-agent. The default is conservative.

The cost is that the sub-agent may need to go through permission approval again. The benefit is a secure default.

**The deeper reason for this design**: because sub-agents use the same queryLoop code, they inherently **inherit every capability of the main loop**, including every tool, every recovery mechanism, and every hook. Reducing a sub-agent's capabilities therefore requires **context-level restrictions**:

- **Clearing permission rules** — Reduces remembered approvals
- **The `allowedTools` allowlist** — Explicitly specifies which tools the sub-agent may invoke
- **An independent CLAUDE.md** — Overrides instructions such as “always have the LLM do X” in the user's CLAUDE.md

These are all forms of **context-level isolation**, not code-level isolation. The code is shared and the full set of capabilities remains available, but each sub-agent sees only **its own dedicated context**.

## Fork—a Special Form of Sub-agent

In addition to ordinary sub-agents, Claude Code has a mechanism called a **fork** (see [Context 06 · Sub-agent Isolation](https://readingclaude.club/zh/context-management/06-sub-agent) for details).

The key difference between a fork and an ordinary sub-agent is:

- **Ordinary sub-agent** — Starts with a brand-new context and knows only its subagent-specific prompt and the single instruction provided by the user. It does not know what previously happened in the main loop
- **Fork** — **Inherits the main loop's complete messages array**, but replaces every tool_result with a placeholder using the fixed string `Fork started — processing in background`

**Why does a fork replace tool_result values?** Forks are typically used to “start multiple similar sub-agents in a batch,” with each fork handling a separate task. If forks retained the complete tool_result values, each fork's history would differ, and **the prompt cache would miss entirely** (see [Context 03 · Prompt Cache](https://readingclaude.club/zh/context-management/03-prompt-cache)). Replacing them with a placeholder makes every fork's history byte-for-byte identical, producing **large cache hits** and dramatically reducing the cost of batch forks.

**How this relates to the loop architecture**: forks are an extreme application of “sharing the queryLoop code.” One invocation can launch 100 forks, each running a complete loop. Because their histories are identical, most requests hit the cache. The loop architecture supports this batch execution without additional code: they are all ordinary sub-agents.

## How Sub-agent Interruption Works

The previous chapter covered interrupts: the user presses Ctrl-C once, and the `AbortController` notifies the entire loop.

**Does a sub-agent have an independent AbortController?**

**No**. The sub-agent uses the one passed down from the **main loop**. The main loop's abort controller is passed to the sub-agent through `toolUseContext.abortController`. Interrupting the main loop also interrupts the sub-agent.

**This follows naturally from the shared-loop design**: one controller covers both the main loop and its sub-agents. When the user presses Ctrl-C, every running sub-agent stops at the same time.

**The reverse is not true**: an error inside a sub-agent—for example, the sub-agent encountering prompt_too_long—**does not interrupt the main loop**. The sub-agent handles the error through recovery within its own loop (see [Chapter 07](07-retry-recovery.md)). Only if recovery fails does it return the error to the main loop as a tool_result with is_error, leaving the main loop to decide what to do.

**This provides strong isolation**: problems inside a sub-agent are resolved within the sub-agent and do not compromise the stability of the main loop.

## Conclusion—All Eight Previous Mechanisms Apply to Sub-agents

Because sub-agents use **the same queryLoop**, every mechanism covered in the previous eight chapters **also applies to sub-agents**:

- **[01](01-tool-permission.md)** — Sub-agents also declare tools and require permission approval, but use an independent rule set
- **[02](02-hooks.md)** — Sub-agents also trigger most hooks, except those exclusive to the main thread, such as the Stop hook
- **[03](03-parallel-scheduling.md)** — Tools inside sub-agents are also grouped and run in parallel according to isConcurrencySafe
- **[04](04-stop-reason.md)** — Sub-agents also evaluate stop_reason to decide whether to continue or exit
- **[05](05-query-engine.md)** — The sub-agent state machine uses the same seven transitions
- **[06](06-streaming.md)** — Sub-agent API calls also use SSE streams, although they are not shown to the UI layer by default
- **[07](07-retry-recovery.md)** — Sub-agents also have eight layers of recovery
- **[08](08-interrupt.md)** — Sub-agents share the AbortController and can be interrupted

**One loop, two contexts**—this is the final insight of the Loop series. A loop is not merely “the mechanism through which the user converses with the LLM.” It is **Claude Code's general-purpose mechanism for autonomous AI task execution**. User conversations, sub-agents, and forks are all instances of it.

## Summary

- **Sub-agents use the same queryLoop** — Recursive invocation, with routing through the `agentId` flag
- **More than a dozen `if (!agentId)` branches** — MemoryPrefetch, summaries, MCP, the Stop hook, cadence, CLAUDE.md, storage, and more
- **Independent transcript files** — `.claude/subagents/agent-<id>.jsonl`, keeping the main sessionId.jsonl clean
- **Cross-file `parentUuid` linkage** — The root of the sub tree hangs beneath the corresponding tool_use message in the main tree
- **The permission system is cleared** — The user's trust in the main loop ≠ trust in a sub-agent
- **Sub-agent context is isolated while code is shared** — Full capabilities, but each sub-agent sees only its dedicated context
- **A fork is a special form of sub-agent** — It inherits history but replaces tool_result values with a placeholder to preserve the prompt cache
- **Sub-agents share the main loop's AbortController** — Interrupting the main loop affects sub-agents; sub-agent errors do not affect the main loop
- **All mechanisms from the previous eight chapters apply to sub-agents** — The loop is a general-purpose mechanism for “autonomous AI task execution,” not merely “user conversation”

The next chapter, [10 · Conclusion · From an Automatic Loop to a General-Purpose Agent Loop](10-conclusion.md), concludes the series, distills five core insights, and reassembles the first ten chapters into a complete map.

---

## References

**Primary file locations** (v2.1.220):
- `src/query.ts` · `queryLoop` main loop · recursive invocation supports sub-agents
- `src/tools/AgentTool/AgentTool.tsx` · Agent tool · sub-agent entry point
- `src/tools/AgentTool/runAgent.ts` · sub-agent execution · permission clearing · independent storage
- `src/utils/sessionStorage.ts` · separate file path for the sidechain transcript
- `src/tools/AgentTool/forkSubagent.ts` · fork mechanism · tool_result placeholder replacement

**Related chapters**:
- [00 · Introduction · From the Chat Window to the Loop](00-intro.md) · Where the Loop begins
- [01 · From Tool Declaration to Pre-execution Approval](01-tool-permission.md) · The rationale behind clearing sub-agent permissions
- [05 · The QueryEngine Main Loop · A Complete View of the State Machine](05-query-engine.md) · How routing through the agentId flag works
- [08 · Interrupt · From Ctrl-C to a Synthetic tool_result](08-interrupt.md) · Sub-agents sharing the AbortController
- [02 · Three Invariants from a Single Message to a Messages Array](https://readingclaude.club/zh/context-management/02-message-invariants) · The parentUuid tree structure
- [03 · Prompt Cache as the Backbone · Why the Other Mechanisms Take Their Shape](https://readingclaude.club/zh/context-management/03-prompt-cache) · Preserving the cache with fork placeholders
- [06 · Sub-agent Isolation](https://readingclaude.club/zh/context-management/06-sub-agent) · A complete discussion of sub-agents from the context perspective

**Official Anthropic documentation**:
- [Agent tool](https://code.claude.com/docs/en/sub-agents) · A user-facing explanation of sub-agents
