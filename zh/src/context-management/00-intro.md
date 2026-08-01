> 这是「Claude Code Context 管理研究系列」的开篇 · 先建全景地图 · 再依次深入。 本篇立主线 —— **Prompt Cache 是 Claude Code 一切设计的底座**;然后讲底座上层的 4 大策略、31 条具体机制。 让后续 6 篇有一张能挂新知识的架构图。
>
> 系列研究基于 Claude Code v2.1.220 泄露源码 · Bun + TypeScript + Ink · 每条结论都能落到具体 `file:line`。

## 从一个可观察的现象说起

你可能观察到过这个现象:

> **一段对话进行到 20 轮之后 · 后一次请求的响应比前一次快很多。 也没看到任何 "缓存已加载" 的字样。**

这不是错觉 —— 这是 **prompt cache** 在工作。 每次调 LLM · Claude Code 把从头到现在的**所有消息**完整重发 · 服务端发现前缀跟上次一样 · 复用之前的计算 · 返回快得多、成本低到 1/10。

Cache 不是"加速器"这么简单 —— 它是 Claude Code **一切设计的底座**。

Anthropic 的 Thariq Shihipar 说过一句很直白的话:

> **"At Claude Code, we build our entire harness around prompt caching."**

第一次看到这句话像是营销话术。 真去读 Claude Code 源码后你会发现:**从 CLAUDE.md 的注入位置到子代理的构造方式 · 从 skill listing 的增量发送到跨零点的日期通知 —— 每一处不合直觉的设计 · 追溯到底都是"为保 cache 而生"**。

本篇讲这个底座、以及它反过来塑造的整个 context 管理架构。

## Cache 的三条铁律

要理解 Claude Code 的 context 设计 · 先记住 Anthropic prompt cache 的**三条底层规则**。 这三条不是 Claude Code 独有的 · 是所有用 Anthropic API 的应用都要面对的。

**铁律 1 · 从头前缀匹配**

Cache 是**从头开始的前缀匹配**。 如果一次请求前 25000 token 跟上次相同 · 这 25000 token 的计算可以复用 · 只需为剩下的新 token 付全价。 严格从请求第一个 token 开始 · 匹配到第一个不同字节为止。

**铁律 2 · 一 byte 变即前缀断裂**

前缀一 byte 变 · 后面所有内容都算"新的" · 都要重新计算。 这意味着:**system prompt 里任何一处不稳定 · 都会让整个后续 cache 失效**。

**铁律 3 · 断点决定 cache 起点**

Anthropic API 让每次请求最多挂 4 个 `cache_control` 断点。 断点的意思是"这个位置之前的内容需要写入 cache" —— 越多断点 · 越能覆盖不同稳定性等级的前缀。 读 cache 便宜(0.1 倍成本)· 写 cache 略贵(1.25 倍 · 5 分钟 TTL)。

三条铁律推出三条设计原则:

- **稳定的东西往前放 · 变的东西往后放** —— 这样变的东西再变 · 影响不到前面的 cache
- **不同稳定性等级用不同断点隔开** —— 一处 bust 不带累其他等级
- **能不进稳定段的 · 就不要进** —— 变的东西挤进稳定段就是拉群众下水

**Claude Code 的所有 context 设计 · 都是这三条原则的直接后果**。 后面每一条具体机制 · 都能追到这里。

## Cache 反过来塑造了什么 · 一个直觉不对的观察

用 Claude Code 用了很久 · 才慢慢意识到一件事:

**它没有一个叫"context 管理"的模块**。

直觉上应该在源码某处找到一个 `ContextManager` 类 · 里面负责窗口计数、压缩、注入等等。 实际不是这样:

- 压缩逻辑散在 6 个不同文件里(`compact/` 有 `compact.ts` `autoCompact.ts` `microCompact.ts` `sessionMemoryCompact.ts` · 还不算 feature-flag 里的 `contextCollapse` 和 API 层的 reactive-compact 分支)
- CLAUDE.md 注入代码在 `utils/claudemd.ts` · Skill 注入代码在 `SkillTool.ts` · MCP schema 注入代码在 `toolSearch.ts` —— 三家的注入方式**完全不同**
- `<system-reminder>` 标签的组装函数有两个(`wrapInSystemReminder` `wrapMessagesInSystemReminder` · 都在 `messages.ts`)· 但 SR 内容本身有 20+ 种不同触发条件散在十几处

**这不是"没设计" · 是 cache 的必然结果**。

Cache 是一个**横切关注(cross-cutting concern)** —— 它不是一个功能模块 · 是**所有功能都要参与**的一件事。 类似于 logging —— 你不会去写一个 `LogManager` 类然后要求所有代码都通过它输出 · 你会定义一个 logger 接口 · 每个模块自己按约定用。

Cache 也是:
- CLAUDE.md 系统自己管自己怎么进 messages 段(不进 system prompt)
- Skill 系统自己管自己怎么做 delta(不全量重发)
- Compaction 自己管自己什么时候触发(不影响 system 段)

把这些强塞进一个 `ContextManager` 会造成一个**上帝对象** —— 谁改功能都要去动它 · 反而没人敢碰。

Claude Code 的选择:**没有中央 ContextManager · 但有一条铁的不变量 —— 保 cache**。 每个功能自己守这条不变量 · 具体实现分散在哪个文件都无所谓。 这跟微服务架构是同一个道理 —— 没有中央数据库 · 但有 API 契约。

## 4 大策略是给 cache 让路的具体设计

Anthropic 在 2025 年 9 月的博客 [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) 里 · 明确列了 4 大 context 管理策略。 但读源码后你会发现:**这 4 策略下面的每一条具体形态 · 都跪在 cache 前面 · 不能保 cache 的方案连备选都轮不上**。

| 策略 | 解决什么问题 | 关键的 cache 让步 |
|---|---|---|
| **Compaction · 压缩** | 会话变长 · context 迟早会满 | 压缩总结**只影响 messages 段** · 不动 tools / system 段 cache |
| **Structured note-taking · 结构化笔记** | 项目/用户偏好不能靠对话历史传递 | CLAUDE.md **不进 system prompt** · 走 messages 段的 SR user msg —— 变化只影响 messages cache |
| **Sub-agent decomposition · 子代理分解** | 单个任务的探索代价太大 · 会把 context 塞满 | fork subagent 用 **placeholder 替换所有 tool_result** · 让 100 次 fork 共享同一个 cache 前缀 |
| **Just-in-time retrieval · 按需检索** | 不知道要用哪些数据 · 又不能全塞 context | Skill listing 用 **delta 而非全量** · MCP schema **服务端 defer_loading** · 都是不 bust cache 的具体做法 |

**每一条策略下面 · 都能列出一批"看起来奇怪但源码就这么写"的具体设计** —— 每一个都是 cache 的直接后果:

- CLAUDE.md 走 messages 段的 prepend 位置 · **不是** 走 system prompt · 因为 CLAUDE.md 会变
- Skill listing 用增量注入 · **不是** 每轮全发 · 因为全发每轮都 bust cache
- fork subagent 里所有 tool_result 替换成 `"Fork started — processing in background"` · **让 100 次 fork 前缀字节完全相同**
- 每天日期**不写死** system prompt · 而是通过 `date_change` system reminder 单发 —— 因为写进 system 每天凌晨零点全球 session 集体 cache 失效
- MCP instructions 用 delta 注入 · 因为 MCP 连接是异步的 · 每次连上都 bust system cache
- `<env>` block memoize · 不 refresh —— `cd` 之后 cwd 里其实是 stale 的 · **这不是 bug 是为保 cache 故意的**
- skipCacheWrite 的 message 断点退到倒数第二条 —— 一次 fire-and-forget 的 side question 不该污染主线 cache
- `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` 分静态/动态段 —— 只有静态段挂 `cache_control` · 动态段(env / language / MCP)每轮可变但不影响静态段命中

**读完这一串你就懂了**:Claude Code 不是先设计功能再考虑 cache · 是**先看清 cache 约束、再倒着推每一处功能**。

## 全景地图 · 31 条机制矩阵

下面这张表是本系列的核心索引 · 后续每一篇的"该拆哪些机制"都从这里取。 **每一条追根到底都是"为保 cache 而生"** —— 你读的时候可以自己想想每一条对应哪条铁律。

| 策略 | 具体机制 | 一句话 | 后续第几篇 |
|---|---|---|---|
| **compaction** | `/compact` 手动压缩 | 用户主动触发 · 可带自定义指令 | 04 |
| **compaction** | auto-compact | 阈值触发 · 轮间执行 | 04 |
| **compaction** | micro-compact | 轮内低成本 tail 剪枝 | 04 |
| **compaction** | reactive-compact | API 返回 `prompt_too_long` 时应急 | 04 |
| **compaction** | sessionMemoryCompact | 跨 session 持久化 | 04 |
| **compaction** | contextCollapse | feature-flag 灰度中的激进变种 | 04 |
| **compaction** | `/clear` | 不总结 · 只重置 · 与 `/compact` 划边界 | 04 |
| **compaction** | `/rewind` | 时间轴级回退 · 只能选 user 消息 | 04 |
| **note-taking** | CLAUDE.md 4 层加载(user / project / .claude / local) | 从 cwd 向上走 · 层层拼接 | 05 |
| **note-taking** | `.claude/rules/*.md` path-scoped | 用 `paths:` frontmatter picomatch 路径 | 05 |
| **note-taking** | `@import` 递归(5-hop) | CLAUDE.md 里 `@filename` 会展开 | 05 |
| **note-taking** | MEMORY.md 自动记忆 | session 起手加载 · 40K 字符预算 | 05 |
| **note-taking** | Todo v2 持久任务 | 落盘 JSON · 用 TaskCreate/Get/List/Update 操作 | 05 |
| **note-taking** | `prependUserContext` 注入通道 | 打包成 `<system-reminder>` user msg prepend | 05 |
| **sub-agent** | Agent tool 独立 context | 默认起 fresh system prompt | 06 |
| **sub-agent** | fork subagent(唯一例外) | 继承 parent context · 用 placeholder 保 cache | 06 |
| **sub-agent** | `isolation: worktree` | git worktree + `AsyncLocalStorage` cwd | 06 |
| **sub-agent** | Task 家族 2 store 共存 | todo v2 磁盘 + 运行中任务内存双系统 | 06 |
| **sub-agent** | `.output` 符号链陷阱 | 对 local_agent 是完整 JSONL · 读了就炸 | 06 |
| **sub-agent** | SendMessage 邮箱系统 | 文件基跨 agent 通信 | 06 |
| **JIT** | Read offset/limit + 2000 行截断 | 大文件默认静默截断 | 07 |
| **JIT** | `readFileState` LRU-100 | 文件读过后缓存 · 100 上限有陷阱 | 07 |
| **JIT** | Read dedup(`FILE_UNCHANGED_STUB`) | 未公开机制 · 二次 Read 返回指令而非字节 | 07 |
| **JIT** | Skill body 按需注入 | listing 只发 frontmatter · body 用时再嵌 | 07 |
| **JIT** | Skill listing 增量发送 | `sentSkillNames` 追踪 · 只发 delta | 07 |
| **JIT** | MCP ToolSearch(server-side) | 客户端标 `defer_loading` · 服务器隐藏 schema | 07 |
| **JIT** | MCP instructions delta | 晚连接 MCP 时避免 cache 失效 | 07 |
| **底座** | Agent Loop · messages 数组只增不减 | LLM 无状态 · harness 每次重发历史 | 01 |
| **底座** | Messages 数组三条不变量 | 只 append / tool_use 配对 / role 严格交替 | 02 |
| **底座** | Prompt Cache 4 断点 | 1 tools + 2 system + 1 messages · 覆盖 4 层稳定性 | 03 |
| **底座** | `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` | 分静态/动态段的 sentinel | 03 |
| **meta** | `<system-reminder>` 20+ 类型 | 静态附加 / cadence / 事件 / 增量 / 用户上下文 / 模式切换 六大类 | 07 |
| **meta** | `<env>` 块 memoize | cwd 会 stale · 但为保 cache 故意的 | 07 |
| **meta** | Cyber-risk 挂 Read | 除 opus-4-6 外每次 Read 都追加安全提醒 | 07 |

共 **31 条** —— 而且这还没穷尽(源码里 feature-flag 关掉的还有一批)。

## 一个可视化 · 一次请求里 cache 长什么样

上面骨架说得抽象。 看一次具体请求的形态 —— 用户输入 "帮我给这个应用加个用户登录" —— context 长这样:

```
─────────────────────────────────────────────────────────────
1. 静态段(挂 cache_control · 一 session 保持稳定)
─────────────────────────────────────────────────────────────
  ├─ tools 列表(最后一个 schema 挂 cache_control)
  ├─ system prompt · 静态部分
  │    ├─ Claude Code 主 prompt
  │    ├─ 工具说明总述
  │    ├─ SR 教学("Tool results may include <system-reminder>…")
  │    └─ <env> 块 (cwd, git, platform, model, cutoff)
  └─ <SYSTEM_PROMPT_DYNAMIC_BOUNDARY>          ← sentinel · 静态/动态段分界

─────────────────────────────────────────────────────────────
2. 动态段(不挂 cache_control · 允许每轮变)
─────────────────────────────────────────────────────────────
  ├─ session guidance(允许的工具集 · skill 命令表)
  ├─ MCP instructions(如果 delta 关 · 每轮重发)
  ├─ output style
  └─ language

─────────────────────────────────────────────────────────────
3. Messages 段(挂 messages.length-1 断点 · 覆盖全部历史)
─────────────────────────────────────────────────────────────
  ├─ [prepend user msg · isMeta:true]        ← CLAUDE.md 走这里 · 不进 system!
  │    <system-reminder>
  │       # claudeMd
  │       ~/.claude/CLAUDE.md (全局)  ← @import 5-hop 展开
  │       /repo/CLAUDE.md (项目)
  │       ~/.claude/rules/*.md (path 匹配的)
  │       # currentDate
  │       Today's date is …
  │    </system-reminder>
  ├─ 用户消息:"帮我加登录"
  ├─ tool_use / tool_result 交替(几轮 Read / Edit / Bash)
  │    每个 Read 附加 <system-reminder> cyber-risk 尾巴
  │    每个 Edit 走 readFileState LRU 检查
  ├─ [cadence 10 轮触发]
  │    <system-reminder>
  │       The TodoWrite tool hasn't been used recently…
  │    </system-reminder>
  └─ 当轮用户新消息

─────────────────────────────────────────────────────────────
4. 边缘:发生特殊事件时才出现的通道
─────────────────────────────────────────────────────────────
  ├─ context 接近满 → auto-compact(轮间)
  ├─ 收到 API prompt_too_long → reactive-compact(应急)
  ├─ 生成 skill 后 → skill listing delta
  ├─ 文件被外部修改 → edited_text_file SR("Note: X was modified…")
  ├─ 跨零点 → date_change SR
  └─ sub-agent spawn → 全新 context · <usage> 回填
```

**几个观察**(每个都是 cache 的直接后果):

1. **CLAUDE.md 不走 system prompt** —— 因为 CLAUDE.md 会变 · 进了 system prompt 一变就 bust 大 cache。 走 messages 段的 prepend · 变化只影响 messages cache
2. **`<system-reminder>` 是一根总线** —— 所有需要"元指令通知模型"的场景都走这一根 · 因为 messages 段本来就变 · 追加 SR 对 cache 影响最小
3. **静态段和动态段显式分开** —— 靠一个字面量 sentinel(不靠启发式)—— cache 边界必须显式而非猜
4. **每 10 轮的 cadence 提醒也走 messages 段** —— 不是 wall-clock · 是每次 API call 前 message normalization 阶段跑一次

## 本系列后 7 篇要回答的问题

学习目标是**回答问题** · 不是罗列机制。 每篇分别对应一个具体的疑问 —— 疑问不解 · 后面的机制就是散珠子。

| 篇号 | 篇名 | 学完能回答什么问题 |
|---|---|---|
| **01** | Agent Loop · context 是怎么装配的 | LLM 是有状态还是无状态?一次对话里 harness 到底给 LLM 打了几次交道?messages 数组是怎么增长的? |
| **02** | 从一条消息到消息数组的三条不变量 | 消息数组里每条消息什么形态?tool_use / tool_result 必配对的硬约束是什么?isMeta 和 `<system-reminder>` 通道怎么工作? |
| **03** | Prompt Cache 是骨架 · 为什么其他机制长成那样 | 本篇讲的"三条铁律"具体怎么落到 4 断点分布?`SYSTEM_PROMPT_DYNAMIC_BOUNDARY` 分段具体几段?每段挂什么?6 个反直觉设计的完整案例分析 |
| **04** | Compaction 六兄弟 · `/compact` `/clear` `/rewind` + auto + micro + reactive | context 满了会发生什么?`/compact` 用什么模型总结?post-compact 会挂回哪些文件?为什么 Anthropic 官方博客说的"80% 阈值"在源码里找不到? |
| **05** | CLAUDE.md 家族 · 4 层加载 + `@import` + rules + MEMORY.md | 一次 session 起手加载了哪些静态指令?`@filename` 的递归到底几层深?`.claude/rules/` 是怎么按路径生效的?MEMORY.md 上限是行数还是字节数? |
| **06** | Sub-agent 隔离 · Agent + fork + Task + SendMessage | sub-agent 到底能不能看到 parent 的东西?worktree 隔离怎么实现?`.output` 文件为什么读了会炸 context?两个 task store 分别做什么? |
| **07** | Meta 机制 · `<system-reminder>` 类型学 + File state + Read dedup + ToolSearch | 到底有多少种 SR?触发条件是什么?readFileState 100 上限的陷阱怎么触发?ToolSearch 是客户端 BM25 还是服务端 defer? |

## 8 处 · 官方文档 vs 源码不符

这轮 discovery 有一个副产品收获 —— **8 处 Anthropic 官方文档说的和源码实际不符**。 列在这里 · 让你带着这些"打脸清单"读后续篇 · 对每条源码事实会更有兴趣:

| # | 官方说法 | 源码实际 |
|---|---|---|
| 1 | `@import` 4-hop 递归上限 | 5-hop(`MAX_INCLUDE_DEPTH = 5`) |
| 2 | 1000-pattern / 4 MiB 内存预算 | 完全不存在 · 实际是 `MAX_MEMORY_CHARACTER_COUNT = 40_000` |
| 3 | MEMORY.md frontmatter 用 `node_type: memory` | 实际用 `name / description / type` 三字段 |
| 4 | auto-compact 阈值是 context 的 80% / 90% | 是绝对值:`contextWindow - 20K reservedOutput - 3K buffer` |
| 5 | `/compact` 用 Haiku 总结 | 用 `mainLoopModel`(和主对话同模型) |
| 6 | ToolSearch:"10% context if schemas fit" | 10 是 Bernoulli auto-defer 概率 · 不是 context 尺寸门槛 |
| 7 | Skill body 懒加载 | body 是**磁盘 eager load** · 但**注入 context 是 late**(不同概念) |
| 8 | Read dedup 完全未提 | 源码有 · 有 killswitch `tengu_read_dedup_killswitch` 灰度中 |

这些不是 Anthropic 撒谎 · 更像是文档比源码更新慢、或者产品团队和 doc 团队没同步。 但对深度研究者来说 · **源码是唯一 ground truth**。 后续每篇都会开一个小节明确"官方 vs 源码差异" · 这也是本系列的差异化 —— 别处看不到这些反差。

## 本篇小结

一句话:**Claude Code 是先看清 prompt cache 约束、再倒着推每一处 context 设计的系统**。

- **Cache 三条铁律**:从头前缀匹配 · 一 byte 变即断裂 · 断点决定 cache 起点
- **三条设计原则**:稳的往前、变的往后、用断点分隔稳定性等级
- **无中央 ContextManager · 但有铁的不变量** —— cache 是横切关注 · 每个功能自己守
- **4 大策略是给 cache 让路的具体设计** —— 每一条形态都能追到"不能 bust 大 cache"这个约束
- **31 条具体机制散在源码各处** —— 每一条追根到底都是"为保 cache 而生"
- **8 处官方文档 vs 源码不符** —— 本系列的差异化卖点

后续 7 篇按 `Agent Loop → 消息数组不变量 → Prompt Cache 具体设计 → 4 策略 → 元机制` 顺序展开。 下一篇 [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) 讲清 messages 数组是什么形态 · 再进 [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) 讲结构约束 · 再到 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 展开本篇的 cache 三铁律怎么落到 Claude Code 的具体 4 断点。

---

## 参考

- Anthropic 博客:[Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)(2025-09)
- Anthropic 博客:[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
- Anthropic 博客:[Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)
- Anthropic 官方:[Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) —— cache 底层机制文档
- Simon Willison(2026-02-20)· Thariq Shihipar quote —— [claude-code tag](https://simonwillison.net/tags/claude-code/)
- Claude Code 文档:[code.claude.com/docs/en](https://code.claude.com/docs/en)(注:`docs.anthropic.com/en/docs/claude-code/*` 已 301 到这里)
- Claude Code 源码(泄露 v2.1.220)· 本地路径
- 本系列 discovery 完整报告:00 · Discovery 报告 · 4 大策略与 20+ 机制清单
- Vault 内相关笔记:
  - 深度学习_System_Prompt · System prompt / prompt cache 底层
  - 学习笔记_s08 · Context Compact L1-L4
  - Claude code tools 研究系列（九）Agent · Agent tool 独立 context
  - Claude code tools 研究系列（五）Read · readFileState / empty file
