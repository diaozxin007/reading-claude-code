# 05 · Permissions · From Tool-Name Matching to Server-Level Authorization

> **TL;DR**: In the permission rule system, MCP tools get a way of writing rules that built-in Tools don't have — a single rule can apply to an entire server, without needing a separate line for every tool. But in exchange, MCP tools themselves take no part whatsoever in deciding whether a call should go through — they hand that decision entirely to external rules, and if the rules haven't spelled it out in advance, the default is always to ask the user first.

[The previous post](04-tool-exposure.md) left a question hanging: once a renamed MCP tool shows up in the Tool list, can the model just call it whenever it decides to? [Skills series post 07](../skills/07-permissions.md) already walked through the basic shape of permission rules — one rule matches one tool name and decides whether to allow it, deny it, or require confirmation. This post won't repeat that baseline mechanism; it only covers what MCP adds on top of it — and where it deliberately opts out.

## One rule governs an entire server

Ordinary permission rules match on a tool's exact name — one rule corresponds to exactly one tool. As covered in [the previous post](04-tool-exposure.md), an MCP tool's name follows the fixed format `mcp__server__tool`, and that format itself opens a door for permission rules: **a rule can stop at the server level, without naming a specific tool, meaning "every tool under this server gets handled by this rule."**

This isn't a coincidence — it's a capability designed to work hand in hand with the renaming rule and the permission rule. Think back to the Jira scenario from [the opening post](01-intro.md): a Jira MCP server might declare a dozen or so tools — create ticket, query status, add comment, close ticket, and so on. If every tool needed its own permission rule, the cost of installing a new server would be quite high. With server-level rules, a team can state its position once — "this server as a whole is trusted, allow it" or "this server as a whole is off-limits" — without having to enumerate a dozen tool names one by one.

This is a capability that built-in Tools simply don't have at all — Tools like Read and Bash have no notion of a "server," so their rules can only ever match the tool precisely. **It's only because an MCP tool's name naturally carries "ownership" information that this extra layer of rule granularity becomes possible.**

## But MCP tools themselves make no judgment calls at all

This is the single most important point in this post, and it's also where the contrast with built-in Tools is sharpest.

Some built-in Tools do make judgment calls on their own — for instance, a Tool that executes commands might recognize on its own that "this particular command looks safe, no need to ask" — not every case gets unconditionally handed off to the external rule layer. MCP tools work nothing like this: **no matter which server or which tool it's connected to, that portion of an MCP tool's own logic will never say "this call looks fine to me, go ahead and allow it." It hands that judgment over entirely — 100% — to the external rule-matching layer.**

This means whether an MCP tool call ultimately gets allowed depends entirely on whether a rule was written in advance to cover it. If a rule covers it, the rule's verdict stands. If no rule covers it, there's no fallback of "this looks safe, so allow it by default" — instead, it's uniformly converted into **a request for user confirmation**. In other words, after installing a new MCP server, if you haven't written any permission rules for it, every single tool call under it will trigger a confirmation prompt the first time — not because the tool is dangerous, but simply because no rule has made the call on its behalf.

## This is the flip side of what Skills post 07 said

[Skills series post 07](../skills/07-permissions.md) explained that `allowed-tools` doesn't shrink the Tool set — Tools not listed there can still be visible and callable, they just continue to go through the original permission policy. Applied to MCP, this post fills in what that "original permission policy" actually looks like: **no category of tool enjoys a default "looks safe, so allow it" treatment — MCP tools simply carry this rule out to its fullest extent. They don't even attempt to make a judgment on their own; they hand the decision over entirely, full stop.**

This design choice traces back to where MCP tools come from: the behavior of built-in Tools is code the Claude Code team wrote themselves, so the team can be confident about which kinds of operations are generally safe. With an MCP tool, Claude Code has no visibility at all into who implemented it, how rigorously it was implemented, or whether it might carry unexpected side effects — **it doesn't dare make a safety judgment about an external tool whose internals it doesn't understand, so it simply doesn't try. That decision is handed entirely over to rules the user configures themselves.**

## Coming up next

Earlier posts mentioned that connecting to a server sometimes stalls because "authentication is required" — a state categorized separately from an ordinary connection failure. What exactly is this "authentication required" state, and how does it go from stalled to actually connected? The process involves a browser authorization step, and in enterprise settings can even achieve "authenticate once, and every server is logged in — no repeat logins needed." The next post, [Authentication · From a Single Authorization to Login-Free Access Across Multiple Servers](06-authentication.md), picks up from here.

## References

- Model Context Protocol official docs: [Introduction](https://modelcontextprotocol.io/introduction)
- Source code (internal research material, not a public link): `/Users/zhengxindiao/Documents/claude-code-haha` · `src/utils/permissions/permissions.ts` (rule matching, passthrough fallback logic), `src/tools/MCPTool/MCPTool.ts` (checkPermissions is a constant passthrough), `src/services/mcp/mcpStringUtils.ts` (name parsing used for permission matching)
- [Permission Governance · From Callable to Safely Executable](../skills/07-permissions.md)
- [Tool Exposure · From the tools list to an Entry in the Tool List](04-tool-exposure.md)
