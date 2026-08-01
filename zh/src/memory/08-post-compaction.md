# 08 · Compaction 之后 · 哪些记忆会自动回来

> **TL;DR**:compaction 不是把所有持久记忆“压进摘要”。它重建 messages 后,重新运行 `SessionStart(compact)` hooks 来恢复启动上下文;同时保留计划、近期文件、已调用 skill 等专门 attachments。auto memory、agent memory、session memory 是三套不同东西:前两者跨会话,session memory 则是压缩可直接消费的会话摘要文件。

上一篇 [07 · Managed CLAUDE.md · 企业管控层](07-managed-claude-md.md) 讲到管理员指令必须长期有效。但同一个 session 还可能经历 `/compact` 或 auto-compact:旧 messages 被摘要替换之后,磁盘记忆怎样重新进入新消息数组?

## 先分清三种“memory”

| 名称 | 载体 | 时间尺度 | 与 compaction 的关系 |
|---|---|---|---|
| auto memory | 项目 memory 目录 + `MEMORY.md` | 跨 session | 启动 context 的持久来源 |
| agent memory | 按 agent type 的 memory 目录 | 跨多次 agent spawn | 构造该 agent system prompt 时加载 |
| session memory | 当前 session 的结构化摘要文件 | 单 session / resume | 可直接替代一次传统 compact LLM 摘要 |

名字相近不代表实现共享。`services/compact/sessionMemoryCompact.ts` 操作的是第三种,不是把 `~/.claude/projects/.../memory/MEMORY.md` 拿来当 compact summary。

## compaction 的产物不是一条 summary

新的消息序列大致由五部分组成:

```text
compact boundary
→ compact summary
→ 必须保留的尾部 messages
→ attachments
→ SessionStart(compact) hook results
```

源码的 `buildPostCompactMessages()` 明确按这个顺序组装。见 `services/compact/compact.ts:302-335`。

这意味着抗压缩不是单一机制。不同信息按不同理由回来:

- 历史事实进入 summary;
- 最新交互保留原消息,避免摘要吞掉刚发生的细节;
- 文件、plan、skills、后台 agent 状态走 attachments;
- CLAUDE.md 等启动级指令走 compact session-start hooks。

## CLAUDE.md 为什么不是交给 summary 记住

传统 compact 与 session-memory compact 都会调用:

```text
processSessionStartHooks('compact', ...)
```

见 `services/compact/compact.ts:592`、`:981` 与 `services/compact/sessionMemoryCompact.ts:583-586`。

设计上不能要求总结模型“顺便记住所有项目规则”。摘要是有损的,规则文件才是 ground truth。重跑启动 hook 等于从磁盘重新取一次当前版本,还允许用户在长会话中修改 CLAUDE.md 后让压缩后的 context 接到新规则。

`postCompactCleanup` 还会清理 CLAUDE.md 文件发现缓存,使后续加载不被旧扫描结果锁住。见 `services/compact/postCompactCleanup.ts:7-34`。

## root 与 nested 的差异

项目 root 的 CLAUDE.md 属于起手上下文,compact 后通过 session-start 路径恢复。nested CLAUDE.md 则与文件触达相关:只有读取或操作相应子目录时才惰性进入 context。

因此 compact 后不能假设所有曾经触达过的 nested 规则都自动重新出现。这个差异不是“不重要”,而是为了让路径相关规则只在相关工作重新发生时占 context。

```text
root CLAUDE.md   → session 生命周期级 → compact 后重跑起手加载
nested CLAUDE.md → 路径触达级       → 再次进入目录时加载
```

## auto memory 如何回来

auto memory 的行为指令属于 system prompt 的 memory section;`MEMORY.md` 索引内容则通过启动上下文装配进入会话。compaction 重建后,这条装配链重新运行,而不是依赖 summary 复述每条索引。

topic 文件正文通常不会全量注入。索引只提供 hook,相关时再 Read / Grep。于是 compaction 前读过某个 topic,并不保证正文永久留在新 context;如果任务仍依赖它,模型需要依据索引或摘要重新读取。

这正是“持久化”和“驻留 context”两件事的区别:

- 文件还在磁盘上 = 记忆没有丢;
- 文件内容仍在 messages 里 = 当前 context 仍驻留。

## session memory compact · 用现成摘要替代再总结

实验性 session-memory compaction 在两个 feature gate 同时开启时生效。它先等待进行中的 session-memory extraction,读取 session memory 内容;没有文件或仍是空模板就回退传统 compact。见 `services/compact/sessionMemoryCompact.ts:400-431,514-543`。

有内容时,它寻找 `lastSummarizedMessageId`,计算该 ID 之后该保留哪些尾部消息。选择边界时同时满足:

- token 与文本消息最低保留量;
- 最大 token cap;
- 不切断 tool_use / tool_result 配对;
- 不拆开共享同一 API message.id 的 thinking / tool_use 流式片段。

见 `services/compact/sessionMemoryCompact.ts:188-397`。

然后 session memory 被包装成 compact user summary。过长 section 会截断,并附上完整 session memory 文件路径。见 `services/compact/sessionMemoryCompact.ts:434-502`。

这条路径的价值是:**后台已经维护了一份可用摘要时,compact 不必再发起一次专门的总结 API call**。但若边界 ID 找不到、内容为空、压缩后仍超 auto-compact 阈值或发生错误,全部回退 legacy compact。见 `services/compact/sessionMemoryCompact.ts:545-629`。

## 消息不变量仍是底线

从历史中保留尾部消息时,最危险的是留下 tool_result 却剪掉对应 tool_use。session-memory compact 会收集保留区所有 tool_result ID,向前寻找缺失的 assistant tool_use;还会向前包含同 message.id 的 thinking 片段。见 `services/compact/sessionMemoryCompact.ts:188-314`。

所以 memory 不能绕开消息协议。无论 summary 多完整,新的 messages 仍必须满足 [02 · 从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md)。

## 哪些东西不会自动回来

- 曾经读过的所有 topic 正文 · 需要摘要保留或再次检索;
- 所有 nested CLAUDE.md · 要再次触达相应路径;
- memory tool `/memories/*` 的应用侧全部内容 · 协议层要求再次 `view`;
- subagent 的完整私有 context · 主线程只接收其结果/状态;
- 已被模型误写或删除的磁盘记忆 · compaction 不提供版本恢复。

## 决策 · 反模式 · 演进信号

### 决策

- summary 保存历史事实,hook/attachment 从权威来源恢复状态。
- root 指令自动回来,nested 规则按路径惰性回来。
- session memory 可复用时直接作为摘要,失败时无条件回退传统 compact。
- 尾部保留算法先维护 API 不变量,再谈 token 最优。

### 反模式

- 把 auto `MEMORY.md` 与 session memory 当成同一文件。
- 认为“磁盘还在”就等于“模型当前已经读到正文”。
- 让 compact summary 承担规则文件的唯一副本。
- 为省 token 直接 slice 尾部消息,切断 tool pair。

### 演进信号

- compact 后频繁违反项目规则 → session-start 恢复链或 CLAUDE.md cache reset 有问题。
- 模型反复重读大量 topic → 索引 hook 太弱或 topic 粒度不合适。
- session-memory compact 经常回退 → 摘要提取、边界游标或阈值配置不稳定。
- nested 规则常被忘记 → 规则实际是全项目级,应提升到 root/rules 而非路径惰性层。

## 小结

Compaction 不是一次“把旧脑子压成新脑子”,而是一次**状态重建**。摘要只承担历史压缩;CLAUDE.md、memory 索引、plan、files、skills 等各自从权威载体回来。最重要的口径是:跨会话 memory、agent memory、session memory 名字相似,生命周期与职责完全不同。

下一篇 [09 · 收尾 · 从一条信息到五种记忆载体](09-conclusion.md) 把整个系列收束成一棵决策树:面对一条值得保留的信息,到底该放 CLAUDE.md、auto memory、agent memory、team memory,还是只留在当前 context。

## 参考

- Claude Code 源码:`services/compact/compact.ts:302-335,527-616,981-1090`
- Claude Code 源码:`services/compact/sessionMemoryCompact.ts:188-397,400-629`
- Claude Code 源码:`services/compact/postCompactCleanup.ts:7-34`
- Claude Code 源码:`utils/sessionStart.ts`
- Claude Code 源码:`utils/claudemd.ts`
- 姊妹篇:[04 · Compaction 六兄弟 · 从手动到无处不在的压缩](../context-management/04-compaction.md)

