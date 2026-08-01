# 前言 · 从“帮我修个 bug”到生产级 Agent

打开 Claude Code，输入一句：

> 帮我看看这个 bug。

接下来发生的事情，看起来很自然：Claude 搜索代码、读取文件、修改实现、运行测试；遇到失败会调整方案，context 快满时会压缩历史，下一次打开项目时还可能记得之前留下的规则。

但只要把这个过程拆开，问题会立刻变多：

- 模型为什么知道有哪些工具可以使用？
- 用户只输入一次，Agent 为什么能连续工作很多轮？
- 每次调用模型时，200K context 里究竟装了什么？
- 对话关闭以后，哪些信息还能留到下一次 session？

这四个问题，正好对应本书的四个部分：**Tools、Agent Loop、Context、Memory**。

## Claude Code 不只是一组 Tools

最初研究 Claude Code，很容易从 Read、Edit、Bash 等工具开始。它们是最容易看到的部分，也是很好的入口。

仔细阅读 Tool description 后，会发现里面充满了看似啰嗦的限制：

- Edit 要求修改前先读取文件。
- Read 给每一行加上固定格式的行号。
- Bash 对 Git 操作设置了大量安全提醒。
- WebFetch 会提醒模型优先检查已有的专用能力。

这些约束不是装饰。每一个字段、每一句 Prompt、每一道 runtime 拦截，都在解决模型曾经容易犯的某类错误。

> **工具的形状，本身就是一份工作方法论。**

但研究继续深入后会发现：Tools 只回答“Agent 能做什么”，无法解释整个系统。

- 没有 Loop，工具只能被调用一次，无法形成自主任务。
- 没有 Context 管理，历史会持续膨胀，模型也不知道当前应该看到什么。
- 没有 Memory，session 结束后，重要信息就无法跨时间存活。

因此，这本书最终形成了四条互相连接的研究线：

```text
Tools    —— Agent 有哪些能力
Loop     —— 这些能力怎样连续运转
Context  —— 每一次运转时，模型看见什么
Memory   —— 时间跨过 session 后，哪些信息还能留下
```

四部分放在一起，才构成一个生产级 Agent 的完整形状。

## 第一部分 · Tools · 能力怎样被交给模型

第一部分从 Tool 协议开始，逐个拆解 Claude Code 的核心工具。

这里关注的不只是“这个工具有什么参数”，而是四层契约：

1. **Schema** 怎样把能力描述给模型。
2. **Prompt** 怎样引导模型选择正确的使用方式。
3. **Runtime** 怎样执行那些不能只靠模型自律保证的约束。
4. **Tool Result** 怎样把结果重新送回模型，影响下一步判断。

这一部分回答：**怎样设计一个模型真正会用、而且不容易用错的工具。**

## 第二部分 · Agent Loop · 一次输入怎样变成连续执行

普通聊天模型回答一次就结束；Agent 会在一次用户输入后持续调用模型和工具。

第二部分从 5 行 loop 伪代码出发，一路展开到：

- 工具声明与权限批准
- Hooks 与并行调度
- `stop_reason` 与状态转换
- Streaming 与逐字显示
- 重试、恢复和 Interrupt
- 主代理与 Sub-agent 复用同一套 Loop

这一部分回答：**“AI 自主推进任务”在工程上究竟怎样发生。**

## 第三部分 · Context · 每次调用到底发送什么

LLM 本身没有会话状态。所谓“Claude 记得刚才说过什么”，其实是客户端在下一次调用时重新发送相关信息。

于是新的问题出现了：

- Tools、system prompt 和 messages 怎样共同占用 context window？
- 为什么 messages 数组有不能破坏的结构？
- Prompt Cache 为什么会反过来塑造整个系统？
- CLAUDE.md 为什么放在 messages，而不是固定 system prompt？
- 历史太长后，Compaction 怎样压缩又不破坏任务？

这一部分回答：**在有限的 context 预算内，怎样持续给模型装配正确的信息。**

## 第四部分 · Memory · 哪些信息能够跨 session 留下来

Context 解决当前调用，Memory 解决时间跨度。

第四部分沿着信息的完整生命周期展开：

- 谁把信息写下来？
- 写进 CLAUDE.md、MEMORY.md，还是 Memory Tool？
- 信息属于个人、项目、团队，还是某个 Sub-agent？
- 下一次 session 什么时候重新加载？
- Compaction 之后，哪些记忆会自动回来？

这一部分回答：**一次对话结束后，信息怎样继续存活，并在未来重新进入 Context。**

## 四部分之间的关系

这四部分不是四套彼此独立的知识。

一次完整的 Agent 行为通常是：

```text
Memory 提供跨 session 留下的信息
              ↓
Context 把当前需要的信息装进一次请求
              ↓
Loop 驱动模型持续判断和行动
              ↓
Tools 对外部世界执行读取、修改和查询
              ↓
Tool Result 回到 Context，Loop 继续下一轮
              ↓
值得长期保留的信息再次沉淀进 Memory
```

也可以压缩成四句话：

> Tools 讲能力。
>
> Loop 讲执行。
>
> Context 讲信息。
>
> Memory 讲时间。

## 这本书采用什么研究方法

本书不是按源码目录逐个解释类和函数，而是采用一条相对稳定的推演路径：

1. **从可观察现象开始** —— 用户在界面上看到了什么？
2. **找到背后的约束** —— API、模型或运行环境不允许什么？
3. **还原机制** —— Claude Code 怎样在这些约束下组织系统？
4. **分析取舍** —— 为什么选择这种设计，而不是更直觉的方案？

Tools 部分会进一步使用“作用、例子、触发条件、技术实现、Prompt / Schema、小结”的拆解结构；Loop、Context 与 Memory 则围绕各自的主线展开。

目标不是背诵实现细节，而是理解：

> **面对相同约束，一个成熟 Agent 系统为什么会长成现在这样。**

## 事实与版本边界

本书同时使用三类材料：

- Anthropic 官方文档与公开的 Tool description
- Claude Code v2.1.220 源码研究
- 实际运行行为与可复现的验证

为了区分事实和推断，正文遵循几条纪律：

- 直接引用尽量保留原始英文，并附来源。
- 源码级结论在文末给出文件定位。
- 无法直接证明的解释，会明确标成推论或设计理解。
- Claude Code 会持续更新；版本相关结论应结合文中标注的研究版本阅读。

## 这本书不是什么

- **不是 Claude Code 使用手册** —— 不以安装、快捷键和日常命令为主线。
- **不是通用 Prompt 教程** —— Prompt 只在解释具体机制时出现。
- **不是逐行源码注释** —— 重点是约束、架构和设计取舍。
- **不是唯一正确的 Agent 架构** —— Claude Code 是一个成熟样本，不是所有系统都必须复制的模板。

## 怎么读

### 第一次系统理解 Agent

建议从头开始，依次阅读 Tools → Loop → Context → Memory。四部分的时间尺度逐渐扩大，前面的概念会成为后面的基础。

### 已经在开发 Agent

可以先从最接近当前问题的部分进入：

- 正在设计 Tool → 第一部分
- 正在实现自主执行循环 → 第二部分
- 正在处理 token、cache 或 compaction → 第三部分
- 正在设计跨 session 记忆 → 第四部分

每篇都尽量保留前置说明和相关链接，允许跳读；但各部分内部仍建议按顺序阅读。

## 参与

- 发现事实错误或有新的验证结果 → 提 [Issue](https://github.com/diaozxin007/reading-claude-code/issues)
- 想修正文或补充章节 → 欢迎提交 PR
- English version → 见 [en/ 目录](https://github.com/diaozxin007/reading-claude-code/tree/main/en)

---

从第一部分的 [Tool 机制：Claude 怎么用工具](tool-mechanism.md) 开始，先看一项能力是怎样被交到模型手里的。
