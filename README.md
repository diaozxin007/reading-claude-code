# 一同读 Claude Code

> Reading Claude Code, Together —— 一本关于 Claude Code 内部机制的深度拆解 · 分四部分：tools 原语设计、agent loop 执行流、context 管理信息流、memory 跨会话记忆。

## 在线阅读

- **中文版**:[https://diaozxin007.github.io/reading-claude-code/zh/](https://diaozxin007.github.io/reading-claude-code/zh/)
- **English**(仅第一部分):[https://diaozxin007.github.io/reading-claude-code/en/](https://diaozxin007.github.io/reading-claude-code/en/)

## 这本书讲什么

Claude Code 是当前生产级 AI coding agent 的标杆。 它的源码里藏着大量**血泪教训沉淀出来的设计** —— 每一个 tool 字段、每一段 prompt 约束、每一处 runtime 硬阻断、每一个反直觉选择 · 背后都是一次工程取舍。

本书从**四个视角**同时切入 · 每个视角构成一个独立系列:

### 第一部分 · Tools 研究(16 篇)

**"给 AI 一个工具箱" · 还是 "用工具形状教 AI 怎么做工程"?**

从 16 个核心工具入手 · 一层层拆解每个 tool 的字段名、prompt 约束、runtime 硬阻断 —— 揭示 tool 设计的**教练学**本质。

- 交互原语:AskUserQuestion / EnterPlanMode / ExitPlanMode
- 执行原语:Grep + Glob / Read / Edit / Write
- 通用能力:Bash / Agent
- 状态调度:Task 家族 / Background / Cron / Monitor
- 信息访问:WebFetch + WebSearch

### 第二部分 · Agent Loop 研究(11 篇)

**LLM 是无状态的 —— 那"agent 在自主推进任务"这件事到底怎么发生?**

从"聊天窗口"这一层用户观察 · 一路挖到 `queryLoop` 主循环的 7 状态状态机、8 层错误恢复叠加、sub-agent 走同一个 loop 递归调用 —— 讲清 Claude Code **执行流**的全景。

- 骨架:loop 是什么、5 行伪代码到真实产品的复杂度落差
- 拦截:权限批准 · Hooks · 并行调度
- 边界:stop_reason 处理 · 状态机 · streaming
- 韧性:8 层错误恢复 · Interrupt · Sidechain 递归

### 第三部分 · Context 管理研究(9 篇)

**Claude Code 没有 ContextManager · 因为 cache 是横切关注 · 每个功能自己守。**

从**一个可观察现象**(20 轮后请求变快)推到 prompt cache 是所有设计底座 · 讲清 CLAUDE.md 为什么不走 system prompt、fork 为什么用 placeholder、compact 为什么故意不重挂 skill listing —— 揭示 Claude Code **信息流**的哲学。

- 底座:Prompt Cache 三条铁律 · 4 断点分配 · sentinel 分段
- 4 大策略:Compaction 六兄弟 / CLAUDE.md 家族 / Sub-agent 隔离 / JIT 检索
- 元机制:20+ 种 `<system-reminder>` · 8 处官方 vs 源码反差

### 第四部分 · Memory 研究(9 篇)

**一次 `/clear` 或退出终端后，Claude 为什么还能“记得”以前的约定？**

从 CLAUDE.md、auto memory、Anthropic API memory tool、subagent memory 和 team memory 五类载体出发，讲清信息如何写入磁盘、跨 session 存活、重新进入 context，以及 compaction 前后哪些记忆能够回来。

- 静态规则：CLAUDE.md 的 Managed / User / Project / Local / Nested 五层结构
- 自动沉淀：Auto Memory 与 Memory Extraction Pipeline
- 多代理与团队：Subagent Memory / Team Memory Sync / Managed CLAUDE.md
- 生命周期：从信息产生、持久化到 compaction 后重新加载

## 阅读顺序建议

**没读过任何 Claude Code 源码的读者**:
1. 先看 [前言](https://diaozxin007.github.io/reading-claude-code/zh/preface.html) 和 [Tool 机制](https://diaozxin007.github.io/reading-claude-code/zh/tool-mechanism.html)
2. 选一个感兴趣的原语切入 · 一路读第一部分
3. 有兴趣继续 · 进第二部分(Agent Loop) —— 从 00 开篇起 · 顺序读
4. 再读第三部分(Context 管理) —— 理解每次调用的信息如何组织
5. 最后进入第四部分(Memory) —— 把时间尺度从当前 session 延伸到跨 session

**已经用过 Claude Code · 想理解为什么这样设计**:
- 直接从 [Context 管理 · 开篇](https://diaozxin007.github.io/reading-claude-code/zh/context-management/00-intro.html) 起 —— 先看 Cache 是底座这个立主线
- 然后按兴趣穿插读第二/第一部分

## 本地阅读

需要装 [mdBook](https://rust-lang.github.io/mdBook/):

```bash
# 中文版
cd zh && mdbook serve --open

# English(仅第一部分 · 二/三/四部分未翻译)
cd en && mdbook serve --open
```

## 关于源码基础

本书基于 Claude Code v2.1.220 泄露源码研究 · Bun + TypeScript + Ink runtime。 每篇文末参考段给出源码 file 定位(不含 line number 避免版本漂移) · 便于读者自己上手验证。

## 参与

- 发现错误 / 有建议 → 提 Issue
- 想补章节 / 翻译英文版 → 欢迎 PR
- 相关项目:[jooj](https://github.com/diaozxin007/jooj)(Java 版 Claude Code 复现)

## License

[MIT](LICENSE)
