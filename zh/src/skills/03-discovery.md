# 03 · 能力发现 · 从一个目录到 Claude 的候选清单

> **TL;DR**:一个 Skill 要进入 Claude 的候选清单 · 先要经过文件系统发现 · scope 合并与同名处理 · 再经过路径和调用可见性筛选。Personal、project、managed 与 Plugin 不只是四个安装位置 · 它们分别表达个人习惯、项目能力、组织治理和可分发组件。Nested 与 `paths` 则把"项目可用"进一步收紧为"在相关目录或文件上工作时才相关"。

上一篇 [02 · 渐进披露 · 从 description 到完整 instructions](02-progressive-disclosure.md) 从单项 Skill 内部看三层加载:metadata 用于发现 · 完整 instructions 在激活时出现 · supporting resources 再按需展开。

但 metadata 从哪里来?Claude Code 不会扫描电脑上的每一个 `SKILL.md`。它先要回答一个更基础的问题:

> **以当前工作目录启动的这次 session · 哪些 Skill 有资格成为候选能力?**

## "发现"其实有三道门

用户在磁盘上创建一个 Skill · 不等于 Claude 已经会使用它。中间至少有三层判断:

```text
文件系统发现
  这个位置是不是 Claude Code 会读取的 Skill scope?
        ↓
候选能力暴露
  这项 Skill 是否允许出现在 Claude 的能力目录?
        ↓
任务匹配与激活
  当前请求是否应该加载它的完整 instructions?
```

这三层经常被混为"自动发现":

- 文件放错位置 · 第一层就不存在;
- Skill 只允许用户手动调用 · 文件存在但不必暴露给模型;
- description 没有匹配当前任务 · Claude 知道它存在却没有选择;
- 路径条件不满足 · 它在项目里存在但当前文件不相关。

因此排查"为什么 Skill 没触发"时 · 不能只反复修改 description。要先确认它是否真正进入候选清单。

## 四种 scope · 四种作者关系

Claude Code 官方文档给出四类主要来源:

| Scope | 典型位置 | 谁维护 | 适用范围 |
|---|---|---|---|
| Enterprise / Managed | 组织管理位置 | 管理员 | 组织内所有用户 |
| Personal | `~/.claude/skills/<name>/SKILL.md` | 当前用户 | 用户的所有本地项目 |
| Project | `.claude/skills/<name>/SKILL.md` | 项目团队 | 当前项目 |
| Plugin | `<plugin>/skills/<name>/SKILL.md` | Plugin 作者 | 启用该 Plugin 的环境 |

它们看起来只是四条路径 · 实际上表达四种不同的能力所有权。

### Personal · 我处理事情的通用方式

个人 Skill 适合跨项目反复使用、但不要求团队成员共同安装的能力:

- 个人常用的代码审查流程;
- 自己维护的笔记整理方法;
- 跨仓库通用的提交说明生成;
- 本机已有工具链的操作封装。

它跟着用户走 · 不跟着仓库走。团队成员 clone 项目后不会自动得到它。

### Project · 这个仓库共同拥有的做法

项目 Skill 可以和代码一起进入版本控制:

- 当前仓库的 release checklist;
- 项目特有的数据库迁移流程;
- 内部架构文档的生成方式;
- 针对当前测试框架的验证流程。

它表达的是"参与这个项目的人都可能需要这项能力"。Project scope 因而不仅是方便共享 · 也使 Skill 的变更可以和代码一样被 review。

### Enterprise · 组织统一提供的能力

Managed Skill 适合由组织集中部署的流程、知识和治理要求。它的作者与使用者分离:用户能够调用 · 却不一定能修改来源。

这类 scope 解决的不是个人复用 · 而是组织一致性。后续权限治理篇会再讨论:集中分发 instructions 不等于完成强制 enforcement。

### Plugin · 能力跟随一个可安装组件

Plugin 可以把 Skills 与其他扩展一起分发。它适合完整产品化的能力包:

- Skill instructions;
- supporting scripts 与 assets;
- subagents;
- hooks;
- MCP server 配置或其他 Plugin 内容。

Plugin Skill 的名字带 Plugin namespace。它不会直接和个人或项目 Skill 抢同一个裸名字 · 使用者也能看出能力来自哪个组件。

四种 scope 的选择首先应该问"谁拥有这项能力" · 而不是"哪个路径最方便写"。

## Scope 不是同步机制

把 Skill 放进 personal scope · 只说明它对当前用户的本地项目可用 · 不代表它会自动同步到其他设备或 Claude surface。

同样:

- Project Skill 能随 Git 仓库传播 · 前提是文件被提交;
- Plugin Skill 通过 Plugin 的安装与版本机制传播;
- Claude Code 本地 Skill 不会自动变成 Claude API 或 claude.ai 中的 Skill;
- 云端 session 也不等于能够读取本机 `~/.claude/skills/`。

Scope 回答"在当前产品环境里谁应该看到" · sync 回答"文件怎样到达那个环境"。两者不能用一个 personal / project 标签替代。

## Project 发现不是只看当前目录

在 monorepo 或从子目录启动 Claude Code 时 · 只读取当前目录的 `.claude/skills/` 会产生一个明显问题——如果用户在 `repo/apps/web/` 启动 session · 根目录的 release Skill 还应不应该可用?Claude Code 的答案是会从起始目录向上查找 project Skills · 直到 repository root:

```text
repo/apps/web/       ← session 起点
      ↑ 查父目录
repo/apps/
      ↑
repo/                ← repository root
└── .claude/skills/release-check/  ← 项目级能力
```

这让"从仓库哪个子目录启动"不会改变根项目的共同能力。

但向上查找只解决继承。Monorepo 还有相反需求:某个 package 可能拥有只与自己有关的 Skill。

## Nested Skill · 能力跟着子目录出现

假设前端 package 有独立部署流程:

```text
repo/
├── .claude/skills/deploy/
│   └── SKILL.md
└── apps/web/
    ├── .claude/skills/deploy/
    │   └── SKILL.md
    └── src/
```

根目录 `deploy` 代表项目默认流程 · `apps/web` 下的同名 Skill 代表前端变体。如果 session 一开始就递归扫描整个 monorepo · 任意依赖目录、示例项目和 package 都可能把自己的能力塞进候选清单。

Claude Code 采用按工作路径发现 nested Skills 的方式:当任务开始接触某个子目录中的文件 · 再发现该路径范围内的 `.claude/skills/`。

这形成一种路径邻近性:

```text
当前只改 repo/backend/
  → apps/web 的 Skill 不必出现

开始处理 repo/apps/web/src/
  → apps/web/.claude/skills/ 成为相关候选
```

Nested Skill 不是"优先级更高的全项目配置" · 而是"进入这个目录时才有意义的局部能力"。

## 同名能力为什么不能简单覆盖

个人、项目和组织 scope 中的同名 Skill 需要确定优先关系。官方文档给出的顺序是:

```text
Enterprise
   ↓ override
Personal
   ↓ override
Project
```

这条顺序体现的是治理和个人控制关系 · 但 nested project variants 面临不同问题。根目录和 package 里的 `deploy` 可能都有效 · 不能只用"谁更近"静默消灭另一份流程。

Claude Code 为 nested variant 提供目录限定名称。例如根目录仍可使用 `/deploy` · 子目录变体可以通过类似 `/apps/web:deploy` 的限定名称明确调用。

这比简单覆盖多保留了一层信息:

- 裸名字代表项目主入口;
- 限定名字指出能力属于哪个目录;
- Claude 可以根据当前正在处理的文件判断是否还应采用相关变体。

同名不总是冲突。有时它表示一个全局流程在不同 package 下的补充。命名机制需要先保留这些变体 · 再由当前工作路径决定组合关系。

Plugin 则用 `plugin-name:skill-name` namespace 从根源上避免与其他 scope 争夺裸名字。

## `paths` · 定义相关性而不再复制目录

并不是每项路径相关能力都值得在子目录重复建一份 Skill。一个 API review Skill 可能放在项目根目录 · 但只在处理后端接口文件时自动相关:

```yaml
---
name: api-review
description: 审查本项目 API 设计与兼容性
paths:
  - "services/api/**"
  - "packages/contracts/**"
---
```

`paths` 把两个问题分开:

- **能力归属**:它仍是整个项目维护的一项 Skill;
- **自动相关性**:只有任务接触匹配路径时 · 才应该激活。

Nested Skill 与 `paths` 因而解决不同问题:

| 机制 | 适合场景 |
|---|---|
| Nested Skill | 子目录拥有独立能力包或局部变体 |
| Root Skill + `paths` | 项目共同维护 · 但只服务特定文件范围 |

`paths` 不是文件访问权限。它影响能力何时被认为相关 · 并不构成 sandbox 或阻止 Claude 读取其他文件。把路径激活当安全边界 · 会高估 frontmatter 的治理能力。

## `--add-dir` 的 Skill 例外

`--add-dir` 通常用于给 Claude 增加可访问目录。Claude Code 对 Skills 做了一个特殊处理:附加目录中的 `.claude/skills/` 可以自动进入能力发现。

这适合把共享能力与主仓库分开维护:

```text
product-repo/

shared-engineering/
└── .claude/skills/
    ├── incident-review/
    └── architecture-check/
```

启动时加入 `shared-engineering` · session 就能使用其中 Skills。这个例外不应被泛化成"附加目录里的所有 Claude 配置都会自动加载"。官方文档明确区分 Skills 与 CLAUDE.md、subagents、commands、output styles 等其他配置。

这再次说明 Skill 发现是一套独立能力注册机制 · 不只是普通文件读取。

## Live detection · 候选清单可以在 session 中变化

开发 Skill 时 · 每次修改都重启 Claude Code 会让迭代非常笨重。Claude Code 会监视已经纳入发现范围的 Skill 目录:

- 新增 Skill;
- 修改 `SKILL.md`;
- 删除 Skill;
- 更新候选描述。

这些变化通常能在当前 session 中被发现。一个边缘情况是:session 启动时顶层 skills 目录根本不存在 · 后来才创建整个目录 · 运行时没有预先监视这个位置 · 可能需要重启。

Live detection 解决的是"磁盘定义发生变化后更新候选能力" · 不代表已经加载进 conversation 的旧 instructions 会被倒带替换。文件定义、候选 listing 与当前 context 是三个不同状态。第 08 篇会专门讨论 Skill 生命周期。

## Symlink · 共享文件不应产生重复能力

Personal、project 与 managed Skill 可以通过 symlink 指向其他目录 · 方便在多个位置复用同一能力包。

但 symlink 带来两个判断:

1. 多条路径是否实际指向同一份 Skill?
2. 链接目标是否仍处于可信与可访问边界?

Claude Code 会避免同一目标因为多条路径被重复加载。Plugin 内的 symlink 有自己的分发规则 · 不能直接套用本地 Skill 的行为。

对作者而言 · symlink 更适合个人开发或统一源目录。需要团队稳定分发时 · Plugin 或明确的项目版本控制通常更容易审阅。

## 候选清单不是磁盘清单

走完上述路径后 · 磁盘上"可找到的 Skill"仍不一定全部以相同方式展示给 Claude:

- 只允许用户调用的 Skill · 不需要靠 description 诱导模型;
- 路径条件尚未满足的 Skill · 暂时不相关;
- nested Skill 尚未触达对应目录 · 还没有被发现;
- 某项能力可能被本地 visibility 设置隐藏;
- 多个来源可能因优先级、namespace 或限定名称被重新组织。

因此候选清单是运行时根据当前 session 构造的**能力视图**:

```text
磁盘上的 Skill 定义
        ↓ scope / parent / nested / add-dir
可发现集合
        ↓ precedence / namespace / path / visibility
当前候选清单
        ↓ description 与用户请求
实际激活的 Skill
```

把这四层分开 · 才能判断问题到底出在安装、作用域、暴露还是匹配。Skill discovery 因此不是一次 `find SKILL.md`——**Scope 决定谁拥有 · parent / nested 决定从哪里继承 · namespace 决定怎样共存 · paths 决定何时相关**。只有进入这张清单之后 · description 才有机会完成上一篇所讲的第一层路由。

## 下一篇预告

候选清单已经生成 · 下一步才真正回到"像 Tool"的部分:用户输入 `/release-check` 与 Claude 主动选择 `release-check` · 是否走同一条调用路径?下一篇 [04 · 能力调用 · 从用户请求到 Skill 激活](04-invocation.md) 将拆开手动调用、模型调用、bundled skill 与 built-in command 的边界。

## 参考

- Anthropic Claude Code 官方文档:[Where skills live](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Discovery from parent and nested directories](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Skills from additional directories](https://code.claude.com/docs/en/slash-commands)
- Anthropic Platform 官方文档:[Cross-surface availability and sharing scope](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- 上一篇:[02 · 渐进披露 · 从 description 到完整 instructions](02-progressive-disclosure.md)
- [01 · CLAUDE.md 家族 · 5 层 hierarchy 与 3 种混装](../memory/01-claude-md-family.md)
