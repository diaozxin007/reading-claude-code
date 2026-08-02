# 09 · 分发 · 从个人文件夹到团队 Plugin

> **TL;DR**:Personal、project、Plugin 与 managed 不是同一份 Skill 的四级继承栈 · 而是四种分发合同。Personal 适合本机迭代 · project 让能力随仓库 review · Plugin 提供 namespace、版本与多组件打包 · managed 负责组织统一部署。Agent Skills 格式可以跨产品识别 · 但 Claude Code、Claude API 与 claude.ai 的存储、运行环境和共享范围仍彼此独立。

上一篇 [08 · 生命周期 · 从一次加载到 compaction](08-lifecycle.md) 讨论的是一项 Skill 在 session 内怎样生存。这一篇把时间拉长:今天写在 `~/.claude/skills/` 的个人流程 · 明天如何交给团队 · 后天又怎样成为可安装组件?

最简单的做法是复制文件夹:

```text
cp -r ~/.claude/skills/release-check teammate-machine/
```

内容确实过去了 · 但很快会出现新的问题:

- 哪一份是权威版本?
- 谁负责更新?
- 同名 Skill 怎样避免冲突?
- scripts 依赖什么环境?
- Hooks、agents 与 MCP 配置怎样一起安装?
- 团队怎样 review 权限变化?
- Claude Code 版能否直接上传到 API 或 claude.ai?

分发的对象不是一个文件夹副本 · 而是一项能力的**维护与信任关系**。

## 四种分发合同

| 方式 | 权威来源 | 更新方式 | 最适合 |
|---|---|---|---|
| Personal | 用户本机目录 | 个人编辑 | 试验、个人习惯、跨项目私有流程 |
| Project | Git 仓库 `.claude/skills/` | 随项目 PR / commit | 仓库特有且团队共同使用的能力 |
| Plugin | Plugin 包与版本 | 安装、升级、marketplace | 跨项目、跨团队、多组件能力 |
| Managed | 组织管理配置 | 管理员集中部署 | 组织统一能力与治理要求 |

它们不是一定要逐级晋升。一个仓库专属迁移 Skill 可以永远留在 project · 一个公开工具的 Skill 可以从第一天就按 Plugin 设计。

真正的判断是:

```text
谁是作者?
谁是使用者?
谁批准更新?
怎样获得新版本?
能力还依赖哪些组件?
```

## Personal · 最快的实验场

个人目录适合从重复操作中提炼第一版 Skill:

```text
~/.claude/skills/release-check/
├── SKILL.md
└── scripts/
```

优点:

- 修改快;
- 不影响团队;
- 可跨本机多个项目测试 description;
- 适合观察实际触发与输出质量。

缺点也同样明确:

- 团队成员没有;
- 换机器不一定存在;
- 没有天然 PR review;
- 容易依赖作者本机的 CLI、路径与凭证;
- 更新历史可能只存在文件修改时间中。

Personal Skill 应被视为个人能力配置 · 不是隐形项目依赖。若团队工作在缺少它时会明显失败 · scope 已经选错。

## Project · 让能力随代码进入 review

把 Skill 放到:

```text
repo/.claude/skills/release-check/
```

并提交 Git · 它就成为项目的一部分。新贡献者 clone 仓库后能获得相同 workflow · Skill 变更也可以进入 code review。

Project 分发最重要的收益不是"自动复制" · 而是建立可审计历史:

```text
为什么修改 release checklist?
  → commit / PR 背景

谁扩大了 allowed-tools?
  → diff 可见

哪个版本开始依赖新 CLI?
  → repository history
```

Project Skill 适合紧密绑定仓库事实的能力。若同一 Skill 被复制到十个仓库 · 每份各自演化 · Git 只能记录十条分叉历史 · 无法提供统一升级。

这时应该考虑 Plugin。

## Standalone 先迭代 · Plugin 再产品化

Claude Code 官方文档建议把 standalone configuration 用于:

- 单项目定制;
- 个人 workflow;
- 快速试验;
- 尚未稳定的 Skills 与 Hooks。

当能力开始需要:

- 跨多个项目复用;
- 分享给团队或社区;
- 独立版本与更新;
- 与 agents、hooks、MCP servers 一起安装;
- Marketplace 分发;

再转换为 Plugin。

这是一条成熟度路径:

```text
重复 Prompt
  ↓
Personal Skill
  ↓ 真实任务迭代
Project Skill
  ↓ 边界稳定 · 多项目复用
Plugin
```

但"进入 Plugin"不是质量认证。它只是换成更正式的包装和分发合同。内容、测试与安全仍需作者负责。

## Plugin · 不只是 Skills 压缩包

一个 Claude Code Plugin 可以包含:

```text
my-plugin/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── release-check/
│       ├── SKILL.md
│       └── scripts/
├── agents/
├── hooks/
├── .mcp.json
├── .lsp.json
├── bin/
└── README.md
```

其中 `.claude-plugin/` 只放 manifest。Skills、agents、hooks 等组件位于 Plugin root · 不是全部塞进 `.claude-plugin/`。

这个结构表达一个更高层能力:

```text
Skill
  定义工作流

Agent
  定义专业 worker

Hook
  定义确定性生命周期动作

MCP / LSP
  提供外部与代码智能能力

Plugin manifest
  把它们变成一个可安装版本
```

因此 Plugin 是 packaging layer · Skill 仍是其中的操作知识层。

## Namespace · 分发前先解决名字所有权

Standalone Skill 可以叫:

```text
/release-check
```

Plugin Skill 会带上 Plugin namespace:

```text
/acme-release:release-check
```

Namespace 看起来增加输入长度 · 却解决两个分发问题:

1. 不同 Plugin 都可以拥有 `review` 或 `deploy`;
2. 用户能看到能力来源 · 不把第三方 Skill 误认成本地项目流程。

Plugin name 因而也是能力命名空间的一部分。随意改 Plugin name 不只是品牌变化 · 还会改变用户调用入口与 permission rules。

Namespace 是可组合生态的代价。个人 shortcut 可以短 · 公共能力必须避免抢占全局名字。

## Manifest · 给能力包一个版本身份

Plugin manifest 可以声明 name、description、version、author、repository、license 等 metadata。

其中 version 建立一个重要边界:

```text
Skill file changed
  ≠
用户已经获得更新

Plugin version changed
  → 分发系统可以识别新发布
```

官方文档说明 · 显式 version 存在时 · 发布者需要 bump 才能让用户获得对应更新;若使用 Git 分发而省略 version · commit SHA 可以成为版本身份。

无论采用哪种策略 · 都应让以下变化可见:

- description 与触发范围变化;
- workflow 语义变化;
- `allowed-tools` / hooks 权限面变化;
- scripts 与依赖变化;
- 输出格式或兼容性变化。

一个只改 prompt 的 release 也可能是 breaking change。模型行为 contract 不能因为文件是 Markdown 就跳过版本管理。

## Plugin 开发 · 本地加载不是正式安装

Claude Code 支持用 `--plugin-dir` 直接加载本地 Plugin · 便于开发测试。修改后可以 reload 组件 · 不必每次走 marketplace 发布。

这条开发路径适合:

```text
本地修改
  ↓
--plugin-dir 测试
  ↓
reload Skills / agents / hooks / MCP
  ↓
fresh session 验证发现与执行
  ↓
bump version / 发布
```

本地 copy 可能覆盖同名已安装 Plugin · 适合测试升级兼容。但 managed policy 强制启用或禁用的组件不应被开发 flag 当作可绕过配置。

测试本地目录成功只说明作者环境可运行 · 发布前还要验证干净机器、依赖、权限与升级路径。

## Managed · 组织分发的是批准版本

Managed Skill 由组织集中部署 · 适合:

- 公司统一的安全 review;
- 合规与数据处理流程;
- 内部系统操作指南;
- 组织批准的 scripts 与 references;
- 需要统一更新的开发工作流。

与 Plugin 相比 · managed 的核心不是 marketplace 安装体验 · 而是管理员控制来源和可用范围。

组织治理通常需要:

```text
作者提交能力更新
  ↓
安全 / 合规 / 平台团队 review
  ↓
发布批准版本
  ↓
管理员部署
  ↓
监控与回滚
```

Managed 仍不能把 Prompt instruction 变成硬 enforcement · 但可以确保组织成员获得同一份批准 workflow · 并与 managed permissions、shell policy 和 hooks 组合。

## 开放格式 · 可移植不等于自动同步

Agent Skills 使用开放的文件夹格式 · 让不同 agent 产品可以识别相同核心:

```text
name + description
SKILL.md instructions
scripts / references / assets
```

这提供**格式可移植性**。但 Anthropic 官方文档明确区分三个 surface:

| Surface | Skill 如何存在 | 共享范围 |
|---|---|---|
| Claude Code | 本地 personal / project / Plugin / managed | 本机、Git 项目或 Plugin 安装范围 |
| Claude API | 上传 Skill · 在 code execution container 使用 | API workspace |
| claude.ai | 用户上传到产品设置 | 对应用户账户 |

它们不会自动同步:

- Claude Code personal Skill 不会自动出现在 claude.ai;
- API workspace Skill 不会自动安装到本地 `.claude/skills/`;
- claude.ai 上传版也不是项目 Git 文件。

"Write once"更准确的含义是核心文件夹可以迁移 · 不是所有 surface 共用同一存储与版本状态。

## Runtime 不同 · 同一 Skill 也可能无法直接运行

Claude Code Skill 在用户本机执行 · 可以使用本地工具与网络 · 受用户环境、permissions 和 sandbox 约束。

Claude API Skills 运行在 code execution container 中 · 官方文档说明其网络与运行时依赖受容器限制。Claude.ai 又有自己的 code execution 与管理员设置。

因此跨 surface 迁移时要分两层检查:

### Portable instructions

- 工作流是否仍有意义?
- references 与 assets 是否完整?
- 输出 contract 是否通用?

### Runtime dependencies

- scripts 使用什么语言和包?
- 是否假设能安装依赖?
- 是否需要网络?
- 是否依赖本机 CLI、credential 或绝对路径?
- Claude Code 私有 frontmatter 在目标客户端是否被支持?

开放格式保证别人看得懂文件夹 · 不保证目标 runtime 能完成所有动作。

## `compatibility` · 把隐含环境写成分发合同

Agent Skills 规范提供 `compatibility` metadata · 用于说明宿主、系统包、网络等要求。

一项 Skill 如果依赖:

- Claude Code 的 dynamic context;
- `gh`、`kubectl` 或自定义 CLI;
- PowerShell;
- 网络访问;
- 某个 MCP server;
- Plugin 提供的 `bin/`;

就不应只在脚本运行失败后才让用户发现。

Compatibility 不是安装器 · 但它把"作者机器上碰巧存在"提升成可审阅的前置条件。

同理 · `license` 与 author metadata 也不是装饰。Skill 可以包含代码、模板与第三方 references · 分发者需要知道是否有权传播和修改。

## Dependency · Skill 文件夹之外还有供应链

即使 Skill 本身完全通过 review · 它也可能在运行时调用:

- `npx package@latest`;
- 未固定版本的 Python package;
- 外部 URL 上的 script;
- 第三方 MCP server;
- 远程模板;
- 用户 PATH 中的同名 executable。

这些依赖可以在 Skill 不变的情况下改变行为。

安全分发至少应考虑:

- 固定或约束依赖版本;
- 记录 checksum / release 来源;
- 避免运行时从任意 URL 下载代码;
- 对外部 MCP 与 credential 明确最小权限;
- 在 changelog 中记录权限面变化;
- 提供卸载与回滚方式。

Skill 是软件供应链的一部分 · 不只是 instruction supply chain。

## 从 standalone 迁移到 Plugin

迁移不应该只是复制目录。可以按五步完成:

```text
1. 锁定 Skill contract
   description · inputs · outputs · side effects

2. 清理本机假设
   绝对路径 · 私有 credential · 未声明 CLI

3. 建 Plugin structure
   manifest · skills/ · agents/ · hooks/ · MCP

4. 建 namespace 与 version
   调用名 · permission rules · changelog

5. 在干净环境验证
   discovery · invocation · permissions · scripts · upgrade
```

若迁移后只是把 `.claude/skills/` 原样包住 · Plugin 形式已经完成 · 产品化仍未完成。

## 分发前的质量门

一项 Skill 在作者自己的历史 conversation 中表现好 · 可能只是因为主 context 已经给了大量隐含帮助。分发前应在 fresh session 验证:

1. **Discovery** · 该触发的请求能否触发?
2. **Precision** · 相邻但不相关的请求是否误触发?
3. **Execution** · 没有作者隐含背景时能否完成?
4. **Environment** · 缺少依赖时是否给出清楚错误?
5. **Permissions** · 实际请求是否和文档一致?
6. **Output** · 结果是否满足约定格式与质量?
7. **Upgrade** · 从上一版本更新后是否兼容?

这里要把两项指标分开:

```text
Trigger quality
  Skill 有没有在正确时机被选中

Outcome quality
  被选中之后是否真的提高任务结果
```

只看到 Skill badge 出现 · 不能证明能力有效。Skill 分发因此不是移动文件 · 而是选择一套维护合同:**Personal 优化迭代速度 · Project 优化仓库一致性 · Plugin 优化可安装与版本化组合 · Managed 优化组织控制;开放格式连接它们 · 但不替它们同步。**

## 下一篇预告

到这里 · 一项 Skill 已经走完格式、发现、调用、渲染、执行、安全、生命周期与分发。最后还剩最实践的问题:手上有一条规则、一套 workflow、一个外部动作或一个专业 worker 时 · 到底应该做成什么?下一篇 [10 · 收尾 · 一项能力应该放到哪里](10-conclusion.md) 将用决策树收束 CLAUDE.md、Rules、Skill、Tool、Hook、Subagent、MCP 与 Plugin 的边界。

## 参考

- Anthropic Claude Code 官方文档:[Share skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Create plugins](https://code.claude.com/docs/en/plugins)
- Anthropic Claude Code 官方文档:[Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- Anthropic Platform 官方文档:[Cross-surface availability](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Agent Skills 开放规范:[Compatibility and metadata](https://agentskills.io/specification)
- 上一篇:[08 · 生命周期 · 从一次加载到 compaction](08-lifecycle.md)
