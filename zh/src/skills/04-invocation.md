# 04 · 能力调用 · 从用户请求到 Skill 激活

> **TL;DR**:用户输入 `/release-check` 与 Claude 主动选择 `release-check` 有不同入口 · 却都要把 Skill 从候选 metadata 展开成当前任务的完整 instructions。Skill 调用的直接结果不是"发布完成" · 而是"这套工作方法进入执行现场"。`disable-model-invocation` 与 `user-invocable` 控制谁能打开这扇门 · 不负责保证门后的每一步一定执行。

上一篇 [03 · 能力发现 · 从一个目录到 Claude 的候选清单](03-discovery.md) 解释了一项 Skill 怎样经过 scope、目录、namespace 与路径条件进入候选能力视图。

现在假设候选清单里已经有:

```text
release-check · 检查代码版本是否具备发布条件
```

它什么时候从一行 description 变成真正影响任务的 instructions?有两个入口:

```text
用户明确调用
  /release-check

Claude 主动调用
  "这个版本能发吗?"
      ↓ description 匹配
  选择 release-check
```

两者都叫"调用 Skill" · 但发起者、可控性和适用场景不同。

## 手动调用 · 用户直接选择能力

用户输入:

```text
/release-check
```

这不是在普通聊天里提到一个文件名 · 而是在明确指定"请加载并采用这项 Skill"。用户已经完成了能力选择 · Claude 不需要先从几十条 description 中猜哪项最相关。

手动调用适合三类任务:

1. **用户掌握时机** · 只有用户知道现在正式进入 release 阶段;
2. **动作可能产生副作用** · deploy、commit、发送消息、更新外部系统;
3. **流程成本较高** · 深度 review、完整验证、批量处理 · 不希望模型顺手触发。

用户也可以附带参数:

```text
/release-check v2.4.0
```

运行时把参数渲染进 Skill instructions · Claude 得到的不只是"使用 release-check" · 而是针对 `v2.4.0` 的具体任务。参数怎样替换、动态上下文怎样插入 · 留到下一篇展开。

手动调用提供的是**入口控制**。它不意味着 Skill 变成传统 CLI command:加载完成后 · 仍是 Claude 阅读 instructions、判断环境并使用 Tools 推进。

## 模型调用 · Claude 从候选清单中选择

用户也可能完全不知道 Skill 名字:

```text
帮我看看这个版本现在能不能发布 · 有哪些阻断项?
```

若 `release-check` 的 description 与请求匹配 · Claude 可以主动选择这项 Skill。此时模型先完成一次能力路由:从用户意图出发 · 比对候选 name 与 description · 选中 release-check 后再请求加载完整 Skill。

这个入口最像普通 Tool selection。Claude 看到能力描述 · 判断是否相关 · 再发起结构化调用。但普通 Tool 调用后会立即进入对应 executor · Skill 调用后首先得到的是 instructions。

模型调用适合:

- 用户只描述目标 · 不应该记忆内部能力名;
- 一项知识应在相关任务中自然参与;
- 多个 Skill 可能根据上下文组合;
- 能力本身没有用户必须控制的高风险时机。

自动选择让 Skill 从"保存过的命令"升级为"Claude 能自主发现的能力"。

## 两条入口 · 一个汇合点

可以把调用过程简化成:用户输入 `/release-check v2.4.0` 或 Claude 主动选择 `Skill(release-check)` · 两条入口在这里汇合——都要先找到 Skill 定义 · 再渲染 arguments 与 dynamic context · 拿到完整 instructions 进入任务 · 最后由 Claude 编排已有 Tools。

入口之前 · 两者不同:

- 手动调用由用户完成选择;
- 模型调用由 description 与当前请求共同完成选择。

汇合之后 · 两者都要解决相同问题:

- 找到对应 Skill;
- 取得完整 `SKILL.md`;
- 处理参数与动态内容;
- 把最终 instructions 放入正确 context;
- 让 Claude 继续执行工作流。

因此"用户能输入 `/name`"与"Claude 能主动使用"是两项独立能力 · 不是同一个开关的两种表现。

## Skill 调用完成了什么

观察下面两个动作:

```text
Read(file)
  → 返回文件内容

Skill(release-check)
  → 加载发布检查 instructions
```

Read 的 tool result 就是动作产物。Skill 的直接产物只是新的操作知识。真正的发布检查还没有完成 · Claude 接下来可能继续:

1. 读取 git 状态;
2. 运行测试;
3. 检查版本文件;
4. 读取 changelog;
5. 输出风险报告。

这揭示 Skill 与 Tool 的关键差别:

> **普通 Tool call 改变或观察外部状态 · Skill call 改变当前 agent 接下来怎样工作。**

当然 · 一项 Skill 也可以进入 forked subagent 独立完成任务并返回结果。但那是执行 context 的变化 · 不改变 Skill 以 instructions 驱动工作的本质。

## `/name` 只是共同入口 · 背后可能不是同一种东西

在 Claude Code 交互界面里 · `/compact`、`/release-check` 与 bundled skills 都通过斜杠名称出现。相同的输入形式很容易让人以为它们都是 Markdown prompt。

实际上至少要区分三类:

| 类型 | 核心内容 | 调用后发生什么 |
|---|---|---|
| Built-in command | 产品内部逻辑 | 直接执行 Claude Code 功能 |
| Bundled Skill | Anthropic 提供的 prompt-based workflow | 加载 instructions · 编排 Tools |
| Custom Skill | 用户、项目或 Plugin 提供的能力包 | 加载自定义 instructions 与资源 |

Built-in command 可能切换模式、管理 session 或打开产品界面 · 它不必把一段工作方法交给模型。Bundled Skill 与 custom Skill 则主要通过 instructions 指导 Claude 完成任务。

所以判断一项 `/name` 的性质 · 不能只看它是否有斜杠。真正的分界是它直接触发固定产品逻辑(→ command)· 还是加载 instructions 让 Claude 编排工作(→ Skill)。用户入口统一 · 执行语义没有统一。

## Custom commands 为什么还能继续工作

旧式 custom command 也是一份通过 `/name` 展开的 Markdown。Claude Code 将这类 prompt-based commands 合并到 Skills 的能力模型中 · 旧目录仍保持兼容。

两者共享的核心路径是:用户或模型选择名称 → 展开 prompt-based content → Claude 继续执行。

Skills 在此基础上增加 supporting files、自动发现、调用控制和更多执行选项。因此迁移方向不是"命令语法废弃" · 而是"单文件 prompt 逐步升级为完整能力包"。

若同名 Skill 与旧 custom command 同时存在 · Claude Code 优先采用 Skill。继续保留两份同名定义只会让维护者误判实际生效来源 · 更稳妥的做法是完成迁移后删除重复入口。

## 谁能调用 · 两个独立开关

默认情况下 · 用户和 Claude 都可以调用一项 Skill:

| 配置 | 用户可调用 | Claude 可调用 | 典型用途 |
|---|---:|---:|---|
| 默认 | 是 | 是 | 普通可复用工作流 |
| `disable-model-invocation: true` | 是 | 否 | deploy、commit 等用户控制时机的流程 |
| `user-invocable: false` | 否 | 是 | 背景知识、内部约定等模型按需加载内容 |

两个字段解决不同问题:

- `disable-model-invocation` 问:Claude 能否主动选择它?
- `user-invocable` 问:它是否应该作为用户命令出现?

### 只让用户调用

```yaml
---
name: deploy-production
description: 将当前版本部署到生产环境
disable-model-invocation: true
---
```

部署 Skill 仍然可以包含完整检查流程 · 但不会因为 Claude 判断"代码看起来准备好了"就自行激活。用户必须明确输入命令。

### 只让 Claude 调用

```yaml
---
name: legacy-system-context
description: 旧订单系统的领域约束 · 处理 legacy order 代码时使用
user-invocable: false
---
```

这类 Skill 更接近按需 reference。用户不需要输入一个没有动作语义的 `/legacy-system-context` · Claude 在相关任务中加载即可。

调用方向应来自能力性质 · 不应该全部保留默认值。

## "只允许用户调用"为什么会减少发现成本

模型要主动调用某项 Skill · 就必须在候选 context 中看到它的 name 与 description。若一项 Skill 明确禁止模型调用 · 继续向模型长期展示 description 没有意义。

Claude Code 因此把调用控制也连接到能力暴露:模型可调用的 Skill · metadata 需要长期留在候选清单里;仅用户调用的 Skill · 用户已经通过 `/name` 完成定位 · metadata 不必再承担模型匹配的职责。

这说明 invocation control 不只是权限语义 · 也影响渐进披露第一层的 context 成本。

反过来 · `user-invocable: false` 只隐藏用户入口 · Claude 仍需要 description 才能主动选择。

## 用户调用不等于用户批准所有后续动作

用户输入 `/release-check` · 只明确批准"采用这套检查流程"。它不一定意味着:

- 允许执行任意 shell command;
- 允许修改所有文件;
- 允许发布到生产;
- 允许跳过 workspace trust;
- 允许绕过 sandbox。

Skill 可以声明某些工具预授权 · Claude Code 也可以为 Skill 设置 permission rules · 但这些是下一层治理。调用身份只回答"谁能启动能力" · 不应该被误解为"能力启动后拥有无限权限"。

同样 · `disable-model-invocation` 也不是完整安全边界。它防止 Claude 通过正常 Skill 调用入口主动激活 · 但 Skill 文件仍在磁盘上 · 相关脚本和外部系统还需要自己的权限与隔离。

## 用户调用也不等于确定性执行

一项 Skill 写着:

```markdown
1. 运行测试
2. 检查版本号
3. 输出报告
```

即使用户明确输入 `/release-check` · 后续仍由模型解释 instructions。环境缺少测试命令、上下文出现冲突、工具调用失败时 · Claude 需要判断怎样恢复。

所以手动调用提供的是**确定的选择** · 不是**确定的执行轨迹**。

若某一步必须无条件、机械地执行 · 应考虑:

- 用 script 固化步骤;
- 用 Hook 在固定事件触发;
- 用 permissions 阻断不允许的动作;
- 用 CI 或外部系统验证最终结果。

Skill 负责行为指导 · 不应独自承担 enforcement。

## 一项 Skill 可以和其他 Skill 组合

Skill 调用不是把 session 切换成互斥模式。一个任务可能同时需要:

```text
release-check
  + security-review
  + changelog-style
```

它们的 instructions 会共同影响后续工作。这是 Skill 能力组合的来源 · 也是冲突风险的来源:

- 两项 Skill 是否要求不同输出格式?
- 是否给出相反的工具使用顺序?
- 是否都认为自己拥有完整主流程?
- 哪一项只应提供 reference · 哪一项才是 task workflow?

组合能力不是简单把更多 prompt 加起来。Skill 边界越清楚 · instructions 越容易协作。每项都声称接管整个任务 · 同时激活时就会互相竞争。

`disable-model-invocation` 与 `user-invocable` 先决定一项 Skill 由谁发起 · 还没有决定它在主 conversation 还是 subagent 中执行——后者属于 execution context · 留到第 06 篇处理。Skill invocation 的本质因此不是执行一个保存好的宏 · 而是把一套按需操作知识带进当前任务:**用户调用提供确定的选择 · 模型调用提供自动的路由 · 两者最终都把 instructions 交给 Claude · 再由 Tools 把做法变成动作。**

## 下一篇预告

Skill 已经被选中 · 但磁盘里的正文还不是 Claude 最终看到的内容。`$ARGUMENTS`、位置参数、Skill 目录变量与动态 shell 输出都会在进入 context 前改变 prompt。下一篇 [05 · Prompt 渲染 · 从参数到动态上下文](05-prompt-rendering.md) 将拆开这层预处理 · 并回答一个安全问题:**Claude 没看到的命令 · 为什么可能已经执行了?**

## 参考

- Anthropic Claude Code 官方文档:[Control who invokes a skill](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Restrict Claude's skill access](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Bundled skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Commands](https://code.claude.com/docs/en/commands)
- 上一篇:[03 · 能力发现 · 从一个目录到 Claude 的候选清单](03-discovery.md)
- [Tool 机制:Claude 怎么用工具](../tool-mechanism.md)
- [01 · 从 tool 声明到执行前的批准](../agent-loop/01-tool-permission.md)
