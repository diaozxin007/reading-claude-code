Claude code tools 研究系列第六篇。前五篇拆完了「交互原语三件套」(Ask / EnterPlanMode / ExitPlanMode) 和执行原语链条的前两环 —— 定位工具 [Grep + Glob](grep-glob.md) 和感知工具 [Read](read.md)。前者告诉 Claude 「相关文件在哪」,后者告诉 Claude 「文件现在长什么样」。

这一篇接着 Read 讲它的搭档 —— **Edit**。如果 Grep + Glob 是「找到坐标」、Read 是「知道文件长什么样」,那 Edit 就是「基于这份知道去精准改」。Read 和 Edit 共享同一套 harness 追踪状态,构成「安全改代码」的完整闭环。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Edit

如果说 Ask / EnterPlanMode / ExitPlanMode 是「协作时的礼仪」,那 Edit 就是「劳动时的匠气」 —— 每一次代码改动都要经过它。这个工具**日均调用量远超所有交互工具的总和**,但它的设计比交互工具更「刀刃向内」 —— 一条条约束都在防 AI 犯低级错误。

### 作用

Edit 是 Claude Code 内置的**精准字符串替换工具**。它做的事很简单:在一个已知文件里,把一段确切的文本(`old_string`)替换成另一段文本(`new_string`)。

它解决的核心问题是「AI 如何**安全、精准、可审阅**地改代码」:

1. **只改需要改的地方** —— 增量替换而不是整文件重写,破坏面最小
2. **强制基于真实文件** —— 必须先 Read 过才能 Edit,禁止凭幻觉修改
3. **唯一性保护** —— 目标文本在文件里必须唯一(除非显式声明批量),防止误伤
4. **可审阅的 diff** —— tool call 里就能看清改了什么,不用整文件比对

### 一个具体例子

**场景**:用户说 **「把 `handleClick` 这个函数名改成 `handleSubmit`,更符合它的实际语义」**。

假设有一个 `LoginForm.tsx` 文件,600 行,`handleClick` 在里面出现了 4 次:1 次函数定义、2 次 JSX 里的 `onClick={handleClick}`、1 次注释里的 "handleClick will..."。

#### 反例:如果没有 Edit(只有 Write)

Claude 只能用 Write 工具**整文件重写**,来完成这次重命名:

- 首先 Read 一遍这 600 行,拿到当前内容
- 在脑子里做 4 处替换
- 用 Write 把改后的 600 行整体写回文件

用户会遇到几个问题:

1. **Token 浪费严重** —— 600 行的内容在 tool call 里被完整传两次(Read 输入 + Write 输出),而实际改动只有 4 处
2. **破坏面失控** —— Write 会覆盖整个文件,如果 Claude 在传输过程中丢了个空格 / 换错了个引号 / 少复制一行,整个文件都被这个 bug 污染
3. **Diff 难审阅** —— 用户在 tool call log 里看到的是「整文件 600 行 → 整文件 600 行」,得跑一次 diff 才能看清 Claude 到底动了什么
4. **幻觉风险** —— 如果 Claude 记忆里的文件跟磁盘上的不一致(比如用户在中间刚编辑过),整文件重写等于**把 Claude 记忆里的版本覆盖到磁盘**,吞掉用户改动
5. **并发冲突** —— 用户在另一个编辑器里刚保存了一个改动,Claude 的整文件写入会把它盖掉,连提示都没有

**核心痛点**:整文件重写把「改一处」的成本放大到「改全部」,风险面从 4 处扩散到 600 行。

#### 用 Edit 是怎么解决的

Claude 会先 Read 拿到文件,然后调 Edit,传三个参数:

- `file_path`: `LoginForm.tsx` 的绝对路径
- `old_string`: `handleClick`
- `new_string`: `handleSubmit`
- `replace_all`: `true` (因为文件里出现了 4 次)

**运行时会发生什么**:

- Runtime 检查:这个文件在本次会话里被 Read 过吗?没有则直接报错
- Runtime 检查:如果 `replace_all=false`,`old_string` 在文件里出现的次数**必须是 1**;不是 1 就报错
- Runtime 执行替换:找到所有 `handleClick`,全部换成 `handleSubmit`
- Runtime 只把**diff 部分**写回文件,不动其它 596 行

用户在 tool call log 里看到的是:

```
Edit(file_path: LoginForm.tsx, old_string: "handleClick", new_string: "handleSubmit", replace_all: true)
→ 4 replacements
```

**一目了然、无副作用、无 token 浪费**。

#### 对照一下两种形式解决了反例里的哪些痛点

| 反例痛点 | Edit 的解法 |
|---|---|
| Token 浪费严重 | tool call 只传 diff 段,不传全文 |
| 破坏面失控 | 只在 `old_string` 匹配处替换,其它 596 行原封不动 |
| Diff 难审阅 | tool call 参数本身就是 diff,一眼看清 |
| 幻觉风险 | Read 前置强制:没读过就报错,不允许凭记忆改 |
| 并发冲突 | 只改 4 处 · 不覆盖整个文件 · 用户的其它编辑不受影响 |

### 触发条件

工具官方说明写得很硬:**「永远优先编辑已有文件 · 不要新建文件除非明确要求」**。这条原则背后是一个价值观:**减少不必要的产物 · 尽量在原地修改**。

**该用 Edit 的场景**:

- **改一段已知代码** —— 修 bug、重命名、调整逻辑
- **微调配置文件** —— 改一个字段值、加一行、删一行
- **修改文档** —— 更新 README 的某一段、修 typo
- **批量重命名** —— 一个变量在多处出现,用 `replace_all`

**不该用 Edit 的场景**(应该用 Write 或其它工具):

- **新建文件** —— Edit 不能创建文件,得用 Write
- **完全重写文件** —— 改动占文件 80% 以上,Edit 的 old_string 会很长很脆弱,不如 Write 一次性重写
- **需要 fuzzy 匹配** —— Edit 是精确字符串匹配,如果你想「找出所有 `console.log(...)` 无视括号里内容」,Edit 做不到,得写脚本

一个**很关键的思维模式**:**Edit 只处理你已经完全知道的字符串**。如果你不确定文件里那段代码长什么样,那你根本不该调 Edit —— 该先 Read 看清楚,或者用 Grep 找上下文。**Edit 不是「探索工具」 · 是「执行工具」**。

### 技术实现

#### 1 · 命名

`Edit`

一个动词概括所有职责。不叫 `Replace` / `Modify` / `Patch` —— 「Edit」是编辑器语义,Claude 拿到这个词第一反应就是"改现存文件的一段内容",不会想成"创建新文件"或"追加内容"。字段名 `file_path` / `old_string` / `new_string` / `replace_all` 也全是望文生义。

#### 2 · 工具级描述

Edit 的描述围绕四件事:**语义定位 / Read 先行 / 唯一性和补救 / 品味约束**。

**开篇一句,奠定基调**

> Performs exact string replacements in files.

"exact" 一词奠定整个工具的基调 —— 不是模糊,不是相似,不是差不多,是**逐字**替换。这一个词就把 Edit 从「AI 智能改代码」拉回「文本处理器」的定位。

**Read 先行的强制**

> You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.

关键词 **will error** —— 不是「建议」不是「最好」,是 runtime 层的硬阻断。这条 prompt 训练 Claude 建立一个反射:**想 Edit ? 先 Read。**

**行号前缀陷阱**

> When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: line number + tab. Everything after that is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.

这一整段专门警告一个具体陷阱。有意思的是官方把「Everything after that is the actual file content」显式说出来,可见团队被这个 bug 咬过很多次。这是**从血泪教训里长出来的 prompt**。

**偏好编辑而非新建**

> ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.

关键词 **ALWAYS / NEVER** —— 大写 + 极端量词。这不只是「建议」,是一种价值观声明:**Claude 应该像一个尊重现有代码结构的工程师,不轻易生产新文件**。

这也在防一类 AI 反模式:**幻觉性生产** —— AI 觉得「我应该建一个新工具类」而实际上项目里已经有一个够用的,结果堆出一堆散乱的新文件。

**emoji 禁令**

> Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.

一条乍看奇怪的约束,专门为 Edit 加。为什么?因为 AI(尤其早期训练模型)特别爱在评论 / 提交信息 / 文档里塞 emoji —— 但**大多数代码库不欢迎这种风格**。这条约束是「代码库品味」的显式表达,让 Claude 的输出更符合专业工程惯例。

**唯一性失败与 replace_all**

> The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.

给出**两种补救路径**:扩上下文 / 用 replace_all。这一条特别贴心 —— 不只是说「会失败」,还告诉 Claude 失败后**怎么办**。这是好 prompt 的标志:错误路径也要设计。

**replace_all 的正当用法**

> Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.

明确 `replace_all` 是**为「变量重命名」这类场景设计的**。给一个具体使用场景比笼统说「设置为 true 会全部替换」有用得多 —— Claude 读到这条会立刻在脑海里建立映射:「哦,重命名要用这个 flag」。

#### 3 · 字段级描述

Edit 有 4 个字段:

- `file_path` —— 目标文件的**绝对路径**(不接受相对路径)
- `old_string` —— 要被替换的确切文本
- `new_string` —— 替换后的文本(必须跟 `old_string` 不同)
- `replace_all` —— 布尔值,默认 `false`;设为 `true` 时替换所有匹配

字段少,但每个背后都有非平凡的设计:

**精确字符串匹配 · 不是 AST / LSP / fuzzy diff**

Claude Code 团队选了**最原始也最鲁棒**的方案 —— 纯字符串匹配。原因:

- **语言无关** —— 不用为每种语言维护 parser,Python / Rust / YAML / Markdown 通吃
- **实现简单** —— 不用引入 tree-sitter / LSP 依赖
- **失败明确** —— 匹配不上就报错,不会「大概匹配到差不多的地方」
- **Claude 可控** —— Claude 输出什么字符串就替换什么,不会被 AST normalizer 悄悄改写

代价是:Claude 必须**逐字**提供 `old_string`,包括空格、缩进、换行。这是把「解析文件的复杂度」外包给 Claude 自己 —— 而 Claude 天然擅长处理精确字符串。

**Read 先行的 harness 约束**

如果没在本次会话里 Read 过某个文件,直接 Edit 会报错。为什么?防幻觉。

Claude 可能「记得」自己上次改过某个文件长什么样,但**上次是上次** —— 磁盘上现在的文件可能已经被用户 / 其它 agent / 其它工具改过。强制 Read 前置的本质是:**每次 Edit 都基于当前磁盘状态,而不是 Claude 记忆里的版本**。

这条约束不是靠自律,是靠 runtime 追踪:「这个 file_path 有没有出现在本次会话的 Read tool 调用里?」没有就拒绝。

**唯一性检查的价值**

如果 `replace_all=false`(默认),Edit 会要求 `old_string` 在文件里出现**恰好一次**。这个约束防止一类隐蔽 bug:

- Claude 想改函数 A 里的 `return null`,但文件里另一个函数 B 也有 `return null`
- Edit 找到第一个匹配就替换,可能改错函数

强制唯一性把这个歧义暴露成**编辑失败**,让 Claude 必须提供**足够多的上下文**来消除歧义 —— 比如 `old_string` 包含函数签名、周围几行,让它变得独一无二。

**replace_all 是重命名场景的一等公民**

同一个工具里既能改一处也能改全部,靠一个 flag 切换:

- 改一个变量名,一次调用就搞定
- 不需要循环调用 Edit 一次一次替换
- 不需要写正则表达式(容易翻车)

**line number prefix 陷阱**

Read 工具输出内容时会加行号前缀(格式:数字 + tab + 实际内容)。Edit 官方说明专门警告:**old_string 里千万不要包含行号前缀** —— 那是 Read 加上去的展示格式,不是文件真实内容。

这个陷阱很微妙,新手最容易踩:

```
Read 输出: 42	  const x = 1;
```

Claude 可能想直接把 `42	  const x = 1;` 塞到 old_string 里 —— 错了,磁盘上根本没有 `42	` 这几个字符。正确做法是取 tab 之后的部分:`  const x = 1;`。

行号前缀是 Read 的**必要输出**(让 Claude 有坐标系统),同时是 Edit 的**必要过滤**。这个"同一个东西承担两种矛盾角色"的现象,是 Read 和 Edit 深度耦合的根源。

#### 4 · schema 校验规则

Edit 的 schema 极简:

| 字段 | 类型 | 约束 |
|---|---|---|
| `file_path` | string | 必填 · 必须绝对路径 |
| `old_string` | string | 必填 · 默认唯一性检查 |
| `new_string` | string | 必填 · 必须 ≠ old_string |
| `replace_all` | boolean | 可选 · 默认 false |

关键的**硬拦截不在 schema 里**,而在 harness 层:

1. **Read 前置** —— 未 Read 直接报错
2. **唯一性** —— old_string 匹配 > 1 处直接报错(除非 replace_all=true)
3. **匹配失败** —— old_string 找不到直接报错
4. **无操作检测** —— old_string == new_string 直接报错

这些校验都是**loud fail**:Claude 收到明确的错误消息,能立刻修正;不会静默降级(比如「模糊匹配到差不多的地方」),避免 bug 在下游积累。

这也解释了为什么 Edit 的 schema 层这么简单 —— **真正的约束都在 runtime 状态机里**,不在参数结构里。

---

### 与邻居工具的分工

Edit 跟前五篇工具形成对照:

| 维度 | 三交互原语 | Grep + Glob | Read | Edit |
|---|---|---|---|---|
| 定位 | 协作对齐 | 定位坐标 | 感知外部 | 精准执行 |
| 频率 | 关键节点 | 日常高频 | 日常高频 | 日常高频 |
| 参数 | 结构化(Ask)/ 空(两个 PlanMode) | pattern(不需要知路径) | file_path + 分页 | 4 字段(含 old_string) |
| 语义 | 意图信号 | 定位坐标 | 感知承诺 | 数据操作 |
| 失败模式 | 用户驳回 | 匹配为空 / head_limit 截断 | 文件不存在 / PDF 超页未指定 | 匹配失败 / 唯一性冲突 / 未 Read |
| 保守偏差 | 「不确定就规划」 | 「先按需搜再全读」 | 「不确定就读一读」 | 「不确定就 Read」 |

**Edit 与前两环的深度耦合**在这张表里最明显 —— Edit 的一半保守偏差(「不确定就 Read」)是**外包给 Read 的**;而 Read 又依赖 Grep+Glob 提供的坐标。三环通过 harness 追踪状态形成信任链:

- Grep / Glob 定位:「哪些文件与这个任务相关」
- Read 建立「感知承诺」:「我知道这个文件现在长什么样」
- Edit 消费承诺:基于 Claude 记忆里的准确内容做精准替换
- 陷阱共享:行号前缀是 Read 的必要输出,是 Edit 的必要过滤
- 状态机协作:harness 追踪 Read 状态 → Edit 时验证 → 缺失就报错

---

### 小结

Edit 的精妙之处,不在于它「让 AI 改代码」这个功能本身,而在于它的信号分布**极度偏向 runtime 状态机**:

- **命名** —— 极简,一个动词
- **工具级描述** —— 长,7 段约束覆盖语义定位 / Read 先行 / 唯一性和补救 / 品味
- **字段级描述** —— 4 字段,每个背后都是非平凡决策(纯字符串 / harness Read 状态 / 唯一性 / replace_all / 行号陷阱)
- **schema 校验** —— 极简,真正的硬拦截全在 runtime 层(Read 状态 / 唯一性 / 匹配失败 / 空操作)

Edit 独特的地方在于它**把「安全改代码」的重心从参数校验转移到了状态机**:Edit 本身几乎没有 schema 约束,但通过和 Read 共享 harness 追踪状态,构造了一个"每次编辑都基于当前磁盘真实内容"的强保证。相当于把「AI 精准改代码」这个泛用能力,收敛成一个**语言无关、防幻觉、可审阅、支持批量**的执行原语。

下一篇继续拆 [Write](write.md) —— Edit 的兄弟工具 · 处理 Edit 干不了的两类事:**新建文件 · 完全重写**。看看 Write 如何在「必需性」和「危险性」之间找平衡。
