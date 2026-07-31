上一篇 [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) 讲清了 loop 里的**权限批准** —— LLM 输出 tool_use 到工具真的执行之间 · 有一层拦截让用户能拍板。

但用户想在 loop 里插入自定义逻辑 · 不止"批不批准工具"一种。 他可能想:

- **每次执行 Bash 前 · 检查一下命令**(pre-tool 拦截)
- **每次执行 Edit 后 · 跑一遍 formatter**(post-tool 收尾)
- **每次 session 起手 · 加载团队公用的 project rules**(session-start 挂载)
- **每次 compact 之前 · 备份一份当前对话**(pre-compact 快照)
- **loop 打算结束时 · 强制它继续再跑一轮**(stop 阻断)

**这些都需要 hooks**。 hooks 是"用户在 loop 里插自定义逻辑"的通用答案。

权限批准是 hooks 的一种特化 —— hooks 的通用能力覆盖 20+ 个不同的插入点。

看清 hooks 要回答几个问题:

- 一共有多少种 hook · 分别挂在 loop 的哪里?
- 一个 hook 拿到什么、返回什么、能做什么?
- Hook 能不能**阻止**一个动作(比如禁止执行某个工具)?
- Hook 能不能**修改**动作的结果(比如改 tool_result 内容)?
- Hook 卡住了怎么办 · 有没有超时?

## 26 种 hook 事件

Claude Code 里 hook 挂载点**远比通常想的多**。 完整清单(按 loop 生命周期分组):

**Session 生命周期**:
- `SessionStart` —— 新 session 起手时
- `SessionEnd` —— session 退出时
- `Setup` —— 初次配置 · Setup 阶段
- `ConfigChange` —— 配置文件变化时

**用户输入 / 提交**:
- `UserPromptSubmit` —— 用户按回车提交前
- `Elicitation` / `ElicitationResult` —— 需要用户澄清 · 收到用户澄清后

**Tool 生命周期**:
- `PreToolUse` —— 每个工具执行前
- `PostToolUse` —— 每个工具执行成功后
- `PostToolUseFailure` —— 工具执行失败后
- `PermissionRequest` —— 权限批准触发时(上一篇的 race 参与者之一)
- `PermissionDenied` —— 权限被拒后

**Turn / Stop**:
- `Stop` —— loop 打算结束时(LLM 返回不带 tool_use · 准备退出)
- `StopFailure` —— stop 处理出错

**Task 家族**:
- `TaskCreated` —— Task 创建时
- `TaskCompleted` —— Task 完成时

**Compaction**:
- `PreCompact` —— 压缩执行前
- `PostCompact` —— 压缩执行后
- `InstructionsLoaded` —— (含 CLAUDE.md 等)加载后

**Subagent**:
- `SubagentStart` —— 子代理启动
- `SubagentStop` —— 子代理停止
- `TeammateIdle` —— 团队协作场景 · 队友空闲

**文件 / 工作区**:
- `FileChanged` —— 文件外部被改
- `CwdChanged` —— cwd 变化
- `WorktreeCreate` / `WorktreeRemove` —— worktree 创建 / 删除

**杂项**:
- `Notification` —— 通知触发
- `Setup` —— 初次配置(有重复 · 上面已列)

**共 26 个事件**。 每个事件都对应 loop 里的一个具体时刻 · 用户在 `settings.json` 里为该事件注册处理逻辑 · Claude Code 到那一刻会自动调用。

## 4 类 executor —— hook 怎么被执行

用户在 `settings.json` 里注册 hook · 可以用 4 种不同方式实现处理逻辑:

**1 · `command` —— 命令行**

最常见的方式:声明一段 shell 命令 · 到那一刻由 Claude Code 启动子进程执行。

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{ "type": "command", "command": "npx prettier --write $CLAUDE_FILE_PATHS" }]
    }]
  }
}
```

Hook 通过环境变量拿输入(比如 `$CLAUDE_FILE_PATHS`)· 通过 stdout / exit code 传出决策。

**2 · `prompt` —— 提示词**

把一段 prompt 发给 LLM 让它处理:

```json
{ "type": "prompt", "prompt": "分析这次改动是否会引入安全问题 · 只回复 YES 或 NO" }
```

hook 主体是**再调一次模型**。 用于复杂判断 —— 用户不想写规则 · 让 AI 自己判断。

**3 · `agent` —— agent 子任务**

启动一个完整的子代理(Agent tool 的 hook 形态):

```json
{ "type": "agent", "agentType": "general-purpose", "prompt": "..." }
```

比 prompt 更重 · 但可以让子代理执行自己的完整 loop。

**4 · `http` —— HTTP webhook**

把事件通过 HTTP 发给一个外部服务处理:

```json
{ "type": "http", "url": "https://internal-hooks.company.com/pre-tool-use" }
```

用于**跨机器**的自动化 —— 比如公司安全组维护一个中央 policy 服务 · 所有 Claude Code 用户的 PreToolUse 都发到这个服务判断。

**不同 executor 覆盖不同复杂度**:command(简单脚本)· prompt(单次 LLM 判断)· agent(完整子代理)· http(跨机器策略)。

## Hook 能不能 block · 能不能 modify

关键问题:一个 hook 只是**观察者** · 还是能**影响** loop 的行为?

**答案:能观察 · 也能影响 · 但看事件类型**。

**Block(阻止)**:hook 返回决策 `block` · 或者退出码为 2 · loop 走 blocking 分支。 比如 `PreToolUse` 里 block · 那个工具就不执行了(退到 tool_result is_error)。

**Modify(修改)**:hook 可以在返回中附带 `additional_context` —— 一段追加内容 · 会以 `<attachment>` 形式插入到 tool_result 中 · LLM 下一次看到这个 tool_result 时能读到 hook 追加的内容。 这个能力主要在 `PostToolUse` 里 —— hook 观察到 tool 结果 · 追加"注解"给 LLM。

**决策形态**(hook 返回体):

```json
{
  "continue": true,             // false = 中止整个 loop
  "decision": "block",           // 或 "approve" 或 undefined
  "reason": "...",               // block 的理由 · LLM 会看到
  "additional_context": "..."    // 追加到 tool_result 的注解
}
```

对应到 loop 状态机 · hook block 就会让 loop 从"正常前进"转入"blocking / recovery"分支。

**每种 hook 事件的 block 语义不同**:
- **PreToolUse block** —— 这个工具不执行 · 生成一条 is_error tool_result 告诉 LLM
- **PostToolUse block** —— 追加 `hook_stopped_continuation` 附件 · loop 强制退出
- **Stop block** —— loop 打算结束时被 hook 拦下 · 强制继续再跑一轮(用户可以让 LLM "别停 · 再想想")
- **UserPromptSubmit block** —— 用户的输入直接被拒 · 不进 messages · UI 提示

**这里体现一个设计洞察**:hooks 不是简单的 pub-sub 事件系统 · 它是**loop 的可编程干预点** —— 用户能改 loop 走什么分支。

## Sync 还是 async

**默认 sync** —— hook 阻塞 loop · 直到 hook 返回。

**默认超时**:`TOOL_HOOK_EXECUTION_TIMEOUT_MS = 10 min`。 10 分钟是很宽容的上限 —— 因为 hook 可能是 LLM 调用、可能是 CI 触发 · 通常几秒到几分钟。 超过 10 分钟 hook 被 kill · loop 继续。

**但也可以配置成 `async`**:

```json
{ "type": "command", "command": "...", "async": true }
```

- **`async: true`** —— fire-and-forget · hook 启动后立即返回 · loop 不等
- **`asyncRewake: true`** —— 更特殊 · async 启动后 · **如果 hook 用 exit code 2 结束 · 会 re-wake LLM** —— 意思是"我在后台想了一段时间 · 现在有话说 · 请让模型再回来处理一下"

**asyncRewake 是一个很微妙的机制** —— 它允许一个后台任务在完成时**主动通知 loop 醒过来继续处理**。 比如:一个耗时 5 分钟的代码分析 · 用户不想在原对话里等 · 让它 async 跑 · 结果出来后再自动回到对话继续。 是"事件驱动 loop 醒来"的一种优雅实现。

## Hook 失败怎么办

Hook 出错(exit code 非 0 且非 2 · JSON 格式坏 · 抛异常)· **loop 不会崩** —— 走 `non_blocking_error` 分支:

- 记日志
- 工具继续执行(pre-tool 场景)· 或者结果直接采用(post-tool 场景)
- 用户看不到明显的错误

**设计哲学:hook 是可选强化 · 不是关键路径**。 hook 挂了不影响主流程 · 只是这次 hook 想做的强化没做成而已。

**但也有例外**:如果 hook 明确返回了 `decision: block` 或 `continue: false` · 那是 hook 的有效决策 · loop 会遵守。 只有**意外错误**才 non_blocking · 明确的 block 决策一定生效。

## Hooks 和权限批准的关系

上一篇讲了权限批准 —— 3 个来源 race:用户点击 · hook · classifier。

**这里的 hook** 就是 `PermissionRequest` hook。 用户在 `settings.json` 里注册这个 hook · 就是在 race 里参赛 —— 提供一个自动批准的判断。

**举例**:

```json
{
  "hooks": {
    "PermissionRequest": [{
      "hooks": [{ "type": "command", "command": "./ci-safety-check.sh" }]
    }]
  }
}
```

Claude Code 到需要批准时 · 会启动 `ci-safety-check.sh` · 这个脚本可能查一个内部安全策略数据库 · 快速返回 "允许" 或 "拒绝"。 用户 UI 都还没弹出来 · hook 已经答完了。

**这就解释了上一篇的 race 设计** —— hooks 系统让"批准决策"变成一个**可插拔的问题**。 谁快谁答:用户点击(慢但权威)· hook(中等)· classifier(快)。 三者协作 · 谁答完谁 win。

## Hooks 相对权限批准的一般性

权限批准专注一件事:**通不通过一个工具调用**。

Hooks 泛化了这个能力 —— 用户能在 **26 个不同点**上**注入决策 / 观察 / 追加内容 / 阻止后续**。 权限批准是 hooks 泛化能力的一个特化(PermissionRequest 事件)。

**这个泛化的价值**:
- Session 起手时 hook · 可以做团队级配置注入(比如统一加载 project rules)
- 每次 tool 前 hook · 可以做 audit log(记录一切调用)
- Compact 前 hook · 可以做备份(快照本轮对话到磁盘)
- Stop hook · 可以强制 loop 再跑一轮(比如"没跑完测试之前不许停")
- Cwd change hook · 可以自动加载不同项目的 rules

**每一个都是"loop 上的可编程干预点"** —— 用户可以在这些点上写自定义逻辑 · 不改 Claude Code 源码。

## 小结

- **26 种 hook 事件** 覆盖 loop 生命周期各阶段
- **4 类 executor**:command(shell 命令)· prompt(LLM 判断)· agent(子代理)· http(webhook)
- **Block 和 Modify** —— hook 可以阻止一个动作、可以追加 tool_result 内容、可以强制 loop 状态转移
- **Sync / async / asyncRewake** —— 默认 sync 10 分钟超时;async fire-and-forget;asyncRewake 后台完成后自动 re-wake LLM
- **失败 non_blocking** —— hook 挂了 loop 继续 · 除非明确 block 决策
- **权限批准 = hooks 的一种特化** —— PermissionRequest 事件让权限批准变成可编程

下一篇 [03 · 从读文件到并行调度](03-parallel-scheduling.md) 讲工具执行的**具体机制**:多个 tool_use 同时来 · 是并行还是串行?工具崩了怎么办?哪些工具能安全并行、哪些必须串行?

---

## 参考

**主要 file 定位**(v2.1.220):
- `src/entrypoints/sdk/coreTypes.ts` · 26 种 hook 事件枚举
- `src/schemas/hooks.ts` · 4 类 executor(command / prompt / agent / http)
- `src/utils/hooks.ts` · 中央 dispatcher · `executeHooks()` · `executePreToolHooks()` 等
- `src/services/tools/toolHooks.ts` · Pre/Post tool hook 触发点
- `src/query/stopHooks.ts` · Stop hook 阻断 loop 逻辑
- `src/hooks/toolPermission/PermissionContext.ts` · Permission hook 参与 race

**相关篇**:
- [01 · 从 tool 声明到执行前的批准](01-tool-permission.md) · 权限批准是 hooks 的一种特化
- [03 · 从读文件到并行调度](03-parallel-scheduling.md) · 下一篇:tool 具体执行机制

**Anthropic 官方**:
- [Claude Code hooks](https://code.claude.com/docs/en/hooks) · `settings.json` 中 `hooks` 段的配置格式
