## The loose thread from the last piece

The last piece ended with a question: when an agent picks back up through a continuation, is it still holding the same set of tools it started with?

The answer, it turns out, is straightforward — nothing in the `SendMessage` continuation payload lets you re-specify tool permissions. That's not an oversight; it's **structurally unnecessary**. A continuation isn't a re-spawn — it's picking the same instance back up mid-conversation. Permissions get decided exactly once, at the moment of "birth." Continuing just means carrying forward the toolset that was already fixed — there's no second allocation point.

Which pushes the question one step earlier: **how, exactly, do permissions get decided at that moment of birth?**

## Permission isn't discretionary — it's picking a preset bundle

The `Agent` tool has a field called `subagent_type`. It isn't free text — it's a selection from a **pre-registered enum**. Whichever type gets picked comes bundled with a **fixed subset of tools**. This isn't "hand out a few extra permissions on the fly when dispatching a task" — it's "the moment you pick the type, the permissions are already bound to it."

The differences are stark once you lay them side by side. Take something as basic as "can it edit files" — different types give completely different answers:

- Some types get `*` — every tool available, no restrictions
- Some types explicitly **exclude** `Agent` / `Artifact` / `ExitPlanMode` / `Edit` / `Write` / `NotebookEdit` — meaning that class of agent can only read and search. It **can't write, can't edit, and can't spawn further agents**

That last point — "can't spawn further agents" — deserves a second look. Within a `subagent_type`'s tool subset, `Agent` itself is one of the items that can be excluded. In other words, a type's definition can directly decide whether an agent is even eligible to dispatch further work downstream. This isn't a runtime judgment call — it's a **boundary baked in at type-definition time**.

## What a type carries isn't just a tool list — it's a mindset

The preset-type design solves more than the simple question of "can this agent edit files." Each type also ships with its own description of purpose — some types are explicitly framed as "read-only search, for locating code, not for code review or checking design docs against implementation." Others are framed as "designing an implementation plan, not writing the code."

The tool subset and the purpose description travel together. Picking a type is, in a sense, **presetting a mindset** for the dispatched agent. An agent with only read-only tools won't try to "fix this obvious typo while I'm here," because it doesn't have `Edit` in the first place. A type explicitly scoped to "design only, no implementation" will hold back within its own behavioral boundary even if the tools would technically allow more. **Permission restrictions and role definition are two sides of the same choice.**

## Agent calls inside `Workflow` draw from the same registry

Spawning an agent inside a `Workflow` script gets you, by default, a general-purpose toolset meant for running workflows. But if a particular step needs an agent with a specific role — say, "this step should be approached with a code-review mindset" — you can explicitly specify a type. And that type comes from **the exact same registry available through the `Agent` tool**, not some separate list `Workflow` maintains on its own.

Which means the "preset bundle" design isn't a mechanism local to the `Agent` tool — it's **a layer of identity shared across tools**. Whether an agent is dispatched directly through `Agent` or from within a `Workflow` script, selecting the same type name gets you the same tool subset and the same purpose. The type registry is shared infrastructure underneath both paths.

## `Workflow` adds one more layer: connect on demand, not all at once

Agents inside `Workflow` have a capability the `Agent` tool doesn't: they can **connect to already-configured MCP tools in the session at runtime, on demand**, rather than having every potentially useful tool stuffed in at the moment of spawning. The tool description uses phrasing like "schemas load on demand per agent" — each agent decides for itself whether to look something up, and only decides whether to use it once it's found, instead of carrying around a full set of tool definitions it may never touch.

This is an extension of the same thinking covered in the [Skills series on progressive disclosure](../skills/02-progressive-disclosure.md): a Skill starts with a one-line description and only expands into full instructions when needed; here, a tool starts unconnected and only gets looked up and schema-loaded when needed. Both are avoiding the same thing — **information that goes unused shouldn't take up space.**

That said, this on-demand connection layer has one clear exception: if an MCP server requires interactive login to use, it may simply be unreachable in unattended contexts (scheduled jobs, background scripts). On-demand connection solves "don't occupy space if unused" — it doesn't solve the deeper constraint of "requires a human present to connect."

## The interface this piece leaves open

At this point, the question of "permissions" has a concrete answer: a type is a pre-registered bundle, the tool subset follows the type, `Agent` and `Workflow` share the same type registry, and `Workflow` adds an extra layer of on-demand MCP connection.

But permissions only answer "what can it do" — not yet "when do you wait on it, and when do you leave it alone." That's the question for the next piece: foreground or background.

## References

- Primary sources this piece is grounded in: the `Agent` tool's `subagent_type` description, the list of agent types available in the current session (readable directly in the system-reminder), and the `agentType`/MCP-related description of `agent()` inside the `Workflow` tool (readable directly within the toolset — verified word for word)
- No source-level discovery has been done yet — exactly how the type registry is maintained, and the finer timing details of ToolSearch loading, are left for a future discovery pass if one happens
- Material already covered elsewhere, not repeated here: [Tools series · Agent piece](../power/agent.md) (the full discussion of the `subagent_type` field's design)
- Cross-reference: [Progressive Disclosure · From description to full instructions](../skills/02-progressive-disclosure.md) (the same on-demand-loading line of thinking)
