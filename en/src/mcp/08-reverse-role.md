# 08 · Reversed Roles · From MCP Client to MCP Server

> **TL;DR**: The first seven parts of this series have all covered Claude Code as an MCP client — connecting to other people's servers. It can just as well flip that around and act as an MCP server itself, translating its own internal Tool definitions directly into protocol messages and exposing them to other MCP clients over stdio. The fact that this reversal is even possible shows that Tool definitions inside Claude Code were never tightly coupled to "who's calling."

When [the opening piece](01-intro.md) introduced the three roles — host, client, and server — every example had Claude Code playing the client: it connects to someone else's server and pulls their capabilities in. This piece covers the opposite case: **Claude Code can also act as a server itself**, exposing its internal Tools so that other MCP-aware applications can connect to it and call them.

## Same Tool Definition, Different Exit Point

Every Tool inside Claude Code — whether it's a built-in like Read or Bash, or one connected in from an MCP server and re-wrapped as covered in earlier parts of this series — has a parameter spec hardcoded in the codebase. Normally that spec exists for the Agent Loop's own use: when the model initiates a call, the spec is what validates whether the parameters are correct.

When Claude Code turns around and acts as a server, that same spec gets converted into the JSON Schema format required by the MCP protocol, and is handed back — along with the tool's name and description — through a standard `tools/list` response to whatever external client connected in. When that external client requests a call to a given tool, Claude Code locates the corresponding Tool implementation, checks whether it's currently available, validates the parameters, actually executes it, and packages the result back according to the protocol format. **This path reuses exactly the same Tool implementation as when the model initiates a call within a conversation — the only difference is that this time the caller isn't the model, it's another program connecting in from outside.**

The channel this path travels over is the standard stdio covered in [Part 03](03-transport.md) — anything wanting to use a capability Claude Code exposes can just spin it up as an ordinary local MCP server, with no need to know that the "server" behind it is actually an entire Claude Code instance.

## What This Reveals

If Tool definitions inside Claude Code were tightly bound to "the model's conversation loop," turning around to act as a server would require rewriting, from scratch, how every Tool is described, validated, and executed — effectively maintaining two parallel definitions, one for internal use and one for external exposure. But that's not what happens: the same Tool definition, run through a single conversion path, becomes an externally callable MCP tool, with nothing needing to be re-described.

This confirms a background assumption that has surfaced repeatedly in [Part 04](04-tool-exposure.md) and [Part 05](05-permissions.md): **the concept of a Tool inside Claude Code was never particularly concerned with who's calling it** — whether the model initiates the call directly within a conversation, or an external caller connects in via the MCP protocol, at the level of the Tool implementation there's no fundamental difference in how it's handled. Earlier parts described how "an MCP tool connected in ends up looking just like a built-in Tool," and this piece describes how "a built-in Tool can, in turn, be called externally through the MCP protocol" — these are really two directions of the same design stance: **the MCP protocol is just one of many exit points for a Tool, not a parallel system that needs to be maintained separately.**

## A Side the Official Docs Don't Emphasize Much

Worth noting: this reversed role isn't something the official Claude Code documentation — cited throughout this series — puts much emphasis on. The official material focuses more on the direction of "bringing external capabilities into Claude Code," which makes sense since that's the scenario the vast majority of users will actually encounter. Claude Code turning around to act as a server and expose itself serves a much more niche scenario: say, some IDE or other MCP-aware tool that wants to directly reuse a batch of capabilities Claude Code has already implemented, without reinventing the wheel. This point is worth flagging clearly: the role reversal described in this piece is an implementation fact read out of the source code, not a feature the official documentation highlights or that users would typically configure themselves in day-to-day use.

## Coming Up Next

That wraps up a reasonably complete loop on MCP — configuration, connection, transport, tool exposure, permissions, authentication, resources/elicitation, and now Claude Code turning around to act as a server itself. The closing piece returns to the dividing line left open in [the opening piece](01-intro.md), placing MCP back among the concepts of Tool, Skill, and Plugin, and lays out clearly which direction a new capability should actually be built in. Next up: [Closing · Drawing the Boundary with Skills, Tools, and Plugins](09-conclusion.md).

## References

- Model Context Protocol official documentation: [Introduction](https://modelcontextprotocol.io/introduction)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/entrypoints/mcp.ts` (`startMCPServer`, zod→JSON Schema conversion, `tools/list`/`tools/call` handling)
- [Opening · From "Built-in Tools Only" to "Pluggable External Tools"](01-intro.md)
- [Transport · From Subprocess to Remote Service](03-transport.md)
