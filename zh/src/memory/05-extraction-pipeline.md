# 05 · Memory extraction pipeline · 从一轮结束到受限 fork

> **TL;DR**:`extractMemories` 是每个完整主轮结束时可能启动的后台 fork。它继承主会话的稳定前缀来吃 prompt cache,但权限被收窄到读取、只读 shell 与 memory 目录内写入;最多 5 turns。游标确保只处理新增消息,写入检测避免和主 agent 重复,尾随运行合并并发触发,失败则保留游标等待下一次补偿。

上一篇 [04 · Subagent memory · 从 agent type 到三层持久目录](04-subagent-memory.md) 讲的是一个专业 agent 怎样跨运行保留经验。本篇解剖一个具体 subagent:`extractMemories`。它不是用户显式创建的 agent,而是 harness 在主轮结束时派出的后台整理员。

## 触发点 · 不是“退出时抽取”

源码注释给出了精确定义:当模型给出没有 tool call 的最终响应、一次完整 query loop 结束时,`handleStopHooks` 启动提取。主线程不等待它,交互响应不会被记忆整理阻塞。见 `services/extractMemories/extractMemories.ts:1-13`、`query/stopHooks.ts:141-153`。

它还要通过多层门控:

- 只在主 agent 运行,subagent 的 stop hook 不触发;
- auto memory 必须开启;
- remote mode 跳过;
- `EXTRACT_MEMORIES` build feature 与运行时 gate 都要开启;
- `--bare` 跳过后台 bookkeeping;
- 可用频率由远程值控制,默认每个 eligible turn 一次。

见 `services/extractMemories/extractMemories.ts:374-386,527-566`。

因此“每轮结束”是候选时机,不是无条件承诺。

## perfect fork · 为什么不从空白 agent 开始

提取 agent 需要理解“最近这些对话里什么值得长期保存”。如果只把最后几句话交给一个 fresh agent,它会失去用户角色、项目背景和这次纠正的前因。源码选择 `runForkedAgent`:system prompt、tool schemas、历史消息前缀与 parent 对齐,只在尾部追加 extraction prompt。

这同时解决成本问题。完全相同的请求前缀可以命中 parent 的 prompt cache;若为了安全给 fork 换一套工具声明,tools 段变化会提前打断 cache。于是代码保留 REPL 等声明,再在 `canUseTool` 层逐次拦截实际动作。见 `services/extractMemories/extractMemories.ts:171-180,371-427`。

## 权限笼子 · 能理解历史,不能继续干活

提取器允许:

- Read / Grep / Glob;
- 被 BashTool 判定为只读的 shell;
- 只对 auto-memory 目录执行 Edit / Write;
- REPL 外壳,但内部 primitive 仍重新走相同权限判断。

它拒绝 Agent、MCP、可写 Bash 以及 memory 目录之外的文件修改。prompt 还明确要求不要 grep 源码、不要跑 git、不要验证对话内容,只从最近 N 条消息提取。见 `services/extractMemories/extractMemories.ts:150-221`、`services/extractMemories/prompts.ts:29-43`。

这是一个典型的“声明保持 cache-safe · 执行权限另收口”设计。

## 两轮理想路径 · 最多五轮

启动前,harness 已扫描 memory 目录并生成 manifest:

```text
- [feedback] feedback-testing.md (timestamp): real database policy
- [user] user-role.md (timestamp): senior backend engineer
```

于是 agent 不必先 `ls`。prompt 推荐的理想节奏是:

1. 并行 Read 所有可能更新的文件;
2. 并行 Edit / Write;

正常提取预计 2–4 turns,硬上限是 5。Edit 要求先读同一文件,所以这个调度同时满足文件状态约束与 turn 预算。见 `services/extractMemories/prompts.ts:29-43`、`services/extractMemories/extractMemories.ts:395-427`。

## 游标 · 每条消息只进入一个提取区间

闭包保存 `lastMemoryMessageUuid`。每次运行计算游标之后 model-visible 的 user/assistant 消息数;progress、system、attachment 不计入。如果 compaction 已把游标对应消息剪掉,计数器回退到全部可见消息,而不是返回 0 永久停摆。见 `services/extractMemories/extractMemories.ts:74-110`。

成功后才推进游标。若 fork 报错,游标保持原位,下次可重新处理。这让失败成为 at-least-once 式重试;重复风险则交给 manifest 和“优先更新已有文件”的 prompt 约束降低。

## 和主 agent 的互斥

主 agent 本轮若已对 auto-memory 路径发出 Edit/Write,后台 agent 直接跳过并推进游标。注意检测对象是 assistant 的 tool_use,不是等文件系统 watcher 猜测写入结果。见 `services/extractMemories/extractMemories.ts:112-148,345-359`。

这形成一条明确优先级:

```text
主 agent 显式记忆 > 后台提取补漏
```

用户明确要求记住时无需等后台;后台只负责主 agent 没抓住的沉淀机会。

## 并发触发 · 只保留最新快照

如果上一轮提取还没结束,新一轮又完成了,源码不会并行启动第二个写入者。它把最新 context 放进 `pendingContext`;更晚的触发覆盖更早的 pending,因为最新 context 已包含更多消息。当前提取结束后,finally 里立即跑一次 trailing extraction。

trailing run 跳过频率 throttle,并基于刚推进的游标只处理新增区间。见 `services/extractMemories/extractMemories.ts:312-325,503-520,554-566`。

这是一种 single-flight + latest-wins 合并:

```text
run A 进行中
  B 到达 → stash B
  C 到达 → 用 C 覆盖 B
run A 完成
  → 从 A 的新游标到 C 的末尾跑一次 trailing run
```

B 没有丢,它已包含在 C 的完整 context 中。

## 写完以后怎样回到主界面

fork 的 transcript 不落盘,避免后台消息与主线程 transcript 竞争。运行结束后,harness 从 assistant tool_use 中提取 Edit/Write 路径,过滤掉机械更新的 `MEMORY.md`,只把 topic 文件计为真正保存的 memories。如果有结果,构造 memory-saved system message 交给 `appendSystemMessage`;启用 team memory 时另带 team 数量。见 `services/extractMemories/extractMemories.ts:415-496`。

因此主 agent 不会吞下整个 fork 对话,只收到“哪些记忆文件已保存”的小型元事件。

## 非交互模式为什么要 drain

交互 TUI 可以让后台任务继续跑;一次性 `--print` 输出后进程马上退出。print 路径先把最终答案写到 stdout,再 `drainPendingExtraction()` 等待 in-flight promise,最后 graceful shutdown。默认 drain 最多等 60 秒。见 `services/extractMemories/extractMemories.ts:579-586`、`cli/print.ts:959-969`。

这实现了一个细节:记忆抽取可以延迟进程退出,却不增加用户看到答案的首字延迟。

## 决策 · 反模式 · 演进信号

### 决策

- perfect fork 保留理解所需历史并复用 cache。
- 工具声明保持不变,执行权限用 `canUseTool` 收窄。
- 游标成功后推进 · 失败不推进,换取可补偿性。
- single-flight + latest-wins 避免两个后台 agent 并发写同一目录。

### 反模式

- 把提取放进主响应关键路径 · 用户每轮都要等整理完成。
- 给 fork 一套更小 tool schema · 安全看似更直观,却破坏共享 cache 前缀。
- 允许提取 agent 验证代码与 git · 它会把 turn 花在可推导事实上。
- 失败也推进游标 · 一次临时错误会永久丢失候选记忆。

### 演进信号

- 经常打满 5 turns → manifest 不够、topic 太碎或 prompt 允许调查过多。
- trailing run 长期频繁 → 提取耗时超过用户交互节奏,应降低扫描/写入成本。
- cache hit 持续偏低 → fork 参数或稳定前缀与 parent 发生漂移。
- “no memories saved”比例极低 → 提取标准太宽,记忆目录会迅速噪声化。

## 小结

Memory extraction pipeline 是一台缩小版 agent loop,但它的自主性被精确限制:可以理解完整历史 · 只能操作记忆目录 · 只处理新增区间 · 不得调查可推导事实 · 最多五轮。它证明“后台 agent”不等于放任第二个 Claude 自由工作;可靠性来自触发、权限、游标、并发和回填五个边界同时成立。

下一篇 [06 · Team memory sync · 从本地双目录到服务端同步](06-team-memory-sync.md) 继续沿落盘后的链路走:一条 memory 被判为 team scope 后,如何从本地目录同步给同一 GitHub 仓库的其他组织成员。

## 参考

- Claude Code 源码:`services/extractMemories/extractMemories.ts:1-13,74-221,271-586`
- Claude Code 源码:`services/extractMemories/prompts.ts:1-153`
- Claude Code 源码:`memdir/memoryScan.ts:21-93`
- Claude Code 源码:`query/stopHooks.ts:133-157`
- Claude Code 源码:`cli/print.ts:959-969`
- 姊妹篇:[03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](../context-management/03-prompt-cache.md)

