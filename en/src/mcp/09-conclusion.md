# 09 · Wrap-up · Where MCP Sits Relative to Skills, Tool, and Plugin

> **TL;DR**: MCP already has a place in the decision tree from the [Skills series wrap-up](../skills/10-conclusion.md) — pick it when "the capability comes from an external system or an independent process." This post fleshes out that placement: when to write a brand-new MCP server, when to just add a tool to an existing server, when all you really need is a script inside a Skill, and — once you've installed a bunch of MCP servers — whether to fold them into a Plugin.

Once the [previous post](08-reverse-role.md) finished explaining that Claude Code can be both an MCP client and an MCP server, the mechanisms this series set out to cover have come full circle — from a single config file, to a handshake, to a tool being renamed into the Tool list, to permission checks, to authentication, to resources/elicitation, and finally to acting as a server itself. This wrap-up doesn't introduce any new mechanism; it returns to a more practical question: **when a new capability need shows up, when should you even reach for MCP.**

## First, back to the spot already mapped out in the Skills series

In the decision tree from the [Skills series wrap-up](../skills/10-conclusion.md), the branch "the model is missing an atomic action" splits into three paths:

```text
Model is missing an atomic action?
  ├─ Private, deterministic logic for one Skill → bundled script
  ├─ General local capability → custom Tool / executable
  └─ External system / independent process → MCP Tool
```

This series hasn't re-argued that branch, because it still holds. What actually needed filling in was **how to tell the branches apart** — the part that wrap-up post left for "a dedicated MCP series to expand on later."

## Private script, general Tool, MCP server: three answers to the same question

The three paths really come down to the same judgment call showing up repeatedly: **does this action serve just one place, or will it get reused in many places; does it need to run independently of Claude Code itself.**

A piece of deterministic logic that's only useful inside one particular Skill — say, validating a version-number format according to a project's own rules — doesn't need to become a proper Tool, and definitely doesn't need an MCP server wired up for it. Just write it as a script inside the Skill's folder and let the instructions decide when to run it. The defining trait of this kind of logic is that **it has no independent meaning outside that Skill's context**, so it's not worth exposing as a general-purpose entry point.

If the action gets reused repeatedly across many different tasks, but it's purely local — no independent process needed, no separate authentication needed — that's a job for one of Claude Code's own Tools. There's no need to detour through MCP.

What genuinely belongs in MCP is a capability that lives in **another process, another service** — the Jira example from the [opening post](01-intro.md) is the textbook case: the data lives in someone else's system, authentication has to go through someone else's authorization flow, and whether the capability changes over time isn't up to Claude Code at all. In this case, turning it into an MCP server — rather than having Claude cobble together Bash commands every single time — isn't just about convenience. The direct parameter-schema pass-through covered in [post 04](04-tool-exposure.md), the server-level permissions covered in [post 05](05-permissions.md), the unified authentication management covered in [post 06](06-authentication.md) — these capabilities come automatically only by going through MCP. Stitch it together with Bash yourself, and you'd have to reimplement all of that from scratch, almost certainly less thoroughly than what the protocol standard already provides.

## Spin up a new server, or add a tool to an existing one

Once you've got more than one MCP server installed, a finer-grained question comes up: when a new need arises, do you connect a new server, or add a tool to a server you're already connected to?

That judgment call doesn't belong on Claude Code's side — **Claude Code is only responsible for connecting and exposing; how many tools a server has internally and how they're organized is up to the server developer.** But from a usability standpoint, it's worth weighing against the "authorize the whole server at once" capability covered in [post 05](05-permissions.md): if two categories of capability are frequently authorized and toggled together (say, they both belong to the same internal system), grouping them under the same server makes life easier for whoever manages permissions. If the two categories of capability really should sit at different trust levels — one is read-only queries, the other can directly modify production data — splitting them into two servers is what lets the permission rules stay clean. That's precisely the point of server-level authorization existing at all: merging versus splitting is, in a sense, deciding how fine-grained your future permission rules can get.

## Once you have many servers, should they be folded into a Plugin

The [Skills series wrap-up](../skills/10-conclusion.md) noted that a Plugin "doesn't introduce a new behavioral layer — it turns existing components like Skills, agents, hooks, and MCP servers into a single installable unit with a namespace and a version." MCP servers are among the components listed right there in that sentence. If a team consistently needs the same full set of MCP servers (internal Jira, internal docs, an internal deployment platform...) along with the Skills that go with them, it's better to package them into one Plugin for unified distribution and version upgrades, rather than having everyone repeat the same additions in their own `.mcp.json` or user config. The judgment standard here is identical to the one on the Skills side: **if it's used by a single project and doesn't need shared version management, keep it in the project or personal config; if multiple repos all need the same set, it's worth wrapping into a Plugin.**

## Where the series lands

Starting from the opening line in the [opening post](01-intro.md) — "Skill answers how to do it, MCP answers what can be done" — this series has walked through how configuration layers get merged, how connections handshake, how transports get chosen, how a tool's name turns into an entry in the Tool list, how permissions get handed off to external rules, how authentication goes from a single browser authorization to enterprise SSO, the two lesser-discussed capabilities of resources and elicitation, and finally Claude Code acting as a server itself — which illustrates that "a Tool definition was never all that concerned with who the caller is" in the first place. Put together, these mechanisms answer one single question: **when the model needs an action that didn't exist out of the box, where can that action come from, how does it get wired in, and who ends up trusting it.**

## References

- Model Context Protocol official docs: [Introduction](https://modelcontextprotocol.io/introduction)
- [Wrap-up · Where should a capability live](../skills/10-conclusion.md)
- [Opening · From "only built-in tools" to "tools can be connected externally"](01-intro.md)
- [Reverse role · From MCP client to MCP server](08-reverse-role.md)
