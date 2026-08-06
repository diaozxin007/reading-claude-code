## Six Posts on "How"; This One Asks "Whether"

The previous six posts broke "multiple agents working together" down into a chain of concrete mechanisms — where context comes from, how permissions get defined, how foreground and background get chosen, what counts as a valid report, how work gets divided, and where the boundary between isolation and sharing sits. Taken together, these mechanisms all answer the question of "how should you use multiple agents, assuming you're going to." But there's a more upstream question none of them touched: **when is it actually worth dispatching an agent, and when does it just turn one task into a more complicated version of itself?**

## Back to the Original Criterion: Compression Ratio

The [Tools series · Agent post](../power/agent.md) already gave a concrete criterion for this:

> "If the volume of key information involved in a task is much smaller than the volume of the resulting conclusion, dispatch an Agent. Researching 100 files to produce a 500-word report is a 100x information compression ratio — a perfect Agent scenario. Changing one line of code has a compression ratio close to 1 — don't dispatch an Agent, just do it yourself."

This criterion is the **starting premise** of the six posts in this series, not something this series discovered on its own — but it's worth putting back on the table now, at the close, because every mechanism discussed across the six posts (the self-contained cost that comes with zero inheritance, the several-hundred-millisecond overhead of `worktree` isolation, the queuing delay of concurrent scheduling) **only matters once this criterion holds**. When the compression ratio doesn't pay off, everything the six posts describe is wasted overhead — context has to be rebuilt, results have to be checked, isolation costs time to build a copy — and a single agent just doing the work directly is faster.

Multi-agent collaboration isn't free parallel acceleration. It's trading a "fixed cost of dispatching" for "information compression" and "concurrent throughput" — the trade only pays off when what you save exceeds what you spend.

## Scale Is a Second Reason, Beyond Compression Ratio

Posts 05 and 06 — on "batch division of labor" and "isolation vs. sharing" — point to a scenario the compression-ratio criterion doesn't cover: **it's not that a single task carries a huge volume of information, it's that there's a batch of independent tasks happening at the same time**. Reviewing ten files, running three different kinds of checks, verifying multiple hypotheses in parallel — taken individually, none of these tasks may have an impressive compression ratio. But **done serially**, the total time is a simple sum; split across several agents running concurrently, the total time is roughly whatever the slowest one takes. In this case, dispatching multiple agents isn't chasing compression — it's chasing **concurrent throughput**.

These two reasons (compressing information / concurrent throughput) often hold at the same time, but either can hold on its own. A single task with a massive but singular volume of information — say, organizing a huge list of historical issues — has only the compression reason and not the concurrency reason, so one agent is enough. Ten independent small checks might each have a mediocre compression ratio individually, but the concurrency reason holds, and it's worth splitting them across several agents to run at once.

## Responsibility Doesn't Disappear Just Because You Dispatched It

No matter which reason justified dispatching however many agents, the "trust but verify" principle from [What Counts as Done · From Free-Form Prose to Fixed Schema](04-completion-reporting.md) still holds: what comes back is a **statement of intent**, not proof of fact. As scale grows, this discipline doesn't relax just because "this time ten agents reported back together" — if anything, it's easier to let slip: when ten reports flood back at once, the impulse to check each one gets naturally diluted by sheer volume. Multi-agent collaboration solves for **information compression and concurrent scheduling**. It does not, and cannot, solve the question of **who is accountable for the final result** — that layer of responsibility has never, from start to finish, transferred out of the hands of whoever dispatched the work.

## Six Mechanisms, One Table

| Question | Answer |
|---|---|
| Where does context come from | `Agent` zero inheritance, self-contained vs. `SendMessage` continues by name, push delivery |
| How are permissions defined | `subagent_type` preset bundles, `Agent`/`Workflow` share a registry |
| Foreground or background | `Bash` defaults to foreground, `Agent` defaults to background (reversible), `Workflow` is always background |
| What counts as done | Free-form prose by default, `Workflow` can enforce a schema; task management and result management are two separate channels |
| Who does which piece of work | Runtime claiming from a shared task board / hardcoded in a script upfront / dynamic scaling driven by a `budget` |
| Where isolation vs. sharing draws the line | Files are isolated on demand (`worktree`), tokens are always shared (`budget` is one shared ledger) |

## The Boundaries This Series Leaves Standing

As stated at the outset, this series never did a formal source-level discovery — every piece of material comes from text that can be verified word-for-word against the tool schemas themselves. That means these six posts answer "what these tools' design intent and external behavior are," not "how these mechanisms are actually implemented internally." The latter — say, how `SendMessage`'s message bus is actually built, or exactly how the `budget` ledger measures usage — would be worth returning to reinforce these posts with a deeper layer of confirmation if a discovery ever fills that gap. But it wouldn't change the conclusions these six posts already stand on.

## References

- The criterion in this post is inherited directly from: [Tools series · Agent post](../power/agent.md) (source of the compression-ratio criterion and the "trust but verify" quote)
- Echoes all six preceding posts in this series: [Opening · From One Agent to a Team](00-intro.md) · [Where Context Comes From · From Zero Inheritance to Continuation](01-context-inheritance.md) · [How Tool Permissions Are Defined · From subagent_type to On-Demand MCP](02-tool-permissions.md) · [Foreground or Background · From Default Reversal to Concurrency Limits](03-foreground-background.md) · [What Counts as Done · From Free-Form Prose to Fixed Schema](04-completion-reporting.md) · [Who Does Which Piece of Work · Shared Task Board vs. Hardcoded Script](05-task-assignment.md) · [The Boundary Between Isolation and Sharing · From worktree to the Token Ledger](06-isolation-sharing.md)
