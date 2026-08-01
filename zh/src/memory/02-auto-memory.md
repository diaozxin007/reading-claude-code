# 02 · auto memory · 从一次纠正到 MEMORY.md

> **TL;DR**:auto memory 不是把整段聊天塞进一个文件。Claude Code 把持久记忆拆成两层:`MEMORY.md` 只做短索引 · 具体内容进入带 frontmatter 的 topic 文件。主 agent 可以当场写 · 若它没写,每个完整 query loop 结束时还有一个受限的 fork subagent 补漏。两条写入路径用游标和写入检测互斥,因此不是两个 agent 同时争抢同一份文件。

上一篇 [01 · CLAUDE.md 家族 · 5 层 hierarchy 与 3 种混装](01-claude-md-family.md) 讲的是用户主动写给 Claude 的长期指令。本篇反过来问:用户没有维护规则文件时,Claude 怎样把一次纠正沉淀到下一次会话?

## 先划边界 · MEMORY.md 不是 CLAUDE.md

| | CLAUDE.md | auto memory |
|---|---|---|
| 信息来源 | 用户、团队或管理员明确声明 | Claude 从协作中提取 |
| 典型内容 | 命令、约束、项目规范 | 用户偏好、纠正、项目背景、外部指针 |
| 写入责任 | 人维护 | 主 agent 主动写 + 提取 agent 补漏 |
| 文件形态 | 层级化指令文件 | `MEMORY.md` 索引 + topic 文件 |
| 失真风险 | 规则陈旧 | 模型误提取、重复或记忆漂移 |

这条边界解释了为什么源码明确排除代码结构、架构、git 历史和文件布局:这些信息可以重新读取,不值得占用持久记忆。auto memory 保存的是**无法从当前项目状态推导**、但未来协作仍有用的信息。四种允许的类型是 `user`、`feedback`、`project`、`reference`。见 `memdir/memoryTypes.ts:4-19`。

## 两层文件结构 · 索引不是正文

默认目录由规范化后的 canonical git root 派生:

```text
~/.claude/projects/<sanitized-git-root>/memory/
├── MEMORY.md
├── feedback-testing.md
├── user-role.md
└── project-release-context.md
```

`MEMORY.md` 不是长篇笔记,而是一行一个链接的入口:

```markdown
- [Testing policy](feedback-testing.md) — integration tests use a real database
```

真正内容进入 topic 文件,并带 `name`、`description`、`type` frontmatter。这样会话起手只需加载一个很短的路由表;需要细节时再 Read 或搜索 topic 文件。源码 prompt 明确要求每条索引约 150 字符以内,并提醒 200 行之后会被截断。见 `memdir/memdir.ts:219-233`、`services/extractMemories/prompts.ts:68-81`。

这里有一个容易混淆的数字:

- `MEMORY.md` 的 context 入口受行数和字节预算约束;
- topic 文件扫描最多返回 200 个文件,每个文件只读前 30 行 frontmatter,并按修改时间倒序排列。

后者是检索清单的上限,不是说整个 memory 目录只能存在 200 个文件。见 `memdir/memoryScan.ts:21-73`。

## 路径为什么跟 canonical git root 绑定

`getAutoMemBase()` 优先取 canonical git root,没有 git 时才回退 project root。于是同一仓库的子目录与 worktree 会映射到同一个 auto-memory 目录。见 `memdir/paths.ts:198-232`。

这是一个产品选择:worktree 是同一项目的并行工作副本,项目背景和用户反馈不应因 checkout 位置不同而割裂。但它也意味着不同 worktree 会读写同一批记忆,所以短期分支进度不适合写进 auto memory;那更适合 task、plan 或 session 内消息。

路径可以通过可信设置源的 `autoMemoryDirectory` 改写。项目仓库里的 project settings 被刻意排除,否则恶意仓库可把目录指向 `~/.ssh` 一类敏感位置,再利用 memory 的写权限豁免。源码只接受 policy、flag、local、user 四种设置源,并拒绝相对路径、根目录、UNC、空字节等危险输入。见 `memdir/paths.ts:95-185`。

## 谁来写 · 主 agent 先写,后台 agent 补漏

auto memory 有两条产生路径。

### 路径一 · 主 agent 当场写

主 prompt 本身包含完整的 memory 分类和保存说明。用户明确说“记住这件事”时,主 agent 不必等会话退出,可以直接写 topic 文件并更新索引。

### 路径二 · 完整一轮结束后补提取

主 agent 没写时,`handleStopHooks` 在主线程完成一次无工具调用的最终回答后,以 fire-and-forget 方式启动 `extractMemories`。它不是“退出终端才运行”,而是**每个完整 query loop 结束时都有机会运行**。`--print` 模式在输出已经 flush 后等待未完成的提取,避免进程退出把它杀掉。见 `query/stopHooks.ts:133-153`、`cli/print.ts:959-969`。

提取 agent 是主会话的 perfect fork:继承相同 system prompt、工具声明和消息前缀,从而复用 prompt cache;然后在尾部追加一条“分析最近 N 条消息”的专用指令。见 `services/extractMemories/extractMemories.ts:1-13`、`services/extractMemories/prompts.ts:1-9`。

## 为什么不会重复写

提取器维护 `lastMemoryMessageUuid` 游标,每次只看游标之后的新消息。启动前还会扫描这个区间里的 assistant tool_use:只要发现 Edit/Write 的目标位于 auto-memory 目录,说明主 agent 已经完成记忆写入,后台提取器就跳过并把游标推进到最新消息。

```text
一轮结束
  ├─ 主 agent 已写 memory → 跳过提取 · 推进游标
  └─ 主 agent 没写 memory → fork 提取 · 成功后推进游标
```

这不是简单的时间 debounce,而是以“这个消息区间是否发生 memory 写入”为互斥条件。若提取失败,游标不推进,同一批消息下次仍可重新考虑。见 `services/extractMemories/extractMemories.ts:112-148`、`:345-359`、`:429-435`。

## 四类记忆 · 保存的是不可推导信息

| 类型 | 适合保存 | 不该保存 |
|---|---|---|
| `user` | 角色、经验、解释偏好 | 对用户的负面判断、与工作无关画像 |
| `feedback` | 用户纠正与确认过的协作方式 | 只对当前一步有效的临时命令 |
| `project` | deadline、事故背景、跨系统动机 | 可从代码或 git 直接看出的结构 |
| `reference` | Linear、Grafana、Slack 等外部位置指针 | 把整个外部系统内容复制进来 |

`feedback` 特别同时收失败和成功。只记纠正,agent 会逐渐变得过度谨慎;记录用户对非显然做法的确认,才能保持已经验证过的判断。启用 team memory 时,类型还承担 scope 路由:用户画像恒 private · project 强烈偏向 team · feedback 只有确属全项目约定时才进 team。见 `memdir/memoryTypes.ts:37-106`。

## 开关不是一个布尔值

`isAutoMemoryEnabled()` 的优先链是:

1. `CLAUDE_CODE_DISABLE_AUTO_MEMORY` 环境变量;
2. `--bare` / `CLAUDE_CODE_SIMPLE`;
3. 远程模式是否提供持久 memory 目录;
4. `autoMemoryEnabled` 设置;
5. 默认开启。

其中显式把环境变量设成假值还能重新开启,并非“变量存在即关闭”。此外提取 agent 还有独立 feature gate 与交互/非交互 gate;所以“auto memory 可用”和“后台提取器本轮一定运行”不是同一件事。见 `memdir/paths.ts:21-76`。

## 决策 · 反模式 · 演进信号

### 决策

- 用 `MEMORY.md` 做索引、topic 文件做正文,把启动成本与记忆容量拆开。
- 主 agent 负责即时显式记忆,后台 fork 负责补漏,再以写入检测互斥。
- canonical git root 让 worktree 共享长期背景,避免同一项目形成多个记忆孤岛。

### 反模式

- 把 `MEMORY.md` 写成流水账 · 200 行预算很快被耗尽。
- 保存代码结构和 git 可推导事实 · 记忆会过期,而源码才是 ground truth。
- 把当前会话的执行步骤写进 memory · task 和 plan 才是短期工作状态载体。
- 在 project settings 中允许任意 `autoMemoryDirectory` · 会把仓库配置变成静默写权限升级。

### 演进信号

- 索引逼近 200 行 → 合并重复 topic、缩短 hook,而不是继续堆正文。
- 同一反馈被反复新增 → frontmatter 描述或查重策略不够可检索。
- worktree 间出现互相污染 → 保存了短期分支状态,应迁回 task/session。
- 主 agent 与提取 agent 写出近似内容 → 检查写入路径检测与游标推进是否失效。

## 小结

auto memory 的核心不是“自动写 Markdown”,而是一条有边界的沉淀流水线:**不可推导信息 → 四类分类 → topic 文件 → MEMORY.md 路由 → 下次会话按需召回**。它把主 agent 的主动性和后台 agent 的补漏能力叠在一起,又用路径权限、写入检测和游标避免失控。

下一篇 [03 · Anthropic API memory tool · memory_20250818 客户端记忆原语](03-api-memory-tool.md) 切到协议层:Anthropic API 给应用的 memory tool 与 Claude Code 这套 auto memory 为什么是两套独立实现。

## 参考

- Claude Code 源码:`memdir/paths.ts:21-278`
- Claude Code 源码:`memdir/memdir.ts:187-315,409-506`
- Claude Code 源码:`memdir/memoryTypes.ts:4-106`
- Claude Code 源码:`memdir/memoryScan.ts:21-93`
- Claude Code 源码:`services/extractMemories/extractMemories.ts:1-13,112-148,329-586`
- Claude Code 源码:`services/extractMemories/prompts.ts:29-153`
- Claude Code 源码:`query/stopHooks.ts:133-153`
- Claude Code 源码:`cli/print.ts:959-969`
- Claude Code 官方文档:[Manage Claude's memory](https://code.claude.com/docs/en/memory)

