> 本系列第 03 篇 · 承接 [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) 立的主线 —— prompt cache 是 Claude Code 一切设计的底座。 开篇讲了 cache 的**三条铁律**(前缀匹配 / 一 byte 变即断裂 / 断点决定 cache 起点)和推出来的**三条设计原则**(稳的往前 / 变的往后 / 断点隔离稳定性)。
>
> 这一篇讲 Claude Code 具体怎么把这三条原则**落地成一整套机制** —— 4 个 cache 断点具体挂哪里、静态和动态段怎么分、6 个反直觉设计怎么串起来。
>
> 本篇聚焦**原理与设计** · 不下沉到代码层。 想看具体函数名和行号的 · 见文末参考段。

## TL;DR

| 维度 | 一句话 |
|---|---|
| **Claude Code 的 4 断点分配** | 按稳定性从高到低:tools 尾 → system 静态段 → system 组织段 → messages 尾 |
| **静态/动态段的显式分界** | 用一个 sentinel 字符串 `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` 划分 · 不靠启发式 |
| **上层设计的形态被 cache 反塑** | 变的东西一律往后放 · 稳定的东西死守不动 · 中间用 sentinel 分界 |
| **6 个反直觉设计** | CLAUDE.md 走 SR 而不进 system · Skill 用 delta · fork 用 placeholder · 环境信息故意 stale · 每天日期用 SR 单发 · MCP delta 注入 |
| **共同心法** | Cache 静态 ≠ 语义静态 · 追求 cache 静态而非语义静态 |
| **底座的边界** | 只对"多轮同用户"场景有意义 · session 短 / 每轮换用户 / 前缀天然不稳的场景 · 底座不成立 |

## 1 · Claude Code 的 4 断点分配

前面说了 · Anthropic API 允许最多 4 个断点。 Claude Code 把这 4 个断点分给了 4 个**不同稳定性等级**的位置。

### 稳定性金字塔

```
                    ┌──────────────────────┐
最稳定  ▲  跨 session │ tools 段             │ 一整个版本几乎不变
       │             ├──────────────────────┤
       │  跨 session │ system 静态段         │ 主 prompt · SR 教学 · env 信息
       │             ├──────────────────────┤
       │  同 session │ system 组织段         │ 允许的工具集 · skill 命令表
       │             ├──────────────────────┤
       │  同 session │  ⋯⋯⋯ 动态段 ⋯⋯⋯      │ 语言 · MCP instructions
       │             ├──────────────────────┤
       │  每轮追加   │ messages 段           │ 用户消息 · tool_result
最变化 ▼
                    └──────────────────────┘
```

Claude Code 把 4 个断点如下分配:

| 断点 | 位置 | 保住什么 | 稳定性 |
|---|---|---|---|
| **① tools 尾** | tools 段末尾 | 全部工具 schema(~20-30 KB) | 最稳:一整个版本内不变 |
| **② system 静态段末** | 主 prompt / 工具说明 / SR 教学 / env 信息 之后 | 主 system prompt(~10-15 KB) | 稳:同 session 内不变 |
| **③ system 组织段末** | 允许的工具集 / skill 命令表 之后 | 组织级配置(~3-5 KB) | 中:偶尔变 |
| **④ messages 末** | 最新一条消息末尾 | 全部对话历史 | 每轮追加 |

**为什么这么分**:每个断点覆盖一个稳定性等级。任何位置的变化 · 只会 bust 从**这个变化位置开始的所有断点** —— 不会带累前面更稳定的断点。

举例:
- 用户发新消息 → 只影响 ④ 断点的 cache 匹配 · ①②③ 全命中
- MCP instructions 变化(在动态段) → 只影响 ④ · ①②③ 全命中
- 组织配置改了(极少发生) → 影响 ③④ · ①② 全命中
- Claude Code 版本升级 tools schema → 影响 ①②③④ · 全 bust · 但这是几周才发生一次的事

**这就是稳定性分层的价值** —— 让高频变化只花高频代价 · 低频变化才付低频代价。

## 2 · 静态段和动态段的分界:一个字符串

Claude Code 的 system prompt 从内容上看是一整段 —— 但从 cache 视角是**两段拼接**:

```
静态段(挂 cache_control)
    +
[分界字符串 __SYSTEM_PROMPT_DYNAMIC_BOUNDARY__]
    +
动态段(不挂 cache_control)
```

**分界的用途**:静态段的内容一 session 内不变 · 挂断点让它进 cache;动态段每轮可能变(比如 MCP 状态) · 挂了反而是坑 —— 挂上去每次都失效 · 每次都要重写 · 白白付 write 成本。

**分界的实现**:一个 sentinel 字符串常量 —— 前后两段代码分别 build · 中间拼一个绝不会出现在正常内容里的分界串。到序列化前统一 split 开 · 前一半挂 `cache_control` · 后一半不挂。

**这个设计的核心思想**:**cache 边界必须是显式的** —— 不能靠 heuristic(比如 "前面几行是静态的")· 因为一次误判就 bust 全 cache。用一个 sentinel 明确划线 · 谁进静态段谁进动态段是编码时决定的 · 运行时 0 判断。

**代价**:多一层拼接逻辑 · 分界串必须绝无冲突。收益:cache 命中率的确定性。

## 3 · 反直觉设计的 6 个案例

有了铁律和分配 · 现在看**具体的、反直觉的**设计。每个案例都是同一模式:直觉这样 → 但 cache 视角这样做会 bust → 所以实际长成这样。

### 案例 1 · CLAUDE.md 不进 system prompt

**直觉**:CLAUDE.md 是 "给 agent 的静态指令" —— 项目规则 · 编码风格 · 团队约定 —— 明显应该进 system prompt。

**cache 视角**:CLAUDE.md 内容**会变**:
- 用户改了自己的 CLAUDE.md
- 切换项目 · CLAUDE.md 内容完全变了
- @import 展开了新的引用文件
- session 中间 CLAUDE.md 被修改(热重载)

如果 CLAUDE.md 进 system 静态段:一变 → 断点 ② 被打穿 → tools 段之后的所有 cache 全 bust。

**实际做法**:CLAUDE.md **不进 system prompt** · 走 **messages 段**的 user message prepend 位置 · 用 `<system-reminder>` 包起来。

**这样的好处**:
- CLAUDE.md 变化只影响 ④ 断点(messages 段)的匹配 —— 而 messages 段本来就是每轮变的 · 变化在预期内
- ①②③ 断点完全不受影响 —— tools + system 段的大 cache 保住

**一次"用较小 cache 换较大 cache"的等价交换**。用户看到的"CLAUDE.md 生效"的感觉不变 · 但账单上省了大头。

### 案例 2 · Skill listing 用增量 · 不全量重发

**直觉**:每次对话都把所有可用 skill 列一遍 · Claude 就知道有哪些 skill 可用了 —— 全量最简单。

**cache 视角**:全量 skill listing 是一段 5-20 KB 的表格。如果每轮都发:
- 每轮 messages 段前缀不同(因为前一轮的 listing 变成了历史)
- 断点 ④ 匹配失败 · 全部历史消息都要重新计算
- 每轮多花几千到上万 token 的写成本

**实际做法**:维护一个 "已发送过的 skill 名字集合" —— 每次只发**新增**的 skill(delta)。

**更绝的一处**:`/compact` 之后 · 这个集合**不清空** —— 意思是 compact 之后不重发 skill listing。直觉上 compact 后不是应该 "重挂全部上下文" 吗?但源码里明确注释:

> post-compact 的 skill listing 是纯 cache_creation(~4K token) · 不重发反而保 cache。

这里体现了**极致的 cache 优先**:模型脑子里对 skill 列表的记忆虽然会稍微淡一点 · 但保住 4K token 的 cache 更划算 —— 一个 session 内成本累计能少几十倍。

### 案例 3 · fork 出来的子代理都用同一句 placeholder

**直觉**:fork 是让子代理接着父的工作 —— 应该带上父的所有历史 · 包括每次 tool 调用的结果。

**cache 视角**:如果一场对话里 fork 出很多子代理(比如批量处理 100 个 URL) · 每个子代理都带着不同的 tool_result · 那么:
- 每个子代理的**历史前缀都不同**(因为 tool_result 各不相同)
- 每个子代理都是全新的 cache 前缀 → 全 miss
- 100 个 fork · 100 次 cache 完整写入 · 成本爆炸

**实际做法**:所有 fork 的历史里 · **每一个 tool_result 都被替换成同一句固定字符串** —— `"Fork started — processing in background"`。

**这样的效果**:
- 所有 fork 的历史前缀**字节完全相同**
- 第一个 fork 建立 cache · 后续 99 个 fork 全命中
- 每个 fork 只有最后的 "给子代理的具体指令" 那几百字是变化的

**这是 prompt cache 工程的极致案例** —— 用一个 placeholder 换来了 100 倍场景下的 cache 命中率。代价是子代理看不到父的具体 tool_result —— 但子代理需要的是 "上下文任务" · 不是 "上下文历史" · 通过父传给的指令直接说明即可。

### 案例 4 · 环境信息故意 stale

**观察**:执行 `cd /new/dir` 后 · Claude 看到的 cwd 还是老的。

**直觉判断**:这是 bug。

**cache 视角**:`<env>` block(包含 cwd / git 状态 / 平台 / 模型信息)挂在 system 静态段。如果 cd 之后 cwd 更新:
- 断点 ② 处的 cache 被打穿
- tools 段之后所有 cache 全 bust
- 每次 cd 就是几万 token 的 write 成本

**实际做法**:`<env>` 一次 session 计算一次 · memoize · 后续 cd 不刷新。

**这是**故意的** —— Claude Code 团队做了取舍**:

- 真正需要 cwd 的地方(Bash · Read · Write · Edit)走独立的 `getCwd()` —— 从进程状态读 · 永远准确
- 系统 prompt 里的 cwd 只用于 "让 Claude 大致知道自己在哪个项目" —— 有点 stale 没关系
- 换来的是每次 cd 不 bust cache · 单次 cd 省掉几万 token 的 write 成本

**这是原理层的取舍训练**:如果一个信息 "有点 stale 也不影响正确性" · 就死守 cache;如果 "必须实时" · 就走另一条路径不进 cache。

### 案例 5 · 每日日期用系统提醒单发

**直觉**:今天日期直接写在 system prompt 里 —— "Today is 2026-07-30" —— 最简单。

**cache 视角**:如果日期写在 system prompt 里 · 每天凌晨零点 · 全球所有 Claude Code session 的 system 段 cache 全体失效 —— 单个 API 请求成本瞬间翻数倍。

**实际做法**:日期**不进 system prompt** · 而是通过一个 "日期变了" 的 `<system-reminder>` 单独 append 到 messages 段:

> The date has changed. Today's date is now 2026-07-30.

**效果**:
- system 段保持稳定 —— 断点 ②③ cache 保住
- 跨零点只影响 messages 段的一小段 —— 断点 ④ 变化很小
- 全球所有用户跨零点没有 cache 雪崩

**这个设计的教训**:**任何跟"时间"绑定的信息都不能进 cache 段** —— 时间不断变 · 就是 cache 的天敌。

### 案例 6 · MCP instructions 用增量注入

**背景**:MCP(Model Context Protocol)server 有自己的 instructions —— 告诉 agent "怎么用我"。它是给 agent 的静态说明。

**直觉**:一次连上 MCP · 把 instructions 拼进 system prompt · 完事。

**cache 视角**:MCP server 连接**是异步的**:
- 有的 server 1 秒内连上
- 有的要几秒
- 有的中途断线重连
- 用户可能在 session 中加装新的 MCP

如果 instructions 进 system prompt:
- 每次 MCP 状态变化 → system 段变 → 大 cache bust
- 一个 session 里 MCP 连断 5 次 · 就是 5 次大 cache 全重建

**实际做法**:MCP instructions 用增量注入 —— 只在 MCP **新连接**时 · 把这一批新连接的 instructions 通过 `<system-reminder>` append 到 messages 段。

**效果**:
- system 段稳定
- MCP 动态变化只影响 messages 段的一小段
- 支持 MCP 异步连接而不付出 cache 代价

## 4 · 6 个案例的共同模式

上面 6 个案例读下来 · 你会发现它们都是同一模式:

```
① 直觉:这个东西应该进 system 段 · 因为它 "语义上是静态的"
② 但它实际上不稳定(会变 · 会异步连上 · 跟时间绑 · 跟用户绑)
③ 若进 system 段 · 一变就 bust 大 cache
④ 所以实际做法:换个路径 · 走 messages 段的 SR 通道 · 或者故意不刷新 · 或者用 placeholder 抹平差异
```

**核心思想是**:**Cache 视角下的 "静态"** ≠ **语义视角下的 "静态"**。

- 语义静态:CLAUDE.md 是给 agent 的固定指令 · 是静态的
- Cache 静态:内容一 byte 不变 · 才是静态的

Claude Code 的每一个"看似奇怪"的设计,都是**顺着 cache 静态而非语义静态在做取舍**。

这个心法就是 [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) 里说的 "为什么其他机制长成那样" 的答案 —— 后 4 篇讲的每一条具体机制,追问到底,都会追到这个心法。

## 5 · 底座的适用边界

Prompt cache 底座**不是普适真理** —— 它只在特定条件下成立。列一下这个底座**失效**的场景:

| 场景 | 为什么底座失效 |
|---|---|
| **每次请求换用户** | Anthropic cache 是按 user 隔离的 · 换用户直接 miss |
| **session 只有 1-2 轮** | Cache write 成本 1.25 倍 · 只发一次或两次的场景 · 写成本还没回本 |
| **前缀天然不稳定** | 比如每轮请求都需要塞新的知识库搜索结果 · 前缀就是每次都变 |
| **对成本不敏感** | 有的场景延迟是主要约束 · 不是成本 |
| **用别家 API(比如 OpenAI · Gemini)** | 各家的 cache 机制不一样 · 具体设计要重新推 |

## 6 · 本篇小结

- **Cache 有三条铁律**:前缀匹配 · 一 byte 变即断裂 · 断点决定 cache 起点
- **三条铁律推出三条设计原则**:稳的往前 · 变的往后 · 用断点分隔稳定性等级
- **Claude Code 用满 4 断点**:tools 尾 → system 静态 → system 组织 → messages 尾 · 4 层稳定性
- **静态/动态段用显式 sentinel 分界** · 而非启发式判断
- **6 个反直觉案例的共同心法**:cache 静态 ≠ 语义静态 · 追求 cache 静态而非语义静态
- **底座有适用边界** · 短 session / 换用户 / 前缀天然不稳的场景不成立

一句话:**Claude Code 不是先设计功能再考虑 cache · 而是先看清 cache 约束再倒着推每一处功能**。

下一篇 02 · Compaction 六兄弟:即使"压缩历史"这种看似跟 cache 无关的机制 · 它的具体触发条件 / 保留策略 / 挂回预算 · 也都追溯到 cache 视角。

---

## 参考

**Anthropic 官方**:
- [Prompt caching · Anthropic docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) · 底层机制
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · 4 大策略框架
- Thariq Shihipar(Anthropic)quote via [Simon Willison](https://simonwillison.net/tags/claude-code/)(2026-02-20)

**Claude Code 源码定位**(v2.1.220):
- tools 断点位置:`src/utils/api.ts` · `toolToAPISchema`
- system prompt 分段:`src/utils/api.ts` · `splitSysPromptPrefix`
- CLAUDE.md 注入:`src/utils/api.ts` · `prependUserContext`
- 断点分配:`src/services/api/claude.ts` · `addCacheBreakpoints`
- 1h TTL 灰度:`src/services/api/claude.ts` · `should1hCacheTTL`
- Cache 失效检测:`src/services/api/promptCacheBreakDetection.ts`
- 分界串定义:`src/constants/prompts.ts` · `SYSTEM_PROMPT_DYNAMIC_BOUNDARY`
- Fork placeholder:`src/tools/AgentTool/forkSubagent.ts` · `FORK_PLACEHOLDER_RESULT`
- Skill listing 增量:`src/utils/attachments.ts` · `sentSkillNames`
- MCP delta:`src/utils/attachments.ts`
- Date change SR:`src/utils/messages.ts`

**Vault 内相关笔记**:
- [00 · 开篇 · Claude Code 的 200K 账本](00-intro.md) · 4 策略 × 20+ 机制总账
- 深度学习_System_Prompt · Prompt cache API 层通用原理(TTL 阈值 / 读写成本 / chat template 等 · 与本篇互补)
