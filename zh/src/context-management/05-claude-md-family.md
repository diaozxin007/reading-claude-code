> 本系列第 05 篇 · 承接 [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) 里画的 prepend 位置 · 承接 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 里划的 stable prefix。 本篇讲一个 session 起手加载的静态指令生态 —— CLAUDE.md 家族的 5 层加载栈 · @import 递归 · path-scoped rules · MEMORY.md 自动记忆 · Todo v2 持久任务 · 以及所有这些为什么绕开 system prompt · 挤进 messages 段的第一条 user msg 里。

## 起手一个问题

假设你在项目根写了一份 `CLAUDE.md` · 只有一句话:

> 这个项目用 pnpm 不用 npm

当你在 Claude Code 里问 "帮我装个 lodash" · 这句话进 LLM 时长什么样?具体点问:

- 它进 system prompt 吗?
- 它跟每天变化的日期挂在一起吗?
- 它挂 cache 断点吗?
- session 里改一下这个文件 · 下一轮生效吗?
- 如果这个 `CLAUDE.md` 里写了 `@AGENTS.md` · 那份文件会被读吗?
- 如果 `AGENTS.md` 里又写了 `@shared/*.md` · 会走多深?

这些问题的答案不是分散在 6 处的 · 而是收敛在同一个装配函数 · 同一个数据结构里。 本篇把这个装配过程摊开。

## 反直觉:CLAUDE.md 不进 system prompt

如果只看现象 · 你会以为 CLAUDE.md 是**给模型立规矩**的地方 —— 立规矩的东西自然该在 system prompt 里 · 跟 "你是 Claude Code" 之类的核心 identity 挂在一起。

**实际不是**。 CLAUDE.md 走的是另一条通道:**注入进 messages 数组的第 0 条 user 消息 · 用 `<system-reminder>` 包起来 · 标 `isMeta: true`**。 具体形态:

```
messages 数组 · 第 0 条(prepend):
{
  role: 'user',
  isMeta: true,
  content: '<system-reminder>
    As you answer the user's questions, you can use the following context:

    # claudeMd
    Codebase and user instructions are shown below. Be sure to adhere to
    these instructions. IMPORTANT: These instructions OVERRIDE any default
    behavior and you MUST follow them exactly as written.

    Contents of ~/.claude/CLAUDE.md (user's private global instructions):
    <文件正文>

    Contents of /repo/CLAUDE.md (project instructions, checked into the codebase):
    <文件正文>

    # currentDate
    Today's date is 2026-07-30.

    IMPORTANT: this context may or may not be relevant to your tasks. You
    should not respond to this context unless it is highly relevant to
    your task.
  </system-reminder>'
}

第 1 条:真正的 user 消息 —— "帮我装个 lodash"
```

三个细节值得停下来:

- **Header 用 `# key` 分段**:`# claudeMd` · `# currentDate` —— 组装函数把一个 `context` 对象的每个 key/value 铺成一段 · 由这些 header 隔开
- **开头挂 MEMORY_INSTRUCTION_PROMPT**:"instructions OVERRIDE any default behavior and you MUST follow them exactly as written" —— 这句话是给模型的 · 让它知道这段 SR 里的规矩优先级最高
- **`isMeta: true`**:告诉 UI 层不要显示这条消息 —— 用户看不到 · 但模型看到

为什么绕开 system prompt?这个设计不是随便定的 · 是 **prompt cache 骨架**决定的(见 [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md))。 用 cache 视角看:

- **如果 CLAUDE.md 进 system prompt**:CLAUDE.md 是每个用户 / 每个项目都不同的 —— 一放进 system prompt 中间 · 就把 system 后半段全部推离 stable prefix · 后续每轮都要重建 system cache
- **走 messages 段的第 0 条**:cache 断点挂在 tools 末 · system 末 · messages 末三处 —— CLAUDE.md 变化只影响 messages cache 分支 · tools + system 那两层稳定 cache 保住

从这个视角看 · CLAUDE.md 这个位置不是"随便找个地方塞" · 是**唯一能塞的地方**。

## 4 层加载栈

一个 session 起手 · Claude Code 从当前目录出发 · 按下面这个顺序把所有能找到的静态指令拢在一起:

| 层 | 位置 | 类型标签 |
|---|---|---|
| **用户全局** | `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md` | `User` |
| **上游 rules 目录** | 从 cwd 向 git root 每一级 · 找 `<dir>/.claude/rules/*.md` | `Project` |
| **项目根** | `<gitRoot>/CLAUDE.md` + `<gitRoot>/.claude/CLAUDE.md` | `Project` |
| **本地未提交** | `<gitRoot>/CLAUDE.local.md` | `Local` |
| **auto-memory** | `~/.claude/projects/<hash>/memory/MEMORY.md` | `AutoMem` |

装配顺序的核心逻辑:**先加全局 · 再从 cwd 沿目录树向上走到 git root · 每一级都看有没有 `.claude/rules/` 目录 · 最后把 git root 上的 CLAUDE.md 和 CLAUDE.local.md 挂上**。

四个反直觉的细节:

**1 · 沿目录树上溯 · 不是只看当前 cwd**

你在 `/repo/apps/web/` 起 session · 装配函数不只看 `apps/web/CLAUDE.md` · 它会:
- 检查 `apps/web/.claude/rules/`
- 检查 `apps/.claude/rules/`
- 检查 `/repo/.claude/rules/`
- 再从 git root(`/repo`)读 `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md`

上溯到 git root 就停 —— 靠 `findGitRoot(originalCwd)` 决定终点。

**2 · nested worktree dedup**

如果你在 `.claude/worktrees/<name>/` 这种 worktree 里起 session · 上溯的过程里主 repo 已经在物理路径上 · 那些 CLAUDE.md 会被 skip —— 否则同一份 CLAUDE.md 会被加载两次。 这个 dedup 是靠 `pathInWorkingPath(gitRoot, ...)` 那一段实现的 · 判断当前 worktree 是否在主 repo 内。

**3 · CLAUDE.local.md 走独立 settings 开关**

不是每个 session 都会加载 `CLAUDE.local.md` · 它要求 `localSettings` 这个 settings source 处于启用状态。 未提交的 local override · 加载路径也 local。

**4 · Managed 层是第 5 层**

上面表格里没画的是 `Managed` 类型 —— 组织级的 `.claude/CLAUDE.md` + `.claude/rules/` · 靠 `getMemoryPath('Managed')` 定位 · 常见于企业部署。 加进来的顺序在最前 · 优先级最高。 严格算 · 加载栈是 **5 层**:Managed → User → Project(含上溯 rules)→ Local → AutoMem。

## 硬关关卡

两个环境让整个 CLAUDE.md 家族**完全不加载**:

- **`CLAUDE_CODE_DISABLE_CLAUDE_MDS`** —— 环境变量硬关。 装配函数第一步就查它 · truthy 就直接返回 `null`
- **`--bare` 模式** —— 除非同时配了 `--add-dir` 显式加目录 · 否则 bare 模式跳过整个装配

这两个开关不是"跳过某一层" · 是**跳过全部**。 用途是脚本化调用 · 不想被本地 CLAUDE.md 干扰行为时。

## `.claude/rules/` 的分岔:unconditional vs conditional

`.claude/rules/` 目录下每个 `.md` 文件都是一条 rule · 但它们分两类:

- **Unconditional rule** —— 文件里没 frontmatter · 或 frontmatter 里没 `paths:` 字段。 这类 rule 一律加载 · 每个 session 都进
- **Conditional rule** —— frontmatter 带 `paths: ["src/**/*.ts", "!src/legacy/**"]` 这样的 glob 列表。 只有**当前操作路径匹配 glob 时**才加载

Conditional rule 的匹配时机不是 session 起手 · 而是 **JIT**:当模型要读 / 编辑某个文件时 · 装配函数拿这个文件的 realpath · 用 `picomatch` 或 `ignore` 库去匹配所有 conditional rules 的 `paths` · 只有匹配上的才注入。

具体到 glob 语义:

- 用 `.gitignore` 那套语法(`ignore()` 库)· 而不是纯 picomatch
- glob 是 `**` 全域递归 · `!pattern` 反向排除
- **相对基准**:Project 类型的 rule · glob 相对 `.claude` 的父目录;Managed / User 类型的 rule · glob 相对 original cwd
- 目标路径必须先 realpath 一次 —— 走过 symlink 也会指到真实文件

举例:`.claude/rules/typescript.md` 的 frontmatter 写 `paths: ["**/*.ts", "**/*.tsx"]` —— 只有 Read / Edit 目标是 `.ts` / `.tsx` 时才注入这条 rule · 打开 `.py` 文件时不加。

这个设计的价值:**path-scoped 指令**。 你不用把整个 monorepo 的所有语言规范都塞进一份大 CLAUDE.md · 可以按 subpath 拆成小文件 · 每个只在相关文件被访问时才占 context。

## @import 的 5-hop 递归

CLAUDE.md 里可以写 `@path/to/file.md` 引入其他文件 —— 这是把 CLAUDE.md 拆小 / 组合的机制。 4 种写法都支持:

- `@relative/path.md` —— 相对当前 CLAUDE.md 所在目录
- `@./explicit.md` —— 显式相对
- `@~/global.md` —— 相对 home
- `@/absolute/path.md` —— 绝对

**反直觉:官方文档说递归上限 4-hop · 源码是 5-hop**。 常量叫 `MAX_INCLUDE_DEPTH = 5` —— A 引 B 引 C 引 D 引 E · A 是深度 0 · E 是深度 4 · 都能载入;E 里再 `@F` 就爆栈。 官方 docs 那句 "4-hop" 是把源头也算成 hop 之一 · 但源码里 depth 0 是源头 · 所以第 5 层是能加载的。

`@import` 的实现细节:

- **相对 including file 目录 · 不是 cwd** —— A.md 在 `/repo/docs/` · 里面写 `@shared.md` · 解析成 `/repo/docs/shared.md` · 跟你在哪个 cwd 起 session 无关
- **代码围栏内 @ 跳过** —— 三个反引号包起来的代码块里的 `@foo.md` 是内容 · 不解析
- **段落级片段**:`@guide.md#advanced` —— 从 `advanced` 标题处切下面那一段(源码走 `splitPathInFrontmatter` 加 `#` 判断)· 只 embed 那一节
- **文件扩展名白名单** —— 一个 `TEXT_FILE_EXTENSIONS` set · 包括 `.md` / `.py` / `.rs` / `.ts` / `.go` / `.sh` / `.env` / `.toml` 等常见文本类型;`.png` / `.jpg` / `.bin` 不在集合里 · 直接拒绝

**cwd 外文件需批准** —— 如果 `@import` 指向一个在 project cwd **之外**的文件(比如 `@~/secrets.md`)· 装配函数会先看项目 config 里的 `hasClaudeMdExternalIncludesApproved` 字段。 没批准过 · 这个 external include 就被跳过 · 除非调用者 `forceIncludeExternal=true`。

这个批准机制是防错用的 —— 别让某份共享 CLAUDE.md 悄悄把你 home 目录里的凭据文件也拉进 context。

## 40k 硬顶 · 官方文档说的另一个数是错的

**反直觉:官方文档提到过 "1000-pattern / 4 MiB 预算" · 源码里根本不存在这两个数**。 实际生效的常量:

- **`MAX_MEMORY_CHARACTER_COUNT = 40_000`** —— 所有加载完的 CLAUDE.md 家族文件 · 总字符数超过 4 万 · doctor 检查会警告(不硬拦 · 只提示 · 靠 `getLargeMemoryFiles` 挑最大的几个报出来)

也就是说 —— 你的 5 层加载 + N 个 @import 全部展开 · 总量控制在 40k 字符以内 · 装配层不会拦你。 超过就是"能用但会有 warning"。

这个 40k 单位是**字符** · 不是 token —— 中文和英文的 token 效率不一样 · 但作为一个粗糙上限够用。

## MEMORY.md · auto-memory 的入口

CLAUDE.md 是**你手写的**静态指令 · MEMORY.md 是 Claude **写给自己的**跨 session 记忆 —— 两者装配路径共享 · 语义分工不同。

MEMORY.md 的位置:`~/.claude/projects/<projectHash>/memory/MEMORY.md`(auto-memory 目录里的入口文件)。 起 session 时 · 它跟 CLAUDE.md 一样通过 `getMemoryFiles()` 拉进来 · 类型标签是 `AutoMem`。 有它自己的一套注入声明:

> Contents of ... (user's auto-memory, persists across conversations)

**双阈值截断 · 200 行 OR 25KB · 先到者胜**:

- `MAX_ENTRYPOINT_LINES = 200`
- `MAX_ENTRYPOINT_BYTES = 25_000`

截断函数叫 `truncateEntrypointContent`。 两个阈值都存在是有原因的:大部分 MEMORY.md 是索引风格 · 一行一条 · 200 行够用;但如果某一行超长(比如粘了一段结构化数据)· 25KB 兜底 —— 上游数据里观测到过一份"197KB 但只有 200 行以内"的 MEMORY.md · 单靠行数不能拦住。

**开关**:

- Setting key `autoMemoryEnabled` —— 支持项目级 opt-out(project 层 `settings.json` 可以关掉一个仓库的 auto-memory)
- 环境变量 `CLAUDE_CODE_DISABLE_AUTO_MEMORY` —— 硬关 · 优先级最高
- 非交互模式默认 opt-out(结合 growthbook 特性)

**Frontmatter 字段**:MEMORY.md 家族的每个记忆文件 · frontmatter 用的字段是 `name / description / type` —— **不是** Simon Willison 早期笔记里写的 `node_type: memory`。 `type` 字段的合法值是四选一:`user / feedback / project / reference`。 每类语义分工:

- **user** —— 用户的角色 / 目标 / 偏好 · 帮 Claude 判断用哪种口吻
- **feedback** —— 用户对 Claude 工作方式的反馈 · 保持一致性
- **project** —— 项目状态类信息 · 跟当前项目结构强绑定
- **reference** —— 事实性引用 · Claude 见过的具体数值 / 文件路径 / API

误用 `node_type` 或者随便写个 `type: memory` · 装配层的 `parseMemoryType` 会 fallback 到 undefined —— 文件依然加载 · 但类型体系不生效。

**Kairos 日志模式**:`logs/YYYY/MM/YYYY-MM-DD.md` 是每天一份的 auto-memory 日志 · 由内部 feature flag `KAIROS` 控制。 外部用户默认没有 —— 你看不到 `logs/2026/07/2026-07-30.md` 这类文件 · 除非 feature flag 打开。

## Todo v2 · 持久任务

跟 CLAUDE.md 家族并列的还有 **Todo v2** —— 不属于静态指令 · 但也是**跨轮 / 跨 session 持久化**的一份状态。

落盘位置 `~/.claude/tasks/<taskListId>/<taskId>.json` · 每个 task 一个 JSON 文件。 `taskListId` 优先级:环境变量 `CLAUDE_CODE_TASK_LIST_ID` → teammate context 的 teamName → leaderTeamName → sessionId。 也就是说:**同一个 team 内的 sub-agent 共享 task list** · 单独 session 有自己的 task list。

开关 `isTodoV2Enabled()`:
- 环境变量 `CLAUDE_CODE_ENABLE_TASKS` truthy · 强制开
- 否则:交互模式开 · 非交互模式关

Todo v2 不通过 messages 注入 · 而是通过 4 个工具(`TaskCreate` / `TaskGet` / `TaskList` / `TaskUpdate`)—— 模型主动查询 / 更新 · 不像 CLAUDE.md 那样 session 起手就 prepend 一次。 传统 `TodoWrite` 工具是 v1 · v2 开启时它自动隐藏。

Todo v2 的角色是"跨轮 stateful 状态" · 补上了 CLAUDE.md(静态)+ auto-memory(跨 session 索引)之外的第三条持久化通道 —— 长任务的进度不会因为 compact / restart 丢失。

## AGENTS.md 不是内置

跟 Cursor 用 `.cursorrules` · Codex 用 `AGENTS.md` 一样 · 都是 agent 系统的入口约定文件。 但 **Claude Code 不内置读 `AGENTS.md`** —— 装配函数的加载栈里没有它。

想让 AGENTS.md 生效 · 两条路:

- **显式 `@AGENTS.md`** —— 在项目 `CLAUDE.md` 里写一行 `@AGENTS.md` · 走 @import 递归拉进来
- **符号链接** —— `ln -s AGENTS.md CLAUDE.md` 让两个入口指向同一份文件

这个设计选择的意思是 · Claude Code 把 CLAUDE.md 当唯一入口 · 不做"多个入口自动 merge"的隐式行为。 需要跨工具复用文档 · 靠 @import 或 symlink 显式打通。

搜索源码里能看到 · `AGENTS.md` 只在 `/init` 命令的 subagent prompt 里出现过 —— 那是让 subagent **调研仓库时**顺便扫一下 AGENTS.md · 而不是让 runtime 自动加载。

## Post-compact 时 · 谁重挂谁不重挂

Compact 是把 messages 数组截短 · 但 CLAUDE.md 家族这份 prepend user msg 会不会被同时重挂?**这是一个反直觉的分岔**(详见 [04 · Compaction 六兄弟 · 从手动到无处不在的压缩](04-compaction.md) compact 分类)。

答案:**触发 compact 时 · getMemoryFiles cache 会被清空 · 下一轮重新装配**。 具体在 `postCompactCleanup.ts` 里:

- 清 `getUserContext` cache
- 调 `resetGetMemoryFilesCache('compact')` 清底层 memory cache
- 清 skill 已发列表 · classifier · sessionMessages · 等等

**为什么要重挂**:compact 会把当前对话总结压成一条消息 · messages 数组重开新链。 如果 CLAUDE.md prepend 不重挂 · 新链条上来就没这层 SR · 模型会丢掉项目规矩。 所以 root / project 层 CLAUDE.md 一定要在 post-compact 重挂。

**但 conditional rules 不重挂**:conditional rules 是 JIT 触发的(读某个文件时才注入)· 不属于 session 起手就 prepend 那份 SR 的一部分。 post-compact 之后 · 下次读文件时才重新匹配 —— 这个"新读"本身就是全量匹配 · 不是 rehang 而是 fresh eval。

**Nested rules 有单独 dedup**:如果 rules 目录嵌套(project 层有 rules · rules 里 @import 到另一份 rules)· post-compact 时靠 `processedPaths` set 保证不重复注入。 这个 set 每次 compact 后重建 —— 每一轮完整装配都是"这次装配内不重复" · 而不是"跨轮不重复"。

## 一份 CLAUDE.md 的完整旅程

回到起手那个问题 —— 一句"这个项目用 pnpm 不用 npm"进 LLM 时长什么样?现在我们可以完整讲完:

1. **session 起手** —— Claude Code 从 cwd 起 · `findGitRoot()` 找项目根 · 拿到 `/repo`
2. **装配 5 层** —— `~/.claude/CLAUDE.md`(空)· `/repo/.claude/rules/`(空)· `/repo/CLAUDE.md`(有:那句 pnpm)· `/repo/CLAUDE.local.md`(没有)· `~/.claude/projects/<hash>/memory/MEMORY.md`(有)
3. **@import 递归** —— `/repo/CLAUDE.md` 里没 @import · 停在 depth 0
4. **conditional rules 检查** —— session 起手不检查 · 等 JIT
5. **总字符数** —— 30 字符 + MEMORY.md 2KB = 2KB 出头 · 远低于 40k 硬顶
6. **组装 SR** —— 每份文件按 `Contents of <path> (<描述>):\n\n<content>` 铺开 · MEMORY_INSTRUCTION_PROMPT 起头
7. **prepend 到 messages[0]** —— `role: user` · `isMeta: true` · SR 包裹 · 加上 `# currentDate` header
8. **cache 断点** —— messages 段末挂断点 · 不影响 tools / system cache
9. **模型看到** —— 第一条 user 消息就是这份 SR · 后面才是你真正问的 "帮我装个 lodash"

**下一轮问 "再装 axios"**:
- CLAUDE.md 家族不变 · getMemoryFiles cache 命中 · 复用同一份 prepend
- messages 段 append 新的 user msg · cache 断点顺移到最新一条
- 那份 pnpm 指令一直挂在数组第 0 位 · 模型每轮都能看到

**session 中改 CLAUDE.md**:
- 装配函数用 memoize · 需要 `resetGetMemoryFilesCache()` 才失效
- 不主动调 reset —— 改文件后当轮不会重挂 · 得触发 compact 或重启 session
- 例外:如果改的是 `.claude/rules/` 里的 conditional rule · 下次读匹配的文件时会看到新版本(每次 JIT 读盘)

**触发 compact**:
- postCompactCleanup 清 cache · 下一轮重挂 —— 那时你改的文件才生效

到这里 · 一行 "用 pnpm" 的旅程完整了 —— 它不进 system prompt · 它跟当天日期挂同一个 SR · 它在 messages[0] 位置抢占模型注意力 · 它 memoize 缓存不实时刷新 · 它在 compact 时重挂。 每一个设计都能追到 prompt cache 骨架和 messages 数组不变量。

## 小结

CLAUDE.md 家族不是一个文件 · 是一个**加载栈**:

- **5 层**:Managed → User → Project(含向上找 rules)→ Local → AutoMem
- **注入位置**:messages 数组第 0 条 user 消息 · SR 包裹 · `isMeta: true` · 走 messages cache 分支而不是 system cache
- **加载时机**:session 起手全量装配 · 全 memoize · post-compact 时清 cache 重挂
- **@import**:5-hop 递归(不是官方说的 4-hop)· 相对 including file 目录 · 代码围栏内跳过 · cwd 外文件要批准
- **path-scoped**:`.claude/rules/*.md` frontmatter 带 `paths:` 走 gitignore 语义 · JIT 匹配 · Read / Edit 目标路径决定加载
- **40k 字符**:总量硬顶 —— 官方文档里那个"1000 pattern / 4MiB"数字源码里不存在
- **MEMORY.md**:200 行 OR 25KB 双阈值截断 · frontmatter 字段是 `name/description/type` · 4 种 memory 类型 · Kairos 日志走 feature flag
- **Todo v2**:第三条持久化通道 · 走工具而非 prepend · 交互模式默认开
- **AGENTS.md**:不内置 · 靠 @import 显式接入

这些机制不是分散的选项 · 是一个**装配函数**的产物。 那个函数在 `src/utils/claudemd.ts` 里 · 一次调用把所有 5 层扫完 · 5-hop 展开 · dedup · 截断 · 拼字符串 · memoize 缓存 —— session 起手一次 · post-compact 再一次 · 中间稳定不变。

下一篇讲 sub-agent 的 context 隔离 —— 这里说的 5 层加载在 sub-agent 里会不会被继承?fork 出的子代理看到什么?详见 [06 · Sub-agent 隔离 · 从独立 context 到 .output 陷阱](06-sub-agent.md)。

---

## 参考

**源码定位**(Claude Code v2.1.220):

- 5 层加载主函数:`src/utils/claudemd.ts` `getMemoryFiles` `:790-1050`
- SR prepend 组装:`src/utils/api.ts` `prependUserContext` `:449-474`
- MEMORY_INSTRUCTION_PROMPT 定义:`src/utils/claudemd.ts` `:89-90`
- MAX_INCLUDE_DEPTH = 5:`src/utils/claudemd.ts` `:537`
- MAX_MEMORY_CHARACTER_COUNT = 40_000:`src/utils/claudemd.ts` `:91`
- @import 解析:`src/utils/claudemd.ts` `extractIncludePathsFromTokens` `:451-535`
- Conditional rules 匹配:`src/utils/claudemd.ts` `processConditionedMdRules` `:1354-1396`
- Nested worktree dedup:`src/utils/claudemd.ts` `:857-870`
- External include 批准:`src/utils/config.ts` `hasClaudeMdExternalIncludesApproved` `:115`
- CLAUDE_CODE_DISABLE_CLAUDE_MDS + bare mode:`src/context.ts` `:162-172`
- MEMORY.md 阈值:`src/memdir/memdir.ts` `MAX_ENTRYPOINT_LINES=200` / `MAX_ENTRYPOINT_BYTES=25_000` `:35-38`
- 截断实现:`src/memdir/memdir.ts` `truncateEntrypointContent` `:57-90`
- Memory type 定义:`src/memdir/memoryTypes.ts` `MEMORY_TYPES` `:14-21`
- Auto-memory 开关:`src/memdir/paths.ts` `isAutoMemoryEnabled` · `src/tools/ConfigTool/supportedSettings.ts` `autoMemoryEnabled:59`
- Todo v2 gate:`src/utils/tasks.ts` `isTodoV2Enabled` `:133-139`
- Todo v2 落盘:`src/utils/tasks.ts` `getTaskListId` `:200-227`
- Post-compact 重挂:`src/services/compact/postCompactCleanup.ts` `resetGetMemoryFilesCache('compact')`

**外部资料**:

- Anthropic docs:[Manage Claude's memory](https://code.claude.com/docs/en/memory) —— 官方文档说 @import 4-hop · 源码是 5-hop
- Simon Willison:`node_type: memory` 那条 —— 已过时 · 源码用 `type: user/feedback/project/reference`
- GitHub issue #29599 —— nested worktree dedup 的背景

**Vault 内相关笔记**:

- 00 · Discovery 报告 · 4 大策略与 20+ 机制清单 · 策略二 note-taking 章节
- [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) · messages prepend 位置
- [02 · 从一条消息到消息数组的三条不变量](02-message-invariants.md) · isMeta / SR 通道
- [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) · 为什么走 messages 段而不是 system
- [04 · Compaction 六兄弟 · 从手动到无处不在的压缩](04-compaction.md) · post-compact 重挂 vs 不重挂
- [07 · Meta 机制 · 从 system-reminder 到 20+ 种通道](07-meta-mechanisms.md) · SR 通道类型学 · CLAUDE.md 是其中一种 SR 用途
- AI Agent 实战/Week06_Memory_Compact_SystemPrompt/学习笔记_s09 · Memory 系统的存 / 选 / 抽 / 固(仅参考)
