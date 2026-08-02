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
- [收尾 · 从自动循环到通用 Agent Loop](agent-loop/10-conclusion.md)

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
- [收尾 · 从 200K 账本到 Cache-first 信息系统](context-management/08-conclusion.md)

---

# 第四部分 · Memory 研究

- [CLAUDE.md 家族 · 5 层 hierarchy 与 3 种混装](memory/01-claude-md-family.md)
- [Auto Memory · 从一次纠正到 MEMORY.md](memory/02-auto-memory.md)
- [Anthropic API Memory Tool · 从日期版本到客户端记忆文件系统](memory/03-api-memory-tool.md)
- [Subagent Memory · 从 agent type 到三层持久目录](memory/04-subagent-memory.md)
- [Memory Extraction Pipeline · 从一轮结束到受限 fork](memory/05-extraction-pipeline.md)
- [Team Memory Sync · 从本地双目录到服务端同步](memory/06-team-memory-sync.md)
- [Managed CLAUDE.md · 企业管控层](memory/07-managed-claude-md.md)
- [Compaction 之后 · 哪些记忆会自动回来](memory/08-post-compaction.md)
- [收尾 · 从一条信息到五种记忆载体](memory/09-conclusion.md)

---

# 第五部分 · Skills 研究

- [开篇 · 从重复粘贴到可调用能力](skills/00-intro.md)
- [能力格式 · 从一个 Markdown 文件到可移植文件夹](skills/01-format.md)
- [渐进披露 · 从 description 到完整 instructions](skills/02-progressive-disclosure.md)
- [能力发现 · 从一个目录到 Claude 的候选清单](skills/03-discovery.md)
- [能力调用 · 从用户请求到 Skill 激活](skills/04-invocation.md)
- [Prompt 渲染 · 从参数到动态上下文](skills/05-prompt-rendering.md)
- [执行边界 · 从 inline 到 forked subagent](skills/06-execution-boundary.md)
- [权限治理 · 从可调用到可安全执行](skills/07-permissions.md)
- [生命周期 · 从一次加载到 compaction](skills/08-lifecycle.md)
- [分发 · 从个人文件夹到团队 Plugin](skills/09-distribution.md)
- [收尾 · 一项能力应该放到哪里](skills/10-conclusion.md)

---

[附录 · 工具索引](appendix-index.md)
[关于](about.md)
