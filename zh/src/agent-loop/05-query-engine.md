前 4 篇讲了 loop 里的具体机制:tool 声明、权限、hooks、并行调度、stop_reason 处理、错误 recovery。 每一篇都是一个具体角度。

这一篇把它们**统一起来**。 主循环的核心 · 不是那 5 行伪代码 · 而是**一个显式的状态机** —— 每一次调 LLM 前 · loop 先决定"我现在要走哪条路径"、每一次调 LLM 后 · loop 先决定"下一次要走哪条路径"。 recovery / retry / autocompact / stop-hook 阻断 · 全都是这个状态机里的**一等分支**。

看清主循环要回答几个问题:

- 5 行伪代码在 Claude Code 源码里到底长什么样?
- Loop 的 iteration 到底是什么 · 一次 iteration 做几件事?
- 什么决定 loop 走哪条路径?
- Recovery 是嵌套的还是并列的?

## 先纠正一个命名误会

`src/QueryEngine.ts` 是 45KB 的一个大文件 —— 从名字看很像"查询引擎主循环"。

**它不是**。

`QueryEngine` 是**SDK 适配层** —— 一个给 SDK / 非交互 CLI 用的稳定接口 · 包装底层的 loop。 它的 `submitMessage()` 是一个 async generator · 用于逐步向 SDK 消费者暴露 loop 事件。

**真正的主循环在 `src/query.ts` 的 `queryLoop` 函数里** · 1700+ 行。 全篇讨论的都是这个 `queryLoop`。

为什么 QueryEngine 不叫 QueryEngine · queryLoop 才是引擎? 大概率是历史命名 —— `QueryEngine` 是较晚为 SDK 接入而加的适配层 · 主循环早就叫 `queryLoop`。 顺手看到 45KB 就以为是主循环是**误会**。 主循环反而没那么大 · 但复杂度高 —— 1700 行几乎全是分支决策。

## 状态机的形态

主循环是这样一个骨架:

```
while (true) {
    根据 state.transition.reason 决定这次要做什么
    执行:调 LLM · 处理 stream · 追加消息 · 执行 tool ...
    生成新的 state.transition · 决定下次做什么
}
```

**关键在 `state.transition.reason`** —— 这是一个 union · 一共 **7 种值**:

- **`next_turn`** —— 正常前进 · 调 LLM · 处理输出
- **`collapse_drain_retry`** —— context 满 · 触发激进压缩(context collapse)后重试
- **`reactive_compact_retry`** —— API 返回 prompt_too_long · compact 后重试
- **`max_output_tokens_escalate`** —— 输出 token 触顶 · 上调 max_tokens 后重试
- **`max_output_tokens_recovery`** —— 上调后又触顶 · 注入 "continue" 消息后重试
- **`stop_hook_blocking`** —— Stop hook block 了 · 强制再跑一轮
- **`token_budget_continuation`** —— 输出 token 预算模式 · 超过 +500k 后继续

**每一次 iteration 开头** · loop 检查 `state.transition.reason` 决定路径:
- 是 `next_turn` —— 正常调 LLM
- 是 `reactive_compact_retry` —— 走 compact 分支 · 再调 LLM
- 是 `stop_hook_blocking` —— 明明要退了 · 因为 hook 阻拦 · 强制再跑

**每一次 iteration 结尾** · loop 根据这次的结果 · 决定下一次的 transition。 是继续 next_turn?还是需要 recovery?还是可以 completed 结束?

**这就是"loop 是状态机"的意思** —— 不是简单的 `while (has_tool_use)` · 而是 `while (transition ≠ terminal)`。

## 一次 iteration 做了什么

一次 iteration = 一次 API 调用 + 一次 tool 批处理。 具体做的事:

1. **构建请求** —— 装配 messages 数组 · 加载 tools · system prompt
2. **调 LLM** —— streaming · 逐个事件消费(见 06)
3. **判断停止原因** —— 从 content 找 tool_use / 检查 stop_reason(见 [04](04-stop-reason.md))
4. **执行工具** —— 权限批准 → hooks → 并行调度(见 [01](01-tool-permission.md) / [02](02-hooks.md) / [03](03-parallel-scheduling.md))
5. **决定下一次 transition** —— 根据本轮结果 · 更新 state.transition.reason

**每一次都是这五步的完整循环**。 复杂度不在单次 · 在**多次之间的状态延续**。

## Loop 的终止 —— Terminal 状态

跟 transition 对应的 · 是一批 **Terminal** —— 表示 loop 应该结束的状态:

- **`completed`** —— 一切正常 · LLM 说完了(内容里无 tool_use)· 顺利结束
- **`max_turns`** —— 打 maxTurns 保险 · 强制退
- **`aborted_tools`** —— 用户 Ctrl-C 打断在 tool 执行阶段
- **`aborted_streaming`** —— 用户 Ctrl-C 打断在 LLM streaming 阶段
- **`hook_stopped`** —— Post-tool hook block · 强制退
- **`stop_hook_prevented`** —— Stop hook 拒绝退 · 但重试用光了
- **`blocking_limit`** —— 达到某种阻塞上限
- **`image_error`** / **`model_error`** —— 上游错误无法恢复
- **`prompt_too_long`** —— compact 都救不了 · 最终抛给用户

**Terminal 类型也有 10+ 种** —— 每一种表示"loop 因为某个具体原因结束了"。 SDK 消费者拿到 Terminal 后 · 根据类型给用户不同的 UX。

## 出错后回到主循环 · 不在 `try/catch` 里层层重试

这和 [工具出错时的处理方式](03-parallel-scheduling.md#Tool-崩了怎么办) 是同一种设计思想：**把错误转换成可以继续处理的状态或数据，而不是让异常直接打断 loop**。工具错误会变成 `tool_result` 交给 LLM；主循环需要恢复时，则会变成 `transition`，交给下一轮处理。

朴素设计里 · recovery 通常长这样:

```python
try:
    call_llm()
except PromptTooLong:
    compact()
    call_llm()  # 嵌套重试
except MaxTokens:
    escalate()
    call_llm()
```

**Claude Code 不是这么写的**。

Claude Code 遇到需要恢复的情况时，不会在当前这一轮里用 `try-except` 立即重试，而是先记录下一步该做什么，再进入下一轮主循环，由下一轮执行相应的恢复操作。

```
本轮结束(某种失败)
    ↓
生成新的 state.transition.reason = 'reactive_compact_retry'
    ↓
loop 转下一 iteration · 从 while 顶开始
    ↓
先看 transition · 是 reactive_compact_retry · 走 compact 分支
    ↓
compact 完 · 继续这一 iteration 的调 LLM 步骤
    ↓
拿到结果 · 再生成下一次 transition ...
```

**这是核心的设计洞察** —— Recovery 是 loop 的**一等状态转换** · 不是异常捕获。

**为什么这样设计?** 两个好处:

**好处 1 · 恢复可以链式**:

一次 iteration 完成后进入 `reactive_compact_retry` · compact 完再调 LLM · **结果又是 max_tokens** —— 这时候 transition 变 `max_output_tokens_escalate`。 然后**这次**又触顶 · transition 变 `max_output_tokens_recovery` · 注入 continue 消息。 一切都在同一个 `while` 循环里 · 每次进 iteration 时按 transition 分派。

**如果用 try-except 嵌套** —— 每层 recovery 都要嵌套 try · 或者写复杂的重入判断 · 一定会写乱。

**好处 2 · 可测试**:

源码注释里明确说 · `state.transition` 是**测试断言用的**。 一段代码执行完 · 断言 `state.transition.reason === 'reactive_compact_retry'` · 就知道有没有走到那个分支。 比 grep 错误消息稳定得多。

## 暂不向外报告错误（withhold）—— loop 的核心哲学

`withhold` 的意思是**暂时扣住、不向外传递**。这里指 loop 遇到错误后，先不通知 SDK 调用方，而是在内部尝试恢复；只有恢复失败，才把最终错误报告出去。

这个设计还有一个更深的目标 —— **对 SDK 调用方隐藏中间错误**。

Claude Code 里有一段直白的注释:某些 SDK 调用方(比如 cowork、desktop 端产品)一看到 API 响应里有 `error` 字段就认为"终止了"、"loop 完蛋了" —— 立即向用户报错。

**但 Claude Code 想在恢复期间藏住错误** —— 意思是 · 收到 `prompt_too_long` 时 · **不向上传** · 先尝试 compact · 如果成功了、下一次调 LLM 也顺利 · 那对 SDK 层面来说 · 这次错误**从未发生过**。 直到 recovery 也失败 · 才把 terminal error 抛出去。

**这就是 loop 是 "recovery engine" · 不是 "error handler"** —— error 是**loop 内部**的信号 · 不是**loop 外部**的输出。

## 一个反直觉：主代理和子代理复用**同一套** `queryLoop` 代码

写 sub-agent 系统的直觉是 —— sub-agent 该有自己的 loop 逻辑、自己的状态机。

**Claude Code 反其道**：主代理和 sub-agent 都调用同一套 `queryLoop` 实现，只是各自独立运行，并通过 `toolUseContext.agentId` 区分身份。这里的“同一个”是指**复用同一套代码**，不是共用同一个正在运行的 loop 实例。

代价:大约十几处 `if (!toolUseContext.agentId)` 判断散在 loop 各处 · 用来区分"main thread 才该做的事" —— MemoryPrefetch、手机 UI 摘要、MCP 清理、Stop hook 的锁等等。

收益:一处 bug 修 · 主线和所有 sub-agent 同时受益。

**共享 loop · 用 flag 分流** —— 这是一个典型的**共享代码 vs 分叉代码**取舍。 Sub-agent 的独立 context / worktree 隔离 / 沙箱执行 · 都由 loop 外的 `AgentTool.tsx` 来处理;loop 本身**不知道**自己是不是 sub-agent · 只是走同样的 iteration。

详见 09 · Sidechain · 子代理 loop。

## 主循环全景

把前 4 篇的机制和上面的状态机放在一起 · 主循环的一次 iteration 全景是这样:

```
─── 一次 iteration 开始 ─────────────────────
根据 state.transition.reason 分派:

  next_turn                    → 什么都不做 · 直接进主流程
  reactive_compact_retry       → 先跑一次 compact
  collapse_drain_retry         → 跑 context-collapse
  max_output_tokens_escalate   → 提高 max_tokens 上限
  max_output_tokens_recovery   → 注入 "[continue]" 消息
  stop_hook_blocking           → 无 op · 直接进主流程(是因为要拒绝退出)
  token_budget_continuation    → 继续输出模式

─── 主流程 ─────────────────────────────────
调 LLM · streaming 消费(篇 06)
      ↓
消息一条条 append 进 messages 数组(Context 系列 02)
      ↓
判断 · content 有 tool_use?
      ├─ 无 → 检查 stop_reason 是不是特殊(篇 04)
      │       ├─ 是 → 生成 recovery transition · 下一 iteration 处理
      │       └─ 否 → 检查 Stop hook · 是否阻拦
      │               ├─ 阻拦 → transition = stop_hook_blocking · 继续
      │               └─ 通过 → return { reason: 'completed' } · loop 退出
      └─ 有 → 执行 tools:
              权限批准(篇 01)
                    ↓
              PreToolUse hook(篇 02)
                    ↓
              并行调度 · 按 isConcurrencySafe 分批(篇 03)
                    ↓
              tool_result 追加 · 维护配对不变量(Context 系列 02)
                    ↓
              PostToolUse hook(篇 02)
              (期间任意步骤失败 · 转 is_error tool_result · 不抛)

─── iteration 结尾 ─────────────────────────
根据本轮结果 · 更新 state.transition.reason
      ↓
回到 while 顶 · 下一 iteration
```

**这就是前 4 篇统一起来的样子**。 每一层机制都是 iteration 里的一环 · 前 4 篇的具体机制 · 全都嵌在这个骨架里。

## 小结

- **`QueryEngine.ts` 不是主循环** —— 是 SDK 适配层。 主循环在 `src/query.ts` 的 `queryLoop`
- **主循环是状态机 · 不是简单 while** —— 7 种 `state.transition.reason` · 10+ 种 Terminal
- **Recovery 是并列 transition · 不是嵌套 try** —— 恢复可以链式、可以测试
- **暂不向外报告错误（withhold）** —— loop 对 SDK 调用方隐藏能自己恢复的中间错误 · 只抛真的无法救的
- **loop 是 recovery engine · 不是 error handler**
- **主代理和 sub-agent 复用同一套 `queryLoop` 代码** —— 各自独立运行 · 通过 `agentId` flag 分流

下一篇 06 · Streaming · SSE 事件流 · Ink 消费 讲主循环里"调 LLM"这一步的**细节** —— Anthropic API 用 SSE 分片流式返回结果 · 6 种事件类型怎么合并成完整消息、UI 层怎么增量渲染。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/query.ts` · `queryLoop` 主循环 · 1700+ 行的 while 状态机
- `src/query.ts` 中的 `state.transition.reason` union 定义
- `src/QueryEngine.ts` · SDK 适配层 · `submitMessage()`
- `src/services/tools/toolOrchestration.ts` · iteration 内的 tool 执行

**相关篇**:
- [00 · 开篇 · 从聊天窗口到 loop](00-intro.md) · 5 行伪代码骨架
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · iteration 中的权限
- [02 · Hooks · loop 上的可编程干预点](02-hooks.md) · iteration 中的 hook
- [03 · 从读文件到并行调度](03-parallel-scheduling.md) · iteration 中的 tool 执行
- [04 · 从回答完了到 stop_reason 的 7 种含义](04-stop-reason.md) · iteration 中的停止判断
- 06 · Streaming · SSE 事件流 · Ink 消费 · 下一篇 · iteration 中"调 LLM"的细节
- [07 · 重试与错误恢复](07-retry-recovery.md) · 与本篇的 recovery transition 直接对应
- 09 · Sidechain · 子代理 loop · 共享 loop / agentId 分流

**Anthropic 官方**:
- [Messages API — streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · streaming 协议
