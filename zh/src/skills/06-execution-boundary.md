# 06 · 执行边界 · 从 inline 到 forked subagent

> **TL;DR**:Inline Skill 把 instructions 加入主 conversation · 共享现有历史并继续在同一条 loop 上工作。`context: fork` 则把 Skill 正文变成一个新 subagent 的任务 · 使用独立 context、agent 配置与工具边界 · 最后只把结果带回主对话。前者适合需要持续协作的知识与流程 · 后者适合自包含、过程冗长、只需返回摘要的任务。

上一篇 [05 · Prompt 渲染 · 从参数到动态上下文](05-prompt-rendering.md) 已经把 `SKILL.md` 渲染成针对本次调用的 instructions。下一步并不是立刻执行某个固定函数 · 而是决定:**这些 instructions 交给当前 Claude · 还是交给一个新的 worker?**

Claude Code 给出两种执行 context:

```text
inline
  rendered Skill
      ↓
  当前 conversation

fork
  rendered Skill
      ↓
  新 subagent context
      ↓
  结果返回当前 conversation
```

它们使用相同的 Skill 文件格式 · 却形成完全不同的信息流。

## Inline · 把方法加入正在进行的工作

默认 Skill 在当前 conversation 中展开。假设主对话已经完成:

1. 用户解释了 release 背景;
2. Claude 读取了当前 diff;
3. 双方确认只检查 staging;
4. 用户调用 `/release-check v2.4.0`。

Inline Skill 可以直接利用这些已有信息:用户目标、已读文件、前面做出的决定、tool results 都还在同一个 conversation 里 · release-check instructions 只是新加入的一项。Claude 不需要重新理解任务 · Skill 只是为当前 agent 增加一套做法。

Inline 适合:

- Reference 型 Skill · 给当前工作补充领域知识;
- 需要与用户持续往返的流程;
- 前后阶段共享大量 context 的任务;
- Skill 只是当前工作的一部分 · 而不是独立委派任务;
- 执行过程中需要继续引用主对话里的决定与 tool results。

它的优势是上下文连续 · 代价是 Skill 正文、后续读取和执行结果都会继续增长主 context。

## Fork · 把 Skill 正文变成一项委派任务

在 frontmatter 中设置:

```yaml
---
name: deep-release-audit
description: 深度审计一个候选发布版本
context: fork
agent: Explore
---
```

调用后 · Claude Code 创建一个独立 subagent。Rendered `SKILL.md` 不再作为主 conversation 的补充说明 · 而是成为 subagent 要完成的任务。

```text
主 conversation
  "审计 v2.4.0"
        ↓ invoke forked Skill

subagent context
├─ agent system prompt
├─ Skill rendered content ← task
├─ 自己读取的文件
├─ 自己产生的 tool results
└─ 最终结论
        ↓
主 conversation
  收到结果 / 摘要
```

这里的 fork 不是把主 messages 数组复制一份。Subagent 有新的 context window · 不会自动看到主对话的完整历史、主 agent 已经读取的所有文件或已经调用的其他 Skills。

它得到的是 Skill task、选定 agent 的执行环境以及产品规定的基础项目 context。

## `context: fork` 先要求 Skill 是一个完整任务

考虑一个 reference Skill:

```markdown
本项目 API 应使用一致的错误格式 · 列表接口必须分页 ...
```

Inline 加载后 · 当前 Claude 可以把这些约定应用到正在编写的 endpoint。

若把它设置成 `context: fork` · 新 subagent 只得到一组 API conventions · 却不知道要审查哪个文件、设计哪个接口或交付什么结果。它拥有知识 · 没有任务。

因此 forked Skill 需要明确写出:

- 要处理的对象;
- 要完成的动作;
- 可用输入从哪里取得;
- 什么算完成;
- 最终返回什么。

```markdown
审查 `$ARGUMENTS` 指定的 API 文件:

1. 找到 endpoint 与 schema
2. 对照本项目 API conventions
3. 检查兼容性、错误格式与分页
4. 返回按严重程度排序的问题清单
```

一句话:

> **Inline Skill 可以只提供知识 · forked Skill 必须能够独立构成任务。**

## Fork 不继承对话 · 参数必须承担交接

主 conversation 里可能已经说过:

```text
只检查 staging · 不看 production · 版本目标是 v2.4.0。
```

Forked subagent 不会因为这些话出现在主历史里就自然知道。必要信息必须进入委派边界:

- 通过 `$ARGUMENTS` 传入;
- 通过动态上下文提前采集;
- 写进 Skill 的固定 instructions;
- 或由主 agent 在调用时组成清楚的任务输入。

这与函数调用类似:

```text
主 conversation 的隐含状态
  ≠
subagent 的显式输入
```

若 forked Skill 总要依赖"你应该记得我前面说过" · 说明任务边界没有封装好 · 可能更适合 inline。

## Agent 字段决定工作环境

`context: fork` 只说明需要独立 context。`agent` 再决定由哪类 subagent 执行:

- `Explore` · 适合只读代码研究;
- `Plan` · 适合形成实施方案;
- `general-purpose` · 适合需要综合工具的任务;
- 自定义 agent · 使用项目定义的 model、tools 与 system prompt。

```yaml
context: fork
agent: Explore
```

Skill 与 agent 的分工是:

```text
Skill
  这次具体做什么 · workflow 与交付标准

Agent
  由什么角色做 · 使用什么模型、Tools 与 permissions
```

同一项"深度研究"workflow 可以交给不同 agent 环境 · 同一类 reviewer agent 也可以执行不同 Skill tasks。

这避免把角色身份与单次任务揉进同一个 Markdown。

## Explore / Plan 的轻量 context 例外

官方文档说明 · 一般 forked Skill 除 agent prompt 与 Skill task 外还会获得项目 CLAUDE.md;但内置 Explore 与 Plan agent 为保持 context 精简 · 不按普通方式加载 CLAUDE.md 与 git status。

这意味着选择 `agent: Explore` 不能只看"它有读文件工具"。若 Skill 的关键约束只存在于 CLAUDE.md · 任务可能没有得到这些规则。

稳妥的判断是:

- 全项目都应遵守、且 agent 环境会加载的规则 → 保留在 CLAUDE.md;
- forked task 成败所必需的约束 → 在 Skill 中显式交代;
- 不要依赖某个 agent 隐式继承主 conversation。

执行 context 越隔离 · 任务 contract 就要越清楚。

## Fork 隔离的是过程 · 不是让成本消失

假设审计需要读取 80 个文件 · 产生大量搜索结果。Inline 执行会把这些中间信息持续堆进主 conversation。

Fork 后:

```text
subagent context
  80 个文件 + 搜索结果 + 推理过程
        ↓ 收束
主 context
  一份问题清单与证据摘要
```

主 context 得到保护 · 但总计算并没有消失:

- Subagent 需要自己的输入 tokens;
- 需要重新读取它不知道的项目材料;
- 启动与结果汇总增加延迟;
- 返回内容过长仍会占主 context。

Fork 的价值是**把过程放在更合适的 context 中** · 不是免费获得第二个大脑。

## 反方向 · 给 Agent 预载 Skills

Skill 与 subagent 可以双向组合。目前讨论的是 `context: fork` 这个方向——Skill 决定 task · agent 决定 worker environment。另一个方向是在 subagent 定义中使用 `skills` 字段:

```yaml
---
name: code-reviewer
description: 审查当前改动
tools: Read, Grep, Glob
skills:
  - api-conventions
  - security-guidelines
---
```

此时:

```text
Subagent definition
  决定角色与 system prompt

Delegation message
  决定这次具体 task

Preloaded Skills
  提供该角色启动时就需要的知识
```

两种组合的差别可以放在一张表里:

| 方式 | System prompt 来自 | 本次 task 来自 | Skill 的角色 |
|---|---|---|---|
| Skill `context: fork` | 选定 agent | `SKILL.md` rendered content | 定义这次工作流 |
| Subagent `skills` | subagent body | 主 agent 的 delegation | 为角色预载知识 |

前者是"这项能力需要找一个 worker 执行" · 后者是"这个 worker 无论接哪次任务都需要这些知识"。

## 预载完整正文 · 不再走 metadata 路由

普通主 session 中 · Skill 先暴露 description · 激活后才加载正文。Subagent 的 `skills` 字段表达了更强的判断:作者已经确定这个 agent 每次启动都需要这些 Skills。

因此预载的是完整 Skill content · 不是只有 name 与 description。

这提高了专业角色的一致性 · 也带来固定 context 成本:

- Reviewer 每次都用 security guidelines → 适合预载;
- 偶尔才处理 PDF → 不应给所有 reviewer 预载;
- 十几项大 Skill 全部预载 → 新 agent 还没接任务就已占用大量 context。

Subagent 预载是"从按需能力提升为角色常驻知识"。它应基于稳定职责 · 不是为了避免 Claude 偶尔忘记调用。

## 预载不等于 Skill Tool allowlist

官方文档区分两件事:

- `skills` 字段 · 把指定 Skill 的完整正文注入 subagent startup context;
- Skill tool availability · subagent 是否还能按需调用其他可见 Skills。

预载清单不是天然的"只能使用这些 Skills"沙箱。若需要限制工具与能力 · 还要配置 agent tools、permissions 或 Skill access rules。

同样 · 给 agent 预载一项 Skill 不会自动授予其中涉及的所有系统权限。Knowledge preload 与 capability enforcement 仍是两个层次。

## Inline 与 fork 的选择表

| 问题 | Inline | Forked subagent |
|---|---|---|
| 需要完整主对话历史 | 适合 | 不自动拥有 |
| 需要频繁和用户往返 | 适合 | 成本较高 |
| 中间读取与日志很多 | 污染主 context | 可隔离 |
| 任务能否自包含 | 不必完全自包含 | 必须清楚封装 |
| 最终只需摘要 | 可以 · 但过程仍在主线 | 适合 |
| 需要专门 tools/model | 受当前 agent 环境影响 | 可选 agent 配置 |
| Reference 型知识 | 适合 | 单独 fork 往往无任务 |
| 延迟敏感的小修改 | 适合 | 启动成本偏高 |

Skill 决定的不只是"做什么" · 还可以决定"这套做法在哪里展开":**Inline 把能力加入当前思路 · fork 把任务交给独立 worker;Skill 调 Agent 是任务驱动 · Agent 预载 Skill 是角色驱动。**

## 下一篇预告

无论 inline 还是 fork · 最终都会调用 Tools。Skill 可以预批准某些动作、排除某些 Tools、注册生命周期 hooks · 项目 Skill 还受 workspace trust 影响。下一篇 [07 · 权限治理 · 从可调用到可安全执行](07-permissions.md) 将划清四条边界:**能调用 Skill、能调用 Tool、免去询问与真正被隔离并不是同一件事。**

## 参考

- Anthropic Claude Code 官方文档:[Run skills in a subagent](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Create custom subagents](https://code.claude.com/docs/en/sub-agents)
- Anthropic Claude Code 官方文档:[Preload skills into subagents](https://code.claude.com/docs/en/sub-agents)
- 上一篇:[05 · Prompt 渲染 · 从参数到动态上下文](05-prompt-rendering.md)
- [06 · Sub-agent 隔离 · 从独立 context 到 .output 陷阱](../context-management/06-sub-agent.md)
- [09 · Sidechain · 从子代理到 agentId 分流](../agent-loop/09-sidechain.md)
