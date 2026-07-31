This is the tenth installment in the Claude Code tools research series. The previous nine covered:

- **Interaction primitives trio** ([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md))
- **Execution primitive chain** ([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md))
- **General-purpose fallback** [Bash](../power/bash.md)
- **Meta-tool** [Agent](../power/agent.md)

The first nine tools are all about "Claude doing **things right now**" — each tool call is an action executed immediately. But in real projects, there's another class of needs: **remembering what needs to be done, tracking progress, breaking large tasks into subtasks, and sharing a single checklist when multiple Claudes collaborate**.

This requires a **"task management system"**. Claude Code's answer is the Task family — a todo system composed of 6 tools.

> This series builds on the [prerequisite article](../tool-mechanism.md) — which explains what tools are and how Claude uses them. This article follows the 4-layer framework proposed there.

## The Task Family (TaskCreate / TaskList / TaskGet / TaskUpdate / TaskStop / TaskOutput)

This is the **first time in the series we cover 6 tools in a single article**. Why combine them? Because they **share a single data model** (the task list), are highly coupled in semantics, and splitting them would pull attention from the "system" back to individual "operations." It's like nobody introduces "how to create a JIRA ticket" without explaining the whole JIRA system.

### Family Overview

Here's a table showing each tool's responsibility at a glance:

| Tool | Responsibility | Common Usage |
|---|---|---|
| **TaskCreate** | Create a new task | When decomposing complex requirements or receiving multi-point requests |
| **TaskList** | List all tasks | Finding the next actionable item or reporting progress |
| **TaskGet** | Get details of a single task | Before starting a task or checking dependencies |
| **TaskUpdate** | Change task status / metadata | Starting a task, completing a task, building dependencies |
| **TaskStop** | Stop a background-running task | Terminating a background bash / subagent |
| **TaskOutput** | Get output from a background task | *Deprecated — use Read tool on the output file* |

**Core division of labor**: The first 4 handle **CRUD for the tasks themselves** (New / List / Get / Update); the last 2 handle **runtime task control** (stop / get output) — they're all called Task but are actually two groups:

- **Todo tasks** — conceptual tasks that Claude has noted down
- **Running tasks** — physical tasks with a real bash / subagent process running

TaskCreate / List / Get / Update manage the former; TaskStop / TaskOutput manage the latter. Same name, different meaning — this is the most confusing aspect of the Task family, and we'll expand on it below.

### Purpose

The Task family (especially the four todo-task tools) solves the core problem of "how Claude **manages multi-step work across tool calls and across time**":

1. **Visible decomposition** — complex requirements broken into items so users can see Claude's pace of progress
2. **Progress tracking** — each task has a pending / in_progress / completed status, crystal clear at a glance
3. **Dependency modeling** — tasks can have "A blocks B" relationships, enforcing order
4. **Multi-Claude collaboration** — main Claude breaks down tasks, subagents claim ownership, sharing the same list
5. **Context compression** — a short one-line subject carries an entire block of work, so main Claude doesn't have to repeatedly recall details

The key difference from all previous tools: **Task is the only tool family with "persistent state"**. Results from Read / Edit / Bash are returned once in the tool call and that's it; a task created by TaskCreate **stays in the system**, visible to TaskList at any future point, until marked completed or deleted.

### A Concrete Example

**Scenario**: The user says **"I want to add a user profile page to the project. I need: backend API + frontend component + database schema + unit tests + permission checks"**.

This is a typical **multi-task composite requirement**. What happens without the Task family?

#### Counter-example: Without the Task Family

Claude can only:

1. Keep it in short-term memory, thinking "what's next" as it goes
2. Say "OK, now I'm going to do xxx" in the chat after each step, using text to record progress
3. Once the conversation grows long, Claude's attention gets crowded out by other things, **forgetting that unit tests haven't been written**
4. When the user asks "how far along is this feature," Claude has to review the entire conversation history to answer

**Core pain point**: The task list **exists only in Claude's short-term context** — once the context is compressed, a subagent is switched, or a session is restored, the list is lost.

#### How the Task Family Solves This

**Step 1 — Receive the requirement, immediately create tasks**

Upon receiving the requirement, Claude's first action is TaskCreate, building out all 5 subtasks:

```
TaskCreate(subject: "Design database schema", description: "Add profile fields to users table or create new profiles table")
TaskCreate(subject: "Write migration file", description: "Generate knex migration")
TaskCreate(subject: "Implement backend API", description: "GET/PATCH /api/profile with auth middleware")
TaskCreate(subject: "Frontend component ProfilePage", description: "Route /profile, form, submit calls API")
TaskCreate(subject: "Add unit tests", description: "API layer unit tests + frontend component tests")
```

Each task returns an ID (e.g., `task_001` through `task_005`).

**Step 2 — Build dependencies, enforce order**

Some tasks have clear ordering: schema must exist before the API can be written, API must exist before the frontend. Use TaskUpdate to build `blockedBy`:

```
TaskUpdate(taskId: "task_002", addBlockedBy: ["task_001"])  # Migration depends on schema design
TaskUpdate(taskId: "task_003", addBlockedBy: ["task_002"])  # API depends on migration
TaskUpdate(taskId: "task_004", addBlockedBy: ["task_003"])  # Frontend depends on API
TaskUpdate(taskId: "task_005", addBlockedBy: ["task_003"])  # Tests also depend on API
```

Now the entire list forms a dependency chain: schema → migration → API → (frontend + tests).

**Step 3 — Find the next actionable item**

Claude calls TaskList and sees:

```
task_001 · pending  · "Design database schema"     · blockedBy: []
task_002 · pending  · "Write migration file"       · blockedBy: [task_001]
task_003 · pending  · "Implement backend API"      · blockedBy: [task_002]
task_004 · pending  · "Frontend component ProfilePage"  · blockedBy: [task_003]
task_005 · pending  · "Add unit tests"             · blockedBy: [task_003]
```

**Only task_001 is pending with an empty blockedBy** — that's the next one to do.

**Step 4 — Claim + do + deliver**

```
TaskUpdate(taskId: "task_001", status: "in_progress")
# ... Claude does actual work: discusses schema, writes down decisions ...
TaskUpdate(taskId: "task_001", status: "completed")
```

Now task_002's blockedBy is empty — it's ready to go.

**Step 5 — Delegate to a subagent**

Large tasks (like "frontend component") can be dispatched to a subagent:

```
Agent(
  description: "Implement ProfilePage",
  prompt: "Task ID task_004, frontend ProfilePage component, route /profile, see TaskGet for details ..."
)
```

**The subagent can TaskGet the details, TaskUpdate to claim it, and mark it completed when done** — main Claude and the subagent collaborate through the shared task system without needing to message each other.

**Step 6 — Report**

Whenever the user asks "how's it going," Claude can TaskList and answer immediately:

```
✅ task_001 · completed  · Design database schema
✅ task_002 · completed  · Write migration file
🔄 task_003 · in_progress · Implement backend API (Claude)
⏸️ task_004 · pending    · Frontend component (blocked by 003)
⏸️ task_005 · pending    · Add unit tests (blocked by 003)
```

One view, everything clear at a glance.

#### Key Insight: The Task Family is Claude's "Externalized Working Memory"

All previous tools are about **"doing things"** — letting Claude complete a specific action. The Task family is different; it's about **"noting things down"** — externalizing Claude's short-term plans from its head **into runtime storage**.

This difference has two profound implications:

1. **Persistence across contexts** — even if main Claude's conversation is compressed, switched, or restored, the Tasks remain
2. **Shared across multiple Claudes** — main Claude and subagents synchronize work state through the Task system without messaging each other

This is like a human engineer **writing todos in JIRA** — not because they don't trust their memory, but because **memory is personal; tasks are for the team**. Writing them down enables collaboration, enables tracking, and prevents things from being missed.

### Trigger Conditions

The Task family's prompts (each tool has one) have strict constraints on trigger conditions. Consolidating them:

**Scenarios where the Task family should be used**:

- **Complex tasks with 3+ steps** — single-step tasks don't need Tasks, just do them directly
- **Non-trivial multi-operation tasks** — requiring planning, multiple operations
- **User explicitly requests a todo list** — user directly says "make me a todo"
- **User gives multiple tasks** — "1. xxx 2. xxx 3. xxx" — create them all at once
- **In plan mode** — use Tasks to track plan steps
- **Before starting work** — immediately mark as in_progress after claiming
- **After completion** — immediately mark completed and pick up newly unblocked tasks

**Scenarios where the Task family should NOT be used**:

- **Single direct tasks** — things completable in one step
- **Trivial tasks** — creating a Task adds noise
- **Simple tasks with fewer than 3 steps** — tracking provides no value
- **Pure conversation / informational tasks** — the user is just asking a question, no need to task-ify it

A **core judgment**: **The Task family is for "work at scale"**. If something is simple enough that Claude can handle it in a single tool call, creating a Task is noise. If something is complex enough to be decomposed, have dependencies, and need tracking, not creating Tasks is negligence.

### Technical Implementation

#### 1 — Naming

`TaskCreate` / `TaskList` / `TaskGet` / `TaskUpdate` / `TaskStop` / `TaskOutput`

**Task** as the family prefix replaces natural intuitive names (like `Todo` / `Ticket` / `Job`). This choice isn't arbitrary: "Task" carries an additional layer of meaning beyond "Todo" — it implies "there's a definite executor." A Todo can be "look at this when free"; a Task implies "someone needs to do this." The naming itself hints at the existence of the owner field.

**Verb suffixes** follow standard CRUD semantics: Create / List / Get / Update — Claude can infer at a glance that they correspond to "create one / list all / get one / update one," identical to database table operations. Upon seeing these 4 names, Claude immediately builds the mental model of "Task is an enumerable, selectable, updatable entity collection."

**No Delete** — this omission is deliberate. Hard deletion is triggered via `TaskUpdate(status: "deleted")`, not a separate `TaskDelete` tool. Why? Because **deletion is an endpoint in the state machine**, not an independent operation. This design channels all state transitions through `TaskUpdate` — one fewer tool = one fewer decision to make.

**Semantic drift with Stop / Output** — `TaskStop` / `TaskOutput` reuse the Task prefix, but their targets are not todo tasks — they're running background processes (background bash / subagents). This is a tension in the family naming: same name, different meaning. The designers clearly decided that "unifying under the Task namespace is better than splitting" — but it's also the most confusing aspect of the family. The field-level descriptions repeatedly emphasize this distinction.

**activeForm is the most ambitious field name in the family**. It's not called `presentContinuous` / `verbForm` / `spinnerLabel` — it's called `activeForm`, a very "grammatical" term. This word forces Claude, when filling in this field, to think not about "filling in a UI label" but about "converting the verb to present progressive tense." The naming brands a grammatical rule into the field semantics.

#### 2 — Tool-level Descriptions

Each tool in the Task family has its own description. Their common semantic positioning is as a **collaboration contract**: 6 tools collaborate around the same data model — each tool description begins by reminding Claude "this is a family member, not an isolated tool."

**TaskCreate's opening — threshold locked down**

> Use this tool proactively in these scenarios:
> - Complex multi-step tasks - When a task requires 3 or more distinct steps or actions

**"Only create Tasks for 3+ steps"** is an explicit quantified threshold. This prompt trains Claude not to overuse — single-step small tasks shouldn't become Tasks. This is also a textbook case of **using specific numbers instead of vague adjectives**: not "complex tasks," but "3+ steps."

**TaskCreate's three-phase timing**

> - After receiving new instructions - Immediately capture user requirements as tasks
> - When you start working on a task - Mark it as in_progress BEFORE beginning work
> - After completing a task - Mark it as completed and add any new follow-up tasks

The timing is clear: **receive instructions → create; start working → mark in_progress; finish → mark completed**. Three actions bookend every segment of work, disallowing "silently starting" or "silently finishing." This elevates "using Tasks to track progress" from a one-time action to a **work cadence**.

**TaskUpdate's completion criteria — particularly strict**

> - ONLY mark a task as completed when you have FULLY accomplished it
> - If you encounter errors, blockers, or cannot finish, keep the task as in_progress
> - Never mark a task as completed if:
>   - Tests are failing
>   - Implementation is partial
>   - You encountered unresolved errors

Claude is not allowed to "call it close enough." Tests failing = not complete. Implementation partial = not complete. Unresolved errors = not complete. This prompt prevents a particularly bad behavior: **false completion** — Claude feels "the general direction is right" and marks completed, leaving behind a pile of half-done tasks.

**TaskList's scheduling intuition**

> Prefer working on tasks in ID order (lowest ID first) when multiple tasks are available

**Default to working tasks in ID order**. Because "earlier-created tasks are usually prerequisites for later ones" — this constraint makes Claude's scheduling follow the intuitive order in which tasks were created, preventing cherry-picking.

**TaskUpdate's staleness reminder**

> Make sure to read a task's latest state using `TaskGet` before updating it.

**A task's state may have been changed by another agent** — especially in multi-Claude collaboration. TaskGet before TaskUpdate fetches the latest state, preventing stale writes from overwriting others' updates. This is essentially an **intuitive version of optimistic concurrency control** — "read then write" rather than "blindly update."

**TaskOutput's deprecation notice**

> DEPRECATED: Background tasks return their output file path in the tool result, and you receive a `<task-notification>` with the same path when the task completes.
> - For bash tasks: prefer using the Read tool on that output file path

The tool description directly marks DEPRECATED and provides the alternative. This is **rare transparency in tool design** — no hiding, no gradual sunset, just directly telling Claude "don't use this, use Read."

**reminder hook — a harness-level cadence unique to this family**

The Task family has a **built-in reminder mechanism** — if Claude hasn't used Task-related tools for a while, the system inserts a system reminder:

> The task tools haven't been used recently. If you're working on tasks that would benefit from tracking progress, consider using TaskCreate to add new tasks and TaskUpdate to update task status.

This reminder is the harness layer helping Claude build **the habit of "using the Task family to track progress."** Even if Claude momentarily forgets, the system will remind — but the closing phrase "Only use these if relevant to the current work" also makes clear it's **not mandatory**, just a nudge. This hook is unique to the Task family — the first 9 tools don't need reminders because their uses are immediate; the Task family needs to track progress over time, requiring a cross-temporal nudge.

#### 3 — Field-level Descriptions

The complete field list for a Task object:

- **id** — system-generated unique ID
- **subject** — short title (imperative, e.g., "Run tests")
- **description** — detailed description
- **activeForm** — present progressive form (e.g., "Running tests," used in spinners)
- **status** — pending / in_progress / completed (also deleted)
- **owner** — who is working on this task (agent name; empty means unclaimed)
- **blocks** — which tasks this task blocks
- **blockedBy** — which tasks block this task
- **metadata** — custom key-value pairs

Many fields — let's expand on 4 key design points.

**The triple expression of subject / description / activeForm**

The same task expressed in three forms:
- **subject** — short title (imperative): "Run tests"
- **description** — detailed description: "Run unit tests, confirm all 4 auth-related tests pass"
- **activeForm** — present progressive form: "Running tests"

Why three? **Because they appear in different UI locations**:
- List view displays the subject (short title)
- Detail view displays the description (full details)
- Spinner displays the activeForm (present progressive — "Running tests..." fits UX better than "Run tests")

This is "multi-form presentation of the same data" — providing the most appropriate text for each location. **The mandatory present progressive of activeForm** is the most distinctive design at this layer: it's not optional polish but a hard requirement — when Claude creates a task, it must simultaneously provide both the imperative and progressive forms; leaving it empty is not allowed. A grammatical rule branded into the field contract.

**blocks / blockedBy are bidirectional dependencies**

`blocks` and `blockedBy` are **two sides of the same thing**:

- A blocks B ⟺ B blockedBy A

The runtime automatically maintains bidirectional consistency. Claude only needs to specify addBlocks or addBlockedBy in one direction; the other syncs automatically.

The field naming choice here is **redundant expression prioritized over minimalism**. The designers could have kept only one direction (say, only blockedBy) and derived the other through reverse lookup. But both directions are exposed as first-class fields because **their read semantics differ**: "who do I block" and "who blocks me" are two different intuitions in Claude's scheduling decisions; separate expression makes prompts more natural.

**addBlocks / addBlockedBy with incremental merge semantics** — TaskUpdate doesn't accept `blocks: [...]` as a wholesale override; it only accepts `addBlocks: [...]` as an incremental append. This field naming detail prevents a class of accidents: **Claude wants to add one dependency but accidentally clears all existing ones**. Incremental semantics make "adding a dependency" idempotent and safe.

**status enum — linear state machine + deleted escape hatch**

State transitions: `pending → in_progress → completed`

**Regression is not allowed** (from completed back to in_progress) — want to redo? Create a new task. This constraint prevents the chaotic state of "tasks bouncing back and forth," keeping progress predictable.

**Special status `deleted`** — this is the hard-delete entry point, not a regression. Used to clean up erroneously created tasks. Deleted tasks don't appear in normal List views, but the runtime retains records to prevent ID reuse. This is the choice of **incorporating deletion into the state machine** — a Task from birth to death is always a value change of the same status field, rather than "deletion = disappearing from the database."

**blockedBy protection** — if a task still has uncompleted dependencies in its blockedBy, **the runtime won't allow it to become in_progress** (or at minimum, the prompt explicitly forbids it). This prevents Claude from impulsively working on tasks that aren't ready. The state machine isn't a single-field transition; it's a **multi-field coordinated transition**: status changes are constrained by the current value of blockedBy.

**owner + metadata — two switches for multi-Claude collaboration**

`owner` records which **agent** is currently working on a task. This field is key to the Task family's **support for multi-Claude collaboration**:

- Main Claude creates a task, owner is empty
- Main Claude dispatches a subagent; the subagent claims it, owner = subagent name
- When main Claude calls TaskList, it can see "which tasks are claimed and which are still empty for dispatching new subagents"
- After a subagent finishes, it releases the owner; main Claude can dispatch another

This is the fundamental pattern of a **distributed task queue**, except the queue consumers are multiple Claude instances.

`metadata` is a free-form key-value field. Claude can put anything here: relevant file paths, reference links, supplementary context for subagents, temporary notes. This is **an escape hatch left for future extension** — the tool designers didn't prescribe what metadata should contain, so users/agents can fill it as needed. owner is the family's core contract; metadata is the family's escape hatch — one hard, one soft.

#### 4 — Schema Validation Rules

The Task family's schema validation has a few hard rejections; the rest lives in the runtime state machine.

| Constraint | Layer | Content |
|---|---|---|
| `activeForm` required | schema | TaskCreate doesn't allow omitting the progressive form |
| `status` enum | schema | Can only be one of pending / in_progress / completed / deleted |
| `subject` length | schema | Short title has a maxLength (exact value varies by version) |
| Status regression | runtime | completed → in_progress is rejected |
| blockedBy non-empty → in_progress | runtime | Unlocked tasks cannot be claimed |
| Read before TaskUpdate | runtime | Strongly recommended but not hard-rejected (trained via prompt) |

**Division between schema and runtime layers** — parameter structure and enum values (i.e., **static constraints**) go in the schema; state machine, dependency checks, and concurrency protection (i.e., **dynamic constraints**) go in the runtime. Edit / Read are the extreme of "putting most constraints in runtime"; the Task family is relatively balanced: entry parameters are guarded by schema, state transitions are guarded by runtime.

**Transparency of degradation to Read** — after TaskOutput was deprecated, the "get output" capability **has no replacement tool** but rather **degrades to an existing primitive** (Read tool directly reads the output file path). This is a hidden principle of Claude Code tool design: **capabilities that can be covered by existing primitives don't get dedicated tools**. One fewer tool = one less API surface area = one fewer decision to make.

---

### Division of Labor with Neighboring Tools

The Task family contrasts with the previous nine tools:

| Dimension | Three interaction primitives | Locate + perceive + execute (5 tools) | Bash | Agent | Task family |
|---|---|---|---|---|---|
| Position | Collaboration alignment | Code modification | Command execution | Spawning Claudes | **Externalized working memory** |
| Tense | Present (single interaction) | Present (single operation) | Present | Present (fork/join) | **Cross-temporal (persistent state)** |
| State location | None (via interaction) | Disk + harness | None (gone when command ends) | Inside subagent | **Runtime storage** |
| Primary benefit | User alignment | Precise code changes | Engineering workflows | Context space | **Fighting forgetting; visible collaboration** |
| Naming duality | Enter/Exit pair | Read/Edit/Write siblings | Single | Single | **CRUD quartet + Stop/Output** |

**The coupling between the Task family and Agent** is the deepest pairing:

- Agent dispatches subagents to do work — results are unpredictable (might error, hang, or die)
- The Task family provides **work-item containers** that make subagent work trackable
- TaskStop accepts both subagent IDs and task IDs — providing a **unified kill entry point**
- TaskOutput (deprecated) was the dedicated interface for retrieving subagent results — now degraded to directly Reading the subagent's output file

**The analogy between the Task family and Bash is also worth noting** — both are **carriers of long-running tasks**: Bash's `run_in_background` lets commands run in the background; TaskCreate lets todos hang in the system. Both solve the problem of "if the AI main loop blocks, nothing else can be done." The difference: Bash's background is "machine waiting for command return"; Task is "humans and AI collaboratively tracking progress" — the former is async IO, the latter is async collaboration.

**The Task family's position in the tool ecosystem** — the first 9 tools are all primitives of "one call does one thing"; the Task family is a meta-primitive of "externalizing what needs to be done into the system." It doesn't add a new capability — rather, it **provides temporal storage for all other capabilities**.

---

### Summary

The elegance of the Task family lies not in the feature of "having a todo list" itself, but in how its signal distribution **spans all 4 layers and forms a complete duality closure**:

- **Naming** — 6 tool names; CRUD quartet + Stop/Output as two runtime controls; `activeForm` brands a grammatical rule into the field name; missing `TaskDelete` (replaced by status=deleted) and missing a separate output retrieval (degraded to Read)
- **Tool-level descriptions** — each tool has an independent prompt that cross-references others; packed with the 3-step threshold, three-phase timing, false-completion prohibition, staleness reminder, deprecation notice, and reminder hook, writing the "collaboration contract" into every description
- **Field-level descriptions** — triple expression (subject / description / activeForm) corresponding to 3 UI locations; bidirectional dependencies (blocks / blockedBy) prioritizing redundant expression over minimalism; addBlocks incremental merge preventing overwrites; owner as a hard field + metadata as a soft escape hatch
- **Schema validation** — static constraints at the schema layer (activeForm required, status enum including deleted); dynamic constraints at the runtime layer (no status regression, blockedBy non-empty rejects in_progress, staleness in multi-Claude scenarios)

What makes the Task family unique is that it extends Claude Code from "present tense" to "future tense": the first 9 tools are all "do an action right now"; the Task family is "externalize what needs to be done into runtime storage — across tool calls, across time, shared across Claudes." This extension isn't as simple as adding a feature — it transforms the work style from "fighting forgetting with willpower" to "fighting forgetting systematically" — forgetting is no longer a disaster, because the list remains.

**Core insight: duality tool families form closed loops; accumulated state has release paths.** The CRUD quartet is a complete duality (Create ↔ Update-deleted; List ↔ Get; read ↔ write), not a half-baked "has creation but no deletion"; accumulated Task state must have release paths — hard deletion via status=deleted, lifecycle termination via completed, indirect release via blockedBy auto-updates. The biggest fear in a task system is "can enter but can't exit" accumulation anxiety; the Task family uses the status state machine to ensure every Task has a clear termination posture.

The design of `activeForm` forcing present progressive tense elevates the low requirement of "fill in a label" to the high requirement of "perform a grammatical transformation" — it's the most ambitious piece among all field designs. It's not collecting data; it's training Claude to view tasks in the tone of **"currently doing"** rather than **"planning to do."** This difference is the difference between "already started" and "intend to start" — a difference in work cadence.

The next article continues with [WebFetch + WebSearch](../info/web.md) — jumping from "file system" and "async tasks" to see how Claude Code's AI **converses with the external network**: one is "curl with AI," the other is "search with filtering." These two tools are like sisters in the ecosystem, paralleling the dual-tool pattern of Grep+Glob.
