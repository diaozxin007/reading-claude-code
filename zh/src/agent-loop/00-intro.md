打开 Claude Code · 输入 "帮我看看这个 bug" · 敲回车。

窗口开始滚动。它读了 auth.py · 又读了 login.py · 跑了个 grep · 改了一行代码 · 跑了下测试 · 最后告诉你 "好了 · 原因是 X"。

**看起来像跟一个记着前面对话、会用工具、会等你回话的人在聊天。**

但你如果去问 Anthropic API —— **LLM 本身是无状态的**。每次你调用它 · 服务端不知道你上次问过什么。想让它"记着"前面的对话 · 你必须每次都把从头到现在的**所有消息**重新完整发送一遍。

于是浮现出一个中间层 —— **harness**。它记着历史 · 每次调 LLM 时把历史打包好。你在聊天窗口看到的"连续对话" · 底下是这样:

```
第 1 轮:harness 发送 [1 条消息] → LLM 返回回复
第 2 轮:harness 发送 [3 条消息] → LLM 返回回复
第 3 轮:harness 发送 [5 条消息] → LLM 返回回复
...
```

Messages 数组只增不减 —— LLM 什么都不记 · harness 记一切。

接下来看:**一次用户输入 = 几次 LLM 调用?**

刚才那次 bug 修复:读了 2 个文件、跑了 grep、Edit 了一处、跑了测试 —— 5 次工具调用。每次工具执行完 · harness 都要把结果(tool_result)塞回 messages · 再调一次 LLM · 让它决定下一步。

所以"一次用户输入"背后是 **5-10 次 LLM 调用** —— 用户按回车 → 调用 A(LLM 说"我要读文件") → harness 读文件 → 调用 B(LLM 说"我要读另一个") → ... 直到 LLM 返回一次不带工具请求的消息 · 用户视角这一轮才算结束。

**这就是 loop。**

Anthropic 官方文档里 · 这个 loop 长这样:

```python
while True:
    response = call_llm(messages)
    if response.has_tool_use:
        results = execute_tools(response.tool_use)
        messages.append(response)
        messages.append(results)
    else:
        break
```

翻译一下:

- **while True** —— 循环 · 除非主动 break 出去
- **response = call_llm(messages)** —— 把当前 messages 数组完整发给 LLM · 拿到回复
- **if response.has_tool_use** —— 检查 LLM 回复里有没有工具调用
- **execute_tools + 双 append** —— 有工具就执行 · 把 LLM 回复和工具结果都追加进数组
- **else break** —— 没工具就退出循环 · 这一轮结束

**5 行代码的核心动作**:调 LLM · 看有没有 tool_use · 有就执行并 append · 没有就退出。

关键一点:**用户在这个 loop 里 · 只出现在开头和结尾**。 用户按下回车 · loop 就开始转 —— 中间的 "调 LLM · 执行 tool · 追加结果 · 再调 LLM" · 完全是程序自己在跑 · 不问用户、不等用户。 直到某一次 LLM 返回一条不带工具调用的回复 · loop 才停 · 最终结果显示给用户 · 这一轮才算结束。

这是 Claude Code 和 chatbot 最根本的区别 —— chatbot 每轮都等人 · agent 只在开头和结尾等人 · 中间全靠自己转。 也正因为 loop 是自己转下去的 · 才会有后面一系列机制:

- **interrupt** —— 用户想停必须打断 · 否则 loop 不会停
- **权限批准** —— 危险操作(比如 `rm -rf`)必须能拦下 loop · 因为 loop 自己不会犹豫
- **maxTurns 断路器** —— loop 万一无限循环怎么办
- **hooks** —— 用户想在 loop 里插自定义逻辑必须走 hook · 因为过程中没人操作

没有这个"自动循环"的前提 · 这些机制都是多余的。

**但这 5 行只是 happy path**。真实产品要处理:

- context 会满 —— 200K 塞不下了怎么办
- API 会失败 —— 网络挂了 / rate limit / 服务器过载 · 重试哪些不重试哪些
- 模型会 refusal —— 触发安全策略 · 提示用户切模型
- 用户会中断 —— Ctrl-C 之后 · 那个正在跑的工具怎么办 · 半截的 tool_use 怎么办
- 工具会崩 —— 别抛异常 · 转成 `tool_result is_error` 让模型自己看
- max_tokens 会触顶 —— 输出被截了 · 要不要注入个 "continue" 让它接着说
- 输出太长 —— 或者换个 fallback model
- 多个 tool_use —— 并行执行还是串行 · 谁能并行谁不能
- 用户跑到一半又发消息 —— 队列化 · 等这轮完了再处理
- 用户在 `.claude/settings.json` 里加了 hooks —— 每次工具执行前后 · 每次 session start/stop · 都要走一遍 hooks
- 工具第一次跑要用户批准 —— 阻塞 loop · 等 UI 点"yes"
- sub-agent 生下来 —— 走同一个 loop · 但要区分谁是主线谁是子代理

**每一条 · 都是 5 行代码没覆盖的复杂度。**

Claude Code 把这十几种情况编织进主循环 —— 于是那 5 行代码变成了这样:

```
while (true) {
    根据 state.transition.reason 决定路径:
        - next_turn                    → 正常调 LLM
        - collapse_drain_retry         → context 满 · 触发 context-collapse
        - reactive_compact_retry       → 被动 compact 后重试
        - max_output_tokens_escalate   → 上调 max_tokens 上限
        - max_output_tokens_recovery   → 注入 continue 消息重试
        - stop_hook_blocking           → stop hook 阻止终止 · 强制继续
        - token_budget_continuation    → 输出 token 预算模式继续

    调用 LLM · 处理 streaming

    捕获 stop_reason:
        - end_turn                     → 检查有无 tool_use · 无则 completed
        - tool_use                     → 走 runTools
        - max_tokens                   → 走 max_output_tokens 恢复
        - refusal                      → 提示 /model
        - context_window_exceeded      → 触发 reactive-compact

    执行工具:
        - 按 isConcurrencySafe 分批 · 并行/串行
        - 每个 tool_use 出错 → 转 is_error tool_result · 不抛
        - 支持 StreamingToolExecutor · 流式解析 JSON 时就启动 tool

    追加 tool_result 到 messages

    检查各种终止条件:
        - AbortController.aborted      → aborted_tools
        - turnCount > maxTurns         → max_turns
        - PostToolUse hook block       → hook_stopped
        - autoCompact 阈值触发          → 走 compact
        - prompt_too_long 错误          → withhold + 恢复

    继续下一次 iteration ...
}
```

后续每一篇 · 展开这里面某一段。
