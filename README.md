# 一同读 Claude Code

> Reading Claude Code, Together — 一本关于 Claude Code 工具原语设计的深度拆解。每一个 tool 的设计都在防 AI 犯哪些错。

## 在线阅读

- **中文版**:[https://diaozxin007.github.io/reading-claude-code/zh/](https://diaozxin007.github.io/reading-claude-code/zh/)
- **English**:[https://diaozxin007.github.io/reading-claude-code/en/](https://diaozxin007.github.io/reading-claude-code/en/)

## 这本书讲什么

Claude Code 的工具设计不是"给 AI 一个工具箱" —— 是"用工具形状,教 AI 怎么做工程"。每一个 tool 的字段名、prompt 约束、runtime 硬阻断,背后都是一次血泪教训的沉淀。

本书从 16 个核心工具入手,一层层拆解:

- **交互原语**:AskUserQuestion / EnterPlanMode / ExitPlanMode —— AI 和用户怎么对齐
- **执行原语**:Grep + Glob / Read / Edit / Write —— 定位、感知、修改文件
- **通用能力**:Bash / Agent —— 无边界兜底 + 派生 subagent
- **状态与调度**:Task 家族 / Background / Cron / Monitor —— 跨越时间与并发
- **信息访问**:WebFetch + WebSearch —— 突破本地边界

## 本地阅读

需要装 [mdBook](https://rust-lang.github.io/mdBook/):

```bash
# 中文版
cd zh && mdbook serve --open

# English
cd en && mdbook serve --open
```

## 参与

- 发现错误 / 有建议 → 提 Issue
- 想补章节 → 欢迎 PR
- 相关项目:[jooj](https://github.com/diaozxin007/jooj)(Java 版 Claude Code 复现)

## License

[MIT](LICENSE)
