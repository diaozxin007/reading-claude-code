前两篇讲清了 LLM 说要调工具之后 · 到工具真的执行之前的两层拦截 —— [01 权限批准](01-tool-permission.md) · [02 hooks](02-hooks.md)。 两层都通过之后 · 工具终于要**真的执行**了。

但一次 assistant 消息里 · LLM 可能声明**多个 tool_use**。 harness 面临一个决策:**同时启动全部 · 还是一个跑完再跑下一个?** 并行更快 · 但如果两个工具都要改同一个文件 · 并行反而会互相覆盖。

这一篇讲执行调度:多个 tool_use 怎么分批、哪些能并行、哪些必须串行、工具崩了怎么处理。 讨论的过程中会反复引用 Context 系列 [02 · 消息数组三条不变量](../context-management/02-message-invariants.md) 里的第二条不变量 —— **每个 tool_use 必须有对应的 tool_result** —— 因为并行调度 / 错误处理 / 中断 · 都要在维护这条不变量的前提下工作。

## 一次最简单的工具调用

从最小的例子起手:LLM 决定读一个文件。

它输出的 assistant 消息里带一个 tool_use 块:

```
{ role: 'assistant', content: [
    { type: 'text',     text: '我先看一下 auth.py' },
    { type: 'tool_use', id: 'toolu_A3f2',
                        name: 'Read',
                        input: { file_path: 'auth.py' } }
  ] }
```

tool_use 块有三个关键字段:id(这次工具调用的唯一编号 · 后面 tool_result 靠它配对)· name(调哪个工具 —— Read / Edit / Bash 等)· input(参数 · 一个 JSON 对象)。

harness 从 name 找到对应的工具实现 · 把 input 传进去执行 · 拿到结果 · 打包成 tool_result 追加到 messages:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_A3f2',
                           content: '<auth.py 的 200 行内容>' }
  ] }
```

tool_use_id 回填 · **一次工具调用的旅程闭环**。 下一次调 LLM · 这个 tool_result 会一起发过去 · LLM 就"看到"文件内容了。

## 一次可以塞多个 tool_use

LLM 可以在**同一条 assistant 消息**里声明多个 tool_use:

```
{ role: 'assistant', content: [
    { type: 'text',     text: '我并行读两个文件' },
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file: 'auth.py' } },
    { type: 'tool_use', id: 'toolu_B', name: 'Read', input: { file: 'login.py' } }
  ] }
```

这时候 harness 面临一个选择:**这两个 Read 是同时启动 · 还是一个跑完再跑下一个?**

技术上都能做:
- **同时启动**(并行):两个 Read 一起跑 · 快
- **一个跑完再跑下一个**(串行):稳 · 但慢

Claude Code 用的是**混合策略** —— 允许 LLM 声明任意多个 tool_use · **由 harness 自己决定并行还是串行**。 LLM 只负责说要调什么 · 具体怎么调是 harness 的事。

## 并行的判断依据 —— 每个 tool 自己声明

朴素做法:harness 内部维护一张表 —— `Read` 可并行、`Edit` 不可并行、`Bash` 看命令 ...

**Claude Code 反其道**:**让每个 tool 自己声明**。

每个 tool 实现一个 "我这次能不能安全并行" 的判断:

- **Read** · 只读文件 · 不改任何状态 · **永远说 "能"**
- **Grep / Glob** · 只搜索文件系统 · **永远说 "能"**
- **Edit / Write** · 会改文件 · **永远说 "不能"** —— 因为两个 Edit 并行可能改到同一个文件
- **Bash** · 视具体命令而定 —— `git status` 之类的读命令可以并行 · `rm` 之类必须串行

**判断逻辑写在每个 tool 内部** —— 因为只有 tool 自己知道自己的副作用。 这个决策**不由 LLM 声明 · 不由 harness 猜** —— 是**每个 tool 的自我声明**。

**这是一个把 "我能不能并行" 的知识**下放到 tool 自己**的设计** —— 一个 tool 加一个新命令、一个 tool 新增一个 side effect · 不用改 harness 的调度器 · tool 自己更新判断就行。

## 打 batch 的规则

harness 拿到 N 个 tool_use · 按声明顺序从头扫 · 把**连续的、都说"能"的**打成一个批 · 遇到一个说"不能"的就切断。

举例 · LLM 声明了 4 个 tool_use:

```
1. Read auth.py         → 能并行
2. Read login.py        → 能并行
3. Edit auth.py         → 不能并行
4. Read session.py      → 能并行
```

分批结果:

```
Batch 1: [Read auth.py, Read login.py]   ← 都能并行 · 打成一批
Batch 2: [Edit auth.py]                   ← 不能并行 · 单独一批
Batch 3: [Read session.py]                ← 虽然能并行 · 但被前面 unsafe 隔开 · 单独一批
```

**Batch 之间严格串行 · Batch 内部并行**。 这样保证了:

- 两个 Read 不会等来等去(Batch 1 并行)
- Edit 之前所有 Read 已经跑完(Batch 1 完 · 才走 Batch 2)
- Edit 之后的 Read 也不会看到 Edit 前的状态(Batch 2 完 · 才走 Batch 3)

**一个 batch 内的并行度有上限** —— 默认 10 个 tool 同时跑 · 更多就要排队(避免打爆本地资源)。

## 判断本身也可能崩

细节:tool 的 "我能不能并行" 判断**本身可能抛异常**。 比如 Bash 工具的判断要 parse 命令行 · 用 shell-quote 解析 —— 命令行有奇怪的引号 · parser 可能崩。

**Claude Code 的处理**:catch 一切异常 · **fallback 认为 "不能并行"**。

**设计思想**:一个 tool 的判断有 bug 时 · 系统的表现应该是**降级到最保守的策略** —— 变慢但不会错。 宁可让并行少一点 · 也不要让 unsafe 的 tool 悄悄并行了。

**这是"保守优于激进"** —— 当你不确定的时候 · 走安全那条路。 跟 [01 篇](01-tool-permission.md) 里 sub-agent 权限不继承(保守默认)是同一种设计取向。

## 更激进的优化 · 流式解析 JSON 时就启动 tool

上面讲的分批 · 是**LLM 说完一条消息**之后 · harness 才开始扫。 但从流式(见 [06 篇](06-streaming.md))的视角看 · LLM 其实是**逐帧发送**的 —— tool_use 的 name 先到、参数是**JSON 字符串分片**流过来的:

```
第 1 帧:tool_use 开始 · name = 'Read'
第 2 帧:input JSON 分片:'{"file'
第 3 帧:input JSON 分片:'_path":"'
第 4 帧:input JSON 分片:'auth.py"}'
第 5 帧:tool_use 结束
```

**朴素做法**:等第 5 帧结束 · JSON 完整 · 再启动 Read。

**Claude Code 的做法**:**边流边解析** —— 只要能提前推断关键参数(比如 file_path 完整了)· 就立即启动 Read · 不等第 5 帧。

**收益**:LLM 还在流式输出下一段 text 时 · Read 已经在读文件了 · 两段延迟并行。 一次工具调用 · Read 可能 100ms · LLM 输出下一段 text 可能 2s。 串行 · 用户看到的延迟是 2.1s;并行 · 是 max(2s, 100ms) = 2s。 累加到一次会话里几十次工具调用 · 省下来的是 5-10 秒。

**代价**:JSON 解析要能处理 partial 输入(缺 `}` 也要能推断)· harness 手写了一个容忍不完整 JSON 的 parser 做这件事。

## Tool 崩了怎么办

场景:LLM 声明 `Read /path/to/does_not_exist.py` —— 文件不存在。 或者 `Bash rm -rf /` —— 权限系统拒绝执行。

**朴素做法**:tool 抛异常 · loop 崩 · 用户看到红色 error。

**Claude Code 的做法**:**tool 永远不抛给 loop** —— 它把异常 catch 住 · 转成 `is_error: true` 的 tool_result:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_X',
                           content: '<tool_use_error>File does not exist</tool_use_error>',
                           is_error: true }
  ] }
```

**设计哲学**：工具执行失败只是 loop 的一种状态，不是会打断 loop 的异常。它会被转换成反馈交给 LLM，由 LLM 决定下一步怎么处理。

理由:
- LLM 完全有能力理解 "文件不存在" · 它下一次调用可以决定重试 · 或者 `Glob` 一下找找 · 或者放弃告诉用户
- 如果 tool 抛给 loop · loop 只能崩溃或吞掉 —— 都不如让 LLM 自己看到错误自己判断

**几种典型的 is_error 来源**:

- **Tool 内部抛异常** —— 文件不存在、权限拒绝、bash 命令 exit code 非零 —— 转 `<tool_use_error>...</tool_use_error>` 内容 · is_error: true
- **未知 tool name** —— LLM 声明了一个没实现的工具 —— 同样转 is_error · 内容为 "Tool 'XXX' not found"
- **用户中断** —— Ctrl-C 见 [08 篇](08-interrupt.md) —— 合成 content: 'Interrupted by user' · is_error: true
- **修补出的假 tool_result** —— content: '[Tool result missing due to internal error]' · is_error: true

**is_error 是一个显式信号** —— 告诉 LLM "这一次工具执行没成功"。 LLM 训练时学过这个字段 · 看到 is_error 会自动进入"我需要处理这个错误"的状态。

## 配对不变量的最高维护者

上面的两个设计合起来 —— **tool 崩了转 is_error 不抛** + **未知 tool name 也转 is_error** —— 结果是:

**只要 LLM 声明了一个 tool_use · 无论后续发生什么 · 一定有一条对应的 tool_result 生成**。

这是 tool 系统对 [Context 02 · 消息数组三条不变量](../context-management/02-message-invariants.md) 中第二条不变量 "tool_use 必配对 tool_result" 的**最强守护**:

- Tool 崩了 · 有 is_error 的 tool_result
- Tool 找不到 · 有 is_error 的 tool_result
- 用户中断 · 有 is_error 的 tool_result

Tool 执行**不会**留下 orphan tool_use。 配对不变量的破坏只能来自更外层的机制(compact 压缩把 tool_use 那条 assistant 消息压掉、rewind 截断消息数组)· 那些破坏由 Context 系列 04 篇讲的**消息修补机制**兜底。

**tool 系统守自己那一段 · 上层机制守跨越自己的破坏** —— 分层清晰。

## 小结

- **一次工具调用**:LLM 输出 tool_use → harness 分派到实现 → 执行 → 打包 tool_result 追加
- **一次可能多个 tool_use** —— harness 决定并行还是串行 · LLM 不管
- **每个 tool 自我声明能否并行** —— tool 内部的知识 · 不是 harness 猜
- **打 batch 规则**:连续 safe 打一批并行 · unsafe 单独切断 · 保持声明顺序
- **判断本身也可能崩** —— fallback 保守走串行(降级到最保守)
- **流式解析 JSON 时就启动 tool** —— 让 tool 延迟和 LLM 输出延迟并行 · 一次会话省几秒到十几秒
- **Tool 崩了转 is_error tool_result** —— 工具错误是给 LLM 的反馈 · 不是给 loop 的异常
- **tool 系统守配对不变量的**最强守护 —— 只要 LLM 声明了 tool_use · 就一定有 tool_result

下一篇 [04 · 从回答完了到 stop_reason 的 7 种含义](04-stop-reason.md) 讲 loop 的另一头 —— tool 执行完 tool_result 回填后、又调一次 LLM、LLM 什么时候算"说完了"。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/services/tools/toolOrchestration.ts` · `runTools` 主流程 · `runToolsSerially` / `runToolsConcurrently` 分批
- `src/services/tools/toolOrchestration.ts` · `isConcurrencySafe` 接口 · `partitionToolCalls` 打 batch 逻辑
- `src/query.ts` · `StreamingToolExecutor` · 流式 JSON 解析下的 tool 预启动
- `src/services/tools/toolExecution.ts` · 单次 tool 执行 · 崩异常转 is_error tool_result 的封装

**相关篇**:
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · tool 执行前的权限拦截
- [02 · Hooks · loop 上的可编程干预点](02-hooks.md) · tool 执行前后的 hook
- [04 · 从回答完了到 stop_reason 的 7 种含义](04-stop-reason.md) · 下一篇 · tool 执行完后 loop 怎么判断继续
- [06 · Streaming · 从 SSE 事件到逐字显示](06-streaming.md) · 流式 JSON 解析的完整机制
- [08 · Interrupt · 从 Ctrl-C 到合成 tool_result](08-interrupt.md) · 用户中断时合成 is_error tool_result
- [02 · 从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md) · 配对不变量的定义

**Anthropic 官方**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) · tool_use / tool_result 的 API 约定
