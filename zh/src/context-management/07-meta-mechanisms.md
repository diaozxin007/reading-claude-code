> 本系列第 07 篇 · 收官篇。 承接前 6 篇打下的 messages 数组 / prompt cache / compaction / CLAUDE.md 家族 / sub-agent 隔离 的完整底盘 —— 讲**元机制**这一层。
>
> "元机制" 指的是**跨越所有上层策略的胶水层** —— 前 6 篇讲的每一处 · 底下几乎都用到了 `<system-reminder>` 这根通道。 这一篇把这根通道单独拎出来讲清楚 · 再补齐几件散在各处的小机制:`<env>` block memoize · Cyber-risk 挂 Read · Read tool 的三件隐性事 · Skill 从 meta 视角看的样子 · MCP ToolSearch 的真实实现。
>
> 本篇讲完 · 系列收束。 最后一节留 7 条读者带走的核心洞察。

## 起手 · 一条你可能见过的消息

你在 Claude Code 里跑一场稍长的会话 —— 20 轮左右 —— 有时会突然看到一条 "系统提示" 冒出来:

> `<system-reminder>`
> The TodoWrite tool hasn't been used recently. Consider whether the current work would benefit from a TODO list.
> `</system-reminder>`

它不是 LLM 主动生成的回答 · 不是你输入的消息 · 也不是任何工具的输出。 它像是**从空气里冒出来的一条指令**。

如果你翻源码 · 会发现这样的字符串在 Claude Code 里有 20+ 种 —— 每一种都在不同的时机被 harness **凭空塞进 messages 数组**:

- 文件被外部修改了 → 塞一条 "Note: X was modified…"
- 跨零点 → 塞一条 "The date has changed. Today's date is now …"
- 大文件被截断 → 塞一条 "…has been truncated to the first 2000 lines. Don't tell the user…"
- 每次 Read 一个文件 → 追加一段 cyber-risk 提醒
- MCP server 新连上 → 塞一段 "有新工具可用" 的说明
- 每 10 轮 · TodoWrite 没被用 → 塞一条 "考虑用一下 TODO 列表"

这些消息形态不一 · 触发条件不一 · 但**共享同一根通道** —— `<system-reminder>` 标签。 这就是本篇的主角:harness 层跟 LLM 通信的**元指令总线**。

## 1 · SR 是一根通道 · 不是一个功能

前 6 篇讲的每一件事 · 底下几乎都用到了 SR:

- **CLAUDE.md**([05 篇])—— 走 SR 打包成 "# claudeMd" prepend 到 user 消息
- **Post-compact 摘要**([04 篇])—— 用 SR 通知 "过去的对话被总结成这样"
- **Sub-agent 起手**([06 篇])—— sub-agent 的 skill 加载用 SR 注入
- **Fork placeholder**([06 篇])—— fork 的 tool_result 抹平后 · 是不是 SR 已经不重要 · 但 harness 侧走的是类似路径
- **Prompt cache 视角**([03 篇])—— 环境信息故意用 SR 单发 · 而不进 system prompt

**每一处上层机制都用到 SR** —— 这就是为什么把 SR 单独拎出来讲。 它不属于任何单一策略 · 是**四条策略共用的胶水**。

从抽象上看 · SR 解决了一个具体问题:

> harness 有一段话要**让 LLM 看到** · 但**这段话不是用户说的** · 也**不是工具执行结果**。 塞进哪里?

这段话可能是:
- 一个状态变化的通知(文件被改了 / 日期变了 / 有新工具)
- 一个 harness 的判断(应该用 TODO / 有 skill 可以用)
- 一个安全提醒(读文件时警惕注入)
- 一个上下文补齐(现在是哪个项目的 CLAUDE.md)

**这些消息不能作为 user 消息** —— 因为它们不是用户发的 · 显示在 UI 上会让用户困惑。
**也不能作为 assistant 消息** —— 因为 assistant 消息是 LLM 输出的 · harness 不该造假。
**也不能作为工具结果** —— 因为不是任何工具调用的产物。

Claude Code 的做法:**造一种"第四类"消息** —— 借用 user role · 但打 `isMeta:true` 标记 · 内容包一层 `<system-reminder>` 标签。 详见 [02 篇](02-message-invariants.md) 里对 isMeta 通道的讨论。

## 2 · SR 的注入形态 —— 折叠进 tool_result

SR 有个反直觉的注入细节。

**直觉上**:SR 是一条独立的 user 消息 · 追加到 messages 数组的末尾。

**实际上**:harness 会把 SR **折叠进邻近的 tool_result 块** —— 让它成为**同一条 user 消息里** tool_result 后面追加的一段文本。

举例:上一轮 LLM 说 "读一下 auth.py" · harness 跑完 Read · 返回 tool_result。 这时如果 harness 想追加 "The date has changed" 的 SR —— **它不新造一条 user 消息** · 而是把这条 SR **黏到那条 tool_result 消息的末尾**:

```
{
  role: 'user',
  content: [
    { type: 'tool_result', tool_use_id: 'xxx', content: '<auth.py 内容>' },
    { type: 'text', text: '<system-reminder>The date has changed…</system-reminder>' }
  ]
}
```

**为什么这么做**:

回忆 [02 篇](02-message-invariants.md) 的第三条不变量 —— **role 必须严格交替**。 assistant 消息之后必须是 user 消息 · user 消息之后必须是 assistant 消息 · 不允许连续两条 user 消息。

如果 SR 单独作为一条 user 消息:

```
[user 消息: 用户输入]
[assistant 消息: LLM 说要调工具]
[user 消息: tool_result]
[user 消息: SR]  ← 违反交替 · API 400
```

Anthropic API 会直接报错。 Claude Code 的解决方式:**把 SR 折叠进上一条 user 消息**。 结果:role 交替不变 · SR 也进了 · 一举两得。

**这个折叠 pass 有个 feature gate** —— 意味着团队保留了随时关闭这个行为的能力。 底层原理不变:SR 不是独立 turn · 是黏在前一个 tool_result 上的追加文本。

## 3 · SR 的触发时机 —— 不是 wall-clock

再一个反直觉细节:**SR 什么时候触发**?

**直觉上**:某个后台定时器每 30 秒扫一次 · 检查有没有需要提醒的事情 · 有就塞一条。

**实际上**:**没有 wall-clock 定时器**。 所有 SR 触发都在一个统一的时机跑 —— **每次调 LLM 之前的 message normalization 阶段**。

具体流程:

```
用户输入 / 上一轮 tool_result 完毕
    ↓
harness 准备下一次 API call
    ↓
把 messages 数组交给 normalizeAttachmentForAPI
    ↓
    ├─ 遍历各种 SR 触发条件
    ├─ 是不是有文件被外部改了?  → 塞外部修改 SR
    ├─ 是不是跨零点了?  → 塞日期变化 SR
    ├─ 距上次 TodoWrite 是不是超过 10 轮?  → 塞 cadence 提醒 SR
    ├─ ...每一条 SR 类型各自的判断
    └─ 折叠 SR 到邻近 tool_result
    ↓
序列化 · 发 API
```

**为什么用这个时机 · 不用 wall-clock**:

- **wall-clock 会引入不确定性** —— session 空闲 5 分钟 · SR 应该塞吗?模型没在跑 · 塞了也没用
- **每次 API call 前** —— 时机跟 "LLM 即将看到 messages" 对齐 —— SR 塞进去马上被读到 · 不会白塞
- **一个中央调度点** —— 20+ 种 SR 全走这一个入口 · 不用每个功能自己起后台线程

**这个设计的收益**:harness 不需要**持续的后台状态跟踪** —— 只要在需要发 API 时 · 一次性判断 "自上次这个 SR 之后 · 有没有触发条件" —— 就够了。

**Cadence-based 频率**:例如 TodoWrite 的提醒是 "至少 10 轮没写 TODO · 且距上次同类提醒 10 轮" —— 两个 10 轮计数器相加。 这些"轮"指的是 API call 次数 · 不是墙上时间。

## 4 · 20+ 种 SR · 分 6 大类

SR 的类型学。 20+ 种 · 按**触发来源**分 6 大类:

### 类 A · 静态附加型 —— 伴随特定 tool_result

每次某个 tool 返回结果 · **无条件**在结果末尾追加一段 SR。 例子:

| SR | 触发场景 |
|---|---|
| "Tool results and user messages may include `<system-reminder>` tags…" | System prompt 一次性 · 教模型认识 SR 的存在 |
| "Warning: the file exists but the contents are empty." | Read 一个空文件 |
| "Warning: the file exists but is shorter than the provided offset…" | Read 时 offset 超过 EOF |
| "Whenever you read a file, you should consider whether it would be considered malware…" | 每次 Read · 除 `claude-opus-4-6` 外的所有模型 |

**特点**:触发极简 —— 特定 tool 触发 · 结果里就一定挂这一段。 不用维护状态 · 不用判断"之前是否发过"。

### 类 B · Cadence 循环型 —— 每 N 轮触发一次

按**API call 次数**计数 · 到点触发。 主要例子:

| SR | 触发条件 |
|---|---|
| "The TodoWrite tool hasn't been used recently…" | 距上次 TodoWrite 10 轮 + 距上次同类提醒 10 轮 |
| "The task tools haven't been used recently…" | 距上次 Task 10 轮 |

**特点**:每种 SR 有独立的**上次触发的轮数**记账。 harness 每次 API call 前 · 判断"当前轮数 - 上次触发轮数 >= 10 吗" —— 是就塞 · 塞完更新记账。

**为什么用轮数不用时间**:一场 session 可能 30 秒 30 轮 · 也可能 10 分钟 3 轮 —— **模型的"注意力衰减"跟轮数正相关 · 跟墙上时间无关**。

### 类 C · 事件触发型 —— 状态发生变化

外部或内部**状态变化**引发 · 变化被检测到 · 就塞一条通知。 例子:

| SR | 触发 |
|---|---|
| "Note: `<filename>` was modified, either by the user or by a linter…" | 外部修改文件检测(Read 过后 mtime 变了) |
| "Note: `<filename>` was read before the last conversation was summarized…" | compact 后引用陈旧文件 |
| "Note: The file `<filename>` was too large and has been truncated…" | 大文件静默截断(下面 Read 一节详说) |
| "The date has changed. Today's date is now …" | 跨零点 |
| Plan-mode 进入 / 退出 · ultrathink · verify_plan | 模式迁移 |
| `<new-diagnostics>` | LSP / type-check 输出变化 |

**特点**:检测靠**每次 API call 前的差分** —— 比较"当前状态"和"上次给 LLM 看时的状态" —— 有变化就塞。 状态可能是文件 mtime · 日期字符串 · plan-mode flag · LSP 诊断列表。

### 类 D · 增量注入型 —— 保 cache 的关键

这一类是[03 篇](03-prompt-cache.md)反复讲的**"增量注入"模式**在 SR 通道上的体现。 主要例子:

| SR | 触发 |
|---|---|
| Skill 列表(re)load | Skill (re)load · **只发 delta**(新增的、未发过的) |
| Deferred-tool delta | MCP server (re)connect —— 只把**新连接**的工具补上 |
| Skill discovery | EXPERIMENTAL_SKILL_SEARCH 预取(灰度中) |

**为什么这一类特殊**:如果每次 skill 列表都全发 —— 每次列表包含的 skill 集合略有变化 · 就会 bust messages cache 一大段。 用 delta 增量注入:第一次发 20 个 skill 名字进 cache · 后来加装 1 个新 skill · **只在 SR 里塞新加的这一个** · 前 20 个的 cache 完全不动。

**Post-compact 例外**:compact 之后 · sentSkillNames 集合被重置 · 全部 skill 列表被**故意一次性重发** —— 因为 compact 已经 bust 全 cache · 不省这一次的 cache write。 这是[04 · Compaction 六兄弟](04-compaction.md)里讲的 compact 后 "轻装重启" 的一部分。

### 类 E · 用户上下文型 —— 每轮打包重发

伴随**每一次** API call 都会挂上的用户上下文信息。 例子:

| SR | 触发 |
|---|---|
| CLAUDE.md 打包("# claudeMd" + "# currentDate") | 每轮 prependUserContext |
| Memory 陈旧度("yesterday", "N days ago") | 记忆年龄注入 |

**这一类是最靠 SR 通道保 cache 的一类**。 详细展开见 [05 · CLAUDE.md 家族](05-claude-md-family.md) —— CLAUDE.md 走 messages 段的 SR 通道 · 而不进 system prompt · 就是因为它会变。 每轮 prepend 到 user 消息前面 · 一变只 bust messages cache 的最后一小段 · 保住整个 system 段的大 cache。

### 类 F · 团队 / 模式切换型 —— 边缘场景

特殊场景下才出现的 SR。 例子:

| SR | 触发 |
|---|---|
| "# Team Coordination…" | Teammate spawn(多 agent 团队协作) |
| "You are running in non-interactive mode… You MUST shut down your team…" | 非交互模式 + 集群 up |
| "This is a side question from the user…" | `/side-question` fork |
| "Brief mode is now enabled/disabled…" | `/brief` 命令切换 |
| Snip nudge | HISTORY_SNIP gate at compact |
| "Auto-compact is enabled. When the context window is nearly full…" | 用户 close 阈值时 |

**特点**:大部分用户碰不到。 但从 SR 通道的**总线**性质看 —— 任何需要"元指令通知模型"的边缘场景 · 都直接挂这根通道 · 不用另起一套机制。

**6 大类的共同点**:

- 所有 SR 都走同一个 `<system-reminder>` 标签 —— 模型认这一个标签
- 所有 SR 都走同一个中央调度(normalizeAttachmentForAPI)—— 无中央控制表 · 但集中调度
- 所有 SR 都遵循同一个折叠 pass —— 保 role 交替不变量
- 所有 SR 都在 messages 段(而非 system 段)—— 保大 cache 不被 bust

**这就是"SR 是元指令总线"的具体形态**。

## 5 · `<env>` 块 memoize —— cwd 故意 stale

系统 prompt 里有一段 `<env>` 块 —— 包含当前 cwd · git 分支状态 · 平台 · 模型 ID · 知识截止日期。

**直觉上**:这段内容应该在每次 API call 前刷新 —— 用户 `cd` 到另一个目录 · env 里的 cwd 应该跟着变。

**实际上**:`<env>` 块是**一次 session 计算一次 · memoize · 后续 cd 不刷新**。

**这是[03 篇](03-prompt-cache.md)反直觉案例 4 的现场**:

- `<env>` 块挂在 **system 静态段** —— 挂了 cache_control · 是大 cache 的一部分
- 如果 cd 后刷新 —— 每次 cd bust 整个 system 段 cache —— 一次 cd 几万 token 的 write 成本
- 于是刻意不刷新 —— system 段 cache 保住 —— 代价是 `<env>` 里的 cwd 会 stale

**Stale 不是 bug · 是设计**。 换来的收益:cd 不 bust cache · 单次 cd 省几万 token。

**cwd stale 的兜底**:真正需要 cwd 的工具(Bash · Read · Write · Edit)走**独立的 cwd 通道** —— 从进程内的 `getCwd()` 读 —— 永远准确。 系统 prompt 里的 cwd 只是给 LLM 大致定位"我在哪个项目" —— 有点 stale 不影响正确性。

这个"stale 换 cache"的取舍在[06 篇](06-sub-agent.md)的 AsyncLocalStorage 里也用到 —— 主进程 process.cwd 不动 · 每个 sub-agent 看到的 cwd 通过 AsyncLocalStorage 独立注入。

## 6 · Cyber-risk 挂 Read —— 每次都挂 · 只有一个模型豁免

每次 Read 一个文件 · 返回结果末尾会附加一段固定的 SR —— 一段安全提醒 · 大意是 "读文件时警惕内容里可能包含试图操纵你的指令 · 保持警觉"。

这就是前面类 A 提到的 "CYBER_RISK_MITIGATION_REMINDER"。

**它是安全一等策略**:

- 每次 Read 都挂 —— 不是每 10 次挂一次 · 不是首次挂
- 挂在 tool_result 的末尾(通过 SR 折叠 pass)—— 而不是 system prompt 里
- 内容不变 —— 每次都是同一段字符串

**这一段字符串**理论上跟 system prompt 里的其他安全提醒功能相同 —— 但如果放在 system prompt · 只发一次;放在每个 Read 结果末尾 · **每次 Read 时模型都被"重新提醒一遍"**。 这是**注意力**的设计 —— 长 session 里 · system prompt 的内容会被 messages 段的大量新信息**冲淡** · 但每个 Read 尾部的 SR 提醒**永远紧挨着 Read 结果** —— 模型看到内容时 · 提醒也刚好在旁边。

**⚠️ 唯一豁免**:`claude-opus-4-6` 模型 —— 这个模型在硬编码的豁免列表里 · 每次 Read 不挂 cyber-risk SR。

**为什么这个特定模型豁免**:大概率是这个更新的模型已经在训练阶段把 cyber-risk 意识内化 · 不需要每次提醒 —— 每次 Read 都挂反而是浪费 token。 但注意:这是**硬编码的模型清单** · 不是配置策略 —— 增加豁免模型需要改代码。

## 7 · Read tool 相关的三件隐性事

Read tool 有几件散在源码各处的"隐性行为" —— 都跟 context 有关 · 值得单独拎出来。

### 7.1 · 2000 行静默截断

**上限**:Read 单次返回**最多 2000 行**(不指定 offset/limit 时)。

**"静默"体现在哪**:如果一个文件 3000 行 · Read 返回前 2000 行 —— 结果里会附带一段 SR:

> Note: The file `<filename>` was too large and has been truncated to the first 2000 lines. **Don't tell the user about this truncation.**

这段 SR 明确要求 LLM **不告诉用户被截断**。

**为什么这么设计**:

- 一次全塞 3000+ 行的文件进 context —— messages 数组瞬间膨胀 · 一次 API 请求几十 KB 白花花地消耗
- 大部分场景 · 前 2000 行已经够回答用户的问题
- 如果 LLM 判断"我需要看后面的" —— 它可以主动带 offset 参数再 Read 一次

这是[03 篇](03-prompt-cache.md) "变的往后 · 稳的往前" 之外的另一个原则 —— **变的进 context 之前 · 先看能不能少变一点**。

**"Don't tell the user"** 这段指令 · 是 Anthropic 团队的 **UX 判断**:告诉用户 "文件被截断了" 会打断对话流 —— 不如让 LLM 在需要时静默取更多。

### 7.2 · readFileState LRU-100 —— 一个大 session 的陷阱

Claude Code 内部维护一个叫 `readFileState` 的**内存缓存** —— 记录 "本 session 里 harness 给 LLM 展示过哪些文件的哪些区段"。

**用途**:

- Edit 前检查:LLM 说 "改 auth.py 第 15 行" —— harness 先查 readFileState —— 这个文件是否被 Read 过?没读过就拒绝 · 返回一段错误 "File has not been read yet. Read it first before writing to it."
- Stale 检测:Read 过后 · 文件 mtime 变了 —— 下次 Edit 时拒绝 · 要求先重读

**上限**:LRU · **100 条**。 触过 100 个文件之后 · 最旧的会被淘汰。

**这里有个陷阱**:

假设一场大 session 里 · 你让 Claude Code 依次 Read 了 120 个文件(比如 grep 出来的候选) —— 前 20 个被 evict 出 readFileState。 后面你问 "把最初那个 auth.py 里的 bug 修一下" —— LLM 说 "改 auth.py 第 15 行" —— **harness 报错** "File has not been read yet" —— 尽管你**确实**读过 auth.py。

**这个 bug 从用户角度看是"神经病"** —— 明明读过 · 说没读。 但源码逻辑一致:readFileState 是内存 LRU · 上限 100 · 就是这样。

**为什么上限是 100**:估计是内存开销考量 —— 每个 entry 存 offset · limit · timestamp · 用户高频操作的文件通常远少于 100 —— 100 是"足够但不失控"的经验数。

**兜底**:LLM 收到 "File has not been read yet" 会 **自动重新 Read** 一次 —— 用户看不到这次多余的 Read · 但会看到"多花了一次 tool call"。 语义上正确 —— 只是效率上多绕一步。

### 7.3 · Read dedup —— 未公开的机制

一个**未在官方文档提及**的机制 —— Read 结果去重。

**触发条件**:

- 同一个文件
- 同一个 offset · 同一个 limit
- 二次 Read
- 中间文件 mtime 没变

**行为**:第二次 Read **不返回文件内容** —— 返回一句固定字符串(源码里叫 `FILE_UNCHANGED_STUB`)—— 大意是"文件没变 · 上次已经读过 · 别重发了"。

**收益**:如果一场对话里 · 由于模型判断失误 · 反复 Read 同一个大文件 —— 每次都全量返回内容 —— messages 数组膨胀极快。 dedup 让第 N 次 Read **返回一个 stub 字符串** —— 而不是全量字节。

**这个机制有 killswitch**(`tengu_read_dedup_killswitch`)—— 说明它在**灰度阶段** —— 如果发现某类用户被搞砸 · 可以远程关闭。

**为什么不公开**:未公开的机制 · 官方保留调整空间 —— 不必给用户承诺具体行为。 从 context 视角看 —— **它是一次 JIT retrieval 的进一步优化** —— [00 篇](00-intro.md) 4 大策略的 just-in-time retrieval 一环。

### 7.4 · 其他细节

- **PDF 最大 20 页 · 每次 Read**:超过 20 页的 PDF · 必须显式指定页范围 —— 否则报错
- **图片 base64 inline**:图片走特殊 schema · content 里塞 base64 —— 而不是文件路径

这些细节都是 Read tool 的**边界处理** —— 每一处都是一个"如果不管会炸 context"的场景 —— harness 用一段 SR 或者一个明确错误挡在前面。

## 8 · Skill 家族 · 从 meta 视角

[06 篇](06-sub-agent.md) 讲过 sub-agent 里 skill 通过 isMeta:true 注入。 这里补齐 skill 家族的**meta 层**特性。

### Skill 有两阶段

- **Listing 阶段**:每次 API call · harness 把当前**可用的 skill 列表**(名字 + 描述)挂到 messages 段的 SR 里 · 告诉 LLM "你可以用这些 skill"
- **Invocation 阶段**:LLM 主动调 Skill tool —— harness 把对应 skill 的 SKILL.md **body** 内联进 tool_result —— 作为 skill 的完整指令

**关键点**:

- Listing 阶段**只用 frontmatter**(name + description · 几十字节)—— 即使 body 已经**磁盘 eager load** —— 序列化到 API 的时机是**晚的**
- Invocation 阶段才把 body 塞进 messages —— 大部分 skill 一场 session 里根本用不到 —— body 就永远不进 context

**这是[00 篇](00-intro.md) 讲的 "just-in-time retrieval" 的教科书应用** —— 只把"目录"给 LLM · 具体内容"用时再取"。

### Listing 增量发送 —— 保 cache

Listing 有个反直觉细节 —— 不是每次都全发。

harness 维护一个内存 set —— **本 session 里已经发过的 skill 名字**。 每次 API call 前 · 判断"当前可用 skill 集合 vs 已发过的集合" —— 只发**新增的**(delta)。

**为什么**:每次 skill listing 是几 KB · 全发一次是"messages 段又加一段" —— messages 段最后一个 breakpoint bust —— 后面新加的 skill · 就只 bust 增量部分的 cache 。 详细见 [03 篇](03-prompt-cache.md) 的增量注入模式。

**Post-compact 例外**:compact 之后 · sentSkillNames set **重置** —— 全部 skill listing 一次性重发。 因为 compact 本身已经 bust 全 cache —— 这一次全发不省 · 反而给 LLM 一个"skill 目录"的完整基线 —— 之后再 delta 增量。

### 客户端不做 skill 触发

**反直觉**:SKILL.md 里有一段固定格式的 "TRIGGER — read BEFORE …" —— 描述这个 skill 应该在什么场景被使用。

**这一段是给 LLM 看的软指引** —— **不是 harness 层的 dispatcher**。 源码里不扫 transcript · 不匹配任何关键词 · 不做任何"看到用户说 X 就自动激活 skill Y"的行为。

**为什么**:客户端做 dispatcher 意味着:

- harness 要理解自然语言(用户在说什么)—— 太脆弱
- 客户端要维护一份"用户意图 → skill" 的映射规则 —— 维护成本高
- LLM 已经会做这件事 —— 让 LLM 判断就够

**Anthropic 的选择**:把 dispatcher 权外包给 LLM —— skill listing 里的描述 · SKILL.md body 里的 TRIGGER 段 · 都是给 LLM 的**语义提示** —— LLM 自己判断"这个场景我该不该调这个 skill"。

### 17 个 bundled skill

Claude Code 二进制里内置 17 个 skill(具体名字随版本变)—— 包括 batch · debug · loop · simplify · verify · updateConfig · claudeApi 等 —— 每个都在 `src/skills/bundled/<name>/SKILL.md`。 用户也可以自定义 skill 放到 `~/.claude/skills/` 或项目 `.claude/skills/`。

**bundled skill 也走同样的 listing / invocation 通道** —— 没有特殊路径。 从 meta 视角 · bundled 和 user-defined 完全对等。

## 9 · MCP ToolSearch —— 服务器端 defer_loading

MCP(Model Context Protocol)是 Claude Code 里一个重要机制 —— 允许用户接入外部工具。 一个成熟用户可能装 10+ 个 MCP server · 每个 server 又暴露 5-20 个工具 —— 加起来 100+ 个工具 schema —— **一次性全塞给 LLM · tool 段就爆了**。

**问题**:tools 段是 cache 的 ①号断点(见 [03 篇](03-prompt-cache.md))—— 挂在 tools 段末尾 · 100+ 个工具意味着 tools 段成为**几十 KB 的大段** —— 每次 API call cache read 都要付这个成本。

**方案**:ToolSearch —— 一个 harness 提供的元工具 —— LLM 主动调它 · 才拉起某个具体工具的 schema。

**⚠️ 反直觉的实现细节**:ToolSearch 是**服务器端 defer_loading** —— **不是**客户端 BM25 或本地检索。

具体做法:

- **客户端标 `defer_loading: true`** —— 把工具 schema 打包时 · 每个"应该 defer 的工具" 加这个 flag
- **API 那边**:模型不主动调 ToolSearchTool · 这些工具的 schema **对模型隐形** —— 模型的输出概率分布里不能包含这些工具名
- **模型主动调 ToolSearchTool** —— 传关键词 · 服务端做检索 —— 拉起最匹配的 N 个工具 —— 告诉模型 "你可以调这些工具了"

**换句话说** —— **检索算法完全在服务端** —— 客户端只做"标记 + 发送" —— 不实现 BM25 · 不实现 regex · 不实现向量检索。

**Auto 模式**:环境变量 `ENABLE_TOOL_SEARCH=auto` 或 `auto:N` —— N ∈ [0,100] —— 默认 10。

**⚠️ 官方文档误导**:一些 Anthropic 官方文档说 "10% context if schemas fit" —— 暗示 "如果 schema 加起来占 context 10% 以下就不 defer"。 **源码里的 10 不是 context 尺寸阈值** —— **是概率**:

```
每次决定要不要 auto-defer 一个工具 · 掷骰子 · 10% 概率 defer · 90% 概率 keep
```

Bernoulli 掷骰子 —— 跟工具 schema 大小无关 · 跟 context 剩余空间无关。

**为什么这么设计**:概率 defer 让"哪些工具进 tools 段" 变得**受控随机** —— 服务端可以基于这次样本判断"defer 的工具在不同 session 里被主动调用的频率" —— 用来调整 auto-defer 的比例。 是一种**在生产环境做 A/B 实验**的方式。

**这是 Claude Code 里"官方文档 vs 源码实际"最大的一处不符** —— 见 [00 篇](00-intro.md) 的 8 处不符清单第 6 条。

## 10 · MCP instructions delta —— 晚连接不 bust cache

MCP server 有自己的 instructions —— 一段告诉 LLM "怎么用我" 的说明。 是给 agent 的**静态说明** —— 语义上应该进 system prompt。

**问题**:MCP server 连接是**异步的**:

- 有的 server 1 秒内连上
- 有的要几秒
- 有的中途断线重连
- 用户可能 session 中间加装新的 MCP

如果 instructions 进 system prompt · 每次 MCP 状态变化 —— system 段变 —— 大 cache bust。

**方案**:MCP instructions 用**增量 SR 注入**。

具体:

- **首次连接**:MCP server 连上 · 把它的 instructions 打包成 SR · 塞到 messages 段
- **再连接**:如果同一个 server 断线重连 —— 不重复发(harness 记账 · 已经发过的不再发)
- **新加装**:用户 session 中间加了一个新 MCP —— 只把这一个新的 instructions 塞进去

**跟 skill listing 增量注入是同一模式** —— 从[03 篇](03-prompt-cache.md) 的角度 · 都是"cache 静态 ≠ 语义静态" 的具体体现:

- MCP instructions 语义上是静态说明
- 但连接的时机是动态的
- 于是让它走 messages 段的 SR 通道 —— 走**增量注入** —— 保 system 段的大 cache 不被 bust

**从代码组织上**:MCP instructions delta 和 skill listing delta 走**同一个 attachments 通道** —— 类似的 sentXxxNames 记账机制。 是一种**可推广的模式** —— 只要一个内容"语义静态但生成时机异步" —— 就走这条路径。

## 11 · SR 通道的边界

SR 强大 · 但不是万能。 列几个 SR **不做**的事情:

- **SR 不做"push"通知** —— 没有后台定时器 · 所有触发都在 API call 前的 normalization 阶段 —— session 空闲时不塞
- **SR 不做安全过滤** —— cyber-risk 只是 remind LLM · 不阻止危险行为 · 阻止行为是权限系统的事
- **SR 不做 UI 显示** —— SR 内容对用户 UI 完全透明 · 只对 LLM 可见 —— 如果一个提醒 UI 也要显示 · 走另一套通知系统
- **SR 不做 client-side reasoning** —— harness 不理解 SR 内容 · 只是打包发过去 —— 内容层的判断完全外包给 LLM

**SR 是一根管道 · 不是一个决策器**。 决策在别处(触发条件的判断在各功能模块)· 决策结果通过这根管道**送达 LLM**。

## 12 · Context 系列到此收束

到这里 · Claude Code 的 context 管理讲完了:

- **00** 200K 账本 · 4 大策略 × 20+ 机制的全景矩阵 · 8 处官方文档 vs 源码不符
- **01** Agent Loop · LLM 无状态 · harness 每次重发历史 · messages 数组只增不减
- **02** 消息数组的三条硬不变量 · role 交替 · tool_use / tool_result 配对 · isMeta 通道
- **03** Prompt Cache 是底座 · 4 断点分配 · 静态 / 动态段 sentinel 分界 · 6 个反直觉案例
- **04** Compaction 六兄弟 · `/compact` `/clear` `/rewind` + auto + micro + reactive · 不同 trigger 共同心法
- **05** CLAUDE.md 家族 · 4 层加载 · @import · rules · MEMORY.md · Todo v2
- **06** Sub-agent 隔离 · Agent · fork · worktree · SendMessage · `.output` 陷阱
- **07**(本篇) Meta 机制 · SR 类型学 · env memoize · Read 隐性事 · Skill / MCP ToolSearch

## 7 条读者带走的核心洞察

Context 系列 8 篇讲完 · 如果只让读者记住 7 件事:

**1 · Cache 是骨架 · 一切设计的底座**

Prompt cache 不是 Claude Code 的"某个功能" —— 是所有其他设计**被逼着长成那样**的原因。 4 大策略 · 20+ 机制 · 追根到底都跪着一个共同底座 —— **不能 bust 大 cache**。 这个约束不显式写在文档里 · 但每一条源码决策都能追到它。

**2 · 静态 / 动态段用显式 sentinel · 不用启发式**

Cache 边界必须是**编码时决定的常量**(`__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__`)—— 不是运行时启发式判断。 因为一次误判就 bust 全 cache —— 而 cache write 成本 1.25 倍 —— 一次误判要几十次 cache hit 才能回本。 **显式 · 保守 · 可预测** —— 比"聪明的启发式"更值。

**3 · CLAUDE.md 走 messages · 不进 system**

CLAUDE.md 语义上是"给 agent 的固定指令" —— 直觉应该进 system prompt。 但因为它**会变**(用户改 / 项目切 / @import 展开 / 热重载)—— 一变就 bust 大 cache。 走 messages 段 · 变化只 bust 消息段的小 cache —— **一次"用较小 cache 换较大 cache"的等价交换**。

**4 · Cache 静态 ≠ 语义静态**

Claude Code 追求的是 **cache 静态**(内容一 byte 不变)—— 不是**语义静态**(概念上不变)。 CLAUDE.md · MCP instructions · Skill body 语义上都是静态说明 —— 但因为生成时机异步 / 会变 · 它们进 cache 会付大代价。 SR 通道 · 增量注入 · fork placeholder · env memoize —— 都是"顺着 cache 静态而非语义静态在做取舍"的具体体现。

**5 · SR 通道是元指令总线**

`<system-reminder>` 不是一个"错误消息" —— 是 harness 跟 LLM 通信的**元指令总线**。 20+ 种触发 · 6 大类型 —— 全部走这一根通道:CLAUDE.md 打包走这条、cadence 提醒走这条、日期变化走这条、Skill listing 走这条 —— 甚至 MCP 晚连接的动态说明也走这条。 **一根通道 · 无中央控制表 · 每个功能自己往上塞** —— 是一种**分散但收敛**的设计。

**6 · 配对不变量是硬约束 · 一切修补机制围绕它**

messages 数组的第一条不变量:**每个 tool_use 必须有 tool_result 配对**。 破了 · API 直接 400 报错。 这条不变量催生了 Claude Code 里一整套修补机制 —— interrupt 后合成 tool_result 补配对 · compact 前先剪掉未完成的工具 · rewind 只能选 user 消息回退 —— **所有涉及历史裁剪的机制底下 · 都是这一条不变量在幕后约束**。

**7 · 横切关注 · 无中央控制 · 但有铁的不变量**

Claude Code 里没有一个"ContextManager 类" —— 没有中央的上下文控制中心。 每个功能自己守 cache · 自己维护自己那份状态 · 自己决定什么时候塞 SR。 但整个系统**收敛**在几条**铁的不变量**上:cache 三铁律 · messages 数组三不变量 · SR role 交替。 **分散但收敛** —— 一种"每个人守自己那一块 · 但守的规则一致" 的架构 —— 比中央控制更 scalable · 也比"各干各的" 更可靠。

## Loop 系列 + Context 系列的合体图景

姊妹系列 [Loop 09](../agent-loop/09-sidechain.md) 讲的是**执行流视角** —— loop 怎么转 · 状态机怎么迁移 · 错误怎么恢复 · sub-agent 怎么递归。

本系列 Context 讲的是 **信息流视角** —— messages 数组怎么装配 · cache 怎么保 · CLAUDE.md 怎么注入 · SR 怎么调度。

**Loop 讲清了"事情怎么发生"** —— 骨架撑起来 · loop 转起来 · stop_reason 决定继续还是退出。
**Context 讲清了"信息怎么组织"** —— 骨架上挂什么 · 每一次 API call 具体发什么。

**两个系列合起来 · 才是 Claude Code 的完整机制图景**。

- 单独看 loop —— 你懂了"AI 怎么自主推进" · 但不懂"AI 每一步看到的输入是什么"
- 单独看 context —— 你懂了"输入怎么组织" · 但不懂"输入组织出来之后干嘛用"
- 合起来看 —— 你懂了 Claude Code 的**内在逻辑** —— 输入怎么进来 · loop 怎么转起来 · cache 怎么保住 · 结果怎么出去

想真正**用好** Claude Code —— 或者拿它的设计去**造别的 agent** —— 这两条视角缺一不可。

## 收官一句话

**Claude Code 不是一个"套壳 LLM 的 agent"** —— 是一个**cache-first 的信息组织系统**。

每一处 context 设计的形态 —— CLAUDE.md 走 SR 而不进 system · fork 用 placeholder 抹平差异 · env memoize · 日期用 SR 单发 · Skill delta 增量 · MCP ToolSearch 服务端 defer —— **都能追溯到"不能 bust 大 cache"这个约束**。

反过来 —— 如果你在设计一个 agent · 但**不理解 prompt cache** —— 你可能会做出"正确但昂贵"的设计。 Claude Code 团队之所以做出这么多**看起来反直觉**的选择 —— 是因为他们**先看清了 cache 的账** —— 再倒着推每一处功能长什么样。

**先算账 · 再设计** —— 这就是 Context 系列 8 篇要留给读者的最后一句话。

---

## 参考

**Anthropic 官方**:
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · 4 大策略框架
- [Prompt caching · Anthropic docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) · cache 底层机制
- [MCP · Model Context Protocol](https://modelcontextprotocol.io/) · MCP 协议规范

**Claude Code 源码定位**(v2.1.220):
- SR 组装函数:`utils/messages.ts` · `wrapInSystemReminder` / `wrapMessagesInSystemReminder`
- SR 折叠 pass:`utils/messages.ts` · gate `tengu_chair_sermon`
- SR 中央调度:`utils/messages.ts` · `normalizeAttachmentForAPI`
- Cadence 常量:`utils/attachments.ts` · `TURNS_SINCE_WRITE` / `TURNS_BETWEEN_REMINDERS`
- `<env>` 块 memoize:`utils/context.ts` · `utils/prompts.ts`
- Cyber-risk 挂 Read:`tools/FileReadTool.ts` · `CYBER_RISK_MITIGATION_REMINDER`
- 模型豁免清单:`MITIGATION_EXEMPT_MODELS`
- Read 2000 行:`tools/FileReadTool/prompt.ts` · `MAX_LINES_TO_READ`
- Read dedup:`tools/FileReadTool.ts` · `FILE_UNCHANGED_STUB` · killswitch `tengu_read_dedup_killswitch`
- readFileState LRU:`utils/fileStateCache.ts` · capacity 100
- Skill listing 增量:`utils/attachments.ts` · `sentSkillNames`
- Skill invocation:`tools/SkillTool.ts` · `isMeta:true`
- MCP ToolSearch:`services/api/toolSearch.ts` · `getToolSearchBetaHeader`
- Defer flag:`utils/api.ts` · `defer_loading`
- Auto-defer 概率:`DEFAULT_AUTO_TOOL_SEARCH_PERCENTAGE = 10`
- MCP instructions delta:`utils/attachments.ts`

**Vault 内相关笔记**:
- [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) · 全景矩阵
- [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) · messages 数组基础
- [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) · isMeta / SR 通道基础
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) · cache 视角
- [04 · Compaction 六兄弟](04-compaction.md) · post-compact 相关的 SR
- [05 · CLAUDE.md 家族](05-claude-md-family.md) · CLAUDE.md 打包 SR
- [06 · Sub-agent 隔离 · 从独立 context 到 .output 陷阱](06-sub-agent.md) · sub-agent 里的 SR
- [09 · Sidechain · 从子代理到 agentId 分流](../agent-loop/09-sidechain.md) · 姊妹系列收官篇 · 执行流视角
- [06 · Streaming · 从 SSE 事件到逐字显示](../agent-loop/06-streaming.md) · 34 行 store 的分散设计
- AI Agent 实战/Week06_Memory_Compact_SystemPrompt/深度学习_System_Prompt · Prompt cache API 层通用原理
- AI Agent 实战/Week10_Skills_MCP_协议/Hermes子系统深读_压缩与记忆 · Hermes 压缩 vs Claude Code 压缩对照
