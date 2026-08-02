# 00 · 开篇 · 从重复粘贴到可调用能力

> **TL;DR**:Skill 把反复粘贴的说明、检查清单与多步流程包装成一项按需能力。Claude 平时只需要知道它的名字和用途 · 真正相关时才加载完整 instructions · 然后使用已有 Tools 完成工作。它像 Tool 一样参与能力选择 · 但不是新的原子 executor。

准备发布一个版本时,你大概率要把这段话重新讲一遍给 Claude:

```text
先检查工作区 · 再跑测试 · 生成 changelog · 核对版本号 ·
最后列出准备发布的文件 · 没有得到确认前不要真正发布。
```

这段话不是项目里永远成立的静态事实——不该塞进 CLAUDE.md · 让每个任务都为一条偶尔才用的流程付出 context。它也不是一次只做一个动作的 Tool——它要按顺序调好几样东西:看 git 状态、跑测试、读 changelog、汇总风险。它是一套会反复用到的**工作方法** · 只是每次都要手动重新交代一遍。

留在聊天里 · 下一次 session 还要再贴一遍。这就是 Skill 要解决的问题:**怎样让一套操作知识长期存在 · 却只在需要时才进入当前任务。**

## 先存成文件夹 · 待在候选清单里不展开

把刚才这段发布检查话术存成一个叫 `release-check` 的文件夹:

```text
release-check/
└── SKILL.md
```

`SKILL.md` 分成两半:

```markdown
---
name: release-check
description: 检查版本是否具备发布条件 · 在准备 release 时使用
---

1. 检查工作区状态
2. 运行测试与构建
3. 核对版本号和 changelog
4. 汇总风险 · 等待用户确认
```

frontmatter 那几行(`name`、`description`)——本系列后文统一称为 **metadata**——不是工作流正文 · 是能力目录里的一条索引:它平时就待在 Claude 的候选清单里 · 不占什么 context。真正的四步指令——SKILL.md 里 frontmatter 之外的正文部分 · 本系列后文统一称为 **instructions**——只有在某次任务被判定"这跟 release-check 相关"之后 · 才会展开、读进当前上下文。

官方把这种分阶段加载称为 **progressive disclosure(渐进披露)**。装的 Skill 越多 · 平时占用的 context 不会跟着涨——因为大多数 Skill 的正文根本没被展开过。

## 选不选它 · 跟选 Tool 是同一套动作

用户问"这个版本能发布吗" · Claude 面前不是一段普通 Markdown。它要先判断:当前任务是否匹配 release-check 的 description、要不要调用它、调用后怎么继续。

这跟 Tool selection 的过程很像——Tool 也是先亮出名字、用途、输入 · 模型判断何时调用。release-check 同样靠一段可被发现的 description 参与选择 · 用户也可以用 `/release-check` 直接点名调用。

所以 Skill 不是 CLAUDE.md 的另一个文件名——CLAUDE.md 是每次 session 都带上的常驻规则 · release-check 这样的 Skill 是能力架上一个平时不露面、被选中才登场的候选项。

但"参与选择的方式像 Tool" 不代表它就是 Tool。

## Tool 给动作 · Skill 给做法

Tool 的终点是一个确定的执行器——Read 读文件 · Bash 跑命令 · 模型发起一次 tool call · 运行时执行、返回结果。

release-check 展开之后 · 终点不是一次执行 · 而是一组 instructions:先用 Bash 看 git 状态 · 再跑测试 · 用 Read 核对 changelog · 最后只输出一份风险汇总 · 等用户确认。四步谁先谁后、看到什么才继续、什么时候该停下——这些判断沉淀在 SKILL.md 里 · 真正改变外部世界的还是 Bash、Read 这些已经存在的 Tool。

**Tool 把 Claude 从"只能说"变成"能够做" · Skill 把"能够做"组织成"知道怎样稳定地完成一类工作"。**

## 四步之外 · 还能带更多东西

如果 release-check 只有那四步 Markdown · 它已经比聊天里存的 prompt 多出"可发现、可复用、按需加载"三种性质。但它是个文件夹 · 还能继续放东西进去——这些跟 instructions 一起打包、但不在 SKILL.md 正文里的材料 · 本系列后文统一称为 **supporting resources**:

一份 `references/version-policy.md` · 记着这个项目对版本号的具体约定——Claude 判断"这次改动该不该升大版本"时才去读 · 平时不占地方。一个 `scripts/validate-version.sh` · 把"版本号格式对不对"这种能写死的判断交给脚本 · 而不是每次都让模型自己现场数。一份 `assets/release-report.md` 模板 · 发布报告照着它填。

四步 instructions 回答"现在具体要怎样完成" · `version-policy.md` 回答"处理这类问题时应该知道什么"——前者是 **Task content** · 后者是 **Reference content**。两者都按需进入 context · 但适合的调用方式不同 · 下一篇会把这个文件夹结构拆开细讲。

## 装好之后 · 还有几个问题没答案

装好 release-check 之后 · 还有几个问题没答案:它是自己一个人躺在项目里 · 还是能被同事共享、被公司统一下发?用户敲 `/release-check` 手动点名 · 和 Claude 自己看描述觉得"这个任务该用它了"——是同一条激活路径吗?展开之后的四步 · 是在当前对话里接着跑 · 还是会被单独派出去一个 subagent 执行 · 执行完只带一份摘要回来?如果 SKILL.md 里写了"允许跑 Bash 但不允许联网" · 这条限制谁来把关?

这几个问题分别对应**发现**(Claude 怎么知道有这项能力)、**激活**(为什么在此刻被选中)、**执行**(instructions 在哪个 context 里运行)、**治理**(谁能分发、调用、授权)。它们最后会收在一条判断标准上:**稳定事实放进常驻规则 · 原子动作做成 Tool · 可复用操作知识做成 Skill**——但那是收尾篇才展开的内容 · 这里先把问题摆出来。本系列接下来沿着 release-check 这类 Skill 的完整生命周期 · 依次回答这四个问题 · 而不是逐字段翻译官方文档。

## 三层内容 · 三种成本

release-check 的文件夹结构不是资料分类习惯 · 而是在安排不同内容什么时候该出现:

| 层 | 平时是否在 context | release-check 里对应什么 |
|---|---|---|
| metadata | 是 | `name`、`description` |
| SKILL.md body | 激活后 | 四步指令 |
| supporting resources | 按需 | `version-policy.md`、`validate-version.sh`、`release-report.md` |

description 写得太模糊 · Claude 遇到发布任务也想不起有 release-check 这回事;写得太长 · 每个 session 都要为这几行多付一点 context。四步指令里塞进太多细节 · 一次激活就把大段判断逻辑带进当前任务;references 没人告诉 Claude 什么时候该读 · 文件躺在那儿也没用。能写成脚本的判断继续留在 instructions 里 · 靠模型每次现场发挥 · 反而不如脚本稳定。

## 下一篇预告

现在已经知道 release-check 这类 Skill 不只是一段 prompt · 而是一个可发现、可展开、可附带资源的能力文件夹。下一篇 [01 · 能力格式 · 从一个 Markdown 文件到可移植文件夹](01-format.md) 会先划清一条边界:release-check 这个文件夹格式 · 哪些是 Agent Skills 开放标准规定的最小结构 · 哪些是 Claude Code 自己加上去的产品能力。

## 参考

- Anthropic Claude Code 官方文档:[Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Platform 官方文档:[Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Agent Skills 开放规范:[Specification](https://agentskills.io/specification)
- [Tool 机制:Claude 怎么用工具](../tool-mechanism.md)
- [00 · 开篇 · Claude Code 的 200K 账本](../context-management/00-intro.md)
