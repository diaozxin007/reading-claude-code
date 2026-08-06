## When Solo Dispatch Is Solved, Scale Adds a New Problem

The previous four pieces all answered questions about "dispatching a single agent" — context, permissions, foreground/background, reporting back. But when a batch of independent work needs to be divided up at once, a new problem surfaces that none of the first four touched: **who decides the order and ownership of this work?**

## The Shared Task Board's Answer: First to See the Board, First to Claim

The `Task` family (`TaskCreate`/`TaskList`/`TaskGet`/`TaskUpdate`) has already been thoroughly covered in the [tools series · Task Family](../state/task-family.md) — owner claiming, `blockedBy` dependencies, the state machine. No need to repeat that here; instead, one point directly relevant to "who divides the work" is worth calling out: **the division of labor on the task board isn't decided in advance**. A task placed on the board goes to whoever sees it first and claims it — this is a division of labor that's **decided at runtime**. Run the same task list through a different batch of agents, and who ends up with what could turn out completely differently.

## Workflow's Answer: Hardcoded in the Script

`Workflow` takes the opposite path. The script itself *is* the division-of-labor plan — `pipeline(items, stage1, stage2, ...)` spells out exactly "this batch of items flows through these stages in sequence," and `parallel(thunks)` spells out exactly "these tasks get thrown out simultaneously." **There's no "claiming" action at all** — the runtime scheduler simply executes what the script says, without making any ownership decisions on anyone's behalf.

A concrete example shows just how thorough this difference is: for reviewing a batch of files, the `Task` board approach creates one task per file and puts them on the board for whoever's free to claim; the `Workflow` approach writes `pipeline(files, f => agent(reviewPrompt(f)))` directly in the script — which file maps to which `agent()` call is fixed the moment the script is written.

## The Key Difference: Determinism

**Given the same script and the same input, `Workflow` produces the same division-of-labor path every single run** — this is the determinism that comes from hardcoding. The `Task` board is the opposite: its division-of-labor path depends on the timing of runtime claims, so running the same batch of tasks again doesn't guarantee the same person gets the same task. Neither is better — they're two designs solving different problems. `Workflow` optimizes for **reproducibility**, while the task board optimizes for **flexible insertion** — it lets new tasks be added and dependencies adjusted on the fly during collaboration, without needing to plan the entire flow up front. `Workflow` requires the whole flow to be thought through before a single line is written, in exchange for a process that can be replayed exactly later.

## "Hardcoding" Isn't Free

Choosing the `Workflow` path presupposes that whoever writes the script can already anticipate "how many stages this batch of work breaks into, who waits for whom, whether it needs to run in parallel." This is a form of **upfront commitment** — the moment the script is written, the division-of-labor plan is fixed. Wanting to change the split midway means editing the script and rerunning it — unlike the task board, where tasks can be added and claims adjusted as the work proceeds.

## A Third Answer: Let the Budget Decide

Inside a `Workflow` script there's a `budget` object that exposes the token target set for the current round, along with how much has been spent and how much remains. Built around this object is a division-of-labor style that's neither "hardcoded to a specific count" nor "claimed at runtime" — it **dynamically decides whether to dispatch the next agent based on remaining budget**:

```
while (budget.total && budget.remaining() > 50_000) {
  const result = await agent("Find the next batch of items to process")
  ...
}
```

How many agents this batch of work ultimately gets split across isn't a number the script author hardcoded, nor is it the outcome of runtime agents competing for claims — it **follows the resource constraint**: when budget is ample, more rounds get dispatched; when budget is tight, dispatching stops early. This is a third answer to "who does how much work" within `Workflow`, sitting somewhere between "fully hardcoded" and "fully open competition."

## The Interface This Piece Leaves Open

At this point, "who divides the work" has three concrete answers: the task board's runtime claiming, the script's upfront hardcoding, and budget-driven dynamic throttling. But none of these three answers addresses a more fundamental question yet: **among these agents running concurrently, what's separated between them, and what's shared from a single ledger?** — whether file changes are isolated from one another, whether token spending is tallied separately for each. That's the question for the next piece.

## References

- The primary source this piece is grounded in: the semantic documentation for `pipeline()`/`parallel()`/`budget` in the `Workflow` tool (directly readable within the toolset · verified word-for-word)
- Existing material not repeated here: [tools series · Task Family](../state/task-family.md) (the full discussion of owner claiming and `blockedBy` dependencies)
- No source-level discovery has been done yet — the concurrency-control details behind the task board's claiming action, and the concrete accounting implementation of the `budget` ledger, are left for future discovery if it happens
