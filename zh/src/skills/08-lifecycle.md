# 08 · 生命周期 · 从一次加载到 compaction

> **TL;DR**:Skill 有四份容易混淆的状态:磁盘 source · 候选 metadata · 某次调用生成的 rendered content · compaction 后重新附着的保留副本。修改 `SKILL.md` 会影响未来发现和调用 · 不会改写已经进入 conversation 的 instructions。Inline Skill 正文会跨 turn 留在当前 session · 但权限 grant 不跟着留;Compaction 只在每项与总预算内保留最近调用 · 不是重新读取完整源文件。

上一篇 [07 · 权限治理 · 从可调用到可安全执行](07-permissions.md) 已经指出一处生命周期分裂:Skill instructions 可能继续留在 context · `allowed-tools` grant 却会在下一条用户消息时清除。

这不是唯一一处分裂。用户常见的直觉是:

```text
Skill 就是磁盘上的 SKILL.md
```

运行起来后 · 至少要区分四个对象。

## 四份状态 · 四个更新时间

```text
A · Source file
  磁盘上的 SKILL.md 与 supporting files
        ↓ discovery

B · Candidate metadata
  当前 session 知道的 name + description
        ↓ invocation + rendering

C · Rendered invocation
  参数、变量、动态上下文都已展开的正文
        ↓ conversation growth / compaction

D · Post-compact preserved copy
  在预算内重新附着的最近 Skill 内容
```

它们分别在不同事件更新:

| 状态 | 什么时候产生 | 什么会让它变化 |
|---|---|---|
| Source | 创建或安装 Skill | 编辑、更新 Plugin、切换版本 |
| Metadata listing | session 发现 Skill | live detection、scope / visibility 变化 |
| Rendered invocation | 用户或 Claude 调用 Skill | 新参数、新动态输出、再次调用 |
| Post-compact copy | conversation compaction | 保留预算、调用新旧顺序 |

若不先给状态命名 · "Skill 已更新""Skill 已加载""Skill 仍生效"都会变成模糊句子。

## Session 起手 · 先有候选索引

Claude Code 普通 session 会把可由模型调用的 Skill names 与 descriptions 放入候选能力 listing。此时:

- Claude 知道有哪些能力;
- 可以根据 description 选择;
- 完整 `SKILL.md` body 还没有进入 conversation;
- references、scripts 与 assets 也没有自动加载。

这就是第 02 篇的 Level 1。候选 listing 是 Skill 生命周期中最早进入 context 的部分 · 也是每次能力发现都要支付的固定成本。

只允许用户调用的 Skill 不需要靠 description 让模型匹配 · 因此可以不把完整发现信息长期暴露给 Claude。Visibility settings 还能把某些 Skill 降为 name-only 或彻底隐藏。

"已安装"只说明 source 存在 · "已列入候选"才说明当前 model 有机会主动选择。

## 第一次调用 · Rendered content 进入 conversation

用户或 Claude 激活 Skill 后 · Claude Code 取得 source、替换 arguments、运行允许的动态 context · 生成 rendered content。

官方文档把它描述为一条整体消息进入 conversation。此后它不只影响调用当下的一个回答 · 而会留在当前 session 的后续 context 中。

```text
Turn 1
  用户调用 /release-check
  → 完整 instructions 进入 messages

Turn 2
  用户补充"只看 staging"
  → 之前的 Skill instructions 仍在历史中

Turn 3
  Claude继续检查
  → 不必重新读取 source 才知道主流程
```

这使 Skill 能承担跨多轮 workflow。代价是正文的每个 token 都不再只是调用瞬间成本 · 它会随着 conversation 被后续请求继续携带。

## Skill 持续存在 · 权限不会一起持续

这条状态尤其容易误判:

```text
Turn 1
  /commit Skill 激活
  allowed-tools 临时预批准 git commands

Turn 2
  Skill instructions 仍在 context
  allowed-tools grant 已清除
```

所以第二轮 Claude 仍知道提交流程 · 但再次调用敏感 Tool 时可能重新询问。

这不是产品忘记了 Skill · 而是 instructions lifecycle 与 permission lifecycle 故意不同:

- 知识需要持续指导整个任务;
- 临时授权只服务用户明确激活的调用时机。

若希望长期授权 · 使用 session / project permission rules;若希望临时授权恢复 · 重新调用 Skill。

## 修改 source · 不会倒带当前 conversation

Claude Code 支持 live detection。作者在 session 中编辑 `SKILL.md` 后 · 候选 description 和未来调用可以更新。

但已经进入 messages 的旧 rendered content 是 conversation 历史的一部分。运行时不会回头找到那条消息并用新文件替换。

```text
T0 · 调用 v1 Skill
  rendered v1 进入 context

T1 · 磁盘改成 v2
  source = v2
  candidate metadata 可刷新

T2 · 继续普通对话
  messages 中仍有 rendered v1
```

这符合消息数组只追加的基本约束。历史记录表达"当时实际加载了什么" · 不应被未来文件变化静默篡改。

需要新版本时有三种选择:

- 重新调用 Skill · 让 v2 作为新内容进入;
- 开启新 session · 从新的候选状态开始;
- 若当前任务已被旧 instructions 深度影响 · 明确告诉 Claude后续以新版本为准。

Live reload 更新的是定义 · 不是时间机器。

## 再次调用 · 先比较 rendered content

同一 session 中可能再次调用同一 Skill:

```text
/fix-issue 123
...
/fix-issue 123
```

若第二次渲染结果与 context 中已有副本相同 · 再追加完整正文只会浪费 tokens。Claude Code 会用一条简短提示说明它已经加载 · 而不是复制同样内容。

但以下情况会生成不同 rendered content:

- arguments 改变;
- dynamic shell 输出改变;
- source file 已修改;
- session variable 或环境快照改变。

```text
/fix-issue 123
  → rendered A

/fix-issue 456
  → rendered B
```

即使 Skill name 相同 · A 与 B 仍是两项不同任务输入。新正文需要进入 context · 否则 Claude 只看得到旧 issue。

因此去重键不是"Skill 是否叫同一个名字" · 而是"本次 rendered content 是否已经存在"。

## Dynamic context 让同名调用天然可能不同

一项 Skill 包含:

```markdown
!`git status --short`
```

第一次调用时工作区 clean · 第二次调用时已有 5 个修改文件。Source 没变 · rendered content 已变。

这解释两个现象:

1. 重新调用可以刷新环境快照;
2. 频繁重新调用也可能反复加入大段新输出。

作者应让动态输出保持紧凑 · 只注入真正影响工作流的状态。否则"刷新 Skill"会成为 context 增长器。

## Supporting resources 没有自动驻留承诺

`SKILL.md` 引导 Claude 读取 reference · 读取结果会以普通 Tool result 进入 conversation。它的生命周期遵循 messages 与 compaction 规则 · 不因为文件位于 Skill 目录就获得特殊常驻身份。

同样:

- script source 未被读取 → 不在 context;
- script 被执行 → 输出进入 Tool result;
- asset 被读取 → 读取内容进入历史;
- 文件仍在磁盘 → 下次需要可以再次访问。

Skill folder 是持久 source · 当前 conversation 只保存实际展开过的部分——这正是渐进披露的长期形态:磁盘能力包可以很大 · session 只记得本次真正走过的路径。

## Forked Skill · 正文主要活在子 context

Inline Skill 的 rendered content 进入主 conversation。`context: fork` 则把正文作为 subagent task 放入独立 context:主 conversation 发起 Skill invocation · subagent 承载 rendered Skill 与中间工作 · 最终只把结果带回主 conversation。

因此主对话通常不会获得子 agent 的整份工作历史 · 它接收的是返回结果。Forked Skill 的完整正文与中间 Tool results 主要消耗子 context。

这也是为什么 fork 适合过程冗长的任务 · 但不适合指望 Skill 作为主 conversation 的长期 reference。若主 agent 后面还要逐条遵循那套知识 · inline 或显式返回必要规则更合适。

## Compaction · Summary 不足以保存工作方法

Conversation 变长后 · Claude Code 会 compaction:用 summary 替换较早的大段历史。

若完全依赖通用 summary · Skill instructions 可能被压成一句:

```text
用户调用过 release-check。
```

名字还在 · 但具体步骤、约束和资源导航已经丢失。后续 Claude 无法继续按原流程工作。

因此 Claude Code 会在 compaction 后重新附着已调用 Skills 的内容。它不是把所有 Skill source 全部重读 · 而是从 session 已记录的 invoked Skills 中保留最近渲染副本。

```text
compact summary
  + project context 恢复
  + invoked Skill preserved content
  → 新的 post-compact context
```

Skill 在这里拥有比普通早期聊天更强的恢复路径 · 但恢复仍受预算控制。

## 两级预算 · 每项 5K · 总计 25K

官方文档给出当前 compaction 保留规则:

- 每项 Skill 最多保留前 5,000 tokens;
- 所有重新附着 Skills 合计最多 25,000 tokens;
- 从最近调用的 Skill 开始填充总预算;
- 较旧 Skill 可能被整体丢弃。

```text
最近调用
  skill-E  5K
  skill-D  5K
  skill-C  5K
  skill-B  5K
  skill-A  5K
  ---------------- 25K
更旧 Skill
  可能不再附着
```

这带来三个结论:

1. `SKILL.md` 超过 5K tokens · 尾部可能在 compact 后消失;
2. 调用很多 Skills · 较旧能力可能不再恢复;
3. 关键约束放在正文尾部 · 比放在开头更容易在截断后丢失。

开放规范建议 instructions 控制在约 5K tokens 内 · 与产品 compaction 单 Skill 保留上限形成呼应。它不是说 Skill 文件绝对不能更长 · 而是提醒长正文的恢复可靠性下降。

## Compaction 保留 rendered snapshot · 不是最新 source

假设:

```text
T0 · 调用 Skill v1
T1 · 磁盘改成 v2
T2 · conversation compact
```

Compaction 要保持对话语义连续 · 因此应该恢复当时实际调用的 v1 rendered content · 而不是悄悄用 v2 重写过去的任务约束。

这条原则与 source edit 不倒带历史一致:source file 决定未来 invocation · invocation record 记录当时加载的 rendered content · compaction preservation 只延续这条 invocation record · 不会重新绑定到当前 source。若用户希望 compact 后采用 v2 · 应重新调用 v2。不要把磁盘更新当成已激活 instructions 的热替换。

## Listing 也有预算

Compaction 预算管理已调用正文 · session 起手的候选 listing 也有自己的 context 预算。

Claude Code 官方文档说明 · Skill listing 按 model context window 的一定比例控制规模。Skills 很多时:

- name 会尽量保留;
- descriptions 可能被缩短;
- 使用频率较低的 Skill 更可能只剩名字;
- `/context` 与 `/doctor` 可以帮助观察 Skills listing 成本。

这意味着安装 500 项 Skill 不会得到 500 项同等清晰的自动匹配能力。磁盘容量不是瓶颈 · metadata 可见性才是。

可见性设置提供四种典型状态:

| 状态 | Claude listing | 用户 `/` 菜单 |
|---|---|---|
| on | name + description | 显示 |
| name-only | 只有 name | 显示 |
| user-only | 隐藏 | 显示 |
| off | 隐藏 | 隐藏 |

这让用户可以对共享项目 Skill 做本地降噪 · 不必修改仓库内的 `SKILL.md`。

## `/clear` 之后 · Source 活着 · 激活状态结束

Skill folder 是磁盘持久能力 · rendered invocation 是 session context。开启新 conversation 后:

- Source 仍在原 scope;
- Skill metadata 可以重新被发现;
- 上个 conversation 激活过的正文不因文件存在而自动继续生效;
- 新任务相关时需要再次调用。

这与 Memory 的作用不同。Memory 负责跨 session 保留不可推导背景 · Skill 负责保存可复用做法。Skill source 跨 session 存在 · 但"上一 session 正在执行到第几步"不应因此自动成为新 session 状态。

若需要续接工作 · 使用 session resume、task 状态或交接记录 · 不要把运行进度写进 Skill definition。

## 一张完整生命周期图

```text
磁盘安装 / 创建
  SKILL.md + resources
        ↓
Session discovery
  name + description listing
        ↓ 匹配
Invocation
  args + vars + dynamic context
        ↓
Rendered content
  作为一条完整 instructions 进入 inline context
  或作为 forked subagent task
        ↓
Subsequent turns
  instructions 继续存在
  permission grant 单独过期
        ↓
Compaction
  每项最多 5K · 合计 25K · 最近优先
        ↓
New session
  source 重新发现 · invocation 需要重新发生
```

Skill 不是一份在 context 中实时映射磁盘的文件:**Source 决定未来怎样调用 · rendered content 记录这次实际加载了什么 · compaction 只在预算内延续这份调用快照。**

## 下一篇预告

一项 Skill 在个人目录中成熟后 · 可能要随项目共享 · 再进入 Plugin 与 marketplace。文件复制能传播内容 · 却不能解决 namespace、版本、依赖和跨 surface 差异。下一篇 [09 · 分发 · 从个人文件夹到团队 Plugin](09-distribution.md) 将回答一项能力怎样从本机实验演进为可安装组件。

## 参考

- Anthropic Claude Code 官方文档:[Skill content lifecycle](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Override skill visibility from settings](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code 官方文档:[Skill descriptions are cut short](https://code.claude.com/docs/en/slash-commands)
- Agent Skills 开放规范:[Progressive disclosure](https://agentskills.io/specification)
- 上一篇:[07 · 权限治理 · 从可调用到可安全执行](07-permissions.md)
- [04 · Compaction 六兄弟 · 从手动到无处不在的压缩](../context-management/04-compaction.md)
- [08 · Compaction 之后 · 哪些记忆会自动回来](../memory/08-post-compaction.md)
