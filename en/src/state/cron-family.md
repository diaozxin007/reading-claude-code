This is the twelfth installment in the Claude Code tools research series. The previous eleven covered Claude Code's **spatial dimension toolset** — from the local filesystem to the internet, from a single Claude to multiple Claudes, from immediate actions to todo lists. All those tools are fundamentally **"synchronous"** in nature — Claude calls a tool, it executes immediately, and returns immediately.

But in real engineering, there's a class of requirements this system can't handle:

- "Remind me to check CI in 30 minutes"
- "Check every 5 minutes if the deployment is done"
- "Run a morning self-check at 9 AM tomorrow"
- "Wait an hour, then re-review this proposal for me"

What these requirements have in common: **the action isn't "do it now" — it's "automatically triggered at some future moment"**.

This requires **temporal primitives**. Claude Code's answer is the Cron family — a scheduling system composed of 3 tools (CronCreate / CronDelete / CronList).

> This series assumes you've read the [prerequisite article](../tool-mechanism.md) — which explains what tools are and how Claude uses them. This article follows the 4-layer framework proposed there.

## Cron Family (CronCreate / CronDelete / CronList)

Like the Task family in the tenth installment, these 3 tools are highly semantically coupled, share the same data model (the session's cron jobs list), and are better covered together.

### Family Overview

| Tool | Responsibility |
|---|---|
| **CronCreate** | Create a future-triggered prompt using a standard 5-field cron expression |
| **CronDelete** | Cancel a scheduled job |
| **CronList** | List all scheduled jobs in the current session |

**"Relative tools"**: Besides the Cron trio, there's also a related **ScheduleWakeup** — specifically for the dynamic mode of the `/loop` skill, scheduling the next self-wakeup. Its role is a **specialized version** of the Cron family (optimized for loop tasks), which we'll briefly cover here.

**Core division of labor**:

- **CronCreate** (the engine) — 90% of calls go here
- **CronList / CronDelete** (management) — checking progress, cleanup

The biggest difference from the Task family: **the Task family records "things to do" while the Cron family schedules "future actions"**. Tasks wait for Claude to get around to them; Cron **automatically triggers when the time comes** — more proactive, more precise.

### Purpose

The core problem the Cron family solves is "how Claude can **execute actions across time**":

1. **Breaking the synchronous constraint** — Claude is no longer limited to "request → response"; it can "schedule a future self-wakeup"
2. **Precise scheduling** — using standard cron syntax (`M H DoM Mon DoW`), flexible enough for any moment or any period
3. **One-shot / recurring dual modes** — toggled with the `recurring` boolean
4. **Lightweight reminders** — achieving "remind me in 30 minutes" without spinning up a background task
5. **Proactive awareness** — when waiting for external state (CI / deployment), proactively checking at scheduled times

Its key difference from all previous tools: **this is the only tool family that can "span time"**.

The previous eleven tools are all **"point" actions** — they complete execution the moment the tool call triggers. The Cron family is **"line" scheduling** — it marks a point on the timeline that automatically fires when reached.

### A Concrete Example

**Scenario**: The user says **"I just pushed a deploy — results come in about 8 minutes — wait for it and check the CI status for me — let me know if there are problems."**

This is a classic **"wait for external state change"** task. Claude has several approaches:

#### Anti-pattern 1: Pure sleep

```
Bash(command: "sleep 480 && gh run list", timeout: 500000)
```

**Problem**: The main Claude is blocked by sleep for 8 minutes — it can't converse with the user during this time; the user has to wait even to ask something else. **Synchronous blocking wastes conversation time**.

#### Anti-pattern 2: Poll every minute

```
while true:
    Bash(command: "gh run list")
    sleep 60
```

**Problem**: Consumes context once per minute — that's 8 times in 8 minutes — the main Claude's context fills up with logs. **Context waste**.

#### How CronCreate Solves It

Claude calls CronCreate, scheduling a **one-shot wakeup 8 minutes later**:

```
CronCreate(
  cron: "13 22 29 7 *",           # Exact time (July 29th 22:13, once)
  recurring: false,                 # One-shot
  prompt: "Check CI status now using gh run list. If failed, tell the user. If passed, confirm briefly."
)
```

**What happens at runtime**:

- The runtime records this job (in session memory)
- The main Claude **immediately returns to the user** — no blocking
- The user can ask other things, have Claude do other work
- At 22:13, the runtime automatically triggers `prompt` as a new Claude invocation
- Claude receives the prompt, runs `gh run list`, reports the status

From the user's perspective, the experience is:

```
[22:05] User: I just pushed a deploy — check CI for me in 8 minutes
[22:05] Claude: Got it — I've scheduled an automatic check at 22:13
              (feel free to do other things)
[22:05-22:12] User: (does other things — Claude responds to conversation as normal)
[22:13] Claude (auto-triggered): CI check complete — all 3 workflows green
```

**Key insight**: CronCreate transforms "waiting" from **the main Claude's responsibility** into **the runtime's responsibility**. The main Claude finishes scheduling and moves on, occupying neither conversation time nor context.

#### Combined Usage: CronList to Check Progress, CronDelete to Cancel Early

If the user suddenly says "never mind, don't wait for CI — I'll check myself", Claude can:

```
CronList()  # Get the ID of the previous job
CronDelete(id: "cron_xxx")  # Cancel it
```

Or if the user asks "what tasks have you scheduled?", Claude can just CronList and answer.

### "Proactive" vs "Reactive" — Two Wakeup Modes

The Cron family has two typical usage patterns:

**One-shot (recurring: false)**

For actions at a **known moment**:
- "Remind me to review this PR at 9 AM tomorrow"
- "Check CI again in 30 minutes"
- "Remind me to eat at 12:00"

The cron expression pins specific minute / hour / dom / month values — triggers once then disappears.

**Recurring (recurring: true)**

For **monitoring with no known end time**:
- "Check CI every 5 minutes until I say stop"
- "Check queue length every hour"
- "Run a morning self-check every day"

Uses expressions like `*/5 * * * *` / `0 * * * *` / `0 9 * * *`. **Note: recurring tasks survive at most 7 days** — they auto-fire one final time at expiry then delete. This cap is a **drift-prevention design**: it prevents jobs from lingering after a session ends (which actually can't happen anyway — see technical implementation below) and prevents jobs from living forever consuming resources.

### Trigger Conditions

**When to use Cron**:

- **Waiting for external async events** — CI / deployment / long-running tasks
- **Reminders / timed execution** — "do Y at time X"
- **Periodic monitoring** — "check X every N minutes"
- **Conversation ended but you want Claude to self-resume later** — a morning self-check

**When NOT to use Cron**:

- **Sub-second / second-level actions** — cron resolution is minutes; use sleep for faster
- **Need precise response to external events** — use the Monitor tool (better fit for "wait for something to happen")
- **The harness already auto-notifies for waits** — e.g., background bash / subagent completion triggers harness notifications; no polling needed
- **Persistent cross-session tasks** — **session-only!** Cron jobs aren't written to disk; they're gone when Claude exits

**Division of labor with other waiting primitives**:

| Requirement | What to Use |
|---|---|
| One-time event notification (CI complete) | **Bash `run_in_background`** (harness auto-notifies) |
| Event listening with no fixed time (file changes) | **Monitor** |
| Timed reminder / one-shot delay | **CronCreate + recurring: false** |
| Periodic monitoring | **CronCreate + recurring: true** |
| Self-wakeup within /loop skill | **ScheduleWakeup** (specialized version) |

This table is critical — **Cron is not the only waiting primitive**; Claude should choose based on semantics.

### Technical Implementation

#### 1. Naming

`CronCreate` / `CronDelete` / `CronList`

The trio is another **dual-closure** — Create hooks it up, Delete removes it, List observes. The lifecycle of a scheduled task is "created -> exists -> expires or is deleted", requiring both an "observe current state" and a "proactively cancel" reverse operation — hence 3 tools, not 2.

The word "Cron" itself is borrowed — **no custom DSL invented, directly reusing Unix crontab's 40-year industry convention**. Users who've written `crontab -e` in their Linux/macOS terminal already understand; no new syntax to learn. **Reusing industry conventions to reduce cognitive overhead** is the core design of this naming. Similarly, `List` uses plural semantics rather than `Get`, hinting it returns multiple items.

#### 2. Tool-Level Description

The Cron family's description centers on six things: **session-only lifecycle / 7-day cap proactively communicated / load spreading (avoid :00 and :30) / when :00/:30 IS appropriate / when NOT to use Cron / one-shot vs recurring language signals / local timezone semantics / jitter mechanism transparency**.

**Session-only stated upfront — lifecycle declared at the opening**

> Jobs live only in this Claude session — nothing is written to disk, and the job is gone when Claude exits.

**Major constraints stated upfront** — so Claude doesn't tell the user "I've scheduled a weekly task" when that's impossible. Transparency beats polish. The design choice behind this constraint: persistent cron would require handling user permission verification, error handling, multi-session state synchronization — complexity explosion. Anthropic chose the **simplified path** — cron is just an in-session timer; the user has full control. The tradeoff is that long-term tasks (days/weeks) are beyond the Cron family; those need system-level cron or cloud services.

**7-day cap — proactively tell the user**

> Recurring tasks auto-expire after 7 days — they fire one final time, then are deleted. This bounds session lifetime. Tell the user about the 7-day limit when scheduling recurring jobs.

**Claude is required to proactively inform the user** about the 7-day cap. Not passively answering questions, but **proactively disclosing constraints**. This is "honest rapport" — Claude shouldn't hide limitations when helping users schedule. The 7-day cap itself is a **forgetting-prevention design**: a user might create an "hourly monitor" and forget about it; this cap ensures it won't occupy resources forever. One-shot tasks aren't affected (they only fire once anyway).

**"Load spreading" awareness written into the prompt — avoid :00 and :30**

> Every user who asks for "9am" gets `0 9`, and every user who asks for "hourly" gets `0 *` — which means requests from across the planet land on the API at the same instant. When the user's request is approximate, pick a minute that is NOT 0 or 30

**This is a rare design of writing "system-level load spreading" into a tool prompt** — most tools only care about Claude's usage behavior, not server pressure. Cron is the exception because it's the only tool that can create periodic requests the user doesn't notice. Everyone's intuition for "9 AM" is "9:00", all requests pile onto the same second, and Anthropic's backend gets hammered (load spike). Having Claude automatically pick an offset minute (like :57 or :03) spreads requests and stabilizes the backend.

**The reasoning is explicitly explained** — not just "follow this rule". When Claude understands the intent behind a rule, it can make its own judgment in edge cases.

**When :00 / :30 IS appropriate — counterexample provided**

> Only use minute 0 or 30 when the user names that exact time and clearly means it ("at 9:00 sharp", "at half past", coordinating with a meeting). When in doubt, nudge a few minutes early or late — the user will not notice, and the fleet will.

**Counterexamples provided** — explicitly stating when using :00 is correct (user explicitly requests or is aligning with a meeting). **Prevents Claude from being dogmatic**: rules have exceptions, and exceptions are documented too.

**When NOT to use Cron — pointing to Monitor**

> Not for live watching. CronCreate re-runs a prompt at fixed wall-clock intervals. To watch a log file, process, or command output and be notified the moment something changes, use the Monitor tool instead — Monitor streams events as they happen; cron polls on a schedule.

**Explicitly tells Claude not to use Cron as a Monitor substitute**. The tool description directly points to the sibling tool rather than hoping the model compares multiple tools on its own. This is another example of "inter-tool collaboration contracts written into individual tool descriptions."

**One-shot task detection — inferred from user language**

> For "remind me at X" or "at `<time>`, do Y" requests — fire once then auto-delete. Pin minute/hour/day-of-month/month to specific values

**Provides concrete trigger signals for recurring: false** — language like "remind me at X" / "at `<time>`, do Y" signals a one-shot scenario. **Inferring parameter values from user language** means Claude doesn't have to ask "do you want one-shot or recurring?" every time.

**Local timezone semantics — avoiding UTC conversion**

> Uses standard 5-field cron in the user's local timezone: minute hour day-of-month month day-of-week. "0 9 * * *" means 9am local — no timezone conversion needed.

**Explicitly states local timezone semantics**, preventing Claude from manually doing UTC conversion. Writing this kind of "habitual pitfall" into the prompt is **grown from hard-learned lessons** — generations of sysadmins have hit timezone bugs. The usage feels as intuitive as writing crontab in one's own terminal.

**Jitter mechanism transparency**

> The scheduler adds a small deterministic jitter on top of whatever you pick

**Telling Claude about jitter** — so Claude doesn't think "I wrote :57 but it fired at :58, is that a bug?" Transparency builds correct expectations. Specific jitter rules: recurring tasks are delayed by up to 10% (capped at 15 minutes); one-shot tasks scheduled at :00 or :30 auto-fire up to 90 seconds early. **Again, load spreading** — even if Claude dogmatically picks `0 9 * * *`, the runtime adds jitter to spread requests.

**Only fires during REPL idle — protecting Claude from interruption**

> Jobs only fire while the REPL is idle (not mid-query).

If cron expires while Claude is handling another user prompt, the trigger is **delayed** until the current processing completes. This prevents cron and user prompts from colliding and breaking Claude's train of thought.

#### 3. Field-Level Description

CronCreate's field inventory:

- **`cron`** — 5-field expression (local timezone): `"minute hour day-of-month month day-of-week"`
- **`prompt`** — the prompt content to trigger when the time comes
- **`recurring`** — boolean, defaults to `true` (repeating); `false` for one-shot
- **`durable`** — legacy field with no actual effect

CronDelete only needs an `id` (returned by CronCreate); CronList takes no parameters. The truly interesting field design is all in CronCreate.

**Key design points**:

**cron uses industry-standard strings — no custom DSL**

`"0 9 * * *"` means every day at 9 AM — **directly reusing Unix crontab syntax**, no new syntax invented. This brings two direct benefits: first, users can read Claude's output and understand immediately without extra explanation; second, Claude's training data already contains abundant cron syntax examples, no additional teaching needed. **Reusing industry conventions to reduce cognitive overhead** is the core design of this field. A counterexample design would be a custom `{ minute: "*/5", hour: "*", ... }` JSON structure — looks more "structured" but both users and models would need to relearn.

**The value orientation of `recurring` defaulting to `true`**

Defaulting to `true` means "if unspecified, it's recurring" — this default intentionally biases toward **monitoring use cases**. Because the Cron family's typical scenarios are CI monitoring, deployment observation, periodic self-checks — all recurring. "One-shot reminders" are actually the minority that requires explicitly declaring `recurring: false`. The default value isn't chosen arbitrarily; it's an **implicit preference declaration for the typical use case**.

**Honest transparency of the `durable` legacy field**

The tool description explicitly stating "durable has no effect" is **honest transparency**. This field is a **historical artifact** — an early attempt at a persistent version that was later abandoned, but the field remains to avoid breaking changes. **Neither deleted nor hidden**, it explicitly tells Claude "this field does nothing, don't waste effort setting it."

#### 4. Schema Validation Rules

CronCreate's schema-level constraints are sparse; most constraints live in the runtime:

| Field | Type | Default | Schema Constraint |
|---|---|---|---|
| `cron` | string | none (required) | 5-field format, no deep validation |
| `prompt` | string | none (required) | No length limit |
| `recurring` | boolean | `true` | Boolean |
| `durable` | boolean | none | None (legacy) |

**The real constraints are all in the runtime**:

- **7-day cap** — runtime auto-deletes on schedule, not blocked at schema level
- **REPL idle trigger** — runtime state machine, inexpressible in schema
- **Jitter spreading** — runtime auto-adds offset; `"0 9 * * *"` in schema gets auto-nudged at runtime
- **Session-only lifecycle** — runtime in-memory state, not persistent behavior

The Cron family's key characteristic: **almost no hard constraints at the schema level; behavior is primarily guided by natural language in the tool description + runtime mechanisms as a safety net**. This is the complete opposite of AskUserQuestion's style of "schema minItems / maxItems hard blocking" — because cron syntax is too flexible, both `"7 * * * *"` and `"0 * * * *"` are valid, schema can't distinguish good from bad, only the description can teach Claude to pick wisely.

### ScheduleWakeup — The Specialized Version

CronCreate is the **general-purpose** scheduler. The /loop skill has its own specialized `ScheduleWakeup`, specifically for "dynamically-intervaled loops":

- **The caller is Claude itself**, not an external trigger
- **Loop context is automatically passed** — the prompt from the previous /loop iteration auto-triggers again
- **Has awareness of the 5-minute prompt cache TTL** — the tool description teaches Claude how to make different choices inside vs outside the cache window
- **Recommended range is 60-1200 seconds** (1 minute to 20 minutes)

**Division of labor with CronCreate**: general scheduling uses CronCreate; self-scheduling within /loop uses ScheduleWakeup. ScheduleWakeup is "a loop-specialized relative of the Cron family."

---

### Division of Labor with Neighboring Tools

The Cron family forms contrasts with the previous eleven tools:

| Dimension | Three Interaction Primitives | Positioning + Perception + Execution | Bash | Agent | Task Family | Web Duo | Cron Family |
|---|---|---|---|---|---|---|---|
| Role | Collaborative alignment | Editing code | Command execution | Spawning Claude | Externalizing working memory | Reaching the public internet | **Future triggering** |
| Tense | Present | Present | Present | Present | Cross-temporal | Present | **Future (scheduled)** |
| State location | None | Disk | None | Subagent | Runtime storage | None | **In-session with 7-day cap** |
| Naming duality | Enter/Exit | Read/Edit/Write | Single | Single | CRUD six-piece set | Fetch/Search sisters | **Create/Delete/List trio** |
| Primary benefit | User alignment | Precise code editing | Engineering workflow | Context space | Fighting forgetfulness | Controlled information interface | **Waiting for the external world to change** |

**Cron Family vs Task Family** — both are **cross-temporal state**, but in opposite directions:

- Task family: **Leave behind unfinished work** — hanging a future-tense todo in the present; state records "what should be done"
- Cron family: **Commit to proactively doing something in the future** — hanging a timed-trigger prompt in the present; state records "what to do at what time"

One is like a sticky-note box (manually checked), the other is like an alarm clock (automatically rings). Tasks are "Claude proactively checks the List"; Cron is "time arrives and Claude gets woken up." Both break past the limitation of "the AI main loop can't do anything while blocked," but through different channels.

**Cron Family vs Bash `run_in_background`** — both are **asynchronous**:

- Background Bash: "machine waits for command to finish" — gets a notification when done (one-time)
- Cron: "machine waits for time to arrive" — triggers each time the time comes (periodic or one-shot)

The former is **IO-async**, the latter is **time-async**. Background Bash can do things Cron can't (like waiting for CI to finish), and Cron can do things Bash can't (like checking every 5 minutes).

**Cron Family vs Agent** — both **create parallelism**:

- Agent: **spatial dimension** parallelism — forking a new context for a child Claude to work in
- Cron: **temporal dimension** parallelism — queuing a future trigger for the main Claude to handle later

**The Cron family's position in the tool ecosystem** — the first 11 tools are all "present-moment actions"; the Cron family is the only primitive that treats **future time** as a first-class citizen. It doesn't add some new capability; rather, it **provides trigger timing for all other capabilities**.

---

### Summary

The most interesting signal from the Cron family is that **"reusing industry conventions to reduce cognitive overhead" is visible at every layer**:

- **Naming layer**: Directly borrowing Unix crontab's 40-year-old terminology, no new concepts invented
- **Field layer**: The `cron` field uses the 5-field string standard syntax, no custom JSON DSL
- **Default value layer**: `recurring: true` aligns with typical monitoring use cases — one-shot is actually the minority requiring explicit declaration
- **Timezone semantics**: Local timezone by default, avoiding the UTC conversion pitfall that generations of sysadmins have fallen into
- **Schema layer**: Unusually sparse — because cron syntax is too flexible, both `"7 * * * *"` and `"0 * * * *"` are valid, schema can't distinguish good from bad

**Another unique signal is "server perspective written into the tool prompt"** — the constraint to avoid `:00` and `:30` puts system-level load-spreading responsibility into Claude's usage behavior. Most tools only care whether Claude uses them correctly, not about server pressure. Cron is a rare exception because it's the only tool that can create periodic requests the user doesn't notice.

**"Honest transparency" runs throughout**: session-only lifecycle stated upfront, 7-day cap requires Claude to proactively inform the user, `durable` legacy field explicitly marked "no effect", jitter mechanism explicitly exposed. Transparency beats polish — what Claude can't deliver should be stated clearly, leaving no room for misunderstanding between user and Claude.

**The dual-closure structure** is consistent with the Task family in the tenth installment: Create / Delete / List trio sharing a single session state, better covered together. The real design density is all in Create; Delete and List are the supporting observation + management tools.

The next article continues with [Monitor](monitor.md) — Cron is "wake up when the time comes," Monitor is "wake up when an event occurs." The former is proactive timed polling; the latter is reactive event-driven. Let's see how this "event stream primitive" is designed and how it divides labor with Cron.
