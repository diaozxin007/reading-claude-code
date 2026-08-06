# 02 · Connection · From a Single Config Line to a Handshake

> **TL;DR**: An MCP server has to appear in some configuration before Claude Code has any chance of connecting to it. Configuration comes in four layers — enterprise-issued, project-shared, user-global, and single-project-private. When names collide, the later layer overrides the earlier one, and once an enterprise configuration exists, it takes over exclusively and the other three layers stop working entirely. And being connected doesn't mean being usable right away — first comes a handshake to confirm the other side is alive and to find out what it supports.

Where should that Jira server from the [previous post](01-intro.md) be written so that Claude Code actually recognizes it?

The answer isn't a single location — it depends on who's going to be using this server.

## Same Name, Four Different Owners

Suppose a company provides a single MCP server that connects to an internal Jira instance. Everyone on the team needs to use it, but nobody's API token should end up on anyone else's machine — and this is exactly the first problem MCP server configuration needs to solve: **the same capability may need different private information for different people using it, but the server's connection details themselves — which protocol to use, which address to connect to — should only need to be written once.**

Claude Code places configuration in four different locations — this series will refer to them collectively as four kinds of **scope**:

- **project** — written into a file called `.mcp.json` at the project root. This file can be committed to git, so everyone on the team who clones the repo can see "this project needs to connect to the Jira server." The address and startup method are hardcoded in there, but it contains no one's private tokens.
- **user** — written in your own user-level configuration, effective across every project you open. Good for servers you personally use often and that aren't tied to any specific project.
- **local** — also written in your own user-level configuration, but effective only for one specific project, and won't show up in any other project you open. In the team scenario above, this is where the "private token" should go — the shared `.mcp.json` only declares "we need to connect to Jira here," and your own local configuration adds your own token; only the combination of the two produces a configuration that can actually connect.
- **enterprise** — issued centrally by a company administrator, not present in any individual's or project's configuration files, and not something ordinary users can modify.

Beyond these four layers, there are two sources worth noting even though they don't come up often: servers specified temporarily on the command line (effective only for that one session, never written to any config file), and connectors you've already set up on the claude.ai web app (which sync with Claude Code). These two don't participate in the layered merge logic described below — they're independent, additive lines. It's worth flagging this upfront so it doesn't look like a gap in the matrix later on.

## Who Wins on Conflict

If project, user, and local all mention a server with the same name, the merge order is fixed: **local overrides project overrides user**. Looking back at the team scenario above, this order isn't arbitrary — it guarantees that "the connection method the team shares" always stays as the baseline, while "your own private additions" always get the final say. This avoids the counterintuitive situation where "the team updates the shared config, but it gets overwritten by some old local config you set up long ago."

**Enterprise doesn't participate in this merge — it's exclusive.** As long as a company administrator's configuration exists, Claude Code will only use the servers listed in that configuration; anything written in the project/user/local layers simply has no effect. This is a different mechanism from "who overrides whom" — merging is competition within the same tier, decided by priority, while enterprise simply shuts off the other three layers entirely. For an individual user, this means that if a server you configured suddenly stops connecting and doesn't show up in `/mcp` either, the first question to ask is "did the company just roll out a managed configuration," not "did I mess up my `.mcp.json`."

Project scope has one more gate that local/user don't: **a confirmation prompt on first use**, listing the command and arguments about to be connected to for you to review, with an option to allow or deny. This gate applies only to project scope, and the reasoning isn't hard to follow — `.mcp.json` gets cloned along with the project, so if the connection command written inside it has a problem (whether malicious or just a misconfiguration), you should take a look before actually running it. The user/local layers, by contrast, are maintained by you yourself, so they naturally don't need this "review external content before letting it in" step.

## After Configuration, Still Need to Connect and Shake Hands

Configuration only declares "there should be a server here" — actually establishing the connection comes next. Internally, Claude Code describes each server's current stage using a five-state model: **connected, failed, needs authentication, connecting, disabled**. Authentication failure is kept as its own separate category rather than being lumped in with plain failure, because the handling is completely different — [Post 06](06-authentication.md) will go into detail on exactly how that path unfolds. For now, just remember that "can't connect" and "connected but not authorized" are two different things, and Claude Code keeps them clearly distinct.

The handshake process itself involves two layers of waiting, with very different amounts of patience given to each. **Establishing the connection** — the step from "deciding to connect" to "confirming the other side has responded" — gets a relatively short window; if there's no response within tens of seconds, it's judged a failure. **A single tool call**, on the other hand — once the connection is established and the model actually issues a call and waits for the result — gets a timeout that's close to unlimited. This contrast is intentional: if the connection-establishment process itself stalls, it's most likely because the address is wrong or the process never started at all, and waiting longer won't help. But how long a single tool call takes depends entirely on what the server is doing on its end — it might be a quick query, or it might be a batch job that takes a long time to run. Setting a short timeout upfront would only interrupt calls that would otherwise have succeeded.

Once connected, Claude Code doesn't assume the other side supports every capability — it first asks, "which of tools, resources, and prompts do you actually support?" This step is called **capability negotiation** — both sides declare what they support, and the intersection is taken; every subsequent action has to check against the outcome of this negotiation. A server that hasn't declared support for tools won't even be asked what tools it has. A server that hasn't declared support for resources won't have the resource-reading feature discussed in [Post 07](07-resources-elicitation.md) enabled for it either. This is consistent with the design orientation of the MCP protocol itself — it doesn't require every server to implement every capability; the negotiation mechanism ensures Claude Code only uses the parts the other side has actually declared support for.

A server only counts as truly "connected" once the handshake succeeds and capability negotiation completes. But being connected isn't the same as being usable — the connected state just means the channel is now available. Whether the model actually gets a new Tool out of it depends on which channel Claude Code uses to talk to the other side, and how it turns whatever the other side hands back into a usable Tool — and that's what the next two posts cover.

## Coming Up Next

This handshake step assumes something by default: that Claude Code already knows what mode of conversation to use with this process — whether to launch it directly like a subprocess, or to talk to it over HTTP like visiting a website. This choice of "what mode of conversation to use" turns out to have several possible answers, and there's a gap between what the official protocol specifies as standard practice and what Claude Code actually supports — a gap worth unpacking on its own. The next post, [Transport · From Subprocess to Remote Service](03-transport.md), picks up from here.

## References

- Claude Code official docs: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- Model Context Protocol official docs: [Introduction](https://modelcontextprotocol.io/introduction)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/config.ts` (scope merging and approval), `client.ts` (connection state machine, timeouts, capability negotiation)
- [Opening · From "Only Built-in Tools" to "Tools Can Be Attached Externally"](01-intro.md)
