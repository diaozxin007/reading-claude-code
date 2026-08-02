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

# Part II · Agent Loop

- [Introduction · From a Chat Window to the Loop](agent-loop/00-intro.md)
- [From Tool Declaration to Pre-Execution Approval](agent-loop/01-tool-permission.md)
- [Hooks · Programmable Intervention Points in the Loop](agent-loop/02-hooks.md)
- [From Reading Files to Parallel Scheduling](agent-loop/03-parallel-scheduling.md)
- [From “The Answer Is Done” to the Seven Meanings of stop_reason](agent-loop/04-stop-reason.md)
- [QueryEngine Main Loop · A Complete View of the State Machine](agent-loop/05-query-engine.md)
- [Streaming · From SSE Events to Character-by-Character Display](agent-loop/06-streaming.md)
- [Retry and Error Recovery · Eight Stacked Recovery Layers](agent-loop/07-retry-recovery.md)
- [Interrupt · From Ctrl-C to a Synthetic tool_result](agent-loop/08-interrupt.md)
- [Sidechain · From Subagents to agentId Routing](agent-loop/09-sidechain.md)
- [Conclusion · From Automatic Loops to a General-Purpose Agent Loop](agent-loop/10-conclusion.md)

---

[Appendix: Tool Index](appendix-index.md)
[About](about.md)
