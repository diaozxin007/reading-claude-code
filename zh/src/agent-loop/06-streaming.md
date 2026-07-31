前面几篇讲的 "调 LLM" · 一直被当作**一个原子操作**:

```
response = call_llm(messages)
```

实际不是。 Anthropic API 用 **Server-Sent Events(SSE)**流式返回 —— LLM 一边生成 · 一边把结果**分片**发给客户端。 用户在 Claude Code 里看到文字逐字冒出来 · 不是"整段生成完再展示" · 是 SSE 分片实时流过来实时渲染。

这一篇讲流是怎么工作的:

- Anthropic API 一次响应会发多少个事件 · 分别是什么?
- Claude Code 怎么把这些碎片合并成完整的一条 assistant 消息?
- tool_use 里的 JSON 参数是 partial 发送的 —— 客户端怎么增量解析?
- UI 层怎么消费这些事件 · 让文字逐字出现?

## 一次调用 · 6 种事件

一次 LLM 调用的 SSE 流长这样(简化):

```
event: message_start           ← 一次响应开头
event: content_block_start     ← 一个 content 块开始(text 或 tool_use)
event: content_block_delta     ← 这个块的增量内容(text 逐字符 · tool_use 参数逐 JSON 片段)
event: content_block_delta     ← (可能有很多个)
event: content_block_delta
event: content_block_stop      ← 这个块结束
event: content_block_start     ← 下一个块开始
...
event: message_delta           ← 消息级 metadata 更新(stop_reason · usage 等)
event: message_stop            ← 整个响应结束
```

**共 6 种事件**:
- **`message_start`** —— 响应的元信息(id、model、role 等 · content 数组还空着)
- **`content_block_start`** —— 一个内容块开始 · 声明它的 type(`text` / `tool_use` / `thinking` 等)
- **`content_block_delta`** —— 这个块的一小段增量内容
- **`content_block_stop`** —— 这个块结束
- **`message_delta`** —— 消息级 metadata(stop_reason / usage 计数)· 通常在 message_stop 前发一次
- **`message_stop`** —— 响应结束

**关键点**:一次响应可以有**多个 content 块**。 比如:一段 text + 一个 tool_use · 就是 2 个块 · 每个块自己 start / delta / stop。

## 客户端怎么合并成一条完整消息

Claude Code 维护一个 `contentBlocks` 数组:

```
contentBlocks = []
```

按事件顺序累积:

```
event: message_start
    → 创建一条 assistant 消息骨架
      { id: '...', role: 'assistant', content: [] }

event: content_block_start (index=0, type=text)
    → contentBlocks[0] = { type: 'text', text: '' }

event: content_block_delta (index=0, delta: { type: 'text_delta', text: '我先' })
    → contentBlocks[0].text += '我先'

event: content_block_delta (index=0, delta: { type: 'text_delta', text: '读 auth.py' })
    → contentBlocks[0].text += '读 auth.py'
      # 现在 contentBlocks[0].text === '我先读 auth.py'

event: content_block_stop (index=0)
    → block 0 完成

event: content_block_start (index=1, type=tool_use, name='Read')
    → contentBlocks[1] = { type: 'tool_use', name: 'Read', input: '' }

event: content_block_delta (index=1, delta: { type: 'input_json_delta', partial_json: '{"file' })
    → contentBlocks[1].input += '{"file'

event: content_block_delta (index=1, delta: { partial_json: '_path":"auth.py"}' })
    → contentBlocks[1].input += '_path":"auth.py"}'
      # 现在 input 拼完是 '{"file_path":"auth.py"}'

event: content_block_stop (index=1)
    → block 1 完成 · JSON parse input · tool_use 就位

event: message_delta (delta: { stop_reason: 'tool_use' }, usage: {...})
    → 更新 message.stop_reason 和 usage

event: message_stop
    → 消息完成 · 追加到 messages 数组 · 进 loop 下一步
```

**核心动作**:每种事件更新 `contentBlocks[part.index]` 的具体字段。 text 走 `text += delta.text`;tool_use 走 `input += delta.partial_json`。

**为什么用 `text += ` 而不是替换** —— 因为 API 保证 delta **只增量**、不重发。 用 append 累积 · 直到 content_block_stop。

## tool_use 的 JSON 是分片发送的

`tool_use` 的 `input` 字段 —— 也就是工具参数 —— 是一个 **JSON 对象**。 但 SSE 里它是**字符串分片**流过来的:

```
delta 1: partial_json: '{"file'
delta 2: partial_json: '_path":"'
delta 3: partial_json: 'auth.py"}'
```

三片拼起来才是完整的 `{"file_path":"auth.py"}`。

**朴素做法**:等 content_block_stop 之后 · JSON 一次性 parse。

**Claude Code 的做法**:边接边解析 · 只要能从 partial JSON 里**推断出关键参数** · 就可以启动后续动作 · 不等 stop。 这是 `StreamingToolExecutor` 的做法(见 [03 · 从读文件到并行调度](03-parallel-scheduling.md))—— 让 tool 在 LLM 还在流式输出时就开始跑。

**代价**:JSON parser 必须能处理 partial 输入(比如缺 `}`)。 Claude Code 手写了一个容忍不完整 JSON 的 parser 来做这件事。

## 一个反直觉:文本 delta 里有"重发"

Anthropic SDK 有一个不那么直观的行为 —— `content_block_start` 事件里 · 如果 block 是 text 类型 · **会带一小段初始 text** · 然后**下一个 delta 事件会重复发送这段 text**。

用伪代码看:

```
event: content_block_start (block: { type: 'text', text: '你好' })
event: content_block_delta (delta: { text_delta: '你好, 我是' })   ← "你好" 又出现了!
```

如果客户端简单地 `contentBlocks[0].text = block.text` 再 `contentBlocks[0].text += delta.text` · 结果会变成 `你好你好, 我是` —— 重复了。

**Claude Code 的处理**:content_block_start 里的 text 字段**故意忽略** · 只用 delta 累积。 源码里有注释直接说这是 SDK 的一个 quirk。

**这是 SSE 集成里很典型的一类小坑** —— API 表面语义清晰 · 实际集成时总有各种非标准行为要处理。

## 一个更微妙的坑:直接 mutate 而不是 replace

一条 assistant 消息在被追加到 `messages` 数组后 · **仍然要接收后续 delta 更新**。 具体场景:

- content_block_stop 时 · Claude Code 立即把这条 assistant 消息追加到 messages(为了让 UI 尽早看到)
- 然后 · message_delta 事件到来 · 携带 stop_reason 和 usage
- Claude Code 需要把 stop_reason 和 usage 塞进**已经在 messages 数组里的那条消息**

**朴素做法**:`messages[last] = { ...messages[last], stop_reason: '...' }`(创建新对象覆盖)

**Claude Code 的做法**:**直接 mutate 原对象** —— `messages[last].message.stop_reason = '...'`。

为什么不用 replace?因为 messages 数组里的这条消息 · **已经被其他地方引用了** —— 比如"transcript 落盘队列"保存了这条消息的引用 · 准备异步 stringify 写进 JSONL。 如果用 replace · 落盘队列拿的还是旧对象 · 写进磁盘的 stop_reason 是 null。 用 mutate · 所有引用都能读到最新 stop_reason。

**这个细节暴露了一个设计选择**:Claude Code 在多个地方共享消息引用(内存数组 / UI 层 / 落盘队列)· 靠 mutate 原对象保证所有人看到同一份状态。 违反了函数式编程的直觉 · 但**换来简单可靠的引用一致性**。

## UI 层怎么消费流

UI 层怎么"知道"当前流到哪儿了、该重新渲染?

答案:**一个手写的 store**。 全部实现 34 行代码 · 提供最小接口(setState / getState / subscribe)· 没用任何流行的状态管理库。

从这个 store 消费流事件:
- 每当有新 delta · 更新 store 里"当前流式消息"的字段
- UI 组件订阅这个字段 · 有变化就重新渲染
- text 累积到哪里 · UI 就渲染到哪里

**这就是"文字逐字冒出来"的实现**。

**为什么这么简单**:CLI 场景不需要复杂的时间旅行、devtools、middleware 生态。 用一个手写 store · **依赖少、启动快、行为可控**。 是一个"够用就好 · 不引流行库"的典型选择。

## QueryGuard —— 3 状态防止并发查询

UI 层还有一个专门的**并发守卫**:

```
状态:idle / dispatching / running
- idle: 没在查询 · 可以接受新用户输入
- dispatching: 用户按了回车 · 正在把消息发出去
- running: LLM 正在流式返回中
```

用户在 running 状态又按回车会怎样?消息**入队** —— 不立即处理 · 存到一个 `commandQueue` 数组里 · 等 loop 回到 idle 时再一条一条 drain。

**为什么需要这个守卫**:
- 一次只能有一个 loop 在跑
- 用户输入不能覆盖当前 loop 的状态
- 但用户不该被"loading 转圈圈"锁住键盘

**用状态机而不是 boolean** —— 是因为需要区分"dispatching 中"和"running 中":
- dispatching 短暂几十毫秒 · 但期间 Ctrl-C 该做什么?(不是打断 loop · 是取消 dispatching)
- running 长(几秒到几十秒) · Ctrl-C 该打断当前 loop

3 状态覆盖了这两种不同的 Ctrl-C 语义 · boolean 表达不了。

## 小结

- **一次 LLM 调用是 SSE 流** —— 6 种事件:`message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop`
- **客户端用 contentBlocks 数组累积** —— text delta 走 `text +=` · tool_use delta 走 `input += partial_json`
- **tool_use 的 JSON 是分片流的** —— 可以边接边解析 · 支撑 StreamingToolExecutor 极致优化
- **两个 SDK 坑要处理**:content_block_start 的 text 字段不能 append(会重复)· 消息 mutation 而非 replace(保引用一致)
- **UI 层用 34 行手写 store** —— 不用流行状态管理库 · 依赖少行为可控
- **QueryGuard 3 状态** —— idle / dispatching / running · 覆盖不同的用户输入语义

下一篇 [07 · 重试与错误恢复](07-retry-recovery.md) 讲 loop 遇到错误时的具体恢复流程:withRetry 指数退避、`prompt_too_long` 三级恢复、fallback model swap、529 overloaded 特殊处理。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/services/api/claude.ts` · `queryModelWithStreaming` · 6 种事件的 switch
- `src/QueryEngine.ts` · SDK 层消费 stream_event
- `src/state/store.ts` · 34 行手写 store
- `src/state/AppState.tsx` · UI 组件消费 store
- `src/utils/QueryGuard.ts` · idle / dispatching / running 3 状态

**相关篇**:
- [03 · 从读文件到并行调度](03-parallel-scheduling.md) · StreamingToolExecutor 依赖流式 JSON 解析
- [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md) · 主循环里"调 LLM"这一步的展开
- [07 · 重试与错误恢复](07-retry-recovery.md) · 下一篇 · 流被截断/失败后的处理

**Anthropic 官方**:
- [Messages API — streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) · 6 种事件的官方定义
