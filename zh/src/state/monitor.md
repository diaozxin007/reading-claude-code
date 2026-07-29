Claude code tools 研究系列第十三篇。上一篇 [Cron 家族](cron-family.md) 讲了 Claude 如何**跨越时间**触发动作。但 Cron 是「时钟驱动」的:到点触发,不管外面发生了什么。

真实工程里有另一类等待场景:**「等某件事发生」**,但不知道确切时间点。比如:

- 「日志里出现 ERROR 就告诉我」—— 不知道什么时候出
- 「文件被改了就重新构建」—— 不知道什么时候改
- 「PR 状态变了就通知我」—— 不知道什么时候变
- 「CI 每个 check 落定就报一次」—— 不知道每个 check 落定的间隔

这类场景要的是**事件驱动的异步等待原语** —— Claude 布下一个「触角」,外部发生什么它自动感知。

这是 Monitor 存在的意义。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Monitor

Monitor 是 Claude Code 内置的**事件流监听工具**。它跟前两个「异步等待原语」形成三足鼎立:

| 工具 | 触发条件 | 语义 |
|---|---|---|
| **Bash `run_in_background`** | 单次任务完成 | 「告诉我 build 完了」 |
| **CronCreate** | 到某时刻 | 「9 点提醒我」 |
| **Monitor** | 事件流(每行 stdout 一个事件) | **「每次 X 发生就告诉我」** |

前两个是「等一件事」(点),Monitor 是**「等事件流」(线)** —— 有可能永远不停,直到 timeout 或 Claude 主动叫停。

### 作用

Monitor 解决的核心问题是「Claude 如何**持续感知外部世界的变化**」:

1. **突破单次通知** —— Bash background 只发一次完成通知,Monitor 每次事件都发
2. **事件流建模** —— stdout 的每一行 = 一个 notification,天然对齐 unix 哲学
3. **两种数据源** —— shell command **或** WebSocket 直连(极稀有的 tool 设计)
4. **filter 强制思考** —— 什么应该发?什么应该忽略?prompt 逼 Claude 想清楚
5. **持久监听** —— `persistent: true` 可以整个 session 都活着 · 用于 PR 监控 / 长日志追踪

它跟 Cron 家族的**根本区别**:

- **Cron** = 时钟驱动 · 到某时间点自动触发 · 时间是主动方
- **Monitor** = 事件驱动 · 外部发生动作才触发 · 事件是主动方

Cron 是「我到点问你」· Monitor 是「你有事叫我」 —— 一个 pull, 一个 push。

### 一个具体例子

**场景**:用户说 **「我这就跑一个 20 分钟的模型训练 · 你帮我盯着 log · 出错马上告诉我 · 有进度提示也顺便报一下」**。

这是一个典型的「**长时间运行 · 事件不定时发生**」任务。

#### 反例 1:纯 sleep 后看

```
Bash(command: "sleep 1200 && cat train.log", timeout: 1300000)
```

**问题**:20 分钟里出错了 Claude 根本不知道 · 等到最后才看已经晚了。**丢失早期信号**。

#### 反例 2:定时 poll

```
CronCreate(cron: "*/2 * * * *", recurring: true, prompt: "check train.log · 有 ERROR 报告")
```

**问题**:每 2 分钟 poll 一次 · 事件已经发生 1 分 59 秒才被感知 · **延迟高**。而且每次 poll 都要重新读全文件 · Cron 触发消费上下文。

#### 反例 3:Bash background 追 log

```
Bash(command: "tail -f train.log", run_in_background: true)
```

**问题**:一次 background 任务只在**完成时**通知一次 · 而 `tail -f` 永远不会自己结束 · 所以永远不通知 · **信号丢失**。

#### 用 Monitor 是怎么解决的

```
Monitor(
  command: "tail -f train.log | grep -E --line-buffered 'elapsed_steps=|Traceback|Error|FAILED|Killed|OOM'",
  description: "训练日志: 进度 + 错误",
  timeout_ms: 1500000
)
```

**运行时会发生什么**:

- Runtime 起 shell command · 让 `tail -f` 持续跟 log
- `grep` 只让匹配的行通过 stdout
- **stdout 的每一行 = 一个 notification** · 立即送到对话里
- Claude 该做什么做什么(可以跟用户对话、可以做别的)
- 每次匹配到 `elapsed_steps=1000` 类的进度或 `Traceback` 类的报错,Claude **自动收到通知**
- 20 分钟 timeout 后自动结束 · 或者用户想中断可以主动 stop

对用户来说,体验是:

```
[13:00] 用户: 帮我盯着 train.log
[13:00] Claude: 好 · 已经开始监听 · 出错或进度我都会及时报告
[13:03] Claude(自动通知): 进度 elapsed_steps=200
[13:07] Claude(自动通知): 进度 elapsed_steps=500
[13:12] Claude(自动通知): ❌ Traceback (most recent call last):
                          File "train.py", line 42, in <module>
                          OOM: CUDA out of memory
              → 训练在 elapsed_steps=800 时 OOM 崩了 · 建议减 batch_size
```

**关键洞察**:Monitor 让 Claude 从**「主动 poll」** 变成 **「被动接收」** · **每次外部事件发生都立即知道** · 不用轮询,不用等待,不占 context。

### 双数据源 —— 命令 or WebSocket

Monitor 有一个极其罕见的设计 —— **两种数据源二选一**:

**数据源 A · Shell command**

用得最多的模式,已在上一节展示。stdout 的每一行 = 一个事件。

**数据源 B · WebSocket**

```
Monitor(
  ws: { url: "wss://events.example.com/stream", protocols: ["v1"] },
  description: "订阅部署事件流",
  timeout_ms: 300000
)
```

**运行时会发生什么**:

- Runtime 直接开一个 WebSocket 连接
- 服务器每次 push 一个文本 frame = 一个事件
- 二进制 frame 会被标记成 `[binary frame, N bytes]`
- 连接关闭结束监听

**为什么专门做 WebSocket 支持?**

因为 `command: "websocat wss://..."` 也能做,但有一堆坑:
- 命令行 escape
- 单独进程开销
- 输出 buffering
- websocat 是不是装了

内置 WebSocket = 少一个进程 · 少一层 shell escape · 帧到事件的映射规范化。这是**「用 tool 消除脆弱性」的典型设计**。

这一条我认为是 Claude Code 工具生态里**「最超出预期的一条」** —— 一般 AI 工具设计不会想到把 WebSocket 内置成一等公民。这背后是设计者对「Claude 真的会用这个」的具体想象:agent-to-agent 通信、订阅式部署事件、长连接推送 —— 都会用 WebSocket。

### 触发条件

Monitor 官方 prompt 里给了非常明确的**选择指南**。整理一下:

**该用 Monitor 的场景**:

- **每次 X 发生都要通知**(不确定次数) —— 「每个 ERROR 都报」
- **每次 X 发生都要通知,直到某个已知终点** —— 「每个 CI check 报一次 · 全落定就停」
- **等一个 WebSocket 事件流** —— 服务器推送模式

**不该用 Monitor 的场景**:

- **只等一件事完成** —— 用 **Bash `run_in_background`** + 一个会 exit 的 `until` 循环
- **到某时刻触发** —— 用 **CronCreate**
- **秒级密集事件** —— rate limiting 会自动 stop · 需要更 selective 的 filter

一个**特别重要的坑**:tool prompt 里明确警告:

> Don't use an unbounded command for a single notification.

如果只想「build 完了通知我一次」· 用 `Bash run_in_background` + `until grep -q "Ready" dev.log; do sleep 0.5; done` —— 因为**这个循环会 exit** · 一次性通知。

**不要用** Monitor `tail -f log | grep -m 1 "Ready"` —— 因为 `tail -f` 匹配到 "Ready" 后不会自己 SIGPIPE · 会一直挂在那儿到 timeout。**Monitor 是为「持续」优化的 · 单次事件用错工具**。

### 技术实现

#### 1 · 命名

`Monitor`

一个中性名词概括工具职责。不叫 `Watch` / `Tail` / `Subscribe` / `Listen` —— 「Monitor」在 SRE 语境里天然带着**「持续观察 + 越过阈值报警」** 的含义,Claude 拿到这个词第一反应就是"布哨、看事件、有事叫我",不会误理解成"一次性 grep"或"读整个文件"。名字提前把「事件驱动」的心智锚定好了。

#### 2 · 工具级描述

Monitor 的描述围绕五件事:**通知选型 / 事件流建模 / 完备性(silence is not success)/ 输出音量 / 数据源偏好**。挑最有意思的看:

**开篇一句,奠定基调**

> Start a background monitor that streams events from a long-running script. Each stdout line is an event — you keep working and notifications arrive in the chat.

"streams events" + "each stdout line is an event" 两个短语就把 Monitor 的语义钉死:**这不是"命令完成时返回全部输出"的工具,是"事件流工具"**。stdout 的每一行 = 一个 notification 流入对话,这条设计让 Monitor 完全对齐 unix 哲学 —— 任何能产生 line-buffered 输出的命令 / 脚本(`tail -f` / `inotifywait -m` / while 轮询 / 自定义 Python)都能变成事件源。

**三选一场景分类 —— 从「通知次数」选工具**

> Pick by how many notifications you need:
> - **One** ("tell me when the server is ready / the build finishes") → use **Bash with `run_in_background`**
> - **One per occurrence, indefinitely** ("tell me every time an ERROR line appears") → Monitor with an unbounded command
> - **One per occurrence, until a known end** ("emit each CI step result, stop when the run completes") → Monitor with a command that emits lines and then exits

**开篇就把「怎么选工具」讲清楚**。三种通知需求 → 三种工具选择。这条 prompt 训练 Claude 从「通知次数」的角度思考等待原语,而不是「等多久」或「等什么」。

**反轮询原则 —— 单次通知不该用 Monitor**

> Don't use an unbounded command for a single notification. `tail -f`, `inotifywait -m`, and `while true` never exit on their own

如果只想「build 完了通知我一次」· 用 `Bash run_in_background` + `until grep -q "Ready" dev.log; do sleep 0.5; done` —— 因为**这个循环会 exit** · 一次性通知。

**不要用** Monitor `tail -f log | grep -m 1 "Ready"` —— 因为 `tail -f` 匹配到 "Ready" 后不会自己 SIGPIPE · 会一直挂到 timeout。Monitor 是为「持续」优化的 · 单次事件用错工具。

**Buffering 教科书 —— unix pipe 底层坑**

> Every pipe stage must flush per line or matches sit in its buffer unseen: `grep` needs `--line-buffered`, `awk` needs `fflush()`. `head` cannot flush at all — `| head -N` delivers nothing until N matches accumulate, then ends the stream.

这条 prompt 稀有到罕见 —— **它把 unix pipe buffering 的坑直接讲给 Claude**。因为 shell pipeline 默认按 block buffer(通常 4KB)· 而不是 line buffer。如果 Claude 天真写 `tail -f log | grep ERROR`,grep 会累积 4KB 才刷一次输出 · **事件延迟到 buffer 满** · 用户看到「Monitor 好像没在工作」。

正确姿势:
- `grep --line-buffered` → 每行立即刷
- `awk '{...; fflush()}'` → 每行显式 flush
- 避免 `head` · 因为它不能 flush,只在累积够 N 个才输出

**这些是老 sysadmin 的 tribal knowledge · 写进 tool prompt = 让 Claude 一开始就避坑**。可见设计者知道 Claude 不擅长这类底层细节 · 干脆写进 prompt:必须 `--line-buffered` / `fflush()` · 避免 `head`。

**silence is not success —— 观测完备性哲学**

> **Coverage — silence is not success.** When watching a job or process for an outcome, your filter must match every terminal state, not just the happy path. A monitor that greps only for the success marker stays silent through a crashloop, a hung process, or an unexpected exit — and silence looks identical to "still running." Before arming, ask: *if this process crashed right now, would my filter emit anything?* If not, widen it.

这条我认为是 Monitor prompt 里**最深刻的一条**。它不是关于「怎么用工具」· 是关于「怎么设计观测」。设计观测的核心不是「怎么看到好」· 是**「怎么不错过坏」**。

- 天真写法:`tail -f run.log | grep --line-buffered "elapsed_steps="` —— 只看进度信号
- 后果:如果任务 crash 了,没进度也没 crash 报告 · 用户以为「还在跑」
- 正确写法:`tail -f run.log | grep -E --line-buffered "elapsed_steps=|Traceback|Error|FAILED|assert|Killed|OOM"` —— **同时覆盖进度 + 失败信号**

原文里的**灵魂拷问** —— *"if this process crashed right now, would my filter emit anything?"* —— 直接把 SRE 的日常自省心智教给 Claude:每次 arm 一个 monitor 之前问自己一句 · 如果任务现在崩了 · 我的 filter 能不能报出来?这种运维直觉写进 tool prompt · 是把「一个高级工程师的思维习惯」显式教给 AI。

**输出音量控制 —— selective ≠ only good news**

> Every stdout line is a conversation message, so the filter should be selective — but selective means "the lines you'd act on," not "only good news."

**「selective 不等于 only good news」** —— 这条防止 Claude 把「选择性」误解成「过滤掉坏消息」。选的是「你会 act on 的行」· 不管是好是坏。跟上一段 silence 哲学互相印证。

**rate limiting 警告 —— 系统会主动 stop 高音量 monitor**

> Monitors that produce too many events are automatically stopped; restart with a tighter filter if this happens.

如果 Monitor 每秒输出 100 行(比如误配了没 filter 的 `tail -f verbose.log`),runtime 会自动 stop 这个 monitor · 因为对话会被淹没。Claude 收到「monitor was stopped due to high output rate」通知后,得**重写更 selective 的 filter**再重启。

这条 prompt 让 Claude 建立预期:失败 → 修 filter → 重试 · 而不是「怎么它自己停了」。这是**保护对话可读性的核心机制** —— 强制 Claude 写高质量 filter。

**200ms 批处理透明化 —— 多行事件保持整体**

> Stdout lines within 200ms are batched into a single notification, so multiline output from a single event groups naturally.

一个隐藏优化:200ms 内的连续 stdout 行会被合并成一个 notification。因为一个「事件」有时候多行(比如 Python Traceback 会一次输出 5-10 行)· 如果每行发一次 notification · 对话会被打散。200ms 窗口让「一次事件」保持整体呈现。

**告诉 Claude 有 batch 机制** —— 让 Claude 知道多行 Traceback 会作为一条消息进来 · 不用担心「一个事件被拆成 5 条」。

**命令 vs WS 的偏好 —— 内置 WebSocket 是一等公民**

> Prefer this [ws source] over `command: 'websocat wss://…'` — it avoids the extra process and line-buffering pitfalls.

**明确让 Claude 优先用内置 ws** · 不要用 websocat 命令行。理由讲清楚(少一个进程 · 少一层 shell escape · 少一层 buffering 坑)· 让 Claude 理解**「为什么」而不是死记「用哪个」**。

一般 AI 工具设计不会想到把 WebSocket 内置成一等公民。这背后是设计者对「Claude 真的会用这个」的具体想象:agent-to-agent 通信、订阅式部署事件、长连接推送 —— 都会用 WebSocket。这是**「用 tool 消除脆弱性」的典型设计**。

#### 3 · 字段级描述

Monitor 有 5 个字段:

- `command` —— shell 命令(数据源 A)
- `ws` —— WebSocket 配置(数据源 B,含 url + protocols)· 与 command 互斥
- `description` —— 描述(会出现在每次通知里)
- `timeout_ms` —— 超时(默认 300000 = 5 分钟 · 最长 3600000 = 1 小时)
- `persistent` —— 布尔 · true = 整个 session 都活着(忽略 timeout)

字段少,但每个背后都有非平凡的设计:

**command 与 ws 互斥 —— 双数据源二选一**

这是 Monitor 最独特的字段设计。Shell command 走 stdout · WebSocket 走 frame · 两者互斥但**语义完全对齐**:

- Shell command:stdout 每一行 = 一个事件
- WebSocket:每个文本 frame = 一个事件(即使 frame 内部多行,也算一次通知)

对 Claude 来说,只用记住一套心智模型 —— 「一个事件 = 一条通知」 —— 但可以接两种物理数据源。二进制 frame 会被规范化成 `[binary frame, N bytes]` 占位,不打断 stdout 语义。服务器关闭 / 错误 → 结束监听,close code 或错误信息会被报告。

**description 是每次通知的可见标签**

> Write a specific `description` — it appears in every notification ("errors in deploy.log" not "watching logs").

description 不是给 Claude 自己看的注释,是**每次通知里都要显示的标签**。所以命名要具体("训练日志: 进度 + 错误")而不是笼统("watching logs")· 让 Claude 收到通知时能一眼看出「这是谁发的」。

这是**「每个字段都有用户可见位置」的典型设计** —— 字段命名不能敷衍,因为它会在事件流里反复出现。

**timeout_ms 的硬上限**

默认 5 分钟 · 最长 1 小时。这个限制存在的价值是**防止 Claude 遗忘 monitor 挂着**。如果 Claude 起了个 monitor 然后就忘了,timeout 兜底,不会有僵尸监听。

超过 1 小时的场景必须显式 opt-in 到 `persistent: true`,把「我知道这是长期监听」这个意图交给 Claude 显式声明。

**persistent —— 会话级监听的一等公民入口**

```
Monitor(
  command: "...",
  persistent: true
)
```

`persistent: true` 忽略 timeout · 一直活到 session 结束或 TaskStop 手动叫停。用于长期监控:PR / issue 追踪 · 日志 tail · 服务器状态。**默认 false** 是**保守偏差** —— 长期监听是危险行为,需要 Claude 主动选择。

#### 4 · schema 校验规则

Monitor 的 schema 中等复杂 —— 关键约束都在 harness / runtime 层:

| 字段 | 类型 | 约束 |
|---|---|---|
| `command` | string | 与 `ws` 互斥 |
| `ws` | object | 与 `command` 互斥,含 url + protocols |
| `description` | string | 必填 |
| `timeout_ms` | number | 可选,默认 300000,最大 3600000 |
| `persistent` | boolean | 可选,默认 false |

真正的硬约束不在 schema,在 runtime:

1. **command / ws 二选一** —— 同时提供或都不提供都会报错
2. **description 必填** —— 因为通知里要显示,不允许留空
3. **timeout_ms 上限 3600000** —— 超过硬拒绝(不 persistent 时)
4. **Rate limiting 运行时拦截** —— 太多事件 → 自动 stop 并通知 Claude
5. **persistent + timeout_ms 语义** —— persistent=true 时 timeout_ms 被忽略,不冲突不报错

这些约束都是**loud fail 或 loud stop**:要么起不来(参数错),要么起来了但被明确终止(rate limit),不会静默继续导致「Monitor 看起来在跑但其实没在做事」的悬空状态。

---

### 小结

Monitor 的精妙之处,不在于它「让 AI 能持续监听」这个功能本身,而在于它的信号分布**极度偏向 tool 描述里的观测方法论**:

- **命名** —— 极简,一个 SRE 语境词
- **工具级描述** —— 极长,8 段约束覆盖通知选型 / 事件流建模 / buffering 教科书 / silence is not success / 输出音量 / rate limiting / 200ms 批处理 / 数据源偏好
- **字段级描述** —— 5 字段,每个背后都是非平凡决策(command/ws 互斥 · description 每次通知可见 · timeout_ms 硬上限防遗忘 · persistent 显式 opt-in)
- **schema 校验** —— 中等,真正的硬拦截在 runtime 层(command/ws 二选一 · description 必填 · timeout 上限 · rate limiting 主动 stop)

Monitor 独特的地方在于它**把「事件流工具的完备性」的重心从参数校验转移到了 prompt 教育**:schema 只锁基本形态,但 tool 描述里塞进了 unix pipe buffering 的老 sysadmin 直觉 + silence-is-not-success 的 SRE 观测哲学 + rate limiting 的对话保护策略。相当于把「Claude 布下一个可靠的事件监听哨」这个泛用能力,收敛成一个**事件驱动、失败可见、防对话淹没、支持两种数据源**的等待原语。

从更广的视角看,Monitor 补齐了 Claude Code 的**异步等待三足鼎立**:Bash `run_in_background` 等一次性完成 · CronCreate 等时刻触发 · Monitor 等事件流。前两个是「等一件事」(点),Monitor 是「等事件流」(线)。让 Claude 从「主动 poll」的执行者,变成「布下监听哨、外部动就报告」的观察员 —— 「等」终于变成一个 first-class 的动作。
