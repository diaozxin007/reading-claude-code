Claude code tools 研究系列第十篇。前九篇拆完了:

- **交互原语三件套**([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md))
- **执行原语链条**([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md))
- **通用兜底** [Bash](../power/bash.md)
- **元工具** [Agent](../power/agent.md)

前九个工具都是「Claude 做**当下的事**」—— 每次 tool call 就是「现在马上」执行一个动作。但真实项目里,还有另一类需求:**记住需要做的事、追踪进度、把大任务拆成子任务、多 Claude 协作时共享同一份清单**。

这需要一个**「任务管理系统」**。Claude Code 的答案是 Task 家族 —— 6 个工具组成的 todo 系统。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Task 家族(TaskCreate / TaskList / TaskGet / TaskUpdate / TaskStop / TaskOutput)

这是系列到目前为止**第一次一篇拆 6 个工具**。为什么合并?因为它们**共享同一个数据模型**(任务清单)· 语义高度耦合 · 单拆一个会把注意力从「系统」拉回「操作」。就像人不会单独介绍「怎么创建一个 JIRA ticket」而不讲整个 JIRA 系统。

### 家族概览

先给一张表,一眼看清 6 个工具各自的职责:

| 工具 | 职责 | 常用时机 |
|---|---|---|
| **TaskCreate** | 建一个新任务 | 拆解复杂需求时 · 收到多点要求时 |
| **TaskList** | 列所有任务 | 找下一个能做的活 · 汇报进度 |
| **TaskGet** | 拿单个任务详情 | 开始做任务前 · 看依赖 |
| **TaskUpdate** | 改任务状态 / 元数据 | 开始任务 · 完成任务 · 建依赖 |
| **TaskStop** | 停止后台运行的任务 | 中止 background bash / subagent |
| **TaskOutput** | 从后台任务取输出 | *已废弃 · 用 Read tool 取输出文件* |

**核心分工**:前 4 个是**任务本身的 CRUD**(New / List / Get / Update)· 后 2 个是**运行时任务的控制**(停止 / 取输出) —— 都叫 Task 但实际是两组:

- **待办任务**(todo)—— 是概念上的 · Claude 记下来的事
- **运行任务**(running)—— 是实体上的 · 一个真正在跑的 bash / subagent

TaskCreate / List / Get / Update 管前者,TaskStop / TaskOutput 管后者。同名不同意 —— 这是 Task 家族最容易让人困惑的地方,后面会展开。

### 作用

Task 家族(尤其是待办任务四件套)解决的核心问题是「Claude 如何**跨 tool call 跨时间**管理多步骤工作」:

1. **拆解可视化** —— 复杂需求拆成条目 · 用户能看到 Claude 的推进节奏
2. **进度追踪** —— 每个任务有 pending / in_progress / completed 状态 · 一目了然
3. **依赖建模** —— 任务之间可以有「A 挡住 B」的关系 · 强制顺序
4. **多 Claude 协作** —— 主 Claude 拆任务 · subagent 认领 owner · 共享同一清单
5. **上下文压缩** —— 用短短一行 subject 承载一整块工作 · 主 Claude 不用反复回忆

它跟前面所有工具的关键差异:**Task 是唯一有「持久状态」的工具家族**。Read / Edit / Bash 的结果都在 tool call 里返回一次就完;TaskCreate 建的任务会**留在系统里**,后续任何时候 TaskList 都能看到,直到被标 completed 或 deleted。

### 一个具体例子

**场景**:用户说 **「我要给项目加个用户资料页 · 需要:后端 API + 前端组件 + 数据库 schema + 单测 + 权限校验」**。

这是一个典型的**多任务复合需求**。不用 Task 家族会怎样?

#### 反例:如果不用 Task 家族

Claude 只能:

1. 记在自己的短期记忆里 · 边做边想「接下来做什么」
2. 每完成一步都在聊天里说「好 · 现在我要做 xxx 了」· 用文字记录进度
3. 一旦对话变长 · Claude 的注意力被别的东西挤走 · **忘了还有单测没写**
4. 用户想问「你这个功能做到哪了」 · Claude 得回顾整个对话历史才能答

**核心痛点**:任务清单**只存在于 Claude 的短期上下文里** · 一旦上下文压缩、切换 subagent、跨 session 恢复,清单就丢了。

#### 用 Task 家族是怎么解决的

**Step 1 · 收到需求 · 立刻建任务**

Claude 拿到需求,第一件事就是 TaskCreate,把 5 个子任务全建出来:

```
TaskCreate(subject: "设计数据库 schema", description: "users 表加 profile 字段 · 或新建 profiles 表")
TaskCreate(subject: "写迁移文件", description: "生成 knex migration")
TaskCreate(subject: "实现后端 API", description: "GET/PATCH /api/profile · 走鉴权中间件")
TaskCreate(subject: "前端组件 ProfilePage", description: "路由 /profile · 表单 · 提交调 API")
TaskCreate(subject: "补充单测", description: "API 层单测 + 前端组件测试")
```

每个任务返回一个 ID(比如 `task_001` ~ `task_005`)。

**Step 2 · 建依赖 · 强制顺序**

有些任务有明显的先后关系:先有 schema 才能写 API,先有 API 才能做前端。用 TaskUpdate 建 `blockedBy`:

```
TaskUpdate(taskId: "task_002", addBlockedBy: ["task_001"])  # 迁移依赖 schema 设计
TaskUpdate(taskId: "task_003", addBlockedBy: ["task_002"])  # API 依赖迁移
TaskUpdate(taskId: "task_004", addBlockedBy: ["task_003"])  # 前端依赖 API
TaskUpdate(taskId: "task_005", addBlockedBy: ["task_003"])  # 单测也依赖 API
```

现在整个清单形成一条依赖链:schema → migration → API → (前端 + 单测)。

**Step 3 · 找下一个能做的活**

Claude 调 TaskList,看到:

```
task_001 · pending  · "设计数据库 schema"     · blockedBy: []
task_002 · pending  · "写迁移文件"            · blockedBy: [task_001]
task_003 · pending  · "实现后端 API"          · blockedBy: [task_002]
task_004 · pending  · "前端组件 ProfilePage"  · blockedBy: [task_003]
task_005 · pending  · "补充单测"              · blockedBy: [task_003]
```

**只有 task_001 是 pending 且 blockedBy 为空** —— 那就是下一个要做的。

**Step 4 · 认领 + 做 + 交付**

```
TaskUpdate(taskId: "task_001", status: "in_progress")
# ... Claude 做实际工作:讨论 schema · 写下决定 ...
TaskUpdate(taskId: "task_001", status: "completed")
```

现在 task_002 的 blockedBy 空了 · 可以做了。

**Step 5 · 分包给 subagent**

大任务(比如「前端组件」)可以派给 subagent:

```
Agent(
  description: "实现 ProfilePage",
  prompt: "任务 ID task_004 · 前端 ProfilePage 组件 · 路由 /profile · 详见 TaskGet 拉的详情 ..."
)
```

**Subagent 拿到 task ID 后可以自己 TaskGet 详情、TaskUpdate 认领、做完标 completed** —— 主 Claude 和 subagent 通过共享 task 系统协作,不用互相发 message。

**Step 6 · 汇报**

用户随时问「做到哪了」,Claude TaskList 一下就能答:

```
✅ task_001 · completed  · 设计数据库 schema
✅ task_002 · completed  · 写迁移文件
🔄 task_003 · in_progress · 实现后端 API (Claude)
⏸️ task_004 · pending    · 前端组件 (blocked by 003)
⏸️ task_005 · pending    · 补充单测 (blocked by 003)
```

一张图 · 一目了然。

#### 关键洞察:Task 家族是 Claude 的「工作记忆外化」

前面所有工具都是**「做事」** —— 让 Claude 完成一个具体动作。Task 家族不一样,它是**「记事」** —— 把 Claude 脑子里的短期规划**外化到 runtime 存储**里。

这个差异带来两个深远影响:

1. **跨 context 持久** —— 就算主 Claude 的对话被压缩、切换、恢复,Task 还在
2. **多 Claude 共享** —— 主 Claude 和 subagent 通过 Task 系统同步工作状态,不用互相 message

这就像人类工程师**把待办事项写到 JIRA 里** —— 不是不信任自己的记忆,而是**记忆是个人的、任务是团队的**。写下来才能协作,才能追踪,才能不遗漏。

### 触发条件

Task 家族的 prompt(每个工具都有)对触发条件有严格约束。合并整理一下:

**该用 Task 家族的场景**:

- **3 步以上的复杂任务** —— 单步任务不用 Task · 直接做
- **非平凡的多操作任务** —— 需要规划、多操作
- **用户明确要求用 todo list** —— 用户直接说「帮我建个 todo」
- **用户给了多个任务** —— 「1. xxx 2. xxx 3. xxx」 · 一次性建出来
- **plan mode 里** —— 用 Task 追踪计划步骤
- **开始工作前** —— 认领后立刻 mark 成 in_progress
- **完成后** —— 立刻 mark completed · 顺便捞新解锁的任务

**不该用 Task 家族的场景**:

- **单个直接的任务** —— 一步就能完成的事情
- **平凡的任务** —— 建 Task 反而增加噪音
- **少于 3 步的简单任务** —— 追踪不带来价值
- **纯对话 / 信息性任务** —— 用户就是问个问题,不需要任务化

一个**核心判断**:**Task 家族是给「有规模的工作」用的**。如果一件事简单到 Claude 一次 tool call 就搞定,建 Task 反而是噪音。如果一件事复杂到会拆分、有依赖、需要追踪,不建 Task 就是失职。

### 技术实现

#### 1 · 命名

`TaskCreate` / `TaskList` / `TaskGet` / `TaskUpdate` / `TaskStop` / `TaskOutput`

**Task** 作为家族前缀,取代了自然的直觉命名(比如 `Todo` / `Ticket` / `Job`)。这个选择不是随手:「Task」比「Todo」多了一层「有明确执行主体」的含义 —— 一个 Todo 可以是「有空看看」,一个 Task 隐含「有人要做」。命名本身就在暗示 owner 字段的存在。

**动词后缀**是标准 CRUD 语义:Create / List / Get / Update —— Claude 望文生义就知道对应「建一条 / 列全部 / 拿一条 / 改一条」,和数据库表操作一模一样。看到这 4 个名字,Claude 脑子里立刻建立起「Task 是一个可枚举、可点选、可更新的实体集合」的心智模型。

**没有 Delete** —— 这是刻意的省略。硬删除通过 `TaskUpdate(status: "deleted")` 触发,而不是单独的 `TaskDelete` 工具。为什么?因为**删除是状态机的一个终点**,不是独立操作。这个设计让状态流转的入口全部收敛到 `TaskUpdate`,少一个工具 = 少一层决策负担。

**Stop / Output 的语义漂移** —— `TaskStop` / `TaskOutput` 复用了 Task 前缀,但操作对象不是待办任务,是运行中的后台进程(background bash / subagent)。这是家族命名里的一个 tension:同名不同意。设计者显然认为「统一在 Task 命名空间下比拆开更好」 —— 但这也是家族最容易让人困惑的地方。字段级描述里会反复强调这个区分。

**activeForm 是家族最具野心的字段命名**。它不叫 `presentContinuous` / `verbForm` / `spinnerLabel`,叫 `activeForm` —— 一个非常「文法」的词。这个词逼 Claude 在写这个字段时,脑子里想的不是「填个 UI label」,而是「把动词变成现在进行时」。命名把语法规则烙进了字段语义。

#### 2 · 工具级描述

Task 家族每个工具都有独立的 description。共通的语义定位是**协作契约**:6 个工具围绕同一份数据模型协作 —— 每个 tool description 的开头都在提醒 Claude「这是家族的一员,不是孤立工具」。

**TaskCreate 的开篇 · 阈值卡死**

> Use this tool proactively in these scenarios:
> - Complex multi-step tasks - When a task requires 3 or more distinct steps or actions

**「3 步以上才建 Task」**是明确的量化门槛。这条 prompt 训练 Claude 不要滥用 —— 单步小任务不该建 Task。这也是**用具体数字代替模糊形容词**的典型:不说「复杂任务」,说「3 步以上」。

**TaskCreate 的时机三段式**

> - After receiving new instructions - Immediately capture user requirements as tasks
> - When you start working on a task - Mark it as in_progress BEFORE beginning work
> - After completing a task - Mark it as completed and add any new follow-up tasks

时机很明确:**收到指令 → 建 · 开始做 → 标 in_progress · 完成 → 标 completed**。三个动作前后包夹每一段工作,不允许「悄悄开始」或「悄悄完成」。这是把「用 Task 追踪进度」从一次性动作,升级成**工作节拍**。

**TaskUpdate 的完成标准 · 特别严格**

> - ONLY mark a task as completed when you have FULLY accomplished it
> - If you encounter errors, blockers, or cannot finish, keep the task as in_progress
> - Never mark a task as completed if:
>   - Tests are failing
>   - Implementation is partial
>   - You encountered unresolved errors

不允许 Claude「差不多算完了」。测试没过 = 未完成。实现不完整 = 未完成。遇到未解决的错误 = 未完成。这条 prompt 防止一类特别糟糕的行为:**假性完成** —— Claude 觉得「大方向对了」就标 completed,结果留下一堆 half-done 的任务。

**TaskList 的调度直觉**

> Prefer working on tasks in ID order (lowest ID first) when multiple tasks are available

**默认按 ID 顺序**做任务。因为「早建的任务通常是后面任务的前置」 —— 这个约束让 Claude 的调度符合任务被建出来的直觉顺序,不东挑西拣。

**TaskUpdate 前的 staleness 提醒**

> Make sure to read a task's latest state using `TaskGet` before updating it.

**任务状态可能被别的 agent 改过** —— 尤其在多 Claude 协作时。TaskUpdate 之前先 TaskGet 拿最新状态,防止 stale write 覆盖别人的更新。这本质上是**乐观并发控制的直觉版本** —— 「先读再写」而不是「盲目更新」。

**TaskOutput 的废弃告示**

> DEPRECATED: Background tasks return their output file path in the tool result, and you receive a `<task-notification>` with the same path when the task completes.
> - For bash tasks: prefer using the Read tool on that output file path

工具 description 直接标 DEPRECATED · 并给出替代方案。这是**工具设计里少见的透明度** —— 不藏、不慢慢淘汰,直接告诉 Claude「这个别用了,用 Read」。

**reminder hook · 家族独有的 harness 层节拍**

Task 家族有一个**内置提醒机制** —— 如果 Claude 长时间没用 Task 相关工具,系统会插入一条 system reminder:

> The task tools haven't been used recently. If you're working on tasks that would benefit from tracking progress, consider using TaskCreate to add new tasks and TaskUpdate to update task status.

这条 reminder 是 harness 层帮 Claude 建立**「用 Task 家族追踪进度」的习惯**。就算 Claude 一时忘了,系统会提醒 —— 但结尾一句「Only use these if relevant to the current work」也说明**不是强制**,是提示。这个 hook 是 Task 家族独有的 —— 前 9 个工具都不需要 reminder,因为它们的用途在当下就用了;Task 家族要追踪进度,需要跨时间的 nudge。

#### 3 · 字段级描述

Task 对象的完整字段清单:

- **id** —— 系统生成的唯一 ID
- **subject** —— 短标题(祈使句,比如 "Run tests")
- **description** —— 详细描述
- **activeForm** —— 进行时形式(比如 "Running tests" · 用在 spinner 里)
- **status** —— pending / in_progress / completed(还有 deleted)
- **owner** —— 谁在做这个任务(agent name · 空表示没人认领)
- **blocks** —— 这个任务挡住哪些任务
- **blockedBy** —— 这个任务被哪些任务挡住
- **metadata** —— 自定义的键值对

字段多 · 挑 4 个关键设计点展开。

**subject / description / activeForm 的三重表达**

同一个任务用三种形式表达:
- **subject** —— 短标题(祈使句):"Run tests"
- **description** —— 详细描述:"跑单测 · 确认 auth 相关的 4 个测试都过"
- **activeForm** —— 进行时形式:"Running tests"

为什么要三种?**因为它们出现在不同 UI 位置**:
- List 视图显示 subject(短标题)
- Detail 视图显示 description(详情)
- Spinner 转的时候显示 activeForm(现在进行时,"Running tests..." 比 "Run tests" 更符合 UX)

这是「同一份数据的多形态呈现」 —— 让每个位置都有最合适的文本。**activeForm 的强制现在进行时**是这一层最独特的设计:它不是可选美化,是硬性要求 —— Claude 建任务时必须同时提供祈使句和进行时两个形式,不允许留空。语法规则烙进了字段契约。

**blocks / blockedBy 是双向依赖**

`blocks` 和 `blockedBy` 是**同一件事的两面**:

- A blocks B ⟺ B blockedBy A

Runtime 会自动维护双向一致性。Claude 只需要 addBlocks 或 addBlockedBy 其中一个方向,另一个方向自动同步。

这里字段命名的选择是**冗余表达优先于极简**。设计者本可以只留一个方向(比如只有 blockedBy),让另一个方向靠反查得到。但两个方向都作为 first-class 字段暴露,原因是**读语义不同**:「我挡住谁」和「我被谁挡住」在 Claude 的调度决策里是两种不同直觉,分开表达让 prompt 更自然。

**addBlocks / addBlockedBy 的增量 merge 语义** —— TaskUpdate 不接受 `blocks: [...]` 这种整体覆盖,只接受 `addBlocks: [...]` 这种增量追加。这个字段命名的细节防止一类事故:**Claude 想加一条依赖,结果把原来的全清空了**。增量语义让「加依赖」这个动作幂等且安全。

**status 枚举 · 线性状态机 + deleted 逃生舱**

状态流转:`pending → in_progress → completed`

不允许**倒退**(从 completed 回到 in_progress) —— 想重新做?建新任务。这个约束防止「任务反复横跳」的混乱状态,让进度可预测。

**特殊状态 `deleted`** —— 是硬删除入口 · 不是回退。用来清理误建的任务。deleted 不出现在正常的 List 视图里,但 runtime 保留记录,防止 ID 复用。这是**把删除也纳入状态机**的选择 —— 一个 Task 从生到死都是同一个 status 字段的取值变化,而不是「删除 = 从数据库消失」。

**blockedBy 保护** —— 一个任务如果 blockedBy 里还有未 completed 的依赖,**runtime 不允许把它变成 in_progress**(或者至少 prompt 里明确禁止)。这防止 Claude 一时兴起去做还没准备好的任务。状态机不是单个字段的转换,是**多字段联动的转换**:status 的变更受 blockedBy 的当前值约束。

**owner + metadata · 多 Claude 协作的两个开关**

`owner` 记录当前任务由**哪个 agent** 在做。这个字段是 Task 家族**支持多 Claude 协作**的关键:

- 主 Claude 建任务,owner 是空
- 主 Claude 派 subagent · subagent 认领,owner = subagent name
- 主 Claude TaskList 时能看到「哪些任务已经被认领了 · 哪些还空着可以派新的 subagent」
- 一个 subagent 完成后释放 owner · 主 Claude 可以再派另一个

这是**分布式任务队列**的基础模式,只不过队列消费者是多个 Claude 实例。

`metadata` 是一个自由 key-value 字段。Claude 可以在这里塞任何东西:相关的文件路径、参考链接、给 subagent 的补充上下文、临时笔记。这是**给未来扩展留的口子** —— tool 设计者没规定 metadata 该放什么,所以用户/agent 可以按需塞。owner 是家族核心契约,metadata 是家族逃生舱,一硬一软。

#### 4 · schema 校验规则

Task 家族的 schema 校验有几处硬拦截,其它都在 runtime 状态机里。

| 约束 | 层次 | 内容 |
|---|---|---|
| `activeForm` 必填 | schema | TaskCreate 不允许省略进行时形式 |
| `status` 枚举 | schema | 只能是 pending / in_progress / completed / deleted 四选一 |
| `subject` 长度 | schema | 短标题有 maxLength(具体值随版本变化) |
| 状态倒退 | runtime | completed → in_progress 被拒 |
| blockedBy 未空 → in_progress | runtime | 未解锁的任务不能被 claim |
| Read 之前 TaskUpdate | runtime | 强 recommend 但不硬拦(靠 prompt 训练) |

**schema 层与 runtime 层的分工** —— 参数结构、枚举取值这类**静态约束**放在 schema 里;状态机、依赖检查、并发保护这类**动态约束**放在 runtime。Edit / Read 是把「大部分约束都放 runtime」的极端;Task 家族则相对均衡:入口参数用 schema 兜、状态转换用 runtime 兜。

**降级到 Read 的透明度** —— TaskOutput 被 deprecated 后,「取输出」这个能力**没有替代工具**,而是**降级到已有原语**(Read tool 直接读 output 文件路径)。这是 Claude Code 工具设计的一个隐藏原则:**能被现有原语覆盖的能力,不做单独工具**。少一个工具 = 少一个 API 表面积 = 少一个决策负担。

---

### 小结

Task 家族的精妙之处,不在于「有个 todo list」这个功能本身,而在于它的信号分布**横跨 4 层且形成完整对偶闭环**:

- **命名** —— 6 个工具名 · CRUD 四件套 + Stop/Output 两个 runtime 控制 · `activeForm` 把语法规则烙进字段名 · 少了 `TaskDelete`(用 status=deleted 代替)、少了单独的 output 拉取(降级到 Read)
- **工具级描述** —— 每个工具独立 prompt 且互相引用 · 塞进 3 步阈值、时机三段式、假性完成禁令、staleness 提醒、废弃告示、reminder hook,把「协作契约」写进每份 description
- **字段级描述** —— 三重表达(subject / description / activeForm)对应 3 处 UI · 双向依赖(blocks / blockedBy)冗余表达优先于极简 · addBlocks 增量 merge 防覆盖 · owner 硬字段 + metadata 软逃生舱
- **schema 校验** —— 静态约束在 schema 层(activeForm 必填、status 枚举含 deleted)· 动态约束在 runtime 层(状态不倒退、blockedBy 未空拒 in_progress、多 Claude 场景下的 staleness)

Task 家族独特的地方在于它把 Claude Code 从「现在时」扩展到「未来时」:前 9 个工具都是「现在马上做一个动作」,Task 家族是「把要做的事外化到 runtime 存储 · 跨 tool call · 跨时间 · 跨 Claude 共享」。这个扩展不是加一个功能这么简单,而是把工作方式从「精神力对抗遗忘」变成「系统性对抗遗忘」 —— 遗忘不再是灾难,因为清单还在。

**核心洞察:对偶工具族形成闭环 · 累积状态有释放路径**。CRUD 四件套是一个完整的对偶(Create ↔ Update-deleted · List ↔ Get · 读 ↔ 写),不是「有创建没删除」这种半吊子;累积起来的 Task 状态必须有释放路径 —— 通过 status=deleted 走硬删除、通过 completed 走生命周期结束、通过 blockedBy 自动更新走间接释放。任务系统最怕的是「进得去出不来」的累积焦虑,Task 家族用 status 状态机保证了每条 Task 都有明确的终结姿势。

`activeForm` 强制现在进行时的设计,把「填个 label」的低要求提到「转换语法形式」的高要求,是所有字段设计里最有野心的一处 —— 它不是在收集数据,是在训练 Claude 用**正在做的口吻**看待任务,而不是**要做的口吻**。这个差别,是「已经开工」和「打算开工」的差别,是工作节拍的差别。
