# 03 · Transport · From Subprocess to Remote Service

> **TL;DR**: The MCP protocol specification defines only two standard channels — spinning up a local subprocess, or sending HTTP requests to a remote address. What Claude Code actually supports is a much larger set of types. The extra ones aren't protocol requirements; they're private extensions Claude Code added for its own product scenarios. Drawing this line clearly is what lets you tell "this is how MCP is supposed to work" apart from "this is a choice Claude Code made on its own."

[The previous article](02-connection.md) left a question open: before the handshake can happen, Claude Code first needs to know how to talk to a given MCP server. This "way of talking" — which this series will consistently refer to by the protocol's own term, **transport** — determines how bytes move from one side to the other. That's a separate concern from "what content gets transported" (tools, resources, and so on), which is the subject of [the next article](04-tool-exposure.md).

## The protocol only specifies two

In the Model Context Protocol specification, there are only two standard transports.

One is **stdio**: Claude Code launches the MCP server directly as a subprocess, and the two sides exchange messages over standard input and output — the server reads requests from stdin and writes responses to stdout. This is the lowest-latency option, with no network overhead, and the official documentation calls it the preferred choice for local scenarios. If the Jira server mentioned in the previous article is a small program installed on your own machine, it most likely connects this way.

The other is **Streamable HTTP**: messages are sent as standard HTTP requests, and responses can be streamed back using Server-Sent Events, for use with remote connections. This is the current standard approach — an earlier version of the protocol had a combined "HTTP+SSE" transport, which has since been marked deprecated; new implementations should use Streamable HTTP directly.

Both transports carry the same JSON-RPC message format — this is a deliberate design choice, and the specification explicitly states that "once transport-level details are abstracted away, MCP should look the same over any transport." In other words, whoever writes the server-side code doesn't need to reimplement the protocol logic separately for each transport; the transport's only job is delivering the message, and it has no bearing on what the message itself looks like.

## Claude Code supports far more than that

In Claude Code's connection logic, there are around eight selectable transport types, not two. Beyond stdio and standard HTTP, there's an older protocol version that uses SSE, two variants that use WebSocket, one built specifically for internal SDK scenarios, one built specifically for syncing connectors on the claude.ai web client, and one that skips both networking and subprocesses entirely — a fully "in-process direct connection."

This isn't a documentation error; it's two different things being layered together. **The protocol specification defines the lowest common denominator for "how any client and server in the MCP ecosystem should communicate."** Claude Code, as one concrete client implementation of that protocol, has to handle a broader range of scenarios than that lowest common denominator covers — it has other internal components that need to talk to each other in an MCP-like way, such as browser extensions, IDE extensions, and SDK subprocesses. There's no need to invent a separate protocol for each of these; reusing MCP's message format and connection-management logic is simply more efficient. But the connection method itself isn't a standard channel that an external third-party server would ever use. **Most of these extra transports connect to pieces of Claude Code's own internal ecosystem — they're not options you'd pick when hand-writing a third-party MCP server.**

This distinction is worth remembering because it has practical consequences: if you're writing an MCP server for your own service, the channels you can choose from — the ones the protocol guarantees compatibility for — are just stdio and Streamable HTTP. That's the part you can rely on long-term. As for whichever private transports Claude Code happens to support internally, that's a decision specific to this one client implementation; switch to a different MCP-compatible application, and there's no guarantee it offers the same extensions.

## In-process direct connection: skipping the "channel" step entirely

The most unusual of these private extensions barely fits the literal meaning of "transport" at all — no subprocess, no network request, both sides simply pass messages back and forth within the same process. This connection method is used specifically for integrations that are built into Claude Code itself and don't need to run as truly independent processes (for example, scenarios involving control of browser tabs): the server-side logic actually runs inside Claude Code's own process, just still wrapped in the MCP message format for external presentation, so that upper-layer code doesn't need to care whether a given connection is really an external process or an internal feature — from the perspective of the code using this connection, handling it is no different from connecting to a genuinely external server.

This is precisely what illustrates the point of having a transport abstraction layer at all: **the upper-layer code — how tools are discovered, how they're invoked, how permissions are handled — never needs to know which channel is underneath.** Whether it's stdio, HTTP, or an in-process direct connection, the layer discussed in article 04 — how a tool becomes a Tool — sees exactly the same interface either way.

## Local vs. remote: two different fates after a disconnect

If a connection drops mid-session after the handshake, Claude Code's response differs by transport, and this is worth mentioning up front since the next article, which covers what happens with tools once connected, assumes this background. For servers running as local subprocesses (the stdio category), a drop is final — there's no automatic reconnection, since it's most likely a configuration or environment problem, and retrying wouldn't help. For servers reached via a remote connection, Claude Code automatically retries a few times at fixed intervals before finally giving up — a remote connection is more likely to be suffering from a transient, recoverable issue like network jitter, and it's worth waiting a bit longer.

Underlying this distinction is a fairly intuitive assumption: **a local process crash usually means "something is fundamentally wrong with this connection," while a remote disconnect is more likely to just mean "temporarily unreachable."** Claude Code doesn't treat all transports identically when it comes to retrying — it differentiates based on this assumption.

## Coming up next

Once you're connected, the handshake is done, and the channel is settled, the genuinely interesting questions begin: when a server declares "I have a tool called `create_issue`," how does that name turn into a Tool the model can actually call — does it collide with a built-in Tool, and how does it end up in the list of tools the model sees? The next article, [Tool Exposure: From tools list to an Entry in the Tool List](04-tool-exposure.md), picks up from here.

## References

- Model Context Protocol official documentation: [Transports](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- Claude Code official documentation: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/client.ts` (transport dispatch branch), `src/utils/mcpWebSocketTransport.ts`, `src/services/mcp/InProcessTransport.ts`
- [Connection: From a Line of Config to a Handshake](02-connection.md)
