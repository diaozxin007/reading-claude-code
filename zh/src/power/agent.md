Claude code tools 研究系列第九篇。前八篇拆完了三条主线:

- **交互原语三件套**([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md)) —— 与用户对齐
- **执行原语链条**([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md)) —— 定位、感知、修改文件
- **通用兜底工具** [Bash](bash.md) —— 唯一「无边界」的工具 · 能操作真实世界

到这里,Claude 已经有能力独立完成一整套「改代码 + 跑测试 + 提交」的工程流程。但还有一类问题这些工具**都解决不了**:

- 「这个 10 万行的 codebase 里,哪些地方用到了 legacy API?」—— Grep 出上百个匹配 · Read 全部读完会爆 context
- 「我要重构鉴权模块 · 帮我先做个调研」—— 涉及多个子系统 · 单个 Claude 一次性看完消化不了
- 「有个 bug · 但不知道在哪 · 帮我从错误信息追根到 root cause」—— 需要试探性搜多次 · 每次都可能失败 · 结果又要综合

这类问题的共同点:**任务本身要么规模超出单个 Claude 的 context 承载力 · 要么过程有多次试错 · 结果需要综合**。这时候一个 Claude 不够 —— 需要**多个 Claude 协作**。

这是 Agent 工具存在的意义。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Agent

Agent 是 Claude Code 里**最独特的一个 tool** —— 它做的事,是**派生一个新的 Claude 实例**去完成一个子任务。用软件工程的话说,这是「fork 一个进程」;用组织管理的话说,这是「委派给下属」。

前八个工具都是「Claude 亲自动手」,Agent 是「Claude 当 manager」。这个视角切换让 Claude Code 从「一个 AI 助手」升级为「一个 AI 团队」。

### 作用

Agent 是 Claude Code 内置的**子任务派生工具**。它做的事:接受一个自然语言 prompt · 派生一个新的 Claude 实例(叫 subagent)在**独立 context** 里执行 · 完成后返回结果给主 Claude。

它解决的核心问题是「单个 Claude context 有限 · 但真实工程任务的信息量常常超限」:

1. **Context 隔离** —— subagent 用自己的 context 池,不占用主 Claude 的 token
2. **专业化分工** —— 不同 subagent 类型(claude / Explore / Plan / vercel:xxx)针对不同任务预设
3. **并行执行** —— 多个 Agent 调用可以并发 · 用墙钟时间换 context 空间
4. **结果聚焦** —— subagent 返回的是**最终报告** · 中间的 tool call、搜索、试错都留在 subagent 那边,主 Claude 只看到结论

Agent 之所以特殊,是因为它**颠倒了「工具」的概念**:前八个工具是「Claude 用工具做事」,Agent 是「Claude 让另一个 Claude 用一堆工具做事」。它是一个**元工具**(meta-tool)—— 一个能创造 Claude 的工具。

### 一个具体例子

**场景**:用户说 **「我要重构鉴权模块 · 先帮我把项目里所有 auth 相关的代码组织清楚 · 输出一份调研报告」**。

这个任务的难点:

- **未知规模** —— auth 代码可能在 `src/auth/` · `middleware/` · `lib/security/` · `pages/api/*` 里散着
- **多轮试探** —— 每找到一个入口,都要顺着往下看它依赖什么、被谁调用
- **需要综合** —— 最后要出一份**结构化报告**,不是一堆散乱的 grep 输出

如果主 Claude 自己动手:

- Glob 找相关文件 —— 上百个匹配
- Read 全部读 —— context 爆
- 分批 Read —— 忘掉之前看过什么
- 最后要写报告时 · 关键上下文已经被挤出去了

#### 用 Agent 是怎么解决的

主 Claude 调用 Agent · 派一个 subagent 去完成这个调研:

```
Agent(
  description: "调研 auth 模块架构",
  subagent_type: "general-purpose",
  prompt: """
调研这个项目里所有 auth 相关的代码 · 输出一份结构化报告。

具体要求:
- 找出所有 auth 相关文件(login / logout / session / token / permission / role)
- 每个文件的职责一句话概括
- 画出模块间的调用关系(谁调用谁)
- 找出 3 个最值得重构的地方 · 说明为什么

约束:
- 只读代码 · 不改任何文件
- 报告控制在 500 字以内 · 不要贴代码
- 如果发现关键决策要问用户 · 直接在报告里标"[需要用户拍板]"
"""
)
```

**运行时会发生什么**:

- Runtime 派生一个新的 Claude 实例(subagent)
- Subagent 拿到一个**全新的 context**(不带主 Claude 的历史对话)
- Subagent 有自己的工具箱(默认包含 Read / Grep / Glob / Bash 等)
- Subagent 在自己的 context 里搜索、读取、思考、综合
- 完成后,subagent 把**最终报告**(一段结构化文字)返回给主 Claude

主 Claude 拿到的:

```
Agent report (500 words):

## Auth 模块架构

**核心文件**:
- src/auth/middleware.ts (JWT 校验主入口)
- src/auth/routes.ts (login / logout / refresh 路由)
- src/lib/session-store.ts (Redis session 存储)
- src/models/permission.ts (RBAC 权限模型)

**调用关系**:
API 请求 → middleware.ts → session-store.ts → 通过 → 业务代码
Login → routes.ts → jwt.sign → session-store.set

**3 个重构建议**:
1. middleware.ts 里 JWT 校验和 session 检查混在一起 · 建议拆分
2. permission.ts 用了硬编码 role · 建议改成数据库配置
3. session TTL 分散在 5 处 · 建议统一到 constants

[需要用户拍板]:
- 是否保留 JWT · 还是完全切换到 session cookie?
- Permission 层是否引入 casbin?
```

**关键点**:

- 主 Claude 的 context 里只留下了 subagent 的**报告**(500 字)· 不是几十个文件的内容
- Subagent 内部可能做了 50+ 次 tool call(Grep / Read / Glob) · 全在自己的 context 池里 · 主 Claude 完全不知道
- 主 Claude 拿到报告后,可以继续跟用户讨论、Ask 澄清、EnterPlanMode 展开

#### 关键洞察:分包不是「委外」· 是「context 隔离」

很多人第一次用 Agent 会误解成「让另一个 Claude 帮我干活」—— 好像找了个实习生。这个类比不完全对。

**Agent 的真正价值不是「省 Claude 的力气」· 而是「省 Claude 的 context」**。同样是消费 tokens,但主 Claude 的 context 池只需要放最后的报告,不需要放中间所有的 grep 输出和文件内容。**用墙钟时间和总 token 数,换 context 空间**。

这就像人类工程师做大项目时会说「这块我不看细节 · 让 XX 帮我调研个结论」—— 不是懒 · 是**认知带宽有限,必须选择性关注**。

### 触发条件

**该用 Agent 的场景**:

- **跨文件调研** —— 「auth 代码是怎么组织的」/「哪里用到了 legacy API」
- **多轮试探性搜索** —— 「有个 bug · 从这个错误信息追根源」
- **规模大到会爆 context** —— 需要读几十上百个文件
- **可以并行的子任务** —— 「同时调研三个不同模块」
- **需要专业化 subagent** —— 用 `Explore` 做搜索、`Plan` 做架构设计、`vercel:xxx` 做特定领域

**不该用 Agent 的场景**:

- **已知目标的单次操作** —— 就是要改一行代码 · 直接 Edit,不用 Agent 兜圈子
- **需要用户交互的任务** —— subagent 一般不能直接跟用户对话 · 有澄清需求主 Claude 亲自问
- **过程本身有价值** —— 如果用户想看到 Claude 的每一步思考(教学场景),Agent 会隐藏过程只给结果
- **信息量小的任务** —— 派 subagent 有启动成本 · 简单任务反而慢

一个**核心判断**:**如果一件事的关键信息量 << 结论信息量,派 Agent**。调研 100 个文件出一份 500 字报告,信息压缩比 100 倍 —— 完美 Agent 场景。改一行代码,压缩比接近 1 —— 别派 Agent,自己动手。

### 技术实现

#### 1 · 命名

`Agent`

一个词概括所有职责,但这个词的选择相当有讲究。它不叫 `Fork` / `Spawn` / `Delegate` —— 而是叫 **Agent**,直接借用 AI 领域「智能体」这个词。这在提示 Claude:你派出去的不是「一个函数调用」也不是「一个进程」,是**另一个能自主决策的智能体**。

字段名也各有语义:

- `prompt` —— 主输入,直接叫「提示词」,和用户对 Claude 的输入同名 · 暗示「你在给下属写指令」
- `subagent_type` —— 明说这是「子智能体」,前缀 sub- 强调层级关系
- `description` —— 3-5 词的简短描述,和其它工具的字段区分开(其它工具的 `description` 是 schema meta,这里是运行时展示用)
- `isolation` —— 「隔离级别」,直接暗示这是权衡「独立性」vs「协作性」的开关
- `run_in_background` —— 逐字表达「后台跑」,和 Bash 的同名参数对齐,但**默认值相反**(Bash 默认前台 · Agent 默认后台) —— 这个默认值反转本身就是一条重要信号(下节详述)

#### 2 · 工具级描述

Agent 的工具级描述**是所有工具里最长的**。这不是啰嗦,而是因为 Agent 涉及的行为规约多、错误模式多、边界模糊。围绕四件事:**该用不该用的边界 / prompt 写法 / 通信协议 / 反 AI 反模式的红线**。

**开篇一句:定位「多步、跨代码库」**

> Launch a new agent to handle complex, multi-step tasks. Each agent type has specific capabilities and tools available to it.

「complex, multi-step」两个词把 Agent 的使用场景收缩了 —— **单步任务、明确目标的操作,别用 Agent**。这是防止「Agent 听起来很强就滥用」的第一道防线。

**"不该用 Agent"的具体反例**

> If the target is already known, use the direct tool: Read for a known path, `grep` via the Bash tool for a specific symbol or string. Reserve this tool for open-ended questions that span the codebase, or tasks that match an available agent type.

这段用**列举反例**的方式训练 Claude 分辨:「已知路径 → 直接 Read」/「找具体符号 → 直接 grep」。**具体已知的操作用直接 tool · 开放式跨代码库问题才用 Agent** —— 这是 Agent 描述里最关键的一条边界规则。

**并行调用的鼓励**

> If the user specifies that they want you to run agents "in parallel", you MUST send a single message with multiple Agent tool use content blocks.

**并行是 Agent 的重要红利**。三个 Agent 顺序调用 = 3 倍时间,同一 message 里三个 Agent = 1 倍时间。这条描述明确让 Claude 学会「独立任务用并行」的直觉 —— 用 `MUST` 大写量词强调这不是可选。

**"背景运行"的默认值反转**

> Agents run in the background by default. When an agent runs in the background, you will be automatically notified when it completes — do NOT sleep, poll, or proactively check on its progress.

这条讲了两件事:①Agent **默认后台**(和 Bash 相反,Bash 默认前台) · ②主 Claude **不要轮询** —— 会有通知机制主动送结果过来。

默认值反转的设计意图很清晰:**Agent 天然是长任务** · 短任务根本用不上 Agent。让长任务默认后台跑,主 Claude 可以继续做别的事 —— 这是**用默认值编码最佳实践**。

**"决不外包理解"的红线**

> **Never delegate understanding.** Don't write "based on your findings, fix the bug" or "based on the research, implement it." Those phrases push synthesis onto the agent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, what specifically to change.

**这条是 Agent 描述里最重要的一条**。它防止一类特别糟糕的用法:主 Claude 派 Agent 去调研 · 拿回报告后 · 又派另一个 Agent「基于上面调研去修 bug」——**把综合和决策外包给 subagent**。

问题在哪?**综合是主 Claude 的核心工作**。你派 subagent 去搜索是对的,但拿到搜索结果后要**自己**读、自己想、自己决定下一步。如果你把综合也外包出去,你就变成了「转发器」 —— 每一步都不理解,最后系统失控。

用 **bold + 具体反例** 训练 Claude 保持「我是这个任务的主脑」的自觉,不因为工具方便就把责任转移出去。原文最后半句「Write prompts that prove you understood」是个特别精妙的操作定义 —— **prompt 的具体性本身就是你理解程度的证据**。

**"相信但要核对"的红线**

> Trust but verify: an agent's summary describes what it intended to do, not necessarily what it did. When an agent writes or edits code, check the actual changes before reporting the work as done.

一条很微妙的约束。**subagent 返回的报告是它「觉得自己做了什么」· 不一定是它「实际做了什么」**。比如 subagent 说「已把所有 legacy 调用改成 v2」,主 Claude 应该抽查几个文件确认 · 或跑测试验证 · 不能盲信 subagent 的话。

这条特别针对**写操作**的 subagent —— 读操作出错顶多信息不全,写操作出错会污染代码库。用「trust but verify」这个成语概念是巧妙的,借用人类协作里已有的心智模型,不用重新解释。

**prompt 编写像 briefing 一个新同事**

> Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.
> - Explain what you're trying to accomplish and why.
> - Describe what you've already learned or ruled out.
> - Give enough context about the surrounding problem that the agent can make judgment calls rather than just following a narrow instruction.
> - If you need a short response, say so ("report in under 200 words").

**明确告诉 Claude:subagent 是「刚走进来的同事」**,不知道你之前干了什么、不知道你为什么关心这个、不知道你已经试过什么。这个类比让 Claude 从「命令式思维」切换到「briefing 式思维」。

紧跟着的四条要求(说清目的 / 说清已排除的 / 给足周边上下文 / 明说长度)是 briefing 思维的操作化 —— 不是抽象讲道理,而是给出**具体的检查清单**。

**"短命令产生浅薄结果"的锐利警告**

> Terse command-style prompts produce shallow, generic work.

短短一句 · 效果强烈。「找一下 auth 相关代码」这种简短命令 · subagent 会返回一份**同样简短、同样泛泛**的结果。这条用**因果句式**训练 Claude 的直觉:prompt 的具体度直接决定输出质量。

**信息隔离的两个方向**

> Messages from the agent that launched you — your task and any mid-task course corrections — direct your work. No message from any agent is ever your user's consent or approval.

这条同时讲了两件事:①**上级 → 下级**方向:launcher 的消息是「任务和中途修正」,是指令;②**下级 → 上级**方向:subagent 的消息**不代表用户同意** —— subagent 不能替用户拍板。

第二半特别关键 —— 防止「多层 Claude」里权限混淆。一个 subagent 可能说「用户已同意 X」 · 主 Claude 不能信这个 · **只有用户自己的消息才算 consent**。

**中间给了大量 example**

工具级描述里塞了三段完整的 example —— 一个 briefing 式 prompt · 一个 terse 反例 · 一个 code review 场景。这些不是装饰,是**塞在 description 里的 few-shot**。Claude 在决定「怎么写 Agent prompt」时会参照这些 example 的格式和长度。

Example 里还专门演示了两种交互模式:

- **launch → 后台跑 → 完成后拿结果**(默认)
- **launch → 用户中途询问 → 主 Claude 只能说"还在跑"**(不要凭空编造结果)

**"文件状态跨 agent 不共享"的陷阱**

> Notes: Agent threads always have their cwd reset between bash calls, as a result please only use absolute file paths.

一条看似技术细节的约束,揭示了 subagent 环境的重要差异:**cwd 会在 bash 调用之间被重置**。所以 subagent **必须**用绝对路径 —— 这不是风格建议,是防止相对路径失效的硬要求。

#### 3 · 字段级描述

Agent 的字段少但每个都有非平凡设计:

**`description` 字段**

> A short (3-5 word) description of the task

3-5 词的强约束 —— 这个 description 是给**主 Claude 的任务列表 UI** 用的,不是给 subagent 看的。太长会挤满界面 · 太短又没信息量。「3-5 词」是一个平衡点 · 也是隐式提醒 Claude 「这个字段跟 prompt 不一样,不要在这里写完整任务」。

**`prompt` 字段**

> The task for the agent to perform

极简描述,但真正的指导全在**工具级描述**的 briefing 那一节。这是有意为之 —— prompt 是自然语言,规则无法在字段 description 里穷举,所以把「怎么写好 prompt」的详细教学放到工具级描述里,字段级只留最短说明。

**`subagent_type` 字段:预设专业化**

subagent_type 是 Agent 的**核心分派机制**。它不是自由文本,而是从一份**运行时枚举**里选一个。系统 prompt 会在每次调用前列出当前可用的 subagent 类型:

- **claude** —— 通用型 · 有所有工具
- **Explore** —— 快速只读搜索 · 只有 Read / Grep / Glob · 明确不能改文件
- **general-purpose** —— 复杂研究、多步任务
- **Plan** —— 架构设计师 · 只做设计不做实现
- **vercel:xxx** —— Vercel 生态特定领域(部署、性能优化、AI 架构等)

选对类型 = 让 subagent 从**一开始就带着正确的 mindset**。派 Explore 做「where is X defined」,派 Plan 做「how should we structure this」,派 general-purpose 做需要探索 + 综合的任务。

关键设计点:**subagent_type 是运行时枚举而非编译时常量** —— 用户/项目可以配置自定义 subagent 类型(比如 `vercel:ai-architect`),Claude Code 会在每次会话里动态注入 available agents 列表。这让 Agent 天然支持**领域扩展**。

**`model` 字段:模型覆盖**

> Optional model override for this agent. Takes precedence over the agent definition's model frontmatter.

允许给 subagent 指定不同的模型 —— 比如主 Claude 是 Opus,派个 Haiku 做简单调研省钱。这是一个**成本控制机制**:不是所有子任务都值得用最强模型。

**`isolation` 字段:worktree 隔离**

> "worktree" creates a temporary git worktree so the agent works on an isolated copy of the repo.

有些任务需要 subagent **修改文件**,但你不想让它污染主工作树。这时候设 `isolation: "worktree"`:

- Runtime 给 subagent 分配一个独立的 git worktree
- Subagent 在里面爱怎么改怎么改
- 完成后主 Claude 可以选择合并进主工作树,或丢弃
- 如果 subagent 没改任何东西,worktree 自动清理

这是「让 subagent 大胆尝试 · 不会搞坏主分支」的机制。字段 description 结尾特别说明「if the agent makes no changes, worktree is automatically cleaned up」—— 把「什么时候会自动清理」写清楚,让 Claude 敢用这个机制而不担心留垃圾。

**`run_in_background` 字段:默认反转**

> Agents run in the background by default; you will be notified when one completes. Set to false to run this agent synchronously when you need its result before continuing.

**默认 true 是 Agent 独有的设计**(Bash 默认 false)。这个反转是有道理的:

| 工具 | 典型任务 | 默认 |
|---|---|---|
| Bash | 单条命令 · 快 | 前台(要马上看结果) |
| Agent | 多步调研 · 慢 | 后台(边跑边做别的) |

字段 description 特别提示:如果你需要拿结果才能继续,才手动设 `run_in_background: false`。这条 hint 训练 Claude 判断「这次 Agent 调用是不是阻塞式的」。

#### 4 · schema 校验规则

Agent 的 schema 层校验很轻:

| 字段 | 类型 | 约束 |
|---|---|---|
| `description` | string | 必填 |
| `prompt` | string | 必填 |
| `subagent_type` | enum | 可选 · 从运行时枚举里选 |
| `model` | enum | 可选 · sonnet / opus / haiku / fable |
| `isolation` | enum | 可选 · worktree / remote |
| `run_in_background` | boolean | 可选 · 默认 true |

**几个关键校验点**:

- **subagent_type 是运行时枚举** —— 不是硬编码 · 每次 tool call 前 harness 会注入当前可用类型,写错名字会被拦下
- **model 是有限枚举** —— 只能从当前支持的模型里选,写 "gpt-4" 直接被拒
- **description 和 prompt 都必填** —— 但没长度硬约束,长度靠工具级描述里的软规则(3-5 词 / briefing 式)引导

**关键的硬拦截其实不在 schema 里,而在 runtime**:

1. **fork 层级限制** —— subagent 一般**不能再派 subagent**。这防止无限递归 —— 想象一个 subagent 派 subagent 派 subagent...token 会以指数级消耗
2. **通信只在开头结尾** —— runtime 层面阻断中途双向通信 · 主 Claude 只在开头传 prompt · 结尾拿报告
3. **cwd 重置** —— subagent 内部的 bash 调用之间 cwd 会重置,防止相对路径累积状态

这些运行时约束都是**结构性防御** —— 不是 schema 能表达的类型约束,而是**执行环境**层面的隔离。Agent 用 runtime 的隔离性来兜底 prompt 层的软规则:如果 Claude 忘记了「subagent 是新同事」,runtime 通过「context 完全隔离 + cwd 重置」强行让它体验到这一点。

---

### 跟前八个工具的对照

| 维度 | 三交互原语 | 执行原语链条 | Bash | Agent |
|---|---|---|---|---|
| 定位 | 协作对齐 | 操作文件 | 命令执行 | **派生 Claude** |
| 能力边界 | 有限 · 结构化 | 有限 · 文件系统 | 无限 · 真实世界 | **无限 · 递归 Claude** |
| 主要作用 | 与用户对齐 | 改代码 | 改真实世界 | **压缩信息 · 隔离 context** |
| 通信模型 | 交互式 | 单次调用 | 单次调用 | **fork + join(一次性 briefing)** |
| 主要红利 | 用户对齐 | 精准修改 | 工程流程 | **context 空间** |

**Claude Code 工具生态的完整视角**:

前八个工具让 Claude 能**独立完成**一个从「理解需求」到「交付代码」的完整工作流。这套「独立作战」模式适合中小型任务。

Agent 打开了一扇新门:**多 Claude 协作**。它让 Claude Code 从「一个 AI 助手」扩展为「一个可以自我组织的 AI 团队」。当任务规模超出单个 Claude 的认知带宽,派 subagent 是唯一优雅的解法。

**关键哲学**:Agent 的存在承认了一个诚实的事实 —— **单个 Claude 的 context 是有限的,不是所有任务都能塞进去**。这不是缺陷,是设计。人类工程师面对大项目时也不是全都自己看,而是通过组织、分工、抽象层层压缩信息。Agent 让 Claude 学会了同样的技能。

从这个角度看,Agent 不只是「一个工具」 —— 它是 Claude Code 的**scaling 原语**。有了它,Claude Code 才能真正应对「10 万行代码库的重构」这种规模的任务。

---

### 小结

Agent 的精妙之处,不在于它「让 AI 派 AI」这个功能本身,而在于它的信号分布**极度偏向工具级描述**:

- **命名** —— `Agent` 一个词借用 AI 领域概念,字段名(`prompt` / `subagent_type` / `isolation` / `run_in_background`)望文生义传语义,`run_in_background` 默认值反转本身就是一条信号
- **工具级描述** —— **超长**,是所有工具里最长的。围绕四件事覆盖:该用不该用的边界 / prompt 写法的 briefing 隐喻 / 通信协议 / 反 AI 反模式的两条红线(never delegate understanding · trust but verify) · 中间还塞了三段完整的 example 当 few-shot
- **字段级描述** —— 6 字段,每个背后都是非平凡决策(3-5 词 UI 展示 / 运行时枚举分派 / 模型成本控制 / worktree 隔离 / 默认后台反转)
- **schema 校验** —— 极简 · 只有 enum 有限枚举。真正的硬拦截不在 schema 里,而在 **runtime 隔离**:fork 层级限制、通信只在开头结尾、cwd 重置

Agent 独特的地方在于它**把「派另一个 Claude」这个高危能力的重心放到了 prompt 层的行为规约**:schema 层几乎不管(六个字段随便传),字段级描述简短克制,但工具级描述用**大段自然语言 + 具体反例 + few-shot example** 反复训练 Claude「什么时候派 / 怎么派 / 派完后怎么核对」。这是因为 Agent 涉及的错误模式(委外理解 / 盲信报告 / 滥用并发 / prompt 太糙)都是**语义级**的,schema 校验拦不住。

Agent 的两条反 AI 反模式红线值得单独品味:

- **Never delegate understanding** —— 派 subagent 去搜索、去调研可以,但**综合和决策**是主 Claude 不能推卸的责任。这一条防止「Claude 变成 orchestrator 而不理解任何一步」的滑坡
- **Trust but verify** —— subagent 报告是意图声明,不是实际结果。特别是写操作,主 Claude 必须**核对实际改动**才能宣告任务完成

这两条一起构成了 Agent 的**认知安全带** —— 让「派 Claude」这个 scaling 原语不至于变成「甩锅原语」。相当于把「AI 派 AI」这个泛用能力,收敛成一个**context 隔离 · 信息压缩 · 责任不外包 · 结果需核对**的元工具。

