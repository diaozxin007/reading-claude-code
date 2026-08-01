# 09 · 收尾 · 从一条信息到五种记忆载体

> **TL;DR**:Memory 不是一个功能,而是一组不同时间尺度、作者和共享范围的载体。先问“未来还能否从项目状态推导”,再问“这是明确规则还是协作观察”,最后问“属于个人、项目、某类 agent 还是团队”。载体选错比没有记更危险:临时状态会污染长期行为,个人偏好会泄漏到团队,可推导事实会悄悄过期。

上一篇 [08 · Compaction 之后 · 哪些记忆会自动回来](08-post-compaction.md) 说明持久文件与当前 context 驻留是两件事。最后一篇不再增加新机制,只回答一个实践问题:**手上有一条信息时,应该沉淀到哪里?**

## 一张总图 · Memory ≠ context

```text
当前 messages[]
  │ 只对当前会话有用
  ├──────────────→ task / plan / 保留在对话
  │
  │ 跨会话仍有用
  ▼
能从代码、git、配置重新推导吗?
  ├─ 能 → 不记 · 下次现查
  └─ 不能
      │
      ├─ 用户/组织明确规定 → CLAUDE.md 家族
      ├─ Claude 从协作中观察 → auto memory
      ├─ 某类专业 agent 的经验 → agent memory
      ├─ 全项目成员共享背景 → team memory
      └─ 通用 API 应用自建存储 → memory_20250818
```

第一刀永远是“可否推导”。代码结构、函数签名、git 历史、目录布局应该重新读取;把它们复制进 memory 只会制造第二份会过期的事实。

## 五种载体不是五个层级

本系列用五种载体铺开全景,但它们不是从低到高的继承栈。

| 载体 | 谁产生 | 共享范围 | 激活方式 | 适合内容 |
|---|---|---|---|---|
| CLAUDE.md 家族 | 用户/团队/管理员 | user、project、local、nested、managed | session 起手/路径触达 | 明确规则与指令 |
| auto memory | 主 agent + extraction agent | 当前用户与项目 | 索引起手 + topic 按需读 | 偏好、反馈、不可推导背景 |
| API memory tool | 应用中的 Claude | 应用自行定义 | tool `view` | 跨 session 工作区 |
| agent memory | 某个 agent type | user/project/local scope | agent spawn | 专业角色经验 |
| team memory | 组织成员与 agent | GitHub repo 对应组织成员 | 起手 pull + 双索引 | 团队共享约定与背景 |

其中 subagent memory 与 team memory 不是单纯“传递层”“同步层”:它们都有独立持久目录、prompt 与生命周期。新版源码尤其显示 team memory 通过服务端 API 同步,而非仓库内 git 文件。

## 决策树第一问 · 这是规则还是观察

### 明确规则 → CLAUDE.md

“commit message 用四段式”“只修改自己负责的文件”“这个仓库用 pnpm”是用户表达的意图。它们应进入 CLAUDE.md 或 `.claude/rules/`,因为用户需要可见、可审阅、可直接修改的权威文本。

### 协作观察 → auto memory

“用户是资深 Go 工程师但刚接触 React”“上次真实数据库测试方案被确认有效”“这个 incident 的外部背景不在 git 中”是从互动中形成的观察,适合 auto memory。

一个有用的提升规则是:同一条 feedback 被用户反复确认,并且已变成稳定项目规范时,应从 private memory **提升**为 CLAUDE.md 或 team memory,而不是永久停留在模型观察层。

## 第二问 · 当前工作还是未来协作

| 信息 | 正确载体 |
|---|---|
| “现在先改 A,再跑测试 B” | task / plan |
| “这个分支还剩两个 TODO” | 当前 session、task 或交接文档 |
| “以后所有迁移测试都必须连真实数据库” | project CLAUDE.md 或 team feedback memory |
| “用户不喜欢回复末尾重复总结” | private feedback memory |

Memory 的诱惑是“反正能跨 session,多写一点没坏处”。实际上短期状态最容易变质。下次 session 把旧分支 TODO 当成当前事实,比完全不记更糟。

## 第三问 · 谁应该看到

### 只有当前用户

沟通偏好、个人角色、未经公开的工作背景进入 private auto memory。不要因为当前仓库是团队项目就自动选择 team。

### 所有项目成员

不可从代码得知、且每个贡献者都应遵守的背景进入 team memory;若它是强制规则而非背景,更适合 project CLAUDE.md。两者区别是:

- CLAUDE.md 是明确治理文本,跟仓库一起 review;
- team memory 是协作中持续沉淀、通过服务端同步的共享观察。

### 某一种 agent

只有 reviewer、security researcher、migration agent 需要的经验进入 agent memory。再按跨项目通用、项目共享、本机私有选择 user/project/local scope。

### 组织不可覆盖规则

合规、安全和企业政策进入 managed CLAUDE.md。它提供行为指引,真正的硬阻断仍应由 permission deny、sandbox 与 hooks 承担。

## 第四问 · 要不要进入通用 memory tool

`memory_20250818` 是 API 给应用的客户端存储原语。只有在构建自有 agent 产品、需要 `/memories` 命名空间和六种文件操作时才选它。Claude Code 内部的 auto memory 没有复用这个 tool type;把两者混为一谈会误判存储责任和安全边界。

API memory tool 的关键问题是“应用如何持久化、隔离租户、防 traversal”;Claude Code auto memory 的关键问题是“产品如何分类、何时提取、如何召回”。两者解决的层次不同。

## 信息可以迁移 · 不应永远困在第一次落点

```text
一次对话中的临时事实
  ↓ 多次复用
private auto memory
  ↓ 被反复确认并成为项目共识
team memory / project CLAUDE.md
  ↓ 成为组织强制政策
managed CLAUDE.md + enforcement
```

反向迁移同样重要:

- 已失效的 CLAUDE.md 规则应删除,不是留着让新规则“覆盖”它;
- team memory 中只对个人有效的偏好应降为 private;
- agent user memory 中项目特例应降到 project/local scope;
- 可从代码稳定推导的记忆应删掉,回归现查。

这不是 GC 的附属工作,而是记忆系统维持可信度的核心。

## 一次具体判断

假设用户说:

> 上季度 mock database 让迁移测试误判,这个项目以后所有 migration test 都要连真实数据库。

拆成四步:

1. 未来仍有用?是。
2. 能从代码现状稳定推导?未必;代码可能暂时还没全部改完。
3. 个人偏好还是项目约定?明确是项目约定。
4. 需要强治理还是协作背景?若必须执行,写 project CLAUDE.md;若先作为团队经验沉淀,写 team feedback memory,包含 Why 与 How to apply。

不要写进 user memory,也不要只留在当前 task。载体选择来自生命周期与受众,不是句子出现在哪次对话。

## 反模式总表

| 反模式 | 后果 | 修正 |
|---|---|---|
| CLAUDE.md 当日志 | 起手噪声越来越大 | 只留稳定规则,历史归档 |
| MEMORY.md 当正文 | 入口预算被耗尽 | 索引 + topic 文件 |
| 保存可推导代码事实 | 形成陈旧副本 | 下次 grep/git/Read |
| private 偏好写 team | 隐私与行为污染 | user/feedback 留 private |
| 短期 TODO 写长期 memory | 旧状态跨 session 复活 | task/plan/交接文档 |
| agent type 复用过宽 | 不同角色经验混杂 | 按职责拆 type |
| 把同步当备份 | 删除/冲突语义不符合预期 | 理解 server-wins 与非删除传播 |
| 把 prompt 当 enforcement | 模型仍可能违背 | permissions/sandbox/hooks |

## 演进信号 · 什么时候该整理

- `MEMORY.md` 接近 200 行 → 合并与晋升稳定规则。
- 同一 topic 反复改名/重复 → frontmatter description 与分类失效。
- private/team 冲突频繁 → scope 选择或团队约定不清。
- compact 后总要重复解释 → 该信息没有进入正确持久载体,或索引 hook 不可检索。
- CLAUDE.md 每次启动都占大量 context → 把路径相关规则下沉到 rules/nested,把观察迁出到 memory。
- agent memory 跨项目冲突 → user scope 过宽。

## 本系列的最终结论

Claude Code 没有一只统一的“长期大脑”。它把记忆拆成多种可审阅文件、不同 scope、不同触发器和不同同步协议。这样做的代价是概念多、名字容易混;收益是每条信息都能有明确的作者、受众、生命周期和恢复路径。

一句话收束:

> **用户表达意图 → CLAUDE.md;Claude 沉淀不可推导观察 → auto memory;专业角色积累 → agent memory;团队共享观察 → team memory;应用开发者自建跨会话存储 → API memory tool。**

而所有这些文件重新进入 200K 请求的方式,回到姊妹系列 [00 · 开篇 · Claude Code 的 200K 账本](../context-management/00-intro.md)。Memory 决定什么跨会话活下来 · Context 决定它在这一轮怎样被装进模型。

## 参考

- 00 · Discovery 报告 · 从 CLAUDE.md 到 memories 的 5 大载体清单
- [01 · CLAUDE.md 家族 · 5 层 hierarchy 与 3 种混装](01-claude-md-family.md)
- [02 · auto memory · 从一次纠正到 MEMORY.md](02-auto-memory.md)
- [03 · Anthropic API memory tool · memory_20250818 客户端记忆原语](03-api-memory-tool.md)
- [04 · Subagent memory · 从 agent type 到三层持久目录](04-subagent-memory.md)
- [05 · Memory extraction pipeline · 从一轮结束到受限 fork](05-extraction-pipeline.md)
- [06 · Team memory sync · 从本地双目录到服务端同步](06-team-memory-sync.md)
- [07 · Managed CLAUDE.md · 企业管控层](07-managed-claude-md.md)
- [08 · Compaction 之后 · 哪些记忆会自动回来](08-post-compaction.md)
- Claude Code 官方文档:[Manage Claude's memory](https://code.claude.com/docs/en/memory)
- Anthropic API 官方文档:[Memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)

