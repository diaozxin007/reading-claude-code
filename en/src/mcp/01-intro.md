# 01 · Introduction · From "Only Built-in Tools" to "Externally Attachable Tools"

> **TL;DR**: Claude Code ships with a fixed set of built-in Tools — Read, Write, Bash, and the like. MCP (Model Context Protocol) lets it connect to an external process at runtime and treat whatever capabilities that process declares as new Tools. What it solves isn't "how do I reuse a piece of operational knowledge" — that's Skill's problem — but "how do I give the model an action that simply didn't exist when it shipped."

Say you want Claude to check the latest status of a ticket on your company's internal Jira before touching any code.

Claude doesn't have a Tool called `Jira`. All it can do is cobble together a `curl` command via Bash — carrying the API token, the org domain, the ticket ID, hand-assembling the JSON request body, then picking the useful fields out of whatever JSON blob comes back. That can be made to work, but every single time you have to re-explain where the token lives, what the endpoint path looks like, and how the fields should be parsed — the same kind of hassle as "having to re-paste the release checklist over and over" from the [Skill series opener](../skills/00-intro.md), just swapped out for "the specifics of talking to an external system" needing to be re-explained each time.

At this point you might think: why not just write this curl-assembly procedure as a Skill?

You could — but what that installs is the **operational knowledge** of "how to talk to Jira." The set of actions actually available to Claude is still just Bash. Once a Skill unfolds, it still ends by invoking an existing Tool — the [Skill series opener](../skills/00-intro.md) states this plainly: **a Skill doesn't add a new executor, it only orchestrates existing Tools.** If Jira needs session state maintained, pagination handled, and occasionally returns different schemas depending on permissions, relying entirely on Bash to assemble curl calls and parse results on the fly will be noticeably less stable than calling a dedicated action that actually knows what Jira looks like.

What's really missing isn't a set of instructions — it's a **new action**: something like Read or Bash that the model can call directly, with a name, parameters, and a return value. But built-in Tools like Read and Bash are compiled into Claude Code itself — you can't modify that code, and there's no way to make it magically recognize Jira out of thin air.

This is the layer MCP addresses: **how to give the model a new action it didn't ship with, without modifying Claude Code's own code.**

## A Process Willing to Be Connected To — Not a Block of Text to Be Read

A Skill is a folder containing Markdown and a few supporting files; Claude reads it and unfolds it. An MCP server is not a file — it's an **independently running process or service**. It might be a small program on your machine that can read and write the local filesystem, or it might be a server permanently running somewhere on your company's intranet, exposing a declaration along the lines of "here are however many tools, however many pieces of readable data, and however many ready-made prompt templates I offer." This declaration is expressed through a single shared protocol, regardless of what language the process is written in or what machine it runs on — the rest of this series will consistently refer to this kind of process as an **MCP server**.

Claude Code plays the role of the **MCP client** on this side — it's responsible for connecting to a given server, asking "what capabilities do you have," and translating the answer into something Claude understands. When a user talks with Claude Code, they're actually dealing with a broader role: Claude Code itself is the **host** — it can manage several MCP clients at once, connected to several servers simultaneously. These three role names (host / client / server) are the generic terms defined by the Model Context Protocol specification itself, not something Claude Code invented — swap in any other MCP-supporting application (some IDE, some desktop assistant) and the same terminology still holds.

The capabilities an MCP server can declare go beyond just "callable actions." The spec defines three categories, and the rest of this series will use these three names consistently:

- **tools** — callable actions that may have side effects, e.g., "create a Jira ticket." This is what the opening scenario in this piece actually needs, and it's the main thread running through the following articles.
- **resources** — readable, read-only data, e.g., "the current list of tickets." This is a completely different thing from the "resources" in Skill's supporting resources — those are reference documents read on demand from within a folder, while these are external data actively declared by an MCP server, possibly changing in real time. [Article 07](07-resources-elicitation.md) will expand on this.
- **prompts** — ready-made conversation templates pre-written by the server. Used less often than the other two categories, and not a focus of this series.

Installing an MCP server doesn't automatically mean you have all three categories at once — a server might declare only tools and no resources. Claude Code has to ask exactly which categories the other side supports before proceeding, and that "asking first" process gets a dedicated section later on. For now, just remember: **tools/resources/prompts are three distinct things, and shouldn't be conflated.**

## Once Connected, It Looks Just Like an Ordinary Tool

Once an MCP server declares a "create ticket" tool, it doesn't show up in front of Claude carrying some special "external capability" status — it gets renamed, wrapped, and turns into an ordinary entry in the Tool list, sitting right alongside Read and Bash. When the model decides whether to call it, it goes through exactly the same judgment process — no extra layer of special handling just because it "comes from outside."

This is what shapes the questions the rest of this MCP series needs to answer — questions that look similar in shape to the Skill series, but land on entirely different answers:

- **Origin**: Where is an MCP server's configuration written, and how does Claude Code come to recognize it — [Article 02](02-connection.md)
- **Channel**: How exactly do bytes travel between Claude Code and this process — a local subprocess and an intranet server obviously aren't connected to the same way — [Article 03](03-transport.md)
- **Naming**: When a tool called `create_issue` connects, why doesn't it collide with a built-in Tool's name, and how does it end up in the Tool list the model can see — [Article 04](04-tool-exposure.md)
- **Authorization**: When the model wants to call an action that reaches into the company intranet and can create tickets, who should approve that, and can approval be granted at the granularity of "authorize the entire Jira server at once" rather than asking about each tool individually — [Article 05](05-permissions.md)
- **Boundary**: Both MCP and Skill "expand what Claude can do" — so where exactly does responsibility split between them? This piece has already given half the answer; the [closing article](09-conclusion.md) will fill in the rest.

## Drawing the Line with Skill — Said Up Front

The detour at the start of this piece — "should this be written as a Skill instead" — wasn't a digression. That dividing line is worth laying out clearly right at the start of the series, because every article after this one assumes the reader already knows it:

| | What It Solves | What It Ends In |
|---|---|---|
| **Skill** | A worthwhile piece of reusable operational knowledge — what to do first, what to do next depending on what you see | Completed by invoking an **existing** Tool |
| **MCP** | An action the model didn't have when it shipped | **Adding a new** Tool |

The two aren't mutually exclusive — once an MCP server is installed and brings a new Tool along with it, that Tool can absolutely be orchestrated into a workflow by some Skill's instructions. That's exactly the junction that [Skill series Article 06](../skills/06-execution-boundary.md) and this series' [closing article](09-conclusion.md) each approach from opposite sides. For now, one sentence is enough to remember: **Skill answers "how to do it," MCP answers "what can be done."**

## Coming Up Next

An MCP server has to first appear in some configuration before Claude Code even gets the chance to connect to it — and the same server name might simultaneously be written into a project's config, into your own user directory, and also be pushed down centrally by your company. When these three layers of configuration disagree about the same name, Claude Code resolves it with a clearly defined merge order. The next article, [Connection · From One Line of Config to One Handshake](02-connection.md), starts from how this configuration is written, how it's layered, and who wins when there's a conflict — and follows it all the way through to a successful handshake, at which point Claude Code knows exactly which capabilities the other side supports.

## References

- Model Context Protocol official docs: [Introduction](https://modelcontextprotocol.io/introduction)
- Claude Code official docs: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/`, `src/tools/MCPTool/`
- [Introduction · From Repetitive Pasting to Callable Capability](../skills/00-intro.md)
- [Tool Mechanism: How Claude Uses Tools](../tool-mechanism.md)
