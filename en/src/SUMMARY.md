# Summary

[Preface](preface.md)

# Getting Started

- [Tool Mechanism: How Claude Uses Tools](tool-mechanism.md)

# Interaction Primitives

- [AskUserQuestion](interaction/ask-user-question.md)
- [EnterPlanMode](interaction/enter-plan-mode.md)
- [ExitPlanMode](interaction/exit-plan-mode.md)

# Execution Primitives

- [Grep + Glob](execution/grep-glob.md)
- [Read](execution/read.md)
- [Edit](execution/edit.md)
- [Write](execution/write.md)

# General-Purpose Power

- [Bash](power/bash.md)
- [Agent](power/agent.md)

# State & Scheduling

- [Task Family](state/task-family.md)
- [Background Mechanism](state/background.md)
- [Cron Family](state/cron-family.md)
- [Monitor](state/monitor.md)

# Information Access

- [WebFetch + WebSearch](info/web.md)

---

# Part 2 · Agent Loop Research

- [00 · Opening · From Chat Window to Loop](agent-loop/00-intro.md)
- [01 · From Tool Declaration to Pre-Execution Approval](agent-loop/01-tool-permission.md)
- [02 · Hooks · Programmable Intervention Points on the Loop](agent-loop/02-hooks.md)
- [03 · From Reading Files to Parallel Scheduling](agent-loop/03-parallel-scheduling.md)
- [04 · From "Done Answering" to the 7 Meanings of stop_reason](agent-loop/04-stop-reason.md)
- [05 · QueryEngine Main Loop · The Full State Machine](agent-loop/05-query-engine.md)
- [06 · Streaming · From SSE Events to Character-by-Character Display](agent-loop/06-streaming.md)
- [07 · Retry and Error Recovery · 8 Layers of Recovery Stacked Together](agent-loop/07-retry-recovery.md)
- [08 · Interrupt · From Ctrl-C to a Synthetic tool_result](agent-loop/08-interrupt.md)
- [09 · Sidechain · From Sub-agents to agentId Routing](agent-loop/09-sidechain.md)
- [10 · Closing · From an Automatic Loop to a General-Purpose Agent Loop](agent-loop/10-conclusion.md)

---

# Part 3 · Context Management Research

- [00 · Intro · Claude Code's 200K Ledger](context-management/00-intro.md)
- [01 · Agent Loop · How Context Gets Assembled](context-management/01-agent-loop.md)
- [02 · From One Message to the Three Invariants of the Messages Array](context-management/02-message-invariants.md)
- [03 · Prompt Cache Is the Skeleton · Why Everything Else Grew the Way It Did](context-management/03-prompt-cache.md)
- [04 · The Six Siblings of Compaction · From Manual to Everywhere](context-management/04-compaction.md)
- [05 · The CLAUDE.md Family · From One Line of "Use pnpm" to a 5-Layer Loading Stack](context-management/05-claude-md-family.md)
- [06 · Sub-agent Isolation · From Independent Context to the .output Trap](context-management/06-sub-agent.md)
- [07 · Meta Mechanisms · From system-reminder to 20+ Channels](context-management/07-meta-mechanisms.md)
- [08 · Closing · From the 200K Ledger to a Cache-First Information System](context-management/08-conclusion.md)

---

# Part 4 · Memory Research

- [01 · The CLAUDE.md Family · 5-Layer Hierarchy and 3 Mixing Patterns](memory/01-claude-md-family.md)
- [02 · Auto Memory · From One Correction to MEMORY.md](memory/02-auto-memory.md)
- [03 · Anthropic API Memory Tool · From Date-Versioned to a Client-Side Memory Filesystem](memory/03-api-memory-tool.md)
- [04 · Subagent Memory · From Agent Type to a 3-Layer Persistent Directory](memory/04-subagent-memory.md)
- [05 · Memory Extraction Pipeline · From End-of-Turn to a Restricted Fork](memory/05-extraction-pipeline.md)
- [06 · Team Memory Sync · From Local Dual Directories to Server-Side Sync](memory/06-team-memory-sync.md)
- [07 · Managed CLAUDE.md · The Enterprise Control Layer](memory/07-managed-claude-md.md)
- [08 · After Compaction · Which Memories Come Back Automatically](memory/08-post-compaction.md)
- [09 · Closing · From a Single Piece of Information to Five Memory Carriers](memory/09-conclusion.md)

---

# Part 5 · Skills Research

- [00 · Introduction · From Repeated Pasting to a Callable Capability](skills/00-intro.md)
- [01 · Capability Format · From a Single Markdown File to a Portable Folder](skills/01-format.md)
- [02 · Progressive Disclosure · From description to Full Instructions](skills/02-progressive-disclosure.md)
- [03 · Capability Discovery · From a Directory to Claude's Candidate List](skills/03-discovery.md)
- [04 · Capability Invocation · From User Request to Skill Activation](skills/04-invocation.md)
- [05 · Prompt Rendering · From Arguments to Dynamic Context](skills/05-prompt-rendering.md)
- [06 · Execution Boundaries · From Inline to Forked Subagent](skills/06-execution-boundary.md)
- [07 · Permission Governance · From Callable to Safely Executable](skills/07-permissions.md)
- [08 · Lifecycle · From a Single Load to Compaction](skills/08-lifecycle.md)
- [09 · Distribution · From Personal Folder to Team Plugin](skills/09-distribution.md)
- [10 · Wrap-up · Where Should a Capability Live](skills/10-conclusion.md)

---

# Part 6 · Multi-Agent Collaboration Research

- [Introduction · From One Agent to a Team](multi-agent/00-intro.md)
- [Where Context Comes From · From a Blank Slate to Continuation](multi-agent/01-context-inheritance.md)
- [How Tool Permissions Are Set · From subagent_type to On-Demand MCP](multi-agent/02-tool-permissions.md)
- [Foreground or Background · From Reversed Defaults to Concurrency Limits](multi-agent/03-foreground-background.md)
- [What Counts as Done · From a Paragraph to a Fixed Format](multi-agent/04-completion-reporting.md)
- [Who Does Which Work · Shared Task Board vs. Hard-Coded Script](multi-agent/05-task-assignment.md)
- [The Boundary Between Isolation and Sharing · From Worktrees to the Token Ledger](multi-agent/06-isolation-sharing.md)
- [Wrap-up · When to Use Multiple Agents—and When Not To](multi-agent/07-conclusion.md)

---

# Part 7 · MCP Research

- [Introduction · From "Only Built-in Tools" to "Externally Attachable Tools"](mcp/01-intro.md)
- [Connection · From a Single Config Line to a Handshake](mcp/02-connection.md)
- [Transport · From Subprocess to Remote Service](mcp/03-transport.md)
- [Tool Exposure · From tools list to an Entry in the Tool List](mcp/04-tool-exposure.md)
- [Permissions · From Tool-Name Matching to Server-Level Authorization](mcp/05-permissions.md)
- [Authentication · From a Single Authorization to Login-Free Access Across Servers](mcp/06-authentication.md)
- [Resources & Elicitation · From Callable to Readable and Askable](mcp/07-resources-elicitation.md)
- [Reversed Roles · From MCP Client to MCP Server](mcp/08-reverse-role.md)
- [Wrap-up · Where MCP Sits Relative to Skills, Tool, and Plugin](mcp/09-conclusion.md)

---

[Appendix: Tool Index](appendix-index.md)
[About](about.md)
