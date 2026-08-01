前一篇讲了 loop 遇到基础设施错误时的自愈机制 —— 8 层恢复叠加。 但有一种情况 loop 永远不能自己处理:**用户改主意了**。

用户看到 loop 跑了半天在读一个无关的文件、或者觉得 LLM 走偏了、或者只是想插一句话补充信息 —— 都得能**中断** loop。

从产品视角看很简单:按 Ctrl-C。 但从 loop 视角看事情复杂 —— loop 可能正处在 3 种不同状态:

- LLM 正在流式返回 · SSE 半段
- 工具正在并行执行 · 有几个 pending
- 权限批准 · Promise 在 await

**每种状态被强行中断 · 都会破坏 messages 数组的结构**。 比如工具执行到一半 · 中断了 · tool_use 已经在 messages 里 · 但 tool_result 没生成 —— **配对不变量被破坏**(见 [Context 02](../context-management/02-message-invariants.md))。 下一次调 LLM 直接 400。

这一篇讲怎么中断而**不让 messages 数组坏掉**。 核心问题:

- Ctrl-C / Esc 怎么从键盘穿过 UI 层传到 loop?
- loop 收到中断信号后怎么清理 in-flight 状态?
- 缺失的 tool_result 怎么补?
- 中断和"打断后继续输入"是同一件事吗?

## 一个 AbortController 贯穿全 loop

Claude Code 的每一次 loop 启动时 · 都会**创建一个新的 `AbortController`** —— 这是 Node.js 内置的抽象 · 提供两个东西:

- **`signal`** —— 可以传给下游函数 · 让它们知道"是否已被中断"
- **`abort()`** —— 触发中断 · 让所有 signal 变成 aborted 状态

Claude Code 把这一个 controller 放在 `QueryEngine` 上 · 全 loop 共享:

```
QueryEngine
    ├── this.abortController = new AbortController()
    ├── interrupt() → this.abortController.abort()
    └── loop 里 · toolUseContext.abortController.signal 传下去
```

用户按 Ctrl-C · UI 层调 `QueryEngine.interrupt()` · 触发 `abort()`。 一瞬间 · **整个 loop 内所有拿到 signal 的地方都变成 aborted 状态**。

**关键设计:一个 controller 而不是多个**。 为什么?因为 loop 里有很多**并行**动作:

- Streaming API 请求
- 多个并行的 tool 执行
- 权限批准 Promise
- Hook 子进程

用一个 controller · 一次 abort 让**所有并行动作**同时收到信号。 用多个 · 就要挨个 abort · 容易漏。

## 三个检查点

Loop 里三个关键位置**检查 `signal.aborted`**:

**检查点 1 · HTTP 请求层**

调 LLM 时把 `signal` 传给底层 fetch:

```
fetch(url, { signal: toolUseContext.abortController.signal })
```

`fetch` 是 signal-aware 的 —— signal 被 abort · fetch 立即 reject。 一瞬间 · 正在流式返回的 API 请求**被物理中断** · 后面的 SSE 事件不会再来。

**检查点 2 · Streaming 结束到 tool 执行之间**

一次 API 调用完成 · 拿到完整的 assistant 消息(可能带 tool_use)· **准备开始执行 tool 之前** —— loop 检查一下 `signal.aborted`。

如果已经 abort · 不启动 tool · 直接进入清理流程。

**检查点 3 · Tool batch 之间**

多个 tool 并行执行 · 一批完成后要执行下一批 —— 在这个间隙检查一次。 如果 abort · 不启动下一批。

**为什么是这三个点** —— 因为 signal 是**cooperative** 的 —— fetch 之类的 IO 操作能立即响应 · 但**非 IO 操作**必须**主动检查**才能中断。 一段纯计算的 for 循环 · 就算 signal abort 了 · 也会跑完。 检查点选在**每个"要开始新工作"的位置** —— 已经在跑的完成后 · 再检查一次要不要开始下一件。

## 缺失 tool_result 的合成

中断触发之后 · messages 数组可能是这个样子:

```
[
  msg 1: 用户消息
  msg 2: assistant 消息 · 里面有 3 个 tool_use 块 (A, B, C)
  msg 3: user 消息 · 里面已经追加了 tool_result A · B 完成了
    ← 但 C 还在执行 · 被 abort 了 · 没生成 tool_result
]
```

**这个数组已经损坏** —— tool_use C 存在 · 但没对应的 tool_result。 下次 append 用户新消息 · 上次数组还带着 orphan tool_use C · 调 LLM 就 400。

**Claude Code 的处理**:abort 触发后 · loop 扫一遍 in-flight tool_use · **合成假的 tool_result**:

```
{
  type: 'tool_result',
  tool_use_id: 'toolu_C',
  content: 'Interrupted by user',
  is_error: true
}
```

**这个合成的假 tool_result** 让 messages 数组结构上完整 · 下次调 LLM 不会 400。 语义上 LLM 也能看懂"这个工具被中断了"。

这段合成逻辑在源码里叫 `yieldMissingToolResultBlocks`。 一开始只用来处理中断 · 后来 [Loop 03](03-parallel-scheduling.md) 讲的 `ensureToolResultPairing` 修补机制也是同一种思路 —— **保配对是硬约束 · 破了必须补**。

## 两种中断语义

实际使用时 · 用户按 Ctrl-C 有两个不同的意图:

**意图 A · 单纯打断 —— "我不要 loop 继续了 · 让我思考一下"**

用户想停 loop · 然后自己看看之前的进度。 之后可能再输入新消息 · 也可能不输入。

**意图 B · 打断以提交新消息 —— "我要在中途补充点信息"**

用户想停 loop · **马上**给 LLM 一条新消息(比如"哦不 · 你走偏了 · 应该看 auth_v2.py")。 之后 LLM 应该继续跑 · 带着这条新消息。

**这两种意图 · 触发 abort 的方式一样 · 但期望的后续行为不同**:

- 意图 A:合成 "Interrupted by user" 追加到 messages · 然后 loop 结束 · 等用户下一次输入
- 意图 B:用户已经把新消息**打字进 UI**了 · loop 结束后 · 立即把这个新消息当作下一次 loop 的输入

**Claude Code 的处理**:通过 `signal.reason` 区分。

- 普通 abort:`signal.reason === 'ctrl-c'`(或类似)· 走 A 意图 · 合成 "Interrupted by user"
- 提交 abort:`signal.reason === 'interrupt'`(带有"要提交新消息"的语义)· 走 B 意图 · **不合成** "Interrupted by user" 消息

**为什么 B 意图不合成**:因为用户马上要提交的新消息本身就是"上下文补充"—— 再合成一句 "Interrupted by user" 是废话。 让用户的新消息**自己解释**为什么中断了这次 loop。

**同一个信号 · 两种语义** · 用 `signal.reason` 分流 —— **这是很聪明的设计**。 用户体验角度 · B 意图更常见(用户想插一句) · A 意图偶尔发生(用户真的只想停)。 让 B 更自然 —— 不追加冗余消息。

## Streaming 中的中断

上面讲了 tool 执行阶段的中断。 **streaming 中的中断**呢?

Streaming 阶段用户按 Ctrl-C · `AbortController.abort()` 触发。 fetch 立即 reject 底层连接。 但**已经收到的 SSE 事件呢**?

Claude Code 的处理:**收到的都当**收到了。 假设已经收到了 3 个 delta · 客户端已经把 3 段 text 累积到 assistant 消息里。 abort 后 · 这条不完整的 assistant 消息**仍然追加到 messages 数组** —— 内容是那 3 段 text · 没 tool_use 也没 stop_reason。

这样对 loop 状态机的影响:
- Terminal 类型是 `aborted_streaming` —— 表示是在 streaming 阶段中断
- 下次继续对话 · 这条不完整消息在历史里 —— LLM 能看到它自己说了半句话

**这个设计的取舍**:
- **保留**部分输出 —— 用户回过头看能看到 loop 走到哪里
- **丢弃**部分输出 —— 更干净但用户看不到进度

Claude Code 选保留。 原因:用户按 Ctrl-C 通常是"我看到 LLM 说了不对的东西 · 想打断" —— 那些不对的话必须保留下来 · 让下次对话时用户能引用("你刚才说的 X 是错的")。 丢弃就没这个上下文了。

## Chicago MCP 清理只在非 subagent 中断时跑

一个小但精妙的细节:某些 MCP server(比如 "chicago"—— Anthropic 内部服务)在 loop 结束时需要**清理连接状态**。

Claude Code 处理:**只有主线程 loop 被中断时才清理** —— sub-agent 中断不触发这个清理。

**为什么**:sub-agent 是主线程 loop 内部起的 · 它跟主线程 loop 共享同一个 MCP server 连接。 sub-agent 中断了 —— 但主线程 loop 可能还要继续用 MCP · 不该把连接清理掉。

**这个细节体现了 sub-agent 跟主线程的边界处理** —— 见 09 · Sidechain · 子代理 loop。 主线程和 sub-agent **共享 queryLoop** · 但**分流**一些主线程独有的行为(用 `if (!toolUseContext.agentId)` 判断)。 MCP 清理就是其中之一。

## Interrupt 是 "loop 中间无人参与" 的第二重例外

[01 篇](01-tool-permission.md) 讲了权限批准是 "loop 中间无人参与" 的**第一重例外** —— 让用户在危险操作时主动出现。

**Interrupt 是第二重例外** —— 让用户在任何时候主动出现。 权限批准是**loop 主动等用户**;interrupt 是**用户主动打断 loop**。

再加上 [04 篇](04-stop-reason.md) 的 **maxTurns** —— 无需用户参与、达到上限自动停 —— 三者互补:

- **权限批准**:loop 主动停 · 等用户在危险时刻拍板
- **interrupt**:用户主动打断 loop · 想停就停
- **maxTurns**:硬保险 · 无人参与也不会无限跑

三个共同保证了"loop 自动跑"这个前提在**任何情况**下都不会失控。 [00 篇](00-intro.md) 里挂的 4 个后续机制 hook 到这里全部落地。

## 小结

- **一个 AbortController 贯穿全 loop** —— 用户 Ctrl-C 一次 · 所有并行动作同时收到信号
- **3 个检查点** —— HTTP 请求(fetch signal-aware)· streaming 到 tool 执行间隙 · tool batch 间隙
- **合成 tool_result** —— 中断后扫 in-flight tool_use · 补合成 `is_error: 'Interrupted by user'` · 保配对不变量
- **两种中断语义** —— `signal.reason` 区分:纯打断合成 "Interrupted by user" · 打断以提交新消息不合成
- **Streaming 中断保留部分输出** —— 让用户能看到 loop 走到哪 · 引用不对的话
- **Chicago MCP 清理只主线程跑** —— sub-agent 中断不影响共享 MCP 连接
- **Interrupt 是 "loop 无人参与" 的第二重例外** —— 权限批准 / interrupt / maxTurns 三者互补

下一篇 09 · Sidechain · 子代理 loop 讲 Claude Code 的最后一个大机制 —— sub-agent 是怎么走同一个 queryLoop 却在 12 处主线程行为上分流的、`.claude/subagents/<agentId>.jsonl` 独立文件、agentId 的分流规则。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/QueryEngine.ts` · `abortController` · `interrupt()`
- `src/query.ts` · `yieldMissingToolResultBlocks` · in-flight tool_use 合成
- `src/query.ts` · `signal.reason === 'interrupt'` 分流
- `src/hooks/useCancelRequest.ts` · Ctrl-C / Esc 事件捕获
- `src/hooks/useCancelRequest.ts` · `chat:cancel` / `app:interrupt` 优先级

**相关篇**:
- [00 · 开篇 · 从聊天窗口到 loop](00-intro.md) · "loop 中间无人参与" 前提
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · 第一重例外 · 权限批准
- [03 · 从读文件到并行调度](03-parallel-scheduling.md) · `ensureToolResultPairing` 的另一半修补场景
- [04 · 从回答完了到 stop_reason 的 7 种含义](04-stop-reason.md) · maxTurns 保险
- 09 · Sidechain · 子代理 loop · 下一篇 · sub-agent 中断的特殊处理
- [02 · 从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md) · 配对不变量硬约束
