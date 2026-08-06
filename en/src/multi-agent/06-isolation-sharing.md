## Who Can See Whom, After the Work Is Divided

The previous piece covered how work gets divided. That raises an immediate follow-up: when a batch of agents runs concurrently, are the files they touch and the money they spend tracked separately, or do they share a single ledger?

## At the File Level: Isolation Is Optional, and It Costs Something

Both `Agent` and `Workflow` expose an `isolation: "worktree"` option. Turn it on, and the agent edits files inside an **independent git working copy**, so it won't collide with other agents running at the same time over the same files. This is not the default — it has to be explicitly opted into, for a plain reason:

> "EXPENSIVE (~200-500ms setup + disk per agent), use ONLY when agents mutate files in parallel and would otherwise conflict; the worktree is auto-removed if unchanged."

**It's only worth turning on when the premise actually holds — that several agents will mutate files concurrently and would genuinely conflict otherwise.** Every time you enable it, you pay a few hundred milliseconds to build a disk copy; if the agent ends up changing nothing, that copy is cleaned up automatically, leaving no trace. Conversely, the default is no isolation — most of the time an agent is just reading files and running commands, without colliding with anyone else, so there's no reason to spin up a separate working copy for every single one.

**At the file level, isolation is an opt-in engineering feature, not a boundary that exists by default.**

## At the Token Level: It Was Never Tracked Separately

Files can opt into isolation, but the `budget` object in `Workflow` scripts answers a different question entirely — how much has already been spent. There's a line here that's easy to skim past but carries real weight:

> "the pool is shared, not per-workflow"

`budget.spent()` tallies the output tokens spent by **the main conversation together with every `Workflow` currently running** — not "how much this particular workflow has spent," but one shared account for everyone. That means even when file-level `worktree` isolation cleanly separates what several agents touch, **there is no corresponding isolation option for token consumption by design**. There's no such thing as "this agent tracks its own budget independently."

That hard constraint carries a consequence: once `spent()` reaches `total`, any subsequent `agent()` call throws immediately.

The budget is a **shared hard cap**, not a quota each agent draws down independently and stops when its own share runs out. Everyone spends from the same pool, and whoever pushes the total to its ceiling first blocks every subsequent call — regardless of who started running first.

## What This Asymmetry Reveals

The same question of isolation gets entirely different answers depending on which resource is at stake — files or tokens:

- **File conflicts** are an engineering problem — solvable on demand via a mechanism like `worktree`, and you don't pay the cost unless you need it.
- **Token spend** was never an engineering problem to begin with. It's fundamentally a constraint on how much money and compute this round of work is allowed to cost, and the design answer is a **single shared ledger** — there's no option to split it apart.

This asymmetry isn't an oversight; it's a deliberate design stance. Files are *state*, and state can be partitioned on demand into non-interfering copies. Tokens are *consumption*, and consumption is inherently a running total — splitting it into "everyone tracks their own" would strip the meaningful question of any meaning, which is: "how much can this round still spend in total," not "how much can this one agent still spend on its own."

## The Interface This Piece Leaves Open

At this point, the four questions around dispatching a single task, the three answers around batch division of labor, and the boundary between isolation and sharing are all laid out. But stacking all these mechanisms together ultimately has to answer a more fundamental question: **when are these mechanisms actually worth using, and when do they just make something more complicated than it needs to be?** That's what the closing piece will answer.

## References

- Primary sources this piece is built on: the `isolation: "worktree"` description for the `Agent`/`Workflow` tools, and the `budget` object description for the `Workflow` tool (directly readable within the toolset · verified word-for-word).
- No source-level discovery has been done yet — the exact timing of worktree cleanup and the underlying accounting implementation behind the shared token ledger are left for future discovery, if any.
- Callback: [Opening · From One Agent to a Team](00-intro.md) (this piece answers the "isolation or sharing" question left open in the opening piece).
