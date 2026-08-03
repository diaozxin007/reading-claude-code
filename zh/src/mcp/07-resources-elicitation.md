# 07 · Resources & Elicitation · 从只能调用到能读能问

> **TL;DR**:MCP server 能提供的不止"可调用的动作"。它还能声明一批可以直接读的只读数据——resources,不需要为每个 server 单独造一套读取工具,Claude Code 全局共用一份。它也能在一次调用中途反过来向用户要一点信息才能继续——elicitation,这是协议里还在快速演进的一块。

前六篇几乎都在讲同一件事:模型调用一个工具,server 执行,返回结果。这是[开篇](01-intro.md)提过的三类能力里最常用的一类——tools。这一篇讲另外两类:可以直接读的数据,以及 server 反过来向用户要信息的机制。

## Resources:不是"调用",是"读取"

一份 Jira 工单列表、一份内部文档、一张监控面板的当前快照——这些东西不需要每次都靠模型精心构造一次工具调用的参数才能拿到,它们更像是"摆在那儿,需要的时候直接读"。这正是 **resources** 这类能力要解决的:server 声明一批可以被读取的只读数据,Claude Code 不用像调用 tools 那样传参数、等执行,而是直接按一个标识把内容取回来。

[04 篇](04-tool-exposure.md)提过,处理 resources 的入口是全局共用的两个工具——一个负责"列出某个 server(或全部 server)当前有哪些资源可读",一个负责"按标识读取某一份具体内容"——不是每接一个新 server 就多注册一套读取逻辑,这两个通用工具处理所有支持 resources 的 server。这个设计跟[04 篇](04-tool-exposure.md)讲的"tools 各自保留原样、只改名字"是不同的处理策略:tools 强调"每个都不一样,原样保留";resources 强调"读取这个动作本身是通用的,没必要重复造"。两者的差异反映了它们的本质区别——tools 的价值在于每个工具做的事情各不相同,resources 的价值在于内容本身,读取这个动作是标准化的。

读到的内容不总是纯文本。如果一份资源本身是图片、PDF 这类二进制内容,Claude Code 不会把它原样塞进模型能看到的上下文——那样一份不大的 PDF 编码成文本也会占用大量 token。它会把二进制内容单独存成一个文件,回传给模型的是一句"内容已保存到这个路径"外加简短描述,后续如果真的需要用到这份内容,走的是文件读取而不是直接塞进对话。这跟[Context 系列](../context-management/00-intro.md)反复强调的"更省 context 的那条路径优先"是同一种取向的延伸。

## Elicitation:调用中途,反过来问一句

有些工作没法一次性把所有信息都准备齐全再发起调用。比如要求填一张表单、要求跳到浏览器完成一次身份验证、或者单纯是某个必填参数模型这一轮拿不准该填什么——这时候 server 需要一种方式,在处理一次调用的中途,反过来向用户要点东西,拿到之后再继续把这次调用跑完。这类能力叫 **elicitation**。

支持这件事,首先要在握手阶段就说清楚"我这个 client 支持被反问"——[02 篇](02-connection.md)讲的能力协商在这里再次出现:Claude Code 连接时会主动声明自己具备 elicitation 能力,没声明这一条的连接,server 想反问也没有地方问。声明之后,真正弹出来问用户的形式有两种:一种是直接在界面里展开一份表单让用户填;另一种是给用户一个链接,让用户跳到浏览器里完成(比如一次需要图形界面的身份确认),完成后再回来接着跑。

值得单独提一句的是,Claude Code 在真正弹出界面之前,会先看有没有用户自己配置好的程序化规则可以直接给出答案——如果有,elicitation 会被静默应答,用户完全不会看到弹窗。这一层不是协议规定的行为,是 Claude Code 自己加的一道"能自动化就不打扰用户"的短路机制,跟前几篇反复出现的取向一致:凡是能提前用规则说清楚的事情,就不必每次都问一遍人。

## 这是协议里还在变形的一块

Elicitation 是 MCP 协议里相对年轻的一部分——最早的协议版本里没有,是后来的版本才加进来。而且加进来之后也没有停在原地:后续版本对 elicitation 具体怎么工作又做了一次改造,把原本"server 发起请求后一直占着一条连接等用户回应"的做法,改成了更适合无状态场景的"server 把'还需要什么信息'连同一份状态一起返回,client 收集好答案后带着这份状态重新发起调用",这样中途接手这次请求的可以是任意一个 server 实例,不需要一直占用同一条连接。

提这一点是想说明:elicitation 不是一个已经定型很久、细节稳定的能力,本篇讲的"两种展现形式 + 程序化短路"是 Claude Code 当前实现依据的协议版本呈现的样子,协议本身仍在往更适合大规模部署的方向调整,具体交互细节比本系列其他篇章涉及的机制更容易在后续版本里变化。

## 下一篇预告

前七篇都在讲 Claude Code 作为 MCP client 的角色——连别人、用别人的能力。但 Claude Code 同时也可以反过来,自己变成一个 MCP server,把内部的 Tool 暴露给别的 MCP client 调用。下一篇 [反向角色 · 从 MCP client 到 MCP server](08-reverse-role.md) 从这个角色互换讲起。

## 参考

- Model Context Protocol 官方文档:[Introduction](https://modelcontextprotocol.io/introduction)
- Model Context Protocol 规范演进:[The 2026-07-28 MCP Specification Release Candidate](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
- 源码(内部调研素材,非公开链接):`/Users/zhengxindiao/Documents/claude-code-haha` · `src/tools/ListMcpResourcesTool/`、`src/tools/ReadMcpResourceTool/`、`src/utils/mcpOutputStorage.ts`(二进制内容落盘)、`src/services/mcp/elicitationHandler.ts`、`src/utils/mcp/elicitationValidation.ts`
- [工具暴露 · 从 tools list 到 Tool 列表里的一条](04-tool-exposure.md)
- [连接 · 从一行配置到一次握手](02-connection.md)
