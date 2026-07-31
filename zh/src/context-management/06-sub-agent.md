> 本系列第 06 篇 · 承接前 5 篇打下的 messages 数组 / cache / compaction / CLAUDE.md 家族的底盘 —— 讲 Claude Code 在**同一进程内起多个 loop** 时 · context 是怎么隔离的。
>
> 姊妹系列 [Loop 09](../agent-loop/09-sidechain.md) 讲的是**执行流视角** —— sub-agent 走同一个 queryLoop · 用 `agentId` flag 分流。 本篇是**context 视角** —— sub-agent 的 messages 数组从哪来 · 怎么装配 · 结束后怎么把结果搬回主 loop · 中间踩过哪些坑。
>
> 两篇讲同一件事物的不同侧面 · 按需读。

## 起手 · 主 loop 遇到一件"探索性"活

假设你在 Claude Code 里问:"帮我看一下这个 monorepo 里所有用 `useMemo` 的 React 组件 · 有哪些用错了依赖数组的?"

一个直觉的解法:主 loop 直接开干 —— grep 一遍全仓库 · 拿到 100 多个候选文件 · 一个个 Read · 一个个分析。

**这条路径的问题不在能不能做完 · 在做完之后主 context 里有什么**:

- 100 次 grep 结果全在 messages 数组里
- 100 次 Read 的文件内容全在 messages 数组里
- 100 次分析的中间推理全在 messages 数组里
- 用户下一轮问完全不相关的问题 · 主 loop 还要背着这 100 个文件的记忆走

主 context 一次性被"探索性任务"撑爆 · 后面无论压缩多少次 · 都在处理这场探索留下的**污染**。

**Sub-agent 是给这类场景的解法** —— 主 loop 说 "开一个新 AI · 让它独立探索 · 探索完只把结论告诉我"。 100 个文件的读、分析、reasoning 全在**另一个 loop** 里发生 · 主 loop 只拿到一段结论文字。

从主 loop 的 messages 数组看:整场探索只留下**一条 tool_result**(那段结论)。 前后 messages 前缀完全稳定 —— 主 loop 的 cache 一点都没被这场探索破坏。

这就是 Anthropic 官方 4 大策略里的**"sub-agent decomposition"** —— 从 context 视角看 · 它本质是**用一个隔离的 messages 数组 · 换取主 messages 数组的干净**。

## 1 · Agent tool 独立 context —— 沙箱是怎么起的

主 loop 里 · sub-agent 是通过一个叫 `Agent` 的工具启动的(线上名字叫 Agent · 保留别名 Task —— 后面提到 "Task 家族" 说的是另一批东西 · 后文详述)。

调 Agent tool 时 · 主 loop 传三个参数:

1. **`subagent_type`** —— 挑一个 sub-agent 预设(比如 `general-purpose` / `code-reviewer`)
2. **`prompt`** —— 一句给 sub-agent 的具体指令
3. **`description`** —— 一句总结(只用于 UI 显示)

然后主 loop **递归调 queryLoop**(见 [Loop 09](../agent-loop/09-sidechain.md))—— 但传给 sub-agent 的 `toolUseContext` 里 · **messages 数组是空的**。

**Sub-agent 起手时 messages 数组的形态**:

```
[
  { role: 'user', content: <用户给的一句 prompt> }
]
```

**就一条**。 没有主 loop 的历史 · 没有之前跑过的工具、读过的文件、思考的过程。

system prompt 也是**全新构造**的:

- 主 loop 的 system prompt 里放 Claude Code 主 agent 的所有介绍 / 用户 CLAUDE.md 相关的东西
- Sub-agent 的 system prompt 是 **subagent-definition 的 Markdown body + 一段默认的 sub-agent 通用前言**
- **不带用户全局 CLAUDE.md** · 不带项目 CLAUDE.md —— 后者是主 loop prependUserContext 的行为(见 [05 篇](05-claude-md-family.md))· sub-agent 走另一条路径

**这个设计的目的**:让 sub-agent **只关注它被交办的一件事**。 主 loop 的历史、CLAUDE.md 里的项目约定、之前的对话上下文 —— 对 sub-agent 全是干扰。 沙箱越小越好。

## 2 · Sub-agent 结束之后 · 主 loop 拿到什么

Sub-agent 自己完整跑一个 loop —— 有自己的 tool 调用、自己的 stop_reason 判断、自己的 recovery。 跑到 `end_turn` 或者用户设定的 stop 条件 · 结束。

结束时 · Agent tool 从 sub-agent 最后一条 assistant 消息里**提取最后一段文本** —— 只这一段 —— 作为 tool_result 的内容返回主 loop。

主 loop 看到的 tool_result 结构大致是:

```
<最后一段 assistant 文本 · 通常是 sub-agent 的结论>

<usage>
  total_tokens: 88551
  tool_uses: 47
  duration_ms: 42311
</usage>
```

**usage 那个 XML 块** —— 就是主 loop 里能看到的 `subagent_tokens: N` 的来源。 主 loop 不知道 sub-agent 内部 messages 数组长什么样 · 只知道**总 token 数、总工具调用次数、总耗时**。

**反直觉**:sub-agent 的中间过程 · 主 loop 一律看不到。 主 loop 想追问"你怎么得出这个结论的" —— 只能通过 sub-agent 给出的文字结论倒推 · 拿不到中间的 tool_use / tool_result 序列。

**这是刻意的**:sub-agent 是"摘要生成器" —— 主 loop 只吃摘要 · 中间过程属于**沙箱内部**。 如果让主 loop 看到全部中间过程 · 那就跟"主 loop 直接干"没区别了。 隔离的价值就没了。

## 3 · Fork 是唯一的例外 —— 继承 parent 但抹掉 tool_result

上面讲的是**默认 sub-agent**:全新 context · 只带一句用户 prompt。

**Claude Code 里还有一种叫 fork 的启动模式** —— 触发条件是 `subagent_type` 空 + `feature('FORK_SUBAGENT')` 启用(灰度中 · 不是所有 build 都开)。

Fork 的关键差别:**继承 parent 的完整 messages 数组**。

但反直觉:**它继承的是"messages 数组结构" · 不是"messages 数组内容"**。 具体说:parent 里每一个 tool_result 块 · 在 fork 的 messages 数组里 · 都被**替换成同一句固定字符串**:

> `Fork started — processing in background`

**为什么这么设计**:

- 假设一场对话里 fork 100 次(比如批量处理 100 个 URL) · 每个 fork 都要跑一个独立 loop
- 如果每个 fork 都带着 parent 的真实 tool_result —— 每个 fork 的历史前缀都不同 —— cache 完全命中不了 —— 100 次都是 cache write —— 成本爆炸
- 换成 placeholder:所有 100 个 fork 的 messages 前缀**字节完全相同** —— 第一个 fork 建 cache · 剩下 99 个全命中

这是把 [03 篇](03-prompt-cache.md)"cache 静态 ≠ 语义静态"心法做到极致的案例 —— fork 语义上想让子代理"知道 parent 之前跑过什么工具" · 但只保留"结构上跑过一个工具"、把真实 tool_result 抹平 · 换来大 cache 命中率。

Sub-agent 收到的 fork 版历史长这样:

```
[
  ...parent 的所有 user / assistant 消息(原样)...,
  { role: 'user', content: '<给 fork 的具体指令>' }
]
```

每条 assistant 消息里的 tool_use 块保留 · 但配对的 tool_result 全是那句 placeholder。 结构对 · 内容抹 —— 这是 fork 的核心工艺。

## 4 · Worktree 隔离 —— 主进程内多个 cwd 并存

Sub-agent 除了 context 隔离 · 还可以选**文件系统层的隔离** —— 通过 `isolation: worktree` 参数指定。

启用之后:

- Claude Code 起手用 `git worktree add` 建一个新 worktree · 位置在 `.claude/worktrees/agent-<agentId 前 8 位>`
- Sub-agent 的 cwd 就是这个 worktree —— 它的 Read / Write / Bash 都在这里执行
- Sub-agent 结束后 · 用 `git worktree remove --force` + `git branch -D` 清理

**读到这里读者会想**:主进程里同时跑多个 sub-agent(比如 fork 出 5 个) · 每个 sub-agent 都要有独立 cwd —— 这在 Node.js 里怎么实现?

**朴素方案**:每个 sub-agent `process.chdir()` 一下。 但 chdir 是**进程级**的 —— 全进程共享一个 cwd —— 一个 sub-agent 改了 cwd · 所有其他 sub-agent 和主 loop 都跟着变。 完全不能用。

**Claude Code 的方案**:**AsyncLocalStorage** —— Node.js 的一个 API · 允许在**异步调用链**里维护"局部变量" · 每条调用链看到的值不同。

具体形态:

```
主 loop 的 async 调用链  ─→  ALS 里 cwd = /project (原始)
Sub-agent A 的调用链    ─→  ALS 里 cwd = /project/.claude/worktrees/agent-abc12345
Sub-agent B 的调用链    ─→  ALS 里 cwd = /project/.claude/worktrees/agent-def67890
```

所有 tool 的 cwd 都从 `AsyncLocalStorage.getStore()` 读 —— **不是**从 `process.cwd()` 读。 因此同一进程内可以有几十个 sub-agent · 每个都以为自己有独立 cwd · 互不干扰。

**这是一个通常在服务器框架(比如 request-scoped context)里才见的技巧** —— 用在 CLI 里是 Claude Code 的工程亮点。

## 5 · Task 家族 —— 两个"task"共存于同一个词

Claude Code 里有**两个完全不同的 task store** · 名字都叫 task · 读者极易混淆。

| Store | 用途 | 存储位置 | 常见工具 |
|---|---|---|---|
| **Todo v2 · 磁盘** | 用户的 TODO 列表 · 类似待办清单 | `~/.claude/tasks/<listId>/<taskId>.json` | TaskCreate / TaskGet / TaskList / TaskUpdate |
| **Running-task 注册表 · 内存** | 后台跑的 bash / 已启动的 sub-agent | `AppState.tasks` · Map · 键有前缀 | TaskOutput / TaskStop |

Running-task 注册表的键有前缀 —— 一个字母告诉你这条 task 是什么类型:

- `b` —— Bash(background bash 任务)
- `a` —— Agent(启动过的 sub-agent)
- `r` —— Remote(远端跑的任务)
- `t` —— Teammate(team 里的其他 agent)
- `w` —— Workflow
- `m` —— Monitor(长任务监听)
- `d` —— Dream(实验性)

**这两个 store 在词汇上碰撞**但**行为上不相关**:

- Todo v2 是**给用户显示的** · session 结束后仍在磁盘 · 下次可以继续
- Running-task 是**给 harness 用来跟踪运行中的东西** · 进程结束就没了

一句话:**Todo v2 是笔记本** · **Running-task 是进程表**。 名字碰撞是历史包袱 · 内部实际是两回事。

## 6 · TaskOutput 已 deprecated —— 指引改用 Read

Running-task 注册表里的每一条 task · 都对应一个磁盘上的 `.output` 文件 —— 存这个 task 的输出。

历史上有一个 `TaskOutput` 工具 · 给主 loop 用来读某个 running-task 的输出。 但在当前 build 里:

- `TaskOutput` 的 tool 描述里明确写 `[Deprecated] — prefer Read on the task output file path`
- `isEnabled()` 返回 false —— 除非 `"external" === 'ant'` 的编译时常量成立
- 这个字面量对比永远 false · Terser 会把这个分支 dead-code 消除

**换句话说 · 开源/泄露版里 TaskOutput 是关的**。 主 loop 被引导直接用 **Read 工具**打开 `.output` 文件。

**读者到这里会想**:那 Read 一下 `.output` 就是最终答案了 —— 那 Deprecated 就 Deprecated 呗。

**但 · `.output` 里藏着一个陷阱**。

## 7 · `.output` 符号链陷阱 —— 读了会炸 context

`.output` 文件对不同类型的 task 有**完全不同的形态**:

### 对 local_bash task

`.output` 就是**真实的字节文件** —— 存 bash 进程的 stdout 和 stderr。 Read 一下 · 就是你想看的日志。

打开的时候还用 `O_NOFOLLOW` 标志 —— 拒绝解引用符号链接 —— 保证读到的是真实字节 · 不会因为符号链攻击读到别的地方。

### 对 local_agent task

`.output` **不是字节文件** —— 是一个**符号链接**。 指向:

```
.claude/subagents/<subdir>/agent-<agentId>.jsonl
```

而 `agent-<agentId>.jsonl` 是 sub-agent 的 **full sidechain transcript** —— **完整对话历史** —— 每一条 user / assistant / tool_use / tool_result 消息都在里面 · 每条都可能有几 KB · 一个跑了 100 轮的 sub-agent 的 JSONL 可能是几 MB 级别。

**如果主 loop Read 了这个 `.output`**:

- Read 工具默认读 2000 行 —— 但 JSONL 每一行都是一条完整消息 —— 2000 行等于 2000 条消息的完整字节
- 全塞进主 loop 的 messages 数组
- 主 loop 的 context 瞬间被 sub-agent 的完整对话历史撑爆 —— 甚至可能一次超过 200K
- 而这一切 sub-agent 都已经**用一段结论文字**告诉主 loop 了 —— Read 只是把主 loop 之前特意用沙箱避免的污染 · 再全部搬回主 loop

**这就是本 session 环境里 output_file 相关 system-reminder 警告的来龙去脉** —— harness 层试图提醒模型"这条 task 的 `.output` 是 agent 类型 · 不要 Read"。

反直觉:同一个文件名 `.output` · **对 bash task 是字节 · 对 agent task 是符号链到完整对话** —— Read 前必须先判断 task 类型。

## 8 · SendMessage —— 跨 agent 的邮箱系统

上面讲的是 parent → sub-agent 的单向启动关系。 Claude Code 里还有另一种 sub-agent 场景 —— **多个 sub-agent 并行跑 · 需要互相通信**。

例如:一个 "researcher" agent 找信息 · 一个 "reviewer" agent 审 · 两个都还在跑 —— reviewer 想问 researcher "你查到 X 没?"。

这种跨 agent 通信走的是 `SendMessage` 工具 · 底层是**文件基邮箱系统**。

**关键设计**:邮箱**不在内存** —— 落盘在 `~/.claude/teams/<teamName>/config.json`。 team 的 members 列表也在这里 —— agentName 映射到 agentId · 也存 tmuxPaneId 和 backendType(local / remote / teammate)。

发送流程分两路:

- **Local delivery**(收件人在同一进程) —— 直接进对方的 `pendingMessages[]` 队列(挂在 `LocalAgentTaskState` 上)· 对方 loop 下一轮 iteration 时消费
- **Team delivery**(收件人在别的进程 / 别的机器) —— 写团队目录邮箱文件 · 对方轮询这个文件

**为什么用文件基而非内存**:因为 team 场景 · 收件人可能是**另一台机器**上跑的 Claude Code。 用文件目录做邮箱 —— 甚至可以放到网络共享盘上 —— 是最简单的跨进程 / 跨机器通信协议。

**Members 列表也是文件基**:sub-agent 加入 team 时 · 写 members 表;退出时删。 team 的成员关系跟 agent 生命周期解耦 —— 一个 agent 挂了 · team 结构不变。

## 9 · Workflow tool 目前是名字 stub

Task 家族里还有一个叫 `workflow` 的工具 —— 但在当前 build 里 · 它**只有一个名字常量** —— 没有实体实现。 需要 `feature('WORKFLOW_SCRIPTS')` gate 才能激活 · 目前未 shipped。

**为什么留个名字 stub**:预留一个 tool 名字空间 · 让上层 UI / SDK / 官方文档可以先按 "有这个工具" 写起来 · 等实体做完再切换 —— 一次 API 稳定性投资。

读者遇到 `workflow` 这个名字 · 记得"它现在没实体"就好。

## 10 · 隔离的边界 —— 什么隔离 · 什么不隔离

前面讲的所有机制加起来 · 构成 sub-agent 的隔离保证。 但这个隔离**不是完全隔离** —— 明白边界很重要。

### 隔离的

- **Context** —— messages 数组独立(默认全新 / fork 特殊)
- **cwd** —— AsyncLocalStorage 隔离 · 主进程内多 agent 各自独立 cwd
- **权限系统 session 级** —— sub-agent 起手时 · 主 loop 的 session-level `alwaysAllow` 规则清空 · 换成 sub-agent 自己的 `allowedTools`(见 [Loop 01](../agent-loop/01-tool-permission.md))
- **Transcript** —— sub-agent 的消息落 `.claude/subagents/agent-<id>.jsonl` · 主 sessionId.jsonl 保持干净(见 [Loop 09](../agent-loop/09-sidechain.md))
- **Skill 状态** —— skill 调用状态按 `agentId` 分键存储 · parent 和 child 用 disjoint 键空间 —— sub-agent 退出时清空自己那份
- **CLAUDE.md 加载** —— sub-agent 不加载用户 CLAUDE.md · 用 subagent-specific 的 prompt

### 不隔离的

- **文件系统** —— sub-agent 能读 parent Write 的任何文件 · 没有 sandbox 层。 想真的文件系统隔离 · 得靠 `isolation: worktree`
- **进程内共享状态** —— 除了 cwd 走 AsyncLocalStorage · 其他一些进程级 shell 状态(比如环境变量、真实 process.cwd)是共享的
- **API key / rate limit** —— 全都是同一个用户账号 · 主 loop 花的 quota 和 sub-agent 花的 quota 算在一起
- **AbortController** —— sub-agent 不新起 · **共享 parent 的** —— 用户 Ctrl-C 一次 · 主 loop + 所有 sub-agent 一起停

**这个"部分隔离 · 部分共享"是刻意的**:

- **隔离的是 context 层的东西** —— 因为 context 是决定 LLM 看什么的核心 · 也是主 loop 想通过 sub-agent 保护的东西
- **共享的是资源层的东西** —— 文件系统、进程资源、AbortController —— 因为这些如果也隔离 · 要付大量额外机制成本 · 收益跟不上

## 11 · 姊妹系列 Loop 09 讲的是同一件事的另一面

[Loop 09](../agent-loop/09-sidechain.md) 讲的是**执行流视角** —— 关注 "sub-agent 走同一个 queryLoop · 一个 flag 分流"。

那一篇的重点:

- Sub-agent 不是新 loop 实现 —— 是同一个 queryLoop 递归调用
- 十几处 `if (!agentId)` 分流(MemoryPrefetch / MCP / Stop hook / cadence 等)
- sub-agent 共享主 loop 的 AbortController
- Sub-agent 的 parentUuid 树跨文件挂链

**本篇讲的是 context 视角** —— 关注 "sub-agent 的 messages 数组从哪来 / 装什么 / 结束时怎么把结果搬回主 loop":

- messages 数组默认全新 · 只带一句用户 prompt
- Fork 是唯一继承 parent 的例外 —— 但抹掉 tool_result 保 cache
- Agent tool 结束时提取 last assistant text + usage · 塞回主 loop 的 tool_result
- `.output` 对 agent task 是符号链到完整 sidechain —— 读了炸 context
- SendMessage 走文件基邮箱

**两篇合起来才是完整的 sub-agent 图景** —— 执行流讲代码怎么复用一份 loop · context 视角讲上下文怎么保持隔离。

## 12 · 小结

- **Sub-agent 是"用一个隔离的 messages 数组换主 messages 数组的干净"** —— 100 次探索的所有中间过程都在沙箱里 · 主 loop 只拿一段结论
- **默认 sub-agent 起手 messages 数组只有一条**(用户给的 prompt) · system prompt 是 subagent-definition 的 markdown body · 不带用户 CLAUDE.md
- **Fork 是唯一继承 parent 历史的例外** —— 但每个 tool_result 被替换成同一句 placeholder · 保证 100 次 fork 的 messages 前缀字节相同 · 大 cache 命中
- **Worktree 隔离靠 AsyncLocalStorage** —— 主进程内多个 sub-agent 各自看到独立 cwd · 而非 process.chdir 全进程共享
- **Task 家族 2 个 store 词汇碰撞** —— Todo v2 是磁盘上的用户 TODO 清单 · Running-task 是内存里的进程注册表 · 内部无关
- **TaskOutput 已 deprecated** —— 主 loop 被指引直接 Read `.output` · 但要区分 task 类型
- **`.output` 对 bash task 是字节文件 · 对 agent task 是符号链到 sidechain JSONL** —— Read 后者会把 sub-agent 完整对话历史搬回主 loop · 主 context 瞬间炸
- **SendMessage 邮箱是文件基** —— 存在 `~/.claude/teams/<teamName>/` · 支持跨进程 / 跨机器通信
- **隔离保证有边界** —— context / cwd / 权限 / transcript / skill 状态 / CLAUDE.md 都隔离 · 文件系统 / AbortController / API quota 共享
- **姊妹系列 Loop 09 讲执行流层的 sub-agent** —— 本篇讲 context 层 —— 合起来才完整

一句话:**sub-agent 不是"让另一个 AI 帮忙"这么简单** —— 从 context 视角看 · 它是一整套"沙箱起手 / 独立跑 / 结论回传 / 中间过程留在沙箱里不污染主 loop" 的隔离协议 —— 每一个细节都在维护"主 messages 数组的干净"这个不变量。

---

## 参考

**Anthropic 官方**:
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · sub-agent decomposition 是 4 大策略之一
- [Sub-agents · Claude Code docs](https://code.claude.com/docs/en/subagents) · 官方 sub-agent 使用文档

**Claude Code 源码定位**(v2.1.220):
- Agent tool 主入口:`src/tools/AgentTool/AgentTool.tsx`
- Sub-agent system prompt 构造:`getSystemPrompt` in AgentTool
- 结果提取:`finalizeAgentTool` in `agentToolUtils.ts`
- Fork placeholder:`src/tools/AgentTool/forkSubagent.ts` · `FORK_PLACEHOLDER_RESULT`
- Fork 触发 gate:`feature('FORK_SUBAGENT')`
- Worktree 建立:`src/utils/worktree.ts` · `git worktree add`
- cwd 隔离:`src/utils/cwd.ts` · AsyncLocalStorage
- 遗留 worktree 清扫:`cleanupStaleAgentWorktrees` · 30 天
- Todo v2:`src/utils/tasks.ts` · `~/.claude/tasks/`
- Running-task registry:`src/tools/Task.ts` · `AppState.tasks` · 键前缀
- TaskOutput deprecated:`src/tools/TaskOutputTool.tsx` · `isEnabled()` false
- `.output` 符号链:`src/tools/AgentTool/LocalAgentTask.tsx`
- Bash `.output` O_NOFOLLOW:`src/tools/BashTool/diskOutput.ts`
- SendMessage:`src/tools/SendMessageTool.ts` · `queuePendingMessage` / `writeToMailbox`
- Team config:`src/utils/swarm/teamHelpers.ts` · `~/.claude/teams/<teamName>/config.json`
- Workflow stub:`src/tools/WorkflowTool/constants.ts` · `WORKFLOW_TOOL_NAME`
- Skill 状态按 agentId 隔离:`src/utils/skills/state.ts` · `${agentId ?? ''}:${skillName}`

**Vault 内相关笔记**:
- [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) · 4 策略总账
- [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) · messages 数组基础
- [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) · 消息结构
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) · fork placeholder 的 cache 视角解释
- [09 · Sidechain · 从子代理到 agentId 分流](../agent-loop/09-sidechain.md) · 姊妹系列 · 执行流视角
- [01 · 从 tool 声明到执行前的批准](../agent-loop/01-tool-permission.md) · sub-agent 权限系统清空
- 读书笔记/Claude code tools 研究系列/Claude code tools 研究系列（九）Agent · Agent tool 早期笔记
