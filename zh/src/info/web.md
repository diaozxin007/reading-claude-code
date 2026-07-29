Claude code tools 研究系列第十一篇。前十篇拆完了 Claude Code 主要的**内向工具集** —— 从与用户对齐、到操作本地文件系统、到执行命令、到派生 subagent、到管理待办任务。所有工具都围绕**本地环境**打造:改本地代码 · 跑本地测试 · 派生本地 Claude 实例。

但真实工程任务里,Claude 经常要**走出本地** —— 看一份 Anthropic 的 API 文档、查一个第三方库的 GitHub README、找一段最新的 npm 教程、核对一个官方规范。这些信息不在本地,也不在训练数据里(或者训练数据已经过时了)。

这需要**互联网访问工具**。Claude Code 的答案是双人组:**WebFetch 精准取一个已知 URL 的内容 · WebSearch 用关键词从整个互联网找**。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## WebFetch + WebSearch

这一篇一起讲。理由跟第四篇的 Grep + Glob 一样:两个工具语义高度耦合 · 一个「按 URL 拉」一个「按查询搜」 · 经常组合使用(先 Search 找 URL · 再 Fetch 取内容) · 拆开写会重复很多。

### 家族概览

先给一张表,一眼看清两个工具各自的职责:

| 工具 | 输入 | 输出 | 典型场景 |
|---|---|---|---|
| **WebFetch** | 一个已知 URL | 该页内容(HTML → Markdown) | 「读这个文档 · 提取 X 信息」 |
| **WebSearch** | 关键词 | 一组搜索结果(标题 + URL) | 「找 xxx 的最新做法」 |

**核心分工**:

- **知道 URL** —— 直接 WebFetch,跳过搜索
- **不知道 URL** —— WebSearch 找 · 拿到结果后再 WebFetch 深挖

这个分工跟本地的 Grep+Glob 完全对称 —— Grep+Glob 在本地文件系统里做「搜索 + 定位」 · WebSearch+WebFetch 在互联网上做同样的事。**同一个心智模型,换个域**。

### 作用

WebFetch + WebSearch 共同解决的核心问题是「Claude 如何**突破训练数据时间和范围的边界**,拿到最新和最具体的外部信息」:

1. **突破训练时间边界** —— 训练数据有 cutoff,但 WebSearch/Fetch 能拿到今天的信息
2. **突破训练范围边界** —— 训练数据不一定包含你项目用的小众库,但 WebFetch 能读它的官方文档
3. **官方信息核对** —— 上一篇 [开篇](../interaction/ask-user-question.md) 讲事实核对纪律时提过,带「引用/官方」承诺字样必须实际取原文 —— 这就是 WebFetch 的责任
4. **内容压缩** —— WebFetch 用 AI 处理内容 · 只返回你 prompt 里问的那部分 · 不把整页 HTML 塞给 Claude

它跟前面所有工具的关键差异:**这是唯一「跨出本地边界」的工具家族**。前十个工具的输入输出都在本机,WebFetch+WebSearch 是 Claude 与**外部世界(公网)** 的接口。

### 一个具体例子

**场景**:用户说 **「Anthropic 最近好像发了新的 Claude 4.5 Sonnet 模型 · 帮我查一下它的 API 用法 · 尤其是跟 4 有什么区别 · 顺便看看 pricing」**。

这是一个典型的**信息在互联网上、不在本地、可能超训练截止**的任务。Claude 完全没法靠训练记忆答:

- 模型是新发布的,训练数据没赶上
- API 参数可能有变化,凭猜就是幻觉
- Pricing 数字更是不敢瞎报,报错要负责

#### Step 1 · 用 WebSearch 找入口

Claude 不知道确切的 URL,但知道要在 anthropic.com 找。第一步先 WebSearch:

```
WebSearch(
  query: "Claude 4.5 Sonnet API pricing announcement 2026",
  allowed_domains: ["anthropic.com", "docs.anthropic.com"]
)
```

**注意**:用了 `allowed_domains` 限定域 —— 只在官方站找 · 排除营销号 / 二手转述。

WebSearch 返回一组结果:

```
1. Claude 4.5 Sonnet — Anthropic
   https://www.anthropic.com/news/claude-4-5-sonnet
2. Models Overview — Anthropic Docs
   https://docs.anthropic.com/en/docs/about-claude/models
3. Pricing — Anthropic
   https://www.anthropic.com/pricing
```

**每个结果是标题 + URL** · 不是全文。Claude 现在有了三个精准入口。

#### Step 2 · 用 WebFetch 深挖具体内容

Claude 依次 WebFetch 三个 URL · 每次带一个**具体的 prompt**告诉 WebFetch 要提取什么:

```
WebFetch(
  url: "https://www.anthropic.com/news/claude-4-5-sonnet",
  prompt: "Extract: model release date · main improvements over Claude 4 · benchmark numbers · API model ID"
)
```

**关键点**:WebFetch 的第二个参数不是「返回全文」· 而是**「用这个 prompt 处理内容」**。Runtime 在幕后:

- 抓取 URL
- 把 HTML 转成 Markdown
- **用一个小快的模型** 按 Claude 的 prompt 从内容里提取相关部分
- 只把提取结果返回给 Claude

这意味着一个 5000 字的博客文章 · 主 Claude 拿到的只有 200 字的关键信息。**跟 Agent 派 subagent 一样,是 context 压缩机制**。

三次 WebFetch 之后,Claude 拿到三段结构化摘要,可以给用户答完整的 API 用法 + 差异 + pricing。

#### 关键洞察:WebFetch 是「带 AI 的 curl」

传统 `curl` 是「输入 URL · 返回原始 HTML」。WebFetch 是「输入 URL + 意图 · 返回**处理后的结果**」。

这个差异深远:

- **curl** 让 Claude 承担 HTML 解析 · CSS 干扰 · 广告过滤等负担
- **WebFetch** 把这些丢给 runtime 里的 AI 处理 · Claude 拿到的是已经**「按你的问题提取过」的答案**

这个设计让 WebFetch 成为**「按需从互联网提取信息的原语」** · 而不是「网页下载器」。

### 触发条件

**该用 WebSearch 的场景**:

- **需要最新信息** —— 训练数据 cutoff 之后的事(新 release、最新价格、当年事件)
- **不知道确切 URL** —— 用关键词找入口
- **对比多个来源** —— 从搜索结果里挑几个权威源
- **在特定域内找** —— 用 `allowed_domains` 限定
- **排除特定域** —— 用 `blocked_domains` 屏蔽垃圾站

**该用 WebFetch 的场景**:

- **已知 URL** —— 用户直接给了 · 或从 WebSearch 拿到的
- **读官方文档 / 规范 / API reference** —— 按具体 prompt 提取
- **核对引用** —— 事实核对纪律要求引用必须来自实际读取源
- **抓 GitHub README / 文档** —— 但 `gh` CLI 更好用(见下)

**什么时候两者组合**:

- **典型 pipeline**:WebSearch 找 URL → 选最靠谱的 → WebFetch 深挖 → 综合答复
- **对比研究**:WebSearch 拿 3~5 个来源 → 每个 WebFetch → 交叉验证

**什么时候不该用**:

- **信息在训练数据里** —— 别没事就上网 · 训练数据能答的直接答(比如 JavaScript 基础语法)
- **GitHub 相关内容** —— 用 `gh` CLI(通过 Bash) · WebFetch 抓 GitHub URL 常常权限受限
- **认证过的 URL** —— WebFetch 抓公开 URL · Google Docs / Confluence / Jira / 私有 GitHub 都抓不到(会 401/403)
- **可以本地搜到的** —— 已经在本地项目里的知识 · 用 Grep 而不是 WebSearch

一个**核心原则**:**能不上网就不上网**。上网慢、贵、有失败模式(网络问题、被墙、页面改版)。**只在本地和训练数据都不够时才走公网**。

### 技术实现

WebFetch 和 WebSearch 是**姊妹工具** —— 分工清晰但共享设计理念(都跨出本地边界抓公网信息)。分开拆 4 层,再看一次它们的对偶。

---

## WebFetch

#### 1 · 命名

`WebFetch`

命名直接说清了做什么 —— **抓一个 web 资源**。「fetch」是行业约定动词(fetch API、`git fetch`),暗示「拉过来」而不是「主动查」。字段 `url` 也是任何做过 web 的人一眼能懂的名字。

如果叫 `ReadURL` 会误导 —— 它不是 Read 家族(Read 是无损全量),而是**带 AI 处理的按需提取**。叫 `HTTPGet` 又太底层,丢失了「AI 帮你按 prompt 处理」的核心承诺。**「Fetch」这个词刚好在「拉取原始内容」和「AI 处理」之间**。

#### 2 · 工具级描述

WebFetch 的描述比大多数工具重 —— 开篇就是全大写 IMPORTANT · 后面又跟一串 Usage notes,围绕四件事:**认证失败告警 · MCP 让位 · GitHub 特化 · 重定向协议**。

**开篇 IMPORTANT · 认证服务黑名单**

> IMPORTANT: WebFetch WILL FAIL for authenticated or private URLs. Before using this tool, check if the URL points to an authenticated service (e.g. Google Docs, Confluence, Jira, GitHub). If so, look for a specialized MCP tool that provides authenticated access.

**整个 WebFetch 描述里最重的一句**。用 IMPORTANT + 全大写 WILL FAIL 双重强调:**别浪费一次调用去撞 401**。同时**给了替代路径** —— 找专用的 MCP tool。这条 prompt 在训练 Claude 建立「先看工具集再动手」的直觉:**每一次「no」都带一次「yes」** —— 不是简单说不行,而是「不行、但你可以走这条」。

**MCP 优先让位**

> IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one, as it may have fewer restrictions.

**明确让位给 MCP** —— 承认自己的能力有限。如果 session 里有专门的 web fetch MCP,让它优先。这是工具生态里少见的「谦逊」姿态。跟第一条呼应:**认证内容找 MCP;能力更强的通用抓取也找 MCP**。

**GitHub 特化指引**

> For GitHub URLs, prefer using the gh CLI via Bash instead (e.g., gh pr view, gh issue view, gh api).

**GitHub 单独拎出来说** · 因为它太常见了。用 `gh` CLI 通过 Bash · 走用户本地已登录的凭据 · 比 WebFetch 抓公开页面能拿到更多信息(比如私有仓、review comments)。这是**具体场景压过通用工具**的典型 —— tool 描述里明说「这个场景别用我」。

**跨域重定向的显式协议**

> When a URL redirects to a different host, the tool will inform you and provide the redirect URL in a special format. You should then make a new WebFetch request with the redirect URL to fetch the content.

**不自动跟跨域重定向** —— 把决定权交给 Claude。防止一类攻击:诱导 WebFetch 通过跳转到你没意识到的域。让 Claude 显式确认再抓,是**安全边界**。**同域跟随、跨域上报** —— 是一个既方便又不失控的默认。

**15 分钟缓存透明**

> Includes a self-cleaning 15-minute cache for faster responses when repeatedly accessing the same URL

告诉 Claude 有缓存 · 短时间内重复抓同 URL 会更快 · **鼓励在同一会话里放心重复调用**(有些设计里 Claude 会因为"怕浪费"而不重复调 · 明确 cache 存在能消除这个顾虑)。

**HTTP 自动升级 HTTPS**

> HTTP URLs will be automatically upgraded to HTTPS

隐藏行为透明化 —— Claude 写 `http://` 会自动升级,不用手动改。**降低出错概率,不做静默魔法**。

#### 3 · 字段级描述

WebFetch 字段极少 —— 但每个都是必填,信号密度很高:

- `url` —— 必填,完整 URL
- `prompt` —— 必填,告诉 WebFetch 你想从内容里提取什么

**为什么 prompt 是必填的?**

因为 WebFetch **不返回全文** · 它返回「按 prompt 处理过的结果」。如果没 prompt · runtime 里那个小快模型就不知道该提取什么 · 该总结成什么长度。

对比一下 curl 的心智:

- curl: `curl https://example.com` → 返回原始 HTML(可能几万字)
- WebFetch: `WebFetch(url, prompt="给我提炼这文章的 3 个核心观点")` → 返回 100 字总结

**Prompt 编写就像给一个新同事下指令** —— 越具体,提取质量越好。「读这个页面」是浅薄的 prompt;「找 rate limit 相关的数字 · 有的话列出来 · 没有就说没有」是精确 prompt。

**把 prompt 从可选升级成必填**,是 WebFetch 最精妙的设计决定 —— 强迫 Claude 每一次调用都**先想清楚要什么**再拉,而不是先拉再消化。这个约束本身就是 context 预算的保护机制。

#### 4 · schema 校验规则

WebFetch 的 schema 层几乎**没有硬约束**:

| 字段 | 类型 | 约束 |
|---|---|---|
| `url` | string | format: uri(URL 格式校验) |
| `prompt` | string | 必填,无长度约束 |

**唯一的硬约束是 `url` 走 `format: uri`** —— 不是完整 URL(如 `foo`)直接被 schema 挡回,连 tool call 都发不出去。这是"物理拦截"级别的兜底:**Claude 想传一个域名字符串都不行,必须是完整 URL**。

其他约束全部下沉到 tool description 用自然语言劝导。这跟 AskUserQuestion 那种「三层递进」不同 —— WebFetch 的复杂度不在参数校验,而在**「什么时候不该用」的判断**(认证、GitHub、MCP 让位),那属于 description 层的职责。

---

## WebSearch

#### 1 · 命名

`WebSearch`

**Search** 而不是 `WebQuery` / `GoogleSearch` —— 保持通用性、避开搜索引擎品牌。工具的行为是「给关键词 · 返回一组结果」,这就是 search 的语义。

跟 WebFetch 组成对偶:**Fetch 拿已知 URL · Search 从关键词找 URL** —— 两个词都借用行业约定,不需要解释。

#### 2 · 工具级描述

WebSearch 的描述最有意思的地方在于它**塞了两条别的工具都没有的硬约束** —— 引用义务和时间意识。围绕四件事:**基础能力介绍 · 强制列 Sources · 域过滤 · 年份硬编码**。

**基础能力介绍**

> Allows Claude to search the web and use the results to inform responses. Provides up-to-date information for current events and recent data.

开篇短短两句,把「用途 = 突破训练截止 + 拿最新信息」交代清楚。「up-to-date」这个词点破了 WebSearch 存在的核心理由 —— 弥补训练数据的时效缺陷。

**强制引用 · CRITICAL 级别**

> CRITICAL REQUIREMENT - You MUST follow this:
> - After answering the user's question, you MUST include a "Sources:" section at the end of your response
> - In the Sources section, list all relevant URLs from the search results as markdown hyperlinks: [Title](URL)
> - This is MANDATORY - never skip including sources in your response

**整个 WebSearch 描述里最重的一段**。CRITICAL / MUST(×3) / MANDATORY —— 用词强度是所有工具里罕见的顶格。这不是「建议」是「铁律」。

**为什么强制列 Sources?**

因为 WebSearch 拿到的信息来自不受控源 · 有偏差、有过时、有 SEO 垃圾。**列 Sources 是可追溯性保障** —— 用户能自己核对 Claude 引的来源是不是靠谱。这是把「引用透明化」硬编码到工具里。

这条约束也回应了系列 [开篇](../interaction/ask-user-question.md) 引出的**事实核对纪律** —— 带「引用/官方」承诺字样必须实际取原文。WebSearch 强制附 Sources 是 tool 层的保障:**不给 Claude "偷懒不列源"的余地**。

**域过滤能力提醒**

> Domain filtering is supported to include or block specific websites

明示 Claude:**用户信任特定域时可以 allowed_domains 白名单;想避开某类站点可以 blocked_domains 黑名单**。这个能力常被忽略 · prompt 里显式提醒。跟事实核对纪律呼应 —— 想核对官方原文,用 `allowed_domains: ["anthropic.com"]` 一次卡死非官方源。

**年份硬编码 · 弥补时间感缺失**

> IMPORTANT - Use the correct year in search queries:
> - The current month is July 2026. You MUST use this year when searching for recent information, documentation, or current events.
> - Example: If the user asks for "latest React docs", search for "React documentation" with the current year, NOT last year

**在 tool description 里 hardcode 当前时间** —— 这条约束非常罕见,但原因深刻:Claude 本身**不知道现在几月**(训练截止后就没有时间感) · 但搜索里日期至关重要。「latest React docs」如果查了 2 年前的年份 · 返回的就是过时的文档。

Prompt 里塞时间 · 让 Claude 在搜索关键词里加正确年份 · 拿到真的「latest」内容 · 而不是「训练时以为的 latest」。**给一个 example** —— React docs 场景直接示范"正确 vs 错误"的对比,比抽象讲原理管用。

**仅美国可用**

> Domain filtering is supported to include or block specific websites. Web search is only available in the US

一个不起眼但重要的边界声明。美国之外的 Claude 实例调 WebSearch 会失败 —— **提前告知避免误用**。

#### 3 · 字段级描述

- `query` —— 必填,搜索关键词
- `allowed_domains` —— 可选,白名单(数组)
- `blocked_domains` —— 可选,黑名单(数组)

**两条并列的过滤维度**:

- `allowed_domains` —— 只在这些域找。用于「我只信 anthropic.com / docs.python.org 官方站」的场景
- `blocked_domains` —— 排除这些域。用于「w3schools 这类过时站点不要」的场景

**不能同时用同一个域**(逻辑冲突)。但可以分开用:**白名单收窄权威源 · 黑名单排除垃圾源** —— 两个维度组合出精准的信息获取姿态。

**query 的最小长度是 2** —— 唯一的字段级 schema 硬约束(下详)。防的是 `q: "a"` 这种一个字符的无效搜索。

#### 4 · schema 校验规则

WebSearch 的 schema 层有几处**硬约束**:

| 字段 | 类型 | 约束 |
|---|---|---|
| `query` | string | minLength: 2(至少 2 字符) |
| `allowed_domains` | array of string | 可选 |
| `blocked_domains` | array of string | 可选 |

**query minLength: 2** —— 一个字符的搜索无意义(除非中文单字,但 minLength 是字符数不是字节),schema 层直接挡回。**比在 description 里劝更硬**。

其他约束依然下沉到 description 层。allowed / blocked domains 是**能力开放而非硬约束** —— schema 允许两个数组同时非空,tool description 提醒用户逻辑上别把同一个域塞两边。**能力放开,判断交给 Claude**。

---

### 为什么专门做 WebFetch/WebSearch 而不让 Claude 用 Bash + curl/搜索 API?

Bash 是 catch-all,理论上 `curl` + 搜索 API 也能干。但直接调有一堆问题:

- **HTML 解析负担** —— curl 返回原始 HTML,Claude 得自己剥 CSS / 广告 / 导航干扰
- **认证凭据泄漏风险** —— 用户本地 curl 可能带 `~/.netrc` / cookie · 无意间发出去
- **搜索 API 密钥管理** —— Google Custom Search / Bing API 都要 API key,谁管、怎么给
- **无引用义务** —— curl 结果 Claude 可以随意引不列源,失去可追溯性
- **无内容压缩** —— 一个 5 万字页面全塞进 context,预算爆炸

专用 tool 把这些痛点全解决了:HTML → Markdown 自动转 · 抓取匿名不带凭据 · 搜索 API 管理由 runtime 负责 · **WebSearch 强制列 Sources** · WebFetch 用 AI 按 prompt 提取。这就是「Bash 是 catch-all,专用工具是精加工」的又一次体现。

---

### 小结

WebFetch + WebSearch 的精妙之处,在于把「让 AI 上网」这个泛用需求,拆成两个专用工具,把 4 层设计手段用满。

**信号分布**:

- **命名**:Fetch / Search 两个词全都借用行业约定,Claude 一看就懂两者分工。「Fetch」暗示已知目标拉取 · 「Search」暗示关键词探索。
- **工具级描述**:WebFetch 描述最重的是 IMPORTANT 认证告警 + MCP 让位 + GitHub 特化 —— 三条一起塑造「先看工具集再动手」的直觉;WebSearch 描述最重的是 CRITICAL 强制列 Sources + 当前月份硬编码 —— 一条给「引用可追溯」兜底 · 一条给「时间感缺失」兜底。
- **字段级描述**:WebFetch 只 2 个字段,但 prompt **必填** —— 强迫 Claude 每一次调用都先想清楚要什么再拉,是 context 预算保护;WebSearch 的 allowed / blocked domains 是能力开放,把「信谁」「不信谁」两个维度独立暴露给 Claude。
- **schema 校验**:WebFetch 用 `url: format: uri` 挡回非 URL 字符串 · WebSearch 用 `query: minLength: 2` 挡回一个字符的无效搜索 —— schema 层做物理拦截,把最基础的错误堵在类型检查里。

**几个跨工具的独有设计信号**:

- **prompt 必填** —— WebFetch 的 prompt 参数把「按需提取」变成一等公民,让工具从「网页下载器」升级成「按 prompt 抽取的原语」
- **强制列 Sources** —— WebSearch 是全工具集里**唯一**在 description 里用 CRITICAL / MANDATORY 强制回复格式的工具,「引用透明化」写进 tool 层而不是靠人自觉
- **当前月份硬编码** —— 极其罕见地把动态时间信息塞进静态 prompt · 弥补 Claude 「不知道今天几月」的能力缺陷
- **对 MCP 谦逊让位** —— 工具生态里少见的「不覆盖认证内容 · 请找 MCP」姿态 · 每一次「no」都带一次「yes」
- **跨域重定向不自动跟** —— 把安全决策交给 Claude · 防跳转攻击 · 是显式协议不是静默魔法

这些信号在 4 层里各就各位,共同把「让 Claude 触达公网」这个能力,收敛成一个可控、可追溯、可让位的外部信息接口。
