Claude code tools 研究系列第八篇。前七篇拆完了两条主线:

- **交互原语三件套**([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md)) —— 解决「AI 和用户怎么对齐」
- **执行原语链条**([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md)) —— 解决「怎么定位、感知、修改文件」

这些工具都是**围绕文件系统**打造的:定位一个文件、读一个文件、改一个文件。但真实项目里,「改代码」只是一部分工作。还有一大堆事情不是「操作文件」能覆盖的:

- 跑一次测试
- 装个 npm 包
- 执行 `git commit`
- 查 CI 状态
- 起个 dev server
- 生成一份 build

这些事的共同点是:**它们需要执行一个命令,而不是修改一个文件**。这是 Bash 存在的意义。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Bash

在 Claude Code 所有 tools 里,**Bash 是能力最强、最灵活、也最危险**的一个。它相当于把整个操作系统的 shell 交到 Claude 手里 —— 理论上,一切能在终端里做的事,Claude 都能通过 Bash 做。

Bash 的存在,让 Claude Code 从「一个改代码的 AI」升级为「一个能真正推进工程任务的 AI」。但同时它也是**整套工具生态里 prompt 最复杂、约束最多**的一个 —— 因为「万能」意味着「危险」,危险需要用规则来收敛。

### 作用

Bash 是 Claude Code 内置的**命令执行工具**。它做的事很直白:执行一个 bash 命令,返回 stdout / stderr / exit code。但这份「直白」下面藏着几层设计意图:

1. **能力兜底** —— 前面所有工具解决不了的事,Bash 兜住
2. **持久 CWD** —— 一次会话里,shell 的工作目录状态是持续的
3. **可后台运行** —— 长任务(dev server / 长测试)不阻塞对话
4. **可超时** —— 每个命令都有 timeout,防止卡死
5. **可 sandbox** —— 有安全边界,不是「Claude 想干啥就干啥」

Bash 之所以特殊,是因为它是**唯一一个「工具边界内包含无穷可能」的 tool**。其他工具的能力面是有限的(Read 只能读、Edit 只能替换),Bash 的能力面等同于「你系统上装的所有 CLI 工具」的组合。

### 一个具体例子

**场景**:用户说 **「跑一下测试,如果都过了帮我 commit + push」**。

这是一个典型的**多步骤命令行工作流**,没有任何一步是「改文件」—— 全都是「执行命令」。

#### 用 Bash 是怎么解决的

Claude 会依次调用 Bash,每一步都带 `description`(描述目的,不叫 Bash 的黑话):

**Step 1 · 跑测试**

```
Bash(command: "pnpm test", description: "运行项目测试套件")
→ 全绿返回 · 失败会打印错误详情
```

**Step 2 · 看当前改动**

```
Bash(command: "git status", description: "查看工作树状态")
→ 精简输出 · 只显示改动文件列表
```

**Step 3 · 看 diff · 确认没混进不该提的**

```
Bash(command: "git diff", description: "查看未暂存改动")
→ 精简 diff · Claude 一眼看清改了什么
```

**Step 4 · 有针对性地 add 文件**

```
Bash(command: "git add src/auth/middleware.ts src/auth/routes.ts", description: "暂存 auth 相关改动")
```

**注意**:按 CLAUDE.md 的 workspace 边界纪律,不用 `git add -A` · 只加自己改的文件。

**Step 5 · Commit**

```
Bash(command: "git commit -m \"$(cat <<'EOF'\nfix(auth): 修复 JWT verify 未剥离 Bearer 前缀\n\n背景: middleware 直接把 Authorization header 传给 jwt.verify · 导致所有请求 401\n改动: 剥离 Bearer 前缀再校验\n度量: 4 个测试新增 · 全绿\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"", description: "提交 auth 修复")
```

**注意**:用 HEREDOC 传 message · 保持格式和换行 · 附 Co-Authored-By tag。

**Step 6 · Push**

```
Bash(command: "git push origin main", description: "推送到 GitHub")
→ 简短的推送确认
```

一路下来 —— **6 次 Bash 调用 · 每次都带 description · 每次都遵守工作树边界**。整个流程用户可以在 tool call log 里逐步审阅。

#### 如果 Bash 没有这些设计约束

想象一下 Bash 只是一个「输入命令 · 返回结果」的裸工具,没有任何 prompt 约束,会发生什么:

1. **黑话满天飞** —— tool call 描述里全是 `git status` / `pnpm test`,没上下文,用户不知道 Claude 在干嘛
2. **`git add .` 混提** —— Claude 把用户未提交的另一批改动一起提了,踩雷
3. **--no-verify 跳 hook** —— 遇到 pre-commit hook 失败,Claude 硬绕过,把污染代码推上去
4. **`rm -rf` 跑起来** —— Claude 认为「清理是好意」,先 rm 后想
5. **明明有 Read 却用 `cat`** —— Bash 是万能 catchall · Claude 什么都用它做 · 浪费专用工具的规范化输出
6. **命令挂死超时** —— 一个 `curl` 卡住,整个对话阻塞

**核心洞察**:Bash 的力量在于「什么都能做」· 危险也在于「什么都能做」。整套 Bash 的 prompt 约束,就是把这份力量收敛成一个「安全 + 可审阅 + 与其它工具协作」的执行原语。

### 触发条件

**该用 Bash 的场景**:

- **跑测试 / 构建 / lint** —— `pnpm test` / `cargo build` / `tsc`
- **git 相关操作** —— status / diff / add / commit / push / branch / stash 等
- **GitHub CLI** —— `gh pr create` / `gh pr view` / `gh run list`
- **包管理** —— `pnpm install` / `npm run xxx`
- **文件系统操作** —— `mkdir -p` / `mv` / `cp` (小心区别于文件内容操作)
- **网络操作** —— `curl` / `gh api`
- **进程管理** —— 起 dev server(用 `run_in_background=true`)
- **专用工具不覆盖的复杂管道** —— `find ... -exec ...` 组合

**不该用 Bash 的场景**(应该用专用工具):

| Bash 用法 | 应该用的工具 | 为什么 |
|---|---|---|
| `cat file.md` | Read | Read 有分页、多模态、harness 追踪 |
| `sed -i 's/foo/bar/g'` | Edit | Edit 有唯一性检查、Read 前置 |
| `echo "..." > file.txt` | Write | Write 有 harness 追踪、父目录检查 |
| `grep -r "pattern" .` | Grep | Grep 有 output_mode、head_limit |
| `ls src/**/*.ts` | Glob | Glob 有 mtime 排序、路径特化 |
| `echo "message"` | 直接输出文字 | echo 是给 shell 用的 · Claude 直接说就行 |

一个**贯穿全篇的原则**:**Bash 是兜底 · 不是首选**。如果一件事有专用工具能做,专用工具永远优先。这是因为专用工具有:

- Runtime 追踪(harness 状态)
- 输出规范化(不用解析文本)
- 语义约束(比如 Edit 的唯一性)
- Prompt 约束(比如 Write 不主动生产 md)

Bash 一切没有 —— 它是一个**逃生舱**,不是主入口。

### 技术实现

#### 1 · 命名

`Bash`

一个词编码所有职责。不叫 `Shell` / `Exec` / `RunCommand` —— `Bash` 就是 shell 里最主流的解释器名,Claude 拿到这个词第一反应就是"跑一条命令,像我平时在终端里那样"。不叫 `Exec` 是因为 `Exec` 会让人以为可以传结构化的 argv 数组;`Bash` 明确了**这是一根字符串,交给一个真实的 shell 去解析**,含变量替换、含管道、含 HEREDOC。

字段名也全是望文生义:`command` / `description` / `timeout` / `run_in_background` / `dangerouslyDisableSandbox`。特别是最后一个 —— **`dangerously` 前缀直接刻在字段名里**,不叫 `disableSandbox` / `noSandbox`,让 Claude 每次看到都不得不多想两秒。这是命名层面的一道劝退。

#### 2 · 工具级描述

Bash 的工具级描述是**整套工具里最长的一段**,原文按信息类型可以切成五块:**核心定位一句 → 一张反例白名单 → 一整段通用注意事项 → 一整段 git 安全协议 → 一整段 PR 创建流程**。反例和硬规矩比核心定位长十倍。

这就是本工具的核心特征 —— **能力无边界,只能用描述劝**。

**核心定位一句**

> Executes a given bash command and returns its output.
> The working directory persists between commands, but shell state does not. The shell environment is initialized from the user's profile (bash or zsh).

一句话说清楚 Bash 是什么。第二句是**唯一的隐式状态承诺**:CWD 会持久,shell 变量不持久。这条不是通过校验实现的,是 harness 实际行为的自我披露 —— 让 Claude 知道 `cd project` 之后下一条命令还在 `project/`,但 `export FOO=bar` 之后下一条命令看不到 `$FOO`。CWD 持久让工作流可组合,shell 状态不持久防止会话污染。

**优先专用工具:一张反例白名单**

> IMPORTANT: Avoid using this tool to run `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:
>
>  - Read files: Use Read (NOT cat/head/tail)
>  - Edit files: Use Edit (NOT sed/awk)
>  - Write files: Use Write (NOT echo >/cat <<EOF)
>  - Communication: Output text directly (NOT echo/printf)
> While the Bash tool can do similar things, it's better to use the built-in tools as they provide a better user experience and make it easier to review tool calls and give permission.

这段是本工具的灵魂。它承认了一个事实:**Bash 里能干的事,一半跟专用工具重叠**。cat 能读文件、sed 能改文件、echo 能建文件、echo 能输出文字 —— 每一个都有专用工具对应。

于是官方选了「用描述劝退」这条路:**列一张反例白名单,一一给出替代方案**。为什么不改成硬拦截?因为 Bash 是通用工具,`cat` 到底是想读文件还是想拼管道(比如 `cat < file | jq ...`)在 schema 层判不出来,只能靠 Claude 自己拿捏。

代价是很明显的 —— 本文末尾的「一个有趣的注解」记录了一次现场翻车:写到第十三篇的时候,系列作者本人还在让 Claude 用 `bash grep` 而不是 Grep tool。**光靠 prompt 约束,面对训练数据惯性,每次调用都会有漏**。

**引号 / cd / find / sleep / 长命令:一整段通用注意事项**

> - Always quote file paths that contain spaces with double quotes in your command (e.g., cd "path with spaces/file.txt")
> - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it. In particular, never prepend `cd <current-directory>` to a `git` command — `git` already operates on the current working tree, and the compound triggers a permission prompt.
> - Avoid unnecessary `sleep` commands: ...
> - When running `find`, search from `.` (or a specific path), not `/` — scanning the full filesystem can exhaust system resources on large trees.
> - When using `find -regex` with alternation, put the longest alternative first. Example: use `'.*\.\(tsx\|ts\)'` not `'.*\.\(ts\|tsx\)'` — the second form silently skips `.tsx` files.

这一整段的信号很集中:**每一条都不是 shell 使用最佳实践,而是「在 Claude Code harness 里跑 shell 时踩过的具体坑」**。

- **路径引号** —— 空格路径不加引号直接翻车,一条最低配约束
- **避免 cd** —— worktree / subagent / 多种触发 CWD 变化的路径共存,cd 之后 Claude 会错判,而**绝对路径永远精确**
- **反轮询** —— 有 background + notification 机制,不该用 sleep 假装等待。「等一件事」有 `run_in_background`,「等多次事件」有 Monitor tool,「重试失败」应该改 root cause 而不是 loop 重跑
- **find 从当前目录出发** —— 从 `/` 找会扫全盘,大目录直接吃爆内存
- **find -regex 长优先** —— 一个非常具体的 GNU find 陷阱:`\(ts\|tsx\)` 会漏掉所有 `.tsx`,得写成 `\(tsx\|ts\)`

最后一条尤其有意思 —— **它是从血泪教训里长出来的**。有人写过 `find . -regex '.*\.\(ts\|tsx\)'` 结果 `.tsx` 文件全部漏搜,而且 find 不会报错(silently skips)。这种"静默失败"最难 debug,所以专门在 prompt 里留了一条。

**git 安全协议:一整段专门规矩**

> Git Safety Protocol:
> - NEVER update the git config
> - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly requests these actions. ...
> - NEVER skip hooks (--no-verify, --no-gpg-sign, etc) unless the user explicitly requests it
> - NEVER run force push to main/master, warn the user if they request it
> - CRITICAL: Always create NEW commits rather than amending, unless the user explicitly requests a git amend. When a pre-commit hook fails, the commit did NOT happen — so --amend would modify the PREVIOUS commit, which may result in destroying work or losing previous changes. Instead, after hook failure, fix the issue, re-stage, and create a NEW commit
> - When staging files, prefer adding specific files by name rather than using "git add -A" or "git add .", which can accidentally include sensitive files (.env, credentials) or large binaries
> - NEVER commit changes unless the user explicitly asks you to. ...

这一大段每一条都是可以独立成一篇 postmortem 的规则。挑最典型的三条看设计意图:

- **amend 那条**给了完整因果链:"pre-commit hook fails → commit did NOT happen → --amend would modify the PREVIOUS commit → 可能毁掉之前的工作"。为什么讲得这么细?因为 hook 失败这个场景 AI 特别容易搞错 —— 看到 hook 报错,以为自己刚才那个 commit 存在但脏了,然后 `--amend` 修复,结果实际上改的是 hook 生效之前的老 commit,把用户上一次干净的工作污染了。这是**从血泪教训里长出来的因果链**,不是抽象原则。
- **`git add -A` 禁令**也是防真实事故:AI 一时不察 `git add .` 把 `.env` / `credentials.json` / node_modules 里的二进制全部推上去。加"specific files by name"这条硬规矩,把「暂存哪些」变成一个显式决策,而不是默认全揽。
- **「NEVER commit unless explicitly asked」**是一条礼貌规矩 —— 不是防坏事,是防太主动。Claude 改完一段代码就自动 commit,会让用户觉得被"抢戏",破坏协作节奏。

**PR 创建流程:一整段工作流规矩**

> Analyze all changes that will be included in the pull request, making sure to look at all relevant commits (NOT just the latest commit, but ALL commits that will be included in the pull request!!!), and draft a pull request title and summary:
> - Keep the PR title short (under 70 characters)
> - Use the description/body for details, not the title
>
> Important:
> - DO NOT use the TaskCreate or Agent tools
> - Return the PR URL when you're done, so the user can see it

这段的四个信号点:①**从改动到 PR 的完整工作流**都在 prompt 里(diff → 分析所有 commit → 生成 title/summary → gh pr create);②**PR title 70 字符硬限** —— 明显是被 GitHub UI 折行坑过;③**「ALL commits, NOT just the latest!!!」三个感叹号** —— 显然是踩过「只看最后一个 commit 写 PR 描述」的坑;④**结尾叮嘱返回 PR URL** —— 用户拿到就能开。

这不是「shell 使用最佳实践」· 而是**「用 shell 完成软件工程任务的最佳实践」**。同样 hardcode 到 prompt 里,让每次 gh pr create 都自然符合协作规范。

**HEREDOC 传 commit message**

> In order to ensure good formatting, ALWAYS pass the commit message via a HEREDOC, a la this example:

单拎出来说,这条防的是一个非常具体的失败模式:用 `-m "..."` 传多行 commit message,shell 会把换行折成一行,导致 commit message 变成一坨。HEREDOC 语法 `git commit -m "$(cat <<'EOF' ... EOF)"` 是唯一保格式的方式。

#### 3 · 字段级描述

Bash 有 5 个字段。命名极简 —— 全都望文生义:

| 字段 | 类型 | 作用 |
|---|---|---|
| `command` | string | 要执行的 bash 命令(必填) |
| `description` | string | 描述这个命令做什么(强烈建议) |
| `timeout` | number | 超时毫秒数(默认 120000 · 最大 600000) |
| `run_in_background` | boolean | 是否后台运行(默认 false) |
| `dangerouslyDisableSandbox` | boolean | 关闭沙盒(默认不用) |

字段少,但每个背后都有非平凡的设计。挑 3 个关键设计点展开:

**description:让 tool call 可读的双通道表达**

description 不是给 Bash 用的,是**给用户和 Claude 未来的自己看的**。tool call log 里显示的不是 `git status`(用户看不懂 Claude 意图),而是 `Show working tree status`(用户一眼明白)。

description 的写法也被约束死了。工具描述里给了非常具体的两组示例:

- **简单命令**(git / npm / 标准 CLI):5-10 字简短
  - `ls` → "List files in current directory"
  - `git status` → "Show working tree status"
  - `npm install` → "Install package dependencies"
- **复杂命令**(pipeline / 奇怪 flag):加足够上下文
  - `find . -name "*.tmp" -exec rm {} \;` → "Find and delete all .tmp files recursively"
  - `git reset --hard origin/main` → "Discard all local changes and match remote main"
  - `curl -s url | jq '.data[]'` → "Fetch JSON from URL and extract data array elements"

甚至禁词都定了:**Never use words like "complex" or "risk" in the description**。不吓唬人、不夸大风险,只说命令做什么。

这是把「命令」和「意图」分开表达 —— **命令给机器执行,意图给人审阅**。tool call log 从此变成一份可读的操作清单,而不是一堆 shell 指令。

**run_in_background:非阻塞异步的入口**

如果一个命令预期跑很久(dev server / 训练 / 等 CI),设 `run_in_background=true`:命令立即返回一个 shell/task ID,Claude 继续对话不阻塞,完成时通过 `<task-notification>` 通知,可以用 BashOutput / TaskStop 检索输出或强杀。

这个 flag 让 Bash 变成 Claude 的「非阻塞 IO」:起个 dev server 后继续改代码,而不是干等。它也是「反轮询原则」的下游支撑 —— 官方为什么敢让 Claude 别用 sleep 轮询?因为有 `run_in_background` + notification 机制兜底。

**dangerouslyDisableSandbox:命名即劝退**

默认 Bash 是在 sandbox 里跑的 —— 有些操作会被拦截(比如系统级配置修改)。这个 flag 可以关掉沙盒。但字段名里的 `dangerously` 前缀不是装饰 —— 它是**命名层面的一道劝退**,让 Claude 每次填这个字段都得多想两秒:「我真的需要关沙盒吗?」

对比 Edit / Write 的字段名都是中性的(`file_path` / `old_string` / `content`),Bash 里出现一个带 `dangerously` 前缀的字段 —— 这个不对称本身就是信号:**能力越大,命名越警惕**。

#### 4 · schema 校验规则

Bash 的 schema 层校验极简:

| 字段 | 约束 |
|---|---|
| `command` | 必填 · string |
| `description` | 可选 · string(但描述里强烈建议填) |
| `timeout` | 可选 · number · max 600000(10 分钟) |
| `run_in_background` | 可选 · boolean |
| `dangerouslyDisableSandbox` | 可选 · boolean |

**Bash 的真正约束全部不在 schema 里**,而在两个地方:

1. **工具描述里的一大段自然语言约束**(专用工具优先 / 引号 / 避免 cd / 反轮询 / git 安全协议 / PR 流程 / HEREDOC)—— 全靠 prompt 劝
2. **harness runtime 层的执行边界**(sandbox 拦截 / timeout kill / permission prompt / 后台任务生命周期)—— 靠环境兜底

对比 Edit / Read 的 schema:Edit 有唯一性检查 / Read 前置状态机;Read 强制绝对路径;都是**可以用 schema + runtime 状态机拦下来**的具体约束。Bash 干不到,因为 Bash 的入参就是「一根字符串,里面能塞任何命令」—— schema 校验根本没法穷举「哪些命令是危险的」。

这解释了为什么 Bash 的工具描述那么长 —— **能力越无边界,越依赖 prompt 层的自然语言约束**。硬约束扛不住的,只能靠软约束反复劝。

---

### 一个有趣的注解

写这个系列的过程,发生过一次特别有教学价值的现场翻车。记下来,当反面案例。

**场景**:写到第十三篇 Monitor 的时候,需要让 Claude 核对一下已经写好的章节里 8 条 prompt 约束的位置。第一反应,看看 Claude 调了什么工具?

```
Bash(command: 'grep -n "约束 2\|约束 3\|约束 4\|约束 5\|..." "十三 Monitor.md" | head -20')
```

**用 `bash grep`。而不是专用的 Grep tool**。

**这个反例的三重讽刺**:

1. **本篇开头就讲过**:Bash 篇「触发条件」一节有一张明确的「不该用 Bash」对照表 —— 第一行就是 `grep -r "pattern" .` → 应该用 **Grep tool**。理由:Grep 有 output_mode、head_limit,专用工具规范化、无 shell escape。
2. **系列(四)Grep+Glob 篇整篇在讲**:「专用 tool 避开 Bash 陷阱」是那一篇的核心论点之一。
3. **系列写到第 13 篇了**:换句话说,「Bash 是兜底不是首选」这个论断已经被复述过 13 次 —— **知行完全不一**。

**为什么会这样?**

我问了 Claude 得到的解释：

> 坦白讲三个原因:
>
>- **训练数据惯性** —— `bash grep` 是命令行工程师的肌肉记忆,一线的 grep 用法在训练语料里出现频次远超「Grep tool 参数化调用」。AI 的第一反应会跟随训练数据里的高频模式,不会跟随刚学到的规则。
>- **短命令的顺手错觉** —— `grep -n xxx file | head -20` 一行搞定,感觉「不用构造 tool call 参数」快得多。这是错觉:构造 `Grep(pattern, path, output_mode, ...)` 的成本其实很低,但**"多打几个字段"的心理阻力**在 AI 决策链里被高估了。
>- **shell escape 陷阱本身就是 Bash 的问题** —— 那行 grep 里用了 `\|` 转义 · 正是 Grep+Glob 篇警告过的东西。Grep tool 里直接写 `"约束 [2-8]"` 干净得多,但 shell 惯性让 AI 掉进了系列自己拆过的坑。

**这条注解的核心教学**:

**光靠 prompt 约束是不够的 —— 面对 AI 训练数据里根深蒂固的惯性,只有 runtime 硬阻断能真正 override**。

回头看 Claude Code 里那些**真正被遵守**的约束:

- **Edit 要求 Read 先行** —— runtime 硬阻断,没读就 error
- **Plan mode 收窄工具白名单** —— runtime 硬阻断,Edit / Write 直接不可用
- **Read 强制绝对路径** —— runtime 硬阻断,相对路径直接报错
- **CronCreate 只在 session 内** —— runtime 硬阻断,session 结束一切清空

这些约束的共同点:**AI 想违反都违反不了**。

反之,**「Bash 优先专用工具」是纯 prompt 约束** —— 没有 runtime 硬阻断,没有 tool 层校验,「推荐用 Grep」但 Bash 里 grep 依然能跑,而且跑得好好的。这种「靠自律」的约束,面对训练数据惯性,**每一次调用都是 Claude 的自律判断,自律就会有漏**。

**推论**:如果 Anthropic 想真让 Claude 停止用 Bash 干专用工具能干的事,最有效的做法不是加更多 prompt,而是**在 Bash sandbox 里把 grep/cat/sed/echo/ls 拦截掉,让它 error out 并提示用专用工具**。**物理不允许**才是真的不允许。

**这也是本篇一开始那段论断的一个反面例证**:「能力越大,约束越多」。**Bash 的能力越大,越难被 prompt 约束住** —— 因为 Bash 里能干的事太多,穷举出「哪些该用专用工具」在 prompt 里根本讲不完。系列作者本人在写作过程中都会漏,更不用说其他 AI 使用场景。

**留给读者的问题**:你观察过 Claude 什么时候「明明有专用工具却用 Bash 兜」?这些场景值得写进你的 CLAUDE.md · 用**硬约束**(比如 hooks 拦截)把这些惯性关进笼子里。

---

### 与邻居工具的分工

Bash 跟前七个工具形成完整对照:

| 维度 | 三交互原语 | Grep + Glob | Read | Edit | Write | Bash |
|---|---|---|---|---|---|---|
| 定位 | 协作对齐 | 定位坐标 | 感知外部 | 精准执行 | 全量执行 | 命令执行 |
| 能力边界 | 有限 · 结构化 | 有限 · 搜索 | 有限 · 读 | 有限 · 替换 | 有限 · 覆盖 | **无限** |
| 主要作用 | 与用户对齐 | 定位文件 | 感知文件 | 改文件 | 写文件 | **改真实世界** |
| 风险面 | 低 | 低 | 低 | 中 | 中高 | **高** |
| 约束风格 | 交互规则 | 参数约束 | 前置约束 | 唯一性 + Read | Read + 目录 | **prompt 层大量硬约束** |

**Bash 在整套工具生态里的独特位置**:前七个工具都是「有边界的原语」 —— 能力有限、风险可控、语义明确。Bash 是**「无边界的兜底」** —— 能力无限、风险最高、语义完全靠 Claude 拿捏。

正因为 Bash 无边界,它承担了两个别的工具承担不了的角色:

- **执行验证** —— 改完代码要跑测试才知道对不对
- **推进工程流程** —— commit / push / PR / deploy 都要靠它

如果说前七个工具让 Claude 能「精确操作文件」,那 Bash 让 Claude 能「真正参与到工程流程里」 —— 从只会改代码的 AI,升级为能推进项目从修改到交付的协作者。

Bash 也是「其它工具改完之后需要真实执行验证」的承接者。系列作者常见的工作流是:Glob 定位 → Grep 精确找函数 → Read 打开文件 → Edit 精准替换 → **Bash 跑测试确认** → Bash git commit → Bash git push。前面五个工具是「改一个文件」的原语,只有 Bash 能把改动**送到真实世界**去检验和交付。

---

### 小结

Bash 独特的地方在于它是**「无边界的兜底」** —— 能力无限、风险最高、语义完全靠 Claude 拿捏。它的信号分布**极度偏向工具级描述**:

- **命名** —— 一个词,`Bash` 明确"交给真实 shell 解析",不叫 `Exec` 避免误以为可传结构化 argv。字段级出现一个 `dangerouslyDisableSandbox`,前缀直接刻在名字里当劝退
- **工具级描述** —— **本工具最长的一层**。核心定位一句 + 反例白名单(cat/head/tail/sed/awk/echo)+ 通用注意事项(引号 / 避免 cd / 反轮询 / find 陷阱)+ git 安全协议(amend / add -A / commit 时机)+ PR 创建流程(所有 commit / 70 字符 / 返回 URL)+ HEREDOC 规范 —— 全靠 prompt 劝
- **字段级描述** —— 5 字段,每个背后都是非平凡设计(description 双通道表达 / run_in_background 非阻塞异步 / dangerously 命名劝退)
- **schema 校验** —— 极简,只有 timeout 上限、bool、string 这类基本 type 约束。**真正的约束都不在 schema 里**,一半在工具描述里劝、一半在 harness runtime 兜底(sandbox / timeout kill / permission prompt)

这个分布跟 Edit / Read 形成鲜明反差 —— Edit / Read 是「靠 runtime 状态机拦」,Bash 是「靠自然语言劝」。原因很简单:**Bash 的入参是一根字符串,里面能塞任何命令,schema 校验根本没法穷举**。**能力越无边界,越依赖 prompt 层的自然语言约束**。

而正如「一个有趣的注解」暴露的:**光靠 prompt 约束是不够的** —— 面对训练数据惯性,每次调用都是 Claude 的自律判断,自律就会有漏。要真的把这些惯性关进笼子,只能靠 hooks / sandbox 拦截这类 runtime 硬约束。这是 Bash 作为 catch-all 通用工具留给整套工具生态的核心洞察。

下一篇继续拆 [Agent](agent.md) —— Claude Code 里最独特的工具:**让 Claude 派另一个 Claude 去干活**。如果说 Bash 让 Claude 突破了「只能改代码」的边界,Agent 让 Claude 突破了「一个 context 的边界」。看看这个「派生 subagent」的能力是怎么设计的。

