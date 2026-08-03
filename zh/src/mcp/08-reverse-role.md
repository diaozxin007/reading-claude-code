# 08 · 反向角色 · 从 MCP client 到 MCP server

> **TL;DR**:前七篇讲的都是 Claude Code 当 MCP client、连别人。它同样可以反过来当 MCP server——把自己内部的 Tool 定义原样转成协议消息,通过 stdio 暴露给别的 MCP client 调用。能这样反过来用,说明 Tool 的定义在 Claude Code 内部本来就没有跟"谁来调用"绑死。

[开篇](01-intro.md)把 host、client、server 三个角色分开介绍时,举的例子里 Claude Code 一直扮演 client——它连别人的 server,把别人的能力接进来用。这一篇要说的是反过来的情况:**Claude Code 也可以自己当一次 server**,把内部的 Tool 暴露出去,让别的支持 MCP 的应用连它、调用它。

## 同一份 Tool 定义,换一个出口

Claude Code 内部每个 Tool(不管是 Read、Bash 这些内置的,还是本系列前几篇讲的从 MCP server 连进来又被重新包了一层壳的)都有一份用代码写死的参数规格。这份规格平时的用途是给 Agent Loop 自己用——模型发起调用时,靠它校验参数对不对。

当 Claude Code 反过来当 server 用的时候,同一份规格会被转换成 MCP 协议要求的 JSON Schema 格式,连同工具名字、用途说明一起,通过标准的 `tools/list` 响应吐给外部连过来的 client。外部 client 请求调用某个工具时,Claude Code 这一侧找到对应的 Tool 实现、检查它当前是否可用、校验参数,然后真正执行,把结果按协议格式包回去。**走的这条路径,跟模型自己在对话里发起一次调用,复用的是同一套 Tool 实现——区别只在于这次发起调用的不是模型,是外部连过来的另一个程序。**

这条路径走的通道是[03 篇](03-transport.md)讲过的标准 stdio——外部想用 Claude Code 暴露出来的能力,把它当成一个普通的本地 MCP server 拉起来就行,不需要知道这个"server"背后其实是一整个 Claude Code。

## 这说明了什么

如果 Tool 的定义在 Claude Code 内部是跟"模型对话循环"死死绑在一起的东西,想要反过来当 server 用,得单独再写一遍每个 Tool 该怎么描述、怎么校验、怎么执行——等于维护两份重复的定义,一份给内部用,一份给对外暴露用。但实际情况不是这样:同一份 Tool 定义,一条转换路径就能变成外部可调用的 MCP 工具,不需要谁额外重新描述一遍。

这反过来印证了[04 篇](04-tool-exposure.md)和[05 篇](05-permissions.md)里反复出现的一个背景假设:**Tool 这个概念在 Claude Code 内部本来就不特别关心调用者是谁**——不管是模型在对话里直接发起,还是通过 MCP 协议从外部连进来调用,落到 Tool 实现这一层,处理方式没有本质区别。前几篇讲的"MCP 工具连进来之后长得跟内置 Tool 一样",和这一篇讲的"内置 Tool 反过来也能通过 MCP 协议被外部调用",其实是同一个设计取向的两个方向:**MCP 协议只是 Tool 众多出口里的一个,不是一套需要单独维护的平行体系。**

## 官方文档不太强调的一面

值得提一句,这个反向角色不是本系列前几篇一直引用的官方 Claude Code 文档着重介绍的内容——官方材料更多聚焦在"怎么把外部能力接进 Claude Code"这个方向,毕竟这是绝大多数用户实际会用到的场景。Claude Code 反过来当 server 暴露自己,服务的是更小众的场景:比如某个 IDE 或者别的支持 MCP 的工具,想直接复用 Claude Code 已经实现好的一批能力,不用重新造轮子。提这一点是为了标注清楚:本篇讲的角色互换,是从源码里读到的实现事实,不是官方文档重点介绍、用户日常会主动配置的功能。

## 下一篇预告

到这里,MCP 从配置、连接、transport、工具暴露、权限、认证、resources/elicitation,一路讲到 Claude Code 自己反过来当 server——一个相对完整的闭环讲完了。收尾篇要回到[开篇](01-intro.md)留下的那条分界线,把 MCP 放回 Tool、Skill、Plugin 这几个概念中间,说清楚一件新能力到底该往哪个方向做。下一篇 [收尾 · 与 Skills Tool Plugin 的边界收束](09-conclusion.md)。

## 参考

- Model Context Protocol 官方文档:[Introduction](https://modelcontextprotocol.io/introduction)
- 源码(内部调研素材,非公开链接):`/Users/zhengxindiao/Documents/claude-code-haha` · `src/entrypoints/mcp.ts`(`startMCPServer`、zod→JSON Schema 转换、`tools/list`/`tools/call` 处理)
- [开篇 · 从"只有内置工具"到"可以外接工具"](01-intro.md)
- [Transport · 从子进程到远程服务](03-transport.md)
