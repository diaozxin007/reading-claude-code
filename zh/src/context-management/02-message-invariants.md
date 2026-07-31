前一篇 [01 · Agent Loop · context 是怎么装配的](01-agent-loop.md) 讲清了 Claude Code 每次调 LLM 都要完整重发一个 messages 数组。 那一篇的重点是 loop 视角 —— 消息数组只是被动承载的容器。

这一篇反过来 · **以消息数组本身为主角** —— 里面每条消息什么形态、数组增长有什么规律、什么结构约束一旦破坏 API 就会拒绝服务。 后面几篇的所有话题(压缩、恢复、CLAUDE.md 注入、sub-agent 隔离、system-reminder 通道)都建立在本篇的三条不变量之上。

看清 messages 数组要回答几个问题:

- 数组里每条消息长什么样?
- 数组增长有什么规律?
- 有哪些结构约束不能破坏?
- 结构约束被破坏后 · Claude Code 怎么应对?

## 一条消息长什么样

你在 Claude Code 里输入 "帮我看看这个 bug" · 按下回车。 Claude Code 会把这段话打包成一条**消息**:

```
{
  role: 'user',
  content: '帮我看看这个 bug',
  uuid: 'a3f2...(36 位)',
  timestamp: '2026-07-30T14:23:11Z'
}
```

**四个字段**:role(谁说的)· content(内容)· uuid(身份)· timestamp(时间戳)。

后面 loop 转起来 · 数组里还会出现另外两类消息 —— 模型的回复、工具的执行结果。 那两类结构稍复杂 · 我们放到具体场景里再看。

## LLM 怎么知道能调哪些工具

上面示例里 LLM 说 "我要调 Read" —— 前提是它**知道有 Read 这个工具**。 这个前提从哪里来?

一次调 LLM · 除了 messages 数组 · Claude Code 还要发一段 **tools 声明**:

```
POST /messages
{
  system:   "...",     ← 系统提示词
  tools:    [...],     ← 可用工具列表
  messages: [...]      ← 对话历史(本篇主角)
}
```

tools 列表里 · 每个工具形如:

```
{
  name: 'Read',
  description: '读一个文件的内容 · 支持 offset / limit 分页 · ...',
  input_schema: {
    type: 'object',
    properties: {
      file_path: { type: 'string' },
      offset:    { type: 'number' },
      limit:     { type: 'number' }
    },
    required: ['file_path']
  }
}
```

三个关键字段:
- **name** —— 工具名 · LLM 回复里 `tool_use.name` 对应到这里
- **description** —— 说明这个工具做什么、什么时候用、边界是什么 · LLM 靠这段决定要不要调它
- **input_schema** —— 参数的 JSON Schema · LLM 输出的 `tool_use.input` 必须符合这个 schema

LLM 收到 tools 列表 · 才知道当前 session 能调什么。 一个不在 tools 列表里的工具 · LLM 不会调 —— 训练时它学过 "只调 tools 里列出来的"。

**Tools 是 API 请求的第三段** —— 和 system prompt 一样 · 一个 session 内相对稳定 · 每次调 LLM 都发一遍。 后续 loop 系列会讲到 tools 的实际内容(有哪些工具、怎么组织、动态注册)。 tool 定义本身的深入拆解 —— 4 层契约、JSON Schema 约束、Claude 怎么读工具描述 —— 见 读书笔记/Claude code tools 研究系列/Claude code tools 研究系列-前置篇（tool 机制）。

本篇之后 · 我们把 tools 当作**已经声明好的**背景 · 专注 messages 数组本身。

## 为什么必须维护一个消息数组

**上一篇的复习**:

- LLM 无状态 · 每次调用不留历史
- 想让 LLM 连贯往下走 · 客户端必须自己攒一份历史
- 每一条已发生的消息(用户输入 / LLM 回复 / 工具结果)都追加进数组 · 每次调 LLM 完整重发

数组不是设计选择 · 是 loop + API 无状态推出来的必然结果。 本篇不再重复推演 · 直接放大数组本身。

## 一次调用里可以有多个工具

LLM 觉得要同时读两个文件 · 一次 assistant 消息里可以塞两个 tool_use:

```
{ role: 'assistant', content: [
    { type: 'text',     text: '我并行读两个文件' },
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file: 'auth.py' } },
    { type: 'tool_use', id: 'toolu_B', name: 'Read', input: { file: 'login.py' } }
  ] }
```

harness 拿到这个 · 会同时启动两个 Read。执行完 · **两个结果打包到同一条 user 消息里**:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_A', content: '<auth.py>' },
    { type: 'tool_result', tool_use_id: 'toolu_B', content: '<login.py>' }
  ] }
```

**为什么两个 tool_result 塞一条消息里** · 而不是分两条:因为 Anthropic API 有个约束 —— **assistant 和 user 消息必须严格交替**。不允许连续两条 user 消息。所以 harness 只能把并发工具的结果**聚合成一条**。

**问题在于**:两个工具执行时间不同。auth.py 秒回 · login.py 要 5 秒。谁先谁后进 tool_result 数组?

**Claude Code 的选择:按完成顺序**。谁先跑完谁先进。所以数组里 tool_result 的顺序 · 跟 assistant 里 tool_use 的声明顺序 **不一定对得上**。

**但这不构成问题** —— 因为配对靠的是 `tool_use_id`(`toolu_A` / `toolu_B`)· 不是位置。API 只要求"每个 tool_use 都要有一个对应 id 的 tool_result" · 位置无关。

这里出现第一个**不变量的雏形**。

## 配对不变量:每个 tool_use 必须有 tool_result

假设 LLM 声明了 3 个 tool_use · 但 harness 只返回了 2 个 tool_result —— 少了一个。

会发生什么?**下一次调 LLM · API 直接返 400 错误**:

> `messages.0.content: unexpected tool_use_id`

理由:LLM 出了一个 tool 调用请求 · 你必须给它对应的结果。少一个 · API 判定这段对话结构损坏 · 拒绝服务。

**所以 messages 数组里出现了第一条硬约束**:

> **每一个 `tool_use` 块 · 都必须有一个 `tool_use_id` 匹配的 `tool_result` 块。缺一个 · API 报废。**

这条约束把 messages 数组从"松散的消息列表" · 变成了"必须维持某种结构的数据"。

**这条不变量催生了一整套修补机制** —— 中断、compact、rewind 都会破坏配对 · 各自需要修补策略。 这些留到专门的分叉篇讲。 主流程里 · 知道"配对是硬约束"就够了。

## isMeta —— 一条 harness 塞给 LLM 的消息

到目前为止 · messages 数组里出现的角色只有:

- 真用户输入的 user 消息
- LLM 输出的 assistant 消息
- harness 生成的 tool_result(借 user role)

还有第四类:**harness 主动塞给 LLM 但不希望在 UI 里显示**的消息。

举几个例子:

- Session 起手 · harness 要告诉 LLM 现在的日期 / 项目的 CLAUDE.md 内容
- 用户中断后 · harness 要合成 "Interrupted by user" 消息补 tool_result 配对
- Compact 之后 · harness 要注入一个 "过去的对话被总结成这样" 的摘要
- MCP server 连接上了 · harness 要通知 LLM "有新工具可用"

这些消息**必须让 LLM 看到** —— 但如果显示在 UI 上 · 用户会一头雾水:"我没说这句啊"。

**Claude Code 的做法**:给消息加一个 `isMeta: true` 标记:

```
{ role: 'user', isMeta: true, content: '<system-reminder>...</system-reminder>' }
```

`isMeta` 的语义:**这是 harness 塞进来的元消息 · 不是真用户** · UI 层看到 `isMeta` 就跳过。

**但注意一件事**:`isMeta` 是 harness 内部的字段 · **Anthropic API 完全不认识它**。

序列化发到 API 时:

```
{ role: 'user', content: '<system-reminder>...</system-reminder>' }
                                          ↑
                              没有 isMeta · 就是普通 user 消息
```

那 LLM 怎么知道这不是用户说的?

**靠内容里的 `<system-reminder>` 文本标签**。 harness 会用 `<system-reminder>...</system-reminder>` 把这些元消息包起来。 而 system prompt 里明确训练 LLM:**看到 `<system-reminder>` · 这是 harness 塞进来的元指令 · 不是用户说的**。

**换句话说**:元消息的身份 · **完全靠一个文本约定** —— API 结构上等同于 user 消息 · 靠 LLM 认标签才知道来路。

这个设计有个后果:**只要你的 CLAUDE.md 或用户消息里恰好包含 `<system-reminder>` 标签 · LLM 就会把那段当元指令处理**。这是一个理论上可注入的攻击面 · 但 Claude Code 里没看到对这个字符串的过滤。

## 三条不变量

到这里 · messages 数组的形态已经完全展开:

- 表面是**平铺数组**(内存视角)
- 底下是**父子链表**(磁盘视角)
- 每条消息带 role / content / uuid / timestamp / 可选 isMeta / 可选 parentUuid
- tool_use / tool_result 必须严格配对
- 元消息借 user role 上线 · 靠 `<system-reminder>` 文本约定被识别

所有的操作(compact / rewind / interrupt / fork / sub-agent)都必须尊重**同一批不变量**。总结出来是三条:

### 不变量 1 · 只 append · 不 update · 不 delete · 不 reorder

- 内存数组只能末尾追加 · 已有的消息不能改
- 磁盘 JSONL 是 append-only · 从来不覆盖不删
- 位置改了 · parentUuid 链就断 · 磁盘 leaf 回溯就找不到路
- Rewind 例外?rewind 是**内存 slice · 磁盘不动** —— 磁盘依然只 append

**为什么这条这么硬**:因为一旦允许 update / delete · 那么整个 session 的状态就没有"确定性回溯路径" · 恢复 session 的时候你不知道要以哪个版本为准。

### 不变量 2 · tool_use ↔ tool_result 必配对

- 每个 tool_use 必须有对应 `tool_use_id` 的 tool_result · 缺了 API 直接 400
- 反向也一样 —— 引用不存在 tool_use 的 tool_result 也不允许
- 位置无所谓 · id 匹配就行 —— 允许并行 tool 按完成顺序返回
- 任何破坏配对的操作(中断 / compact / rewind)· 必须**修补** —— 补 orphan / 剔 dangling

**为什么这条这么硬**:因为 Anthropic API 把它当结构约束在服务器端强执行 —— 客户端没有选择。

### 不变量 3 · role 严格交替 · 元消息借 user role 上线

- API 只允许 user / assistant 严格交替 —— 不允许连续两条 user real content
- 元消息(CLAUDE.md 注入 · 日期变化 · 中断合成 · compact 摘要)必须走 user role · 但用 `<system-reminder>` 文本包裹让 LLM 认出
- 相邻的两条 user 消息(比如 CLAUDE.md 注入 + tool_result)· 必须**合并成一条**才能上线 —— 源码里这个操作叫 `smoosh`
- 合并方式:两个 content 数组拼起来 · 打包进一条 user 消息

**为什么这条这么硬**:训练数据里模型学到了"user - assistant - user - assistant"这个交替模式。连续两条 user · 模型会认为对话该结束 · 提前输出 stop sequence。**结构不合规不只是被 API 报错 · 是让模型行为退化。**

## 三条不变量之上 · 才谈得上上层功能

一旦你把上面这三条不变量装进脑子 · 后续 loop 系列所有话题都会顺畅得多:

- **compact** 是"把老消息群总结成一条 · 但要保 tool_use/tool_result 完整"
- **rewind** 是"内存 slice + 新 conversationId · 磁盘不动"
- **interrupt** 是"补上所有缺失的 tool_result 让配对完整"
- **fork subagent** 是"复用 messages 数组但把 tool_result 换成 placeholder"
- **sub-agent** 是"另起一个 messages 数组 · 但 parentUuid 链到 parent"
- **CLAUDE.md 注入** 是"prepend 一条 isMeta:true user 消息 + `<system-reminder>` 包裹"

每一条都是在**不变量约束下**的具体设计选择。 后续系列讲每个话题时 · 都会回来引用这三条。

**下一篇** [03 · Prompt Cache 是骨架 · 为什么其他机制长成那样](03-prompt-cache.md) 讲 Prompt Cache —— messages 数组每次完整重发的成本 · 靠 cache 才能可持续。 cache 的每一个设计选择 · 追根到底都是本篇讲的三条不变量在幕后约束。
