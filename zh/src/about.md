# About

## 关于作者

**diaozxin007** —— 后端工程师 · Java 出身 · 近两年主要在做 AI Agent 应用与实践。

### 相关项目

- **[jooj](https://github.com/diaozxin007/jooj)** —— Java 版的 Claude Code 精简复现。这本书的**元前提** —— 因为写过 jooj · 才对官方版本的很多设计取舍有了具体的体感。
- **[text2diagram](https://text2everything.vip/)** —— 自然语言 → Mermaid 图的 Agent 应用。走 chat-based agent + repair loop 架构 · 支持多种 diagram 类型。
- **博客** —— [xilidou.com](https://xilidou.com) · 记录 AI Agent / 分布式系统 / Java 技术相关的实践思考。

### GitHub / 联系

- **GitHub**:[@diaozxin007](https://github.com/diaozxin007)
- **Issues**:发现内容错误 / 有建议 / 想投稿 · 请在 [reading-claude-code Issues](https://github.com/diaozxin007/reading-claude-code/issues) 提

---

## 关于这本书

### 定位

《一同读 Claude Code》从 16 个核心工具出发，继续深入 Agent Loop、Context 管理和跨会话 Memory，一层层拆解 Claude Code 的内部机制与设计哲学。

它不是 Claude Code 使用手册，也不是通用 Prompt 工程教程，而是一次面向工程设计的深度阅读。

### 写作过程

这本书的正文完全是**人 + Claude 一起协作沉淀**出来的。方法论:

1. 每篇按**六段式结构**推进(作用 / 具体例子 / 触发条件 / 技术实现 / prompt 详解 / 小结)
2. 所有 tool description 的引用**必须贴英文原文** —— 事实核对纪律
3. 每次 review 发现的问题反哺方法论 · 沉淀成下一篇的加速器

全书从 Tools 扩展到 Agent Loop、Context 与 Memory，写作方法也从工具六段式逐步演化为按机制主线组织的系列研究。

### 技术栈

| 环节 | 工具 |
|---|---|
| **写作** | Obsidian + Claude Code |
| **静态站生成** | [mdBook](https://rust-lang.github.io/mdBook/)(Rust 生态 · 官方支持) |
| **持续构建 & 部署** | GitHub Actions · 每次 push 到 main 自动 build + 部署 |
| **托管** | GitHub Pages |
| **域名** | `diaozxin007.github.io/reading-claude-code/`(暂用 GitHub 子域) |
| **双语** | 中英双站 · 各自独立 mdBook 项目 · 通过 hreflang 关联 |

### 版权 & 授权

**MIT License**。你可以:

- ✅ 自由阅读、分享
- ✅ 引用书中片段(附出处即可)
- ✅ Fork 仓库 · 用作个人学习参考
- ✅ 提 PR 修文字 / 补章节

请**不要**:

- ❌ 未经修改直接印成商品书
- ❌ 剽窃内容而不注明来源

### 参考 & 致谢

- **[Claude Code](https://www.anthropic.com/claude-code)** —— Anthropic 出品 · 本书完全基于官方 v0.5+ 版本的 tool description 分析而来
- **[Anthropic 官方文档](https://docs.anthropic.com/)** —— 涉及 tool call 机制的部分
- **[mdBook](https://rust-lang.github.io/mdBook/)** —— 让这本书能够作为静态站发布
- **[jooj](https://github.com/diaozxin007/jooj)** —— 本书的**元前提**

### 反馈

发现内容错误、有更好观察角度、想投稿新章节 —— 都欢迎:

- **Issue**:[github.com/diaozxin007/reading-claude-code/issues](https://github.com/diaozxin007/reading-claude-code/issues)
- **PR**:直接提 · 我会 review

---

回到 [前言](preface.md) · 或去 [首章](tool-mechanism.md)。
