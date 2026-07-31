# Appendix: Tool Index

Sorted alphabetically for quick navigation to each tool's detailed chapter.

## Interaction

| Tool | One-Line Purpose | Chapter |
|---|---|---|
| [AskUserQuestion](interaction/ask-user-question.md) | Let the user pick from preset options | Interaction Primitives |
| [EnterPlanMode](interaction/enter-plan-mode.md) | Enter read-only planning mode | Interaction Primitives |
| [ExitPlanMode](interaction/exit-plan-mode.md) | Submit the plan for user approval | Interaction Primitives |

## Execution

| Tool | One-Line Purpose | Chapter |
|---|---|---|
| [Glob](execution/grep-glob.md) | Find files by path pattern | Execution Primitives |
| [Grep](execution/grep-glob.md) | Find files/lines by content | Execution Primitives |
| [Read](execution/read.md) | Read file contents | Execution Primitives |
| [Edit](execution/edit.md) | Precise string replacement | Execution Primitives |
| [Write](execution/write.md) | Full-file write | Execution Primitives |

## General-Purpose

| Tool | One-Line Purpose | Chapter |
|---|---|---|
| [Bash](power/bash.md) | Execute shell commands | General-Purpose Capabilities |
| [Agent](power/agent.md) | Spawn a subagent to handle subtasks | General-Purpose Capabilities |

## State & Scheduling

| Tool | One-Line Purpose | Chapter |
|---|---|---|
| [TaskCreate](state/task-family.md) | Create a to-do task | Task Family |
| [TaskList](state/task-family.md) | List all tasks | Task Family |
| [TaskGet](state/task-family.md) | Get details of a single task | Task Family |
| [TaskUpdate](state/task-family.md) | Update task status/metadata | Task Family |
| [TaskStop](state/task-family.md) | Stop a background-running task | Task Family |
| [TaskOutput](state/task-family.md) | Get output from a background task (deprecated) | Task Family |
| [CronCreate](state/cron-family.md) | Schedule a future prompt trigger | Cron Family |
| [CronList](state/cron-family.md) | List all cron jobs | Cron Family |
| [CronDelete](state/cron-family.md) | Cancel a cron job | Cron Family |
| [ScheduleWakeup](state/cron-family.md) | Self-wakeup specialized for /loop | Cron Family |
| [Monitor](state/monitor.md) | Continuously listen to an event stream | Monitor |
| Background (capability) | Cross-tool async execution mode | [Background Mechanism](state/background.md) |

## Information Access

| Tool | One-Line Purpose | Chapter |
|---|---|---|
| [WebFetch](info/web.md) | Fetch content from a known URL | Information Access |
| [WebSearch](info/web.md) | Search the public web by keywords | Information Access |

## Lookup by "What Problem to Solve"

| Need | What to Use |
|---|---|
| Let the user make a decision | [AskUserQuestion](interaction/ask-user-question.md) |
| Plan before acting | [EnterPlanMode](interaction/enter-plan-mode.md) → [ExitPlanMode](interaction/exit-plan-mode.md) |
| Find which files in the project are relevant | [Glob](execution/grep-glob.md) / [Grep](execution/grep-glob.md) |
| See the current state of a file | [Read](execution/read.md) |
| Modify code at a known location | [Edit](execution/edit.md) |
| Create a new file / completely rewrite | [Write](execution/write.md) |
| Run tests / build / git | [Bash](power/bash.md) |
| Large-scale cross-file investigation | [Agent](power/agent.md) |
| Break down complex requirements into steps | [Task Family](state/task-family.md) |
| Start a long task without blocking the conversation | [Background Mechanism](state/background.md) |
| Auto-trigger at a specific time | [Cron Family](state/cron-family.md) |
| Continuously listen to an event stream | [Monitor](state/monitor.md) |
| Get the latest public web information | [WebFetch + WebSearch](info/web.md) |

## Lookup by "Design Philosophy"

| Observation | Chapter |
|---|---|
| Runtime hard-blocks > AI self-discipline | Spread across chapters; see [Edit](execution/edit.md) for the Read-first constraint |
| Read-first trust chain | [Edit](execution/edit.md) / [Write](execution/write.md) |
| Empty parameters = state-switching intent | [EnterPlanMode](interaction/enter-plan-mode.md) / [ExitPlanMode](interaction/exit-plan-mode.md) |
| Context isolation | [Agent](power/agent.md) / [WebFetch](info/web.md) |
| Prompts born from hard-won lessons | [Bash](power/bash.md) / [Monitor](state/monitor.md) |
| Orthogonal capability vs. standalone tool | [Background Mechanism](state/background.md) |
| Temporal primitives (past / present / future) | [Task Family](state/task-family.md) / [Cron Family](state/cron-family.md) |

---

Back to [Table of Contents](SUMMARY.md).
