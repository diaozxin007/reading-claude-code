# Summary

[前言](preface.md)

# 第一部分 · Tools 研究

## 起步

- [Tool 机制:Claude 怎么用工具](tool-mechanism.md)

## 交互原语

- [AskUserQuestion](interaction/ask-user-question.md)
- [EnterPlanMode](interaction/enter-plan-mode.md)
- [ExitPlanMode](interaction/exit-plan-mode.md)

## 执行原语

- [Grep + Glob](execution/grep-glob.md)
- [Read](execution/read.md)
- [Edit](execution/edit.md)
- [Write](execution/write.md)

## 通用能力

- [Bash](power/bash.md)
- [Agent](power/agent.md)

## 状态与调度

- [Task 家族](state/task-family.md)
- [Background 机制](state/background.md)
- [Cron 家族](state/cron-family.md)
- [Monitor](state/monitor.md)

## 信息访问

- [WebFetch + WebSearch](info/web.md)

---

# 第二部分 · Agent Loop 研究

- [开篇 · 从聊天窗口到 loop](agent-loop/00-intro.md)
- [从 tool 声明到执行前的批准](agent-loop/01-tool-permission.md)
- [Hooks · loop 上的可编程干预点](agent-loop/02-hooks.md)
- [从读文件到并行调度](agent-loop/03-parallel-scheduling.md)
- [从"回答完了"到 stop_reason 的 7 种含义](agent-loop/04-stop-reason.md)
- [QueryEngine 主循环 · 状态机全景](agent-loop/05-query-engine.md)
- [Streaming · 从 SSE 事件到逐字显示](agent-loop/06-streaming.md)
- [重试与错误恢复 · 8 层恢复叠加](agent-loop/07-retry-recovery.md)
- [Interrupt · 从 Ctrl-C 到合成 tool_result](agent-loop/08-interrupt.md)
- [Sidechain · 从子代理到 agentId 分流](agent-loop/09-sidechain.md)

---

# 第三部分 · Context 管理研究

- [开篇 · Claude Code 的 200K 账本](context-management/00-intro.md)
- [Agent Loop · context 是怎么装配的](context-management/01-agent-loop.md)
- [从一条消息到消息数组的三条不变量](context-management/02-message-invariants.md)
- [Prompt Cache 是骨架 · 为什么其他机制长成那样](context-management/03-prompt-cache.md)
- [Compaction 六兄弟 · 从手动到无处不在的压缩](context-management/04-compaction.md)
- [CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](context-management/05-claude-md-family.md)
- [Sub-agent 隔离 · 从独立 context 到 .output 陷阱](context-management/06-sub-agent.md)
- [Meta 机制 · 从 system-reminder 到 20+ 种通道](context-management/07-meta-mechanisms.md)

---

[附录 · 工具索引](appendix-index.md)
[关于](about.md)
