## Dispatch and Then: Wait in Place, or Go Do Something Else?

The previous piece covered permissions — what tools a dispatched agent can actually use. But right after choosing a type and hitting "dispatch," a more basic question comes up immediately: **do I need to stand here and wait for it to finish?**

## A Default Flipped on Its Head

The `Bash` tool has a `run_in_background` option, and its description says the setting must be set to true for the command to run in the background — leave it alone, and the default is to wait in place until the command finishes and get the result immediately. That matches intuition: most commands wrap up in a few seconds, so waiting a moment is no big deal.

The `Agent` tool has a field with the same name, but the default is inverted:

> "Agents run in the background by default; you will be notified when one completes. Set to false to run this agent synchronously when you need its result before continuing."

**The default is background** — once dispatched, there's no need to wait in place; a notification arrives once the work is done. Only when it's clear that "the next action can't proceed without this result" should the setting be manually flipped back to foreground.

This inversion isn't arbitrary. `Bash` commands usually finish within seconds, so waiting in the foreground costs almost nothing; `Agent`, by nature, corresponds to multi-step, cross-file tasks that were always going to take a while. Defaulting to background lets that waiting time be filled with other work instead of being burned idle. **The default value itself is making the judgment call — "how long does this kind of task usually take" — on behalf of the user.**

## One Rule: No Fabricating Results While Something Runs in the Background

Backgrounding by default introduces a new problem: if you're not waiting in place, how should "where has it gotten to" be handled? The tool description gives an explicit rule:

> "Don't race: after launching a background agent, you know nothing about its results. Never fabricate or predict them in any format — not as prose, summary, or structured output."

**Not knowing means not knowing** — before a background task finishes, there's no writing up "here's roughly what it'll conclude" to paper over the gap, whether phrased as plain prose or dressed up as a formal report. The tool description then spells out the correct behavior:

> "The completion notification arrives in a later turn; it is never something you write yourself."

**The completion notification only ever shows up in "some later turn"** — it isn't something imagined in advance; it's delivered by the system once that turn actually arrives. If the user presses for progress in the meantime, the only honest answer is "still running" — not a plausible-sounding fake status update.

## Workflow: Not Even the Option to Wait

`Agent` at least leaves the `run_in_background: false` switch available, so waiting is still possible if wanted. `Workflow` **doesn't even offer that switch**:

> "Workflow runs in the background — this tool returns immediately with a task ID, and a `<task-notification>` arrives when the workflow completes."

There's no such thing as "set to foreground" — calling `Workflow` always returns a task ID immediately, and the actual execution result only ever shows up in some later turn's notification. This makes sense: a `Workflow` script can internally be managing dozens of agents running at once, and no "wait in place" mode could accommodate orchestration at that scale.

## But Inside the Script, the "Wait or Not" Decision Is Handed Back to the Author

`Workflow` is uniformly backgrounded from the outside, but how concurrency is organized **inside** the script is up to whoever wrote it. Two strikingly different patterns show up here:

- `parallel(thunks)` — **is a barrier**: it "awaits all thunks before returning." A batch of tasks gets thrown in and runs simultaneously, but execution **must wait for the entire batch to finish** before moving on.
- `pipeline(items, stage1, stage2, ...)` — **has no barrier**: "Item A can be in stage 3 while item B is still in stage 1." Each item flows through its own stages independently; whichever finishes first reaches the end first, with no need to wait for the others.

This is a different matter from the "background by default" behavior of `Agent` / `Workflow` at the outer level — that's about whether the *caller* waits for an entire task. `parallel` / `pipeline` are about whether *this particular step inside the script* waits for an entire batch. The former is a default set by the tool's designers; the latter is a choice **the author makes every time a script is written, between two synchronization strategies**.

## Concurrency Isn't Unbounded Either

Whether it's `parallel` or `pipeline`, "running at the same time" itself has a hard ceiling:

> "Concurrent agent() calls are capped at min(16, cpu cores - 2) per workflow — excess calls queue and run as slots free up."

Calls beyond this ceiling don't error out — they **queue and wait for a slot to open up**. Passing in 100 tasks doesn't mean 100 are truly running at once; at any given moment only around a dozen or so are actually executing, and the rest sit in the queue. Above this limit sits an even coarser backstop:

> "Total agent count across a workflow's lifetime is capped at 1000 — a runaway-loop backstop set far above any real workflow."

This isn't a routine limit — it's the last safeguard against a script that spirals into an infinite loop. The number is set far above any normal scale, so it's never hit in ordinary use and only matters when things go out of control.

## What This Piece Leaves Open

At this point, the question of "foreground or background" has an answer at all three levels: a single `Agent` call defaults to background (and can be flipped back), `Workflow` as a whole is always background (and cannot be flipped), and the concurrency strategy inside a script is chosen by the author (barrier or no barrier), with a hard ceiling on top to guard against runaway growth.

But regardless of whether — or how long — something waits, it eventually has to face the same question: once it says it's done, **what actually counts as "done"** — is a paragraph of prose enough, or does it have to hand back something in a fixed format? That's the question for the next piece.

## References

- Primary sources this piece is built on: the `run_in_background` field descriptions for the `Bash` / `Agent` tools, the background-invocation description for the `Workflow` tool, the semantics of `parallel()` / `pipeline()` inside scripts, and the descriptions of the concurrency cap and lifetime cap (directly readable within the toolset · verified word for word)
- No source-level discovery has been done yet — exactly how a `<task-notification>` gets delivered to "some later turn," and the implementation details of the concurrent scheduler's queuing, are left for future discovery if it turns up
- Material already covered elsewhere, not repeated here: [Tools series · Agent](../power/agent.md) (the full discussion of the `run_in_background` default being inverted)
