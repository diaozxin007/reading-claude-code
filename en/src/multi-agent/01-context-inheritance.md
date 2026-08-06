## "Mid-task course corrections" — the seam the tool description leaves for itself

In the `Agent` tool's description, there's a line written specifically for **the agent being dispatched**, telling it how to understand the messages it will receive:

> "Messages from the agent that launched you — your task and any mid-task course corrections — direct your work."

"Mid-task course corrections" — this phrase acknowledges something: **after dispatch, the launching side can still send follow-up corrections**. It's not "the task description must be locked in once and for all, with no way to add to it afterward" — the design genuinely leaves room for "changing course mid-stream."

This brings us to the first question left open by the previous piece: **where does context come from** — is the information an agent receives sealed at the moment of the call, or can it keep being appended to as the process unfolds?

## The default answer: nothing at all

The `Agent` tool's description states this quite bluntly. The dispatched agent

> "hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters"

Not "sees part of it" or "sees a summary" — it **sees none of it at all**. It knows nothing about anything that happened before; its only source of information is the task description written into this one call. The tool description follows up with something even more direct:

> "A new Agent call starts a fresh agent with no memory of prior runs, so the prompt must be self-contained."

**Must be self-contained** — these words are the only compensation zero-inheritance design offers to the person using the tool. Since the other side knows nothing, the description given this time has to cover everything at once — what to do, why to do it, which paths have already been ruled out — with no room left for "I'll explain the rest later."

This is also why the tool description reaches for this analogy:

> "Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters."

"A colleague who just walked into the room" — this analogy precisely pins down the consequence of zero inheritance: it's not that the other side lacks ability, it's that **its information set only begins at this moment**. A terse one-line instruction is incomprehensible to someone who just walked in with no context; the tool description makes this point explicitly too:

> "Terse command-style prompts produce shallow, generic work."

The more terse the instruction, the less background the other side can fill in, and the more generic the returned result will be. This isn't the other side "slacking off" — it's **a direct consequence of the zero-inheritance structure itself**. It has nowhere else to draw information from except the text given in this one call.

## To keep talking, you first need to give it a name

Zero inheritance solves the "one-shot delegation" scenario. But the opening line about "mid-task course corrections" points to a different need: **finding the same agent again, rather than spinning up a new one** — actually putting "changing course mid-stream" into practice.

This doesn't rely on the `Agent` tool itself, but on another tool: `SendMessage`. Its usage is simple — specify a target, send a message:

```
{"to": "researcher", "message": "While you're at it, check whether this module uses any already-deprecated interfaces"}
```

The key is what goes into the `to` field. The tool description lists two kinds of targets: one is **a teammate found by name**, the other is the special value `"main"` (covered in a later piece about reporting back). For now, let's look at the "find a teammate by name" path — it corresponds exactly to "finding the same person to keep talking to."

The tool description states this clearly:

> "Refer to agents by name — names keep working after an agent completes (a send resumes it from its transcript)."

"Resumes it from its transcript" — what gets resumed is **the history that agent itself has accumulated**, not the context of the party sending the message. This forms a contrast with the `Agent` tool's requirement to be "self-contained":

- **`Agent` spawning a new one**: zero inheritance, context **built from scratch** using this call's description
- **`SendMessage` finding an existing one**: no rebuilding — it's a matter of **continuing** the history that agent has already accumulated on its own

One is "writing from a blank page," the other is "flipping back to the last page and continuing." Neither of them is "inheriting the context of the party sending the message" — this is a point that's easy to get misled by intuition on, and worth calling out separately: what gets continued is **the target's own** history, not **mine**.

## Addressing by name hides one rule

Finding an agent by name carries an implicit premise: the name must **uniquely** point to one specific agent instance. Tucked into the tool description is a rule that's easy to overlook:

> "Use the raw `agentId` (format `a...-...`) from its spawn result only when the agent has no name, or when a newer agent took the name (latest wins)."

"Latest wins" — if two spawns use the same name, that name will **only point to the most recent** instance; the earlier one becomes unreachable through the name and can only be found again via the raw `agentId` it originally returned. This means a "name" isn't a stable identity — it's more like **a nickname that can be displaced at any time**. As soon as a new agent shows up with the same name, the old one becomes unreachable by name.

This rule explains why `SendMessage`'s usage description specifically emphasizes that "name" and "agentId" are two different addressing paths: names are easy to remember but can be displaced, while `agentId` is stable but requires remembering a generated string. In everyday collaboration, defaulting to names makes sense — only when "the name might no longer point to the one I want" do you fall back to `agentId` as a safety net.

## Messages are pushed to you, not something you go check

Once you've reconnected with an agent, how do you get the reply? There's a line in the tool description that's easy to skim past:

> "Messages from teammates are delivered automatically; you don't check an inbox."

**Delivered automatically, no need to actively check** — this is the exact opposite of the "task management" path mentioned in the previous piece. Recall: the shared task board (the `Task` family) relies on `TaskList`/`TaskGet` to actively **pull** status — if you don't ask, it won't proactively tell you about progress. But this `SendMessage` communication path is **pushed** — the moment a reply arrives, it just shows up, without you having to actively ask "how's it going on your end?"

The same description also draws a boundary around this communication path:

> "Your plain text output is NOT visible to other agents — to communicate, you MUST call this tool."

Text written on my own side is only visible to the user — **other agents can't see it at all**, unless I explicitly call `SendMessage` to pass it along. This is an extension of the same restraint described in the [Context series' message-array invariants](../context-management/02-message-invariants.md): inside a single agent, everything going in and out has to move through explicit message structure — nothing relies on "implicit awareness." Scaled up to between multiple agents, this boundary still holds: **whatever isn't visible must be explicitly sent to become visible.**

## The interface this piece leaves open

At this point, "where does context come from" has two concrete answers:

- **Zero inheritance**: `Agent` spawns a new one, built from scratch on a self-contained description
- **Resumption**: `SendMessage` finds the same one by name, resuming its own history — replies are pushed rather than pulled

But neither path has yet answered one question: **once an agent is resumed, does it still have the same set of tools it had before?** In other words, if the context is resumed, does authority get resumed along with it — that's the question the next piece will answer.

## References

- Primary source this piece is grounded in: the schema descriptions of the `Agent` / `SendMessage` tools (directly readable within the toolset — verified word-for-word; all quotes in the text are verbatim)
- "Mid-task course corrections" was first quoted by [the tools series · Agent piece](../power/agent.md) (that piece approached it from the angle of "information isolation direction"; this piece reuses it from the angle of "how context gets resumed")
- No source-level discovery has been done yet — exactly how "latest wins" implements name override at runtime, and exactly how the transcript is stored for resumption, are left for a future discovery if one becomes available
- Cross-reference: [Three invariants from a single message to the message array](../context-management/02-message-invariants.md) (the message invariants inside a single agent; this piece is their extension across multi-agent boundaries)
