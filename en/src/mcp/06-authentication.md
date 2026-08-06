# 06 · Authentication · From a Single Authorization to Login-Free Access Across Servers

> **TL;DR**: Connecting to a remote MCP server that requires authentication follows the standard browser authorization flow — a temporary local page waits for the callback, stores the token once received, and refreshes it automatically when it expires. In enterprise settings there's also a shortcut: an employee logs in once with their company identity provider, and every internal server they connect to afterward skips authorization entirely.

The [previous post](05-permissions.md) ended with an open question: how does the "requires authentication" connection state mentioned in [post 02](02-connection.md) actually go from stuck to properly connected.

## What's stuck is "requires authentication," not "connection failed"

Back to the five-state machine from [post 02](02-connection.md): when a server is rejected because it lacks access permissions, it isn't lumped into the "connection failed" category — it gets its own dedicated "requires authentication" state. The reason for treating it separately is straightforward: **a connection failure usually means this attempt is dead, while requiring authentication just means "one step remains."** As soon as the authorization flow completes, that server flips from "requires authentication" to "connected" instantly, with no need for the user to reconfigure anything.

A server in the "requires authentication" state doesn't disappear from the tool list entirely — it gets replaced by a special entry dedicated to triggering authorization, referred to in this series as the **auth tool**. What the model sees isn't "this server can't do anything right now," but rather a clearly labeled action saying "call me to complete login," which, once invoked, returns a link to the authorization page. This design makes "requires authentication" something actionable, rather than a wall nobody can touch.

## The standard flow: a trip through the browser, then the token gets stored

The actual authorization follows the industry-standard approach — first, a small local web server spins up temporarily to wait for the callback; the browser opens the authorization page; the user confirms authorization on that page; the page redirects back to this local temporary address, carrying the authorization result. The whole process allows a window of a few minutes to wait; if it times out, the attempt is considered failed and needs to be restarted.

Once the authorization result comes back, the token that actually represents "you're logged in" isn't stored in plaintext in a config file — it goes into the operating system's built-in credential management mechanism, the same one used to store passwords, rather than some separate plaintext file Claude Code manages on its own. The token itself has an expiration date; as it nears expiry, it gets refreshed automatically in the background, with no need for the user to notice, let alone go through the browser authorization flow all over again.

If no browser is available in the current environment (for example, running on a headless server), the flow falls back to manual pasting — the link to the authorization page is handed to the user, who opens it on another device, completes the authorization, and pastes the result back manually.

## Ten internal servers connected, logged in only once

Enterprise settings run into a distinctly different problem: a company might expose several different MCP servers internally at once (an internal ticketing system, internal docs, an internal monitoring dashboard...). If each one required a full browser authorization flow, the experience for employees would be poor — they'd have to log in again every time they connect to a new server.

Claude Code implements a shortcut for exactly this scenario, referred to in this series as **enterprise login-free access** — it relies on the company's unified identity provider (typically the same single sign-on system employees use to log into their corporate account). The idea is: an employee first completes **one** login with the company's identity provider, obtaining a credential that represents "who you are." From then on, each time a new internal MCP server needs to be connected, instead of popping up a browser authorization page again, that credential is used to quietly exchange for a temporary pass granting "access to this specific server" in the background — this exchange goes through two rounds of a standardized token exchange protocol, with no page ever shown to the user. **The only thing the user perceives is that initial login; no matter how many internal servers get connected afterward, none of them interrupt the user again.**

This shortcut isn't enabled by default — it requires an administrator to perform a one-time setup (telling Claude Code the address of the company's identity provider), plus a dedicated switch that must be explicitly turned on. Otherwise, even if a server's configuration specifies "use enterprise login-free access," it won't silently fall back to regular per-server authorization — it fails outright, alerting the administrator that this path hasn't been configured yet. This is a deliberate choice: **either it works explicitly the enterprise login-free way, or it fails outright — no ambiguous middle ground is allowed between configuration and actual behavior.**

## 401 can show up at two different moments

Authentication problems don't only appear at the moment of first connecting. A server that's already connected and has been in use for a while can still hit a permission error if its token becomes invalid mid-session and a tool call is issued — and the handling in that case isn't quite the same as during the handshake phase. An already-established connection gets re-flagged as requiring authentication because of that failed call, rather than letting the call fail silently. Regardless of whether the authentication problem surfaces during the handshake or mid-use, the path presented to the user ends up the same — back to the auth tool, and through the authorization flow again.

## Coming up next

Once a server passes authentication, everything covered so far has been about the "call a tool" path — the model initiates, the server executes, and a result comes back. But MCP's declared capabilities aren't limited to tools. What resources — mentioned back in the [opening post](01-intro.md) — and another capability not yet covered, where the server turns around and asks the user for a bit of information before continuing, actually look like is the subject of the next post: [Resources & Elicitation · From Only Calling to Also Reading and Asking](07-resources-elicitation.md).

## References

- Model Context Protocol official documentation: [Introduction](https://modelcontextprotocol.io/introduction)
- Model Context Protocol specification evolution: [The 2026-07-28 MCP Specification Release Candidate](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/services/mcp/auth.ts` (standard OAuth flow), `src/tools/McpAuthTool/McpAuthTool.ts` (auth tool), `src/services/mcp/xaa.ts`, `xaaIdpLogin.ts` (enterprise login-free access)
- [Connection · From a Single Line of Config to a Handshake](02-connection.md)
- [Permissions · From Tool Name Matching to Server-Level Authorization](05-permissions.md)
