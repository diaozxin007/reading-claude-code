> 本系列第 01 篇 · 承接 [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) —— 讲清 agent loop · 让后 5 篇每一次说到 "messages 数组"、"重发历史"、"每轮追加" 都有具体形状可参照。
>
> **为什么把这一篇放在最前面**:context 管理的所有讨论 · 都建立在"context 到底是什么"这个前提上。而 context 是什么 · 只有看清 agent loop 才知道。
>
> 本篇不涉及 cache · 也不涉及压缩 —— 先建立**基础模型** · 再谈优化。

## 你可能没搞清的几件事

Claude Code 用起来是这样:一个聊天窗口 · 你打字 · 它回复 · 中间它可能读几个文件、运行几个命令、然后继续跟你说话。

但你有没有想过:

1. **它是"记住"了之前的对话 · 还是每次都重新看一遍?**
2. **它执行 `Read` 工具的时候 · 到底跟 LLM 打了几次交道 · 一次还是多次?**
3. **200K context 上限 —— 这 200K 到底是从哪里算到哪里?是一整段对话的总量?还是一次调用的输入?**
4. **同一段对话进行到 20 轮之后 · 前面的对话内容还在不在?会不会被"忘掉"?**
5. **你输入的一段话 · 到底以什么形式进了 LLM 的输入 —— 直接原样进去了?还是被 harness 包过一层?**

这几个问题如果答不上来 · 后面聊 cache / 压缩 / 断点 / CLAUDE.md 就是空中楼阁。本篇把这几件事讲清楚。

## TL;DR

| 问题 | 答案 |
|---|---|
| LLM 是有状态的吗? | **无状态** · 每次调用都是全新的 —— 之前"记得什么"完全靠 harness 每次把历史重发进去 |
| 一次"对话"内 · 到底调了多少次 LLM? | 用户每输入一次 · 会引发**一轮多次**的 LLM 调用 —— 每有一次工具调用 · 就多一次 |
| Context 是什么? | 一个消息数组 · 从 session 起手到现在的完整历史 · 每次调用 LLM 都完整重发 |
| 200K 是什么单位? | **单次 LLM 调用**的输入 token 上限 · 不是"session 累计上限" |
| Messages 数组会自然变小吗? | **不会** · 只会增长 —— 除非 harness 主动做压缩操作 |
| 你输入的一段话进 LLM 时长什么样? | 前面会 prepend 一段 `<system-reminder>` 包着的元信息(CLAUDE.md · 日期 · 等等)· 后面是原文 |

## 1 · LLM 是无状态的 —— 这是所有讨论的起点

**先立起最反直觉的一点**:LLM 本身是**无状态**的。

你打开 Claude Code · 跟它对话 10 轮。你以为是这样:

```
你说了 10 轮
    ↓
Claude 记着这 10 轮
    ↓
第 11 轮 · Claude 基于记着的东西回复
```

**错的**。实际是这样:

```
第 1 轮:harness 发送 [messages 数组:1 条] 给 LLM
第 2 轮:harness 发送 [messages 数组:3 条(第 1 轮的用户消息 + LLM 回复 + 你的新消息)] 给 LLM
第 3 轮:harness 发送 [messages 数组:5 条] 给 LLM
...
第 11 轮:harness 发送 [messages 数组:21 条] 给 LLM
```

**LLM 每一次调用都是全新的 —— 它"看到"什么完全取决于 harness 这一次给它塞了什么**。

- 你觉得 Claude "记住" 你前面说过的话 —— 实际是 harness 把前面所有话都塞进了这一次的输入
- 你觉得 Claude "看过" 那个文件 —— 实际是 harness 把 Read 的输出塞进了这一次的输入
- 你觉得 Claude "还记得" CLAUDE.md —— 实际是 harness 每一次都在输入前面塞了一遍 CLAUDE.md

**Harness 就是那个"记忆的载体"**。LLM 什么都不记 · harness 记一切。

这就是为什么本系列叫 "Claude Code Context 管理研究" —— **不是研究 LLM 怎么管记忆 · 是研究 harness(Claude Code 本身)怎么每次决定给 LLM 塞什么**。

## 2 · 一次"对话"到底是几次 LLM 调用

用户视角看 · 一次对话是这样:

```
你:"帮我看看这个 bug"
Claude:好的 · 我先读一下 auth.py …… 我看到了 · 原因是 X · 需要改 Y。已改完。
```

**看起来是 1 次交互**。实际上 · 中间 Claude 会:

1. 读 `auth.py`
2. 读 `login.py`(auth.py 引用了它)
3. 执行 `grep` 查找相关调用
4. 用 Edit 改文件
5. 运行测试确认

**每一次工具调用 · 都对应一次独立的 LLM 调用**。

真实的调用流是这样:

```
─── 调用 1 ────────────────────────────────────
harness → LLM:messages = [
   { role: 'user', content: '帮我看看这个 bug' }
]
LLM → harness:{ text: '好的,我先读一下 auth.py',
                tool_use: { name: 'Read', input: { file: 'auth.py' } } }
harness 执行 Read · 得到文件内容

─── 调用 2 ────────────────────────────────────
harness → LLM:messages = [
   { role: 'user', content: '帮我看看这个 bug' },
   { role: 'assistant', content: [<text>, <tool_use>] },
   { role: 'user', content: [<tool_result: auth.py 内容>] }
]
LLM → harness:{ text: '看到 auth.py 依赖 login.py · 继续读',
                tool_use: { name: 'Read', input: { file: 'login.py' } } }
harness 执行 Read

─── 调用 3 ────────────────────────────────────
harness → LLM:messages = [
   { role: 'user', content: '帮我看看这个 bug' },
   { role: 'assistant', content: [<text>, <tool_use: auth.py>] },
   { role: 'user', content: [<tool_result: auth.py 内容>] },
   { role: 'assistant', content: [<text>, <tool_use: login.py>] },
   { role: 'user', content: [<tool_result: login.py 内容>] }
]
LLM → harness:...

...(往后可能还有 3-5 次调用)...

─── 调用 N ────────────────────────────────────
harness → LLM:messages = [...(累积到现在的所有消息)...]
LLM → harness:{ text: '已改完 · 原因是 X · 我改成了 Y' }
                (没有 tool_use · 说明这一轮结束了)
```

**"一轮"结束的标志是 LLM 返回一次不带 tool_use 的回复**。也就是 LLM 说"我说完了 · 该你了"。用户视角这叫"Claude 回复了" · 实际经过 5-10 次 LLM 调用。

**关键观察**:

- **每次调用 · 都在原来 messages 数组末尾追加了新的东西**(LLM 输出 + tool_result)
- **每次调用 · 都是把整个 messages 数组完整发送** —— 不管是第 1 次还是第 10 次
- **20 轮对话之后 · 一次 LLM 调用可能就要发 50K+ token** —— 因为 messages 数组已经有几十条了

## 3 · Context 是一个只增不减的消息数组

前面画的调用流已经透露:**context 就是一个消息数组 · 从 session 起手到现在**。

它的**基本操作只有两个**:

- **append**:LLM 输出后 · harness 把 assistant 消息追加进数组;工具执行完后 · harness 把 tool_result 追加进数组;用户发新消息 · 追加进数组
- **prepend**(session 起手一次):harness 在数组最前面塞一段元信息 —— 我们下面细说

**它没有的操作**:

- ❌ **修改** —— 前面的消息不能改。改了 LLM 会以为 "以前的对话是那样"
- ❌ **删除** —— 前面的消息不能删。删了后面的引用就断了(比如 tool_use 和 tool_result 必须配对)
- ❌ **重排** —— 前面的消息不能换顺序。LLM 靠顺序理解因果

**这三个限制加起来 · 就是本系列后面所有讨论的前提**:

- **Compaction(压缩)其实是"append 一个摘要 + 抛弃前面所有"**,不是"改前面的消息"
- **Cache 前缀匹配为什么有效** —— 因为消息只 append 不改 · 前缀天然稳定
- **`isMeta:true` 消息** —— harness 为了不污染真对话历史而做的标记

## 4 · 200K 是"单次调用"上限 · 不是"session 累计"上限

一个非常常见的误解:

> "我这个 session 已经用了 150K context · 快到 200K 就该 /compact 了"

**这个理解**部分对**但不精确**。准确的说法是:

- 200K 是**一次 LLM 调用**的 **输入** token 上限
- 你说的 "session 用了 150K" 实际是说 "**最近一次调用的输入**大概是 150K"
- session 历史本身没有"累计上限" —— 你可以对话 100 轮 · 只要**每一次调用**都不超 200K 就行

但因为 messages 数组只增不减 · **每一次调用**的输入都在增长 · 早晚会撞上 200K。撞上之前必须做点什么。

**"做点什么"就是** 03 · Compaction 六兄弟 **要讲的**。

**具体来说 200K 里装了什么**:

```
一次 LLM 调用的完整输入 · 拼起来的样子:

┌────────────────────────────────────────────┐
│ tools 段:所有可用工具的 schema             │  ~20-30 KB
│    (Read / Edit / Write / Bash / Agent /    │
│     TaskCreate / …40 多个 tool …)           │
├────────────────────────────────────────────┤
│ system prompt 段:                          │  ~15-25 KB
│    主 prompt · 工具使用说明 ·               │
│    环境信息(cwd / git / 平台)·             │
│    组织级配置(允许的工具集)                │
├────────────────────────────────────────────┤
│ messages 段:                               │  增长
│    [prepend user msg:CLAUDE.md · 日期]     │  ~2-10 KB
│    第 1 轮:user 消息 + assistant 回复      │
│    第 1 轮的 tool_use / tool_result 对      │
│    第 2 轮:user 消息 + assistant 回复      │
│    第 2 轮的 tool_use / tool_result 对      │
│    ...(所有历史轮次)...                    │
│    最新一轮:user 消息(等待 LLM 处理)     │
└────────────────────────────────────────────┘

三段全部 token 加起来 ≤ 200K
```

**tools + system prompt 段基本不变** · 一直占 30-50 KB。也就是说 · **messages 段能用的空间实际是 ~150-170K**。真到 messages 段用满 150K · 就该 compact 了。

## 5 · 你输入的话进 LLM 时长什么样

再看一处细节:你在 Claude Code 里输入的这段话 —— "帮我看看这个 bug" —— 到 LLM 输入里长什么样?

**如果是 session 的第一条消息** · 它进 LLM 的样子:

```
messages: [
   {
     role: 'user',
     isMeta: true,                              ← harness 标记 · 表示不是"真"用户消息
     content: '<system-reminder>
        As you answer the user's questions, you can use the following context:
        # claudeMd
        <Contents of ~/.claude/CLAUDE.md (user's private...):
        <你的全局 CLAUDE.md 内容>

        Contents of /repo/CLAUDE.md (project instructions...):
        <项目 CLAUDE.md 内容>

        # currentDate
        Today's date is 2026-07-30.

        IMPORTANT: this context may or may not be relevant to your tasks.
        </system-reminder>'
   },
   {
     role: 'user',
     content: '帮我看看这个 bug'                 ← 真正的用户消息
   }
]
```

**观察**:

1. **你输入的原话没变** —— 就是 "帮我看看这个 bug"
2. **前面被 harness prepend 了一条 `isMeta:true` 消息** · 塞满了元上下文(CLAUDE.md / 日期)
3. **元上下文包在 `<system-reminder>` 里** —— LLM 看到 SR 标签就知道这不是用户说的 · 是 harness 塞的

这就引出了后续的几个关键机制:

- **`<system-reminder>` 是 harness 跟 LLM 的元通信通道** —— 06 · Meta 机制 · system-reminder 类型学 + File state 会讲 · 有 20+ 种触发条件
- **`isMeta:true` 是 harness 标记 "这不是真用户消息"** —— 前面案例说过 · harness 也要标记类型学
- **CLAUDE.md 走 messages 段的 prepend 位置 · 不是走 system prompt** —— 这个反直觉的设计有具体原因 · [05 · CLAUDE.md 家族](05-claude-md-family.md) 和 [03 · Prompt Cache 是骨架](03-prompt-cache.md) 都会讲

## 6 · Agent Loop 全景图

上面各点合起来 · 一张完整的 agent loop 图:

```
                    ┌────────────────────┐
     用户输入 ────→ │ 追加到 messages 尾  │
                    └────────────────────┘
                              │
                              ▼
        ┌───────────────────────────────────────┐
        │  装配一次 LLM 调用的输入:             │
        │  [tools] + [system prompt] + messages │
        └───────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │   LLM (无状态)    │
                    └──────────────────┘
                              │
                              ▼
             ┌──────────────────────────────┐
             │  LLM 返回:text ± tool_use   │
             │  追加为 assistant 消息       │
             └──────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  带 tool_use 吗? │
                    └──────────────────┘
                     │              │
                    是               否
                     │              │
                     ▼              ▼
    ┌──────────────────────┐   ┌──────────────────┐
    │ 执行工具              │   │  一轮结束        │
    │ tool_result 追加到    │   │  等用户下次输入   │
    │ messages 尾           │   └──────────────────┘
    └──────────────────────┘
                     │
                     └──── 循环回 "装配一次 LLM 调用" ──→
```

**这张图是本系列所有后续讨论的基石**。后面每一篇 · 都是在这个 loop 上加不同的**扭曲**或**优化**:

- **Compaction**:发现 messages 太长 · 在装配之前先把老消息压成一条摘要
- **CLAUDE.md 家族**:装配时 · 除了 tools/system/messages · 还要 prepend 元信息进 messages 头
- **Sub-agent 隔离**:遇到重活 · 不在当前 loop 里搞 · fork 一个**独立的 loop** 出去 · 只把结果拿回来
- **JIT 检索**:装配前 · Skill 的 body / 大文件的内容 —— 能不塞 messages 就不塞
- **Prompt cache**:每次调用完整重发前缀 · 但服务器发现前缀跟上次一样 · 复用之前的计算
- **`<system-reminder>` 类元机制**:harness 除了追加"真消息" · 还追加各种元指令通知

## 7 · 一次真实调用的成本账

有了 loop 模型 · 现在可以算一笔账:

假设一次简单的 "读一个文件 · 改一处代码" 任务 · 5 次 LLM 调用 · 消息数组从 1 条增长到 11 条:

| 调用 # | messages 数量 | tools + system | 输入总 token | 说明 |
|---|---|---|---|---|
| 1 | 1(仅用户消息) | 50K | ~52K | 起手 · 最便宜 |
| 2 | 3(+ assistant + tool_result) | 50K | ~55K | tool_result 可能有 3K |
| 3 | 5 | 50K | ~60K | 继续读文件 |
| 4 | 7 | 50K | ~65K | Edit 前审查 |
| 5 | 11(Edit 完 · 又跑测试) | 50K | ~75K | 尾声 |

**没有 cache 的话** · 5 次调用总输入 ~305K token。**5 次调用里** · 从第 2 次起 · **每次都在重发前面所有 token**。

有 cache 的话:
- 第 1 次全价 ~52K(付 write cost 1.25 倍)
- 第 2 次开始:tools + system 段(50K)之前已缓存 · 只算 read cost(0.1 倍)· 相当于付 5K 全价 —— 加上新增的一条消息 · 全价部分只有 ~5K + 3K
- 第 3-5 次同理

**cache 命中率一高 · 单次调用成本从 60K token 变成 8K token —— 差 7 倍以上**。

**这就是**为什么** Claude Code 要围绕 prompt cache 建整套 harness** —— 因为不做 cache 优化 · agent loop 的成本会随对话轮数**平方级**膨胀(每轮发送量线性增长 × 轮数越多发得越多)。

这也是为什么下一篇 [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) 会先讲清消息数组的结构约束 · 再由 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 讲底座 —— cache 不是加速器 · 是让 agent loop 在**成本上可持续**的必然选择。

## 8 · 本篇小结

- **LLM 无状态** · 所有"记忆"都是 harness 每次重发的
- **一次用户输入 = 多次 LLM 调用** · 每次工具调用后都要再调
- **Context 是一个只增不减的消息数组** · 只能 append · 不能改/删/重排
- **200K 是单次调用输入上限** · 不是 session 累计
- **每次调用发送 = tools 段 + system prompt 段 + 整个 messages 数组** · 三段拼接
- **用户输入进 LLM 时被前置了元信息** —— CLAUDE.md / 日期 / etc · 走 SR 包裹的 `isMeta:true` user message
- **成本随对话轮数平方级膨胀** —— 这是 cache 存在的根本理由

一句话:**Claude Code 的 harness 每一轮都在做同一件事 —— 装配 messages 数组 · 发给无状态 LLM · 处理返回 · 追加消息 · 再装配一次**。所有 context 管理机制 · 都是这个 loop 的变体或优化。

下一篇 [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) 放大 messages 数组本身:每条消息什么形态、结构有什么约束、约束破坏了怎么办。

---

## 参考

- Anthropic 官方:[Messages API](https://platform.claude.com/docs/en/api/messages) · role / tool_use / tool_result 格式
- Anthropic 官方:[Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) · loop 语义
- [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) · 4 策略 × 20+ 机制总账
- 系列后续:
  - [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md)
  - [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md)
  - 03 · Compaction 六兄弟(未写)
  - 04 · CLAUDE.md 家族(未写)
  - 05 · Sub-agent 隔离(未写)
  - 06 · Meta 机制 · system-reminder 类型学 + File state(未写)
