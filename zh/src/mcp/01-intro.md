# 01 · 开篇 · 从"只有内置工具"到"可以外接工具"

> **TL;DR**:Claude Code 出厂只带 Read、Write、Bash 这些固定的内置 Tool。MCP(Model Context Protocol)让它在运行时连上一个外部进程 · 把那个进程声明的能力当成新的 Tool 用。它解决的不是"怎么复用一段操作知识"——那是 Skill 的问题——而是"怎么让模型拿到一个它出厂时压根不存在的动作"。

你想让 Claude 在动手改代码之前 · 先看一眼公司内部 Jira 上这张工单的最新状态。

Claude 没有一个叫 `Jira` 的 Tool。它能做的只是用 Bash 拼一条 `curl` · 带上 API token、组织域名、工单 ID · 自己拼 JSON 请求体 · 再把返回的一大坨 JSON 挑出有用字段。这件事能做成 · 但每次都要重新交代一遍 token 放在哪、接口路径长什么样、字段该怎么解析——跟 [Skill 系列开篇](../skills/00-intro.md)里"发布检查清单要反复重新粘贴"是同一类麻烦,只是换成了"跟外部系统对话的具体做法"要反复重新交代。

这时候你可能会想:那把这套 curl 拼装步骤写成一个 Skill 不就好了?

能写 · 但装的是"怎么跟 Jira 说话"这份**操作知识** · Claude 手里可用的动作还是只有 Bash 一个。Skill 展开之后 · 终点仍然是调用已有的 Tool——[Skill 系列开篇](../skills/00-intro.md)把这句话写得很直接:**Skill 不新增 executor · 只编排已有 Tools。** 如果 Jira 那头需要维护会话状态、处理分页、时不时因为权限不同返回不同 schema · 全靠 Bash 里现拼 curl 现解析 · 稳定性会比"调用一个专门知道 Jira 长什么样的动作"差一截。

真正缺的不是一份操作说明 · 是一个**新的动作**——一个像 Read、Bash 那样、模型能直接调用、有名字有参数有返回值的东西。但 Read、Bash 这些内置 Tool 是编进 Claude Code 本体里的 · 你改不了它的代码 · 也没法凭空让它认识 Jira。

MCP 解决的就是这一层:**怎样在不改 Claude Code 本体代码的前提下 · 让模型拿到一个它出厂时不存在的新动作。**

## 一个愿意被连接的进程 · 而不是一段被读取的文本

Skill 是一个文件夹 · 里面是 Markdown 和几个辅助文件 · Claude 读它、展开它。MCP 服务器不是文件 · 是一个**独立运行的进程或服务**——可能是你电脑上一个能读写本地文件系统的小程序 · 也可能是公司内网一台常驻服务器 · 对外提供"这里有几个工具、几份可读数据、几条现成的 prompt 模板"这样的声明。这份声明用同一套协议表达 · 不管这个进程是用什么语言写的、跑在哪台机器上——本系列后文统一把这类进程称为 **MCP server**。

Claude Code 这一侧扮演的角色叫 **MCP client** ——它负责连上某个 server、问它"你有什么能力"、把答案翻译成 Claude 认识的东西。用户在跟 Claude Code 对话时 · 实际上是在跟一个更大的角色打交道:Claude Code 本身叫 **host** ——它可以同时管理好几个 MCP client、同时连着好几个 server。这三个角色名字(host / client / server)是 Model Context Protocol 规范里定义的通用叫法 · 不是 Claude Code 自造的概念 · 换成别的支持 MCP 的应用(某个 IDE、某个桌面助手)· 同一套术语依然成立。

MCP server 能声明的能力不止"可调用的动作"一种。规范定义了三类 · 本系列后文统一用这三个名字:

- **tools** ——可以被调用、可能带副作用的动作,例如"创建一个 Jira 工单"。这是本篇开头那个场景真正需要的东西,也是后面几篇的主线。
- **resources** ——可以被读取的只读数据,例如"当前工单列表"。跟 Skill 里的 supporting resources 是完全不同的两个"resources"——那是文件夹里按需读取的参考文档,这里是 MCP server 主动声明、可能实时变化的外部数据,[07 篇](07-resources-elicitation.md)会展开。
- **prompts** ——server 预先写好、可以直接拿来用的对话模板,用得比前两类少,不是本系列的重点。

三类能力不是装了一个 MCP server 就全部具备——一个 server 可以只声明 tools、不声明 resources,Claude Code 连上去之后要先问清楚对方到底支持哪几类,这个"先问清楚"的过程后面会有专门篇幅展开,这里只需要知道:**tools/resources/prompts 是三种不同的东西,不能混着说。**

## 连上之后 · 长得像一个普通 Tool

一个 MCP server 声明了"创建工单"这个 tool 之后,它不会以"外部能力"这种特殊身份出现在 Claude 面前——它会被改名、包装,变成 Tool 列表里普通的一条,和 Read、Bash 排在一起,模型选择要不要调用它时,走的是同一套判断逻辑,不会因为它"来自外部"而多一层特殊处理。

这一点决定了 MCP 系列接下来要回答的问题,跟 Skill 系列问题的形状很像,但答案完全不同:

- **来源**:一个 MCP server 的配置写在哪、怎样才会被 Claude Code 认到——[02 篇](02-connection.md)
- **通道**:Claude Code 跟这个进程之间的字节到底怎么传——本地子进程和一台内网服务器显然不是同一种连法——[03 篇](03-transport.md)
- **命名**:一个叫 `create_issue` 的 tool 连上来之后,为什么不会跟内置 Tool 撞名,又是怎样出现在模型能看到的 Tool 列表里——[04 篇](04-tool-exposure.md)
- **授权**:模型想调用一个连接公司内网、能创建工单的动作,这件事该由谁批准、批准粒度能不能做到"整个 Jira server 一次性放行"而不是一个个工具单独问——[05 篇](05-permissions.md)
- **边界**:同样是"扩展 Claude 能做的事情",MCP 和 Skill 到底谁负责什么——本篇已经先给出一半答案,[收尾篇](09-conclusion.md)会把另一半说完整

## 跟 Skill 的分界 · 提前说清楚

这篇开头绕了一圈"要不要写成 Skill",不是为了岔开话题,是因为这条分界线值得在系列一开始就摆清楚,后面每一篇都会默认读者已经知道:

| | 解决什么 | 终点是什么 |
|---|---|---|
| **Skill** | 一套值得复用的操作知识——先做什么、看到什么再做什么 | 调用**已有的** Tool 完成 |
| **MCP** | 模型出厂时没有的一个动作 | **新增一个** Tool |

两者不互斥,一个 MCP server 装好之后带来的新 Tool,完全可以被某个 Skill 的 instructions 编排进流程里——这正是 [Skill 系列 06 篇](../skills/06-execution-boundary.md)和本系列 [收尾篇](09-conclusion.md)会分别从两侧碰到的同一个交界处。这里先记住一句话就够:**Skill 回答"怎么做" · MCP 回答"能做什么"。**

## 下一篇预告

MCP server 要先出现在某个配置里,Claude Code 才有机会去连它——同一个 server 名字,可能同时被写在项目里、写在你自己的用户目录下、还可能由公司统一下发,三份配置遇到同一个名字该听谁的,是 Claude Code 用一套明确的合并顺序解决的问题。下一篇 [连接 · 从一行配置到一次握手](02-connection.md) 从这份配置怎么写、怎么分层、遇到冲突谁赢开始,一路跟到握手成功、Claude Code 知道对方支持哪些能力为止。

## 参考

- Model Context Protocol 官方文档:[Introduction](https://modelcontextprotocol.io/introduction)
- Claude Code 官方文档:[Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- 源码(内部调研素材,非公开链接):`/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/`、`src/tools/MCPTool/`
- [开篇 · 从重复粘贴到可调用能力](../skills/00-intro.md)
- [Tool 机制:Claude 怎么用工具](../tool-mechanism.md)
