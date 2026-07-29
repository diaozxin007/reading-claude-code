Claude code tools 研究系列第七篇。前六篇拆完了「交互原语三件套」(Ask / EnterPlanMode / ExitPlanMode)、搜索双人组 [Grep + Glob](grep-glob.md),以及感知 + 精准执行的搭档 [Read](read.md) / [Edit](edit.md)。这一篇聊 Edit 的兄弟工具 —— **Write**。

Grep + Glob + Read + Edit 组合起来,能应对「先定位、后读、再精准修改」的绝大多数场景。但有两类事 Edit 干不了:**新建文件 · 完全重写文件**。这两类事只能靠 Write。

Write 看似简单(就是「把内容写到文件里」),但它的设计有一个特别的张力 —— **它既是必需的(唯一能创建新文件的工具),又是危险的(能覆盖任何已有文件)**。整套 Write 的 prompt 都在处理这个张力。

> 本系列先读 [前置篇](../tool-mechanism.md) —— 讲清楚 tool 是什么、Claude 怎么用。本篇按前置篇提出的 4 层骨架展开。

## Write

### 作用

Write 是 Claude Code 内置的**文件全量写入工具**。它做的事很直白:给一个绝对路径 + 一段文本内容,把内容写到那个文件里。如果文件已存在,**整个覆盖**;如果不存在,**新建**。

它解决的核心问题是「AI 如何**安全、显式**地生产新文件 · 或者做完全重写」:

1. **唯一能创建新文件的执行工具** —— Edit 不能新建,Bash 可以但不受审阅
2. **完全重写的最经济路径** —— 改动占文件 80% 以上时,Write 比一堆 Edit 高效
3. **强制基于真实状态覆盖** —— 已存在的文件必须先 Read 过才能 Write,防幻觉覆盖
4. **可审阅的完整产物** —— tool call 里就是即将写入磁盘的全文,一目了然

### 一个具体例子

**场景**:用户说 **「给我加个 `UserBadge` 组件,展示用户头像 + 名字 + 状态灯,放到 `src/components/UserBadge.tsx`」**。

这是一个**从零创建新文件**的典型场景。项目里没有 UserBadge,Claude 探索完项目风格后,准备把新文件写出来。

#### Write 是怎么解决的

Claude 直接调 Write,传两个参数:

- `file_path`: `/Users/xxx/project/src/components/UserBadge.tsx`(绝对路径)
- `content`: 完整的组件代码(几十行)

**运行时会发生什么**:

- Runtime 检查:目标路径的父目录存在吗?不存在则报错
- Runtime 检查:如果文件已存在,本次会话里 Read 过吗?没有则报错(**跟 Edit 是同一套 harness 追踪机制**)
- Runtime 执行写入:把 `content` 完整落到磁盘
- 如果是新建,顺便创建文件;如果覆盖,替换整个内容

用户在 tool call log 里看到的是:

```
Write(file_path: src/components/UserBadge.tsx, content: [full 40-line component])
→ File created
```

**一次到位、无副作用**。

#### 反例:如果拿 Write 干 Edit 该干的事

接续上一篇 Edit 的场景 —— 用户说「把 `handleClick` 重命名成 `handleSubmit`」。这个文件已经存在,600 行,只需要改 4 处。

**如果 Claude 硬用 Write 而不是 Edit**:

- 先 Read 拿到 600 行完整内容
- 在脑子里做 4 处替换
- 用 Write 把改后的 600 行整体写回

这时会遇到几个问题:

1. **Token 浪费严重** —— 600 行内容在 tool call 里被完整传输一次(Write 的 content 参数),而实际改动只有 4 处
2. **破坏面失控** —— Write 会覆盖整个文件,如果 Claude 在传输过程中丢了个空格 / 换错了个引号 / 少复制一行,整个文件都被这个 bug 污染
3. **Diff 难审阅** —— 用户在 tool call log 里看到 600 行 content,得跟旧版本跑一次 diff 才能看清 Claude 到底动了什么
4. **并发冲突放大** —— 如果用户在另一个编辑器里刚保存了别的改动,Write 会把它整个盖掉,连提示都没有
5. **误覆盖风险** —— Write 是「整个替换」,没有 Edit 那种「old_string 必须匹配」的安全网,写错内容也不会报错

**核心洞察**:**Write 和 Edit 不是替代关系 · 是分工关系**。Write 干新建 / 完全重写,Edit 干增量修改。混着用会失去每个工具的独特安全保障。

#### 什么时候该 Write 什么时候该 Edit

| 场景 | 选 Write | 选 Edit |
|---|---|---|
| 从零创建新文件 | ✅ 唯一选择 | ❌ 不能创建 |
| 改动占文件 80%+ | ✅ 全量重写更经济 | ⚠️ old_string 会很长很脆弱 |
| 改动占文件 20%- | ⚠️ token 浪费 · 风险面大 | ✅ 精准替换 |
| 重命名变量 / 函数 | ❌ 不推荐 | ✅ 用 replace_all |
| 修 typo | ❌ 大炮打蚊子 | ✅ 一次替换搞定 |
| 生成配置文件 / boilerplate | ✅ 一次写完 | ❌ 空文件 Edit 不了 |

一个粗略的**思维模型**:如果你的 `new_string / new_content` 里大部分内容是**从旧文件复制过来的**,那就用 Edit;如果**大部分内容是新写的**,那就用 Write。

### 触发条件

工具官方说明写得非常克制:**「优先编辑已有文件 · 除非明确需要,否则不新建」**。这是 Write 与 Edit 的默认竞争关系的**显式仲裁**。

**该用 Write 的场景**:

- **用户明确要求新建文件** —— 「给我加个 xxx 组件」/「生成一份 xxx 配置」
- **代码需要新模块** —— 拆分现有代码时创建新文件
- **完全重写** —— 改动占比 80%+,Edit 的 old_string 会过长,反而增加脆弱性
- **生成 boilerplate** —— 脚手架、测试模板、迁移文件

**不该用 Write 的场景**:

- **微调现有文件** —— 用 Edit,精准替换是它的强项
- **写文档 / README 除非用户明确要** —— 官方硬约束,见下方 2 · 工具级描述
- **加 emoji 除非用户明确要** —— 官方硬约束,见下方 2 · 工具级描述
- **凭幻觉「验证」** —— 跟 Read 那篇提到的反浪费原则一样,Write 完不用回头 Read 验证

一个有意思的**反自动生产原则**:官方 prompt 里写了 `NEVER create documentation files (*.md) or README files unless explicitly requested by the User` —— 大写 NEVER。这条约束背后是**血泪教训**:早期 AI 工具经常「贴心地」自动生成一堆 README / CHANGELOG / API.md,项目主一看满地都是没请示过就冒出来的 markdown,又不好删,只好留着。**Write 的这条约束在把这个反模式钉死**。

### 技术实现

#### 1 · 命名

`Write`

命名极其直白 —— 一个动词,英语里最基本的「写」。跟 `Edit`(编辑) 、`Read`(读)构成同族三兄弟,望文生义:

- **Read** —— 读 · 感知外部
- **Edit** —— 编辑 · 增量修改
- **Write** —— 写 · 全量落盘 / 新建

三个动词都指向「文件」这个操作对象,但语义边界清晰:Read 只输入不输出;Edit 是「已有内容 → 改一部分」;Write 是「有没有都行 → 整个覆盖 / 新建」。**动词的粒度直接编码了危险度** —— Write 是三者里最重的动作,名字本身就在提示这一点。

字段名同样朴素:`file_path` + `content`。没有 old_string / new_string / replace_all 之类的「匹配」概念,因为 Write 根本不做匹配 —— 语义就是「把这段内容盖到磁盘上」。字段少反而是一种坦率:**Write 没有安全网,也不假装有**。

#### 2 · 工具级描述

Write 的工具级描述短小精悍,几条约束逐条拆:

**约束 1:覆盖行为的透明化**

> This tool will overwrite the existing file if there is one at the provided path.

关键词 **will overwrite** —— 没有「小心 / 请注意」的软化,直接说清楚。这条描述让 Claude 完全清楚 Write 的破坏性 —— 不会有「我以为它会 merge」的错觉。

**约束 2:Read 先行的强制**

> If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.

关键词 **MUST / will fail** —— 硬阻断。跟 Edit 是完全一样的约束。这条描述让 Read → Edit / Write 的信任链在 Claude 的直觉里建立起来:Runtime 记录本次会话里 Read 过哪些文件,Write 到已存在文件时验证。目的:

- **防幻觉覆盖** —— Claude 可能「记得」文件长什么样,但磁盘上的可能已经被改过
- **强制感知承诺** —— 「你要覆盖这个文件?先证明你知道现在里面是什么」
- **与 Edit 共享信任链** —— Read → Edit 和 Read → Write 走同一套状态机

新建文件不需要 Read 先行(因为文件还不存在),但一旦文件已存在,就必须走 Read。**这是「Write 的双面性」在 harness 层的体现**。

**约束 3:偏好 Edit 而非 Write**

> Prefer the Edit tool for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.

关键词 **Prefer / Only** —— 一个鼓励一个限制,把 Write 的合理适用面**收窄到两种**:

- 新建文件
- 完全重写

这条约束是 Write 与 Edit 分工的**权威仲裁**。避免 Claude 因为「Write 语义更简单」就滥用它。

**约束 4:不主动创建文档**

> NEVER create documentation files (*.md) or README files unless explicitly requested by the User.

关键词 **NEVER / unless explicitly requested** —— 大写 + 极端量词。这条特别贴近**用户体验**:防止 Claude 自作聪明生产一堆没人要的 markdown。背后是**血泪教训**:早期 AI 工具经常「贴心地」自动生成一堆 README / CHANGELOG / API.md,项目主一看满地都是没请示过就冒出来的 markdown,又不好删,只好留着。

有意思的是这条约束**只针对 Write**(Edit 里也有类似原则,但没这么极端)—— 因为 Write 是「新建文件」的入口,新建 md 文件比编辑现有 md 文件更容易造成噪音污染。

**约束 5:emoji 禁令**

> Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.

跟 Edit 是同一条,原因也一样:AI 训练模型天然爱在代码 / 注释 / 提交信息里塞 emoji,大多数专业代码库不欢迎这种风格。

**约束 6:错误恢复路径**

> This tool will fail if you did not read the file first.

不只是说会失败,隐含了纠正路径:**报错后先 Read,再重试 Write**。这跟 Edit 的「唯一性失败 → 扩上下文 / 用 replace_all」是同一种「好 prompt 的标志」 —— 错误路径也要设计。

**「不主动生产」的价值观合成**

约束 3 + 约束 4 + 约束 5 合起来构成 Write 的**「不主动贡献噪音」原则**:除非用户明确要,否则 Claude 不该:

- 主动生成 README / CHANGELOG / docs
- 主动创建新文件(能编辑就编辑)
- 主动加 emoji

这三条不是 runtime 硬阻断(Write 参数没有校验 md 后缀 / emoji),而是**描述层的行为训练**。把「AI 应该谨慎生产,不应该自动贡献 markdown 和 emoji」这个价值观 hardcode 到 Claude 的默认行为里。

#### 3 · 字段级描述

Write 的入参 schema 极其简单,只有两个字段:

- **file_path** —— 目标文件的**绝对路径**
- **content** —— 要写入的完整内容

看似平平无奇,但每个字段都有讲究:

**`file_path` —— 为什么强制绝对路径**

跟 Read / Edit 是同一种设计:消除 CWD 依赖,让每次调用**自解释**。跨会话、跨 subagent、跨 worktree,绝对路径都不会歧义。

**`content` —— 为什么就是「完整内容」**

对比 Edit 的 4 字段(file_path + old_string + new_string + replace_all),Write 只有 2 字段,少了「匹配」和「批量」的概念。原因:

- **语义就是「用这段内容覆盖磁盘」** —— 不需要「匹配什么」,因为不是替换
- **没有「批量」概念** —— 一次 Write 就是一次完整写入,不存在部分匹配
- **失败模式简单** —— 要么写成功,要么写失败(权限 / 磁盘 / 路径),没有「匹配失败」这种中间态

Write 的简洁反过来意味着它**没有 Edit 的那些安全网** —— 没有匹配校验、没有唯一性检查、没有 replace_all 分流。**风险面更大,但语义也更清晰**。这是「危险面 + 必要性并存」在字段级的体现:字段少不是能力弱,是**故意不给 Claude 留下「精细调整」的错觉**,逼它意识到「按 Write 就是整个覆盖」。

#### 4 · schema 校验规则

Write 在 schema 层几乎**没有硬约束** —— 没有长度上限、没有格式校验、没有内容黑名单。就两个字段都是 required,如此而已。

真正的约束都放在 **runtime** 里,构成一套状态机:

| 检查 | 时机 | 失败行为 | 意图 |
|---|---|---|---|
| 父目录存在 | 写入前 | 报错拒写 | 防 typo 造成散落目录 |
| 文件已存在 → 本会话 Read 过 | 写入前 | 报错拒写 | 防幻觉覆盖(harness 追踪) |
| 文件不存在 → 直接允许 | 写入前 | 直接创建 | 新建路径不需要 Read |
| 权限 / 磁盘 / 路径合法 | 写入时 | 报错拒写 | 兜底 OS 级失败 |

**为什么父目录不自动创建**:如果 Write 传的路径是 `foo/bar/baz.ts` 但 `foo/bar/` 目录不存在,Write 会直接报错,**不会自动创建目录**。原因:

- **防止 typo 造成散落的目录** —— Claude 拼错路径 `srcc/component.tsx`,如果 Write 自动创建 `srcc/`,会污染项目结构
- **强制 Claude 意识到目录结构** —— 想在新目录写文件?先用 Bash `mkdir -p` 明确表达意图,不能悄悄拉出一个目录
- **失败明确** —— 报错比「悄悄成功」更利于纠错

**Read 先行的 harness 状态共享**:Read 建立「感知承诺」,Edit / Write 消费这个承诺:

- Read 的 harness 状态被**两个执行工具共享**
- Edit 消费:「我知道 old_string 在文件里的样子」
- Write 消费:「我知道我在覆盖什么」

这个共享让 Read 的一次调用可以给后续多个 Edit / Write 提供感知基础,不用每次都重读。

schema 层空、runtime 层有状态机,这个分工在告诉我们:**Write 的风险主要不在参数格式,而在时序和感知**。参数格式能不能自动校验?能。但「你有没有先感知文件当前状态」这件事,只能靠 runtime 追踪。schema 就把简单的活留给自己,把难的留给 runtime。

---

### 小结

Write 的精妙之处,不在于它「把内容写到文件」这个功能本身,而在于它的信号分布**极度依赖描述层的价值观 + runtime 状态机**:

- **命名** —— 极简,一个动词(Read / Edit / Write 同族);字段名朴素,没有匹配 / 批量概念,直接映射「覆盖」语义
- **工具级描述** —— 6 段约束覆盖:覆盖行为透明化、Read 先行硬阻断、显式偏好 Edit、不主动生产文档、emoji 禁令、错误恢复路径;三条软约束合成「不主动贡献噪音」价值观
- **字段级描述** —— 只有 2 字段(file_path + content),字段少不是能力弱,是**故意不给 Claude 留下「精细调整」的错觉**,逼它意识到 Write = 整个覆盖
- **schema 校验** —— schema 层几乎空;真正约束都在 runtime 状态机:父目录必须存在(不自动创建)、已存在文件必须本会话 Read 过、与 Edit 共享同一套 harness 追踪状态

Write 独特的地方在于它**是唯一能创建新文件 / 完全覆盖文件的工具,「必需性」和「危险性」并存**:必需性上,新建和完全重写这两类活只能它干,Edit 顶不上;危险性上,它没有 Edit 的匹配安全网,一次调用就能覆盖 596 行文件的任何位置。这种张力靠三重设计化解 —— **描述层显式偏好 Edit(把 Write 收窄到「新建 / 完全重写」)、runtime 状态机强制 Read 先行(消除幻觉覆盖)、三条软约束钉死 AI 反模式(不主动建 docs / 不新建 / 不加 emoji)**。相当于把「AI 全量写文件」这个天然危险的能力,收敛成一个**用途受限、感知强制、不主动噪音**的执行原语。

**Grep+Glob → Read → Edit / Write** 四类五个工具共享一套 harness 追踪状态,通过「Read 先行」这条硬约束串联起来。核心哲学是:**任何对磁盘的写入,必须建立在对当前磁盘状态的感知之上**。不是靠 AI 自律,而是靠 runtime 强制。
