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

[Appendix: Tool Index](appendix-index.md)
[About](about.md)
