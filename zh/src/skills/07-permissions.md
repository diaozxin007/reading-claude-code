# 07 · 权限治理 · 从可调用到可安全执行

> **TL;DR**:Skill 安全至少分四层:谁能激活 Skill · 激活后哪些 Tools 可见 · 哪些 Tool 可以免询问 · 命令最终能访问哪些系统资源。`allowed-tools` 是临时预批准 · 不是 Tool allowlist;`disallowed-tools` 是本轮排除 · 不是 OS sandbox;调用开关控制入口 · 也不替代外部系统权限。高风险 Skill 要把 instructions、permissions、hooks、sandbox 与人工确认组合起来。

上一篇 [06 · 执行边界 · 从 inline 到 forked subagent](06-execution-boundary.md) 决定了 Skill 在当前 conversation 还是独立 worker 中展开。无论在哪 · instructions 最终都可能要求 Claude 调用 Bash、Edit、MCP tools 或其他能力。

于是出现一个危险的短路推理:

```text
用户调用了 /deploy
  → 用户同意部署
  → Skill 里写了 allowed-tools
  → 后续所有操作都安全
```

这三步没有一条能够推出下一条。调用意图、Tool availability、批准策略与实际隔离是不同安全层。

## 先画四道门

```text
Gate 1 · Skill invocation
  谁能启动这项工作流?
        ↓
Gate 2 · Tool availability
  运行中的 Claude 能看到哪些 Tools?
        ↓
Gate 3 · Permission decision
  某次 Tool call 是允许、询问还是拒绝?
        ↓
Gate 4 · Execution boundary
  进程、文件系统、网络与外部服务最终允许什么?
```

对应机制分别可能是:

| 安全问题 | 主要机制 |
|---|---|
| Claude 能否主动调用 Skill | `disable-model-invocation`、Skill permission rules |
| 用户是否看到 `/skill-name` | `user-invocable`、visibility settings |
| Skill 激活时哪些 Tools 免询问 | `allowed-tools` |
| 哪些 Tools 暂时不可用 | `disallowed-tools` |
| 每次调用前是否执行确定检查 | Hooks、permission rules |
| Bash 能访问哪些文件和网络 | Sandbox、OS 权限、容器 |
| MCP / API 能做什么 | 外部认证、服务端授权、scope |

任何一列都不能独自承担整条安全链。

## 第一层 · 控制 Skill 入口

第 04 篇已经介绍两项 frontmatter:

```yaml
disable-model-invocation: true
user-invocable: false
```

它们控制的是正常调用路径:

- 禁止模型调用 · 让副作用流程只能由用户明确启动;
- 隐藏用户入口 · 让 reference 型能力只由 Claude 按需加载。

除此之外 · Claude Code permissions 还能控制整个 Skill tool 或具体 Skill:

```text
Skill
Skill(release-check)
Skill(deploy *)
```

概念上可以形成三种策略:

- 禁止模型使用所有 Skills;
- 只允许指定 Skill;
- 对某项带 arguments 的 Skill 单独允许或拒绝。

但 `user-invocable: false` 只负责用户菜单与直接入口 · 官方明确提醒它不等于阻止 Skill tool 访问。真正要禁止 Claude 程序化调用 · 应使用 `disable-model-invocation` 或 permission rules。

UI 可见性不是安全边界。隐藏按钮从来不等于禁用能力。

## 第二层 · `allowed-tools` 是临时预批准

一项提交 Skill 可以写:

```yaml
---
name: commit
description: 检查并提交当前改动
disable-model-invocation: true
allowed-tools:
  - Bash(git status *)
  - Bash(git diff *)
  - Bash(git commit *)
---
```

`allowed-tools` 的作用是:本次 Skill 激活所在 turn 中 · 列出的 Tool patterns 可以不再逐次询问用户。

它不是:

- "Skill 只能使用这些 Tools";
- 永久 session allow rule;
- 绕过所有项目 permission settings;
- 让 shell 进程获得超出 OS 的权限;
- 对后续每一个用户 turn 持续有效。

可以把它理解为 Skill 对自己 workflow 的**临时权限需求声明**:

```text
Skill instructions 长期留在 context
  ≠
allowed-tools grant 长期留在 permission state
```

官方文档说明 · grant 会在用户发送下一条消息时清除。若后续还要继续免询问 · 需要重新调用 Skill;若整个 session 都应允许 · 应配置正式 permission allow rules。

这条生命周期差异很重要:instructions 与权限不会同步存活。

## `allowed-tools` 不会缩小 Tool 集合

字段名容易被误解为 allowlist。事实上它列的是"预批准哪些 Tools" · 没列出的 Tool 仍可能可见和可调用 · 只是继续走原有 permission policy——例如 `allowed-tools: Read Grep` 的结果不是"只剩 Read / Grep 可用" · 而是"Read / Grep 得到本轮预批准 · 其他 Tools 继续按 baseline policy 判断"。

若目标是建立只读 Skill · 仅列 `allowed-tools: Read Grep` 不够。Claude 仍可能请求 Edit 或 Bash。

真正缩小可用能力需要:

- Skill 的 `disallowed-tools`;
- Subagent 的 `tools` allowlist;
- permission deny rules;
- 只读 agent 类型或 sandbox。

"免询问"和"不可调用"必须使用不同词汇。

## `disallowed-tools` · 临时移除能力

Claude Code Skill 可以声明:

```yaml
disallowed-tools:
  - Edit
  - Write
```

这会在 Skill 活跃的调用范围内把指定 Tools 从可用池移除。它适合表达工作流本身的负能力:

- 审计 Skill 不应修改文件;
- 后台循环不应向用户提问;
- 研究流程不应发送外部消息。

但它仍然是 Claude Code runtime 的工具级限制:

- 不等于操作系统文件只读;
- 不阻止一个未被禁用的 Bash command 间接修改文件;
- 不替代外部服务的权限;
- 生命周期结束后限制会清除。

例如只禁 Edit 与 Write · 却保留 Bash · 不能推出"绝对不会写文件"。安全目标应按能力效果审计 · 不能只按 Tool 名字审计。

## Permission rules · 对 Skill 与 Tool 分别治理

一项高风险 Skill 通常需要两层 rules:

```text
Skill(deploy-production *)
  控制是否允许启动部署工作流

Bash(kubectl apply *) / MCP deploy tool
  控制工作流中的实际部署动作
```

第一层阻止不应出现的 workflow。第二层即使 Skill 被加载 · 仍能拦截具体动作。这是一种纵深防御:若只在 Skill 层 allow / deny · Claude 也可能不通过 Skill 而直接请求同一个 Tool。若只在 Tool 层治理 · 则高成本或敏感 instructions 仍可能被错误加载。两层解决不同风险。

## Workspace trust · 项目 Skill 是可执行配置

Project Skill 可以随陌生 Git 仓库一起出现。它不只包含 Markdown:

- `allowed-tools` 可能申请广泛预批准;
- 动态 context 可能在加载阶段执行 shell;
- scripts 可能访问文件和网络;
- references 可能包含恶意 Prompt Injection;
- hooks 可能在 Tool 生命周期自动运行。

因此打开一个仓库不能把 `.claude/skills/` 当普通文档目录。它更接近项目提供的可执行开发配置。

Claude Code 把项目配置与 workspace trust 连接起来。项目 Skill 中的 permission grant 只有在用户信任该 workspace 后才会生效。

"信任"也不是逐文件安全审计的替代品。它只表示用户接受这个目录的配置参与运行。引入第三方 Skill 时仍应检查:

1. `SKILL.md` instructions;
2. dynamic shell placeholders;
3. `allowed-tools` / `disallowed-tools`;
4. scripts 的文件、网络与凭证访问;
5. references 与外部内容来源;
6. hooks;
7. Plugin 或依赖更新路径。

官方安全建议可以概括为:**把 Skill 当软件安装 · 不要当 prompt 收藏。**

## Dynamic shell · 权限发生在 Claude 阅读之前

第 05 篇介绍过:

```markdown
!`git diff --stat`
```

命令在 rendered instructions 交给 Claude 前执行。即使它只是上下文预处理 · 仍然是实际 shell execution。

这带来独立治理开关 `disableSkillShellExecution`。组织可以允许 Skills 提供 instructions · 同时禁止用户、项目与 Plugin Skills 在加载阶段运行动态 shell。

这条策略很有价值:

```text
允许 Prompt-based workflow
  但不允许 Prompt preprocessing 自动执行本地命令
```

作者可以把动态命令改成显式 Tool 步骤 · 让它回到普通 permission loop。多一次往返换来更清楚的批准与审计路径。

## Hooks · 把建议变成固定检查点

Skill instructions 可以写:

```text
每次运行 Bash 前检查命令是否触及生产环境。
```

这是行为指导 · Claude 仍可能理解不完整或漏掉。Skill-scoped Hook 则能在 Tool 生命周期的固定事件上运行检查。

```text
Skill 激活
  ↓
Claude 请求 Bash
  ↓
PreToolUse Hook
  ├─ 允许
  ├─ 要求询问
  └─ 阻断
```

Hook 的优势是触发时机确定。它适合:

- 拦截危险命令;
- 验证参数;
- 在编辑后自动格式化;
- 在工作流结束时运行验证;
- 记录审计事件。

但 Hook script 本身也是代码 · 同样需要权限、输入验证与维护。把一段 prompt 风险转移到一个未经审计的 shell hook · 不会自动更安全。

可以用一条原则分工:

> **Skill 告诉 Claude怎样做 · Hook 保证某个生命周期检查一定发生。**

## Sandbox · Tool policy 之外的执行边界

Permission 主要决定"是否允许发起某次操作"。Sandbox 决定"操作即使被允许 · 实际能触达什么"。

例如 Bash 已获批准:

```text
Permission layer
  允许执行 command

Sandbox layer
  限制可写路径与网络

OS / container layer
  限制进程身份和系统资源
```

对于自动化程度高的 Skill · sandbox 往往比反复 permission prompts 更可靠。它可以预先划定工作区 · 让 Claude 在边界内自由执行 · 边界外无法触达。

但 sandbox 也不能决定业务授权。一个进程能访问网络 · 不代表它应该调用生产 API;本机有 kubeconfig · 不代表 Skill 应获得 production deploy 权限。

## 外部 Tools · 最终权限在服务端

Skill 可能调用 MCP tool、云 CLI 或 API:

```text
Skill allowed-tools
  允许 Claude 请求 deploy tool
        ↓
MCP / CLI credential
  决定客户端以谁的身份访问
        ↓
External service authorization
  决定账号能部署到哪个环境
```

本地 allow rule 只影响 Claude Code 是否放行调用。真正的数据范围、写权限与审计日志仍由外部系统控制。

因此敏感 Skill 应采用最小权限凭证:

- 只读 token 不用于写操作;
- staging 与 production credential 分离;
- destructive action 需要服务端确认或审批;
- 不让 Skill instructions 承担 secret 隔离;
- Tool result 中的外部内容继续按不可信数据处理。

Skill 可以编排授权系统 · 不能取代授权系统。

## Managed Skill · 统一分发不等于绝对执行

组织可以部署 managed Skills · 统一提供合规检查、安全 review 和内部流程。

它适合建立:

- 组织批准的工作方法;
- 统一的 reference 与 scripts;
- 默认权限与 hooks;
- 集中更新的能力版本。

但只把一句"禁止上传敏感数据"写进 managed Skill · 仍然是 Prompt instruction。真正强制阻断需要 deny rules、network policy、sandbox、DLP 或服务端 authorization。

这与 [07 · Managed CLAUDE.md · 企业管控层](../memory/07-managed-claude-md.md) 的结论一致:managed prompt 提供不可由普通项目轻易替换的行为指引 · enforcement 仍要落在确定性控制面。

## 一张安全矩阵

| 机制 | 控制对象 | 生命周期 | 不能保证什么 |
|---|---|---|---|
| `disable-model-invocation` | Claude 是否主动调用 Skill | Skill 定义 | 用户不会调用、磁盘文件不可读 |
| `user-invocable` | 用户入口是否显示 | Skill 定义 | Claude 无法调用 |
| `Skill(name)` rule | 指定 Skill tool call | Permission policy | Skill 内 Tools 自动安全 |
| `allowed-tools` | 某些 Tools 临时免询问 | 调用所在 turn | 只剩这些 Tools、永久授权 |
| `disallowed-tools` | 临时移除 Tools | 调用范围 | OS 级隔离、间接副作用 |
| Hook | 固定事件上的检查 | Skill / session 生命周期 | Hook 代码本身正确 |
| Sandbox | 文件与网络执行边界 | 进程 / session | 业务授权正确 |
| External auth | 服务端资源权限 | credential / policy | Prompt 不被注入 |

安全审计应该沿行逐项检查 · 不是看到某一个字段就宣布 Skill"安全"。

## 高风险 Skill 的组合模板

以 production deploy 为例:

```text
入口
  disable-model-invocation: true
  用户必须明确调用

Instructions
  先验证环境、版本、审批状态
  未确认不得执行

Tool permissions
  只预批准只读检查
  实际 deploy 继续询问

Hooks
  PreToolUse 校验 target environment

Sandbox / credentials
  默认只有 staging credential
  production 使用独立短期授权

External service
  服务端 RBAC + audit log + rollback
```

任何一层失败 · 后面仍有机会阻断。纵深防御比"写一段非常严厉的 Prompt"更可信 · 这就是这一篇要收束的结论:**Invocation 决定谁能开始 · Tool policy 决定怎样请求动作 · Hooks 决定哪些检查必经 · Sandbox 与外部授权决定动作最终能触达什么。**

## 下一篇预告

Skill 已被发现、调用并安全执行 · instructions 会不会在下一轮仍然存在?修改磁盘文件是否立刻影响已经加载的副本?Compaction 后又保留多少?下一篇 [08 · 生命周期 · 从一次加载到 compaction](08-lifecycle.md) 将把 source file、invocation record、conversation content 与 post-compact 恢复拆成四种状态。

## 参考

- Anthropic Claude Code 官方文档:[Pre-approve tools for a skill](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Restrict Claude's skill access](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Configure permissions](https://code.claude.com/docs/en/permissions)
- Anthropic Claude Code 官方文档:[Hooks in skills and agents](https://code.claude.com/docs/en/hooks)
- Anthropic Platform 官方文档:[Agent Skills security considerations](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- 上一篇:[06 · 执行边界 · 从 inline 到 forked subagent](06-execution-boundary.md)
- [01 · 从 tool 声明到执行前的批准](../agent-loop/01-tool-permission.md)
- [02 · Hooks · loop 上的可编程干预点](../agent-loop/02-hooks.md)
