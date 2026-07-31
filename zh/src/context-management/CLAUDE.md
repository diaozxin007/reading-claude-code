# Claude Code Context 管理研究系列 · 编写指引

> 写这个系列 · 先读:
> @../Claude Code 研究系列 · 写作规范.md

## 本系列专属规则

**主线**:Claude Code 的**信息流** —— 消息数据结构 · 每次 LLM 调用塞什么 · 怎么压缩 · 怎么恢复

**姐妹系列**:[Agent Loop 研究系列](../agent-loop/00-intro.md) · 讲**执行流** —— 事情怎么发生 · 工具怎么被调、被批准、被并行、被中断

**核心分工原则**:
- 消息数据结构 / 消息不变量 / 压缩 / 恢复 / CLAUDE.md 注入 / isMeta / prompt cache → **本系列**
- Tools 声明 / 权限 / hooks / 并行调度 / streaming / interrupt / stop_reason / retry / sub-agent → **姐妹系列**

**篇号 / 标题 / 状态**

| # | 篇名 | 状态 |
|---|---|---|
| 00 | 开篇 · Claude Code 的 200K 账本 | ✅ 定稿 |
| 00 | Discovery 报告 · 4 大策略与 20+ 机制清单 | 内部工作簿 · 不发布 |
| 01 | Agent Loop · context 是怎么装配的 | ✅ 定稿 · 本系列前置 · 从 loop 视角切入消息数组 |
| 02 | 从一条消息到消息数组的三条不变量 | ✅ 定稿 |
| 03 | Prompt Cache 是骨架 · 为什么其他机制长成那样 | ✅ 定稿 |
| 04 | Compaction 六兄弟 · 从手动到无处不在的压缩 | ✅ 定稿 |
| 05 | CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈 | ✅ 定稿 |
| 06 | Sub-agent 隔离 · 从独立 context 到 .output 陷阱 | ✅ 定稿 |
| 07 | Meta 机制 · 从 system-reminder 到 20+ 种通道 | ✅ 定稿 · 收官 |

**Context 系列全部 8 篇初稿完成**(00-07 + Discovery)。 7 篇正文按推演式结构落地 · 与 Loop 系列 10 篇形成完整机制图景。

## 4 大策略 · 20+ 机制矩阵

**Anthropic 官方 4 策略**(见开篇):
- Compaction · 压缩
- Structured note-taking · 结构化笔记
- Sub-agent decomposition · 独立 context
- Just-in-time retrieval · 按需检索

**底座**:Prompt Cache · 决定上层每一条机制具体形态的约束

**元通道**:`<system-reminder>` —— 20+ 种触发 · 是黏合前 4 策略的胶水

## 关键铺垫链

- **LLM 无状态 · 每次重发完整历史** —— 从 01 篇建立
- **消息数组三条不变量** —— 02 篇正式提出:只 append / tool_use 配对 / role 严格交替 · 后续所有话题都建立在此
- **CLAUDE.md 走 messages 段 · 不进 system prompt** —— 反直觉但是保 cache 的核心设计(03 篇讲)
- **cache 静态 ≠ 语义静态** —— 6 个反直觉案例的共同心法(03 篇讲)
- **6 种 compaction 变种共存** —— 手动 / auto / micro / reactive / sessionMemory / contextCollapse(04 篇讲)
- **`/compact` 用 mainLoopModel 不是 Haiku** —— 反直觉 · 打脸大多数人的假设(04 篇讲)

## 8 处 · 官方文档 vs 源码反差

本系列的差异化卖点 —— 每条已在 00 篇末尾表格列出。 写具体机制时展开对应条目。

## 与 Loop 系列的引用关系

**本系列引用 Loop 系列**:
- 02(消息数组不变量)讲到 tool_use / tool_result 配对时 · 可引 Loop 03(并行调度)
- 06(Sub-agent)引 Loop 09(Sidechain)

**Loop 系列引用本系列**:
- Loop 03(并行调度)引本系列 02(消息数组不变量)
- Loop 讲清 loop 骨架 → 引本系列 03(cache 落在 loop 里的位置)

**跨系列引用要显式** —— 别让读者猜某个概念在另一个系列的哪一篇。

## Discovery 素材位置

- 主 discovery 报告:Discovery 内部工作簿(未发布 · 仅 vault 保留)
- 4 条 sub-agent 分别覆盖:Compaction · CLAUDE.md 家族 · Sub-agent 隔离 · Meta 机制
- **Loop 系列写作时的 3 条 sub-agent · Message 数据模型那一条大部分内容划给了本系列 02**

## 已复用的 vault 素材

- AI Agent 实战/Week06_Memory_Compact_SystemPrompt/深度学习_System_Prompt · Prompt cache API 层通用原理(03 篇互补)
- AI Agent 实战/Week06_Memory_Compact_SystemPrompt/学习笔记_s08 · Context Compact L1-L4(04 篇会用)
- 读书笔记/Claude code tools 研究系列/Claude code tools 研究系列（九）Agent · Agent tool(06 篇会用)
- 读书笔记/Claude code tools 研究系列/Claude code tools 研究系列（五）Read · readFileState(07 篇会用)
