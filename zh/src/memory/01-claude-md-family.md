# 01 · CLAUDE.md 家族 · 5 层 hierarchy 与 3 种混装

> 本系列第 01 篇 · 承接 00 · Discovery 报告 · 从 CLAUDE.md 到 memories 的 5 大载体清单 的"载体 A · CLAUDE.md 家族(静态指令层)"节展开 · 讲**磁盘视角**的记忆栈第一层。
>
> 姊妹篇 [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](../context-management/05-claude-md-family.md) 讲"消息数组视角"—— CLAUDE.md 怎么被 prepend 成 system-reminder · 怎么打 isMeta 标记 · 40 KB 硬顶怎么劈开。**05 是入口 · 本篇是出口**:上一篇讲装入路径 · 本篇讲**这些文件是谁写的 · 写在哪 · 谁能盖谁不能盖 · 什么条件才装载**。

## TL;DR

| 记忆栈第一层的 6 个关键事实 | 结论 |
|---|---|
| CLAUDE.md **不是一个文件** | 是 5 个层次 —— Managed / User / Project / Local / Nested,由不同角色维护 |
| 覆盖机制是**追加**不是替换 | 每层都进 messages 数组 · 后加载的不会覆盖前加载的语义 · 只是"再补一句" |
| Managed 层**无法被排除** | `claudeMdExcludes` 可以在 user/project/local/policy 任一层配置 · 但 policy 的 managed CLAUDE.md 是硬约束 |
| `.claude/rules/*.md` 带 `paths` frontmatter 是**按需加载** | 匹配的 glob 命中时才注入 · 不是每次 tool use 都判 · 1000 pattern + 4 MiB 双上限 |
| `@import` 最多 **4 hop** · 跳过 code fence · 相对路径以**导入方**为基准 | 不是以 `cwd` 为基准 —— 这是最常见的踩坑点 |
| AGENTS.md **Claude Code 不直接读** | 要么 `@AGENTS.md` 显式导入 · 要么 `ln -s AGENTS.md CLAUDE.md` 符号链接 · 要么分离维护 |

## 1 · 从仓库根目录的一份 CLAUDE.md 说起

假设一个项目在仓库根目录放了一份 `CLAUDE.md`，里面写着：

- 安装依赖使用 `pnpm`，不要使用 `npm`
- 修改代码后运行 `pnpm test`
- 新组件统一放进 `src/components/`
- 不要直接修改自动生成的文件

用户启动 Claude Code 后，这些项目约定会被加载；后续让 Claude 安装依赖、修改组件或运行测试时，它都会参考这些规则。

只看这个例子，很容易以为 CLAUDE.md 就是“仓库根目录的一份项目说明”。但它其实只是 CLAUDE.md 家族中的 **Project 层**。除此之外，还有组织统一下发的规则、用户在所有项目中通用的偏好、个人在当前项目里的私有规则，以及进入子目录后才加载的局部规则。

因此，**“CLAUDE.md 到底是什么”不能只看一个文件，而要看 5 个层次合成后的结果**。下面把这 5 层拆开讲。

## 2 · 5 层 hierarchy 全景

Claude Code 官方文档([https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))把静态指令载体分为 5 个层。它们的位置 · 谁能写 · 加载时机各不相同:

| 层 | 磁盘位置 | 谁能写 | 加载时机 | 可否被 `claudeMdExcludes` 排除 |
|---|---|---|---|---|
| **Managed** | `managed-settings.json` 的 `claudeMd` 字段 | 组织管理员(policy 层) | session 起手 · 每次必载 | **不可** |
| **User** | `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md` | 单用户全局 | session 起手 · `userSettings` 未禁则载 | 可 |
| **Project** | `./CLAUDE.md` 或 `./.claude/CLAUDE.md` + `./.claude/rules/*.md` | 团队(git 仓库共识) | session 起手 · `project` 未禁则载 | 可 |
| **Local** | `./CLAUDE.local.md`(应 gitignore) | 项目内单用户 | session 起手 · `local` 未禁则载 | 可 |
| **Nested** | 子目录下的 `CLAUDE.md` | 子模块团队 | **触达该子目录文件时才载**(惰性) | 可(按路径)|

### 2.1 · Managed(组织管控层)

官方文档原文:"The `claudeMd` key lets you put managed CLAUDE.md content directly inside `managed-settings.json`"(source: [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))· 例:

```json
{"claudeMd":"Always run `make lint` before committing.\nNever push directly to main."}
```

关键属性:

- **Scope**:文档原文"every Claude Code session on machine, in every repository" —— 机器上每一个 session · 每一个仓库都要吃这条
- **加载顺序**:文档原文"Loads before user project CLAUDE.md"
- **不可覆盖**:文档原文"Setting `claudeMd` in user, project, or local settings has no effect"

这是**唯一一层无法被用户排除**的 —— 组织合规要求(内部密钥不外传 · main 禁直推 · 敏感操作必须走审批)沉淀在这里。源码印证:`src/utils/claudemd.ts:547-550` 的 `isClaudeMdExcluded` 函数开头就写死"Only applies to User, Project, and Local memory types. Managed, AutoMem, and TeamMem types are never excluded."

Managed 层还有一个孪生角色 —— `getManagedClaudeRulesDir()`(`src/utils/claudemd.ts:814`)· 支持 managed policy 的 `.claude/rules/*.md`。也就是说组织可以把安全规则拆分到多个文件按需加载 · 但每一个都是硬约束。

### 2.2 · User(用户全局层)

位置:`~/.claude/CLAUDE.md` + `~/.claude/rules/*.md`。

这是“我这台机器上所有项目通用”的偏好。例如 Git commit 时机、工作目录边界和事实核对要求，都适合放在 User 层；只适用于某个仓库的规则则应该留在 Project 层。

官方文档原文:"User-level rules Personal rules in `~/.claude/rules/` apply to every project on your machine. Use them for preferences that aren't project-specific"。

**加载顺序**:官方文档原文"User-level rules are loaded before project rules, giving project rules higher priority" —— user 先加载 · project 后加载 · 后者"更靠近对话"因此语义上更优先(见 §3 覆盖机制讨论)。

**独立开关**:如果启动时 `--setting-sources` 排除了 `userSettings` · 则 user 层完全不载(`src/utils/claudemd.ts:826` `if (isSettingSourceEnabled('userSettings'))`)。CI 环境跑 Claude Code · 通常会禁掉 user 层免受个人偏好污染。

### 2.3 · Project(项目层)

官方文档原文:"A project CLAUDE.md can be stored in either `./CLAUDE.md` or `./.claude/CLAUDE.md`"。

**两个位置都合法**。前者是仓库根 · 一目了然;后者藏在 `.claude/` 下 · 和其他 Claude Code 配置(`.claude/settings.json` · `.claude/rules/`)住一起 · 目录更整洁。团队可以选择:

- 若 CLAUDE.md 是全 team 都要看的第一入口 → 放 `./CLAUDE.md`
- 若 CLAUDE.md 只是 team 内部的"给 AI 看的备忘" · 不希望污染仓库根 → 放 `./.claude/CLAUDE.md`

配套的 `.claude/rules/*.md` 只能在 `./.claude/rules/` 下 —— 官方文档把它设计为"较大项目的分文件组织" · 见 §4 展开。

### 2.4 · Local(项目内单用户层)

官方文档原文:"For private per-project preferences checked into version control, create a `CLAUDE.local.md` at the project root. It loads alongside `CLAUDE.md`" · 后紧接一句"Add `CLAUDE.local.md` to your `.gitignore` so it isn't committed."

**语义**:这是"我自己在这个项目上的偏好 · 不共享给团队"的层。典型 case:

- 我在 A 项目上跑本地 postgres 走 5432 端口 · 队友走 5433 —— 端口偏好写这里
- 我个人的 build 快捷方式 alias · 团队不想统一 —— 写这里
- 我个人的 API key sandbox 名字 —— 写这里

**关键**:这层默认应加进 `.gitignore` · 不然会污染仓库。文档没有强制 · 但把它作为"per-project 个人偏好"设计出来 · 就是奔着 gitignore 去的。

若 `--setting-sources` 排除 `local` · 则 CLAUDE.local.md 完全不载(见 §5.3 附加目录讨论)。

### 2.5 · Nested(嵌套按需层)

关键性质:**惰性加载**。子目录里的 CLAUDE.md 只在 Claude Code **触达该子目录文件时**才载入。

官方文档在讲 compaction 时给出决定性的对照:"Nested CLAUDE.md files in subdirectories are not re-injected automatically; they reload the next time Claude reads a file in that subdirectory. If an instruction disappeared after compaction, the conversation or lives in a nested CLAUDE.md that hasn't reloaded yet"(source: [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))。

这意味着 nested CLAUDE.md 有两个反直觉的运行时特性:

1. **不会 session 起手全读** —— 一个 monorepo 有 30 个子模块 · 30 份 nested CLAUDE.md · 不会因为你 `cd` 到根目录就全塞进 context
2. **不会自动 compaction 恢复** —— `/compact` 之后 · project-root CLAUDE.md 会被自动 re-inject · 但 nested 的不会 · 得下一次读到该子目录的文件时才回来

这个"惰性 vs 抗压恢复"的差异 · 是本文 §6 反直觉设计的第 1 个案例 · 后面详展开。

## 3 · 加载顺序 · 覆盖规则 · 排除规则

前面 5 层每层加载时机不同 · 组合到消息数组里的顺序是什么?排除规则又是怎么工作的?

### 加载顺序:Managed → User → Project → Local → Nested

看 `src/utils/claudemd.ts:800-847` 的实现:

```
1. Process Managed file first (always loaded - policy settings)     :804
2. Process Managed .claude/rules/*.md files                          :814
3. Process User file (only if userSettings is enabled)               :826-834
4. Process User ~/.claude/rules/*.md files                           :837
5. Then process Project and Local files (each dir walked from cwd)   :849-857
6. Nested = lazy on Read tool file access                            (elsewhere)
```

官方文档也印证:"User-level rules are loaded before project rules, giving project rules higher priority" · 隐含**加载顺序 ≠ 优先级顺序**(后加载优先级更高)。

### 覆盖机制:追加不替换

一个非常反直觉的点:**Claude Code 不做规则冲突消解**。5 层加载出来 · 全部 verbatim 塞进 messages 数组第 0 条的 system-reminder 里(参见姊妹篇 [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](../context-management/05-claude-md-family.md) 的完整消息形态)。

如果 User 层写了"用 pnpm" · Project 层写了"用 npm" · Claude 看到的是:

```
Contents of ~/.claude/CLAUDE.md: ... 用 pnpm ...
Contents of ./CLAUDE.md: ... 用 npm ...
```

**两条都在 · 让 LLM 自己解冲突**。经验上 Project 层更靠近对话正文 · LLM 会倾向读 project 的 —— 但这是 LLM 语义解读的结果 · 不是加载器强制的。

### 排除规则:`claudeMdExcludes` 分层 merge · managed 免疫

官方文档原文:

```json
{"claudeMdExcludes":["**/monorepo/CLAUDE.md","/home/user/monorepo/other-team/.claude/rules/**"]}
```

配套解释:"Patterns are matched against absolute file paths using glob syntax. You can configure `claudeMdExcludes` at any layer: user, project, local, or policy. Arrays merge across layers. Managed policy CLAUDE.md files cannot be excluded."

分层 merge 的意思:

- User 层 settings 写:排除 `**/experiments/CLAUDE.md`
- Project 层 settings 写:排除 `**/vendor/CLAUDE.md`
- 合成结果:两个都排除

**Managed 免疫**在源码里非常显式 —— `src/utils/claudemd.ts:547-550`:

```
if (type !== 'User' && type !== 'Project' && type !== 'Local') {
  return false
}
```

Managed / AutoMem / TeamMem 三种类型直接短路返回 false —— 排除模式**根本不参与判断**。这是"policy 层"设计的兑现:管理员配的合规规则 · 用户不可能通过 setting 绕开(可以卸载 Claude Code · 但不能"用 Claude Code 却不吃这条规则")。

## 4 · `.claude/rules/*.md` · 按路径条件加载

前 5 层讲的是"整个 CLAUDE.md 文件"。但一个大项目的规则可能有几十条 · 全塞一个 CLAUDE.md 会撑爆 40 KB 上限(见 [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](../context-management/05-claude-md-family.md) 讲 `MAX_MEMORY_CHARACTER_COUNT = 40_000`)。Claude Code 给出的方案是 `.claude/rules/*.md` · 按需加载。

### paths frontmatter · glob 语法

官方文档原文示例:

```yaml
---
paths:
  - "src/api/**/*.ts"
---
# API Development Rules
- All API endpoints must include input validation
- Use the standard error response format
- Include OpenAPI documentation comments
```

关键规则(全部 verbatim 引自 [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)):

- "Rules without a `paths` field are loaded unconditionally and apply to all files" —— 没写 paths 的 rules 起手就全部装载 · 相当于 CLAUDE.md 拆片
- "Path-scoped rules trigger when Claude reads files matching the pattern, not on every tool use" —— **不是每次 tool use 都重判**(避免了 O(pattern × tool_call) 的 CPU 开销)· 而是**读到匹配文件时**才装载
- "Path-scoped matching also works when Claude reaches a file through a symlinked path to the project directory" —— symlink 下的项目路径也能命中

### 上限:1000 pattern · 4 MiB

官方文档原文:"`paths` list shares one budget of 1,000 expanded patterns and 4 MiB, and patterns without braces don't count against it. Claude Code uses any pattern that would exceed the budget unexpanded, so literal braces match no files."

含义拆解:

- 1000 是**展开后**的 pattern 数 —— `src/**/*.{ts,tsx}` 展开成 2 个 · `{a,b}/{c,d}/*.{ts,tsx}` 展开成 8 个
- 无花括号的 pattern **不算入预算** —— 因为不需要展开
- 4 MiB 是总字节上限
- 超预算的 pattern 会"以字面量方式使用"—— 也就是 `{}` 被当成普通字符 · 通常匹配不到任何文件 —— **是"降级失效"而非"直接报错"**

### 版本注记

三个版本边界都能从官方文档同一页 verbatim 找到:

- **min-version 2.1.217**:"Before v2.1.217, a `paths` value with many brace groups stalled or crashed the CLI" —— 2.1.217 之前 · 花括号组合数过大会拖垮 CLI
- **min-version 2.1.207**:"Before v2.1.207, one invalid pattern made the Read tool fail for every file the rule was evaluated against, instead of matching nothing" —— 2.1.207 之前 · 一个无效 pattern 会让整个 rule 的 Read tool 失败
- **min-version 2.1.211**:"Before v2.1.211, rules that load on demand, including path-scoped rules and rules in nested `.claude/rules/` directories, loaded even when `project` was excluded" —— 2.1.211 之前 · path-scoped rules 会绕过 `--setting-sources` 的 `project` 排除

三条都是"新版本"更保守 · 老版本更宽松(所以老版本有绕过风险 · 有崩溃风险 · 有 rule 传染失败风险)。**若组织合规重度依赖 setting-sources 排除 · 必须 pin 到 2.1.211+**。

## 5 · 三种混装策略

上面讲的是"官方 5 层"。实际使用中还有 3 种常见混装法:

### 5.1 · AGENTS.md 互换

背景:很多项目已经维护了 AGENTS.md(给 Cursor / Copilot / Windsurf 等其他 coding agent 看的通用指令文件)。Claude Code 怎么复用?

官方文档明确:"Claude Code reads `CLAUDE.md`, not `AGENTS.md`" —— **Claude Code 只读 CLAUDE.md · 不直接读 AGENTS.md**。

三种玩法:

**玩法 A · @import 显式导入**(官方推荐):

```markdown
@AGENTS.md

## Claude Code
Use plan mode for changes under `src/billing/`.
```

好处:AGENTS.md 是唯一"通用规则库" · CLAUDE.md 底下追加 Claude-specific 指令。

**玩法 B · 符号链接**:

```bash
ln -s AGENTS.md CLAUDE.md
```

官方原文:"A symlink also works if you don't need to add Claude-specific content" · 附带一条 Windows 警告:"On Windows, symlink requires Administrator"。

**玩法 C · 分离维护**:两份文件各写各的。缺点:双份维护成本。

**验证方法**:官方文档给了一句"run `/context` and confirm `CLAUDE.md` appears under **Memory files**" —— 起手后跑 `/context` 命令 · 看 CLAUDE.md 是否出现在 Memory files 段。

### 5.2 · `@import` 语法 · 4 hop 深度 · 跳过 code fence

CLAUDE.md 里可以用 `@` 前缀导入其他 md · 官方文档规则 verbatim:

1. **相对路径 vs 绝对路径**:"Both relative and absolute paths are allowed."
2. **相对路径的基准是 · 谁?**:"Relative paths resolve relative to the file containing the import, not the working directory." —— **不是 `cwd` · 是导入方所在文件** —— 是最常见的踩坑点
3. **递归 4 hop**:"Imported files can recursively import other files, with a maximum depth of four hops."
4. **跳过 code fence**:"Import parsing skips Markdown code spans and fenced code blocks."

第 4 条 verbatim 例子:写 `` `@README` ``(反引号包裹)· `@README` 是文档字符串不触发导入;写 `@README` · 触发导入。

关于第 3 条 · 有一个精细的地方:官方文档说"maximum depth of four hops" · 但源码 `src/utils/claudemd.ts:537` 是 `const MAX_INCLUDE_DEPTH = 5`。"hop"和"depth"差 1 的通常约定:originating 文件占 depth 1 · 4 hop = depth 5。姊妹篇 [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](../context-management/05-claude-md-family.md) 已验证过此对照。

**导入个人偏好的写法**:官方文档在"CLAUDE.local.md"节末尾建议一种替代 —— 直接在 CLAUDE.md 里导入 `~/.claude/my-project-instructions.md`:

```markdown
# Individual Preferences
- @~/.claude/my-project-instructions.md
```

这样 CLAUDE.md 走版本控制被团队共享 · 但 `~/.claude/my-project-instructions.md` 是个人级 · 各人不同。避开了 CLAUDE.local.md 需 gitignore 的手动步骤。

### 5.3 · 附加目录 · `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` + `--add-dir`

官方文档原文命令:

```bash
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir ../shared-config
```

后紧接:"This loads `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/*.md`, and `CLAUDE.local.md` from additional directory. `CLAUDE.local.md` is skipped if you exclude `local` from `--setting-sources`."

场景:monorepo 里两个子项目共享一份 shared-config · 但工作目录只能是其中一个。用 `--add-dir` + 环境变量 · 让 Claude Code 把 shared-config 里的 CLAUDE.md / rules 也一并载入。

**注意**:是**加载**而非**替换** —— shared-config 的规则和当前项目的规则**都会**进 messages 数组(参见 §3 覆盖机制)。

**关键细节**:`--setting-sources` 排除 `local` 时 · 附加目录里的 CLAUDE.local.md 也一并跳过。这个联动是 setting-sources 的"分类排除"设计的自然结果:它排除的是"层类型" · 不是"位置"。

## 6 · 3 个反直觉设计

翻源码和文档 · 有几个初见时会奇怪、想清楚原因就服气的设计:

### 案例 1 · Nested CLAUDE.md 惰性加载而非启动加载

**直觉**:项目切进来 · 一切 CLAUDE.md 起手都读进来 —— 反正总要读的 · 早读晚读一样。

**现实**:官方文档在 compaction 段落里明确说 "Nested CLAUDE.md files in subdirectories are not re-injected automatically; they reload the next time Claude reads a file in that subdirectory"。也就是**读到子目录文件时**才载入 · session 起手不载。

**为什么**:一个 monorepo 有 30 个子模块 · 每个子模块一份 CLAUDE.md 各占 5-10 KB —— 全部起手加载就是 200 KB 起 · 直接吃掉了大半个 200K 窗口。惰性加载的代价是"某次 tool call 首次进子目录时 · 会临时挂 nested CLAUDE.md" · 但收益是"session 起手 context 是最小集"。

**副作用**(反直觉之处):compaction 抗压时 · project-root CLAUDE.md 会 re-inject · **nested 不会**。若某条规则在 nested CLAUDE.md 里而对话又过了 `/compact` · 那条规则**暂时消失了** · 得等下一次读到该子目录才回来。这是官方文档明确警告的:"If an instruction disappeared after compaction, ... lives in a nested CLAUDE.md that hasn't reloaded yet."

### 案例 2 · rules/*.md 用 `paths` frontmatter 做门控 · 而非启动全读

**直觉**:所有 `.claude/rules/` 下的 md 起手全读一次 —— 反正规则不多 · 20-30 条统统进 context 也没多少字节。

**现实**:官方文档区分明确 —— "Rules without a `paths` field are loaded unconditionally" · **但有** `paths` **frontmatter 的规则不进** —— 只在读到匹配文件时才进。

**为什么**:大规模项目 rules 可能几百条(前端规则 · 后端规则 · 测试规则 · 安全规则 · 迁移规则 · 部署规则)· 全塞进 context 是既撑爆窗口又干扰 LLM 注意力。设计上"用 glob 匹配文件路径"是**用文件系统语义反推规则相关性** —— 我读 `src/api/user.ts` · 意味着我大概率要处理 API 逻辑 · 那 `paths: ["src/api/**/*.ts"]` 的 rule 现在装载最合适。

**运行时机**(反直觉之处):不是 tool use 触发 · 而是 **Read tool 触发 · 读到匹配文件时装载**。所以规则的"生效时机"贴合 LLM 的**当前上下文** · 而不是"每次调工具就重判"。源码入口是 `src/utils/claudemd.ts:1205` 的 `getManagedAndUserConditionalRules(targetPath, ...)` —— 参数是 targetPath · 也就是"你现在准备读哪个文件" · 由此决定装哪些 rule。

### 案例 3 · Managed CLAUDE.md 无法排除是刻意的

**直觉**:让用户在 user settings 里手动排除总行吧?毕竟 excludes 都存在了。

**现实**:官方文档硬约束"Managed policy CLAUDE.md files cannot be excluded" —— 用户在 user / project / local 任一层写 `claudeMdExcludes` · 都**排除不了** managed 层。源码 `src/utils/claudemd.ts:547-550` 直接短路。

**为什么**:managed CLAUDE.md 存在的意义是**组织合规**。若用户能通过一句 `claudeMdExcludes` 绕开 · 那 policy 就架空了 —— 相当于"锁能被开锁的人绕开就不叫锁"。这是硬约束 · 不是软约束。

**孪生分工**(反直觉之处):官方文档特意区分 managed CLAUDE.md 和 managed settings 的不同 —— "A managed CLAUDE.md and managed settings serve different purposes"。managed settings 里的 `permissions.deny` / `sandbox.enabled` / `env` / `forceLoginMethod` 是**硬阻塞**(通过工具层 · 沙箱层直接拦截);managed CLAUDE.md 是**行为倾向**(通过给 LLM 看规则塑造行为 · 不是拦截)。原文:"CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer" —— 所以"code style"·"quality guidelines"这类应放 managed CLAUDE.md;而"禁跑 rm -rf"·"禁访问 /etc"这类应放 managed settings 的 permissions.deny。分工是刻意的。

## 7 · 一份项目 CLAUDE.md 变长后怎么拆

项目刚开始时，根目录的 `CLAUDE.md` 可能只有几条命令和代码规范。随着项目增长，人们很容易继续往里面加入模块规则、临时任务、历史决定和个人偏好，最后把它变成一份越来越长的混合文档。

这时不应该只考虑“怎样继续添加”，而应该判断每类内容真正属于哪一层、哪一种载体。

### 长期通用规则留在根目录

根目录 `CLAUDE.md` 适合保存整个项目长期成立的规则，例如：

- 项目使用哪种包管理器
- 提交前必须运行哪些检查
- 哪些目录或生成文件不能直接修改
- 全项目共同遵守的架构边界

这些内容适用于整个仓库，而且值得在每个 session 起手时加载。

### 模块规则下沉到 rules 或 Nested 层

如果一条规则只适用于某类文件，可以拆进 `.claude/rules/*.md`，并通过 `paths` frontmatter 按需加载。如果一个子目录代表独立模块，也可以在该目录放置 Nested CLAUDE.md。

这样前端、后端、测试和部署规则不会在每次启动时全部进入 context；Claude 触达相应文件时，相关规则才出现。

### 个人偏好不要混进团队规则

只属于个人的跨项目习惯应放进 User 层；只属于个人且只针对当前项目的偏好应放进 `CLAUDE.local.md`。根目录的 Project 层应该保留团队愿意通过版本控制共同维护的约定。

按这个边界拆分，可以避免个人偏好进入仓库，也避免同一条通用规则在多个项目之间反复复制。

### 临时进度和历史记录移出静态指令

“下一步继续做什么”和“上个月做过哪些决定”不是长期行为规则。前者更适合任务系统或 auto memory，后者更适合独立的设计文档、变更记录或归档文件。

如果暂时只能借 CLAUDE.md 保存短期进度，也应该把它视为降级方案：单独划出临时区域，定期清理，只在根文件中留下必要索引。Claude Code 不会自动替用户清理持续增长的 CLAUDE.md，而加载内容本身还有字符上限。

### 拆分的最终目标

拆分不是为了让文件数量变多，而是让不同内容按照自己的作用域和生命周期落位：

- 长期、全项目有效 → Project CLAUDE.md
- 只对特定路径有效 → path-scoped rules 或 Nested CLAUDE.md
- 个人偏好 → User 或 Local 层
- 临时进度 → task / auto memory
- 历史材料 → 普通文档或归档

根目录 CLAUDE.md 最终只保留**每次启动都值得加载的最小规则集**。

## 8 · 决策 · 反模式 · 演进信号

### 决策 · 5 层设计的**根本原因**是"每层由不同角色维护"

回顾 5 层的**产生者**:

| 层 | 产生者 | 变更频率 | 变更审批 |
|---|---|---|---|
| Managed | 组织管理员 | 极低(季度级) | 组织流程 |
| User | 单用户 | 中(周级) | 无 |
| Project | 团队(git 共识) | 中(周级) | PR review |
| Local | 项目内单用户 | 高(天级) | 无 |
| Nested | 子模块团队 | 低(月级) | 子模块 PR |

**5 层不是"技术分层" · 是"审批分层"**。每层用不同的人 · 不同的流程 · 不同的评审频率。若把所有规则塞一个 CLAUDE.md · 会出现"想改自己习惯得申请管理员"·"想变团队规范得改所有人的 dotfile"这类灾难 —— 分层就是分离关注点。

### 反模式

- **Managed 层写行为倾向 · 想做硬阻塞** —— 官方明确"CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer" · 硬阻塞去 managed settings 的 `permissions.deny` / `sandbox.enabled`
- **CLAUDE.md 无止境增长 · 不做拆分或归档** —— 达到加载上限后可能被截断 · 模块规则应下沉 · 临时进度和历史记录应移到对应载体
- **rules 全写无 paths · 每次起手全载** —— 大项目 rules 应带 paths 按需装载 · 减少每次起手的 context 占用
- **在 `.claude/rules/*.md` 里放"跨项目通用偏好"** —— 应放 `~/.claude/rules/*.md`(user 层) · 不然新项目还得再抄一份
- **CLAUDE.local.md 未加 gitignore** —— 会污染仓库 · 团队看到私人偏好文件很尴尬
- **在 nested CLAUDE.md 里放"抗压必存活"的指令** —— compaction 后不会自动回来 · 关键规则得挪到 project-root CLAUDE.md

### 演进信号 · 什么时候要提升到下一层

- **同一条规则我在 3 个项目都写一遍了** → 提升到 User 层(`~/.claude/CLAUDE.md`)
- **我个人习惯在 project 层被队友 revert 了** → 挪到 Local 层(CLAUDE.local.md)· 或个人偏好导入 `@~/.claude/my-project-instructions.md`
- **某个 rule 只在 `src/api/**/*.ts` 里管用 · 其他文件干扰 LLM 判断** → 从 CLAUDE.md 挪到 `.claude/rules/api.md` · 加 `paths` frontmatter
- **组织合规要求 · 用户不能绕开** → 从 Project 层升到 Managed 层(managed-settings.json 的 `claudeMd`)
- **子模块团队有独立 code style · 且不影响其他模块** → 拆到子目录的 Nested CLAUDE.md
- **CLAUDE.md 快到 40 KB 了 · 加载器要截断了** → 拆到 `.claude/rules/*.md` 或 归档到 history 文件

## 参考

### 官方文档

- Claude Code Memory · [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)(5 层 hierarchy · @import · paths frontmatter · claudeMdExcludes · managed CLAUDE.md · AGENTS.md 互换 · CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD · 三条 min-version 全部 verbatim 引自本页)

### 源码

- `src/utils/claudemd.ts:537` —— `MAX_INCLUDE_DEPTH = 5`(与文档"4 hops"的对照)
- `src/utils/claudemd.ts:540-573` —— `isClaudeMdExcluded` 函数 · managed 免疫的硬编码短路
- `src/utils/claudemd.ts:800-847` —— 5 层加载顺序 · Managed → User → Project → Local
- `src/utils/claudemd.ts:1020-1039` —— 5 层 telemetry 独立计数 · 印证是 5 个独立类型
- `src/utils/claudemd.ts:1205-1237` —— `getManagedAndUserConditionalRules(targetPath, ...)` · path-scoped rules 的入口 · targetPath 而非 tool call 名

### 姊妹篇 · 系列内引

- 00 · Discovery 报告 · 从 CLAUDE.md 到 memories 的 5 大载体清单 · 本文承接的 5 载体全景
- [05 · CLAUDE.md 家族 · 从一行 "用 pnpm" 到 5 层加载栈](../context-management/05-claude-md-family.md) · 姊妹篇 · 从消息数组视角看 CLAUDE.md 怎么进 prompt · isMeta 标记 · 40 KB 硬顶
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](../context-management/03-prompt-cache.md) · CLAUDE.md 落在 prompt cache 哪一段
- [06 · Sub-agent 隔离 · 从独立 context 到 .output 陷阱](../context-management/06-sub-agent.md) · subagent 是否继承 CLAUDE.md(与本系列 04 篇联动)
