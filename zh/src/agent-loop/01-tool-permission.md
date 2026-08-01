上一篇 [00 · 开篇 · 从聊天窗口到 loop](00-intro.md) 讲清了 loop 的 5 行骨架 —— 调 LLM · 看有无 tool_use · 有就执行、没有就退出。

这一篇挖 loop 每一步里的**第一件事**:LLM 怎么知道有哪些工具能调? 声明了要调 · 到工具真的执行 · 中间还差什么?

看清这一步要回答几个问题:

- LLM 凭什么知道当前 session 能调 Read?
- LLM 说要调 Read · 就真的调了吗?
- 如果不是 · 中间发生了什么?
- 谁来决定这次调用能不能进行?

## Tools —— API 请求的第三段

上一篇讲 loop 时 · 每次调 LLM 都在发一个 messages 数组。 完整的 API 请求其实不止 messages 一段:

```
POST /messages
{
  system:   "...",     ← 系统提示词
  tools:    [...],     ← 可用工具列表(本篇主角)
  messages: [...]      ← 对话历史
}
```

三段拼一起 · 一起发给 LLM。 messages 段每轮变 · tools 和 system 段一 session 内相对稳定。

**LLM 只调 tools 段里列出来的工具** —— 训练时它学过 "tool_use 里的 name 必须从 tools 声明里挑一个"。 一个不在 tools 列表里的工具 · 模型不会调 —— 因为它根本不知道存在。

所以 LLM 能调 Read · 前提是 Claude Code 在 tools 段里**已经声明**了 Read。

## 一个 tool 声明长什么样

tools 段是一个数组 · 每个元素声明一个工具。 一个工具声明包含三个字段:

- **name** —— 工具名 · 就是 LLM 回复里 `tool_use.name` 会用到的字符串
- **description** —— 说明这个工具做什么、什么时候用、什么时候不该用、有什么边界
- **input_schema** —— 参数的 JSON Schema · 声明工具接受什么样的输入 · LLM 输出的 `tool_use.input` 必须符合这个 schema

LLM 靠什么决定要不要调某个 tool?**完全靠 description**。 你 description 写得越清楚 · LLM 判断得越准。 一个工具 description 差 · LLM 会用错场景 · 或者忽略这个工具。

tool 定义本身的深入拆解 —— 4 层契约、JSON Schema 具体约束、Claude Code 里怎么组织多个 tool、MCP 动态注册 —— 见 tools 研究系列前置篇。 本篇只需要知道:tools 段是一批**给 LLM 的工具菜单** · 定好之后每次调 LLM 都发一份。

## LLM 输出 tool_use · 到工具执行 · 中间还有一步

现在 LLM 收到了 tools 段 · 看到 Read 存在 · 也看到你的问题("帮我看看 auth.py")· 回复里带了一个 tool_use:

```
{
  role: 'assistant',
  content: [
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file_path: 'auth.py' } }
  ]
}
```

**下一步会发生什么?**

按 loop 骨架 · 应该是"执行工具 · 拿到结果 · 追加消息"。 但真实情况里 · **中间还夹着一步**:

**权限批准**。

Read 一个普通文件可能自动通过。 但如果 LLM 说要:
- `Bash rm -rf /some/dir` —— 删目录 · 危险 · 必须让用户确认
- `Edit /etc/passwd` —— 改系统敏感文件 · 必须确认
- `Bash` 命令的第一次调用 —— 每种新命令用户可能都要拍板一次

这些情况下 · Claude Code **不会直接执行工具** —— 它会先弹出一个批准提示 · 等用户点 "允许" 或 "拒绝" 才继续。

## 这就是"loop 中间无人参与" 的**唯一例外**

上一篇建立了一个关键前提:**loop 是自动循环 · 中间没有用户参与**。

**权限批准是这个前提的唯一例外**。

为什么必须有这个例外? 因为 loop 是自己转下去的 · 中间没人。 如果没有权限批准这一层拦截 · LLM 说要 `rm -rf` · loop 就照做 · 用户来不及反应 · 文件就没了。

权限批准存在的意义就是:**在 loop 自动流转过程中 · 主动让用户短暂重新出现** —— 只在批准这一个点上 · 别的地方不让用户介入。

其他相关机制也都是这个思路 · 但各自的介入方式不同:
- **权限批准** —— 阻塞 loop 等用户输入(loop 停下来 · 弹窗 · 用户决定)
- **interrupt** —— 用户主动中断 loop(loop 在跑 · 用户按 Ctrl-C · loop 才停)
- **maxTurns** —— 无需用户参与 · 达到轮数上限自动停(硬保险)

三者互补 · 覆盖"loop 自动跑"这个前提的三种"必要例外"。

## 批准规则的 6 级来源

用户不希望**每次**都被打断 —— 如果每次 Read 都要点一下允许 · 用户会疯。 所以 Claude Code 的权限系统需要**记住用户的偏好**:哪些工具/命令自动通过 · 哪些每次都要问 · 哪些永远禁止。

这些偏好来自 **6 个不同层级**:

| 来源 | 优先级 | 生效范围 | 例子 |
|---|---|---|---|
| **denyRule**(明确拒绝) | 最高 | 一律拒绝 · 不问 | `Bash(rm -rf *)` · 永远禁止 |
| **askRule**(明确要问) | 次高 | 每次都问 · 不能记住"总是允许" | `Bash(git push)` · 每次都要确认 |
| **classifier 自动判断** | 中 | AI 系统本身判断安全的自动通过 | 只读的 Grep / Read 通常自动过 |
| **alwaysAllow**(总是允许) | 中 | 用户明确点过"总是允许"之后记住 | `Read(*)` · 允许所有文件读操作 |
| **defaultMode** | 低 | 系统级默认模式 | 默认策略 · 比如"读操作全允许 · 写操作要问" |
| **abortController 已 abort** | 最优先 | 用户已中断 · 直接拒绝 | 用户按了 Ctrl-C 后 · 剩下的批准全跳过 |

这些规则来自**多个配置文件层级**:
- **`cliArg`** —— 启动 CLI 时传的参数 · 一次 session 有效
- **`session`** —— 用户在当前 session 中点过 "总是允许" 后 · 只在**本 session** 有效
- **`localSettings`** —— 项目下的 `.claude/settings.local.json` · 只对当前用户 · 不进 git
- **`projectSettings`** —— 项目下的 `.claude/settings.json` · 进 git · 团队共享
- **`userSettings`** —— 用户全局的 `~/.claude/settings.json`
- **`managedSettings`** —— 企业管理员级 · 用户不能覆盖

**每次批准前 · 系统按上面的顺序检查**:先看 abort · 再看 deny · 再看 ask · 再看 classifier · 再看 alwaysAllow · 最后看 default。 有一层命中 · 立即得出结论。

## 一个批准怎么阻塞 loop

假设当前所有规则都不能自动得出结论 —— 只能问用户。 这一步在 loop 层面看是这样:

```
loop 转到某一次 · LLM 输出 tool_use
    ↓
准备执行工具 · 先跑权限检查
    ↓
所有自动规则都不匹配 · 需要用户拍板
    ↓
【loop 阻塞 · Promise pending】
    ↓
UI 层弹出一个批准对话框(Ink 层渲染)
    ↓
用户点"允许" · Promise resolve
    ↓
loop 继续 · 工具真的执行
```

**关键点**:loop 不是"轮询用户点没点" —— 它是 **await 一个 Promise**。 UI 层拿到用户的点击 · resolve 这个 Promise · loop 才继续。 用户在批准弹窗上思考 10 秒钟 · loop 就阻塞 10 秒 —— 什么也不做。

**副作用**:批准阻塞期间 · **LLM 的 API 调用没在进行** —— 因为 loop 卡在批准这一步 · 还没到下一次 call_llm。 也就是说 · 用户思考的时间 **不计入 API 成本** —— 这是权限系统的一个隐形优点。

## 3 个批准来源同时判断 · 谁先返回就采用谁

上面说"UI 层拿到用户点击 · resolve Promise" —— 但真实设计更巧妙:**批准的 resolve 可以来自 3 个不同来源**:

1. **用户点击**(UI 层的 "允许" / "拒绝" 按钮)
2. **PermissionRequest hook**(用户或团队在 `settings.json` 里配了自动批准 hook · 走命令行 / HTTP 触发)
3. **AI classifier**(Claude Code 内置的分类器 · 判断这个操作是否明显安全)

这 3 个来源会**同时开始判断**。这就是这里的 `race`（竞速）：谁最先给出结果，就采用谁的结果并结束等待；另外两个来源随后返回的结果不再生效。

为什么这么设计?

- 用户点击最慢(通常 3-10 秒)· 但绝对权威
- Hook 中等(几百毫秒到几秒)· 灵活可编程
- Classifier 最快(几十毫秒 AI 推理)· 但可能保守拒绝

**如果依次判断** —— 先等 hook · 再等 classifier · 最后问用户 —— 总等待时间可能是三者耗时之和。让三者同时判断，只需等待最快的一个，因此批准流程响应更快。

**但并发就要防止 double-resolve** —— 如果 Promise 被 resolve 两次 · 会崩溃。 Claude Code 用一个叫 `ResolveOnce` 的机制 · 三者中第一个到达的**声明认领**(claim)· 之后其他两个尝试认领都会被拒绝。 保证 Promise 只被 resolve 一次。

**这里体现了一个设计洞察**:让多个来源竞速 · 而不是先决定优先级串行 —— 是权限系统追求"用户体验最快"的直接产物。 race condition 通常是 bug · 这里反过来是**特性**。

## Subagent 的权限系统不继承

主对话里 · 用户可能已经点过"总是允许 Bash" · session 层级里记着 alwaysAllow 规则。

现在 · 主对话生一个 [subagent](09-sidechain.md)(让另一个 AI 独立跑一件事)—— 让 subagent 也去跑 Bash 命令。

**主对话的 alwaysAllow 会传给 subagent 吗?**

**不会**。

Claude Code 的默认行为是:subagent 起手时 · **清空主对话的 session 级批准** —— 只保留 CLI 参数级(不变的启动配置)· session 级换成 subagent 自己的 `allowedTools`(声明 subagent 允许调什么)。

为什么这么设计? 因为主对话的 alwaysAllow 是**用户对主对话的信任**。 subagent 是另一个 AI · 用户没有对它同等的信任。 不继承 = 更保守 · 更安全。

代价是 subagent 里可能需要重新走一次权限批准 —— 但**默认保守优于默认信任**是安全系统的基本原则。

## 小结

- **tools 段是 API 请求的第三段** · 声明当前 session 能调什么工具。 LLM 靠 description 判断要不要调
- **LLM 输出 tool_use 之后 · 到工具真的执行前 · 有一步"权限批准"** —— 这是"loop 中间无人参与"的**唯一例外**
- **权限规则 6 级来源** · 从 abort > deny > ask > classifier > alwaysAllow > default 顺序判断
- **批准阻塞 loop 的方式是 await Promise** —— 用户思考的时间不计入 API 成本
- **3 个批准来源同时 race** —— 用户 / hook / classifier · 谁快谁赢 · `ResolveOnce` 兜底防止 double-resolve
- **subagent 权限不继承** —— 保守的安全默认

下一篇 02 · Hooks · loop 上的插入点 讲**批准之后**:一个 tool_use 到工具真的执行之间 · 除了权限批准 · 还有一个更通用的机制 —— hooks —— 允许用户在 loop 的 26 个不同点上插自定义逻辑。 权限批准是 hooks 的一种特化;hooks 是"用户想在 loop 里插自定义逻辑" 的通用答案。

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/utils/permissions/permissions.ts` · `hasPermissionsToUseTool` 主流程
- `src/hooks/toolPermission/handlers/interactiveHandler.ts` · 交互式批准 Promise
- `src/hooks/toolPermission/PermissionContext.ts` · `ResolveOnce` claim
- `src/utils/permissions/PermissionUpdate.ts` · alwaysAllow 持久化
- `src/utils/settings/types.ts` · settings.json 中 `permissions` schema
- `src/types/permissions.ts` · `PermissionRuleSource` 6 级来源
- `src/tools/AgentTool/runAgent.ts` · subagent 权限清空

**相关系列**:
- Claude code tools 研究系列-前置篇（tool 机制） · tool 定义的 4 层契约、JSON Schema、系统提示词组织
- [02 · 从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md) · tool_use 在消息数组里的位置和约束

**Anthropic 官方**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) · tool 声明的 API 格式
