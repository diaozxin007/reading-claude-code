Claude code tools 研究系列第十四篇。前十三篇都是**「拆工具」** —— 逐个把 tool 掰开看内部设计。这一篇不一样,是系列第一篇**「专题篇」**:不拆某个工具,而是拆一套**跨越多个工具的正交能力** —— Background 机制。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开(以「命名 · 工具描述 · 字段描述 · schema」四个视角看跨 tool 的 background 机制)。

## 为什么专门讲 Background

细心的读者会发现:Claude Code 里**没有一个独立叫 `Background` 的 tool**。这不是遗漏 —— 是**设计选择**。

Background 相关能力**碎片化地散在多个工具里**:

| 位置 | 形态 |
|---|---|
| **Bash `run_in_background: true`** | 参数 |
| **Agent `run_in_background: true`** | 参数 |
| **Monitor** | 整个工具本身就是持续 background 监听 |
| **CronCreate** | 整个工具是「未来某刻 background 触发」 |
| **TaskStop** | 停止 background 任务的独立工具 |
| **TaskOutput** | 从 background 取输出(已废弃) |
| **`<task-notification>`** | background 完成时的通知消息 |

单拆任一个都只能看到局部。这一篇把它们放到**同一张图**里讲。

## Background 的本质:执行模式,不是行为

前十三个工具里,每个 tool 都有一个**核心行为**:

- Read 「读文件」
- Bash 「跑命令」
- Agent 「派 subagent」
- ...

**Background 不是行为 · 是模式**:

- 「跑命令」是行为 → Bash
- 「以后台方式跑」是执行模式 → `run_in_background: true` 参数

同一个行为(Bash / Agent)可以走**两种执行模式**:

- **同步模式**(默认):调用 → 阻塞等 → 拿结果 → 继续对话
- **后台模式** (`run_in_background: true`):调用 → 立即返回 task ID → 主 Claude 继续对话 → 后台任务完成时 harness 主动通知

如果 background 做成独立工具,就要有 `BackgroundBash` / `BackgroundAgent` / `BackgroundMonitor`...tool 数量翻倍,决策负担翻倍。

**用参数化代替工具化 —— 这是 Claude Code 里一个典型的「正交设计」**。跟 [Grep](../execution/grep-glob.md) 的 `output_mode` 三档、[Edit](../execution/edit.md) 的 `replace_all` 布尔是同一种思路:**行为固定 · 用参数切换执行模式**。

### 类比:操作系统里的 fork / wait

如果你熟悉 Unix 系统调用,这个设计有一个熟悉的影子:

- Unix 里 `fork()` 创建子进程 · `wait()` 等它完成
- Bash `run_in_background: true` 类似 fork · task ID 是 pid · `<task-notification>` 类似 SIGCHLD 通知父进程

**Claude Code 用 harness 层做了一个「Claude 视角的进程管理系统」** —— 只是子进程可能是 shell 进程 · 也可能是另一个 Claude · 也可能是 WebSocket 连接。

## 统一的 task ID 系统

不管起的是 background bash / background agent / cron job / monitor,harness 都用**同一套 task ID 机制**追踪:

```
Bash(command: "long-training.py", run_in_background: true)
    → 返回 task_id: "bh0u2kafo"

Agent(prompt: "...", run_in_background: true)
    → 返回 task_id: "ag_xxx..."

CronCreate(cron: "*/5 * * * *", recurring: true, prompt: "...")
    → 返回 job_id: "cron_..."

Monitor(command: "tail -f log | grep ERROR", persistent: true)
    → 返回 monitor_id: "..."
```

**所有 ID 都能被 TaskStop 停** —— 这就是**统一接口**。你不需要为每种 background 类型学一套 stop 机制。

具体差异只在**通知格式**上:

- Bash background 完成 → `<task-notification>` 带 output 文件路径
- Agent background 完成 → `<task-notification>` 带 agent 结果
- Cron 到点 → runtime 直接把 prompt 作为新一轮对话触发
- Monitor 每次事件 → 每行 stdout 变成一条 message 流入对话

**接口统一 · 语义按类型分化** —— 是好的 API 设计。

## 三种「后台任务」

按语义划分 · Claude Code 里有三种典型的 background 任务:

### 类型 A · 有明确终点的一次性任务

**代表**:Bash background · Agent background

**特征**:
- 起点明确 · 终点明确
- 任务完成时 harness 主动发 `<task-notification>`
- 主 Claude 不用问 · 到时候通知会自己到

**典型场景**:
- 长测试 / build / train
- 派 subagent 做调研
- 装个大依赖

**接口**:
```
Bash(command: "...", run_in_background: true) → task_id
    (对话继续 · 直到通知到达)
[<task-notification> task_id status: completed output: /tmp/.../out.log]
Read("/tmp/.../out.log") → 拿输出
```

### 类型 B · 到某时刻自动触发

**代表**:CronCreate

**特征**:
- 起点是调用 CronCreate
- 触发点是 cron 表达式指定的时刻
- 触发时 runtime 用**指定 prompt** 起新一轮对话(不是给已有对话发通知)

**典型场景**:
- 30 分钟后提醒
- 每 5 分钟看 CI
- 明天 9 点跑晨检

**接口**:
```
CronCreate(cron: "...", prompt: "...", recurring: false) → job_id
    (对话可以继续 · 或 session 结束)
[到点] runtime 用 prompt 触发新对话
```

跟类型 A 的关键差异:**类型 A 是「已开始的任务在跑」· 类型 B 是「未开始的任务在等触发」**。

### 类型 C · 持续 / 长期监听

**代表**:Monitor(尤其 `persistent: true`)

**特征**:
- 起点明确 · 终点未定(或者定在 timeout / 事件流结束 / Claude 手动叫停)
- 每次事件都发通知 · 不是一次性
- 数据源可以是 shell 命令 stdout · 也可以是 WebSocket 帧

**典型场景**:
- 追 log 里的 ERROR
- 监听文件系统变化
- 订阅 WebSocket 事件流
- PR 状态直到 merge

**接口**:
```
Monitor(command: "...", persistent: true) → monitor_id
    (每次事件流入对话)
[event 1] ... [event 2] ... [event 3] ...
    (直到 Claude 主动 TaskStop 或 session 结束)
```

### 三类对比

| 维度 | 类型 A · 一次任务 | 类型 B · 定时触发 | 类型 C · 持续监听 |
|---|---|---|---|
| 通知次数 | **1 次**(完成时) | **N 次**(每次 fire) | **不定次**(每次事件) |
| 起终关系 | 任务已开始 · 等结束 | 任务未开始 · 等触发 | 任务已开始 · 事件流不停 |
| 主要接口 | Bash / Agent + background | CronCreate | Monitor |
| 停止方式 | 通常自然结束 · 可 TaskStop | CronDelete | TaskStop |

## 反轮询原则

Background 机制的存在,让 Claude 应该建立一个**核心行为直觉**:

> **有 harness 通知就别 sleep · 有 background 就别同步等**

Anti-pattern 举例:

**反例 1:sleep 轮询等 background**

```
Bash(command: "long-task", run_in_background: true)
    → task_id
Bash(command: "sleep 60")
Bash(command: "cat /tmp/.../out.log")  # 手动 poll
```

**问题**:harness 会自动通知任务完成 · 你不用 sleep + cat · 直接等通知即可。

**正确做法**:

```
Bash(command: "long-task", run_in_background: true)
    → task_id · 主 Claude 干别的事
[等通知自然到] → Read 输出
```

**反例 2:sleep 等外部状态**

```
Bash(command: "curl -sf https://ci-status/build/42")
    → 未完成
Bash(command: "sleep 60")
Bash(command: "curl -sf https://ci-status/build/42")
    → 未完成
... 重复 8 次
```

**问题**:每次消费一次 tool call + 一次上下文 · 20 分钟就是 20 次浪费。

**正确做法**:
- 如果这个 curl 会 exit 表示完成 → 用 `Bash run_in_background` + `until` 循环
- 如果状态是流事件 → 用 Monitor
- 如果只是「到点看一次」→ 用 CronCreate

**反例 3:短 sleep 循环规避 harness 通知**

Claude Code prompt 里明确警告:

> Long leading `sleep` commands are blocked.

系统**主动阻止**长 sleep · 就是为了强制 Claude 用正确的 background 姿势。这是从 tool 层强制 Claude 学会异步思维。

## Task ID vs Job ID vs Task(待办)—— 命名困惑

这里有一个**Claude Code 里最容易搞混的命名冲突**。

三个名字都有「task」:

| 名字 | 属于哪套系统 | 语义 |
|---|---|---|
| **Task (TaskCreate / TaskList / ...)** | [Task 家族](task-family.md) | **待办事项**(concept) |
| **task_id / task-notification** | Background 机制 | **正在运行的后台任务**(instance) |
| **task_id 在 CronCreate 返回值里** | Cron 家族 | **定时 job 的 ID** |

**核心区分**:

- Task 家族的 Task = **概念上要做的事**(可能还没开始)
- Background 的 task = **实体上正在跑的任务**(bash / agent / monitor / cron)

TaskStop / TaskOutput 名字里有 "Task",但它们控制的是**后者**,不是前者。这是 Claude Code 里最令人困惑的命名 —— 上一篇 [Task 家族](task-family.md) 篇里已经点过,这里再次强调。

**记忆技巧**:

- Task**Create** / Task**List** / Task**Get** / Task**Update** —— 管**待办**(前 4 个动词都是 CRUD 感)
- Task**Stop** / Task**Output** —— 管**运行任务**(动词都是运行时控制感)

## 一个综合工作流的例子

**场景**:用户想同时启动 3 个动作 · 边做边聚合结果:

1. 后台跑一个完整测试套件(15 分钟)
2. 派 subagent 调研 auth 模块架构
3. 起 dev server 边改代码边观察日志

Claude 一次消息里同时:

```
Bash(
  command: "pnpm test:all",
  description: "跑完整测试套件",
  run_in_background: true,
  timeout: 900000
) → task_bh0test

Agent(
  description: "调研 auth 模块",
  prompt: "...",
  run_in_background: true
) → task_ag_auth

Bash(
  command: "pnpm dev",
  description: "起 dev server",
  run_in_background: true
) → task_bh0dev

Monitor(
  command: "tail -f /tmp/dev.log | grep -E --line-buffered 'error|warn'",
  description: "监听 dev server 错误"
) → monitor_dev
```

**运行时会发生什么**:

- 主 Claude 拿到 4 个 ID · 一个 message 里发出所有
- **一次 message 多 tool call = 并发** —— 3 个 Bash + 1 个 Agent + 1 个 Monitor 同时启动
- 主 Claude 继续跟用户对话 · 讨论重构方向
- **测试跑完 →** `<task-notification>` for task_bh0test · Read output 拿结果
- **subagent 调研完 →** `<task-notification>` for task_ag_auth · 拿报告
- **dev.log 出 error →** Monitor 立即推送一条 message · Claude 立刻感知
- **用户想终止 dev server →** `TaskStop(task_bh0dev)` 一句话搞定

**这就是 background 机制的完整威力**:主 Claude 用一次 message 铺开 4 个并发后台任务 · 之后一直处于「随时可对话 + 随时接通知」的状态 · 直到用户或 harness 触发下一次动作。

**跟传统 REPL 的对比**:

- 传统 REPL:一次 tool call · 阻塞等结果 · 拿到结果继续 → 4 个动作串行 15+ 分钟
- Claude Code + background:一次 message 铺 4 个 tool call · 并发跑 → 4 个动作并行 · 最长的那个决定总时间

**用参数换来的并发红利,是 Background 机制最直接的收益**。

## Background 机制的边界

Background 不是万能的。有几个明确的边界:

### 边界 1 · Session-only

跟 [Cron](cron-family.md) 的约束一样:**所有 background 任务只活在当前 session**。Claude 退出 = 任务被 kill · task ID 失效。

**含义**:不要用 background 做需要跨越几天的任务。用系统级 cron / launchd / GitHub Actions / 云 scheduler。

### 边界 2 · 通知有延迟(至下一次 idle)

`<task-notification>` **不会打断** Claude 正在处理的用户 prompt。**只在 REPL idle 时才送到**。所以:

- 如果 Claude 正在跟用户对话 · 通知会 queue 起来
- 直到对话轮次结束 · 下一次 idle 时通知才呈现
- 高频通知在忙 Claude 的场景可能会有小延迟

### 边界 3 · Rate limiting

Monitor 会自动 stop 高音量事件流(每秒几百行会挤爆对话)。Background 任务的 stdout 也有累积上限。**strong filter 是 first-class citizen** —— 不选择性输出的 background · 会被系统截断。

### 边界 4 · 并发上限

- Bash background · Agent background 有并发上限(通常 min(16, cpu-2))
- 超出上限的任务会被 queue 起来 · 等前面的完成再启动
- Workflow 里的 pipeline / parallel 也在这个上限里

### 边界 5 · Sandbox 依然生效

Background bash 依然在 sandbox 里跑 —— **不是绕过安全边界的手段**。dangerouslyDisableSandbox 才能突破 · 但那是另一回事。

## 4 层视角看 Background 机制

Background 不是单一 tool · 没有单一 prompt。但把它散布在多个工具里的信号按前置篇的 4 层拆开 · 依然能看清设计意图。**信号在这 4 层里分布得非常不均** —— 这本身就是 Background 机制的**特征**。

### 1 · 命名

Background 相关的命名信号,几乎全在「不做独立工具」这一决策上。

**参数化而非工具化**

Claude Code 没有 `BackgroundBash` / `BackgroundAgent` / `BackgroundMonitor` —— 有的只是一个布尔字段 `run_in_background`。这个命名选择本身就是一个隐式声明:**background 是执行模式 · 不是新行为**。字段级的一个 flag · 顶掉了整套并行的 tool 家族。

**TaskStop / TaskOutput 的动词统一**

停止 background bash 不叫 `BashStop`;停止 subagent 不叫 `AgentStop`;停止 monitor 不叫 `MonitorStop`。**统一叫 `TaskStop`**。这符合 Unix 的 `kill <pid>` 哲学 —— **不管你 fork 出来的是什么 · 一律用同一个动词收敛**。task_id 就是 pid 的等价物 · TaskStop 就是 kill。

**TaskOutput 的降级消失**

早期 API 里有 TaskOutput —— 从 background 显式取输出。现在被降级到"用 Read 读 output 文件"。命名层的信号变化非常直接:**能被现有原语(Read)覆盖的能力,不给单独动词**。这个减法在第十篇 [Task 家族](task-family.md) 里也点过。

**task_id 与待办 Task 的命名撞车**

这是 Claude Code 里**最容易混的命名**:Task 家族里的 Task = **待办事项**(概念),background 系统里的 task_id / `<task-notification>` = **正在运行的实例**(实体)。同一个词 · 两套系统。TaskStop 的 "Task" 属于后者 —— 它管的是运行实例 · 不是待办清单。

前面「Task ID vs Job ID vs Task(待办)」节展开过 · 不再重复。这里只标一点:**命名撞车是遗憾** · 但已经稳定 · Claude 靠上下文语义(动词是 CRUD 还是运行控制)区分。

**Cron / Monitor 是 background 的命名特化**

Cron 命名里没有 "background" · 但它本质是「background + 时钟触发」。Monitor 命名里也没有 "background" · 但它本质是「background + 事件流」。命名层保留了各自的语义辨识度 · 内部复用 task_id / TaskStop 基础设施。**基础 API + 特化 API 分层** —— 命名层对外分立、内部实现共享。

### 2 · 工具级描述

工具级描述里 · background 的相关信号高度**规范性** —— 不描述能力,描述**该怎么用**。

**反轮询原则**

Bash tool description 里明确写:

> Avoid unnecessary `sleep` commands: Do not sleep between commands that can run immediately — just run them. Use the Monitor tool to stream events... For one-shot "wait until done," use Bash with run_in_background instead.

**告诉 Claude:通知会自己到 · 别 sleep + cat 轮询**。这一条是全篇的核心行为直觉。

**长 sleep 硬阻断**

> Long leading `sleep` commands are blocked.

工具级描述直接**声明系统级拦截** —— 不是软劝导。Claude 想写长 sleep 也写不成 · 从物理层强制学会异步姿势。这跟 Edit 的「Read 前置 will error」是同一种设计:**把关键约束从建议升级到硬阻断**。

**Monitor 的 filter 优先**

Monitor description 里反复强调"strong filter is first-class citizen"、"never pipe raw logs"、"monitors that produce too many events are automatically stopped"。这是在告诉 Claude:background 事件流的**成本是对话上下文** · 不选择性输出会被系统截断。这条约束比"能不能跑"更微妙 —— **能跑但会被限流**。

**Cron 的 session-only 声明**

CronCreate description 明确:job 只活在 session 里 · Claude 退出即失效。这一条把 background 机制的**边界**写进单个工具的描述里 —— 让 Claude 每次考虑 CronCreate 都会读到"这不是系统级 cron"。跟 AskUserQuestion 把「和 plan mode 的时序关系」写进自己描述是同一种思路:**跨工具契约写进单个工具**。

### 3 · 字段级描述

字段级的信号集中在 `run_in_background` 参数本身,以及 `<task-notification>` 的返回结构。

**`run_in_background` 的默认值反差**

同一个字段名 · 在两个工具里默认值相反:

| 工具 | 默认 | 描述里的引导 |
|---|---|---|
| Bash | `false` | 「大部分 shell 任务是短的 · 默认同步简单」 |
| Agent | `true` | 「subagent 通常慢 · 默认 background 让主 Claude 不阻塞」 |

**默认值是设计意图的最显式表达** —— 反映了两个 tool 的典型使用场景。默认值这个层面的信号 · 比任何 prompt 都硬:Claude 不显式改就是这个值。

**Bash `run_in_background` 描述细节**

Bash 的字段描述里写:"Only use this if you don't need the result immediately and are OK being notified when the command completes later. You do not need to check the output right away — you'll be notified when it finishes. You do not need to use '&' at the end of the command when using this parameter."

这里同时干三件事:①声明前置条件(不急要结果)· ②声明后续保证(会通知)· ③禁止在 command 里加 `&`(避免双重 background)。**字段描述兼任 few-shot 反例**。

**Agent `run_in_background` 描述细节**

Agent 的字段描述里写:"Foreground vs background: Pass `run_in_background: false` to run an agent in the foreground when you need its results before you can proceed... Otherwise let it run in the background (the default) so you can keep working in parallel."

**跟 Bash 是镜像结构**:同一个字段名 · 一个说"什么时候要开 background"、一个说"什么时候不要开 background"。默认值不同 · 描述引导方向也就相反。

**`<task-notification>` 的输出契约**

background bash 完成时 · 通知带 `output` 文件路径。这个字段的设计 · 引导 Claude 用 Read 读输出 · 而不是找一个 "getOutput" API。**通过通知字段的结构本身 · 让 Claude 自然走 Read 路径** —— 这就是 TaskOutput 能被降级的原因。

**Monitor 的 `persistent` 字段**

`persistent: false` (默认) = 有 timeout 的一次监听;`persistent: true` = 无 timeout 的 session-长监听。用一个 boolean 区分「类型 A 事件流」和「类型 C 事件流」。字段的两个取值 · 对应两种完全不同的 background 语义。

### 4 · schema 校验

schema 层的信号很稀薄 —— 因为 background 更多是**语义模式**而非结构约束。但有几处硬约束值得点:

| 约束 | 位置 | 意图 |
|---|---|---|
| `timeout_ms` 上限 3600000 (1 小时) | Monitor 非 persistent 模式 | 阻止无节制的 background 监听 |
| `persistent: true` 与 `timeout_ms` 互斥 | Monitor | 语义清晰 · 二选一 |
| `run_in_background: true` + `&` 兼容处理 | Bash | 用户加 `&` 不额外产生 double-fork |
| cron 表达式格式校验 | CronCreate | 挡住语法错的定时表达式 |
| task_id 类型统一 | TaskStop | 各种 background 用同一个 stop 接口 |
| 并发上限 min(16, cpu-2) | runtime 层 | 保护主机资源 |
| Sandbox 默认生效 | 所有 background | background 不是绕过安全边界的手段 |

**schema 层最有意思的是「几乎没什么可校验的」** —— 因为 background 是**修饰**同步行为、不是**替代**。同步 tool call 已有的 schema(command / prompt / cron / ...)基本够用 · background 只加一个布尔或换一层触发条件。

**这也解释了为什么 Background 不需要独立工具**:如果它有独立 schema · 说明是新行为;它没有独立 schema · 说明是执行模式 —— schema 层的稀薄本身就是「参数化 vs 工具化」这个设计选择的证据。

## 小结

Background 机制的精妙之处 · 不在于「让 AI 能异步」这个功能本身,而在于它的**信号分布高度不均 · 却处处呼应「参数化而非工具化」这一核心选择**:

- **命名** —— 极简 · 没有独立 tool · 只有 `run_in_background` 字段 + 统一的 TaskStop 动词 · task_id 承担 pid 角色
- **工具级描述** —— 规范性 · Bash / Agent / Monitor / Cron 各自的描述里都塞了「反轮询」「filter 优先」「session-only」等跨工具行为契约
- **字段级描述** —— 反差最集中 · Bash 与 Agent 的 `run_in_background` 默认值相反 · 描述引导方向也镜像 · 是设计意图最显式的体现
- **schema 校验** —— 稀薄 · 因为 background 是修饰同步行为而非替代 · 硬约束只有 timeout 上限 / persistent 互斥 / 并发上限这几处兜底

**信号分布的稀薄本身就是证据** —— schema 越简单 · 说明「background 是执行模式而不是新行为」这个选择贯彻得越彻底。如果它像一个独立能力 · 就会长出独立的字段和校验;它没长出来 · 就说明它成功地寄生在了同步 API 的**默认值和 flag 里**。

**Background 机制在 Claude Code 生态里的位置**:

前 13 个 tool 是**空间原语**(在某个位置对某个东西做什么)。Background 机制是**时间原语的实现层** —— 让所有 tool 的执行都能从同步扩展到异步。

**没有 Background 机制,Claude Code 是「一次一动作的助手」;有了 Background 机制,Claude Code 是「多线程协作者」**。这个能力,让 Claude 真正能应对**「多个长任务并发 + 边做边聊 + 到点自动干活 + 事件驱动响应」** 的复杂工程场景。

从这个角度看,Background 不是「一个功能」—— 它是让所有工具**从『同步管道』升级为『异步协作系统』** 的隐形骨架。

---

## 与邻居工具的关系

Background 机制不是一个独立 tool,而是**跨 tool 的横切参数**。它跟前 13 个工具的关系不是「并列」,而是「贯穿」:

| 承载工具 | Background 表现 | 默认档位 | 主要作用 |
|---|---|---|---|
| **Bash** | `run_in_background: false` 默认 · 显式 opt-in | 前台阻塞 | 支持长任务不卡主循环 |
| **Agent** | `run_in_background: true` 默认 · 显式 opt-out | 后台异步 | subagent 常态就是长跑 |
| **Task 家族** | task_id 承载 pid 角色 · TaskStop / TaskOutput | N/A | 提供跨时状态和杀灭入口 |
| **Cron 家族** | 定时驱动 · 未来时唤醒 | 定时触发 | 时间原语 |
| **Monitor** | 事件驱动 · 事件流唤醒 | 事件触发 | 事件流原语 |

**"反轮询原则"是 Background 机制的中枢** —— 它同时约束了 Bash / Agent / Monitor 三个 tool 的使用方式:
- Bash 后台任务完成会通知 · **不要在 sleep 里 poll**
- Agent 后台任务完成会通知 · **不要用 CronCreate 定期查它**
- Monitor 流式事件到就通知 · **不要用 tail -f 一次事件后忘了停**

这条原则不写在任何单一 tool 的 description 里 · 只有把 background 作为**机制**来看才能理解为什么它贯穿所有 tool。这也是这一篇必须跨 tool 拆解的核心原因。

**Background 机制与同步机制的分工哲学**:
- 同步:一次调用 → 结果直接进 context,主循环用完就下一步
- 异步:一次调用 → 立即返回句柄,任务在后台跑 · 通知机制推送结果 → 结果通过 Read output 文件或 TaskOutput 拉回

前 13 个工具都是**默认同步**:Read / Edit / Write / Grep / Glob / WebFetch / WebSearch / AskUserQuestion / Enter/ExitPlanMode 全都是同步。这暗示 Claude Code 的**默认心智模式是同步**,异步是**特殊场景的显式选择**(除了 Agent 反过来 —— 那是因为 subagent 生命周期跟主循环解耦,同步反而违和)。

---

## 系列尾声

至此,Claude Code tools 研究系列完结。回望 14 篇的地图:

1. **前置篇** —— tool 是什么、Claude 怎么用
2-4. **交互原语三件套**(Ask / EnterPlanMode / ExitPlanMode) —— AI 和用户怎么对齐
5. **Grep + Glob** —— 定位
6. **Read** —— 感知
7-8. **Edit / Write** —— 精准 / 全量执行
9. **Bash** —— catch-all 兜底
10. **Agent** —— 派生 Claude
11. **Task 家族** —— 外化工作记忆
12. **WebFetch + WebSearch** —— 触达公网
13. **Cron 家族** —— 未来时间
14. **Monitor** —— 事件流
15. **Background 机制** —— 让所有 tool 从同步升级到异步

整个 tool 生态的骨架是这样搭起来的:**用户对齐 → 定位 → 感知 → 执行 → 兜底 → scaling(subagent / 时间 / 事件流)**。每一层都是「够用 + 安全 + 可组合」的原语,组合起来构成一个完整的协作系统。

15 篇不是为了穷举,而是为了让每一个 tool 都过一遍这套「4 层拆解」的解剖:命名 · 工具级描述 · 字段级描述 · schema 校验。**这个方法可以复用到任何 tool 系统的分析上** —— 不管是 MCP servers、别人写的 skills、或者你自己的下一个 agent 项目。

系列到这里全部拆完。整套沉淀,如果要一个字概括 Claude Code tools 的设计哲学:**克制** —— 每个工具只做一件小事,组合起来才构成协作系统。
