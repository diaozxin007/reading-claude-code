前面 8 篇讲的都是**一个** loop —— 用户按一次回车、loop 转起来、跑到结束、用户接手。 一个用户对一个 loop。

但 Claude Code 里还有一种反直觉的场景 —— **loop 里嵌套 loop**。

主对话跑到某一步 · LLM 说要调 `Agent` 工具 —— 就是 "让另一个 AI 去做一件独立的事 · 只把结果告诉我"。 于是主 loop 启动一个**子代理** —— 子代理自己完整地跑一个 loop · 收工时把结果作为一条 tool_result 塞回主 loop。

从主 loop 视角看:这只是"某个 tool 跑了很久 · 返回了一段文字"。 从子代理视角看:它就是一个完整的 loop · 有自己的 messages 数组、自己的工具执行、自己的 stop_reason 判断。

这一篇讲子代理 —— 特别是一件事:**子代理走的到底是"一个新 loop 实现" · 还是"同一个 loop 换个上下文"?**

## 一个直觉错的问题

朴素设计:sub-agent 有**独立的 loop 实现** —— 一个专门的 `SubagentLoop` 类。 主 loop 用 `MainLoop`。 各自维护状态、各自处理消息数组。

**Claude Code 反其道** —— sub-agent 走的是**同一个** `queryLoop`。 一个 while true · 覆盖两种场景。

启动 sub-agent 的具体动作:

```
主 loop 遇到 Agent tool_use
    ↓
构造新的 toolUseContext
    ├─ agentId = 生成一个新 id
    ├─ messages = [] (全新)
    ├─ system prompt = subagent 的独立 prompt
    └─ 其他字段...
    ↓
递归调 queryLoop(newToolUseContext)
    ↓
sub-agent loop 跑到 completed · 返回结果
    ↓
结果作为一条 tool_result 塞回主 loop 的 messages 数组
```

**同一个函数 · 递归调用**。 主 loop 里 sub-agent 是一次 tool 调用;sub-agent 里也可以再启动 sub-sub-agent —— 就是再递归一次。

**为什么这么设计**:一份代码维护两种场景。 修一个 bug · 主线和 sub-agent 同时受益。 想加一个 recovery transition · 不用改两遍。

## `agentId` 分流

同一份代码要覆盖两种场景 —— 意味着代码里需要**区分"我是主 loop 还是 sub-agent"**。

Claude Code 的方案:一个 flag —— `toolUseContext.agentId`。

- **主 loop** —— `agentId === undefined`
- **Sub-agent** —— `agentId === '<生成的 UUID>'`

loop 里几十处判断 `if (!toolUseContext.agentId)` —— 表示 "只在主 loop 里做" 的行为:

**分流的行为**:

- **MemoryPrefetch** —— session 起手加载用户 memory · 只主 loop 做 · sub-agent 用 subagent 自己的 prompt
- **手机 UI 摘要** —— 主 loop 结束后跑一次 Haiku 摘要 · 给手机端显示 —— sub-agent 结束不摘要
- **MCP 状态清理** —— 主 loop 结束时清理 chicago MCP 连接 · sub-agent 结束不清(会影响主 loop 复用)
- **Stop hook 的重入锁** —— Stop hook 只主 loop 触发 · sub-agent 结束不触发 Stop hook
- **Cadence reminder** —— TodoWrite 提醒之类的每 10 轮触发 —— 只主 loop 记轮数
- **CLAUDE.md 加载** —— 主 loop 起手加载 CLAUDE.md · sub-agent 用 subagent-specific 的 · 不加载用户 CLAUDE.md
- **Session storage 追加消息** —— 主 loop 消息追加到主 sessionId 的 JSONL · sub-agent 追加到 subagent 独立的 JSONL

**分流的判断都是"if (!agentId)"** —— 一个 flag 覆盖十几个不同点。 简单但对代码可读性有代价 —— 读代码时要理解每个分支为什么这样。 换取的是**共享 loop 代码**的收益。

## Sidechain transcript —— 独立文件

主 loop 的消息全部落盘到:

```
~/.claude/projects/<项目名编码>/<sessionId>.jsonl
```

一行一条消息 · 每条带 `parentUuid` 指向前一条(见 [Context 02](../context-management/02-message-invariants.md))。

**Sub-agent 的消息不写这个文件**。 它写到:

```
.claude/subagents/agent-<agentId>.jsonl
```

**独立文件 · 独立追加**。

**为什么单独文件**:

- 主 loop 和 sub-agent 的消息数组是**分离**的 —— sub-agent 的消息不进主 loop
- 如果都写同一个文件 · 恢复 session 时怎么区分哪些是主 · 哪些是 sub?
- 独立文件 · **主 sessionId.jsonl 保持干净** —— 只有主 loop 消息 · 恢复时逻辑简单
- sub-agent 消息作为**调试信息**保留 · 需要时可以打开这个独立文件查看

**主 sessionId.jsonl 里 sub-agent 的痕迹**:只有主 loop 收到的**最终 tool_result**(sub-agent 的最终输出)· 用 `tool_use_id` 配对。 中间过程一律不进主 log。

## `parentUuid` 树在 sub-agent 场景怎么工作

主 loop 消息的 `parentUuid` 链构成一棵 tree —— session 起手是根 · 从 leaf 回溯就是当前对话。

Sub-agent 的消息也有 `parentUuid` 链 —— 但是**独立**的一棵树 · 存在自己的 JSONL 文件里。

**跨文件延续**:sub-agent 的消息树 · 第一条消息的 `parentUuid` 指向主 loop 里**启动 sub-agent 的那个 tool_use 消息的 uuid**。 也就是说:

```
主 tree:
  msg 1 (root)
    └── msg 2 (用户输入)
          └── msg 3 (LLM 说要调 Agent tool)
                └── msg 4 (tool_result: sub-agent 结果)

Sub tree(独立文件):
  msg S1 (parentUuid = msg 3 的 uuid)
    └── msg S2
          └── msg S3
                ...
```

**Sub tree 逻辑上挂在主 tree 的 msg 3 下面**。 如果需要"完整对话 · 包含 sub-agent 过程"—— 有工具可以把两棵树 merge。 默认只看主 tree · 干净。

## Sub-agent 权限系统清空

呼应 [01 篇](01-tool-permission.md) 那段:sub-agent 起手时 · 主 loop 里 session 级的 `alwaysAllow` 规则**清空**、只保留 CLI 参数级(不变的启动配置)· session 级换成 sub-agent 自己的 `allowedTools`。

**这背后的原理**:sub-agent 是**另一个 AI** —— 用户对主 loop 的信任(比如"总是允许 Bash")不等于对 sub-agent 的信任。 default 保守。

代价:sub-agent 内可能重复走一次权限批准。 收益:安全默认。

**这个设计的深层理由**:sub-agent 走同一个 queryLoop 代码 —— 意味着 sub-agent 天生**继承主 loop 所有能力**(包括所有工具、所有 recovery、所有 hook)。 想让 sub-agent **减少能力** · 只能靠**上下文限制**:

- **权限规则清空** —— 减少批准记忆
- **`allowedTools` 白名单** —— 明确列 sub-agent 能调什么
- **独立 CLAUDE.md** —— 覆盖用户 CLAUDE.md 里的"总是让 LLM 做 X"

这些都是**上下文层的隔离** · 不是代码层。 代码是共享的、能力是完整的 —— 但每个 sub-agent 看到的 context 是**它专属的**。

## Fork · sub-agent 的一种特殊形式

除了普通 sub-agent · Claude Code 还有一种叫 **fork** 的机制(见 [Context 06 · Sub-agent 隔离](../context-management/06-sub-agent.md) 详解)。

Fork 跟普通 sub-agent 的关键差别:

- **普通 sub-agent** —— 全新 context · 只知道 subagent-specific 的 prompt 和用户给的一条指令。 不知道主 loop 之前发生了什么
- **Fork** —— **继承主 loop 的完整消息数组** · 但所有 tool_result **替换成 placeholder**(用固定字符串 `Fork started — processing in background`)

**为什么 fork 要替换 tool_result**:因为 fork 通常是"批量启动多个类似 sub-agent"—— 每个 fork 分别处理一件事。 如果 fork 保留完整 tool_result · 每个 fork 的历史都不同 · **prompt cache 完全命中不了**(见 [Context 03 · Prompt Cache](../context-management/03-prompt-cache.md))。 换成 placeholder —— 所有 fork 的历史字节完全相同 · **cache 大命中** —— 批量 fork 的成本骤降。

**这个设计跟 loop 主题的关系**:fork 是"共享 queryLoop 代码"的极端应用 —— 一次调用 · 100 个 fork · 每个都跑一个完整 loop · 但因为历史相同 · 大部分请求命中 cache。 loop 架构支持这种批量调用不需要额外代码 —— 都是普通 sub-agent。

## Sub-agent 的中断怎么工作

上一篇讲 interrupt —— 用户 Ctrl-C 一次、`AbortController` 通知全 loop。

**Sub-agent 有独立的 AbortController 吗?**

**没有** —— sub-agent 用**主 loop 传下来的**。 主 loop 的 abort controller 通过 `toolUseContext.abortController` 传给 sub-agent。 主 loop 中断 · sub-agent 也中断。

**这是"共享 loop"设计的自然结果** —— 一个 controller 覆盖主 + sub。 用户按 Ctrl-C · 所有正在跑的 sub-agent 一起停。

**但反过来**:sub-agent 内部的错误 —— 比如 sub-agent 遇到 prompt_too_long —— **不会中断主 loop**。 sub-agent 的错误在它自己的 loop 里通过 recovery 处理(见 [07 篇](07-retry-recovery.md))· 恢复不了才作为 tool_result is_error 返回主 loop · 主 loop 决定怎么办。

**这是很好的隔离**:sub-agent 里的问题在 sub-agent 内部解决 · 不影响主 loop 的稳定性。

## 收官 · 前 8 篇的机制在 sub-agent 里都成立

因为 sub-agent 走**同一个 queryLoop** —— 前 8 篇讲的所有机制在 sub-agent 里**都成立**:

- **[01](01-tool-permission.md)** —— sub-agent 也有 tools 声明 · 也有权限批准(但规则集独立)
- **[02](02-hooks.md)** —— 大部分 hook sub-agent 也触发(除了主线程独有的比如 Stop hook)
- **[03](03-parallel-scheduling.md)** —— sub-agent 里 tool 也按 isConcurrencySafe 分批并行
- **[04](04-stop-reason.md)** —— sub-agent 也判断 stop_reason 决定继续或退出
- **[05](05-query-engine.md)** —— sub-agent 状态机 7 种 transition 一样
- **[06](06-streaming.md)** —— sub-agent 的 API 调用也是 SSE 流(不过默认不给 UI 层显示)
- **[07](07-retry-recovery.md)** —— sub-agent 也有 8 层恢复
- **[08](08-interrupt.md)** —— sub-agent 共享 AbortController · 可以被中断

**同一个 loop · 两种上下文** —— 这是 Loop 系列最后要留给读者的洞察。 loop 不是"用户跟 LLM 对话的机制" · 是**Claude Code 里"AI 自主推进任务"的通用机制** —— 用户对话、sub-agent、fork · 都是它的实例。

## 小结

- **Sub-agent 走同一个 queryLoop** —— 递归调用 · `agentId` flag 分流
- **十几处 `if (!agentId)` 分流** —— MemoryPrefetch / 摘要 / MCP / Stop hook / cadence / CLAUDE.md / storage 等
- **独立 transcript 文件** —— `.claude/subagents/agent-<id>.jsonl` · 主 sessionId.jsonl 保持干净
- **parentUuid 跨文件挂链** —— sub-tree 的根挂在主 tree 的对应 tool_use 消息下
- **权限系统清空** —— 用户对主 loop 的信任 ≠ 对 sub-agent 的信任
- **Sub-agent 上下文隔离 · 代码共享** —— 能力完整 · 但每个 sub-agent 只看到它专属的 context
- **Fork 是 sub-agent 的特殊形式** —— 继承历史但替换 tool_result 为 placeholder · 保 prompt cache
- **Sub-agent 共享主 loop 的 AbortController** —— 主中断影响 sub · sub 错误不影响主
- **前 8 篇机制在 sub-agent 里都成立** —— loop 是"AI 自主推进任务"的通用机制 · 不只是"用户对话"

## 5 条读者带走的核心洞察

Loop 系列 10 篇讲完 · 如果只让读者记住 5 件事:

**1 · Loop 是自动循环 · 中间无人参与**

用户按一次回车 · loop 自己跑到底 · 中间不问用户、不等用户 —— 除非工具需要权限批准(loop 主动停等)或用户主动打断(interrupt)。 这是 agent 和 chatbot 最根本的区别。

**2 · Loop 是状态机 · 不是简单 while**

Loop 的核心不是 5 行伪代码 · 是 7 状态 transition 的显式状态机。 每次 iteration 决定"下次要走哪条路径" —— recovery / retry / compact 都是状态机的一等分支 · 不是嵌套 try-except。

**3 · Loop 是 recovery engine · 不是 error handler**

大部分错误(max_tokens / context_exceeded / overloaded / 网络)loop 都尝试**自己恢复** —— 8 层恢复叠加 · 只有真的救不回来才抛给用户。 中间的错误对 SDK 调用方**藏起来**。

**4 · 三重"loop 无人参与"的例外互补**

Loop 自动跑不是绝对的 · 有三重能让用户重新出现的保险:
- **权限批准** —— loop 主动停 · 等用户在危险时刻拍板
- **interrupt** —— 用户主动打断 loop · 想停就停
- **maxTurns** —— 硬保险 · 无人监督也不会无限跑

三者共同保证"loop 自动跑"在任何情况下都不会失控。

**5 · Sub-agent 走同一个 loop · agentId flag 分流**

Sub-agent 不是"另一个 loop 实现" · 是**递归调用同一个 queryLoop**。 一份代码维护两种场景 —— 修 bug 处处受益。 loop 是 "AI 自主推进任务" 的**通用**机制。

## Loop 系列到此收束

到这里 · Claude Code 的 loop 讲完了:

- **00** 起点:从聊天窗口的直觉 · 到 5 行伪代码
- **01-04** loop 的"每一步做什么":tool 声明 → 权限 → hooks → 并行 → stop_reason
- **05** 统一:主循环状态机 · recovery 作为一等公民
- **06** 细节:streaming · SSE 6 事件 · 34 行手写 store
- **07** 保护:8 层错误恢复 · 让 loop 尽可能自愈
- **08** 例外:interrupt · 让用户能主动打断
- **09**(本篇) 泛化:sub-agent · 同一个 loop 覆盖多种场景

**Loop 是骨架**。 骨架撑起来后 · 上面挂的是 **信息流** —— messages 数组怎么装配、cache 怎么保、compact 怎么触发、CLAUDE.md 怎么注入。 那是姊妹系列 Context 管理研究系列 的主题。

Loop 讲清了 "事情怎么发生"。 Context 讲清 "信息怎么组织"。 两个系列合起来 · 才是 Claude Code 的完整机制图景。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/query.ts` · `queryLoop` 主循环 · 递归调用支持 sub-agent
- `src/tools/AgentTool/AgentTool.tsx` · Agent 工具 · sub-agent 启动入口
- `src/tools/AgentTool/runAgent.ts` · sub-agent 执行 · 权限清空 · 独立 storage
- `src/utils/sessionStorage.ts` · sidechain transcript 独立文件路径
- `src/tools/AgentTool/forkSubagent.ts` · fork 机制 · tool_result placeholder 替换

**相关篇**:
- [00 · 开篇 · 从聊天窗口到 loop](00-intro.md) · Loop 起点
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · sub-agent 权限清空的呼应
- [05 · QueryEngine 主循环 · 状态机全景](05-query-engine.md) · agentId flag 分流的机制
- [08 · Interrupt · 从 Ctrl-C 到合成 tool_result](08-interrupt.md) · sub-agent 共享 AbortController
- [02 · 从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md) · parentUuid tree 结构
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](../context-management/03-prompt-cache.md) · fork placeholder 保 cache
- [06 · Sub-agent 隔离](../context-management/06-sub-agent.md) · sub-agent 从 context 视角的完整讨论

**Anthropic 官方**:
- [Agent tool](https://code.claude.com/docs/en/sub-agents) · sub-agent 用户视角说明
