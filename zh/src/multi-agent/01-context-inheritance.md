## "mid-task course corrections"——工具说明自己留的一条缝

`Agent` 工具的说明里,有一句话是写给**被派出去的那个 agent**看的,交代它该怎么理解自己会收到的消息:

> "Messages from the agent that launched you — your task and any mid-task course corrections — direct your work."

"mid-task course corrections"(任务进行中的修正)——这个词组承认了一件事:**派出去之后,发起方还可能再追加修正**。不是"任务描述必须一次性写死,写完就再也补不了",设计里确实留了"中途改口"这条路。

这就带出上一篇留下的第一个问题:**上下文怎么来**——一个 agent 拿到的信息,是这次调用时就封死的一份,还是能在过程中被继续接上话?

## 默认答案:什么都不带

`Agent` 工具的说明把这件事讲得很直接:被派出去的 agent

> "hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters"

不是"看到一部分"或者"看到摘要"——是**完全没看到**。它对之前发生的一切一无所知,唯一的信息来源就是这一次调用里写的那段任务描述。工具说明接着补了一句更直白的:

> "A new Agent call starts a fresh agent with no memory of prior runs, so the prompt must be self-contained."

**必须自成一体**——这五个字是零继承设计留给使用者的唯一补偿。既然对方什么都不知道,这次给的描述就必须把"要干什么、为什么干、已经排除了哪些路子"一次性交代完,不能留"回头再说"的余地。

这也是为什么工具说明会打这样一个比方:

> "Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters."

"刚走进房间的同事"——这个类比精确地锚住了零继承的后果:不是对方能力不够,而是**它的信息集合从这一刻才开始**。一句简短的命令,对刚走进房间的人来说是听不懂上下文的;工具说明也确实这样点破:

> "Terse command-style prompts produce shallow, generic work."

命令写得越简略,对方能补上的背景就越少,交回来的结果也就越泛。这不是对方"偷懒",是**零继承结构本身逼出来的结果**——它没有别的地方能补信息,只能靠这一次给的文字。

## 想要接着说,得先给一个名字

零继承解决的是"一次性委托"的场景。但开头那句"mid-task course corrections"指向的是另一种需求:**找回同一个 agent,而不是新起一个**——把"中途改口"这件事真正落到实处。

这靠的不是 `Agent` 工具本身,是另一个工具:`SendMessage`。它的用法很简单——指定一个目标,发一句话:

```
{"to": "researcher", "message": "顺便看看这个模块有没有用到已经废弃的接口"}
```

关键在这个 `to` 字段填的是什么。工具说明列了两种目标:一种是**按名字找到的队友**,一种是特殊值 `"main"`(留到讲汇报那篇细说)。这里先看"按名字找队友"这条路——它对应的正是"找回同一个人接着说"这件事。

工具说明写得很明确:

> "Refer to agents by name — names keep working after an agent completes (a send resumes it from its transcript)."

"resumes it from its transcript"——续上的是**它自己**积累的那份历史,不是发消息这一方的上下文。这跟 `Agent` 工具"必须自成一体"的要求形成了一组对照:

- **`Agent` 新起一个**:零继承,靠这一次的描述**从头建立**上下文
- **`SendMessage` 找回一个**:不重建,是把这个 agent 自己此前已经攒下的历史**接着往下续**

一个是"从头写",一个是"翻回上一页接着写"——两者都不是"继承发消息这一方的上下文",这一点容易被直觉带偏,值得单独点破:续接续的是**目标自己的**历史,不是**我的**。

## 名字这个寻址方式,有一条隐藏规则

用名字去找一个 agent,背后隐含一个前提:名字得**唯一地**指向一个具体的 agent 实例。工具说明里藏了一条容易被忽略的规则:

> "Use the raw `agentId` (format `a...-...`) from its spawn result only when the agent has no name, or when a newer agent took the name (latest wins)."

"latest wins"——如果两次 spawn 用了同一个名字,名字**只会指向最近一次**那个实例,更早的那个就此失联,只能靠它当初返回的原始 `agentId` 找回来。这意味着"名字"不是一个稳定的身份证,而更像一个**随时可能被顶替的绰号**——同名的新 agent 一出现,旧的通过名字就够不着了。

这条规则解释了为什么 `SendMessage` 的用法说明特意强调"名字"和"agentId"是两条不同的寻址路径:名字好记但会被顶替,`agentId` 稳定但要记一串生成的字符串。日常协作里默认用名字,只有在"名字可能已经不指向我想要的那个"时,才退回到用 `agentId` 兜底。

## 消息是主动送到的,不是我去问的

续接一个 agent 之后,回复怎么拿到手?工具说明里有一句容易被读快的关键信息:

> "Messages from teammates are delivered automatically; you don't check an inbox."

**自动送达,不用主动查收**——这跟上一篇提到的"任务管理"那条路径正好相反。回想一下:共享任务板(`Task` 家族)靠的是 `TaskList`/`TaskGet` 主动去**拉**一下状态,不问就不会主动告诉你进展。而 `SendMessage` 这条通信路径是**推**过来的——回复一到,直接出现,不需要我主动问一句"你那边怎么样了"。

同一份说明里还有一句话,划出了这条通信路径的边界:

> "Your plain text output is NOT visible to other agents — to communicate, you MUST call this tool."

我在自己这边写的文字,只有用户看得到,**另一个 agent 完全看不到**,除非我显式调用 `SendMessage` 把话递过去。这跟 [Context 系列讲过的消息数组不变量](../context-management/02-message-invariants.md)是同一种克制的延伸——单个 agent 内部,一切进出都要走明确的消息结构,不能靠"隐式感知";放大到多个 agent 之间,这条边界依然成立:**看不见的东西,必须显式发出去才能被看见**。

## 这一篇留下的接口

到这里,"上下文怎么来"这个问题有了两个具体答案:

- **零继承**:`Agent` 新起一个,靠自成一体的描述从头建立
- **续接**:`SendMessage` 按名字找回同一个,续的是它自己的历史,回复是推送到的而非拉取的

但这两条路径都还没回答一个问题:**续接回来的这个 agent,手里还是不是原来那套工具?** 换句话说,上下文续上了,权限是不是也跟着续上了——这是下一篇要回答的。

## 参考

- 本篇立足的一手材料:`Agent` / `SendMessage` 工具的 schema 说明(工具集内直接可读 · 已逐字核对 · 文中引用均为原文)
- "mid-task course corrections"一句由 [tools 系列 · Agent 篇](../power/agent.md)先引用(该篇是从"信息隔离方向"角度讲的 · 本篇从"上下文怎么续"角度重新用)
- 尚未做源码级 discovery——"latest wins"具体在 runtime 里怎么实现名字覆盖、transcript 具体怎么存储续接,留待后续如有 discovery 补充
- 呼应:[从一条消息到消息数组的三条不变量](../context-management/02-message-invariants.md)(单 agent 内部的消息不变量,本篇是它在多 agent 边界上的延伸)
