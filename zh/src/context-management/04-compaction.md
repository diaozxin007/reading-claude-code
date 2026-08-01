> 本系列第 04 篇 · 承接前 3 篇立起来的三条不变量 —— messages 数组只 append 不删、tool_use / tool_result 必须配对、role 严格交替(见 [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md))。 这三条 "不能改" 是压缩机制存在的根本原因 —— 数组不能自然变小 · 只能靠 harness 主动动手。
>
> 前一篇 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 讲了 cache 是所有设计的底座。 这一篇讲**压缩** —— 但压缩不是一种 · 是**六种协同**。 每一种触发场景不同 · 保留策略不同 · 对 cache 的态度也不同。
>
> 本篇聚焦**原理与设计** —— 6 种变种各自解决什么问题、彼此怎么分工、post-compact 的 3 处反直觉。 具体源码位置见文末参考段。

## 你可能没搞清的几件事

Claude Code 里 · 你可能听说过 `/compact` · 但如果只知道这一个 · 会漏掉一大半:

1. **一次对话跑到 context 快满了 · 什么时候是我按 `/compact` · 什么时候是 harness 自己压缩?**
2. **`/compact` 是不是就用个便宜的小模型总结一下?**
3. **压缩完 · 之前那些读过的文件还在吗?我要不要再 Read 一遍?**
4. **`/compact` 和 `/clear` 差别是什么?一个总结一个不总结 —— 但为什么要留两个命令?**
5. **`/rewind` 也能"回到之前状态" —— 它跟压缩是什么关系?**
6. **听说有 `/fork` —— 输入之后为啥没反应?**

一句话答案:**Claude Code 有 6 种 compaction 变种协同工作 · 覆盖从"用户主动"到"API 已经报错"的全谱系触发场景 —— 加上 `/clear` `/rewind` 划边界 · 加上 `/fork` 一个未编译进的伏笔**。

## TL;DR

| 维度 | 一句话 |
|---|---|
| **为什么需要压缩** | messages 数组三条不变量决定了它只 append 不删 · 长到一定程度必须动手 |
| **6 种变种共存** | `/compact` 手动 / auto-compact 阈值 / micro-compact 轮内剪 / reactive-compact 应急 / sessionMemoryCompact 跨 session / contextCollapse 灰度 |
| **`/compact` 用主模型不是 Haiku** | 反直觉 —— 大多数人以为用 Haiku 便宜总结 · 实际用 mainLoopModel · 因为总结质量本身就是核心业务 |
| **9 段 XML 结构** | `<analysis>` 草稿被剥掉 · `<summary>` 9 段留下 · 覆盖 Primary Request / Files / Errors / All user messages 等 |
| **auto-compact 阈值不是 80%** | 是绝对值 `context - 20K reserved - 3K buffer` · 官方博客说的 "80%" 在源码里找不到 |
| **Post-compact 挂回 5 file / 50K token** | 有硬预算:5 file 上限 · 每 file 5K · 总 50K · skill 25K |
| **3 处反直觉挂回** | root CLAUDE.md 重挂 / nested 不重挂 / skill listing 故意不重挂 —— cache 优于记忆完整性 |
| **`/clear` 不总结** | 完全重置 AppState + 换 session ID + 重跑 SessionStart hooks · 跟 `/compact` 划边界 |
| **`/rewind` 粒度** | 只能选 user 消息 · 不能到 tool_use / tool_result 中间 · 保三条不变量 |
| **`/fork` 未编译进** | feature-flag 未启用 · 被 `/branch` 收编 · 真 fork 见 [06 · Sub-agent 隔离](06-sub-agent.md) |

## 1 · 为什么"压缩"不是一种是六种

先立起前提:messages 数组的三条不变量([02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md)) —— **只 append 不删** · tool_use / tool_result **必须配对** · role **严格交替**。

这三条决定了 messages 数组**只会长不会短**。 一次对话跑到 20 轮 · 数组可能就有几十条消息。 跑到 100 轮 · 几百条。 而每次调 LLM 都要完整重发 —— 200K 上限迟早会撞到。

所以必须压缩。 但**压缩什么时候发生、怎么发生**  · 六种变种覆盖不同场景:

| 变种 | 谁触发 | 什么时机 | 干什么 |
|---|---|---|---|
| **`/compact`** | 用户主动 | 用户按下 · 立即 | 9 段总结 + 挂回 last 5 file |
| **auto-compact** | harness 自动 | 每轮末尾 · 达阈值 | 同 `/compact` · 但用户没主动 |
| **micro-compact** | harness 自动 | 轮内 · 低成本 | 只丢过时 tool_result · 不总结 |
| **reactive-compact** | harness 自动 | API 报 `prompt_too_long` | 应急削尾 · 最多 3 次 |
| **sessionMemoryCompact** | harness 自动 | session 结束 | 写盘 · 跨 session 持久化 |
| **contextCollapse** | feature-flag | 灰度中 | 更激进 · 直接大幅削减 |

**为什么要六种**:每一种都有别人不能替代的 niche —— 
- `/compact` 是**用户主动**的入口 —— 用户可能预感到需要压缩(比如刚接完一大段任务 · 想换个话题)· harness 自己没办法预知
- auto-compact 是 **harness 主动**的阈值触发 —— 用户没意识到 · 但 context 快满了
- micro-compact 是**轮内**的低成本清理 —— 阈值没到 · 但发现历史里有过期的 tool_result · 悄悄扔掉几条
- reactive-compact 是 **API 已经报错**的应急恢复 —— 前几种都没救 · 只能被动救火
- sessionMemoryCompact 是**跨 session** 的 —— 不解决当前 session 的 context 满 · 解决"下次进来能记得什么"
- contextCollapse 是**灰度实验**的激进版 —— 常规压缩不够 · 更狠

**这跟单一 `/compact` 的心智完全不同** —— Claude Code 的压缩是**分层防御** · 每一层解决自己那一层的问题。

## 2 · `/compact` 深入 —— 手动最典型

`/compact` 是最典型的入口 —— 用户主动按下 · 可以带 `[custom instructions]`(比如 "重点保留数据库 schema 部分")。

**这一步有专门的 prompt。** `/compact` 并不是把这条命令原样发给模型，而是由程序另外发起一次“总结当前对话”的 LLM 请求：system prompt 告诉模型它的任务是总结对话，具体的压缩 prompt 则规定下面的 9 段 XML 输出结构。用户附带的 `[custom instructions]` 也会加入这次请求，用来控制总结重点。

### 反直觉:用的是主模型 · 不是 Haiku

大多数人的假设:总结是**次要任务** · 应该用便宜的 Haiku 或者背景模型。

**源码实际**:用 **mainLoopModel** —— 也就是你当前 session 用的主模型(Opus / Sonnet)。 `querySource` 标为 `'compact'` · `thinkingConfig` 设为 `disabled`(总结不需要思维链)· `systemPrompt` 简单一句 "You are a helpful AI assistant tasked with summarizing conversations."

**为什么用主模型**:总结质量本身就是核心业务 —— 压缩后的 summary 会替代 messages 数组里几十上百条消息 · session 后续所有推理都建立在这段 summary 上。 如果 Haiku 漏掉一个关键上下文(比如某个错误的根因)· 后续所有回答都会失真。 用主模型 · **总结的质量跟对话的质量一致**。

代价是压缩本身很贵 —— 一次 `/compact` 消耗几千到上万 token 的推理成本。 但相对于 "总结失真导致后续几十轮回答都在原地打转" · 一次几千 token 是划算的。

### 9 段 XML 结构

`/compact` 让 LLM 输出一段结构化总结 · 包在两层 XML 标签里:

```
<analysis>
   ... 草稿式思考 ...
</analysis>

<summary>
1. Primary Request and Intent      ← 用户的主要意图
2. Key Technical Concepts          ← 关键技术概念
3. Files and Code Sections         ← 涉及的文件和代码
4. Errors and fixes                ← 出过的错和修复方式
5. Problem Solving                 ← 解题过程
6. All user messages               ← 所有用户消息(完整保留)
7. Pending Tasks                   ← 未完成任务
8. Current Work                    ← 当前进行的工作
9. Optional Next Step              ← 下一步建议
</summary>
```

**两层 XML 的作用**:
- `<analysis>` 是**草稿区** —— LLM 可以在里面自由思考 · 处理完成后**被 `formatCompactSummary` 剥掉**
- `<summary>` 是**成品区** —— 只有这段留下 · 替代原本的 messages 历史

**9 段结构的核心思想**:压缩不是简单地"缩短对话" —— 是**按主题重组信息**。 一段自然的对话历史里 · 一个 bug 的讨论可能散在 10 条消息里(用户报错 → LLM 尝试修 → 失败 → 用户补充 → LLM 二次尝试 ...) —— 9 段 结构把它们**归到 "Errors and fixes" 一栏** · 压缩后一条条列清晰。

**第 6 段 "All user messages" 是特殊设计**:让 LLM **完整保留**所有用户消息 —— 不允许省略。 因为用户消息是唯一表达"用户意图"的锚点 · 丢一条可能就丢一个方向。 LLM 回复可以总结 · 用户消息不能。

### customInstructions

`/compact` 命令接受一个可选参数 —— `argumentHint: <optional custom summarization instructions>`。

用法示例:

```
/compact 重点保留数据库 schema 讨论 · 忽略 UI 样式相关
```

这段自定义指令会拼进总结 prompt 里 · 让 LLM 按用户的要求偏向保留某类信息。 是给用户的**手动干预旋钮** —— 有时候用户比 harness 更清楚哪些是关键。

## 3 · auto-compact —— 阈值不是 80%

`/compact` 是用户主动;auto-compact 是 harness 自动。 每轮 LLM 调用结束后 · harness 检查 context 长度 · 如果超过阈值 · 自动触发一次压缩。

### 反直觉:阈值是绝对值不是百分比

Anthropic 官方博客说 auto-compact "在 context 达到 80% 时触发"。

**源码实际**:阈值是一个**绝对值** · 不是百分比。 具体公式:

```
触发阈值 = effectiveContextWindow - 20K reservedOutput - 3K buffer
```

拆开看:
- **effectiveContextWindow** —— 当前模型的 context 上限(比如 200K)
- **20K reservedOutput** —— 给 LLM 回复留的空间 —— 200K 的 context · 输入不能占满 200K · 得留一部分给 LLM 输出
- **3K buffer** —— 安全边距 —— 万一 tokenizer 计算有误差 · 别踩到硬上限

对 200K 的模型:触发阈值 = 200K - 20K - 3K = **177K** —— 约 88.5%。 对 100K 的模型(比如某些 fallback):触发阈值 = 100K - 20K - 3K = 77K —— 约 77%。

**为什么设计成绝对值而非百分比**:reservedOutput 是**固定 20K** 而非按比例 —— 因为 LLM 输出的合理长度跟 context 大小没什么关系 · 一次回复 20K token 已经够写小论文了。 用绝对值保证 "留给输出的空间不会因为上限变大而白白浪费"。

**env 覆盖**:有环境变量 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 可以把阈值改成百分比 —— 但默认没有百分比 · 是显式打开的选项。

**"80%" 从哪里来的**:可能是 Anthropic 团队早期设计文档的说法 · 或者对普通模型的粗略近似。 但源码里找不到 "80%" 这个数字。 这是[00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) 末尾 "官方文档 vs 源码反差" 表里的第一条。

## 4 · micro / reactive / sessionMemory / contextCollapse —— 4 个微观变种

上面两种是主戏 · 剩下 4 种是配角 —— 但少了任何一个 · 系统都会漏一大块。

### micro-compact —— 轮内低成本剪枝

`/compact` 和 auto-compact 都是**轮末**触发的重量级操作 —— 要发一次 LLM 请求做总结 · 成本几千 token。

**micro-compact 是轮内的轻量清理** —— 不发 LLM · 也不做总结 —— 只做一件事:**扫一遍历史 · 找出那些已经过期的 tool_result · 悄悄替换成 placeholder**。

**什么算过期**:典型场景是 **file dedup** —— 同一个文件被读过 3 次 · 前 2 次的 tool_result 已经过时了(后一次的更全)· 前两条可以剪掉。 harness 用一个 `readFileState` 追踪每个文件的最新版本(细节见 [07 · Meta 机制](07-meta-mechanisms.md)) · micro-compact 就靠这个判断哪些旧读的结果可以扔。

**替换后的 placeholder**:一段固定英文 `FILE_UNCHANGED_STUB`:

> File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.

**不是** `[...]` 那种简写 marker · **是完整的一句英文指令** —— 因为 LLM 看到这条消息时 · 需要知道 "去看更后面那次 Read 的结果" —— 一句自然语言指令比一个符号更明确。

**micro-compact 保持三条不变量**:tool_use / tool_result 配对没有破坏 —— tool_use 还在 · tool_result 还在 —— 只是 tool_result 的**内容**被换了。 配对结构没动 · 只是内容瘦身。

### reactive-compact —— API 报错才触发

前面几种都是**预防性**的 —— 在 API 报错之前动手。 reactive-compact 是**应急**的 —— API 已经报 `prompt_too_long` 错误了 · 才被迫触发。

为什么会走到这一步:
- 用户禁用了 auto-compact(有环境变量可以关)
- 或者 auto-compact 的估算不准 —— 实际 token 数比 harness 算出来的还多
- 或者用户装了一大堆 MCP · MCP 突然一次挂载了几万 token 的 schema · 让 context 一下超了阈值

reactive-compact 的处理:
- **最多 3 次尝试** —— `RECOVERY_LIMIT = 3`
- 每次尝试 · 削掉一部分历史(头部或尾部)· 重新发请求
- 3 次还救不回来 · 抛 `{ reason: 'prompt_too_long' }` 给 SDK 层

这是 [07 · 重试与错误恢复 · 8 层恢复叠加](../agent-loop/07-retry-recovery.md) 里讲的 8 层恢复中的**第 4 层**。 具体的削尾策略叫 `truncateHeadForPTLRetry` —— 从**头部**削(削尾会破坏 tool_use / tool_result 配对 · 头部相对安全)。

**reactive-compact 藏在错误里** —— 用户看不到 "prompt_too_long 出现了 · 又消失了" —— 只有 3 次都失败才看到错误。 这跟 [05 · QueryEngine 主循环 · 状态机全景](../agent-loop/05-query-engine.md) 里的 "错误 withhold" 哲学一致。

### sessionMemoryCompact —— 跨 session 持久化

前面几种都是**当前 session 内**的压缩 —— 处理完 · messages 数组变短了 · session 接着跑。

sessionMemoryCompact 不同 —— 它的目标不是让当前 session 变短 · 是让**下次开新 session** 能接着上次的上下文。

工作流:
- session 结束时(或 idle 一段时间) · harness 把当前 session 的 messages 数组做一次 summary
- summary 落盘到 `~/.claude/projects/<project>/memory/`
- 下次同项目开 session · 起手会加载这个 memory —— 相当于"上次的记忆"

**跟 auto-compact 的区别**:
- auto-compact:总结完 · 塞回**当前 session 的 messages 数组头**
- sessionMemoryCompact:总结完 · **写到磁盘** · 供下次读取

**跟 MEMORY.md 的区别**:MEMORY.md 是**用户可编辑**的记忆(用户可以手改)· sessionMemoryCompact 是 **harness 自动写**的。 两者协同 —— 一个手动 · 一个自动。 具体机制见 [05 · CLAUDE.md 家族](05-claude-md-family.md)。

### contextCollapse —— feature-flag 灰度中的激进版

前面的压缩都是"温和" —— 保留结构 · 只压缩内容。 contextCollapse 更狠 —— 直接**大幅削减**历史 · 不做精细总结。

**为什么要更狠**:有一类极端情况 —— context 已经**远超**阈值(比如用户禁了所有 auto 机制 · 或者一次批量塞了 100 个大文件 tool_result) · 常规压缩都不够 —— 总结完还是超。 这时候需要**激进抛弃**。

contextCollapse 在源码里存在 · 但**被 feature-flag 门禁** —— 默认不开 · 只有部分灰度用户能触发。 它的具体保留策略比 `/compact` 更激进 —— 直接扔掉某段历史 · 而不是总结。

这是 [07 · 重试与错误恢复 · 8 层恢复叠加](../agent-loop/07-retry-recovery.md) 里讲的 prompt_too_long 三级恢复的**级 1**(激进压缩) · 前面 reactive-compact 是**级 2** —— 递进关系:先温和救一救 · 不行再狠一点 · 再不行才抛给用户。

## 5 · Post-compact 挂回策略 —— 5 file / 50K token 预算

现在深入一个前面反复出现的操作:**post-compact 挂回**。

`/compact` / auto-compact 做完总结后 · messages 数组的样子是:

```
[压缩前的 messages 数组:几十条]
                    ↓
[9 段 summary](一条 user 消息包 <system-reminder>)
+ [边界后的 user 消息:verbatim 保留]
```

但**只有一段 summary 是不够的** —— 有些"结构化上下文"必须重新挂回:
- 用户前面 Read 过的文件 —— 总结里只能说 "读过 foo.ts" · 具体内容丢了
- 用户在用的 skill —— 总结里可能提到但没具体 body
- CLAUDE.md —— 项目规则不能靠 summary 概括

所以 post-compact 需要**主动挂回**这些结构化上下文。 但挂回**必须有预算** —— 否则 " 压缩完又变长" · 白压。

### 硬预算表

Claude Code 的挂回预算是几个硬编码常量:

| 预算项 | 值 | 含义 |
|---|---|---|
| **POST_COMPACT_MAX_FILES_TO_RESTORE** | 5 | 最多挂回 5 个文件 —— 超过 5 · 靠 LLM 后续按需再 Read |
| **POST_COMPACT_TOKEN_BUDGET** | 50K | 所有挂回文件总 token 上限 |
| **POST_COMPACT_MAX_TOKENS_PER_FILE** | 5K | 单个文件最多 5K token —— 大文件自动截断 |
| **POST_COMPACT_MAX_TOKENS_PER_SKILL** | 5K | 单个 skill body 最多 5K |
| **POST_COMPACT_SKILLS_TOKEN_BUDGET** | 25K | 所有挂回 skill 总 token 上限 |

**挑哪 5 个文件挂回**:harness 记录每个文件最后被访问的时间 —— 挂回最近 5 个。 逻辑是 "用户最近在关注的 · 最可能继续关注"。

**为什么是 5 · 而不是 3 或 10**:是**取舍**产物 —— 
- 太少:用户马上要接着讨论的文件被漏 · 需要重新 Read · 浪费一轮
- 太多:挂回的文件本身占预算 —— 5 file × 5K = 25K token · 加上 skill 25K · 加上 summary 本身 · 已经用了几万 token

5 是 Claude Code 团队在**"避免用户马上再读"和 "压缩完不能又长回来"之间**找的平衡点。

## 6 · Post-compact 的 3 处反直觉

Post-compact 挂回除了预算 · 还有 3 处反直觉的处理 —— 每一处都指向同一心法:**cache 视角 · 不是语义视角**(见 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md))。

### 反直觉一 · root CLAUDE.md 重挂 · nested 不重挂

`/compact` 后 · CLAUDE.md 应该重挂 —— 因为 summary 里可能没完整覆盖项目规则。

但**只有 root/project CLAUDE.md 重挂 · nested 不重挂**。

- **root/project** —— 项目根的 CLAUDE.md · 用户全项目的规则 · 必须重挂
- **nested** —— 子目录里的 CLAUDE.md(比如 `src/frontend/CLAUDE.md`) · 只跟这个子目录的文件相关 —— **不重挂**

**为什么 nested 不重挂**:nested CLAUDE.md 只在用户**实际操作那个子目录的文件**时才需要 —— 如果 compact 后用户接下来的话题跟那个子目录无关 · 挂了浪费 token。 harness 保留一个 `nestedMemoryAttachmentTriggers` 机制 —— 下次读该子目录文件时 · nested CLAUDE.md **自动挂回**(通过 attachment 触发) —— 需要时才挂 · 不需要时不占预算。

**这是 just-in-time retrieval 策略** —— 见 [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) 的第 4 策略。

### 反直觉二 · Skill listing 故意不重挂

`/compact` 前 · Claude Code 有一个 "已发送过的 skill 名字集合" —— 用来做增量注入(见 03 篇案例 2)。

直觉上:compact 后 · summary 只是文字描述 · LLM 对 "有哪些 skill" 的记忆已经淡了 —— 应该**清空这个集合** · 让 skill listing 全量重发一次。

**源码实际**:**故意不清空** —— 集合保留 · compact 后 skill listing **不重发**。

源码注释直说了原因:

> post-compact 的 skill listing 是纯 cache_creation(~4K tokens)· 不重发反而保 cache。

**这是极致的 cache 优先**:
- 直觉:LLM 的 "skill 记忆" 完整性
- 反直觉:保住 4K token 的 cache 前缀更划算 —— 一个 session 内累计能少几十倍成本

**代价**:LLM 对 skill 列表的记忆稍淡一点 —— 用户显式 slash-command 唤起 skill 时不受影响 · 只影响 LLM "主动想起要用 skill" 的场景。 权衡后 · 团队选择保 cache。

### 反直觉三 · FILE_UNCHANGED_STUB 是英文指令不是 marker

前面 micro-compact 那节讲过这段:

> File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.

**为什么不用简写 marker** 比如 `[...]` 或 `<file:unchanged>`:
- Marker 需要 LLM **训练时理解过** —— 一段没见过的符号 LLM 会困惑
- 完整英文自然语言 —— LLM 直接理解 —— 一段消息就是一段指令
- Marker 需要文档解释 —— 一段完整英文自解释

**这是给 LLM 的产品文档 · 而不是 harness 内部标记**。 LLM 是"用户" · 你写的每一段元信息都要按 LLM 能理解的方式写 —— 用它的语言 · 不用你的语言。

这种 "元信息用自然语言" 的模式在 Claude Code 里很多 —— `<system-reminder>` 包着的 CLAUDE.md 也是完整英文段(见 [05 · CLAUDE.md 家族](05-claude-md-family.md)) · date_change reminder 也是完整英文。 详见 [07 · Meta 机制](07-meta-mechanisms.md)。

## 7 · `/clear` 和 `/rewind` —— 什么时候用哪个

到这里已经讲了 6 种 compaction 变种。 但用户视角还有两个入口跟"清理历史"相关 —— `/clear` 和 `/rewind`。 它们**不是** compaction —— 但跟 compaction 划边界 · 有必要在这里讲清楚。

### `/clear` —— 不总结 · 只重置

**跟 `/compact` 的核心区别**:
- `/compact` —— 保留信息 · 只是压缩 —— messages 数组变短 · 但语义连续
- `/clear` —— **完全重置** —— messages 数组清空 · 一切从零开始

`/clear` 具体重置什么:
- messages 数组:清空
- AppState 里的 tasks(运行中任务追踪)
- attribution(消息归因 —— 谁触发了什么)
- fileHistory 的 snapshots(文件历史快照)
- standaloneAgentContext(独立 sub-agent 上下文缓存)
- MCP state(MCP 连接状态)
- plan-slug cache
- session metadata
- **重新生成 session ID** —— 相当于一个全新 session
- **重新跑 SessionStart hooks** —— 让 hooks 有机会重新初始化环境

**为什么 `/clear` 要留一个入口**:有些场景用户想**彻底切换任务** —— 前面聊的 bug 已经修完 · 现在要开始一个完全无关的功能开发。 `/compact` 会保留 summary —— 但用户不需要那些信息 —— 反而会干扰 LLM 关注新任务。

**记忆口诀**:**要接着聊 · 用 `/compact`;彻底换话题 · 用 `/clear`**。

### `/rewind` —— 时间轴级回退

`/rewind`(在有的版本叫 `/checkpoint`)是另一个维度的清理 —— **回到之前某个时间点**。

跟 `/compact` / `/clear` 的核心区别:
- `/compact` / `/clear` —— 时间上是**当前** · 只是清一部分或全部
- `/rewind` —— 时间上**倒回**某个之前的点

**粒度**:只能选**user 消息** —— 不能选到某个 tool_use / tool_result 中间。

**为什么只能到 user 消息**:三条不变量决定的 —— 
- 如果 rewind 停在一个 tool_use 之后但 tool_result 之前 —— 破坏配对
- 停在 tool_result 之后但 assistant 回复之前 —— role 交替被破坏
- **只有 user 消息之前是"干净的截面"** —— 每一个 user 消息之前的历史都是完整的 turn boundary · 三条不变量都满足

具体过滤逻辑叫 `selectableUserMessagesFilter` —— 过滤掉 tool_result / synthetic / meta / compact-summary / command-output —— 只留下**真实的用户消息**。 用户看到的选择列表就是过去按过回车的每一次。

**Restore 选项**:选中一个 user 消息后 · 还有 6 种恢复方式:
- **both** —— 恢复对话 + 代码(文件回退到当时的状态)
- **conversation** —— 只恢复对话 · 代码不动
- **code** —— 只恢复代码 · 对话不动
- **summarize** —— 把中间那段总结成一段 · 不完全丢
- **summarize_up_to** —— 总结到某一点
- **nevermind** —— 取消

**这跟 [07 · Meta 机制](07-meta-mechanisms.md) 讲的 "rewind 悖论" 关联** —— rewind 时 · 内存里的 messages 数组直接截断 —— 但磁盘上的记录是**追加式**的 · 保留 rewind 前的完整历史 · 只是标记 rewind 点。 这就是 "内存 flat · 磁盘 tree" 的核心。

### 一张表 · 清理历史的 3 种入口

| 入口 | 保留信息 | 时间维度 | 何时用 |
|---|---|---|---|
| `/compact` | 保留 —— 9 段 summary | 当前 · 压缩 | 接着聊 · 但历史太长 |
| `/clear` | **不保留** —— 全清 | 当前 · 重置 | 彻底换话题 |
| `/rewind` | 保留 —— 但回到过去 | 倒回 · 截断 | 想撤回某次操作 |

## 8 · `/fork` —— 一个未编译进的伏笔

你可能在什么地方看到过 `/fork` 命令。 但你实际输入 `/fork` · 可能没反应 —— 或者被识别成了 `/branch`。

**源码实际**:`/fork` 命令定义**存在** · 但被一个 feature-flag 门禁:

```
featureFlag: 'FORK_SUBAGENT'
```

如果这个 flag 未启用 —— 也就是大部分用户的默认状态 —— `/fork` 命令**未编译进** UI · 输入不识别 · 被 `/branch` 命令收编。

**为什么保留 `/fork`**:真正的 fork 实现在 `tools/AgentTool/forkSubagent.ts` —— 是 **sub-agent** 主题(见 [06 · Sub-agent 隔离](06-sub-agent.md)) —— 不是 compaction 主题。 fork 是**独立 sub-agent 继承父上下文**的机制 —— 用 placeholder 抹平所有 tool_result 保 cache · 让 100 次 fork 共享同一个 cache 前缀([03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 案例 3)。

这里只做**伏笔** —— 你看到 `/fork` 没反应 · 不是 bug · 是 sub-agent 主题的入口 · 06 篇会展开。

## 9 · 六种变种的分工全景

现在把 6 种 compaction + 2 种非 compaction 入口 · 按**触发场景**捋一遍:

```
用户视角:
  ┌─ 主动想压缩          → /compact  (带 customInstructions)
  ├─ 主动想换话题        → /clear
  └─ 主动想撤回          → /rewind

harness 自动:
  ┌─ 每轮末尾 · 阈值触发  → auto-compact
  ├─ 轮内 · 发现过期数据  → micro-compact
  ├─ API 已报错 · 救急    → reactive-compact
  ├─ session 结束        → sessionMemoryCompact (跨 session)
  └─ 灰度激进            → contextCollapse
```

**六种变种共存的合力**:让 messages 数组在**任何时刻**都不会失控 —— 
- 平时:auto-compact 悄悄扫 · 阈值到了压一次 —— 用户无感
- 用户想主动干预:`/compact` + customInstructions —— 精细控制
- 出问题救急:reactive-compact —— 最后一道防线
- 跨 session:sessionMemoryCompact —— 记忆延续到下次
- 极端情况:contextCollapse —— 灰度中的核选项

**每一种都不能被别的替代** —— 场景不同 · 触发方式不同 · 保留策略不同。 这就是 "六兄弟" 的意义 —— 不是六个抽象层次 · 是六个**独立触发路径** · 一起覆盖了从"用户主动"到"API 已经炸了"的**全谱系**。

## 10 · 本篇小结

- **三条不变量决定了 messages 数组只增不减** —— 必须靠压缩机制人为动手
- **6 种 compaction 变种共存** —— `/compact` / auto / micro / reactive / sessionMemory / contextCollapse —— 每种解决自己那一层的问题
- **`/compact` 用主模型 · 不是 Haiku** —— 总结质量本身就是核心业务
- **9 段 XML 结构 + 用户消息完整保留** —— 按主题重组 · 而不是简单缩短
- **auto-compact 阈值不是 80%** —— 是绝对值 `context - 20K reserved - 3K buffer`
- **Post-compact 挂回 5 file / 50K token** —— 硬预算 · 挂回自身也要控本
- **3 处反直觉挂回** —— root CLAUDE.md 重挂 / nested 不重挂 / skill listing 故意不重挂 —— cache 优于记忆完整性
- **`/clear` 完全重置** —— 跟 `/compact` 划边界 · 想接着聊用 compact · 想换话题用 clear
- **`/rewind` 只能选 user 消息** —— 三条不变量的必然结果
- **`/fork` 未编译进** —— feature-flag 门禁 · 真 fork 是 sub-agent 主题

一句话:**压缩不是一次操作 · 是一整套触发路径 —— 每一条都由 messages 数组的三条不变量、cache 优先的心法、just-in-time 挂回预算共同塑形**。

下一篇 [05 · CLAUDE.md 家族](05-claude-md-family.md):讲 Claude Code 结构化笔记的另一半 —— CLAUDE.md 4 层加载顺序、@import 递归、`<system-reminder>` 通道注入、post-compact 里 nested CLAUDE.md 为什么故意不重挂的细节。

---

## 参考

**Claude Code 源码定位**(v2.1.220):
- `src/services/commands/compact/index.ts` · `/compact` 命令入口 · customInstructions 参数
- `src/services/commands/compact/prompt.ts` · 9 段 XML 结构
- `src/services/compact/compact.ts` · 压缩主流程 · post-compact 挂回 · reactive-compact
- `src/services/compact/autoCompact.ts` · auto-compact 阈值计算
- `src/services/compact/microCompact.ts` · 轮内 tail 剪枝
- `src/services/compact/sessionMemoryCompact.ts` · 跨 session 持久化
- `src/services/compact/contextCollapse.ts` · feature-flag 激进变种
- `src/tools/FileReadTool/prompt.ts` · `FILE_UNCHANGED_STUB` 常量
- `src/services/commands/conversation.ts` · `/clear` 命令 · AppState 重置
- `src/services/commands/MessageSelector.tsx` · `/rewind` UI · `selectableUserMessagesFilter`
- `src/services/commands/commands.ts` · `/fork` feature-flag `FORK_SUBAGENT`
- `src/services/commands/branch/index.ts` · `/fork` 未启用时的 fallback
- `src/tools/AgentTool/forkSubagent.ts` · 真 fork 实现(sub-agent 主题)

**相关篇**:
- [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) · 4 大策略 · 31 条机制矩阵
- [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) · messages 数组只增不减的起源
- [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) · 压缩必须遵守的三条约束
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) · Post-compact 反直觉的心法
- [04 · 从回答完了到 stop_reason 的 7 种含义](../agent-loop/04-stop-reason.md) · context_window_exceeded 触发点
- [05 · QueryEngine 主循环 · 状态机全景](../agent-loop/05-query-engine.md) · compaction 作为 transition 一等公民
- [07 · 重试与错误恢复 · 8 层恢复叠加](../agent-loop/07-retry-recovery.md) · reactive-compact 是第 4 层
- [05 · CLAUDE.md 家族](05-claude-md-family.md) · nested CLAUDE.md 为什么故意不重挂
- [06 · Sub-agent 隔离](06-sub-agent.md) · 真 fork 的展开
- [07 · Meta 机制](07-meta-mechanisms.md) · rewind 悖论 · 内存 flat vs 磁盘 tree

**Anthropic 官方**:
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · 4 大策略框架
- [Claude Code memory & context](https://code.claude.com/docs/en/memory) · 官方文档提到 auto-compact 的 "80%" —— 与源码不符 · 见本篇第 3 节
