This is the fourteenth installment of the Claude Code tools research series. The first thirteen were all **"tool teardowns"** — cracking open each tool to examine its internal design. This one is different: it's the series' first **"thematic essay"**: instead of dissecting a single tool, it dissects a **cross-cutting orthogonal capability that spans multiple tools** — the Background mechanism.

> This series builds on the [prerequisite essay](../tool-mechanism.md), which explains what a tool is and how Claude uses them. This essay follows the 4-layer framework proposed there (examining the cross-tool background mechanism through the lenses of "naming," "tool description," "field description," and "schema").

## Why Dedicate an Essay to Background

Attentive readers will have noticed: there is **no standalone tool called `Background`** in Claude Code. This is not an oversight — it's a **design choice**.

Background-related capabilities are **fragmented across multiple tools**:

| Location | Form |
|---|---|
| **Bash `run_in_background: true`** | Parameter |
| **Agent `run_in_background: true`** | Parameter |
| **Monitor** | The entire tool is essentially a persistent background listener |
| **CronCreate** | The entire tool is "trigger in the background at a future moment" |
| **TaskStop** | A standalone tool for stopping background tasks |
| **TaskOutput** | Retrieving output from background (deprecated) |
| **`<task-notification>`** | Notification message when a background task completes |

Dissecting any single one only reveals a partial picture. This essay places them all on **the same map**.

## The Essence of Background: Execution Mode, Not Behavior

In the first thirteen tools, each tool has a **core behavior**:

- Read: "read a file"
- Bash: "run a command"
- Agent: "dispatch a subagent"
- ...

**Background is not a behavior — it's a mode**:

- "Run a command" is behavior → Bash
- "Run it in the background" is execution mode → `run_in_background: true` parameter

The same behavior (Bash / Agent) can follow **two execution modes**:

- **Synchronous mode** (default): invoke → block and wait → get result → continue conversation
- **Background mode** (`run_in_background: true`): invoke → immediately return a task ID → main Claude continues the conversation → harness proactively notifies when the background task completes

If background were made into a standalone tool, you'd need `BackgroundBash` / `BackgroundAgent` / `BackgroundMonitor`... doubling the tool count and doubling the decision burden.

**Using parameterization instead of toolification — this is a classic example of "orthogonal design" in Claude Code**. It follows the same philosophy as [Grep](../execution/grep-glob.md)'s three-mode `output_mode` and [Edit](../execution/edit.md)'s `replace_all` boolean: **behavior stays fixed; parameters switch the execution mode**.

### Analogy: fork / wait in Operating Systems

If you're familiar with Unix system calls, this design has a familiar shadow:

- In Unix, `fork()` creates a child process; `wait()` waits for it to complete
- Bash's `run_in_background: true` is analogous to fork; the task ID is the pid; `<task-notification>` is analogous to SIGCHLD notifying the parent process

**Claude Code uses the harness layer to implement a "process management system from Claude's perspective"** — except the child process might be a shell process, another Claude, or a WebSocket connection.

## The Unified task ID System

Whether you start a background bash / background agent / cron job / monitor, the harness tracks them all with **the same task ID mechanism**:

```
Bash(command: "long-training.py", run_in_background: true)
    → returns task_id: "bh0u2kafo"

Agent(prompt: "...", run_in_background: true)
    → returns task_id: "ag_xxx..."

CronCreate(cron: "*/5 * * * *", recurring: true, prompt: "...")
    → returns job_id: "cron_..."

Monitor(command: "tail -f log | grep ERROR", persistent: true)
    → returns monitor_id: "..."
```

**All IDs can be stopped by TaskStop** — that's the **unified interface**. You don't need to learn a separate stop mechanism for each type of background task.

The only differences lie in **notification format**:

- Bash background completes → `<task-notification>` with output file path
- Agent background completes → `<task-notification>` with agent result
- Cron fires → runtime directly triggers a new conversation round using the specified prompt
- Monitor event arrives → each stdout line becomes a message flowing into the conversation

**Unified interface; semantics differentiated by type** — this is good API design.

## Three Types of "Background Tasks"

Semantically, Claude Code has three typical kinds of background tasks:

### Type A: One-Shot Tasks with a Clear Endpoint

**Representatives**: Bash background, Agent background

**Characteristics**:
- Clear start point, clear end point
- Harness proactively sends `<task-notification>` when the task completes
- Main Claude doesn't need to ask — the notification arrives on its own

**Typical scenarios**:
- Long tests / builds / training runs
- Dispatching a subagent for research
- Installing a large dependency

**Interface**:
```
Bash(command: "...", run_in_background: true) → task_id
    (conversation continues · until notification arrives)
[<task-notification> task_id status: completed output: /tmp/.../out.log]
Read("/tmp/.../out.log") → get output
```

### Type B: Trigger at a Scheduled Time

**Representative**: CronCreate

**Characteristics**:
- Start point is the CronCreate invocation
- Trigger point is the moment specified by the cron expression
- When triggered, the runtime starts a new conversation round using the **specified prompt** (not a notification to the existing conversation)

**Typical scenarios**:
- Reminder in 30 minutes
- Check CI every 5 minutes
- Run a morning check tomorrow at 9 AM

**Interface**:
```
CronCreate(cron: "...", prompt: "...", recurring: false) → job_id
    (conversation can continue · or session can end)
[trigger time] runtime uses the prompt to initiate a new conversation
```

The key difference from Type A: **Type A is "a started task that's running"; Type B is "an unstarted task waiting to be triggered"**.

### Type C: Continuous / Long-Running Monitoring

**Representative**: Monitor (especially with `persistent: true`)

**Characteristics**:
- Clear start point; endpoint undefined (or set at timeout / event stream end / Claude manually stops it)
- Every event sends a notification — not one-shot
- Data source can be shell command stdout or WebSocket frames

**Typical scenarios**:
- Tracking ERRORs in logs
- Monitoring filesystem changes
- Subscribing to a WebSocket event stream
- PR status until merge

**Interface**:
```
Monitor(command: "...", persistent: true) → monitor_id
    (each event flows into the conversation)
[event 1] ... [event 2] ... [event 3] ...
    (until Claude proactively calls TaskStop or the session ends)
```

### Comparison of the Three Types

| Dimension | Type A: One-Shot Task | Type B: Scheduled Trigger | Type C: Continuous Monitoring |
|---|---|---|---|
| Notification count | **Once** (on completion) | **N times** (each fire) | **Variable** (each event) |
| Start/end relationship | Task already started; waiting to end | Task not started; waiting for trigger | Task already started; event stream ongoing |
| Primary interface | Bash / Agent + background | CronCreate | Monitor |
| Stop method | Usually ends naturally; TaskStop available | CronDelete | TaskStop |

## The Anti-Polling Principle

The existence of the Background mechanism should establish a **core behavioral intuition** for Claude:

> **If the harness will notify you, don't sleep. If there's background, don't synchronously wait.**

Anti-pattern examples:

**Anti-pattern 1: sleep-polling for background completion**

```
Bash(command: "long-task", run_in_background: true)
    → task_id
Bash(command: "sleep 60")
Bash(command: "cat /tmp/.../out.log")  # manual poll
```

**Problem**: The harness will automatically notify you when the task completes. You don't need to sleep + cat; just wait for the notification.

**Correct approach**:

```
Bash(command: "long-task", run_in_background: true)
    → task_id · main Claude does other work
[wait for notification to arrive naturally] → Read the output
```

**Anti-pattern 2: sleep-waiting for external state**

```
Bash(command: "curl -sf https://ci-status/build/42")
    → not finished
Bash(command: "sleep 60")
Bash(command: "curl -sf https://ci-status/build/42")
    → not finished
... repeat 8 times
```

**Problem**: Each iteration consumes one tool call + one context slot. 20 minutes means 20 wasted calls.

**Correct approach**:
- If the curl will exit to signal completion → use `Bash run_in_background` + an `until` loop
- If the status is a streaming event → use Monitor
- If it's just "check once at a given time" → use CronCreate

**Anti-pattern 3: short sleep loops to circumvent harness notifications**

The Claude Code prompt explicitly warns:

> Long leading `sleep` commands are blocked.

The system **actively prevents** long sleeps — specifically to force Claude to use the correct background patterns. This is the tool layer physically enforcing asynchronous thinking on Claude.

## Task ID vs Job ID vs Task (To-Do) — Naming Confusion

Here lies **the most easily confused naming collision in Claude Code**.

Three names all contain "task":

| Name | Belongs to which system | Semantics |
|---|---|---|
| **Task (TaskCreate / TaskList / ...)** | [Task family](task-family.md) | **To-do item** (concept) |
| **task_id / task-notification** | Background mechanism | **Currently running background task** (instance) |
| **task_id in CronCreate return value** | Cron family | **Scheduled job's ID** |

**Core distinction**:

- Task family's Task = **something to be done conceptually** (might not have started yet)
- Background's task = **something actually running as an entity** (bash / agent / monitor / cron)

TaskStop / TaskOutput have "Task" in their names, but they control the **latter**, not the former. This is the most confusing naming in Claude Code — the previous [Task family](task-family.md) essay already flagged this, and it bears repeating here.

**Mnemonic**:

- Task**Create** / Task**List** / Task**Get** / Task**Update** — manage **to-dos** (first 4 verbs all have CRUD flavor)
- Task**Stop** / Task**Output** — manage **running tasks** (verbs have runtime-control flavor)

## A Comprehensive Workflow Example

**Scenario**: A user wants to launch 3 actions simultaneously, aggregating results as they arrive:

1. Run a full test suite in the background (15 minutes)
2. Dispatch a subagent to research the auth module architecture
3. Start a dev server while editing code and observing logs

Claude issues all of these in a single message:

```
Bash(
  command: "pnpm test:all",
  description: "Run full test suite",
  run_in_background: true,
  timeout: 900000
) → task_bh0test

Agent(
  description: "Research auth module",
  prompt: "...",
  run_in_background: true
) → task_ag_auth

Bash(
  command: "pnpm dev",
  description: "Start dev server",
  run_in_background: true
) → task_bh0dev

Monitor(
  command: "tail -f /tmp/dev.log | grep -E --line-buffered 'error|warn'",
  description: "Monitor dev server errors"
) → monitor_dev
```

**What happens at runtime**:

- Main Claude receives 4 IDs, all dispatched in a single message
- **Multiple tool calls in one message = concurrency** — 3 Bash + 1 Agent + 1 Monitor all start simultaneously
- Main Claude continues conversing with the user, discussing refactoring direction
- **Tests finish →** `<task-notification>` for task_bh0test; Read the output to get results
- **Subagent research completes →** `<task-notification>` for task_ag_auth; retrieve the report
- **dev.log produces an error →** Monitor immediately pushes a message; Claude perceives it instantly
- **User wants to kill the dev server →** `TaskStop(task_bh0dev)` — done in one call

**This is the full power of the background mechanism**: main Claude lays out 4 concurrent background tasks in a single message, then remains in a state of "always conversable + always receiving notifications" until the user or harness triggers the next action.

**Comparison with a traditional REPL**:

- Traditional REPL: one tool call, block for result, get result, continue → 4 actions serially take 15+ minutes
- Claude Code + background: one message dispatches 4 tool calls running concurrently → 4 actions in parallel; the longest one determines total time

**The concurrency dividend earned through parameterization is the most direct benefit of the Background mechanism**.

## Boundaries of the Background Mechanism

Background is not omnipotent. There are several clear boundaries:

### Boundary 1: Session-Only

Same constraint as [Cron](cron-family.md): **all background tasks only live within the current session**. When Claude exits = tasks are killed and task IDs become invalid.

**Implication**: Don't use background for tasks that need to span multiple days. Use system-level cron / launchd / GitHub Actions / cloud schedulers instead.

### Boundary 2: Notifications Have Latency (Until Next Idle)

`<task-notification>` **does not interrupt** a prompt that Claude is currently processing. **It's only delivered when the REPL goes idle**. Therefore:

- If Claude is in the middle of a conversation, notifications queue up
- They only appear when the current conversation turn ends and the next idle window arrives
- High-frequency notifications may experience slight delays when Claude is busy

### Boundary 3: Rate Limiting

Monitor will automatically stop high-volume event streams (hundreds of lines per second would flood the conversation). Background task stdout also has cumulative limits. **A strong filter is a first-class citizen** — background output that isn't selective will be truncated by the system.

### Boundary 4: Concurrency Limit

- Bash background and Agent background have concurrency caps (typically min(16, cpu-2))
- Tasks exceeding the cap are queued, starting when earlier ones complete
- Pipeline / parallel tasks in Workflows also count against this cap

### Boundary 5: Sandbox Still Applies

Background bash still runs inside the sandbox — **it is not a way to bypass security boundaries**. Only dangerouslyDisableSandbox can break out, but that's a different matter.

## The 4-Layer Perspective on the Background Mechanism

Background is not a single tool and has no single prompt. But extracting the signals scattered across multiple tools through the prerequisite essay's 4 layers still reveals clear design intent. **Signals are distributed very unevenly across these 4 layers** — and that itself is a **defining characteristic** of the Background mechanism.

### 1. Naming

Background-related naming signals are concentrated almost entirely in the single decision of "don't make it a standalone tool."

**Parameterization over toolification**

Claude Code has no `BackgroundBash` / `BackgroundAgent` / `BackgroundMonitor` — only a boolean field called `run_in_background`. This naming choice is itself an implicit declaration: **background is an execution mode, not a new behavior**. A single flag at the field level displaces an entire parallel tool family.

**Verb unification in TaskStop / TaskOutput**

Stopping a background bash isn't called `BashStop`; stopping a subagent isn't called `AgentStop`; stopping a monitor isn't called `MonitorStop`. **They're all unified under `TaskStop`**. This follows the Unix philosophy of `kill <pid>` — **regardless of what you forked, you use the same verb to converge**. task_id is the equivalent of pid; TaskStop is the equivalent of kill.

**The deprecation and disappearance of TaskOutput**

Early API versions had TaskOutput — explicitly fetching output from background tasks. It has since been demoted to "use Read on the output file." The naming-layer signal change is very direct: **capabilities that can be covered by existing primitives (Read) don't get their own verb**. This subtraction was also noted in the tenth essay on the [Task family](task-family.md).

**The naming collision between task_id and to-do Tasks**

This is **the most confusable naming** in Claude Code: the Task family's Task = **to-do item** (concept); the background system's task_id / `<task-notification>` = **running instance** (entity). Same word, two systems. The "Task" in TaskStop belongs to the latter — it manages running instances, not to-do lists.

The earlier "Task ID vs Job ID vs Task (To-Do)" section covered this in detail, so it won't be repeated. The only point to note here: **the naming collision is regrettable** but now stable; Claude disambiguates via contextual semantics (whether the verb is CRUD or runtime-control).

**Cron / Monitor are naming specializations of background**

The Cron name doesn't contain "background," but it's essentially "background + clock trigger." The Monitor name doesn't contain "background" either, but it's essentially "background + event stream." The naming layer preserves each tool's semantic distinctiveness while internally reusing the task_id / TaskStop infrastructure. **Base API + specialized API layering** — externally distinct in naming, internally sharing implementation.

### 2. Tool-Level Description

In tool-level descriptions, background-related signals are highly **prescriptive** — they don't describe capabilities; they describe **how to use them correctly**.

**The anti-polling principle**

The Bash tool description explicitly states:

> Avoid unnecessary `sleep` commands: Do not sleep between commands that can run immediately — just run them. Use the Monitor tool to stream events... For one-shot "wait until done," use Bash with run_in_background instead.

**It tells Claude: the notification will arrive on its own — don't sleep + cat to poll**. This is the core behavioral intuition of the entire essay.

**Hard blocking of long sleeps**

> Long leading `sleep` commands are blocked.

The tool-level description directly **declares system-level interception** — this isn't soft advice. Claude can't write a long sleep even if it wants to — physical-layer enforcement of the async pattern. This is the same design philosophy as Edit's "Read prerequisite will error": **elevating critical constraints from suggestions to hard blocks**.

**Monitor's filter-first principle**

The Monitor description repeatedly emphasizes "strong filter is first-class citizen," "never pipe raw logs," "monitors that produce too many events are automatically stopped." This tells Claude: the **cost of background event streams is conversation context**; non-selective output will be truncated by the system. This constraint is more subtle than "can or can't run" — **it can run but will be rate-limited**.

**Cron's session-only declaration**

The CronCreate description explicitly states: jobs only live within the session; they become invalid when Claude exits. This writes the **boundary** of the background mechanism into a single tool's description — ensuring Claude reads "this is not system-level cron" every time it considers CronCreate. This follows the same pattern as AskUserQuestion writing its "timing relationship with plan mode" into its own description: **cross-tool contracts written into individual tools**.

### 3. Field-Level Description

Field-level signals concentrate on the `run_in_background` parameter itself and the return structure of `<task-notification>`.

**The contrasting default values of `run_in_background`**

Same field name; opposite default values in two tools:

| Tool | Default | Guidance in description |
|---|---|---|
| Bash | `false` | "Most shell tasks are short; synchronous by default is simpler" |
| Agent | `true` | "Subagents are typically slow; default to background so main Claude isn't blocked" |

**Default values are the most explicit expression of design intent** — they reflect the typical usage scenarios of each tool. Signals at the default-value level are harder than any prompt: if Claude doesn't explicitly change it, that's the value it gets.

**Bash `run_in_background` description details**

The Bash field description states: "Only use this if you don't need the result immediately and are OK being notified when the command completes later. You do not need to check the output right away — you'll be notified when it finishes. You do not need to use '&' at the end of the command when using this parameter."

This simultaneously accomplishes three things: (1) declares the precondition (don't need the result urgently), (2) declares the subsequent guarantee (you'll be notified), (3) prohibits adding `&` in the command (avoiding double-backgrounding). **A field description serving as a few-shot counter-example**.

**Agent `run_in_background` description details**

The Agent field description states: "Foreground vs background: Pass `run_in_background: false` to run an agent in the foreground when you need its results before you can proceed... Otherwise let it run in the background (the default) so you can keep working in parallel."

**This mirrors the Bash structure**: same field name; one says "when to turn on background"; the other says "when not to turn on background." Different defaults lead to opposite guidance directions.

**The output contract of `<task-notification>`**

When a background bash completes, the notification carries an `output` file path. This field's design guides Claude to use Read to access the output rather than looking for a "getOutput" API. **Through the structure of the notification field itself, Claude naturally follows the Read path** — and that's why TaskOutput could be deprecated.

**Monitor's `persistent` field**

`persistent: false` (default) = a one-time monitor with a timeout; `persistent: true` = a session-length monitor without timeout. A single boolean distinguishes "Type A event stream" from "Type C event stream." The field's two values correspond to two completely different background semantics.

### 4. Schema Validation

Schema-layer signals are sparse — because background is more of a **semantic mode** than a structural constraint. But a few hard constraints are worth noting:

| Constraint | Location | Intent |
|---|---|---|
| `timeout_ms` upper limit of 3600000 (1 hour) | Monitor non-persistent mode | Prevent unbounded background monitoring |
| `persistent: true` and `timeout_ms` are mutually exclusive | Monitor | Semantic clarity; pick one |
| `run_in_background: true` + `&` compatibility handling | Bash | User adding `&` doesn't produce a double-fork |
| cron expression format validation | CronCreate | Block syntactically invalid scheduled expressions |
| Unified task_id type | TaskStop | All background types share the same stop interface |
| Concurrency limit min(16, cpu-2) | Runtime layer | Protect host resources |
| Sandbox enabled by default | All background tasks | Background is not a way to bypass security boundaries |

**The most interesting thing about the schema layer is "there's almost nothing to validate"** — because background **modifies** synchronous behavior rather than **replacing** it. The existing schema for synchronous tool calls (command / prompt / cron / ...) is basically sufficient; background only adds a boolean or changes a layer of trigger conditions.

**This also explains why Background doesn't need a standalone tool**: if it had its own schema, that would indicate a new behavior; it has no independent schema, which indicates an execution mode — the schema layer's sparseness is itself evidence for the "parameterization vs. toolification" design choice.

## Summary

The elegance of the Background mechanism lies not in the capability of "letting AI go async" per se, but in its **highly uneven signal distribution that consistently echoes the core choice of "parameterization over toolification"**:

- **Naming** — minimal; no standalone tool; just the `run_in_background` field + unified TaskStop verb; task_id plays the role of pid
- **Tool-level description** — prescriptive; Bash / Agent / Monitor / Cron each embed cross-tool behavioral contracts like "anti-polling," "filter-first," "session-only" in their own descriptions
- **Field-level description** — where contrast is most concentrated; Bash and Agent have opposite `run_in_background` defaults with mirrored guidance directions; the most explicit embodiment of design intent
- **Schema validation** — sparse; because background modifies synchronous behavior rather than replacing it; hard constraints are limited to timeout caps / persistent mutual exclusion / concurrency limits as safety nets

**The sparseness of signal distribution is itself evidence** — the simpler the schema, the more thoroughly the choice of "background is an execution mode, not a new behavior" has been carried through. If it were a standalone capability, it would grow its own fields and validations; it didn't grow them, which means it has successfully parasitized the **default values and flags** of the synchronous API.

**Background mechanism's position in the Claude Code ecosystem**:

The first 13 tools are **spatial primitives** (doing something to something at some location). The Background mechanism is **the implementation layer of temporal primitives** — enabling all tool executions to extend from synchronous to asynchronous.

**Without the Background mechanism, Claude Code is "a one-action-at-a-time assistant"; with it, Claude Code is "a multi-threaded collaborator."** This capability is what lets Claude truly handle **"multiple long tasks running concurrently + working while chatting + automatically acting at scheduled times + event-driven responses"** in complex engineering scenarios.

From this perspective, Background isn't "a feature" — it's the invisible skeleton that upgrades all tools **from a "synchronous pipeline" to an "asynchronous collaboration system."**

---

## Relationship with Neighboring Tools

The Background mechanism is not a standalone tool; it's a **cross-tool cross-cutting parameter**. Its relationship with the first 13 tools isn't "parallel" but "pervasive":

| Host Tool | Background Manifestation | Default Mode | Primary Purpose |
|---|---|---|---|
| **Bash** | `run_in_background: false` default; explicit opt-in | Foreground blocking | Support long tasks without blocking the main loop |
| **Agent** | `run_in_background: true` default; explicit opt-out | Background async | Subagents are normally long-running |
| **Task family** | task_id plays the pid role; TaskStop / TaskOutput | N/A | Provide cross-temporal state and kill entry point |
| **Cron family** | Timer-driven; future-time awakening | Scheduled trigger | Temporal primitive |
| **Monitor** | Event-driven; event stream awakening | Event trigger | Event stream primitive |

**The "anti-polling principle" is the nerve center of the Background mechanism** — it simultaneously constrains how Bash / Agent / Monitor are used:
- Bash background tasks will notify on completion — **don't poll in a sleep loop**
- Agent background tasks will notify on completion — **don't use CronCreate to periodically check on them**
- Monitor streaming events notify on arrival — **don't tail -f and forget to stop after one event**

This principle isn't written in any single tool's description; only by viewing background as a **mechanism** can you understand why it permeates all tools. This is also the core reason this essay must analyze across tools.

**The division of labor between Background and synchronous mechanisms**:
- Synchronous: one call → result goes directly into context; main loop consumes it and moves on
- Asynchronous: one call → immediately returns a handle; task runs in background; notification mechanism pushes results → results are pulled back via Read on output file or TaskOutput

The first 13 tools are all **synchronous by default**: Read / Edit / Write / Grep / Glob / WebFetch / WebSearch / AskUserQuestion / Enter/ExitPlanMode are all synchronous. This implies Claude Code's **default mental model is synchronous**; async is an **explicit choice for special scenarios** (except Agent, which reverses this — because subagent lifecycles are decoupled from the main loop, synchronous would actually be the awkward choice).

---

## Series Conclusion

With this, the Claude Code tools research series is complete. Looking back at the map of 14 essays:

1. **Prerequisite essay** — what a tool is and how Claude uses them
2-4. **The interaction primitive trio** (Ask / EnterPlanMode / ExitPlanMode) — how AI and user align
5. **Grep + Glob** — locating
6. **Read** — perceiving
7-8. **Edit / Write** — precise / wholesale execution
9. **Bash** — catch-all fallback
10. **Agent** — spawning Claude instances
11. **Task family** — externalizing working memory
12. **WebFetch + WebSearch** — reaching the public web
13. **Cron family** — future time
14. **Monitor** — event streams
15. **Background mechanism** — upgrading all tools from synchronous to asynchronous

The skeleton of the entire tool ecosystem is built like this: **user alignment → locating → perceiving → executing → fallback → scaling (subagent / time / event streams)**. Each layer is a "sufficient + safe + composable" primitive; combined, they form a complete collaboration system.

These 15 essays aren't meant to be exhaustive, but to put every tool through the same "4-layer dissection": naming, tool-level description, field-level description, schema validation. **This method can be reused for analyzing any tool system** — whether MCP servers, skills written by others, or your next agent project.

The series ends here, fully dissected. If you had to summarize Claude Code tools' design philosophy in one word: **restraint** — each tool does only one small thing; it's only in combination that they form a collaboration system.
