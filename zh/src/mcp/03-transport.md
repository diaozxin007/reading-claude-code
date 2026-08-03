# 03 · Transport · 从子进程到远程服务

> **TL;DR**:MCP 协议规范定义的标准通道只有两种——本地拉起一个子进程 · 或者对一个远程地址发 HTTP 请求。Claude Code 实际支持的类型比这多得多,多出来的部分不是协议要求,是 Claude Code 为了自己的产品场景加出来的私有扩展。分清这条线,才知道哪些行为是"MCP 本该如此",哪些是"Claude Code 自己的选择"。

[上一篇](02-connection.md)留了个问题:握手之前,Claude Code 得先知道用什么方式跟这个 MCP server 说话。这个"说话方式"——本系列后文统一沿用协议里的叫法,称为 **transport**——决定的是字节怎么从这一头传到那一头,跟"传过去的内容是什么"(tools、resources 这些)是两件事,后者是[下一篇](04-tool-exposure.md)的主题。

## 协议只规定了两种

Model Context Protocol 的规范文档里,标准 transport 只有两种。

一种是 **stdio**:Claude Code 把 MCP server 当成一个子进程直接拉起来,两边通过标准输入输出传消息——server 从标准输入读请求,往标准输出写响应。这是延迟最低的方式,没有网络开销,官方文档把它称为本地场景的首选。前一篇提到的 Jira server 如果是一个装在你电脑本地的小程序,大概率就是这种连法。

另一种是 **Streamable HTTP**:用标准的 HTTP 请求发消息,响应可以用 Server-Sent Events 流式返回,给远程连接用。这是目前的标准做法——协议早期版本里还有一种"HTTP+SSE"的组合,现在已经被标记为过时,新实现应该直接用 Streamable HTTP。

两种 transport 传的都是同一套 JSON-RPC 消息格式——这一点是刻意设计的,规范文档明确说"抽象掉通信细节之后,MCP 在任何 transport 上都应该长一个样"。换句话说,server 那头写代码的人不需要为每种 transport 单独实现一遍协议逻辑,transport 只负责把消息送到,不影响消息本身长什么样。

## Claude Code 支持的比这多

到 Claude Code 的连接逻辑里,实际能选的 transport 类型有八种左右,而不是两种。除了 stdio 和标准 HTTP,还有走 SSE 的旧协议版本、走 WebSocket 的两种变体、专给内部 SDK 场景用的一种、专给 claude.ai 网页端连接器同步用的一种,再加一种完全不走网络也不起子进程的"进程内直连"。

这不是文档写错了,是两件不同的事被叠在了一起看:**协议规范定义的是"MCP 生态里任何 client 和 server 之间该怎么通信"的最小公约数**,Claude Code 作为其中一个具体的 client 实现,要处理的场景比这个最小公约数宽——它自己内部还有别的组件需要用类似 MCP 的方式互相说话,比如浏览器插件、IDE 扩展、SDK 子进程,这些场景没必要每个都另起一套协议,复用 MCP 的消息格式和连接管理逻辑更省事,但连接方式本身就不是外部第三方 server 会用到的标准通道。**多出来的那几种 transport,连的大多是 Claude Code 自己生态内部的东西,不是给你手写一个第三方 MCP server 时会去选的选项。**

这条区分线值得记住的原因很实际:如果你在给自己的服务写一个 MCP server,能选的、协议保证兼容的通道就是 stdio 和 Streamable HTTP 这两种——这是能长期依赖的部分。至于 Claude Code 内部还支持哪些私有 transport,是 Claude Code 这一个 client 实现的具体选择,换一个支持 MCP 的应用,不见得会有同样的扩展。

## 进程内直连:连"通道"这一步都省了

私有扩展里最特殊的一种,连 transport 的字面意思都不太符合——没有子进程,没有网络请求,两头直接在同一个进程里互相塞消息。这种连法专门用在 Claude Code 自己内建、不需要真正独立运行的集成上(比如控制浏览器标签页这类场景):server 端的逻辑其实就跑在 Claude Code 自己的进程里,只是仍然裹着一层 MCP 的消息格式对外呈现,好让上层代码不用关心"这次连的到底是外部进程还是内部功能"——对使用这个连接的代码来说,处理方式和连一个真正的外部 server 没有区别。

这恰好说明了 transport 这层抽象存在的意义:**上层代码(怎么发现工具、怎么调用、怎么处理权限)完全不需要知道底下走的是哪种通道。** 换成 stdio、换成 HTTP、还是换成进程内直连,04 篇要讲的"工具怎么变成 Tool"这一层看到的都是同一套接口。

## 本地和远程 · 断线之后的两种命运

握手之后如果连接中途断了,Claude Code 的处理方式因 transport 而不同,这一点值得提前说,因为下一篇讲连上之后的工具会默认这个背景。走本地子进程(stdio 这一类)的 server,断了就是断了,不会自动重连——大概率是配置或环境本身有问题,重试没有意义。走远程连接的 server,断了会按固定的时间间隔自动重试几次,超过次数才彻底放弃——远程连接更可能是网络抖动这种可恢复的问题,值得多等一等。

这条区分背后是一个不难理解的假设:**本地进程崩溃通常意味着"这次连接从根上就有问题",远程连接中断更可能只是"暂时联系不上"。** Claude Code 没有对所有 transport 一视同仁地重试,而是按这个假设区别对待。

## 下一篇预告

连上、握手完、也确定了走哪条通道之后,真正有意思的问题才开始:server 那头声明"我有一个叫 `create_issue` 的工具",这个名字怎么变成模型手里能调用的一个 Tool——它会不会跟内置的 Tool 撞名,又是怎么出现在模型看到的那份工具列表里的。下一篇 [工具暴露 · 从 tools list 到 Tool 列表里的一条](04-tool-exposure.md) 从这里接着讲。

## 参考

- Model Context Protocol 官方文档:[Transports](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- Claude Code 官方文档:[Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- 源码(内部调研素材,非公开链接):`/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/client.ts`(transport 判别分支)、`src/utils/mcpWebSocketTransport.ts`、`src/services/mcp/InProcessTransport.ts`
- [连接 · 从一行配置到一次握手](02-connection.md)
