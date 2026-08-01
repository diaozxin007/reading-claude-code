# 04 · Subagent memory · 从 agent type 到三层持久目录

> **TL;DR**:普通 subagent 默认拥有独立 context,但“独立”不等于“永远失忆”。Agent 定义可以选择 `user`、`project`、`local` 三种持久 memory scope。每个 agent type 有自己的目录和 `MEMORY.md`;spawn 时读取,运行中由该 agent 自己维护。snapshot 则不是 parent 对话的实时镜像,而是项目提供的初始化模板和显式更新源。

上一篇 [03 · Anthropic API memory tool · memory_20250818 客户端记忆原语](03-api-memory-tool.md) 区分了协议级 memory tool 与 Claude Code 自身的文件记忆。本篇继续追问:当任务交给 subagent,长期经验怎样越过一次 spawn 的边界?

## 先纠正一个直觉 · 不是主 agent 把自己的 MEMORY.md 塞给子 agent

主 agent 和 subagent 的 context 默认隔离。persistent agent memory 也按 **agent type** 分目录,并不是把主 agent 的 auto memory 整体复制过去。一个 code-review agent 与一个 research agent 即使在同一仓库运行,也会形成不同的记忆空间。

```text
Agent 定义(memory: project)
        ↓ spawn
.claude/agent-memory/<agentType>/MEMORY.md
        ↓ 构造专属 memory prompt
subagent 独立 context
        ↓ Read / Edit / Write
下次同类型 agent 再次 spawn 时读回
```

因此这里真正跨越的不是 parent→child 的消息历史,而是**同一种 agent 身份在多次运行之间的经验**。

## 三种 scope · 生命周期不同

源码把 scope 固定为三值联合类型:`user | project | local`。见 `tools/AgentTool/agentMemory.ts:12-14`。

| scope | 目录 | 共享范围 | 典型用途 |
|---|---|---|---|
| `user` | `<memoryBase>/agent-memory/<agentType>/` | 同一用户跨项目 | 通用 reviewer 方法、个人协作偏好 |
| `project` | `<cwd>/.claude/agent-memory/<agentType>/` | 项目成员可经版本控制共享 | 项目专属审查规则、领域背景 |
| `local` | `<cwd>/.claude/agent-memory-local/<agentType>/` | 当前项目与机器 | 不宜提交的本地环境经验 |

远程持久目录存在时,`local` 会搬到远程 mount 下、并以 canonical project root 做 namespacing;`project` 仍保持 cwd-based。见 `tools/AgentTool/agentMemory.ts:24-64`。

`user` 不是“主 agent 用户记忆”的同义词。它仍以 agent type 分区,只是生命周期跨项目。`project` 的 prompt 明确告诉 agent 这些记忆会经版本控制分享;`local` 则明确不进版本控制。见 `tools/AgentTool/agentMemory.ts:138-176`。

## agent type 也是安全边界

插件 agent 常用 `plugin-name:agent-name` 这样的名字。冒号在 Windows 目录名中非法,源码将其替换为连字符。见 `tools/AgentTool/agentMemory.ts:15-22`。

路径判断不会只做字符串拼接后盲目信任。`isAgentMemoryPath()` 先 normalize,再分别检查 user、project、local 三个根;远程 local 还要求路径位于 remote memory 的 `projects/` 下并包含 `agent-memory-local` 段。见 `tools/AgentTool/agentMemory.ts:67-104`。

这个检查的意义是给 FileWrite/Edit 权限系统提供一个明确 carve-out:agent 可以维护自己的记忆目录,但不能因为“拥有 memory”就获得任意文件写权限。

## spawn 时发生什么

`loadAgentMemoryPrompt()` 是同步 prompt 构造路径的一部分。它做三件事:

1. 根据 agent type 与 scope 计算目录;
2. fire-and-forget 创建目录;
3. 调 `buildMemoryPrompt()` 读取该目录的 `MEMORY.md`,并追加 scope 指引。

目录创建不阻塞 spawn。即使 mkdir 尚未完成,FileWriteTool 自身也会创建父目录。这个选择避免了 React render / 同步 system prompt 回调被异步文件系统拖住。见 `tools/AgentTool/agentMemory.ts:131-176`。

agent memory 复用 auto memory 的“索引 + topic 文件”结构与四类 taxonomy,但入口内容直接进入 agent 的 prompt,因为这里没有主会话 `getClaudeMds()` 那条统一加载路径。见 `memdir/memdir.ts:268-315`。

## snapshot 到底是什么

snapshot 目录位于:

```text
<cwd>/.claude/agent-memory-snapshots/<agentType>/
├── snapshot.json
└── *.md
```

`snapshot.json` 只保存 `updatedAt`;每个实际 scope 目录另有 `.snapshot-synced.json`,记录上次同步的 snapshot 时间。见 `tools/AgentTool/agentMemorySnapshot.ts:10-41`。

检查结果有三种:

| action | 条件 | 行为 |
|---|---|---|
| `none` | 没 snapshot,或已同步且不更新 | 不动作 |
| `initialize` | snapshot 存在但本地没有任何 `.md` | 首次复制 |
| `prompt-update` | 本地已有 memory,但 snapshot 更新 | 让交互层决定是否替换 |

首次初始化会复制 snapshot 中除 `snapshot.json` 外的普通文件,并写同步元数据。替换操作先删除目标目录现有 `.md`,再复制 snapshot,避免旧文件成为 orphan。用户若选择保留本地版本,可只更新同步标记。见 `tools/AgentTool/agentMemorySnapshot.ts:56-196`。

所以 snapshot 不是“冻结 parent 活跃 memory,subagent 退出后丢弃”。它更接近**项目给某类 agent 准备的 seed / upgrade 包**。真正持久状态仍在 scope 目录中,会被未来同类型 agent 继续读写。

## 隔离与继承 · 准确口径

| 问题 | 答案 |
|---|---|
| 子 agent 能看到 parent 全部对话吗 | 默认不能;fork agent 是另一机制 |
| 子 agent 会继承主 auto memory 吗 | 不是整体继承;它加载自己的 agent-type memory |
| 子 agent 能写持久 memory 吗 | scope 开启后可以写自己的目录 |
| 写入会回到当前 parent context 吗 | 不会自动变成 parent 消息;未来 spawn 通过磁盘读回 |
| project snapshot 会自动覆盖本地吗 | 首次可初始化;已有本地内容时产生更新决策,不是静默覆盖 |

## 决策 · 反模式 · 演进信号

### 决策

- 以 agent type 而非 session ID 分区,让经验跟“角色能力”绑定。
- 用三种 scope 表达跨项目、团队共享、本地私有三种生命周期。
- snapshot 只做版本化初始化,不把活跃目录变成共享可变状态。

### 反模式

- 把 `user` scope 理解成主 agent 用户画像的全量继承。
- 在 `project` scope 存密钥或机器路径 · 它可能进入版本控制。
- 用 snapshot 当双向同步目录 · 替换语义会删除旧 `.md`。
- 多个职责完全不同的 agent 复用同一个 type 名 · 记忆会互相污染。

### 演进信号

- 同一 agent 在不同项目写出相互冲突规则 → 从 `user` 下沉到 `project`。
- project memory 充满个人偏好 → 转入 `local` 或主 auto memory private scope。
- snapshot 每次更新都要求人工判断 → seed 变化过于频繁,应缩小 snapshot 内容。
- agent 需要实时读取 parent 当轮决策 → 这是消息 handoff 问题,不是 persistent memory 问题。

## 小结

Subagent memory 的设计重点不是“怎么把父 context 复制过去”,而是**怎样让一个专业角色跨多次运行积累经验,同时不破坏 agent 之间的 context 隔离**。scope 决定经验活多久和分享给谁;agent type 决定经验属于哪个角色;snapshot 决定这个角色如何获得可版本化的初始知识。

下一篇 [05 · Memory extraction pipeline · 从一轮结束到受限 fork](05-extraction-pipeline.md) 深入 auto memory 的后台补漏者:它如何复用主会话 cache、限制工具、合并并发触发并把结果通知回界面。

## 参考

- Claude Code 源码:`tools/AgentTool/agentMemory.ts:12-176`
- Claude Code 源码:`tools/AgentTool/agentMemorySnapshot.ts:10-196`
- Claude Code 源码:`tools/AgentTool/loadAgentsDir.ts`
- Claude Code 源码:`memdir/memdir.ts:268-315`
- 姊妹篇:[06 · Sub-agent 隔离 · 从独立 context 到 .output 陷阱](../context-management/06-sub-agent.md)

