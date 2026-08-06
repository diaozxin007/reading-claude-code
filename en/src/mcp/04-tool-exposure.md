# 04 · Tool Exposure · From tools list to an Entry in the Tool List

> **TL;DR**: When an MCP server says "I have a tool called `create_issue`," Claude Code doesn't just drop that name straight into the Tool list — it renames it first, then wraps it in a shell, turning it into the entry the model actually sees. Renaming avoids collisions; wrapping makes built-in Tools and external Tools look identical to the model.

The [previous piece](03-transport.md) covered how bytes get transmitted. This piece covers what happens after those bytes arrive — how a tool a server declares turns into a Tool the model can actually call.

## Rename First · Preventing a Tool Named Write from Causing Trouble

Suppose you've connected two MCP servers, one called `jira` and one called `linear`, and both happen to have a tool called `create_issue`. If Claude Code dropped both `create_issue` entries into the Tool list as-is, which one would the model call? Worse, if some server happens to have a tool also named `Write` — colliding with a built-in Tool — then when the model calls `Write`, is it trying to read/write a local file, or trigger that external tool?

Claude Code's solution is straightforward: **every tool coming from an MCP server has its name prefixed with which server it came from** — the format is `mcp__` plus the server name plus `__` plus the tool's original name. In the example above, the two `create_issue` tools become two distinct names, one belonging to `jira` and one to `linear`; they no longer collide with each other or get confused with built-in Tools. This renaming rule isn't complicated on its own, but it produces a side effect worth noting up front: **you can tell whether a Tool comes from MCP, and from which server, just by looking at its name** — and the [next piece](05-permissions.md), on the "authorize an entire server at once" permission syntax, relies precisely on this naming pattern.

After renaming, what does this tool look like to the model? **Exactly like a built-in Tool** — same kind of name, same kind of parameter description, appearing in the same Tool list. When the model decides whether to call it, nothing prompts it to ask "is this an MCP tool?" — a point already made in the [opening piece](01-intro.md); this is where it concretely plays out.

## Parameter Descriptions Are Copied Verbatim · Not Redefined

The parameter format for built-in Tools (which fields to pass, what type each field is) is hard-coded by Claude Code itself. MCP tools are different — the parameter format is declared by the server itself, and Claude Code passes it straight through to the model without redefining an equivalent description of its own. The reasoning behind this choice is practical: if Claude Code had to re-understand every new server's parameter structure and translate it into its own format, the cost of adding a new MCP server would be much higher. By passing it through directly, whatever the server declares is exactly what the model sees, and adding a new server requires no code changes on Claude Code's side.

The tool description itself does have a loose upper length limit, beyond which it gets truncated — not to constrain what a server can express, but to keep an overly long description from eating up too much space in the Tool list and crowding out the model's attention when it's deciding which tool to use.

## A Somewhat Counterintuitive Choice: Skipping the Rename

The previous section explained renaming as a way to avoid collisions, but Claude Code also leaves an escape hatch that goes the other way: in certain scenarios, an MCP tool can **keep its original name** with no prefix added — at the cost of genuinely overriding a built-in Tool with the same name. This isn't default behavior; it's an option that has to be explicitly turned on, meant for one specific scenario — an SDK context where you want a custom implementation to fully replace some built-in behavior (say, swapping in your own file-writing logic in place of the default `Write`). Even when the rename is skipped for display purposes, Claude Code still internally remembers which server the tool actually came from — the permission checks discussed in the [next piece](05-permissions.md) rely on this internal record, not on the name the model sees, so the permission rules still apply correctly even when the display name skips the prefix.

## Resource-type Tools · Appearing Only Once

MCP tools mainly handle the tools category of capability mentioned in the [opening piece](01-intro.md), but the resources category (read-only data declared by a server) also needs a way to be exposed to the model — not by having each server spin up its own set of "read resource" tools, but through **a single global pair**: one generic "list resources" tool and one generic "read a specific resource" tool, shared regardless of how many resources-supporting servers you've connected. This design avoids the bloat of "the more servers you connect, the more times the same generic capability gets re-registered." [Piece 07](07-resources-elicitation.md) will cover in detail how these two generic tools work.

## After Connecting · The List Isn't Fixed Once and For All

A server's declared set of tools isn't permanently fixed once the handshake completes — it can change during runtime, say a new tool gets added, or an old one gets retired. When establishing a connection, Claude Code checks whether the server has declared "my tool list may change." If it has, then whenever a change actually happens, Claude Code re-fetches the latest list and replaces that server's old tools, without requiring the user to manually disconnect and reconnect. This mechanism is usually invisible, but it explains a phenomenon that might otherwise be puzzling: within the same session, the tools available from a connected server suddenly increase or decrease by one — not a bug, but a genuine change in the capabilities the other side has declared.

## Connections Are Concurrent · Results Land in Batches

When more than one MCP server is installed, Claude Code doesn't connect to them one at a time in sequence — local subprocesses and remote services each connect concurrently under their own separate concurrency caps, and connection results (tools, resources, channels) don't trigger a Tool list update the instant each connection succeeds. Instead they're accumulated over a short window and applied all at once, in a batch. This "batch, then update" approach is mainly an engineering efficiency consideration and doesn't affect the point of this piece: regardless of how long each server took to connect or in what order, what the model ultimately sees is one single Tool list, named by a consistent rule and formatted uniformly.

## Coming Up Next

A renamed MCP tool showing up in the Tool list doesn't mean the model can call it just by saying so — one of the questions left open in the [opening piece](01-intro.md) was "who approves this?" The renaming rule described in the previous section turns out to be exactly why the next piece's permission logic can grant approval at the granularity of "an entire server, all at once." The next piece, [Permissions · From Tool-name Matching to Server-level Authorization](05-permissions.md), picks up from here.

## References

- Model Context Protocol official documentation: [Introduction](https://modelcontextprotocol.io/introduction)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/mcpStringUtils.ts` (renaming rule), `client.ts` (tool fetching, schema pass-through, resources tool deduplication, list_changed handling), `src/tools/MCPTool/MCPTool.ts` (tool shell template)
- [Transport · From Subprocess to Remote Service](03-transport.md)
