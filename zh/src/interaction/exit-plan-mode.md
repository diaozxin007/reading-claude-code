Claude code tools 研究系列第三篇。前两篇拆了 [AskUserQuestion](ask-user-question.md) 和 [EnterPlanMode](enter-plan-mode.md) —— 决策流水线的前两环:澄清 · 展开。这篇聊最后一环 —— ExitPlanMode:**提交方案让用户批准**。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## ExitPlanMode

从表面看,这可能是 Claude Code 三个交互 tool 里**最不起眼**的一个。它没有 AskUserQuestion 的多选卡片,也没有 EnterPlanMode 的模式切换戏剧性 —— 它只做一件事:**触发一次「批准 / 驳回」的确认**。

但正是这个「什么都不做」的克制,让整套三工具流水线得以闭合。

### 作用

ExitPlanMode 是 Claude Code 内置的**「规划模式退出 · 请求批准」工具**。它的职责就一句话:在 plan mode 里写好完整方案后,调用这个工具,让用户看到 plan 全文并做出决定 —— **批准执行 / 让 Claude 修改 / 驳回换方向**。

它解决的核心问题是「AI 从规划切回执行时,如何得到用户显式的批准」:

1. **让方案可视化** —— plan 文件的完整内容被 UI 展示给用户,不是聊天里飘过的一段话
2. **强制显式决策** —— 用户必须点批准 / 驳回,不能默认继续,防止 Claude 抢跑
3. **一键切换回执行模式** —— 用户批准后 Claude 自动回到可用 Edit/Write 的默认模式
4. **保留反馈通道** —— 用户可以驳回并要求修改,而不是「要么全按 plan 走 · 要么全废」

### 一个具体例子

**场景**:承接上一篇 [EnterPlanMode](enter-plan-mode.md) 里那个 auth 重构例子 —— 用户说「把 JWT 换成 session cookies」,Claude 已经进 plan mode 探索完、跟用户 Ask 澄清完(只换 web 端 · session 用 Redis)、写好了 plan 文件,现在准备开始写代码。

问题来了:**Claude 怎么让用户知道 plan 写完了,可以开始执行了?**

#### 反例:如果没有 ExitPlanMode

Claude 只能在聊天里说:「我方案写好了,大概是这样... [几百字的方案描述] ... 可以开始了吗?」

用户会遇到几个问题:

1. **plan 淹没在聊天里** —— 几百字的方案跟前面的探索日志、澄清对话混在一起,难阅读
2. **没有明确的批准动作** —— 用户回复「OK」/「行」/「可以」/「👍」都能表示同意,但语义不明确
3. **Claude 需要解析同意语义** —— 拿到「行,不过 sessions 表的字段能不能加个 device_id?」这种半批准半修改的回复,不知道该继续还是回改 plan
4. **模式切换没有仪式感** —— Claude 从「规划」滑到「执行」是**渐变**的,可能话说到一半就开始写代码,用户措手不及
5. **驳回成本高** —— 用户如果发现方案有问题,得手动打字说清楚,而不是有一个「驳回并说明理由」的正规通道

**最深层的问题**:如果 Claude 想通过 AskUserQuestion 问「方案 OK 吗?」来解决这个 —— 上一篇提过,**在 ExitPlanMode 触发之前,用户根本看不到 plan 全文**。用 Ask 问「OK 吗?」等于让用户在真空里投票,毫无意义。

#### 用 ExitPlanMode 是怎么解决的

Claude 写完 plan 文件后,直接调用 ExitPlanMode(**入参也是空的** —— 见下文技术实现)。UI 层做几件事:

**Step 1 · 展示 plan 全文**

界面会从 plan mode 指定的 plan 文件路径读取内容,渲染成一个**独立、结构化、可滚动**的方案视图。用户看到的不是「聊天里飘过的一段话」,而是一份正式的方案文档:范围 / 影响文件 / 迁移步骤 / 风险 / 回滚。

**Step 2 · 提供三种明确的响应通道**

- ✅ **批准** —— Claude 回到默认模式,按 plan 执行
- ✏️ **修改** —— 用户输入反馈,Claude 回 plan mode 继续调整
- ❌ **驳回** —— 结束,换方向

**Step 3 · 模式切换是原子的**

用户按下批准的一刻,runtime 做几件事:
- Edit / Write / NotebookEdit 从禁用变为可用
- CWD 相关缓存刷新
- Claude 拿到「用户已批准」的显式信号,开始执行

**没有语义歧义、没有滑坡、没有 Claude 抢跑**。

#### 对照一下两种形式解决了反例里的哪些痛点

| 反例痛点 | ExitPlanMode 的解法 |
|---|---|
| plan 淹没在聊天里 | UI 独立渲染 plan 文件全文,不是聊天消息 |
| 没有明确的批准动作 | 用户必须点批准 / 修改 / 驳回,枚举明确 |
| Claude 需要解析同意语义 | 返回值是结构化状态(批准 / 未批准),不是自然语言 |
| 模式切换没有仪式感 | 批准触发原子性的工具白名单切换 |
| 驳回成本高 | 「修改」是一等公民入口,不需要用户手写「你改改」 |

### 触发条件

工具官方说明写得很直接:**「只在你在 plan mode 里 · 写完 plan 文件 · 准备好接受用户批准的时候用」**。

**该用的场景**:
- 在 plan mode 里,plan 文件写完了 —— **唯一合规的调用时机**

**不该用的场景**:
- **纯研究任务** —— 官方原文举了个反例:「搜索并理解 vim 模式的实现」这种任务,不该用 ExitPlanMode,因为你没在做「实现规划」
- **plan 还没定型** —— 半成品方案不该拿出来批准,先补完
- **想用它做一般性询问** —— 「我可以继续吗?」这种问题应该用别的通道(如果确实需要问 · 用 AskUserQuestion 澄清具体分叉,而不是问元问题)

一个有意思的判断线:**能被引用的方案才配触发 ExitPlanMode**。如果你的方案还没到「一份可读、可审阅、可反驳的文档」的程度,那就先继续在 plan mode 里探索,别急着 exit。

### 技术实现

#### 1 · 命名

`ExitPlanMode`

和 `EnterPlanMode` 完全对偶 —— `Enter/Exit` 是标准的进出配对，暗示"有始有终"的状态操作，而不是单向切换。命名直接借用文件描述符 open/close、锁 acquire/release 这种约定俗成的对偶范式，语义无需解释。

如果叫 `SubmitPlan` 或 `RequestApproval`，语义会滑向"提交某个数据 / 请求某个权限"，反而弱化了它作为**模式退出信号**的核心语义。

#### 2 · 工具级描述

ExitPlanMode 的描述围绕三件事：**什么时候用 / 参数不传 plan 内容 / 禁止用 Ask 问元问题**。

**严格的适用边界（开篇）**

> Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

三个条件叠加：**在 plan mode 里 + plan 文件已写完 + 准备接受批准**。任一不满足都不该调。

**参数机制的透明化**

> This tool does NOT take the plan content as a parameter - it will read the plan from the file you wrote

明确告诉 Claude：**别想着把 plan 内容塞进 tool call 参数**。UI 会自己从 plan 文件读。这是防止 Claude 冗余复制 —— 既省 tokens 也确保「UI 展示的和 plan 文件一致」。

**批准的隐含语义**

> This tool simply signals that you're done planning and ready for the user to review and approve

关键词 **signal** —— 这个 tool 不做实际渲染逻辑、不做批准判定，它只发一个信号。渲染、投票、状态切换都由 runtime 处理。**tool call 是最轻量的「信号发射器」** —— 一个非常 Unix 哲学的设计。

**与研究任务的边界**

> IMPORTANT: Only use this tool when the task requires planning the implementation steps of a task that requires writing code. For research tasks where you're gathering information, searching files, reading files or in general trying to understand the codebase - do NOT use this tool.

这条呼应 EnterPlanMode 那篇也强调过的：**plan mode 是「实现前的规划」，不是「理解现有代码的调研」**。研究性任务应该用 Agent tool 派 subagent 去调研。

**禁止元问题反模式**

> **Important:** Do NOT use AskUserQuestion to ask "Is this plan okay?" or "Should I proceed?" - that's exactly what THIS tool does. ExitPlanMode inherently requests user approval of your plan.

这条特别精妙 —— 它不是简单说「用 ExitPlanMode 别用 Ask」，而是从**语义等价性**角度指出：**Ask 问「plan OK 吗」和 ExitPlanMode 是同一个语义，用后者才是正确表达**。前两篇都提过这条反模式的存在，本篇给出了描述层的**根本禁令**。

**澄清 vs 请求批准的顺序**

官方 Examples 第 3 条：

> Initial task: "Add a new feature to handle user authentication" - If unsure about auth method (OAuth, JWT, etc.), use AskUserQuestion first, then use exit plan mode tool after clarifying the approach.

明确了 Ask 和 ExitPlanMode 在 plan mode 里的**执行顺序**：先澄清具体分叉，再统一拿方案去批准。**不要边澄清边请求批准**，让流程线性收敛。

#### 3 · 字段级描述

**空**。

有一个字段 `allowedPrompts` 但已被标记 deprecated（"Deprecated: no longer used"），实际不使用。

这个字段的历史痕迹本身很有意思：从字段名反推，早期版本可能允许 Claude 在请求批准的**同时**声明一批「用户批准后自动放行的操作类型」（比如 `run tests` / `install dependencies`），让 Claude 一次性拿到复合权限。现在被弃用了，说明 Claude Code 团队后来选择了更保守的路径：**批准就是批准 plan 本身，权限扩展走别的机制**（比如 permissions.yaml）。这是一个**权限设计从「批准即授权」演进到「批准归批准 · 授权归授权」的痕迹**。

#### 4 · schema 校验规则

**空**。

和 EnterPlanMode 一样 —— input_schema 只有一个 deprecated 字段，无实际约束。调用行为本身 = 提交意图，不需要传任何数据。

**空 schema 的运行时职责**：

1. 只在 plan mode 里可用 —— 默认模式下调不动
2. 触发 UI 展示 plan —— UI 从 plan mode 状态里知道 plan 文件的路径，读取渲染
3. 等待用户显式响应 —— 同步阻塞，没有默认继续
4. 批准 → 原子性模式切换 —— 工具白名单恢复、缓存刷新、Claude 拿到批准信号

这几件事都是 runtime 干的，不需要 Claude 传参 —— 又一次呼应 EnterPlanMode 的空 schema 设计：**权限和状态收敛在 runtime，Claude 只发信号**。

---

### 与邻居工具的分工

**决策流水线的最后一环** —— 三个工具的完整闭环：

```
用户: 「帮我重构 auth · JWT 换 session」
    ↓
Claude: 有几个分叉需要确认
    ↓
AskUserQuestion (澄清: 只换 web 端 · Redis session store)
    ↓
Claude: 好 · 让我先做个规划
    ↓
EnterPlanMode (用户批准进入)
    ├─ Grep / Read / Glob 探索
    ├─ Ask 澄清子问题 (中间可能再问几次)
    └─ 写 plan 文件
    ↓
ExitPlanMode (用户看到完整 plan)
    ├─ ✅ 批准 → 默认模式 · 按 plan 执行
    ├─ ✏️ 修改 → 回 plan mode 调整 · 完成后再 Exit
    └─ ❌ 驳回 → 结束
```

**三个工具各司其职，组合起来才构成一次完整的「协作对齐」**：

- **AskUserQuestion** —— 澄清:「A 还是 B?」（单点决策）
- **EnterPlanMode** —— 展开：进入只读探索，把方案落成文档
- **ExitPlanMode** —— 拍板：让用户对整个方案做批准 / 修改 / 驳回

---

### 小结

ExitPlanMode 的精妙之处，不在于它「让用户批准方案」这个功能本身，而在于它的信号分布**跟 EnterPlanMode 高度镜像** —— 命名对偶（Enter/Exit）、工具描述堆行为约束、字段和 schema 都是空的。

如果说 AskUserQuestion 是「让用户点选项」、EnterPlanMode 是「进入规划模式」，那 ExitPlanMode 就是这套系统里**最谦逊的一环**：它什么都不做，只发一个信号，却让整个流程有了终点、让整套协作有了「拍板」的仪式感。

**三工具流水线到此闭合**：

> Claude Code 把「AI 与人协作」这件事，拆成了三个可组合、可编排、可预测的交互原语：澄清 · 展开 · 拍板。每一个原语都是**克制**的 —— 只做一件小事 —— 但组合起来足够表达任何协作场景。

下一篇继续拆 [Grep + Glob](../execution/grep-glob.md) —— 从"协作对齐"三工具切换到"代码探索"两工具，看看信息搜索类 tool 是怎么编码"搜什么 / 怎么搜 / 返回多少"的。
