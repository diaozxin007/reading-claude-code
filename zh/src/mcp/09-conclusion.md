# 09 · 收尾 · 与 Skills、Tool、Plugin 的边界收束

> **TL;DR**:MCP 在[Skills 系列收尾篇](../skills/10-conclusion.md)的决策树里已经有位置——"能力来自外部系统或独立进程"时选它。这一篇把这个位置具体化:什么时候该新写一个 MCP server,什么时候该在已有 server 上加一个工具,什么时候其实只需要一个 Skill 里的脚本;以及装了很多个 MCP server 之后,该不该把它们收进 Plugin。

[上一篇](08-reverse-role.md)讲完 Claude Code 能同时是 MCP client 和 MCP server 之后,这个系列讲的机制已经闭环了——从一份配置,到一次握手,到一个工具改名进 Tool 列表,到权限判断,到认证,到 resources/elicitation,再到反过来当 server。收尾篇不再新增机制,回到一个更实际的问题:**遇到一项新能力需求,什么时候该往 MCP 这个方向想。**

## 先回到 Skills 系列已经画好的位置

[Skills 系列收尾篇](../skills/10-conclusion.md)的决策树里,"模型缺一个原子动作"这一支分了三条路:

```text
模型缺少一个原子动作?
  ├─ Skill 私有确定逻辑 → bundled script
  ├─ 本地通用能力 → custom Tool / executable
  └─ 外部系统 / 独立进程 → MCP Tool
```

本系列一直没有重新论证这条分支,是因为它依然成立——真正需要补的是**分支之间怎么区分**,这是那篇收尾篇留给"以后有专门系列研究 MCP 时再展开"的部分。

## 私有脚本、通用 Tool、MCP server:同一个问题的三种答案

三条路对应的其实是同一个判断维度反复出现:**这个动作只服务一处,还是会被多处复用;它要不要独立于 Claude Code 本体运行。**

一段只在某个 Skill 内部用得到的确定性逻辑——比如按项目自己的规则校验版本号格式——不需要变成一个正经的 Tool,更不需要为它连一个 MCP server,直接写成 Skill 文件夹里的一个脚本,由 instructions 决定什么时候跑就够了。这类逻辑的特点是:**离开这个 Skill 的语境就没有独立存在的意义**,不值得单独暴露成一个通用入口。

如果这个动作会被很多不同任务反复用到,但它是纯本地的、不需要独立进程、不需要单独认证——那是 Claude Code 自己的 Tool 该做的事,不需要绕道 MCP。

真正该往 MCP 走的,是能力本身就活在**别的进程、别的服务里**——[开篇](01-intro.md)那个 Jira 例子是典型场景:数据在别人的系统里,认证要走别人的授权流程,能力会不会变化也不由 Claude Code 决定。这种情况下,把它做成 MCP server 而不是让 Claude 每次都拼 Bash 命令去凑,好处不只是省事——[04 篇](04-tool-exposure.md)讲过的参数 schema 直通、[05 篇](05-permissions.md)讲过的服务器级权限、[06 篇](06-authentication.md)讲过的统一认证管理,这些能力只有走 MCP 这条路才自动具备,自己用 Bash 拼一遍,这些都要从零重新实现一遍,而且大概率实现得没有协议标准做的完善。

## 新建一个 server,还是给已有 server 加一个工具

装了不止一个 MCP server 之后,还会遇到一个更细的问题:新的需求出现时,是新连一个 server,还是在已经连着的某个 server 上加一个工具?

这个判断不属于 Claude Code 这一侧——**Claude Code 只负责连接和暴露,server 内部有多少个工具、怎么组织,是 server 开发者的决定。** 但从使用体验的角度,[05 篇](05-permissions.md)讲的"整个 server 一次性授权"这条能力值得纳入考虑:如果两类能力经常需要放在一起统一授权、统一开关(比如都属于同一套内部系统),归到同一个 server 底下,用户管理起来更省心;如果两类能力的信任级别本来就该分开(一个只读查询,一个能直接改生产数据),拆成两个 server,权限规则才能分得干净——这正是服务器级授权这条能力存在的意义,合并还是拆分,某种程度上就是在决定权限规则将来能写多细。
## 很多个 server 之后,要不要收进 PluginAu











[Skills 系列收尾篇](../skills/10-conclusion.md)提到 Plugin"不提供新的行为层,把已有 Skills、agents、hooks、MCP servers 等组件变成一个有 namespace 与版本的安装单元"——MCP server 本身就在这句话列出的组件里。一个团队如果长期需要同一整套 MCP server(内部 Jira、内部文档、内部部署平台……)加上配套的 Skills,与其让每个人各自在自己的 `.mcp.json` 或用户配置里重复添加,不如打包成一个 Plugin 统一分发、统一升级版本。判断标准跟 Skill 那边完全一致:**单个项目用、不需要共享版本管理,就留在项目或个人配置里;多个仓库都要用同一套,才值得包装成 Plugin。**

## 系列走到这里

从[开篇](01-intro.md)那句"Skill 回答怎么做,MCP 回答能做什么"出发,这个系列一路讲了配置怎样分层合并、连接怎样握手、通道怎样选择、一个工具名字怎样变成 Tool 列表里的一条、权限怎样交给外部规则、认证怎样从一次浏览器授权走到企业免登录、resources 和 elicitation 这两种不那么常被提及的能力,以及 Claude Code 自己反过来当 server 这件事说明的"Tool 定义本来就不特别关心调用者是谁"。这些机制合在一起回答的是同一个问题:**当模型需要一个它出厂时不存在的动作,这个动作可以来自哪里、以什么方式接进来、又该被谁信任。**

## 参考









text Protocol 官方文档:[Introduction](https://modelcontextprotocol.io/introduction)
- [收尾 · 一项能力应该放到哪里](../skills/10-conclusion.md)
- [开篇 · 从"只有内置工具"到"可以外接工具"](01-intro.md)
- [反向角色 · 从 MCP client 到 MCP server](08-reverse-role.md)
