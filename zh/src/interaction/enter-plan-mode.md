Claude code tools 研究系列第二篇。上一篇拆了 [AskUserQuestion](ask-user-question.md) —— 一个「让用户点选项」的结构化提问工具。这篇聊它的**兄弟工具** —— EnterPlanMode。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## EnterPlanMode

跟 AskUserQuestion 一样,是每天都能见到的高频工具。但它的设计比 Ask 更「重」 —— 它不是问一个问题,而是**把 Claude 切换到一种全新的工作模式**。

### 作用

EnterPlanMode 是 Claude Code 内置的**「规划模式入口」工具**。它做的事很简单也很暴力:把 Claude 从「边想边写」的默认模式,切换到一个**只读探索 + 方案设计**的规划模式,拿到用户对方案的显式批准之后,再回到写代码模式。

它解决的核心问题是「AI 与用户之间的方案对齐」:

1. **防止半途改错方向** —— 让 Claude 在动手改任何一个文件之前,先跟用户对齐方案
2. **强制只读探索** —— 进入规划模式后 Edit / Write / NotebookEdit 被禁用,物理上无法「边探索边偷偷改」
3. **明确决策边界** —— 用户看到完整方案后批准 / 驳回 / 让 Claude 修改,不是看到 PR 才发现方向错了
4. **可追溯的规划产物** —— Plan mode 产出的是一份写下来的 plan 文件,不是聊天里飘过的一段话,可以引用、可以修订

### 一个具体例子

**场景**:用户对 Claude 说 **「帮我重构这个身份验证模块,把 JWT 换成 session cookies」**。

这个需求听起来清晰,但实际横跨:登录路由 / token 生成中间件 / 前端存储层 / 会话过期策略 / 数据库 schema (要不要建 sessions 表?) / 已有 API 调用者的向后兼容处理。**多文件、多决策、多依赖**。

#### 反例:如果没有 EnterPlanMode

Claude 只能凭上下文猜一个方案,直接动手:

- 打开 `auth/middleware.ts` —— 改成读 session cookie
- 打开 `auth/routes.ts` —— 删掉 JWT 签发,改成 `req.session`
- 打开 `frontend/api.ts` —— 删掉 `Authorization` header 逻辑
- 打开 `models/user.ts` —— 加个 `sessionId` 字段
- 改到一半发现:原来项目里有 3 个别的服务通过 JWT 校验访问这套 API...

用户看到 diff 一脸懵:「我要的是 web 端 session,后台服务的 JWT 请保留啊。你把整套 API 都换了怎么办?」

这一轮出现的问题:

1. **方向性错误提前 5 步才发现** —— 已经改了 4 个文件,回滚很痛
2. **决策边界模糊** —— 「是替换所有 auth 还是只替换 web 端」这种关键分叉,Claude 猜错了没人拦
3. **用户看不到全景** —— 只看到一堆 diff,反推方案很累
4. **重要副作用未预警** —— 数据库要不要建 sessions 表?session 过期用 memory 还是 Redis?这些都在 Claude 脑子里飘过但没落地成文
5. **回滚成本高** —— 每一步改动都花了 tokens 和心智,推翻等于全废

**核心痛点**:「边想边写」让 Claude 在一个**方案还没定型的状态下**开始产出 diff · 用户不到最后一刻看不到全局。

#### 用 EnterPlanMode 是怎么解决的

Claude 会先声明「我要进 plan mode」,请求用户批准 —— **注意这一步本身就是一个交互确认**,拒绝了就退回默认模式。用户批准后:

**Step 1 · 进入只读探索**

Claude 的工具箱被收窄:
- ✅ 可用:Read / Glob / Grep / Agent / AskUserQuestion / ExitPlanMode
- ❌ 禁用:Edit / Write / NotebookEdit

物理上无法改任何一个文件。所有探索行为都是读性质的。

**Step 2 · 摸清项目现状**

- 用 Grep 找出所有使用 JWT 的地方 —— 发现除了 web 端,还有 3 个内部服务
- 用 Read 看 `auth/middleware.ts` 的现有校验逻辑
- 用 Glob 定位所有 auth 相关的测试文件
- 用 Agent 派一个 general-purpose subagent 去调研「项目里有没有既有的 session store 约定」

**Step 3 · 遇到关键分叉,用 AskUserQuestion 澄清**

比如问用户:
- 是「只换 web 端」还是「全部换」?
- session store 用 memory / Redis / DB?

—— 这就回到了上一篇讲的 Ask 澄清模式,**Ask 和 EnterPlanMode 天然配对**。

**Step 4 · 写下方案**

Claude 把整套方案写到一个 plan 文件里:范围、影响文件、迁移步骤、风险、回滚策略。**这是一份可以被引用、被修订的产物,不是聊天记录**。

**Step 5 · ExitPlanMode 请求批准**

用户看到完整的方案,做出决定:
- ✅ 批准 → Claude 回到写代码模式,按 plan 执行
- ✏️ 修改 → 反馈意见,Claude 修 plan
- ❌ 驳回 → 换方向

**没有一个文件在被批准之前被改过**。用户的 tokens、时间、心智不会浪费在错方向上。

#### 对照一下两种形式解决了反例里的哪些痛点

| 反例痛点 | EnterPlanMode 的解法 |
|---|---|
| 方向性错误提前 5 步才发现 | ExitPlanMode 批准之前不能改任何文件 |
| 决策边界模糊 | plan mode 里可用 AskUserQuestion 澄清关键分叉 |
| 用户看不到全景 | plan 文件是完整方案,而不是一堆 diff |
| 重要副作用未预警 | 强制探索 → 设计 → 呈现,给 Claude 时间考虑周全 |
| 回滚成本高 | 探索是只读的,plan 被驳回不用回滚代码 |

### 触发条件

工具官方说明写了一条很有意思的原则:**「非平凡的实现任务默认走 plan」** —— 这是一个**偏保守的默认**。

**7 类**「该用 plan」的场景:

- **新功能实现** —— 不管多小,只要是从 0 加一块功能都有隐含决策(放哪、按钮点了做啥、报错怎么处理...)
- **多种合理方案** —— 「加缓存」可能是 Redis / 内存 / 文件,「实时更新」可能是 WebSocket / SSE / 轮询,选择本身就是设计
- **修改现有行为** —— 「更新登录流程」到底改什么?动前先说清楚
- **架构决策** —— 选模式、选依赖、选数据流方向,都是要用户拍板的
- **跨 3 个以上文件的改动** —— 影响面大到 diff 看不出全貌
- **需求本身不清晰** —— 「让 app 变快」 —— 得先 profile,先讨论优化方向
- **用户偏好会影响实现** —— 如果你想用 AskUserQuestion 澄清,那更应该用 EnterPlanMode 展开

**4 类**「不该用 plan」的场景:

- **单行修复** —— 修 typo、明显的 off-by-one
- **只添加一个函数,需求非常清晰** —— 直接写,不用铺垫
- **用户已经给出非常具体、详细的指令** —— 用户已经在做规划的事,Claude 再规划一次是重复
- **纯研究 / 探索任务** —— 这种任务应该用 Agent tool,不涉及后续实现

一个**很有意思的偏差**:官方原文写 "err on the side of planning" —— **如果不确定,倾向于规划**。这个默认设置本身就说明设计者的态度:**bias toward alignment over speed**。

### 技术实现

#### 1 · 命名

`EnterPlanMode`

对比 AskUserQuestion 4 层都有信号，EnterPlanMode 的信号分布很不一样 —— **命名承担了本该由 schema 承担的角色**：

- `Enter` —— 动词，暗示"进入一种状态"（不是获取数据、不是执行动作）
- `PlanMode` —— 状态名，配对 `ExitPlanMode` 形成对偶

一个反事实设计：如果叫 `SetMode(mode: "plan")`，模型会把它当成"设置一个属性"，随手切换、随手切换回。当前命名把它编码成一次**有仪式感的状态跳转** —— 需要显式 Enter，需要显式 Exit，语义比参数化的 SetMode 强得多。

这也是为什么后面 schema 层可以是空的 —— 命名已经把语义顶死了，schema 不需要再兜底。

#### 2 · 工具级描述

EnterPlanMode 的描述围绕四件事：**什么时候用 / 什么时候不用 / 与邻居的分工 / 运行时会发生什么**。

**开篇的保守偏差**

> Prefer using EnterPlanMode for implementation tasks unless they're simple.

一句话就重塑了 Claude 的行为倾向 —— 「不确定的时候先规划」，而不是「不确定的时候直接干」。这是把**默认档位调保守**写进了 tool 顶部。

**7 类 use case 的量化门槛**

原文 "When to Use This Tool" 段落列了 7 个编号 heading，每条都带具体判断线索。最典型的一条：

> Multi-File Changes: The task will likely touch more than 2-3 files

给出**量化门槛**（2-3 文件）而不是主观感觉。这减少了 Claude 在"要不要用 plan mode"这件事上的分歧 —— 主观直觉被编译成客观规则。

**与 AskUserQuestion 的边界**

> If you would use AskUserQuestion to clarify the approach, use EnterPlanMode instead

这条把一个模糊边界（什么时候用 Ask 什么时候用 plan）转化成明确规则：**Ask 只解决单点澄清，涉及方案层面的分叉直接开 plan**。避免"用 Ask 问一堆问题拼凑出一个方案"这种反模式 —— 那种 Ask 循环体验很差。

**与 Agent 的边界**

> Pure research/exploration tasks (use the Agent tool with explore agent instead)

明确了另一条边界：**纯研究不做实现的，别用 EnterPlanMode**。为什么？因为 EnterPlanMode 是「实现前的规划」，如果不打算实现，进 plan mode 是空转 —— 直接用 Agent 派 subagent 调研更合适。

**用户批准是硬要求**

> This tool REQUIRES user approval - they must consent to entering plan mode

这不是「AI 单方面切换状态」 —— 用户是流程的守门员。这也解释了为什么这是个空参数的 tool call：调用本身就是一次「请示」，不是执行。

**不确定时的默认**

> If unsure whether to use it, err on the side of planning - it's better to get alignment upfront than to redo work

这是整段 prompt 的**价值观声明** —— 与其做错回滚，不如多花一轮对齐。这个价值观在 AskUserQuestion 那篇也见过 —— **Claude Code 的整个工具生态都 bias toward alignment**。

**社交礼仪 framing**

> Users appreciate being consulted before significant changes are made to their codebase

这一句在训练 Claude 的**社交直觉** —— 不只是效率考虑，规划本身是一种「尊重用户对自己 codebase 的所有权」的姿态。这个 framing 让 Claude 不把「先规划」看成打扰，而看成协作礼仪。

#### 3 · 字段级描述

**空**。

EnterPlanMode 没有任何入参字段 —— schema 是空对象 `{}`。所以字段级描述这一层不存在。所有意图都上移到工具级描述里。

#### 4 · schema 校验规则

**空**。

`input_schema` 是空对象 —— 无字段、无类型、无约束。调用行为本身 = 状态切换意图，不需要传任何数据。

这一层的"空"本身就是设计信号：**权限收敛在工具层实现，不在参数层**。Claude 不需要"申请"某些权限或"声明"进入哪种模式，官方 runtime 在 Claude 调用 EnterPlanMode 后自动执行以下动作：

1. 需要用户批准 —— 就像 Ask 一样，进入 plan mode 需要用户点「同意进入 plan」
2. 工具白名单被收窄 —— 进入后 Edit / Write / NotebookEdit 被禁用
3. CWD 相关的缓存被重写 —— system prompt sections / memory files / plans directory 都会重刷，确保 plan mode 上下文干净
4. 只能通过 ExitPlanMode 退出 —— 不像 AskUserQuestion 那样问完就结束，plan mode 是一个**持续的状态**

---

### 与邻居工具的分工

- **AskUserQuestion** —— 单点澄清:「A 还是 B？」
- **EnterPlanMode** —— 展开完整方案（在 plan 期间 Ask 可以继续用）
- **ExitPlanMode** —— 提交方案让用户批准

三个工具连起来的完整决策流水线：

```
遇到不清楚的分叉
    ↓
Ask 澄清 (选 A / 选 B)
    ↓
EnterPlanMode (进入规划模式)
    ├─ Grep / Read / Glob / Agent 探索
    ├─ Ask 澄清子问题 (可以多次)
    └─ 写 plan 文件
    ↓
ExitPlanMode (提交方案)
    ├─ 用户批准 → 回默认模式 · 按 plan 写代码
    ├─ 用户修改 → 回 plan mode 改
    └─ 用户驳回 → 结束
```

上一篇讲过 AskUserQuestion **不应该**在 plan mode 里被用作「方案 OK 吗」的元问题 —— 原因再复述：**因为用户在 ExitPlanMode 触发之前根本看不到 plan · 用户无东西可批** · 「OK 吗」这个问题在这个时序里没有语义。

---

### 小结

EnterPlanMode 的精妙之处，不在于它「让 AI 先想再做」这个功能本身，而在于它的**信号分布极端偏斜**：命名承担核心语义（Enter + PlanMode 的对偶）、工具级描述堆满行为约束（7 类 use case + 保守偏差 + 社交礼仪）、字段级描述和 schema 都是空的。

这告诉我们一个更本质的事：**空 schema 本身就是一种设计**。当一个 tool 的语义就是"状态切换"时，参数化会破坏这个语义 —— 参数化的 SetMode 邀请随手切换，而无参的 EnterPlanMode 是一次仪式化的请示。

下一篇继续拆 [ExitPlanMode](exit-plan-mode.md) —— 三工具决策流水线的最后一环 · 看看「提交方案批准」这个动作是怎么设计的。
