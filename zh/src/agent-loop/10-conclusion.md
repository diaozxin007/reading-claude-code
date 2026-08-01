# 10 · 收尾 · 从自动循环到通用 Agent Loop

前 10 篇分别拆开了权限、hooks、工具调度、状态机、streaming、错误恢复、interrupt 和 sub-agent。这一篇不再增加新机制，只做一件事：把这些局部重新拼回完整的 Agent Loop。

## 5 条读者带走的核心洞察

如果整套 Loop 系列只记住 5 件事，应该是下面这 5 条。

### 1 · Loop 是自动循环 · 中间通常无人参与

用户按一次回车 · loop 自己向前运行 · 中间通常不需要用户逐步指挥。只有工具需要权限批准时，loop 才会主动停下来等用户；用户也可以通过 interrupt 主动打断。

这是 agent 和普通 chatbot 最根本的区别：chatbot 完成一次回答就停，agent 可以在一次用户输入后连续调用模型和工具，直到任务结束。

### 2 · Loop 是状态机 · 不是简单的 while

Loop 的核心不是 5 行伪代码，而是一套显式状态。每一轮结束时都会记录下一步该做什么；下一轮再根据这个状态决定走正常调用、重试、压缩还是恢复分支。

因此，出错后不会在当前一轮的 `try/catch` 里层层重试，而是回到主循环，由下一轮处理恢复操作。详见 [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md)。

### 3 · 错误是可以继续处理的状态

工具执行失败会被转换成 `tool_result` 交给 LLM；主循环需要恢复时，会被转换成 `transition` 交给下一轮。两者遵循同一种思想：**把错误转换成可以继续处理的状态或数据，而不是让异常直接打断 loop**。

因此，loop 不只是等待错误发生的 error handler，更像一个主动尝试自救的 recovery engine。只有内部恢复也失败时，最终错误才会报告给用户。详见 [07 · 重试与错误恢复 · 8 层恢复叠加](07-retry-recovery.md)。

### 4 · 自动运行有三道保险

Loop 自动运行并不意味着完全失控。有三种机制让人或系统可以重新取得控制：

- **权限批准** —— 执行危险工具前，loop 主动停下来等用户拍板
- **Interrupt** —— 用户随时主动打断正在运行的 loop
- **maxTurns** —— 即使无人干预，达到轮数上限也会强制停止

三者分别处理“执行前确认”“运行中制动”和“最终硬上限”，共同约束自动循环。

### 5 · 主代理和子代理复用同一套 loop

Sub-agent 不是另一套 loop 实现。主代理和 sub-agent 都调用同一套 `queryLoop` 代码，只是各自独立运行，并通过 `agentId` 区分身份。

这说明 loop 并不是专门服务于聊天窗口的代码，而是 Claude Code 中“让 AI 自主推进任务”的通用执行引擎。详见 [09 · Sidechain · 从子代理到 agentId 分流](09-sidechain.md)。

## 从 5 行骨架到完整系统

现在回头看整个系列：

- **[00](00-intro.md)** —— 从聊天窗口的直觉走到 5 行 loop 骨架
- **[01](01-tool-permission.md)—[04](04-stop-reason.md)** —— 拆开每一轮里的工具声明、权限、hooks、并行调度和停止判断
- **[05](05-query-engine.md)** —— 用状态机把前面的局部机制统一起来
- **[06](06-streaming.md)** —— 展开一次模型调用内部的流式过程
- **[07](07-retry-recovery.md)** —— 解释 loop 如何在失败后自我恢复
- **[08](08-interrupt.md)** —— 解释用户如何从外部打断自动循环
- **[09](09-sidechain.md)** —— 把同一套 loop 泛化到 sub-agent

最初的 5 行伪代码没有错，只是省略了真正重要的部分：**每一步之间如何分支、失败后如何恢复、用户如何重新取得控制，以及同一套循环如何服务不同类型的 agent。**

## Loop 管执行 · Context 管信息

**Loop 是骨架**。它解释事情怎么发生：什么时候调用模型、什么时候执行工具、什么时候重试、什么时候停止。

骨架上流动的是**信息**：messages 怎么装配、prompt cache 怎么复用、compact 怎么缩短历史、CLAUDE.md 怎么注入。这些属于姊妹系列 [Context 管理研究系列](../context-management/00-intro.md)。

两个系列的分工可以压缩成两句话：

> Loop 讲清“事情怎么发生”。
>
> Context 讲清“信息怎么组织”。

二者合起来，才是 Claude Code Agent 运行机制的完整图景。

---

## 相关系列

- [Claude Code Context 管理研究系列](../context-management/00-intro.md) · messages、cache、compaction 与上下文注入
- [Claude Code Tools 研究系列](../tool-mechanism.md) · 每个具体工具的能力与设计
