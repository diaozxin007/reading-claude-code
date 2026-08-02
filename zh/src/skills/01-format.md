# 01 · 能力格式 · 从一个 Markdown 文件到可移植文件夹

> **TL;DR**:Agent Skills 标准定义的是一个可移植文件夹:`SKILL.md` 负责发现与核心 instructions · references 保存按需知识 · scripts 承担确定性操作 · assets 提供模板和产物素材。Claude Code 接受这套核心格式 · 同时增加调用、执行、权限和路径相关字段。设计 Skill 时应先写标准核心 · 再明确哪些行为依赖 Claude Code。

上一篇 [00 · 开篇 · 从重复粘贴到可调用能力](00-intro.md) 把 Skill 放回能力栈:它像 Tool 一样参与选择 · 激活后却不是进入独立 executor · 而是加载一套操作知识来编排已有 Tools。

现在把视线移到磁盘。为什么 Skill 不是一份 `deploy.md` · 而要占据一个完整文件夹?

## 一份 Markdown 很快会遇到三种内容

假设要做一个 `release-check` Skill。最初只有四步:

```markdown
1. 检查工作区
2. 运行测试
3. 核对 changelog
4. 汇总风险
```

继续使用后 · 很快会出现三类新增内容:

- 一份详细的版本规范 · Claude 需要查阅;
- 一个检查版本号的脚本 · Claude 需要执行;
- 一份发布报告模板 · Claude 需要复制并填写。

如果全部塞进同一份 Markdown · 规范、程序和模板会跟核心流程一起加载。读者很难分清哪些是每次都要遵循的主线 · 哪些只是遇到特定情况才需要的材料。

Agent Skills 没有把 Skill 定义成"一个 Markdown 文件" · 而是定义成"以 `SKILL.md` 为入口的文件夹":

```text
release-check/
├── SKILL.md
├── scripts/
│   └── validate-version.sh
├── references/
│   └── version-policy.md
└── assets/
    └── release-report.md
```

这四个位置不是单纯按扩展名整理文件。它们代表四种不同角色:

| 位置 | 角色 | Claude 怎样使用 |
|---|---|---|
| `SKILL.md` frontmatter | 能力索引 | 判断这项能力是否相关 |
| `SKILL.md` body | 核心 instructions | 激活时进入 context |
| `references/` | 按需知识 | 遇到对应问题时读取 |
| `scripts/` | 确定性操作 | 需要时执行 · 不必把源码全文放进 context |
| `assets/` | 模板与资源 | 复制、转换或用于最终产物 |

文件夹因此同时是一份**能力说明书**和一个**运行材料包**。

## `SKILL.md` 是入口 · 不是仓库

`SKILL.md` 至少承担三件事:

1. 用 metadata 说明"我是谁 · 什么时候用我";
2. 用正文说明"激活后先做什么 · 怎样判断";
3. 为 supporting files 提供导航 · 告诉 Claude 何时读取或执行。

第三点容易被忽略。把 `version-policy.md` 放进 `references/` 并不会自动让 Claude理解它的用途。入口文件仍要交代:

```markdown
## Supporting resources

- 判断版本号是否合法时 · 读取 `references/version-policy.md`
- 需要机械校验时 · 运行 `scripts/validate-version.sh`
- 生成最终报告时 · 使用 `assets/release-report.md`
```

这里的关键不是列一遍目录 · 而是给出**读取条件**。Skill 的渐进披露依赖导航:只有入口知道哪些资源存在 · Claude 才能在正确时机继续展开。

所以 `SKILL.md` 不应该变成所有知识的仓库 · 它更像一张地图——`description` 决定什么时候有人翻开它 · 正文告诉你从哪里起步、走到哪个岔口该查哪份资源 · `references`、`scripts`、`assets` 只是地图标出的几条支路 · 不需要提前搬进正文。地图过短 · Claude 不知道怎样走;地图把沿途细节全画上去 · 渐进披露又失去意义。

## 开放标准只锁定可移植核心

Agent Skills 开放规范要求 `SKILL.md` 由 YAML frontmatter 和 Markdown body 组成。标准核心很小:

```yaml
---
name: release-check
description: 检查版本是否具备发布条件 · 在准备 release 时使用
---
```

其中:

- `name` 提供稳定身份;
- `description` 同时说明做什么和何时使用;
- Markdown body 保存 instructions;
- `scripts/`、`references/`、`assets/` 是约定角色 · 可以按需要存在。

标准还提供 `license`、`compatibility`、`metadata` 与实验性的 `allowed-tools` 等可选 metadata。它们解决的是跨客户端仍然有意义的问题:许可、运行环境要求、额外标识与工具预授权。

开放规范刻意不定义 Claude Code 的界面、subagent 类型或 session 生命周期。同一个 release-check 文件夹换到另一个 agent 产品里 · 依然能告诉它"怎样做"——但去哪里发现这个文件夹、怎样把 metadata 亮给模型、怎样触发激活、`validate-version.sh` 在什么环境里跑、跑完怎么处理产物 · 规范都不管 · 每个宿主要自己决定。

这就是**格式标准**与**产品运行时**的边界。

## Claude Code 在标准上增加了什么

Claude Code 不只是读取通用 `SKILL.md` · 还把它接入自己的 commands、Tools、subagents、hooks 和 permissions 系统。因此 frontmatter 里会出现更多产品字段。

这些扩展可以按问题分成四组:

| 问题 | Claude Code 扩展的方向 |
|---|---|
| 谁能调用 | 用户调用、模型调用与可见性控制 |
| 在哪执行 | 当前 conversation 或 forked subagent |
| 带什么输入 | arguments、动态上下文、shell 选择 |
| 能做什么 | tool 预授权、tool 排除、hooks 与路径条件 |

例如一项部署 Skill 可以要求只能由用户手动触发;一项代码研究 Skill 可以进入独立 subagent context;一项只服务前端目录的 Skill 可以设置路径条件。这些都很有用 · 但它们不是所有 Agent Skills 客户端共同保证的行为。

于是同一份文件里实际存在两层协议:

```text
Agent Skills 标准核心
  name · description · instructions · supporting files
        ↓ 宿主解释
Claude Code 产品扩展
  invocation · fork · paths · hooks · permissions · shell ...
```

写作者必须知道自己正在依赖哪一层。否则"在 Claude Code 里能用"很容易被误写成"这是 Agent Skills 标准行为"。

## 一个看似矛盾的 name

开放规范把 `name` 视为必需 metadata · 并要求它与父目录名对应。Claude Code 的本地 Skill 则能从目录名得到命令身份 · 官方产品文档因此允许省略 `name`,把它更多用于显示。

这不是谁对谁错 · 而是两个问题不同:

- 开放格式问:离开当前宿主后 · 这个文件夹怎样保持可验证身份?
- Claude Code 问:在已知的本地目录结构里 · 用户要输入哪个 `/skill-name`?

只服务 Claude Code 的个人 Skill 可以依赖目录名推导。准备跨客户端分发的 Skill · 最稳妥的做法仍是显式写出符合开放规范的 `name` 与 `description`。

这条原则也适用于其他扩展字段:

> **可移植核心显式写 · 产品扩展按需加 · 不让扩展字段承担核心语义。**

例如"部署前必须等待用户确认"应该出现在正文 instructions 中 · 不能只依赖某个宿主的手动调用开关。调用开关提供额外保护 · instructions 保留工作流本身的语义。

## scripts 不是把 Skill 变成 Tool

Skill 可以携带脚本 · 但这不意味着 Skill 与 Tool 的边界消失。

Tool 通常由宿主注册 · 有明确调用接口、权限身份与返回协议。Skill 里的 script 是这项能力自带的实现材料 · Claude 仍需要根据 instructions 决定何时通过现有代码执行能力运行它。

两者关系更接近:

```text
Skill instructions
  "先检查版本文件"
        ↓
已有执行能力
  Bash / code execution
        ↓
Skill bundled script
  scripts/validate-version.sh
```

脚本适合承担输入输出明确、重复运行应得到稳定结果的步骤。instructions 更适合承担上下文判断、例外处理与流程编排。

如果把所有确定性逻辑都写成自然语言 · 每次执行都依赖模型重新解释。如果把整个工作流硬编码成一个脚本 · 又失去 Claude 处理上下文和例外的能力。Skill 文件夹允许两者组合 · 而不是要求二选一。

## assets 不是给 Claude 阅读的 reference

`references/` 和 `assets/` 都可能装 Markdown、JSON、图片或模板 · 区别不在文件格式 · 而在用途:

- reference 是**为了帮助 Claude 判断**而读取的资料;
- asset 是**为了生成最终交付物**而使用的材料。

例如 API 规范适合放 references · 报告模板适合放 assets。Claude 可能都要读取 · 但前者进入推理依据 · 后者进入产物制作。

这个区分有助于审阅 Skill:

- 更新 reference · 可能改变 Claude 的判断;
- 更新 asset · 主要改变输出形态;
- 更新 script · 可能改变确定性操作;
- 更新 SKILL.md · 可能改变整个调用与执行流程。

一个文件夹于是拥有了比"prompt 版本号"更清楚的变更边界。

## Custom commands 为什么会并入 Skills

一份旧式 custom command 也能把 Markdown 暴露为 `/deploy`。从用户视角看 · 它已经具备"保存一段可重复调用的 prompt"这一核心能力。

Skills 在此基础上补上了三块结构:

1. description 参与模型自动发现;
2. 文件夹可以携带 supporting files;
3. frontmatter 能表达更完整的调用与执行方式。

因此 Claude Code 继续兼容旧 commands · 同时把 Skills 作为推荐方向。这里的演进不是把斜杠命令换一个名字 · 而是把"用户主动展开一段 prompt"扩展成"用户或模型都能发现的一项能力包"。

但 built-in command 仍不能全部等同于 Skill。某些 command 直接触发产品内部逻辑 · bundled skill 则主要提供 instructions 并编排 Tools。二者可能共享 `/name` 入口 · 背后的执行语义仍不同。

开放标准让能力包可以被识别 · 产品运行时让它真正参与一次 session——这条边界贯穿了这一篇讲过的每一处对照:文件夹里哪几处是可移植核心、哪几处是 Claude Code 自己加上去的字段。两层缺一不可 · 但不应混为一层。

## 下一篇预告

文件夹结构解决了"内容放在哪里" · 还没有回答"Claude 为什么没有在 session 起手时读完全部内容"。下一篇 [02 · 渐进披露 · 从 description 到完整 instructions](02-progressive-disclosure.md) 将沿 metadata、instructions、resources 三层继续推演 · 看一项 Skill 怎样用不同的加载时机交换 context 成本与能力可见性。

## 参考

- Agent Skills 开放规范:[Specification](https://agentskills.io/specification)
- Anthropic Platform 官方文档:[Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Anthropic Claude Code 官方文档:[Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- 上一篇:[00 · 开篇 · 从重复粘贴到可调用能力](00-intro.md)
- [Tool 机制:Claude 怎么用工具](../tool-mechanism.md)
