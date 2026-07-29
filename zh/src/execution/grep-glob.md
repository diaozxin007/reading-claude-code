Claude code tools 研究系列第四篇。前三篇拆完了「交互原语三件套」—— [AskUserQuestion](../interaction/ask-user-question.md)、[EnterPlanMode](../interaction/enter-plan-mode.md)、[ExitPlanMode](../interaction/exit-plan-mode.md)。这三个工具解决「AI 和用户怎么对齐」。

从这篇开始,进入**执行原语**的世界 —— Claude 拿到方案后,怎么把代码真的改出来。但在读、改、写之前,先要**知道去哪里读改写**。所以第一个要拆的执行原语是**搜索双人组**:Glob 按路径找 · Grep 按内容找。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Grep + Glob

Claude 刚进入一个新项目时,根本不知道文件路径 —— 「auth 相关代码在哪?」「哪些文件用了 useState?」「最近改过的文件是哪些?」这类问题,如果没有搜索工具,Claude 只能靠训练记忆猜(不准)或让用户手动列(累)。

Claude Code 里搜索是双人组:**Glob 按路径找 · Grep 按内容找**。这一篇把两个工具合并讲,因为它们功能高度耦合、经常组合使用,拆开写会重复很多。

它们共享一个核心哲学:**按需感知 · 只把 Claude 真正需要看的东西送到 context 里**。这也是接下来要拆的 [Read](read.md) / [Edit](edit.md) / [Write](write.md) 三个「文件操作原语」的前置工具。

### 作用

**Glob** 是**按路径 pattern 找文件**的工具 —— 输入一个 shell glob (`**/*.ts` / `src/**/api-*.js`),返回匹配的文件路径列表,按修改时间倒序排。

**Grep** 是**按内容找文件 / 找行**的工具 —— 底层是 ripgrep,输入一个正则表达式,返回匹配的文件路径 / 匹配行 / 匹配数量(三种输出模式可选)。

它们共同解决的核心问题是「Claude 如何在一个庞大 codebase 里**定位到需要看的文件**」:

1. **不用整读整个项目** —— 定位到需要看的文件再 Read,省 context
2. **不用猜文件在哪** —— 相比训练记忆,搜索直接给磁盘真相
3. **不用拼 Bash 命令** —— 专用 tool 避开 shell escape / 路径依赖 / 权限问题
4. **输出模式可控** —— 尤其 Grep,三档 output_mode 让 Claude 按需拿数据

### 一个具体例子

**场景**:用户说 **「你帮我看看 auth 相关的代码是怎么组织的 · 我要 refactor」**。

Claude 完全不知道 auth 代码在哪:可能在 `src/auth/`、`server/middleware/`、`lib/security/`,也可能散在 `pages/api/login.ts` 里。

#### 反例:如果只有 Read

Claude 没有搜索工具,只能:

- **凭训练记忆猜** —— 「Node.js 项目 auth 一般在 `src/middleware/auth.js`」,Read 过去发现不存在
- **让用户列文件** —— 「auth 相关的文件路径能告诉我吗?」用户手动列一堆,累
- **整个 src/ 都 Read 一遍** —— 一个中等项目就 200 个文件,几十万 token,context 直接爆

**痛点**:没有搜索 = Claude **看不清 codebase 的形状** · 只能靠间接信息或暴力全读。

#### 用 Grep + Glob 是怎么解决的

**Step 1 · 用 Glob 先摸文件轮廓**

Claude 调 Glob:

- `pattern`: `**/*{auth,login,session,jwt}*`(匹配路径 / 文件名里带这些关键词的)

返回:
```
src/auth/middleware.ts    (2h ago)
src/auth/routes.ts        (2h ago)
src/lib/session-store.ts  (3d ago)
src/pages/api/login.ts    (1w ago)
tests/auth.test.ts        (2h ago)
```

按修改时间倒序 —— **最近改过的排前面**,通常是主战场。

**Step 2 · 用 Grep 深挖具体调用**

Claude 想知道「哪里在用 `jwt.verify`」:

- `pattern`: `jwt\.verify`
- `output_mode`: `content`(返回匹配行 + 文件路径 + 行号)
- `-C`: `2`(前后各 2 行上下文)
- `type`: `ts`

返回:
```
src/auth/middleware.ts:8:      const decoded = jwt.verify(token, process.env.JWT_SECRET);
src/auth/middleware.ts:9:      req.user = decoded;
--
src/services/api-client.ts:42:  return jwt.verify(token, PUBLIC_KEY);
--
```

**每一条都是精确坐标 · 立刻可以 Read 或 Edit**。

**Step 3 · 组合使用**

如果 Claude 只想知道**多少个文件用了 jwt.verify**(而不是具体在哪):

- `pattern`: `jwt\.verify`
- `output_mode`: `count`

返回 `4 files`。这次调用只花几十 token,不用把匹配行都拉进 context。

如果只想知道**哪些文件用到**(路径列表,不要具体行):

- `pattern`: `jwt\.verify`
- `output_mode`: `files_with_matches`

返回文件路径列表。

**核心洞察**:Grep 的三档 output_mode(**content / files_with_matches / count**)让 Claude 可以**按需精度地拿数据** —— 想深挖就拿匹配行 · 想缩小范围就拿路径列表 · 想估算规模就拿计数。

### 触发条件

**什么时候用 Glob**:

- **按文件名 / 路径找** —— 「所有 `.tsx` 文件」/「`src/api/` 下所有文件」/「测试文件在哪」
- **按修改时间找** —— 「最近改过的文件」(Glob 默认按 mtime 倒序)
- **组合 Grep 前先缩范围** —— 先 Glob 缩到相关文件,再 Grep 深挖

**什么时候用 Grep**:

- **按内容找文件 / 行** —— 「哪里用了 useEffect」/「哪里定义了 UserBadge」
- **调查 API 使用面** —— 「所有调用 `db.query` 的地方」
- **搜错误信息** —— 用户贴了一段报错,搜 codebase 里哪里可能抛这个

**什么时候两者组合**:

- **大 codebase 里定位模块** —— 先 Glob 缩到 `**/*auth*` 相关文件 · 再 Grep 具体调用
- **限定语言 / 类型** —— 只在 `.ts` 文件里搜 —— Grep 的 `type: "ts"` 直接搞定,不用 Glob 前置

**什么时候不该用**:

- **知道确切路径的 Read** —— 直接 Read,不用 Grep/Glob 兜圈子
- **列目录**(而不是找 pattern) —— 用 Bash `ls`,Glob 是 pattern 匹配不是目录浏览
- **模糊语义搜索**(比如「找所有做认证的代码」) —— Grep 只能字面 / 正则匹配,不理解语义,应该用 Agent 派 subagent 去调研

### 技术实现

Grep 和 Glob 是**姊妹工具** —— 分工清晰但共享设计理念。分开拆 4 层,再看一次它们的对偶。

---

## Glob

#### 1 · 命名

`Glob`

命名直接借用 shell / Python glob 库的行业约定 —— 「glob」就是"按路径 pattern 找文件"的通用叫法。字段 `pattern` / `path` 都是任何 shell 用户直觉能懂的名字。

如果叫 `FindByPath` 或 `SearchFiles`,反而弱化了「用 glob 语法而非正则」这个核心承诺。命名本身就在暗示语法。

#### 2 · 工具级描述

Glob 的描述极短,只有 5 条 bullet,围绕两件事:**用法约束 · 边界外包**。

**pattern 是 glob 语法,不是正则**

> Supports glob patterns like "**/*.js" or "src/**/*.ts"

只给两个例子、不给正则例子。**用示范代替禁令** —— 与其写"不要用正则",不如让 Claude 看到 `**/*.js` 这种典型 glob 形态。防止 Claude 把 `.*\.ts` 塞进 pattern 里。

**返回按修改时间倒序**

> Returns matching file paths sorted by modification time

声明输出的 total order。这条描述让 Claude 建立直觉:**Glob 返回的第一个文件是最近改的**。「找项目主战场」/「找刚 refactor 过的模块」这类任务直接吃头几条就够。

**明确用途:按文件名找**

> Use this tool when you need to find files by name patterns

虽然 Grep 也有 `glob:` 字段能过滤路径,但那是**过滤**不是**搜索**。Glob 是文件名的一等公民工具。

**开放式搜索转 Agent · 不硬扛**

> When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead

这条最有意思:**主动承认自己的边界**。如果任务需要多轮 glob + grep 交替(比如「找哪个模块最近改坏了」),描述主动让 Claude 换 Agent tool,别在单次 Glob 里死磕。

#### 3 · 字段级描述

- `pattern` —— shell glob 表达式(`**/*.js` / `src/**/*.{ts,tsx}`),不是正则
- `path` —— 可选,限定搜索目录(默认 CWD)

字段极简。**修改时间排序**是个隐藏的宝贝设计:人类程序员想「最近在改哪块」时,直觉就是看 `ls -lt`。Glob 默认输出按 mtime 倒序,**让 Claude 一眼看到项目主战场**。冷代码沉在下面,热代码浮在上面。

#### 4 · schema 校验规则

**极简**。只有 `pattern` 必填、`path` 可选,没有额外的数值约束。

Glob 的信号几乎全在**命名 + 工具描述**上。schema 层不加限制,因为 glob 语法本身已经足够收敛。

---

## Grep

#### 1 · 命名

`Grep`

同样借用行业约定 —— 「grep」是 Unix 世界公认的"按内容匹配"操作。但要注意,tool 底下用的是 **ripgrep**(rg),不是传统 grep。命名保留最熟悉的名字降低认知门槛,内部升级到更快的引擎。

#### 2 · 工具级描述

Grep 的描述比 Glob 详一档,7 条 bullet + 一句宣言,围绕四件事:**双向锁死用法 · 语法说明 · 过滤维度 · 边界外包**。

**ALWAYS · NEVER · 双向锁死**

> ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.

**整个 Grep 描述里最重的一句**。ALWAYS + NEVER 双向锁死:正面说要用什么、反面禁止哪条捷径、加一句「已优化 permissions 和 access」把「为什么」也答了。防的是 Claude 熟稔 shell 后本能地想走 `Bash("rg foo")` —— bash 里 rg 输出不结构化,也过不了权限层。

**pattern 是 ripgrep 正则**

> Supports full regex syntax (e.g., "log.*Error", "function\s+\w+")

跟 Glob 明确对立 —— Grep 的 pattern 是**正则**。给两个真实感很强的例子:`log.*Error`(找日志 error)、`function\s+\w+`(找函数定义),Claude 一看就知道语法风格。

**两条过滤维度 · glob vs type**

> Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")

给 Claude 两条并列的路径:走 `glob:`(精确路径 pattern)或走 `type:`(语言 shortcut,ripgrep 内置表)。type 是 ripgrep 特色 —— 一个 `type:rust` 顶写 `**/*.{rs,toml}` 那种。

**output_mode 默认 files_with_matches**

> Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts

**注意 "(default)" 标在 files_with_matches 上**。为什么不是 `content`?因为 **content 最耗 context**,把它设成默认容易爆。默认拿路径列表,Claude 再决定要不要深挖。这是**尊重 token 预算的默认值**。

**开放式搜索转 Agent(和 Glob 对称)**

> Use Agent tool for open-ended searches requiring multiple rounds

跟 Glob 完全对称。两个工具**成对声明自己的边界** —— 遇到多轮迭代场景,换 Agent。

**ripgrep 不是 grep · 字面量要转义**

> Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\{\}` to find `interface{}` in Go code)

给一个**具体的踩坑例子**:找 Go 代码里的 `interface{}`,得写成 `interface\{\}`。为什么专门讲这个?因为 `{}` 在 ripgrep 里是**量化范围符**(`a{2,3}` 表示重复 2-3 次),Claude 若按 grep 直觉写 `interface{}` 会报正则错。**用一个真实例子代替长篇语法讲解**。

**multiline 默认关闭 · 显式开启**

> Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \{[\s\S]*?field`, use `multiline: true`

**默认单行匹配** —— 这条防的是 Claude 写了个跨行正则却拿不到匹配还不知道为啥。给个具体例子:找 Go struct 内的 `field` 声明,得 `multiline: true`。**默认关 + 显式开**这个 pattern 用了两次(这条 + Read 的 pages 参数),都是"贵" behavior 走显式开关。

#### 3 · 字段级描述

Grep 的字段远比 Glob 丰富:

- `pattern` —— 正则表达式(ripgrep 语法)
- `path` —— 可选,限定搜索目录
- `glob` —— 可选,只搜匹配 glob 的文件(比如 `"*.ts"`)
- `type` —— 可选,只搜特定语言(`ts` / `py` / `rust`)
- `output_mode` —— `content` / `files_with_matches`(默认) / `count`
- `head_limit` —— 限制输出行数
- `-i` —— 大小写不敏感
- `-n` —— 显示行号(content 模式默认加)
- `-A` / `-B` / `-C` —— 后 / 前 / 前后上下文行数(仅 content 模式)
- `multiline` —— 允许模式跨行匹配
- format flags(`-c`, `-l`, `-L`, `-o`, `-Z`) —— 让 grep 走原生,不做包装

**几个关键设计点**:

**output_mode 三档设计** —— 这是 Grep 最精妙的部分。同一个搜索,可以出三种精度:

- `content`(全量匹配行) —— 需要看具体在哪、上下文什么样
- `files_with_matches`(仅文件路径) —— 只想知道涉及哪些文件
- `count`(仅计数) —— 只想知道规模

对应三种典型意图:「我要 fix」(content)/「我要重构」(files_with_matches)/「我要评估」(count)。Grep 让 Claude **按意图选精度**,避免每次都拿全量数据浪费 context。

**head_limit 的兜底** —— 一个 `console.log` 搜索可能返回 1000 行,不做限制会把 context 灌爆。`head_limit: 50` 让 Grep 只返回前 50 条,**够用又不爆炸**。注意 head_limit 前的排序对 Grep 是**按文件路径字典序**,对 Glob 是**按修改时间倒序**,不是相关性排序、只是截断。

**type vs glob 两种缩范围** —— type 是 ripgrep 基于文件内容/扩展名的语言识别,认识 `.py` `.rs` `.ts` 这类;glob 是纯路径匹配,能处理特殊路径(比如 `**/legacy/**/*.js` 排除某个目录)。type 更简洁,glob 更灵活。

**「format flags 原样透传」的降级通道** —— 当 tool 的规范化输出不够用时,Claude 可以「掉到」原生 ripgrep 的能力。设计者知道自己包装不完美,留了个逃生舱。

#### 4 · schema 校验规则

Grep 的 schema 层也**几乎没有硬约束**(数值限制、字符长度),所有约束都是**枚举**:

| 字段 | 类型 | 约束 |
|---|---|---|
| `output_mode` | string | 枚举 `content` / `files_with_matches` / `count`,默认 `files_with_matches` |
| `-i` / `-n` / `multiline` | boolean | 默认 false |
| `-A` / `-B` / `-C` | integer | 只在 output_mode = content 时生效 |
| `head_limit` | integer | 无默认,不填则不限 |

**默认值是 Grep 的核心设计** —— output_mode 默认 `files_with_matches`、multiline 默认关、i/n 默认关。**每个默认都朝"少输出 · 简单模式"倾斜**,让 Claude 用默认值就已经在最省 context 的档位。

---

### 为什么专门做 Grep/Glob 而不让 Claude 用 Bash + rg?

Bash 是 catch-all,理论上什么都能干。但直接调 rg 有一堆问题:

- **shell escape** —— 正则里的 `$` `!` `(` 都可能被 shell 展开
- **路径依赖** —— rg 是不是装了?版本是啥?
- **输出解析** —— Bash 返回一大坨文本,Claude 得自己解析
- **没有 output_mode 分档** —— rg 的 flag 太多,Claude 得记

专用 tool 把这些痛点全解决了:参数 typed、输出规范化、无 shell 陷阱、Claude 一次搞定。这也是 Grep 描述里那句 "ALWAYS use Grep... NEVER invoke grep or rg as a Bash command" 的**技术底座**。

---

### 与邻居工具的分工

**Grep + Glob 在 Claude Code 执行原语体系里的位置** —— 提前给出一个「地图」,后续几篇会逐个填充:

| 维度 | 三交互原语(已讲) | Grep + Glob(本篇) | Read(下篇) | Edit(第六篇) | Write(第七篇) |
|---|---|---|---|---|---|
| 定位 | 协作对齐 | 定位坐标 | 感知内容 | 精准执行 | 全量执行 |
| 频率 | 关键节点 | 日常高频 | 日常高频 | 日常高频 | 中频 |
| 输入 | 结构化 / 空 | pattern(不需要知道路径) | 已知路径 | 已知路径 + old_string | 已知路径 + 完整内容 |
| 输出 | 用户决策 | 路径列表 / 匹配行 / 计数 | 完整文件内容 | 修改后的 diff | 新文件 / 覆盖 |
| 保守偏差 | 「不确定就规划」 | 「先按需搜再全读」 | 「不确定就读」 | 「不确定就 Read」 | 「能 Edit 就 Edit」 |

**完整调查链**(把后续几篇的执行原语组合起来):

```
用户: 帮我 refactor auth 相关代码
    ↓
Glob (**/*{auth,login,session}*)              ← 本篇
    → 得到相关文件路径列表 (按 mtime 排序)
    ↓
Grep (pattern: "jwt\.verify", output_mode: files_with_matches)  ← 本篇
    → 得到具体使用了 API 的文件
    ↓
Read (每个相关文件)                              ← 下一篇
    → 拿到完整内容,建立感知承诺
    ↓
Edit / Write                                     ← 后续
    → 基于感知承诺做精准 / 全量修改
```

**执行原语的信任链**:

- **Glob / Grep** —— 定位:「哪些文件与这个任务相关」
- **Read** —— 感知:「这些文件当前长什么样」
- **Edit / Write** —— 执行:「基于感知做精准 / 全量修改」

每一步都是 runtime 强制、参数 typed、输出规范化的。**从一个模糊的用户需求,收敛到一次精准的文件改动**,整个过程可预测、可审阅、可组合。

---

### 小结

Grep + Glob 的精妙之处,不在于「让 AI 能搜索」这个功能本身,而在于它们的信号分布**极其对称又各有侧重**:

- **Glob** —— 命名承担核心语义(直接用行业约定)、字段极简、schema 无约束。整个工具的复杂度就是"按 glob 语法找路径"这一件事
- **Grep** —— 字段最丰富的一环(11 个字段/flag),但 schema 层没有数值硬约束,全靠**默认值收敛到最省 context 的档位**

两个工具最精彩的一处对称:**都在描述层主动承认边界** —— 遇到"多轮 glob + grep 交替"这种场景,主动让 Claude 换 Agent。**工具知道自己适合什么、不适合什么** —— 这是 Claude Code 工具生态里非常克制、非常成熟的设计。

这也是 Claude Code 工具生态的核心哲学 —— **不是给 AI 一个万能的 shell 让它自己想办法,而是把每一步都做成一个「够用 + 安全 + 可组合」的原语**。

下一篇继续拆 [Read](read.md) —— 拿到坐标后,Claude 如何精准地感知一个文件的当前状态,为 Edit / Write 建立起「感知承诺」的信任链。
