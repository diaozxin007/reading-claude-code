Claude code tools 研究系列第五篇。前四篇拆完了「交互原语三件套」(Ask / EnterPlanMode / ExitPlanMode) 和搜索双人组 [Grep + Glob](grep-glob.md)。前者解决「AI 和用户怎么对齐」,后者解决「Claude 如何在项目里定位相关文件」。

拿到文件路径之后,Claude 需要**感知这个文件当前长什么样** —— 这就是 **Read**。它是执行原语链条里承上启下的一环:接住 Grep/Glob 定位到的坐标 · 为后面的 Edit / Write 建立起「感知承诺」的信任链。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Read

在所有 tool 里,Read 是**最基础也最容易被低估**的一个。它看起来只是「读一个文件」,但它承担着一个关键角色:**Claude 感知外部世界的唯一合规通道**。

没有 Read,Claude 只能靠训练时的记忆(过时)+ 用户在聊天里粘贴的片段(局部)+ 幻觉(危险)来构造对项目的理解。有了 Read,Claude 每一次改动才有真实的立足点。

### 作用

Read 是 Claude Code 内置的**文件内容读取工具**。它做的事很直白:给一个绝对路径,返回文件内容 —— 但它承担的职责远不止「读文件」这四个字:

1. **给 Claude 提供磁盘真实状态** —— 而不是让它靠训练记忆 / 用户粘贴 / 幻觉猜测
2. **前置 Edit 的必要条件** —— Read 建立了 harness 层的追踪状态,Edit 才能安全地改
3. **多模态感知统一入口** —— 文本 / 图片 / PDF / Jupyter notebook 都走同一个工具
4. **大文件安全读取** —— 分页机制(offset + limit)防止一次性把上下文吃满

### 一个具体例子

**场景**:用户说 **「`auth/middleware.ts` 里 token 校验的 bug 你帮我看看,应该在 verifyToken 那段」**。

Claude 直接调 Read:

- `file_path`: `/Users/xxx/project/src/auth/middleware.ts`(**绝对路径**)

**运行时返回**:

```
     1	import jwt from 'jsonwebtoken';
     2	
     3	export async function verifyToken(req, res, next) {
     4	  const token = req.headers.authorization;
     5	  if (!token) return res.status(401).send('unauthorized');
     6	  
     7	  try {
     8	    const decoded = jwt.verify(token, process.env.JWT_SECRET);
     9	    req.user = decoded;
    10	    next();
    11	  } catch (err) {
    12	    return res.status(401).send('invalid token');
    13	  }
    14	}
```

**每一行前面有行号 + tab 前缀** —— Claude 可以据此精确定位。看到第 4 行 `req.headers.authorization` 直接暴露了 bug:没剥离 `Bearer ` 前缀。

这段输出体现了 Read 的几个关键特性:

- **绝对路径 in · 磁盘真实内容 out** —— Claude 拿到的是**当前**磁盘状态,不是训练记忆、不是聊天历史、不是幻觉
- **行号前缀建立坐标系** —— 用户说「第 4 行的 bug」Claude 立刻能定位;Claude 说「第 8 行的 jwt.verify」用户也能立刻找到
- **默认 2000 行** —— 大文件不会一次性把上下文吃满

**其它形态的输入**:

- **大文件**(比如 5000 行):默认只读前 2000 行,可以指定 `offset: 2000, limit: 1000` 读第 2001~3000 行
- **截图 / 图片**:runtime 检测扩展名,**直接以视觉方式呈现**给 Claude(而不是返回文本),Claude 可以「看见」报错框、堆栈、字段值
- **PDF**:超过 10 页必须指定 `pages: "1-5"`,每次最多 20 页,防止大文档一次性爆掉上下文
- **Jupyter notebook**:返回所有 cell 的代码 + 输出 + Markdown,一起呈现

**核心价值**:Read 是 Claude 感知外部世界的**唯一合规通道** —— 把「猜测 / 记忆 / 幻觉」替换成「知道」。所有后续的 Edit / Write / Bash 都建立在这份感知承诺之上。

### 触发条件

工具官方说明写得很清楚:**「假设这个工具能读机器上任何文件」** —— Claude 不该纠结「这个文件我该不该读」,如果需要就直接读。

**该用 Read 的场景**:

- **改一个已知文件之前** —— Edit / Write 之前的必修课
- **理解项目结构** —— 读 `package.json` / `tsconfig.json` / `CLAUDE.md` 建立项目基线认知
- **用户 @filename** —— 用户消息里用 `@` 引用的文件,Claude 应该主动读
- **用户 linked_note** —— 系统上下文里出现的 `<linked_note>`,直接读
- **读图片 / PDF / notebook** —— 多模态感知的入口
- **wikilink 里的嵌入图片** —— 读文档时遇到 `![[image.png]]`,主动 Read 图片建立完整语境

**不该用 Read 的场景**:

- **刚刚 Edit 过的文件想「验证一下」** —— harness 追踪了状态,Edit 成功就说明改动生效了,重复 Read 是浪费
- **列目录内容** —— 用 Glob 或 bash `ls`,Read 不能读目录
- **搜文件里的关键词** —— 用 Grep,Read 是全读一段,不适合搜索
- **凭幻觉「验证」自己上一步的输出** —— 如果 Edit / Write 成功,Claude 不用回头怀疑自己

一个有意思的**反浪费原则**:官方专门写了一条 `Do NOT re-read a file you just edited to verify` —— 意思是 harness 帮你追踪了文件状态,Claude 不用像人类程序员那样反复确认。

### 技术实现

#### 1 · 命名

`Read`

命名极简 —— 一个动词概括所有职责。文件、图片、PDF、Jupyter notebook 全部走这一个动词,不叫 `ReadFile` / `LoadImage` / `ParsePDF`。**统一命名对应统一入口** —— Claude 不需要记多个工具名,选文件读什么由 runtime 根据扩展名分派。

字段名也是最直觉的一组:`file_path` / `offset` / `limit` / `pages`,任何写过分页 API 的人一眼看懂。

#### 2 · 工具级描述

Read 的描述围绕四件事:**能力宣告 / 分页触发 / 多模态提示 / 反浪费禁令**。

**全权限声明**

> Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid.

训练 Claude **不要质疑用户给的路径**,不要犹豫「这个文件我能读吗」。信任用户 + 信任工具,直接执行。消除了 Claude 的「过度谨慎」倾向。

**绝对路径硬约束**

> The file_path parameter must be an absolute path, not a relative path

关键词 **must be** —— 硬性。Claude Code 是一个跨会话、跨 CWD 的 agent,相对路径在不同上下文里会歧义:Claude 以为 CWD 是 `~/project`,实际是 `~/project/src`。强制绝对路径把 CWD 依赖去掉,**每次 Read 都是自解释的**。

**分页触发条件**

> When you already know which part of the file you need, only read that part. This can be important for larger files.

这条不是硬规则,是**优化建议** —— 提醒 Claude「你不需要每次都从头读」。训练 Claude 建立「按需读取」的直觉。

**多模态能力宣告**

> This tool allows Claude Code to read images (eg PNG, JPG, etc). When reading an image file the contents are presented visually as Claude Code is a multimodal LLM.

关键词 **presented visually** —— 明确告诉 Claude:图片不是被转成文本描述,而是**直接进入你的视觉理解**。这条 prompt 让 Claude 建立「Read 图片 = 我能看见」的直觉,而不是「Read 图片 = 我读了 alt 描述」。

**PDF 分页强制**

> For large PDFs (more than 10 pages), you MUST provide the pages parameter to read specific page ranges (e.g., pages: "1-5"). Reading a large PDF without the pages parameter will fail. Maximum 20 pages per request.

关键词 **MUST / will fail** —— 硬阻断。跟 Edit 的 Read 先行是同一种设计哲学:**不合规范的调用不允许,而不是允许后返回错误结果**。

**处理截图的社交指令**

> You will regularly be asked to read screenshots. If the user provides a path to a screenshot, ALWAYS use this tool to view the file at the path. This tool will work with all temporary file paths.

这条是**社交行为训练** —— 明确告诉 Claude「用户给你截图路径就直接读」。防止 Claude 出现「用户给我一个路径,我该不该读?」的犹豫。

**空文件的行为约定**

> If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.

这条 prompt 让 Claude 提前知道**空文件不会返回空字符串**,避免看到 reminder 时误以为「工具出错了」。这是**用体贴的错误消息代替 silent fail**的设计。

**反浪费(不要 verify)**

> Do NOT re-read a file you just edited to verify — Edit/Write would have errored if the change failed, and the harness tracks file state for you.

这条特别有意思 —— 它是在**扭转 Claude 的一个本能倾向**。Claude 训练时可能学到「改完代码要 verify」的编程直觉,但在 Claude Code 里 verify 是浪费,因为 harness 已经追踪了状态。这条 prompt 显式关掉了这个多余行为。

#### 3 · 字段级描述

Read 有 4 个字段:

- `file_path` —— 目标文件的**绝对路径**(不接受相对路径)
- `offset` —— 从第几行开始读(可选,默认 0)
- `limit` —— 最多读多少行(可选,默认 2000)
- `pages` —— PDF 的页码范围(如 `"1-5"`,只对 PDF 生效)

**几个关键设计点**:

**行号 + tab 前缀的双重角色**

Read 返回内容时,每行前面加 `行号 + tab + 实际内容` 的前缀。这个设计一石二鸟:

- **给 Claude 坐标系统** —— Claude 能说「第 42 行的 bug」,用户能定位
- **给 Edit 制造陷阱** —— 前缀不是文件真实内容,Edit 时必须剥离(见下一篇 Edit 的详细讨论)

行号前缀是「感知友好」和「操作陷阱」的**同一个东西**。这也是为什么 Edit 的 prompt 专门用一整段警告这个陷阱 —— **它是 Read 的必要输出,也是 Edit 的必要过滤**。

**分页机制:offset + limit**

为什么默认 2000 行?

- Claude 单次 context 有限,大文件全塞进去会挤爆
- 大多数场景下,只需要文件的某一段(比如某个函数)
- 强制 Claude 学会「按需读」而不是「全部读」

分页的存在也隐含了一个哲学:**Claude 不需要看完整个文件才能改一段代码** —— 就像人类程序员打开一个 5000 行文件,也是滚到 verifyToken 函数附近就够了。

**多模态统一入口**

Read 不是「只能读文本」的工具。图片 / PDF / notebook 都走同一个 tool call:

- **图片(PNG/JPG/GIF/WebP)** —— runtime 检测扩展名,把图片以视觉 token 塞给 Claude,而不是文本描述
- **PDF** —— runtime 提取文本(超过 10 页强制指定页码防爆),嵌入图像也保留
- **Jupyter notebook** —— cell 结构、代码、输出、Markdown 全部返回

**这是「统一感知层」的设计** —— Claude 不用为不同格式学不同工具,一律 Read。runtime 负责把多种格式规范化成 Claude 能吃的输入。

**与 Edit 的 harness 协作**

Read 的一个隐藏职责是**为 Edit 建立追踪状态**。Runtime 会记录:「本次会话里,Claude Read 过哪些文件」。当 Claude 调 Edit 时,runtime 检查这个记录 —— 没读过就报错。

这个协作让 Read 不只是「读文件」,而是**「感知承诺」** —— Claude 承诺「我知道这个文件当前长什么样」。这个承诺被 Edit 消费,构成整套「基于真实状态改代码」的信任链。

#### 4 · schema 校验规则

Read 的 schema 层几乎没有硬约束,除了一条:

| 字段 | 类型 | 约束 |
|---|---|---|
| `file_path` | string | 必填 · 必须绝对路径 |
| `offset` | integer | 可选 · 默认 0 |
| `limit` | integer | 可选 · 默认 2000 |
| `pages` | string | 可选 · PDF > 10 页时**必填** |

**默认值是 Read 的核心设计** —— 2000 行默认让 Claude 用默认值就落在"够用又不爆炸"的档位。PDF > 10 页强制 pages 是唯一的硬拦截,防止大文档一次性把 context 吃满。

---

### 与邻居工具的分工

Read 跟前四篇工具形成对照:

| 维度 | 三交互原语 | Grep + Glob | Read |
|---|---|---|---|
| 定位 | 协作对齐 | 定位坐标 | 感知外部 |
| 频率 | 关键节点 | 日常高频 | 日常高频 |
| 输入 | 结构化(Ask)/ 空(两个 PlanMode) | pattern(不需要知道路径) | file_path + 分页(需要知道路径) |
| 输出 | 用户决策 | 路径列表 / 匹配行 / 计数 | 完整文件内容 |
| 保守偏差 | 「不确定就规划」 | 「先按需搜再全读」 | 「不确定就读一读」 |

**Grep+Glob → Read 的信任链** —— 是搜索到感知的**顺畅衔接**:

- Grep/Glob 输出**坐标**(文件路径 + 可选行号),但只包含匹配行片段
- Read 消费这些坐标 —— 挑出真正需要深入的文件,拉取完整上下文
- Read 建立**感知承诺**,交给下一步的 Edit / Write 消费

**Read 与 Edit 的关系** —— 是 Claude Code 里最紧密的一对工具搭档:

- **感知承诺**:Read 是「我知道这个文件现在长什么样」的承诺
- **操作依据**:Edit 消费这个承诺,基于 Claude 记忆里的准确内容做精准替换
- **陷阱共享**:行号前缀是 Read 的必要输出,同时是 Edit 的必要过滤
- **状态机协作**:harness 层追踪 Read 状态 → Edit 时验证 → 缺失就报错

如果说 AskUserQuestion / EnterPlanMode / ExitPlanMode 是三个原语组成的**协作对齐流水线**,那 Grep+Glob → Read → Edit / Write 就是**执行环节的完整流水线** —— 定位、感知、执行,共享一套 harness 追踪状态,组合起来才构成「安全改代码」的完整闭环。

---

### 小结

Read 的精妙之处,不在于它「读文件」这个功能本身,而在于它的信号分布**全压在工具级描述和字段设计上**:

- **命名** —— 极简,一个动词覆盖多模态(文本 / 图片 / PDF / notebook)
- **工具级描述** —— 长,8 条约束串起「能力宣告 · 分页触发 · 多模态提示 · 反浪费禁令」
- **字段级描述** —— 4 字段但每个都有非平凡的设计(绝对路径 / 行号双角色 / 分页 / PDF pages)
- **schema 校验** —— 极简,只有"PDF > 10 页必须 pages"这一条硬拦截

Read 最独特的地方是它是**感知原语** —— 把「猜测 / 记忆 / 幻觉」替换成「知道」,并把这份「知道」以 harness 追踪状态的形式**承诺**给下游 Edit / Write。这份承诺是整个执行原语体系的**信任地基**。

下一篇继续拆 [Edit](edit.md) —— 看看 Read 建立的感知承诺,是怎么被 Edit 消费成一次次精准的字符串替换的。
