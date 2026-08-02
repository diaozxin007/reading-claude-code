# 02 · 渐进披露 · 从 description 到完整 instructions

> **TL;DR**:Skill 并不是因为"文件放在磁盘上"就能节省 context,而是通过三次不同的加载决策实现渐进披露:首先,所有 Skill 只用 metadata 争取被发现;被选中后,再加载完整的 `SKILL.md`;只有在实际工作需要时,才继续读取 references 或执行 scripts。每一层都必须为下一层提供明确的触发条件,否则要么过早加载内容,要么能力虽然存在,却始终不会被调用。

上一篇 [01 · 能力格式 · 从一个 Markdown 文件到可移植文件夹](01-format.md) 把 Skill 拆成入口、参考、脚本与资源。文件已经分开 · 但分文件本身不会自动节省任何 token。

真正决定成本的是:**哪一份内容在什么时候进入 Claude 的视野。**

## 如果启动时读完所有 Skill

假设一个团队安装了 40 项能力:

- 发布检查;
- API 设计规范;
- incident 调查;
- 数据库迁移;
- 前端无障碍审查;
- PDF、表格与演示文稿处理;
- 还有各个内部系统的操作流程。

若 Claude 每次 session 启动都读完 40 份 `SKILL.md` 和所有 references · 即使当前任务只是改一个按钮 · 也要携带发布流程、数据库手册和 incident runbook。

这会产生两个问题:

1. **成本问题** · 与当前任务无关的内容提前占据 context;
2. **注意力问题** · 多套流程同时存在 · 模型更难判断此刻应该遵循哪一套。

另一种极端是启动时什么都不告诉 Claude · 等用户准确输入 `/skill-name`。这样虽然省 context · 但模型不知道能力存在 · 无法在相关任务里主动使用。

Agent Skills 选择中间路径:先给一张能力目录 · 再按相关性逐层展开。

## 三层不是三个目录 · 是三次决策

官方用三层描述 Skill 的渐进披露:

```text
Level 1 · Metadata
  name + description
  所有候选 Skill 的发现信息
          ↓ 这项能力与当前任务匹配吗?

Level 2 · Instructions
  完整 SKILL.md body
  激活后需要遵循的操作知识
          ↓ 当前步骤需要更多材料吗?

Level 3 · Resources and code
  references / scripts / assets
  按需读取、执行或使用
```

"三层"不是说文件必须放进三个固定目录 · 而是把一次能力使用拆成三次不同粒度的选择:

1. 从所有能力里选出相关 Skill;
2. 从相关 Skill 中取得核心工作方法;
3. 从能力包内部再选出当前步骤需要的材料。

每向下一层走一次 · 信息更多 · context 成本也更高。因此上一层必须提供足够线索 · 让 Claude 知道是否值得继续展开。

## 第一层 · description 是路由 · 不是简介

`description` 经常被写成一句产品宣传:

```yaml
description: 帮助你更好地完成发布
```

人类可以从 Skill 名字和团队背景猜出意思 · Claude 面对几十项候选能力时却缺少匹配依据。"更好"没有说明做什么 · "发布"也没有说明在哪些请求中应该触发。

一条有效 description 至少要回答两个问题:**这项 Skill 能完成什么(what)· 什么任务或用户表达出现时该用它(when)**。例如:

```yaml
description: 检查代码版本是否具备发布条件 · 在用户准备 release、要求发布前检查或询问版本风险时使用
```

它没有把完整流程塞进 metadata · 但已经给出可匹配的任务和触发语境——用户问"这个版本能发吗" · 这条 description 就是让这句话路由到 release-check、再展开完整 instructions 的匹配条件。

因此 description 的目标不是"准确概括全文" · 而是**让正确请求进入正确能力**。

### description 的两个失败方向

**过窄**:

```yaml
description: 当用户输入"运行 release-check"时使用
```

只有近乎精确的措辞才能命中 · 自动发现失去价值。

**过宽**:

```yaml
description: 与代码质量有关时使用
```

几乎所有编码任务都可能触发 · 一项偶尔使用的能力变成持续噪声。

好的 description 不是关键词堆砌 · 而是在 recall 与 precision 之间划边界:相关任务不要漏 · 相邻但不同的任务不要误入。

## Metadata 的成本小 · 但不是零

渐进披露常被简化成"没调用就没有成本"。更准确的说法是:

> **没调用时只承担发现成本 · 不承担完整 instructions 与 supporting resources 的成本。**

Claude 必须看到候选 Skill 的 name 与 description · 才能主动选择。因此安装的 Skill 越多、description 越长 · 能力目录本身也会增长。

这会改变 metadata 的写法:

- 把最关键的用途放在前面;
- 不在 description 中解释背景历史;
- 不复制完整步骤;
- 避免多个 Skill 使用近乎相同的宽泛描述;
- 用稳定任务语言 · 而不是团队内部只有作者明白的口号。

Metadata 是长期驻留的**索引税**。单项很小 · 数量上升后仍会成为架构问题。

## 第二层 · `SKILL.md` 是激活后的控制面

一旦 Skill 被用户或 Claude 选中 · 完整 `SKILL.md` body 才进入当前工作。此时它不再负责"吸引调用" · 而要接管执行方向。

核心正文适合包含:

1. 当前 Skill 的目标与完成条件;
2. 必须遵守的约束;
3. 主流程与关键判断点;
4. 何时读取哪份 reference;
5. 何时运行哪个 script;
6. 输出格式与验证方式。

例如:

```markdown
## Workflow

1. 检查工作区是否包含未预期改动
2. 运行项目规定的测试与构建
3. 读取版本文件和 changelog
4. 若版本格式不确定 · 查 `references/version-policy.md`
5. 汇总阻断项与非阻断风险
6. 等待用户确认 · 不直接发布
```

正文的价值不在于"写得尽可能详细" · 而在于建立足够稳定的决策骨架。所有 case 都展开在正文里 · 会让少数边缘情况绑架每次激活。只写一句目标 · Claude 又只能临场猜流程。

因此 `SKILL.md` 更像一张控制面——目标、主流程、判断点、资源导航、验证 · 五件事划清楚就够 · 不是一份事无巨细的手册。

## 激活成本会跨越当前步骤

一份普通 prompt 往往只服务当前用户消息。Skill 的 instructions 被加载后 · 可能需要在后续多轮继续影响任务。

这意味着正文里的每一段都不能只按"一次读取成本"衡量。若 Skill 在当前 conversation 中持续生效 · 冗长的背景、重复示例与无关说明会跟随任务继续占用 context。

于是正文与 description 使用相反的优化目标:

| 层 | 首要目标 | 不应该承担 |
|---|---|---|
| description | 精确找到何时激活 | 完整执行步骤 |
| SKILL.md body | 稳定指导激活后的工作 | 所有低频细节 |
| supporting files | 提供特定分支所需细节 | 全局触发判断 |

同一句话如果同时出现在三层 · 通常意味着边界还没有理清。

## 第三层 · Supporting resources 需要二次路由

Skill 被激活后 · Claude 已经知道要做发布检查。但它未必需要读取完整版本规范:

- 版本号明显符合现有格式 → 不读;
- 出现 prerelease 标记或特殊分支 → 读取;
- 只需要生成报告 → 使用模板;
- 需要机械校验 → 运行脚本。

这就是 Skill 内部的第二套路由:

```text
SKILL.md 判断点
  ├─ 格式存在歧义 → references/version-policy.md
  ├─ 需要机械校验 → scripts/validate-version.sh
  └─ 生成交付报告 → assets/release-report.md
```

References 的价值不是"可以放无限内容" · 而是把大内容推迟到正确分支。若入口只写"更多信息见 references" · Claude 仍不知道哪些信息与当前任务相关。

好的资源导航应回答:

- 这份文件包含什么;
- 在什么条件下读取;
- 读取后怎样应用;
- 是否只需局部查找 · 而非全文装入。

Supporting files 不会因为被拆出正文就自动按需。**按需加载来自清楚的决策边界 · 不是目录名称。**

## script 节省的是指令歧义 · 不保证结果便宜

一个脚本可以让 Claude 不必读取实现源码 · 直接执行稳定操作。这通常比用自然语言重新推导算法可靠。

但脚本执行仍会产生输出。若一个检查脚本打印十万行日志 · 即使源码没有进入 context · 输出照样可能淹没当前任务。

因此 scripts 也要符合渐进披露:

- 默认输出摘要 · 详细信息写入文件;
- 失败时给出定位信息 · 不倾倒全部中间状态;
- 支持按目标、文件或阶段缩小范围;
- 让 Claude 能根据结果决定是否继续读取详情。

渐进披露管理的不只是"读哪些文件" · 还包括"执行后返回多少信息"。

## Directory size 不等于 Context size

一个 Skill 文件夹可以很大 · 却不一定立刻消耗大量 context:

```text
磁盘上 20 MB references
  ≠
当前请求里 20 MB context
```

只要入口能准确导航 · 未读取的资料仍停留在磁盘。相反 · 一个只有 30 KB 的 `SKILL.md` 如果每次激活都全文进入当前 conversation · 实际成本可能比大型但按需读取的能力包更高。

因此审计 Skill 不能只看文件夹体积。至少要分别看:

| 指标 | 对应风险 |
|---|---|
| metadata 总量 | 每次发现阶段的固定成本 |
| `SKILL.md` 大小 | 每次激活的基础成本 |
| reference 读取方式 | 特定分支的增量成本 |
| script 输出规模 | 执行阶段的结果成本 |
| 同时激活的 Skills 数量 | 多套 instructions 的竞争与累积 |

这是一套分层账本 · 不是一个"整个目录多少 KB"的数字。

## 和 CLAUDE.md 的加载时机对照

CLAUDE.md 与 Skill 都能保存 instructions · 差别首先不是内容类型 · 而是默认加载时机:

| 载体 | 默认何时出现 | 适合内容 |
|---|---|---|
| CLAUDE.md | session 起手或路径触达 | 广泛成立的项目规则与事实 |
| Skill metadata | 候选能力发现阶段 | 这项能力做什么、何时用 |
| Skill body | Skill 激活后 | 一类任务的完整做法 |
| Skill resources | 工作流需要时 | 大型参考、模板、脚本 |

一段 CLAUDE.md 不断膨胀成多步 procedure · 往往说明它不必每个任务都常驻 · 可以迁移成 Skill。一项 Skill 每次任务都必然激活 · 则可能说明其中部分约束其实应该提升为项目常驻规则。

载体选择不是看 Markdown 语法 · 而是看**适用范围与加载时机是否一致**。

## 渐进披露不是"把长文拆成多个文件"

它让每一层只解决一个选择问题:

```text
description
  选哪项能力

SKILL.md
  选怎样推进任务

supporting resources
  选当前分支需要的材料与执行
```

只有三层之间都有清楚的进入条件 · Skill 才能同时保持**可发现、可执行和低常驻成本**。

## 下一篇预告

渐进披露假设 Claude 已经拿到一张候选能力目录。但 personal、project、parent、nested、additional directory 与 Plugin Skill 并不来自同一个位置。下一篇 [03 · 能力发现 · 从一个目录到 Claude 的候选清单](03-discovery.md) 将回答:**哪些 Skill 会出现在当前 session · 同名能力与路径相关能力又怎样划定作用范围。**

## 参考

- Agent Skills 官方概览:[How do Agent Skills work?](https://agentskills.io/home)
- Agent Skills 开放规范:[Progressive disclosure](https://agentskills.io/specification)
- Anthropic Platform 官方文档:[How Skills work](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Anthropic Claude Code 官方文档:[Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- 上一篇:[01 · 能力格式 · 从一个 Markdown 文件到可移植文件夹](01-format.md)
- [00 · 开篇 · Claude Code 的 200K 账本](../context-management/00-intro.md)
