Claude code tools 研究系列第十二篇。前十一篇拆完了 Claude Code 的**空间维度工具集** —— 从本地文件系统到互联网 · 从单 Claude 到多 Claude · 从当下动作到待办清单。所有工具的时态本质上是**「同步」** —— Claude 调 tool,立刻执行,立刻返回。

但真实工程里有一类需求这套体系解决不了:

- 「30 分钟后提醒我 check 一下 CI」
- 「每 5 分钟看看部署好了没」
- 「明天早上 9 点跑一遍晨间自检」
- 「等一个小时后,重新审阅一下我的这份方案」

这些需求的共同点:**动作不是「现在做」· 是「未来某个时刻自动被触发」**。

这需要**时间原语**。Claude Code 的答案是 Cron 家族 —— 3 个工具(CronCreate / CronDelete / CronList)组成的定时调度系统。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Cron 家族(CronCreate / CronDelete / CronList)

跟第十篇 Task 家族一样,3 个工具语义高度耦合 · 共享同一数据模型(session 内的 cron jobs 列表) · 合并写更利落。

### 家族概览

| 工具 | 职责 |
|---|---|
| **CronCreate** | 创建一个未来触发的 prompt · 用标准 5 字段 cron 表达式 |
| **CronDelete** | 取消一个已调度的 job |
| **CronList** | 列出当前 session 里所有调度中的 jobs |

**「亲戚工具」**:除了 Cron 三件套,系列里还有一个相关的 **ScheduleWakeup** —— 专门给 `/loop` skill 的动态模式用,安排下一次自唤醒。它的定位是 Cron 家族的**特化版本**(为循环任务优化),这一篇顺带提一下。

**核心分工**:

- **CronCreate**(引擎)—— 90% 的调用集中在这里
- **CronList / CronDelete**(管理)—— 看进度、清理

跟 Task 家族最大的不同在于:**Task 家族记「待办的事」· Cron 家族安排「未来的动作」**。Task 是等 Claude 有空时来做 · Cron 是**到时间自动触发** —— 更主动、更精确。

### 作用

Cron 家族解决的核心问题是「Claude 如何**跨越时间**执行动作」:

1. **打破同步束缚** —— Claude 不再只能「有请求 → 回应」· 可以「安排一个未来的自我唤醒」
2. **精确调度** —— 用标准 cron 语法(`M H DoM Mon DoW`)· 灵活到任意时刻或任意周期
3. **一次性 / 重复两种模式** —— 用 `recurring` 布尔切换
4. **轻量提醒** —— 不用起 background task 就能实现「30 分钟后 remind」
5. **主动感知** —— 等外部状态时(CI / 部署)· 主动到点检查

它跟前面所有工具的关键差异:**这是唯一能「跨越时间」的工具家族**。

前十一个工具都是**「点」上的动作** —— tool call 触发就执行完毕。Cron 家族是**「线」上的调度** —— 在时间线上标一个点 · 到了自动引爆。

### 一个具体例子

**场景**:用户说 **「我刚推了个部署 · 大概 8 分钟出结果 · 你等好了帮我看下 CI 状态 · 有问题告诉我」**。

这是一个典型的**「等外部状态变化」** 任务。Claude 有几种做法:

#### 反例 1:纯 sleep

```
Bash(command: "sleep 480 && gh run list", timeout: 500000)
```

**问题**:主 Claude 被 sleep 阻塞 8 分钟 · 期间没法跟用户对话 · 用户想问别的都得等。**同步阻塞浪费了对话时间**。

#### 反例 2:每分钟循环 poll

```
while true:
    Bash(command: "gh run list")
    sleep 60
```

**问题**:每分钟消费一次上下文 · 8 分钟就是 8 次 · 主 Claude 的 context 被日志灌满 · **上下文浪费**。

#### 用 CronCreate 是怎么解决的

Claude 调 CronCreate,安排一次 **8 分钟后的一次性唤醒**:

```
CronCreate(
  cron: "13 22 29 7 *",           # 精确的时间 (7 月 29 日 22:13 一次)
  recurring: false,                 # 一次性
  prompt: "现在检查 CI 状态 · 用 gh run list · 如果失败告诉用户 · 成功就简短确认"
)
```

**运行时会发生什么**:

- Runtime 把这个 job 记下来(session 内存里)
- 主 Claude **立即回到用户** —— 不阻塞
- 用户可以问别的 · 让 Claude 干别的
- 到 22:13 · runtime 自动把 `prompt` 作为一次新的 Claude 调用触发
- Claude 拿到 prompt · 跑 `gh run list` · 汇报状态

对用户来说,体验是:

```
[22:05] 用户: 我刚推了部署 · 8 分钟后帮我看下 CI
[22:05] Claude: 好的 · 我已经安排 22:13 自动检查
              (你可以随便干点别的)
[22:05-22:12] 用户: (随便干别的 · Claude 有对话就答有对话就答)
[22:13] Claude(自动触发): CI 检查完毕 · 3 个 workflow 全绿 ✅
```

**关键洞察**:CronCreate 把「等待」从**主 Claude 的责任**变成**runtime 的责任**。主 Claude 完成安排就撤,不占对话时间也不占 context。

#### 组合用法:CronList 看进度 · CronDelete 提前取消

如果用户忽然说「算了不用等 CI 了 · 我自己看」,Claude 可以:

```
CronList()  # 拿到之前那个 job 的 ID
CronDelete(id: "cron_xxx")  # 取消
```

或者用户问「你安排了什么任务」· Claude CronList 一下就能答。

### 「主动」vs「被动」两种唤醒模式

Cron 家族有两种典型使用模式:

**一次性 (recurring: false)**

用于**已知时刻**的动作:
- 「明天 9 点提醒我 review 这份 PR」
- 「30 分钟后再看一次 CI」
- 「12:00 到点吃饭提醒」

Cron 表达式里 minute / hour / dom / month 都固定 · 到时间触发一次就消失。

**周期性 (recurring: true)**

用于**未知截止时间的监控**:
- 「每 5 分钟检查一次 CI · 直到我说停」
- 「每小时看一下队列长度」
- 「每天早上跑一遍晨间自检」

用 `*/5 * * * *` / `0 * * * *` / `0 9 * * *` 这类表达式。**注意 recurring 任务最多存活 7 天** · 到期自动最后一次触发后删除。这个上限是**防漂移设计**:防止 session 结束后 job 还在(实际上不会 · 见下文技术实现)· 也防止 job 无限存活占资源。

### 触发条件

**该用 Cron 的场景**:

- **等外部异步事件** —— CI / 部署 / 长任务
- **提醒 / 到点执行** —— 「X 时候做 Y」
- **周期性监控** —— 「每 N 分钟 check 一次 X」
- **对话已结束但想让 Claude 未来自己接手** —— 一次晨间自检

**不该用 Cron 的场景**:

- **秒级 / 亚秒级动作** —— cron 分辨率是分钟 · 太快用 sleep
- **需要精确响应外部事件** —— 用 Monitor tool(比 cron 更贴合「等某事发生」)
- **harness 已经会自动通知的等待** —— 比如 background bash / subagent 完成 harness 会通知 · 不用 poll
- **跨 session 的持久任务** —— **session-only!** cron job 不写盘 · Claude 一退出就没了

**跟其他等待原语的分工**:

| 需求 | 用什么 |
|---|---|
| 一次性事件通知(CI 完成) | **Bash `run_in_background`**(harness 自动通知) |
| 无固定时间点的事件监听(文件改动) | **Monitor** |
| 到点提醒 / 一次性延迟 | **CronCreate + recurring: false** |
| 周期性监控 | **CronCreate + recurring: true** |
| /loop skill 里的自唤醒 | **ScheduleWakeup**(特化版本) |

这张表很关键 —— **等待原语不止 Cron 一个** · Claude 应该按语义选。

### 技术实现

#### 1 · 命名

`CronCreate` / `CronDelete` / `CronList`

三件套是又一组**对偶闭环** —— Create 挂上、Delete 摘下、List 观察。定时任务的生命周期是「创建 → 存在 → 到期或被删」,需要「观察当前状态」和「主动取消」两个反向动作,所以 3 件而不是 2 件。

「Cron」这个词本身是借用 —— **不自造 DSL,直接沿用 Unix crontab 40 年的行业约定**。用户在自己的 Linux/macOS 终端里写过 `crontab -e` 就懂,不用再学一套语法。**复用行业约定、减少认知门槛**是这个命名的核心设计。同样 `List` 用复数而不是 `Get` · 暗示返回多条。

#### 2 · 工具级描述

Cron 家族的描述围绕六件事:**session-only 生命周期 / 7 天上限主动告知 / 负载分散(避开 :00 和 :30) / 何时反而应该用 :00/:30 / 不用 Cron 的场景 / 一次性 vs 循环的语言信号 / 本地时区语义 / 抖动机制透明**。

**Session-only 明示 · 生命周期开篇就说**

> Jobs live only in this Claude session — nothing is written to disk, and the job is gone when Claude exits.

**开篇就把重大约束说清楚** —— 让 Claude 不至于在 tool call 之后跟用户说「已安排每周一次」这种做不到的事。透明比华丽重要。这条约束背后是 Anthropic 的设计选择:持久 cron 要处理用户权限验证、错误处理、多 session 状态同步,复杂度爆炸。选**简化路径** —— cron 只是 session 内的定时器,用户能全权控制。代价是长期任务(几天几周)Cron 家族做不到,得靠系统级 cron / 云服务。

**7 天上限 · 主动告知用户**

> Recurring tasks auto-expire after 7 days — they fire one final time, then are deleted. This bounds session lifetime. Tell the user about the 7-day limit when scheduling recurring jobs.

**要求 Claude 主动告知用户** 7 天上限。不是被动回答问题,是**主动预告约束**。这是「诚实的默契」—— Claude 帮用户设时不能藏着掖着。7 天上限本身是**防遗忘设计**:用户可能建了个「每小时监控」然后忘了,这个上限保证不会永久占资源。一次性任务不受此限(反正只 fire 一次)。

**「负载分散」意识写进 prompt · 避开 :00 和 :30**

> Every user who asks for "9am" gets `0 9`, and every user who asks for "hourly" gets `0 *` — which means requests from across the planet land on the API at the same instant. When the user's request is approximate, pick a minute that is NOT 0 or 30

**这是把「系统级负载分散」写进 tool prompt 的稀有设计** —— 一般 tool 只关心 Claude 使用行为,不管服务器压力。Cron 例外,因为它是唯一一个可能造成用户不察觉的定期请求的 tool。所有用户对「9 点」的直觉都是「9:00」,所有请求都会挤在同一秒,Anthropic 后端会同时被打(负载尖峰)。让 Claude 自动挑一个偏移分钟(如 :57 或 :03),请求分散,后端稳定。

**明确解释理由** · 不只是「按这规则来」—— Claude 理解规则背后的意图,才能在边界情况下自行判断。

**何时反而应该用 :00 / :30 · 给出反例**

> Only use minute 0 or 30 when the user names that exact time and clearly means it ("at 9:00 sharp", "at half past", coordinating with a meeting). When in doubt, nudge a few minutes early or late — the user will not notice, and the fleet will.

**给出反例** —— 明确什么时候用 :00 是对的(用户明确要求或有会议对齐)。**避免 Claude 教条化**:规则有例外,exception 也写清楚。

**不用 Cron 的场景 · 指路 Monitor**

> Not for live watching. CronCreate re-runs a prompt at fixed wall-clock intervals. To watch a log file, process, or command output and be notified the moment something changes, use the Monitor tool instead — Monitor streams events as they happen; cron polls on a schedule.

**明确告诉 Claude 别拿 Cron 当 Monitor 用**。tool description 里直接指路兄弟 tool,而不是指望模型自己去比对多个工具。这也是「工具间协作契约写进单个工具描述里」的又一个例子。

**一次性任务的判断 · 从用户语言反推**

> For "remind me at X" or "at `<time>`, do Y" requests — fire once then auto-delete. Pin minute/hour/day-of-month/month to specific values

**给出 recurring: false 的具体触发信号** —— 「remind me at X」/「at `<time>`, do Y」这类语言是一次性场景。**从用户语言反推参数取值**,让 Claude 不用每次都问用户「你要一次还是循环」。

**本地时区语义 · 避免 UTC 换算**

> Uses standard 5-field cron in the user's local timezone: minute hour day-of-month month day-of-week. "0 9 * * *" means 9am local — no timezone conversion needed.

**明确本地时区语义**,避免 Claude 手动做 UTC 转换。这类「习惯误区」写进 prompt 是**从血泪教训里长出来的** —— 老一辈 sysadmin 都遇过时区搞错的坑。用起来跟用户在自己终端里写 crontab 一样直觉。

**抖动机制透明**

> The scheduler adds a small deterministic jitter on top of whatever you pick

**告诉 Claude 有 jitter** —— 让 Claude 别以为「我写了 :57 结果 :58 fire,是不是有 bug」。透明化让 Claude 建立合理预期。Jitter 具体规则:周期性任务实际触发最多延迟 10%(上限 15 分钟);一次性任务写在 :00 或 :30 时,自动提前最多 90 秒 fire。**又是负载分散** —— 就算 Claude 教条化选了 `0 9 * * *`,runtime 也会加抖动让请求分散。

**REPL idle 才触发 · 保护 Claude 不被打断**

> Jobs only fire while the REPL is idle (not mid-query).

如果 cron 到期时 Claude 正在处理另一个用户 prompt,触发会**延迟**到当前处理完。这防止 cron 和用户 prompt 撞车打断 Claude 思路。

#### 3 · 字段级描述

CronCreate 的字段清单:

- **`cron`** —— 5 字段表达式(local timezone):`"minute hour day-of-month month day-of-week"`
- **`prompt`** —— 到时间要触发的 prompt 内容
- **`recurring`** —— 布尔 · 默认 `true`(重复)· `false` 为一次性
- **`durable`** —— 遗留字段 · 无实际效果

CronDelete 只要一个 `id`(CronCreate 返回的);CronList 无入参。真正有意思的字段设计都在 CronCreate。

**几个关键设计点**:

**cron 用行业标准字符串 · 不自造 DSL**

`"0 9 * * *"` 表示每天 9 点 —— **直接沿用 Unix crontab 语法**,不发明新语法。这带来两个直接好处:一是用户看 Claude 输出直接懂,不需要再解释;二是 Claude 训练数据里已经有大量 cron 语法示例,不用再教。**复用行业约定,减少认知门槛**是这个字段的核心设计。反例设计会是自造一个 `{ minute: "*/5", hour: "*", ... }` 的 JSON 结构,看起来更「结构化」,但用户和模型都要重新学。

**`recurring` 默认 `true` 的价值取向**

默认 `true` 意味着「不写就是循环」—— 这个默认值有意导向**监控用途**。因为 Cron 家族典型场景就是 CI 监控、部署观察、周期性自检,这些都是循环。「一次性提醒」反而是要显式声明 `recurring: false` 的少数场景。默认值不是随手一挑,是**对典型用途的隐式偏好声明**。

**`durable` 遗留字段的诚实透明度**

tool description 明确写「durable has no effect」是**诚实的透明度**。这个字段是**历史痕迹** —— 早期可能试图做持久版本,后来撤了,但字段留下来避免 breaking change。**不删也不藏**,明确告诉 Claude「这个字段没用,不要浪费精力设置它」。

#### 4 · schema 校验规则

CronCreate 的 schema 层约束很稀薄,大部分约束在 runtime:

| 字段 | 类型 | 默认值 | schema 约束 |
|---|---|---|---|
| `cron` | string | 无(必填) | 5 字段格式 · 不做深校验 |
| `prompt` | string | 无(必填) | 无长度限制 |
| `recurring` | boolean | `true` | 布尔 |
| `durable` | boolean | 无 | 无(遗留) |

**真正的约束都在 runtime**:

- **7 天上限** —— runtime 定时到期自动删,不是 schema 层拦
- **REPL idle 触发** —— runtime 状态机,schema 表达不了
- **Jitter 分散** —— runtime 自动加 offset,schema 里的 `"0 9 * * *"` 到 runtime 会被自动 nudge
- **Session-only 生命周期** —— runtime 内存态,不是持久化行为

Cron 家族的关键特征:**schema 层几乎没有硬约束,行为主要靠 tool description 里的自然语言劝导 + runtime 机制兜底**。这跟 AskUserQuestion 那种「schema minItems / maxItems 硬拦截」的风格完全相反 —— 因为 cron 语法本身太灵活,`"7 * * * *"` 和 `"0 * * * *"` 都合法,靠 schema 分不出好坏,只能靠 description 教 Claude 挑好的。

### ScheduleWakeup —— 特化版本

CronCreate 是**通用**调度器。/loop skill 有自己特化的 `ScheduleWakeup`,专门给「动态间隔的循环」用:

- **调用者是 Claude 自己**,不是外部触发
- **循环上下文自动传** —— 上一次 /loop 的 prompt 会自动再次触发
- **有 5 分钟 prompt cache TTL 意识** —— tool description 教 Claude 如何在 cache 窗口内外做不同选择
- **建议 60-1200 秒**(1 分钟到 20 分钟)是主流

**跟 CronCreate 的分工**:通用调度用 CronCreate,/loop 里的自调度用 ScheduleWakeup。ScheduleWakeup 是「Cron 家族的循环特化亲戚」。

---

### 小结

Cron 家族最有意思的信号,是**「复用行业约定 · 减少认知门槛」这条主线在每一层都能看到**:

- **命名层**:直接借 Unix crontab 40 年的词,不发明新概念
- **字段层**:`cron` 字段用 5 字段字符串标准语法,不自造 JSON DSL
- **默认值层**:`recurring: true` 对齐典型监控用途 —— 一次性反而是要显式声明的少数
- **时区语义**:本地时区默认,避开 UTC 换算这个 sysadmin 世代都踩过的坑
- **schema 层**:反常地稀薄 —— 因为 cron 语法太灵活,`"7 * * * *"` 和 `"0 * * * *"` 都合法,靠 schema 分不出好坏

**另一条独有信号是「服务器视角写进 tool prompt」** —— 避免 `:00` 和 `:30` 这条约束,是把系统级负载分散的责任写到 Claude 使用行为里。一般 tool 只关心 Claude 使用是否正确,不管服务器压力,Cron 是稀有例外,因为它是唯一一个可能造成用户不察觉的定期请求的 tool。

**「诚实透明」也贯穿始终**:session-only 生命周期开篇就说、7 天上限要求 Claude 主动告知用户、`durable` 遗留字段明确写「no effect」、jitter 机制显式暴露。透明比华丽重要 —— Claude 承诺不了的事就说清楚,用户和 Claude 之间不留误解空间。

**对偶闭环的结构**跟第十篇 Task 家族一致:Create / Delete / List 三件套共享一份 session 状态,合并写更利落。真正有设计密度的都在 Create,Delete 和 List 是配套的观察 + 管理工具。
