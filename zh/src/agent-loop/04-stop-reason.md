前三篇讲清了 loop 里"要不要执行工具"以及"怎么执行":权限批准、hooks、并行调度。 那是 loop 里**每一次转起来**的机制。

这一篇讲**另一头**:loop 什么时候**停**?

按 00 篇讲的 5 行骨架:

```python
while True:
    response = call_llm(messages)
    if response.has_tool_use:
        execute_tools + append
    else:
        break         ← 这里
```

**"没有 tool_use 就 break"** —— 但事情没那么简单。 LLM 一次调用返回时会带一个 `stop_reason` 字段 · 表示这次为什么停下:"我说完了"?"我要调工具"?"输出被截断了"?"我拒绝回答"?"context 满了"?

每一种 stop_reason 都需要 loop 做不同的处理。 看清一轮怎么结束 · 要回答这几个问题:

- Anthropic API 一共有几种 stop_reason?每种什么语义?
- Claude Code 依据哪个信号判断"这一轮真的结束了"?
- 哪些 stop_reason 会让 loop 停 · 哪些让 loop 继续?
- 如果 loop 就是不肯停(死循环)· 怎么办?

## 完整 stop_reason 清单

Anthropic API 的一次响应会带下面几种 `stop_reason` 之一:

| stop_reason | 含义 |
|---|---|
| **`end_turn`** | 模型觉得说完了 · 该用户接话了 |
| **`tool_use`** | 模型输出了 tool_use · 要调工具 |
| **`max_tokens`** | 输出 token 触顶 · 被服务端强制截断 |
| **`stop_sequence`** | 匹配到自定义的停止序列 |
| **`refusal`** | 触发安全策略 · 模型拒绝回答 |
| **`pause_turn`** | 模型请求暂停这一轮 · 稍后继续 |
| **`model_context_window_exceeded`** | 上下文超上限 · 输入太长 |

**7 种** —— 但 Claude Code 对它们的处理方式**很不均匀**。

## 第一个反直觉:一轮结束不看 stop_reason

写 loop 的直觉是:

```
if stop_reason == "end_turn":
    break
elif stop_reason == "tool_use":
    execute_tools
```

**Claude Code 不是这么写的**。

Claude Code 判断 "一轮结束"的方式是:**assistant 消息里有没有 `tool_use` 块**。

```
if response.content 里有 tool_use 块:
    execute_tools
else:
    break
```

**为什么不看 stop_reason** —— 因为 `stop_reason === 'tool_use'` 在实际中**不可靠**。 源码里有注释直接说了这一点。 有时模型明明输出了 tool_use · stop_reason 却是 `end_turn`;有时 stop_reason 是 `tool_use` 但 content 里没实际的 tool_use 块。

**唯一可靠的判据是内容本身** —— 扫 content 数组 · 有 tool_use 就继续 · 没有就退。

**stop_reason 主要用途:错误 UX** —— 告诉用户"输出被截了 · 请让模型继续" · 或者"模型拒绝回答 · 请换个说法"。 **不作为 loop 的分派依据**。

## 各 stop_reason 的具体处理

**`end_turn`** —— 正常完成。 loop 检查 content · 无 tool_use · 走 `completed` 分支 · 结束。

**`tool_use`** —— 直接**忽略这个 reason**。 只看 content 里有没有 tool_use 块。 有就 execute_tools · 追加 tool_result · 再进下一轮。

**`max_tokens`** —— 输出触顶被截。 这是个错误状态 · loop 触发 `max_output_tokens` 恢复流程:
- 先尝试**上调 max_tokens 上限**(escalate)· 再试一次
- 如果上调过还触顶 · 注入一条 `[Output token limit hit, continue]` 用户消息 · 让 LLM 明确知道要接着说
- 最多重试 3 次(`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`)· 还失败就抛给用户
- **loop 从头看是"还没结束" · 继续跑**

**`model_context_window_exceeded`** —— context 超上限。 loop 触发 [reactive-compact](../context-management/04-compaction.md) 流程 · 尝试压缩历史后重试。 也是**继续跑**分支。

**`refusal`** —— 模型触发了安全策略。 loop 生成一条错误消息 · 建议用户 `/model` 换模型试试。 但**不重试** —— refusal 是模型的主动拒绝 · 靠自动重试没意义。 loop **结束**。

**`stop_sequence`** —— 自定义停止序列命中。 Claude Code 里几乎**不用**这个字段 · 因为它没设 stop_sequences。 fall through 到"检查 content 有无 tool_use" —— 通常无 · 就 break 出去。

**`pause_turn`** —— **完全没处理**。 源码里**找不到任何对 `pause_turn` 的分支处理**。 SDK 层认它 · 但 Claude Code loop 层没有任何相关代码。 大概率理由:pause_turn 是给"运行时间很长的复杂 turn 用的" · Claude Code 主 loop 场景通常一轮 3-10 次调用 · pause_turn 用不到。 是**一个源码里的实际空白** —— 未来若接入长思考类模型 · 需要补上处理逻辑。

## 反直觉的错误处理哲学

上面 `max_tokens` / `context_window_exceeded` 的处理路径揭示一个 Claude Code 的核心哲学:

**错误不是终止 · 而是 recovery 的触发信号**。

- `max_tokens` → 不是"抱歉输出太长了 · 请重试" · 是自动上调上限 + 注入 continue + 重试
- `context_window_exceeded` → 不是"抱歉 context 满了" · 是自动 compact + 重试
- `overloaded` / rate limit → 自动 fallback model + 重试
- 网络错误 → withRetry 指数退避 + 重试

**loop 的设计目标是"能自己恢复的错误都自己恢复 · 只把真的没法救的抛给用户"**。 这跟 Anthropic 官方博客里 "Claude Code 是**恢复引擎**而不是**错误处理器**"是一致的。

在 loop 状态机层面 · 这些恢复对应不同的 transition · loop 07 篇会讲。

## MaxTurns —— 硬保险

上面这么多 recovery · 都能让 loop 继续跑 —— 那 loop 会不会**永远不停**?

理论上可能。 比如:
- LLM 陷入循环 · 每轮都要调工具 · 每轮工具结果也没让它满意
- max_tokens 恢复重复触发 · 每次上调后又触顶
- context_window 触发 compact · compact 后马上又超 · 无限套娃

**Claude Code 有一个硬保险:`maxTurns`**。

一次 loop 内(从用户按回车到 loop 结束)· 累计 LLM 调用次数超过 `maxTurns` · 直接强制退出。 SDK 层默认可以由用户在启动 Claude Code 时配置 · 交互式 REPL 有一个较高的默认值。

hit maxTurns 后:
- 追加一条系统消息 `[max_turns_reached]` 到 messages
- SDK 层返回 `{ subtype: 'error_max_turns' }`
- 用户看到明确提示 · 明白 loop 被强制停了

**maxTurns 是"loop 中间无人参与"前提的一重保险** —— 让 loop 在无人监督的情况下也不会无限跑。 [08 篇](08-interrupt.md) 会把这一重和其他保险一起总结。

## Stop hook 的最后阻断

按上面的逻辑 · loop 走到"content 无 tool_use → completed" · 就该退了。 但还有最后一个门 —— **Stop hook**。

Loop 02 讲过:hook 里有一个 `Stop` 事件 · 挂在 loop 打算结束的时刻。 如果 Stop hook 返回 `decision: block` · **loop 不能真的结束** —— 必须再跑一轮。

这个能力用于:
- "跑测试之前不允许结束"(hook 里检查测试有没有跑)
- "还有未提交的改动 · 强制让 LLM 处理完"

**一次真正的 loop 结束需要过三关**:
1. 内容里没有 tool_use(内容判据)
2. stop_reason 不是需要 recovery 的类型
3. Stop hook 不阻拦

三关都过了 · loop 才 `completed` · 结果显示给用户 · 用户回来接手。

## 完整的一轮结束逻辑

上面的所有分支 · 落到 loop 状态机里就是这样的伪代码:

```
一轮调 LLM 之后 · 检查:

if content 里有 tool_use 块:
    → execute_tools · 追加 tool_result · 进下一轮
elif stop_reason == "max_tokens":
    → max_output_tokens 恢复(escalate → 注入 continue → 重试)
    → 最多 3 次 · 之后放弃 · 抛给用户
elif stop_reason == "model_context_window_exceeded":
    → reactive-compact · 压缩后重试
elif stop_reason == "refusal":
    → 生成错误消息 · loop 结束
elif turnCount > maxTurns:
    → max_turns 保险 · 强制结束
elif Stop hook return block:
    → 忽略结束 · 强制再跑一轮
else:
    → completed · loop 真的结束
```

**7 种 stop_reason · 5 种分支处理** —— stop_sequence 和 pause_turn 实际没进这个流程。 loop 决策依据是"内容 + 特殊 stop_reason + turnCount + hook" 四个信号的组合。

## 小结

- **一轮结束的判据是 "content 里有没有 tool_use"** —— stop_reason 不可靠 · 只用于错误 UX
- **7 种 stop_reason**:`end_turn` / `tool_use` / `max_tokens` / `stop_sequence` / `refusal` / `pause_turn` / `model_context_window_exceeded`
- **max_tokens 和 context_window_exceeded 触发 recovery** —— 不是终止 · 是自动恢复后重试
- **refusal 直接结束** —— 不重试(重试无意义)
- **pause_turn 完全没处理** —— 源码空白 · 未来接长思考模型需补
- **maxTurns 硬保险** —— 一次 loop 内累计调用超上限强制退
- **Stop hook 最后阻拦** —— 挂在结束前 · 能强制再跑一轮
- **一次真正结束要过三关**:内容判据 · stop_reason 判据 · Stop hook 判据

下一篇 [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md) 把前四篇的所有机制统一起来 —— 权限 / hooks / 并行调度 / stop_reason 处理 / recovery —— 都是主循环状态机的一部分。 主循环靠 `state.transition.reason` 这个 7 值 union · 每一 tick 决定走哪条路径。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/services/api/claude.ts` · `message_delta` 分支里的 stop_reason 处理
- `src/services/api/errors.ts` · `getErrorMessageIfRefusal` 检测 refusal
- `src/query.ts` · `queryLoop` 主循环 · turn 判断、maxTurns、recovery 分支
- `src/query/stopHooks.ts` · `Stop` hook 阻断逻辑
- `src/QueryEngine.ts` · SDK 层 `error_max_turns` 结果类型

**相关篇**:
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · 单步拦截保险
- [02 · Hooks · loop 上的可编程干预点](02-hooks.md) · Stop hook
- [03 · 从读文件到并行调度](03-parallel-scheduling.md) · tool_use 内容判据的具体检测
- [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md) · 下一篇 · recovery 分支的统一
- [04 · Compaction 六兄弟](../context-management/04-compaction.md) · reactive-compact 详解

**Anthropic 官方**:
- [Messages API — stop_reason](https://platform.claude.com/docs/en/api/messages#response-body-stop-reason) · stop_reason 值语义
