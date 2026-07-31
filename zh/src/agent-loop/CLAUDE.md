# Claude Code Agent Loop 研究系列 · 编写指引

> 写这个系列 · 先读:
> @../Claude Code 研究系列 · 写作规范.md

## 本系列专属规则

**主线**:Claude Code 的**执行流** —— 事情怎么发生 · 工具怎么被调、被批准、被并行、被中断

**姐妹系列**:[Context 管理研究系列](../context-management/00-intro.md) · 讲**信息流** —— 消息数组、cache、压缩、注入等

**核心分工原则**:
- 消息数据结构 / 消息不变量 / 压缩 / 恢复 / CLAUDE.md 注入 / isMeta / prompt cache → **Context 系列**
- Tools 声明 / 权限 / hooks / 并行调度 / streaming / interrupt / stop_reason / retry / sub-agent → **本系列**

**篇号 / 标题 / 状态**

| # | 篇名 | 状态 |
|---|---|---|
| 00 | 从聊天窗口到 loop | ✅ 定稿 |
| 01 | 从 tool 声明到执行前的批准 | ✅ 定稿 |
| 02 | Hooks · loop 上的可编程干预点 | ✅ 定稿 |
| 03 | 从读文件到并行调度 | ✅ 初稿(开头已挂 Context 02) |
| 04 | 从回答完了到 stop_reason 的 7 种含义 | ✅ 定稿 |
| 05 | QueryEngine 主循环 · 状态机全景 | ✅ 定稿 |
| 06 | Streaming · 从 SSE 事件到逐字显示 | ✅ 定稿 |
| 07 | 重试与错误恢复 · 8 层恢复叠加 | ✅ 定稿 |
| 08 | Interrupt · 从 Ctrl-C 到合成 tool_result | ✅ 定稿 |
| 09 | Sidechain · 从子代理到 agentId 分流 | ✅ 定稿 |

**Loop 系列全部 10 篇初稿完成**(00-09)。 03 需要按整体统一风格再看一遍 · 其余定稿。

**未来编辑动作 · 系列级**:
- Loop 09 讲了 sub-agent · 回头到 Loop 01 那段 "Subagent 的权限系统不继承" · 加一个 wikilink 指向 Loop 09
- 03 篇按整体统一风格再校订(在 3 轮示例、命名、reference 段位等)

## 关键前置概念(00 篇已建立)

- **LLM 无状态** —— 后续所有 messages 数组的讨论都基于这一点
- **loop 中间无人参与 · 用户只在开头和结尾出现** —— agent vs chatbot 分水岭
- **每次调 LLM 都完整重发 messages 数组** —— 引出 cache 必要性(Context 系列讲)
- **loop 骨架 5 行代码** —— 后续所有复杂机制都是在这 5 行上叠加

## 划归 Context 系列的话题(本系列不讲)

- 消息数据结构(user / assistant / tool_result role 三类)
- 三条不变量(只 append / tool_use 配对 / role 严格交替)
- API 只有 3 种 role 的约束
- isMeta 与 `<system-reminder>` 通道
- messages 数组增长的规律和成本
- rewind 悖论 · 内存 flat vs 磁盘 tree
- 修补机制(interrupt / compact / rewind 破坏配对后的 ensureToolResultPairing)
- Compaction 六兄弟
- CLAUDE.md 家族
- Prompt Cache 4 断点

以上话题在本系列引用时 · 都是**wikilink 到 Context 系列对应篇** · 本系列不重复讲。

## Discovery 素材来源

本系列各篇的 discovery 结论散在 Loop 系列写作时的 3 条 sub-agent 输出中:
- QueryEngine 主循环 · Turn 终止 · 工具编排 · Streaming · Interrupt · 重试 · Sidechain
- Permission · Hooks · Interrupt · Streaming → UI · Stop reasons · Concurrency
- Message 数据模型 · role / content · isMeta · tool 协议 · 并行 · 配对 · 持久化 · smoosh(**这一条大部分内容划给 Context 系列**)

未来某个时刻应该沉淀成独立的 discovery 报告(参考 Context 系列的 `00 · Discovery 报告`)· 但目前分散状态可以工作。
