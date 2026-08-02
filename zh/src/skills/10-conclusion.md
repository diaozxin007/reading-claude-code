# 10 · 收尾 · 一项能力应该放到哪里

> **TL;DR**:稳定且普遍成立的规则放 CLAUDE.md / Rules · 可复用知识与多步做法放 Skill · 固定事件必须发生的动作放 Hook · 原子执行接口做 Tool · 外部系统能力通过 MCP 接入 · 需要独立 context 的工作交给 Subagent · 多项扩展一起安装时再包装成 Plugin。Skill 位于中间:它不直接提供新的执行原语 · 而是按需加载"怎样组合现有能力完成一类工作"。

上一篇 [09 · 分发 · 从个人文件夹到团队 Plugin](09-distribution.md) 把 Skill 从个人文件夹送到项目、Plugin 与 managed scope。到这里 · 一项 Skill 已经走过完整生命周期:

```text
文件夹格式
  ↓
metadata 发现
  ↓
用户 / 模型调用
  ↓
Prompt 渲染
  ↓
inline / fork 执行
  ↓
permissions / hooks / sandbox
  ↓
compaction 恢复
  ↓
project / Plugin / managed 分发
```

最后一篇不再增加机制 · 只回答一个实践问题:

> **当你发现 Claude 缺少一项能力时 · 应该补 CLAUDE.md、Skill、Tool、Hook、Subagent、MCP 还是 Plugin?**

## 先不要问"放哪个文件夹"

假设用户说:

```text
以后每次发布前都先跑测试 · 检查 changelog ·
确认版本号 · 汇总风险 · 得到我批准后才能发布。
```

这段话可以被拆成不同性质:

- "本项目使用 pnpm" · 稳定项目事实;
- "发布前的检查顺序" · 可复用 workflow;
- "任何 push production 都必须阻断等待批准" · enforcement;
- "读取部署状态" · 外部动作;
- "完整审计会读取很多文件" · context isolation;
- "希望全团队一键安装" · distribution。

若把整段话原样扔进一个 Skill · 虽然能工作 · 但不同责任被混在一层。正确问题不是"这句话像不像 Skill" · 而是逐项判断:

```text
它是常驻事实、按需做法、原子动作、固定触发、独立 worker
还是分发包装?
```

## 第一刀 · 每个任务都应该知道吗

### 是 · CLAUDE.md 或 Rules

适合内容:

- 包管理器、构建命令与项目规范;
- 目录边界与不可违反的协作约定;
- 每项相关工作都应采用的命名、测试或架构规则;
- 路径相关但仍属于项目规则的 instructions。

```text
"这个仓库只能使用 pnpm"
  → CLAUDE.md

"修改 migrations/** 时必须保留向后兼容"
  → path-scoped Rule
```

CLAUDE.md / Rules 的核心特征是**常驻或路径触达即加载**。如果一段内容在 90% 的任务中都不相关 · 把它常驻只会增加噪声。

### 否 · 继续问是否是一套可复用做法

发布、review、incident、迁移、文档生成等 workflow 只在特定任务出现 · 适合按需加载。

```text
"准备 release 时按这 8 步检查"
  → Skill
```

CLAUDE.md 与 Skill 都能写 instructions · 真正分界是适用频率与加载时机:

> **每次都要知道 → CLAUDE.md;遇到一类任务才要知道 → Skill。**

## 第二刀 · 缺的是"怎样做"还是"能够做"

### 缺做法 · Skill

Skill 提供:

- 领域知识;
- 检查清单;
- 多步 workflow;
- 判断标准;
- 工具编排顺序;
- reference、script 与 asset 导航。

```text
"怎样审查数据库 migration"
  → Skill
```

### 缺动作 · Tool

Tool 提供模型可调用的原子执行接口:

- 读取一个数据源;
- 创建 ticket;
- 查询部署状态;
- 修改特定对象;
- 运行一个有稳定 input / output contract 的操作。

```text
"查询 staging 当前部署版本"
  → Tool
```

两者组合:

```text
release-check Skill
  1. 调 deployment-status Tool
  2. 调测试相关 Tool / Bash
  3. 读取 changelog
  4. 判断是否满足发布条件
```

Skill 不需要重新实现 Tool · Tool 也不需要知道完整 release policy。

核心分界:

> **Tool 暴露 affordance · Skill 组织 affordance。**

## 第三刀 · Tool 在本地还是外部系统

Claude Code 自带 Read、Edit、Bash 等 Tools。需要新的本地确定逻辑时 · 可能只要一个 script;需要让模型以结构化接口调用新的外部能力时 · 通常通过 MCP 接入。

### Skill bundled script

适合:

- 只服务这项 Skill;
- 由 instructions 决定何时运行;
- 使用已有 Bash / code execution;
- 不需要作为全局独立能力被其他 workflows 发现。

```text
release-check/scripts/validate-version.py
```

### MCP Tool

适合:

- 能力来自外部服务或独立进程;
- 多项 Skill 和普通任务都可能调用;
- 需要结构化 schema 与 tool result;
- 需要独立认证、部署与生命周期;
- 不应要求 Claude 手工拼 CLI 参数。

```text
deployment server
  ├─ get_status(environment)
  ├─ deploy(version, environment)
  └─ rollback(deployment_id)
```

Skill 可以知道"何时查询、什么条件下部署、失败后怎样 rollback" · MCP server 提供实际动作。

判断标准:

```text
逻辑只属于一项能力包?
  → bundled script

多个 workflow 都需要的独立动作?
  → Tool / MCP
```

## 第四刀 · 是模型判断 · 还是固定事件必须发生

Skill instructions 由模型解释。若要求是:

```text
"每次 Edit 后都必须运行 formatter"
```

把它写进 Skill 意味着 Claude 需要记得 · 并选择执行。更直接的机制是 PostToolUse Hook——Edit 事件发生后确定性地触发 formatter · 不经过模型判断。

Hook 适合:

- 固定 lifecycle event;
- 每次命中都必须运行;
- 需要阻断或自动处理;
- 不希望依赖模型主动记起。

Skill 适合:

- 需要理解上下文后选择步骤;
- 不同结果会走不同分支;
- 工作流需要推理、协作与解释。

两者可以组合:

```text
security-review Skill
  指导完整审查方法

PreToolUse Hook
  确保危险 command 必经校验
```

一句话:

> **需要 Claude 判断怎样做 → Skill;事件发生就必须做 → Hook。**

## 第五刀 · 当前 context 还是独立 worker

有一套 reusable workflow · 仍要决定它在哪执行。

### Inline Skill

适合:

- 需要主 conversation 的完整历史;
- 要持续与用户往返;
- planning、implementation、verification 紧密共享 context;
- Reference 知识要持续影响当前任务。

### Forked Skill / Subagent

适合:

- 中间搜索与日志很多;
- 任务能独立封装;
- 只需要返回结果摘要;
- 需要专门 tools、model 或 permissions;
- 不希望污染主 context。

### Custom Subagent

当"由什么角色做"比"这次 workflow 是什么"更稳定时 · 建 custom subagent:

```text
code-reviewer agent
  system prompt · tools · model · permissions
  + preloaded review Skills
```

Skill 与 Subagent 的分界:

> **Skill 保存可复用内容 · Subagent 提供独立 context 与执行身份。**

一个 Skill 可以 fork agent · 一个 agent 也可以预载 Skills。不要为了保存一段 prompt 就创建 agent · 也不要为了隔离大量工作只创建 inline Skill。

## 第六刀 · 单项配置还是安装单元

Skill 已经成熟 · 还要判断怎样分发。

```text
一个仓库共同使用
  → .claude/skills/ · Project Skill

个人跨项目使用
  → ~/.claude/skills/ · Personal Skill

与 agents / hooks / MCP 一起跨项目安装
  → Plugin

组织统一部署批准版本
  → Managed
```

Plugin 不提供新的行为层。它把已有 Skills、agents、hooks、MCP servers 等组件变成一个有 namespace 与版本的安装单元。

因此不要因为"想显得正式"就把单项目 Skill 过早做成 Plugin。也不要让十个项目各自 copy 同一套多组件能力 · 只因为最初从 standalone 开始。

## 全景决策树

```text
手上有一条新能力需求
  │
  ├─ 每个相关任务都应知道的事实 / 规则?
  │    ├─ 全项目 → CLAUDE.md
  │    └─ 特定路径 → Rules / nested CLAUDE.md
  │
  ├─ 只在一类任务中需要的知识 / 多步做法?
  │    └─ Skill
  │         ├─ 共享主历史 → inline
  │         └─ 独立自包含 → context: fork
  │
  ├─ 固定事件发生时必须执行?
  │    └─ Hook
  │
  ├─ 模型缺少一个原子动作?
  │    ├─ Skill 私有确定逻辑 → bundled script
  │    ├─ 本地通用能力 → custom Tool / executable
  │    └─ 外部系统 / 独立进程 → MCP Tool
  │
  ├─ 需要独立 context、角色、model、tools?
  │    └─ Subagent
  │
  └─ 多项扩展需要统一安装、版本与更新?
       └─ Plugin / Managed distribution
```

同一套完整能力往往会同时命中多条 · 这不是冲突 · 而是分层组合。

## 一个完整例子 · Production release

将开篇的发布需求拆成能力栈:

### CLAUDE.md

```text
- 本项目使用 pnpm
- production 发布必须由用户明确批准
- changelog 使用 Keep a Changelog 格式
```

这些是广泛成立的项目规则。

### Skill

```text
release-check
1. 确认目标版本与环境
2. 检查工作区和测试
3. 验证 changelog 与 version
4. 查询当前部署状态
5. 汇总阻断项
6. 等待用户决定
```

这是按需 workflow。

### Scripts

```text
validate-version.py
check-changelog.py
```

承担确定性校验。

### MCP Tools

```text
get_deployment_status
deploy_release
rollback_release
```

连接部署平台。

### Hooks

```text
PreToolUse
  production deploy 前校验审批 token 与目标环境
```

建立确定性检查点。

### Subagent

```text
release-auditor
  独立读取大量变更与测试结果
  返回风险摘要
```

隔离审计过程。

### Plugin

```text
acme-release/
  skills + agents + hooks + MCP config + scripts
```

把整套能力交给多个仓库安装。

若全部写进一个 `SKILL.md` · 每一层都只能靠模型自觉。拆开后 · 每个机制承担自己最擅长的约束。

## Skill 自己的设计决策树

确定"应该做 Skill"之后 · 还要继续判断:

```text
内容主要是知识还是动作?
  ├─ Reference → 默认 inline · 可 user-invocable: false
  └─ Task workflow
       │
       ├─ 用户必须控制时机?
       │    └─ disable-model-invocation: true
       │
       ├─ 需要主对话历史?
       │    ├─ 是 → inline
       │    └─ 否 · 过程冗长 → context: fork
       │
       ├─ 大型低频资料?
       │    └─ references/
       │
       ├─ 确定性处理?
       │    └─ scripts/
       │
       └─ 最终模板 / 素材?
            └─ assets/
```

这棵树对应前九篇建立的格式、发现、调用、渲染与执行边界。

## 质量判断 · 先测触发 · 再测结果

Skill 写完后 · 至少要测两类质量。

### Trigger eval

准备三组 prompt:

```text
应该触发
  "这个版本能发布吗?"
  "帮我做 release readiness check"

不应该触发
  "解释 semver 是什么"
  "只改 README 一个错别字"

边界 case
  "生成 changelog · 先不要做完整发布检查"
```

观察 description 的 precision 与 recall。只测 `/release-check` 手动调用 · 无法证明自动发现有效。

### Outcome eval

在 fresh session 中比较:

```text
同一任务 + Skill enabled
vs
同一任务 + Skill disabled
```

检查:

- 是否真的遵循 workflow;
- 是否减少遗漏;
- 是否正确使用 references / scripts / Tools;
- 是否产生过多 context 或不必要调用;
- 是否满足输出与验证 contract;
- 是否引入新的副作用风险。

Skill 被调用只是路由成功 · 结果优于 baseline 才是能力有效。

## Skill 成熟度不是正文越来越长

一项 Skill 的演进通常应该是:

```text
v0 · 一段可重复 prompt
  ↓
v1 · 清楚 description + 核心 workflow
  ↓
v2 · references / scripts / assets 分层
  ↓
v3 · 调用控制 + permissions + verification
  ↓
v4 · evals + versioned distribution
```

如果每次失败都只往 `SKILL.md` 追加一段警告 · 最终得到的是庞大 Prompt · 不是成熟能力。

不同失败应进入不同层:

| 失败 | 更合适的修正 |
|---|---|
| 不触发 | description |
| 误触发 | what / when 边界、paths |
| 漏步骤 | core workflow |
| 低频细节错误 | reference |
| 确定性操作不稳定 | script / Tool |
| 必须动作偶尔没发生 | Hook / CI |
| 权限过宽 | permission / sandbox / auth |
| 主 context 被淹没 | forked subagent |
| 团队版本漂移 | Project / Plugin / managed |

让问题回到正确层 · Skill 才不会成为所有缺陷的垃圾桶。

## 反模式总表

| 反模式 | 后果 | 修正 |
|---|---|---|
| CLAUDE.md 塞偶发 workflow | 每个 session 常驻噪声 | 下沉 Skill |
| Skill 模拟一个结构化原子 API | 参数脆弱 · 输出不稳定 | Tool / MCP |
| Skill 要求"每次必须"却无 Hook | 依赖模型记得 | 固定 lifecycle trigger |
| 为 reference 创建 subagent | 有知识无任务 | inline / preload |
| 用 `allowed-tools` 当 allowlist | 未列 Tool 仍可能调用 | disallow / deny / agent tool list |
| 动态 shell 偷做主任务 | Claude 阅读前已有副作用 | 正常 Tool loop |
| 所有资料塞 `SKILL.md` | 激活与 compaction 成本过高 | progressive disclosure |
| 任务进度写进 Skill | 旧状态污染未来调用 | task / session / memory |
| 复制文件夹当团队分发 | 版本与来源漂移 | Project Git / Plugin |
| Plugin 当安全认证 | 恶意脚本与依赖仍存在 | audit + version + sandbox |

## 演进路径 · 能力可以迁移

载体不是第一次选择后永远不变:

```text
反复粘贴的 Prompt
  → Personal Skill

个人流程成为项目共识
  → Project Skill

多个仓库都需要
  → Plugin

Skill 中的某一步变得稳定且通用
  → Script / Tool / MCP

某条检查从"建议"变成"必须"
  → Hook / CI / policy

某段 Skill 每次都必然加载
  → CLAUDE.md / Rule

Inline 过程不断污染主 context
  → Forked Skill / Subagent
```

反向迁移也成立:

- 全局规则只服务 release → 从 CLAUDE.md 降到 Skill;
- Plugin 只有单仓库使用 → 回到 project;
- Forked task 总依赖完整聊天历史 → 回到 inline;
- Tool 只有一项 Skill 内部使用且接口没有复用价值 → 收回 bundled script。

架构可信度来自持续把职责放回合适层 · 不是追求扩展数量。

## 本系列的最终结论

Skill 最容易被误解成三样东西:

- 更长的 Prompt;
- 更方便的 slash command;
- 不需要 schema 的 Tool。

它同时继承了三者的一部分特征 · 却有自己的完整位置:

```text
Prompt
  提供 instructions
       ↓ 可复用 + 文件夹化
Skill
  被发现 · 按需加载 · 编排能力
       ↓ 调用
Tools / MCP
  执行原子动作
```

它又可以进入不同 context:

```text
Skill inline
  → 扩展当前 agent 的做法

Skill fork
  → 把做法变成独立 worker 的任务
```

还可以被不同层治理与分发:

```text
Permissions / Hooks / Sandbox
  → 控制执行

Project / Plugin / Managed
  → 控制传播
```

一句话收束整个系列:

> **Skill 是按需加载的操作知识包:metadata 让它被找到 · instructions 让 Claude 知道怎样做 · resources 与 scripts 提供材料 · Tools 把做法变成动作 · runtime 决定它在哪个 context、以什么权限执行。**

## 下一系列预告

Skill 已经解释了"怎样把现有能力组织成 workflow"。下一条自然问题是:Claude Code 怎样获得原本不存在的外部 Tools 与数据?这将进入 **MCP 研究系列** —— 从一个 server 暴露的 tool schema 出发 · 追踪连接、发现、调用、权限、transport 与外部生命周期。

## 参考

- Anthropic Claude Code 官方文档:[Extend Claude Code](https://code.claude.com/docs/en/features-overview)
- Anthropic Claude Code 官方文档:[Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Tools reference](https://code.claude.com/docs/en/tools-reference)
- Anthropic Claude Code 官方文档:[Create custom subagents](https://code.claude.com/docs/en/sub-agents)
- Anthropic Claude Code 官方文档:[Hooks reference](https://code.claude.com/docs/en/hooks)
- Anthropic Claude Code 官方文档:[Create plugins](https://code.claude.com/docs/en/plugins)
- Agent Skills 开放规范:[Specification](https://agentskills.io/specification)
- [00 · 开篇 · 从重复粘贴到可调用能力](00-intro.md)
- [01 · 能力格式 · 从一个 Markdown 文件到可移植文件夹](01-format.md)
- [02 · 渐进披露 · 从 description 到完整 instructions](02-progressive-disclosure.md)
- [03 · 能力发现 · 从一个目录到 Claude 的候选清单](03-discovery.md)
- [04 · 能力调用 · 从用户请求到 Skill 激活](04-invocation.md)
- [05 · Prompt 渲染 · 从参数到动态上下文](05-prompt-rendering.md)
- [06 · 执行边界 · 从 inline 到 forked subagent](06-execution-boundary.md)
- [07 · 权限治理 · 从可调用到可安全执行](07-permissions.md)
- [08 · 生命周期 · 从一次加载到 compaction](08-lifecycle.md)
- [09 · 分发 · 从个人文件夹到团队 Plugin](09-distribution.md)
- 上一篇:[09 · 分发 · 从个人文件夹到团队 Plugin](09-distribution.md)
