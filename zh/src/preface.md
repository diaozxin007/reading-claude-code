# 前言

之前研究过 Claude Code 的设计 · 用 Java 写了一个乞丐版的 Claude Code · 开源地址 [jooj](https://github.com/diaozxin007/jooj)。Claude Code 的 tools 都设计的非常精巧。所以想逐个研究一下。大家共同学习。

## 为什么写这本书

Claude Code 表面看,就是一堆平平无奇的 tool call —— Read / Edit / Bash 之类。但仔细读每个工具的 description 时,会发现里面有大量看似「啰嗦」的约束:

- Edit 强制要求先 Read 过才能改
- Read 每一行都加了「行号 + tab」前缀
- Bash 用一整段警告说别用 amend
- WebFetch 反复强调「认证 URL 会失败,先看 MCP 有没有」

这些约束是从哪里来的?

答案是:**血泪教训**。每一条 prompt 约束背后,都是一次 AI 干过的蠢事、一次用户的踩坑、一次 Anthropic 团队复盘出的经验。

**工具的形状本身,就是一份工作方法论**。

这本书就是想拆开这些工具 —— 看看每一个字段名、每一条 prompt 约束、每一次 runtime 硬阻断,分别在防 AI 犯什么错、承载什么、教 Claude 什么。

写完 jooj 那次 reverse engineering 后 · 对官方版本的很多设计选择有了更深的体会 —— 那些看着「简单」的字段,其实每一个都是精心设计的取舍。这本书某种意义上就是那次实践的产物 · 只不过用了更容易阅读的形式呈现。

## 这本书讲什么

全书从四条线拆解 Claude Code：

- **Tools** —— 具体能力如何通过 schema、prompt 和 runtime 约束交给模型
- **Agent Loop** —— 模型调用、工具执行、状态迁移、恢复和中断如何组成自动循环
- **Context** —— 每次调用的信息如何装配、缓存、压缩和按需加载
- **Memory** —— 哪些信息能够跨 session 留下来，并在下一次对话中重新生效

四部分分别回答“能做什么”“事情怎么发生”“信息怎么组织”和“哪些信息能够留下”。

## 这本书**不**讲什么

- 不是《Claude Code 使用手册》 —— 不教你怎么装、怎么配 keybindings
- 不是《AI Prompt 工程教程》 —— 只讲工具层的 prompt · 不讲通用 prompt 技巧
- 不是《LLM 原理入门》 —— 假设读者了解 tool call、system prompt 是什么

## 怎么读这本书

**从头读**:章节按分层组织 · 前面章节的概念在后面会被复用。特别是「Tool 机制」这一章 · 提供了整套系列的心智模型。

**跳读**:每一章可以独立读。想直接看某个具体工具怎么设计的 · 直接翻过去。

第一部分的工具章节采用六段式结构:

1. **作用** —— 这个工具解决什么问题
2. **一个具体例子** —— 用真实场景说清"没有这工具会怎样 vs 用了怎样"
3. **触发条件** —— 该用 / 不该用的边界
4. **技术实现** —— 参数设计 / runtime 行为 / harness 协作
5. **prompt 详解** —— 逐条拆解官方 tool description 里的约束
6. **小结** —— 精妙之处 + 与其它工具的对照

## 事实核对纪律

这本书里每一段引用 tool description 的地方,都尽量贴的是**官方原文**(英文 · 保留原始表述)。翻译或加工的内容 · 会明确用「我的理解是...」或类似标注区分开。

这条纪律来自一次写作过程中的自我打脸 —— 详见 [AskUserQuestion](interaction/ask-user-question.md) 篇的开头。

## 参与

- 发现内容错误 / 有更好的观察角度 → 提 [Issue](https://github.com/diaozxin007/reading-claude-code/issues)
- 想补章节 / 修文字 → 欢迎 PR
- English version → 见 [en/ 目录](https://github.com/diaozxin007/reading-claude-code/tree/main/en)

---

准备好了 · 从下一章 [Tool 机制:Claude 怎么用工具](tool-mechanism.md) 开始。
