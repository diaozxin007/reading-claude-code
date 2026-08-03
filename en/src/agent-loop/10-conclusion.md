# 10 · Closing · From an Automatic Loop to a General-Purpose Agent Loop

The previous 10 articles took apart permissions, hooks, tool scheduling, the state machine, streaming, error recovery, interrupt, and sub-agent. This closing article doesn't add a new mechanism — it just does one thing: puts these pieces back together into the complete Agent Loop.

## 5 Core Insights for the Reader to Take Away

If the whole Loop series is only remembered for 5 things, they should be these 5.

### 1 · The loop is automatic — usually no one is in the middle of it

The user hits enter once, and the loop runs forward on its own — it usually doesn't need the user to direct it step by step. The loop only actively stops and waits for the user when a tool needs permission approval; the user can also actively interrupt it.

This is the most fundamental difference between an agent and an ordinary chatbot: a chatbot stops once it finishes an answer, while an agent can keep calling the model and running tools after a single user input, all the way until the task is done.

### 2 · The loop is a state machine, not a simple while loop

The core of the loop isn't the 5-line pseudocode — it's an explicit set of states. At the end of every turn, it records what to do next; the next turn then decides, based on that state, whether to take a normal call, a retry, a compaction, or a recovery branch.

So when something fails, it isn't retried layer by layer inside the current turn's `try/catch` — instead, control returns to the main loop, and the next turn handles the recovery. Details in [05 · QueryEngine Main Loop · The Full State Machine](05-query-engine.md).

### 3 · Errors are states that can keep being processed

A failed tool execution gets converted into a `tool_result` and handed to the LLM; when the main loop needs to recover, it gets converted into a `transition` and handed to the next turn. Both follow the same idea: **convert an error into a state or piece of data that can keep being processed, rather than letting an exception directly break the loop**.

So the loop isn't just an error handler waiting for failures to happen — it's more like a recovery engine that actively tries to save itself. Only when internal recovery also fails does the final error get reported to the user. Details in [07 · Retry and Error Recovery · 8 Layers of Recovery Stacked Together](07-retry-recovery.md).

### 4 · Automatic operation has three safeguards

The loop running automatically doesn't mean it's completely out of control. There are three mechanisms that let a person or the system regain control:

- **Permission approval** — before executing a dangerous tool, the loop actively stops and waits for the user's decision
- **Interrupt** — the user can actively break a running loop at any time
- **maxTurns** — even with no intervention, hitting the turn cap forces a stop

The three respectively handle "confirmation before execution," "braking during execution," and "a final hard cap" — together they constrain the automatic loop.

### 5 · The main agent and sub-agents reuse the same loop

A sub-agent isn't a separate loop implementation. The main agent and sub-agents both call the same `queryLoop` code — they simply run independently and are distinguished by `agentId`.

This shows that the loop isn't code dedicated to serving a chat window — it's the general-purpose execution engine in Claude Code that lets "AI autonomously drive a task forward." Details in [09 · Sidechain · From Sub-agent to agentId Routing](09-sidechain.md).

## From a 5-Line Skeleton to a Complete System

Now, looking back at the whole series:

- **[00](00-intro.md)** — moves from the intuition of a chat window to the 5-line loop skeleton
- **[01](01-tool-permission.md)–[04](04-stop-reason.md)** — take apart tool declaration, permissions, hooks, parallel scheduling, and the stop decision within each turn
- **[05](05-query-engine.md)** — uses a state machine to unify the pieces above
- **[06](06-streaming.md)** — unpacks the streaming process inside a single model call
- **[07](07-retry-recovery.md)** — explains how the loop recovers on its own after failure
- **[08](08-interrupt.md)** — explains how the user interrupts the automatic loop from outside
- **[09](09-sidechain.md)** — generalizes the same loop to sub-agents

The original 5-line pseudocode wasn't wrong — it just left out the parts that actually matter: **how branching happens between steps, how recovery works after failure, how the user regains control, and how the same loop serves different types of agents.**

## Loop Manages Execution · Context Manages Information

**Loop is the skeleton.** It explains how things happen: when to call the model, when to run tools, when to retry, when to stop.

What flows across that skeleton is **information**: how messages get assembled, how prompt cache gets reused, how compact shortens history, how CLAUDE.md gets injected. Those belong to the sister series, the [Context Management Research Series](../context-management/00-intro.md).

The division of labor between the two series compresses into two sentences:

> Loop explains "how things happen."
>
> Context explains "how information is organized."

Only together do they form the complete picture of how Claude Code's Agent operates.

---

## Related Series

- [Claude Code Context Management Research Series](../context-management/00-intro.md) — messages, cache, compaction, and context injection
- [Claude Code Tools Research Series](../tool-mechanism.md) — the capabilities and design of each concrete tool
