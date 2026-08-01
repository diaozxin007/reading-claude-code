前面几篇讲了 loop 遇到错误时**能自己恢复的都自己恢复** —— max_tokens 上调重试、context 满触发 compact、stop_reason refusal 换模型建议。 但这些都是**语义级**错误(LLM 结果不对头)。

真实产品面对的还有一整类**基础设施级**错误:

- 网络挂了 · 请求根本没发出去
- API 返 500 —— 服务器内部错误
- API 返 429 —— rate limit 超了
- API 返 529 —— overloaded · Anthropic 集群压力大
- API 返错误说 "prompt_too_long" —— messages 加起来太长了

这一篇讲这些错误怎么处理:重试、退避、模型 fallback、compact 恢复。 核心问题:**loop 遇到基础设施错误怎么办 · 什么时候重试 · 什么时候放弃 · 什么时候换模型 · 什么时候压缩**。

## 每次 API 调用都套在 withRetry 里

Claude Code 每次调 LLM 都不是**裸调用** —— 而是走一个 `withRetry` 包装器。 一次逻辑上的 "call_llm" 背后可能是 1-10 次实际 HTTP 请求。

`withRetry` 的核心:

- **DEFAULT_MAX_RETRIES = 10** —— 默认最多重试 10 次
- 可以用环境变量 `CLAUDE_CODE_MAX_RETRIES` 覆盖
- 遇到失败 · 判断这个失败**能不能重试**(见下节)
- 能重试 · 按退避策略 sleep 后重发;不能重试 · 直接抛给 loop

对 loop 来讲 · 一次调用要么成功要么失败 —— 中间的重试全部是 withRetry 藏起来的。 loop 只看到"最终结果"。

## 判断能不能重试 —— 服务端说了算

朴素想法:客户端**自己判断**哪些错误能重试 —— 500 能、429 能、400 不能。

**Claude Code 的选择**:优先**问服务端**。

Anthropic API 在错误响应里带一个 header:

```
x-should-retry: true
```

或者:

```
x-should-retry: false
```

**服务端说能重试就重试 · 说不能就不重试** —— 无视 status code。

**为什么信服务端**:
- 客户端 heuristic(比如"所有 5xx 都重试")在一些边缘 case 是错的 —— 比如 500 里有一部分是"用户请求本身有问题" · 重试也白搭
- 服务端知道内部集群状态 —— 有的错误看起来是 rate limit 但实际是"这条请求的模型不可用了" · 重试没意义
- 服务端可以**动态调整** retry 语义 —— 部署更新时不需要客户端跟着改

**只有 header 缺失才 fallback 到 heuristic** —— 检查 status code / error type / error body 里的字符串。 比如 body 里有 `"type":"overloaded_error"` · 判定可重试。

**这个设计模式在生产系统里非常常见** —— 让**服务端主导决策** · 客户端只做兜底。 好处是**演进解耦**:服务端可以随时调整逻辑 · 客户端不需要发版。

## 退避策略 —— 优先 Retry-After · fallback 指数退避

判定能重试之后 · **等多久再重试**?

Claude Code 也是**服务端优先**:

- 如果响应头有 `Retry-After: 30`(秒)· 就 sleep 30 秒
- 如果响应头有 `Retry-After: <HTTP date>` · sleep 到那个时间点
- 都没有 · fallback 到**指数退避** —— 1s · 2s · 4s · 8s · 16s · 32s ...

**为什么优先服务端指定**:
- 服务端知道 rate limit 什么时候重置(有精确的窗口时间)
- 客户端指数退避是**盲目**的 —— 可能你等的 32 秒里 · 服务端 5 秒后就恢复了 · 你白等
- 或者反过来 · 你的指数退避 8 秒到了 · 服务端还没恢复 · 你重试又失败

**服务端指定的退避** —— 消除盲目性 · 让重试尽可能高效。

一种特殊模式:**persistent retry** —— 遇到 rate limit 时不用指数退避 · 直接用 rate limit 窗口重置时间。 比如 "每分钟 100 次" · 用满了 · 就 sleep 到下一分钟。 这是最精确的重试节奏。

## 529 overloaded 的特殊处理

Anthropic 的 529 状态码有特殊语义:**"我们集群压力大 · 你的请求现在没资源处理"**。

跟 429(rate limit)不一样 —— 429 是"你请求太快"· 529 是"我们服务器忙"。

如果盲目重试 529 · 会**让集群压力更大** —— 大家都在收到 529 · 大家都在重试 · 压力**放大而不是减小**。 这是分布式系统里的经典"重试雪崩"。

**Claude Code 的处理**:

- **非 foreground 查询源立即失败** —— 不重试 —— 避免放大压力。 什么算非 foreground?比如 `compact` 查询源、`session_memory` 查询源 —— 这些是后台任务 · 用户没直接等 · 出问题就出问题 · 别加剧集群压力
- **foreground 查询才重试** —— 用户在等 · 需要重试 —— 但也有上限:`MAX_529_RETRIES` · 连续 529 达到上限后抛 `FallbackTriggeredError`

`FallbackTriggeredError` 触发的下一步 —— **fallback model swap** —— 见下节。

**这个设计体现了 Claude Code 对生产 SLA 的成熟处理**:不所有请求都平等。 后台任务失败没关系(下次再来);用户 foreground 失败要救 —— 用更小的模型也比让用户等着好。

## Fallback model swap —— 保留当前 turn 换个模型再试

达到 529 上限或者其他致命错误时 · Claude Code 不直接抛给用户 · 而是尝试 **fallback**:

```
主模型是 claude-opus-4-6
529 连续失败 3 次 · 抛 FallbackTriggeredError
   ↓
Claude Code 捕获 · 尝试切换到 fallback_model(比如 claude-sonnet-4-6)
   ↓
用同样的 messages 数组 · 换新模型 · 重发
```

关键设计:**这次 swap 不算新的 turn** —— `turnCount` 不递增。 从 loop 状态机看 · fallback swap 是**inner while** 里的 · 不是**outer while**(turnCount 递增的那一层)。

**为什么保留 turn**:
- 用户按一次回车 · 期望的是"一次问答"· 中间自动 fallback 不该算成 turn 数消耗
- 用户配的 maxTurns 保险不该被 fallback 消耗掉

**技术细节:strip signature 块**

不同模型之间的 **thinking signature 不兼容**。 主模型输出的 assistant 消息里可能有:

```
{ type: 'thinking', signature: '...', thinking: '...' }
```

这个 `signature` 是**模型特定的**。 换模型再发这条历史 · 服务端会拒绝(signature 不匹配)。

**处理**:swap 前 · 扫一遍 messages · **删掉所有 signature 字段**。 用户和 LLM 视角看 · thinking 内容还在;只是元信息被剥了。

## Prompt too long —— 三级恢复

上一篇讲了 `context_window_exceeded` 的 stop_reason 处理。 但错误的另一种形式是 API 直接返 `prompt_too_long` 错误 —— 更明显、更强烈。

Claude Code 对这个错误有**三级恢复**:

**级 1 · Context collapse drain**

不是简单 compact · 是**激进压缩** —— 把老消息强行削掉一大批。 这是 feature-flag 灰度中的机制 · 详见 Context 系列 04(Compaction 六兄弟)。

**级 2 · Reactive compact**

标准的 `/compact` 流程 · 但触发原因是"被动"(reactive) —— API 已经报错了才触发 · 不是主动阈值触发。

**级 3 · 抛给用户**

前两级都失败 —— 抛 `{ reason: 'prompt_too_long' }` 给 SDK 层 · 用户看到明确错误。

**关键设计**:**这些恢复期间 · 错误对 SDK 调用方藏起来**。 用户/SDK 看不到"prompt_too_long 出现了 · 又消失了" —— 只有真的三级都失败才看到错误。

**这跟 [05](05-query-engine.md) 讲的 "错误 withhold" 哲学是一致的** —— loop 是 recovery engine · 尽可能自己恢复 · 只把无法恢复的抛出去。

## Max output tokens 的三次机会

`stop_reason === 'max_tokens'`(输出触顶)也有类似的多次恢复:

- **第一次 max_tokens**:上调 `max_tokens` 上限 · 重发
- **第二次 max_tokens**:即使上调了还是触顶 · 注入一条 `[Output token limit hit, continue]` user 消息 · 让 LLM 明确知道要接着说
- **第三次 max_tokens**:仍然触顶 · 放弃 · 抛给用户

`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`。

**跟 prompt_too_long 一样是三级恢复**。 loop 一直在给自己机会。

## 错误恢复的层次总结

一个 API 调用出错 · loop 有多少个恢复层?按由近到远:

1. **withRetry 内 · 网络/500/529 等 · 指数退避重试** —— 最多 10 次
2. **withRetry 外 · fallback model swap** —— 主模型无法恢复时换模型再试
3. **loop iteration 内 · 换模型时 signature 剥除** —— 兼容不同模型的 thinking format
4. **loop iteration 间 · prompt_too_long 三级压缩恢复** —— collapse → compact → 抛出
5. **loop iteration 间 · max_tokens 三级恢复** —— escalate → 注入 continue → 抛出
6. **loop iteration 间 · reactive_compact / stop_hook / max_output** 各自 transition —— 见 [05](05-query-engine.md)
7. **主循环 · maxTurns 硬保险** —— 前面所有恢复都不行时的最终终止
8. **主循环 · 错误 withhold 到 SDK 层** —— 只把最终无法恢复的错抛给用户

**8 层恢复叠在一起** —— 保证用户按一次回车 · loop 尽可能自己走到最终结果 · 只在无法救的时候才让用户重新介入。

## 小结

- **每次 API 调用套 withRetry** —— 最多 10 次 · 指数退避
- **是否重试听服务端的 `x-should-retry` header** —— 客户端 heuristic 只做兜底
- **退避时间听 `Retry-After` header** —— 服务端最懂什么时候恢复
- **529 overloaded 特殊** —— 非 foreground 立即失败 · 避免"重试雪崩"
- **Fallback model swap** —— 主模型无法恢复时换 fallback · turnCount 不递增 · signature 剥除
- **prompt_too_long 三级恢复** —— collapse → compact → 抛出
- **max_tokens 三级恢复** —— escalate → 注入 continue → 抛出
- **8 层恢复叠加** —— 保证 loop 尽可能自愈

下一篇 08 · Interrupt · 用户中断的处理 讲 loop 的另一头 —— 有些错误 loop 无法自愈 · 但用户可以**主动中断**。 用户按 Ctrl-C 之后 · 已经在流式返回的 LLM 请求怎么办、执行中的 tool 怎么办、messages 数组怎么保持结构合规。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/services/api/withRetry.ts` · `withRetry` 包装器 · `DEFAULT_MAX_RETRIES` · `shouldRetry`
- `src/services/api/errors.ts` · 错误分类 · `getErrorMessageIfRefusal`
- `src/query.ts` · fallback model swap 逻辑 · `attemptWithFallback` inner while
- `src/query.ts` · `truncateHeadForPTLRetry` · prompt_too_long 三级恢复
- `src/services/compact/compact.ts` · reactive-compact 触发点

**相关篇**:
- [04 · 从回答完了到 stop_reason 的 7 种含义](04-stop-reason.md) · max_tokens / refusal 触发的 recovery
- [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md) · recovery 作为 transition 一等公民
- 08 · Interrupt · 用户中断的处理 · 下一篇 · 无法自愈时用户手动介入
- [04 · Compaction 六兄弟](../context-management/04-compaction.md) · reactive-compact 详解

**Anthropic 官方**:
- [Handling errors](https://platform.claude.com/docs/en/api/errors) · `x-should-retry` / `Retry-After` header 语义
