# 08 · 收尾 · 从 200K 账本到 Cache-first 信息系统

前 8 篇从 200K context window 出发，拆开了 messages、prompt cache、compaction、CLAUDE.md、sub-agent 隔离和 `<system-reminder>`。这一篇不再增加新机制，只把这些局部重新拼回 Claude Code 的信息组织系统。

## 7 条读者带走的核心洞察

如果整套 Context 系列只记住 7 件事，应该是下面这 7 条。

### 1 · 200K 是单次调用的预算

200K 不是一个 session 累计可以使用的 token 总额，而是一次 LLM 调用能够装下的完整输入。Tools schema、system prompt 和 messages 历史都要从同一本账里扣除。

由于 LLM 本身无状态，Claude Code 每一轮都要重新发送这些信息。Context 管理要解决的核心问题因此不是“保存历史”，而是“怎样在固定预算内反复重建模型需要看到的输入”。详见 [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md)。

### 2 · Messages 数组有不能破坏的结构

消息历史不是可以随意增删的文本列表。它要保持 role 顺序，并保证每个 `tool_use` 都有对应的 `tool_result`。一旦破坏，API 请求可能直接失败。

Interrupt 后补出工具结果、compact 前处理未完成工具、rewind 只能从特定消息回退，这些看似独立的限制，底层都在保护同一套消息不变量。详见 [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md)。

### 3 · Cache 是骨架 · 不只是一个优化功能

Prompt cache 不只是 Claude Code 的某个性能开关。许多看起来反直觉的设计，都是为了维持一个尽可能长且稳定的输入前缀。

因此，判断一种信息应该放在哪里，不能只看它语义上属于 system、tool 还是 user，还要看它是否稳定、变化时会打穿多大的 cache。详见 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md)。

### 4 · 越稳定的内容越靠前 · 越容易变化的内容越靠后

真正稳定、通用的内容适合放在 tools 和 system prompt 等前部区域；用户、项目和运行时相关的信息，更适合通过 messages 往后追加。

CLAUDE.md 虽然语义上是系统级指令，却会随用户和项目变化，因此进入 messages 而不是固定 system prompt。这样变化只影响靠后的 cache，前面的稳定部分仍可复用。详见 [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](05-claude-md-family.md)。

### 5 · Cache 静态不等于语义静态

一段内容在含义上长期不变，不代表它在序列化后的字节上稳定。MCP instructions 可能晚连接，Skill 列表可能新增，日期会跨天，CLAUDE.md 也可能被修改。

Prompt cache 关心的是前缀是否逐字一致，而不是内容在概念上是否仍表达同一件事。因此，增量 message、placeholder、memoize 和延迟加载都在服务“字节稳定”这一目标。

### 6 · `<system-reminder>` 是信息通道 · 不是决策器

`<system-reminder>`（SR）把 CLAUDE.md、日期变化、Skill listing、MCP instructions 等程序生成的信息送给模型。触发判断由各功能模块完成，SR 只负责包装和传递。

所以 SR 更像一条元信息总线：多个功能共用同一条通道，但不存在一个中央模块理解并决定所有内容。详见 [07 · Meta 机制 · 从 system-reminder 到 20+ 种通道](07-meta-mechanisms.md)。

### 7 · Context 管理是分散但收敛的

Claude Code 没有一个包办所有事情的 ContextManager。每个功能维护自己的状态，决定何时加载、裁剪或注入信息。

这些分散的实现最终收敛在少数共同约束上：context 预算、prompt cache 的稳定前缀、messages 数组的不变量。它不是“各干各的”，而是“各自负责，但遵守同一套规则”。

## 从 200K 账本到完整系统

现在回头看整个系列：

- **[00](00-intro.md)** —— 建立 context 预算的全景
- **[01](01-agent-loop.md)** —— 解释无状态 LLM 为什么需要每轮重发输入
- **[02](02-message-invariants.md)** —— 建立消息历史的结构约束
- **[03](03-prompt-cache.md)** —— 解释稳定前缀如何塑造上层设计
- **[04](04-compaction.md)** —— 解释历史过长后如何分层压缩
- **[05](05-claude-md-family.md)** —— 追踪项目指令如何进入 context
- **[06](06-sub-agent.md)** —— 解释信息如何在多个 agent 之间隔离
- **[07](07-meta-mechanisms.md)** —— 展开程序向模型补充元信息的通道

这些机制共同回答了一个问题：**在 LLM 无状态、输入预算有限、每轮都要重发历史的前提下，Claude Code 怎样持续给模型装配足够、正确而且成本可控的信息。**

## Context 管信息 · Loop 管执行

本系列讲的是**信息流**：每次调用要给模型看什么，这些内容放在哪里，什么时候加载、压缩或重新注入。

姊妹系列 [Agent Loop 研究系列](../agent-loop/10-conclusion.md) 讲的是**执行流**：什么时候调用模型、什么时候执行工具、失败后如何恢复、什么时候停止。

两条线的分工可以压缩成两句话：

> Context 讲清“信息怎么组织”。
>
> Loop 讲清“事情怎么发生”。

只有把两者放在一起，才能看到完整过程：输入如何进入 context，loop 如何消费这些输入，工具结果如何返回 messages，cache 如何复用稳定部分，历史过长后又如何压缩。

## 收官一句话

**Claude Code 不只是一个套着工具的 LLM，也是一个 cache-first 的信息组织系统。**

CLAUDE.md 放进 messages、Skill 列表增量追加、MCP 工具延迟加载、fork 用 placeholder 抹平差异，都可以追溯到同一个约束：有限的 context 必须反复使用，昂贵的大 cache 不能轻易失效。

> **先算清信息的账，再决定机制应该长什么样。**

---

## 相关系列

- [10 · 收尾 · 从自动循环到通用 Agent Loop](../agent-loop/10-conclusion.md) · 执行流视角的系列收尾
- [Claude Code Tools 研究系列](../tool-mechanism.md) · 具体工具能力与设计
