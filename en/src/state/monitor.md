This is the thirteenth installment in the Claude Code tools research series. The previous article, [The Cron Family](cron-family.md), covered how Claude **crosses time** to trigger actions. But Cron is "clock-driven": it fires on schedule regardless of what's happening externally.

In real-world engineering, there's another category of waiting scenarios: **"wait for something to happen"** without knowing the exact time. For example:

- "Tell me when ERROR appears in the logs" -- don't know when it will show up
- "Rebuild when a file changes" -- don't know when it will change
- "Notify me when PR status changes" -- don't know when it will change
- "Report each time a CI check lands" -- don't know the interval between checks

What these scenarios require is an **event-driven asynchronous waiting primitive** -- Claude deploys a "feeler," and it automatically senses when something happens externally.

This is why Monitor exists.

> Start with the [prerequisite article](../tool-mechanism.md) in this series -- it explains what tools are and how Claude uses them. This article follows the 4-layer framework proposed there.

## Monitor

Monitor is Claude Code's built-in **event stream listening tool**. Together with the other two "async waiting primitives," it forms a triumvirate:

| Tool | Trigger Condition | Semantics |
|---|---|---|
| **Bash `run_in_background`** | One-time task completion | "Tell me when the build is done" |
| **CronCreate** | A point in time arrives | "Remind me at 9am" |
| **Monitor** | Event stream (each stdout line = one event) | **"Tell me every time X happens"** |

The first two wait for "one thing" (a point). Monitor waits for **"an event stream" (a line)** -- it may never stop, running until timeout or until Claude actively stops it.

### Purpose

The core problem Monitor solves is "how Claude **continuously perceives changes in the external world**":

1. **Breaking past single notifications** -- Bash background sends only one completion notification; Monitor sends one for every event
2. **Event stream modeling** -- Each line of stdout = one notification, naturally aligned with Unix philosophy
3. **Two data sources** -- Shell command **or** direct WebSocket connection (an extremely rare tool design)
4. **Forced filter thinking** -- What should be emitted? What should be ignored? The prompt forces Claude to think it through
5. **Persistent listening** -- `persistent: true` keeps it alive for the entire session, for PR monitoring / long log tracking

Its **fundamental difference** from the Cron family:

- **Cron** = clock-driven; fires at a certain time point; time is the active party
- **Monitor** = event-driven; fires when an external action occurs; the event is the active party

Cron is "I check on you on schedule"; Monitor is "you call me when something happens" -- one is pull, one is push.

### A Concrete Example

**Scenario**: The user says **"I'm about to run a 20-minute model training job. Watch the log for me -- if there's an error, tell me immediately. Also report progress updates as they come."**

This is a classic "**long-running, events arrive at unpredictable times**" task.

#### Anti-pattern 1: Pure sleep-then-read

```
Bash(command: "sleep 1200 && cat train.log", timeout: 1300000)
```

**Problem**: If an error occurs during those 20 minutes, Claude has no idea. By the time it reads the log at the end, it's too late. **Early signals are lost.**

#### Anti-pattern 2: Timed polling

```
CronCreate(cron: "*/2 * * * *", recurring: true, prompt: "check train.log, report any ERRORs")
```

**Problem**: Polling every 2 minutes means an event could have occurred 1 minute 59 seconds ago before being detected. **High latency.** Plus, each poll re-reads the entire file and each Cron trigger consumes context.

#### Anti-pattern 3: Bash background tailing logs

```
Bash(command: "tail -f train.log", run_in_background: true)
```

**Problem**: A background task only notifies once upon **completion**. But `tail -f` never terminates on its own, so it never notifies. **Signal is lost.**

#### How Monitor Solves This

```
Monitor(
  command: "tail -f train.log | grep -E --line-buffered 'elapsed_steps=|Traceback|Error|FAILED|Killed|OOM'",
  description: "Training log: progress + errors",
  timeout_ms: 1500000
)
```

**What happens at runtime**:

- The runtime spawns a shell command, letting `tail -f` continuously follow the log
- `grep` only passes matching lines through stdout
- **Each line of stdout = one notification**, immediately delivered to the conversation
- Claude continues whatever it's doing (can chat with the user, can do other tasks)
- Each time `elapsed_steps=1000` progress or a `Traceback` error matches, Claude **automatically receives a notification**
- After 20-minute timeout, it ends automatically; or the user can actively stop it

From the user's perspective, the experience is:

```
[13:00] User: Watch train.log for me
[13:00] Claude: Got it -- monitoring is active. I'll report errors and progress as they come.
[13:03] Claude (auto-notification): Progress elapsed_steps=200
[13:07] Claude (auto-notification): Progress elapsed_steps=500
[13:12] Claude (auto-notification): Error -- Traceback (most recent call last):
                          File "train.py", line 42, in <module>
                          OOM: CUDA out of memory
              -> Training OOM'd at elapsed_steps=800. Suggest reducing batch_size.
```

**Key insight**: Monitor transforms Claude from **"active polling"** to **"passive receiving"** -- **it knows immediately every time an external event occurs**, with no polling, no waiting, and no context consumption.

### Dual Data Sources -- Command or WebSocket

Monitor has an extremely rare design -- **two data sources, pick one**:

**Data source A: Shell command**

The most common pattern, demonstrated in the previous section. Each line of stdout = one event.

**Data source B: WebSocket**

```
Monitor(
  ws: { url: "wss://events.example.com/stream", protocols: ["v1"] },
  description: "Subscribe to deployment event stream",
  timeout_ms: 300000
)
```

**What happens at runtime**:

- The runtime opens a WebSocket connection directly
- Each text frame the server pushes = one event
- Binary frames are labeled as `[binary frame, N bytes]`
- Connection close ends the monitoring

**Why build dedicated WebSocket support?**

Because `command: "websocat wss://..."` could also work, but it has a pile of pitfalls:
- Command-line escaping
- Extra process overhead
- Output buffering
- Whether websocat is even installed

Built-in WebSocket = one fewer process, one fewer layer of shell escaping, and normalized frame-to-event mapping. This is a **classic design of "using tools to eliminate fragility."**

I consider this the **most unexpectedly thoughtful feature** in the entire Claude Code tool ecosystem -- typical AI tool designs wouldn't think to make WebSocket a first-class citizen. Behind this is the designer's concrete imagination of "Claude will actually use this": agent-to-agent communication, subscription-based deployment events, long-lived push connections -- all use WebSocket.

### Trigger Conditions

The official Monitor prompt provides very clear **selection guidance**. Here's the summary:

**Scenarios where you should use Monitor**:

- **Notify every time X happens** (unknown number of times) -- "report every ERROR"
- **Notify every time X happens, until a known endpoint** -- "report each CI check, stop when all are done"
- **Waiting for a WebSocket event stream** -- server-push pattern

**Scenarios where you should NOT use Monitor**:

- **Waiting for just one thing to complete** -- use **Bash `run_in_background`** + an `until` loop that exits
- **Triggering at a specific time** -- use **CronCreate**
- **Sub-second dense events** -- rate limiting will auto-stop; need a more selective filter

One **particularly important pitfall**: the tool prompt explicitly warns:

> Don't use an unbounded command for a single notification.

If you just want "notify me once when the build finishes," use `Bash run_in_background` + `until grep -q "Ready" dev.log; do sleep 0.5; done` -- because **this loop will exit**, giving a one-time notification.

**Do not use** Monitor with `tail -f log | grep -m 1 "Ready"` -- because after `tail -f` matches "Ready," it won't SIGPIPE itself and will hang until timeout. **Monitor is optimized for "continuous" -- using it for a single event is the wrong tool.**

### Technical Implementation

#### 1. Naming

`Monitor`

A neutral noun capturing the tool's responsibility. Not `Watch` / `Tail` / `Subscribe` / `Listen` -- "Monitor" in the SRE context naturally carries the connotation of **"continuous observation + alerting when thresholds are crossed."** When Claude encounters this word, its first instinct is "set up a sentry, watch for events, call me when something happens," not "do a one-time grep" or "read an entire file." The name anchors the "event-driven" mental model upfront.

#### 2. Tool-Level Description

Monitor's description revolves around five things: **notification selection / event stream modeling / completeness (silence is not success) / output volume / data source preference**. Let's look at the most interesting parts:

**Opening line, setting the tone**

> Start a background monitor that streams events from a long-running script. Each stdout line is an event -- you keep working and notifications arrive in the chat.

Two phrases -- "streams events" + "each stdout line is an event" -- pin down Monitor's semantics: **this isn't a tool that "returns all output when the command finishes"; it's an "event stream tool."** Each line of stdout = one notification flowing into the conversation. This design fully aligns Monitor with Unix philosophy -- any command or script capable of line-buffered output (`tail -f` / `inotifywait -m` / while loops / custom Python) can become an event source.

**Three-way scenario classification -- choose your tool by "number of notifications"**

> Pick by how many notifications you need:
> - **One** ("tell me when the server is ready / the build finishes") -> use **Bash with `run_in_background`**
> - **One per occurrence, indefinitely** ("tell me every time an ERROR line appears") -> Monitor with an unbounded command
> - **One per occurrence, until a known end** ("emit each CI step result, stop when the run completes") -> Monitor with a command that emits lines and then exits

**The prompt opens by clarifying "how to choose your tool."** Three notification needs -> three tool choices. This prompt trains Claude to think about waiting primitives from the perspective of "how many notifications," rather than "how long to wait" or "what to wait for."

**Anti-polling principle -- single notifications shouldn't use Monitor**

> Don't use an unbounded command for a single notification. `tail -f`, `inotifywait -m`, and `while true` never exit on their own

If you just want "notify me once when the build finishes," use `Bash run_in_background` + `until grep -q "Ready" dev.log; do sleep 0.5; done` -- because **this loop will exit**, giving a one-time notification.

**Do not use** Monitor with `tail -f log | grep -m 1 "Ready"` -- because after `tail -f` matches "Ready," it won't SIGPIPE itself and will hang until timeout. Monitor is optimized for "continuous" -- using it for a single event is the wrong tool.

**Buffering textbook -- Unix pipe internals pitfall**

> Every pipe stage must flush per line or matches sit in its buffer unseen: `grep` needs `--line-buffered`, `awk` needs `fflush()`. `head` cannot flush at all -- `| head -N` delivers nothing until N matches accumulate, then ends the stream.

This prompt is rare to the point of extraordinary -- **it teaches Claude about Unix pipe buffering pitfalls directly.** Shell pipelines default to block buffering (usually 4KB), not line buffering. If Claude naively writes `tail -f log | grep ERROR`, grep will accumulate 4KB before flushing -- **events are delayed until the buffer fills** and the user sees "Monitor doesn't seem to be working."

The correct approach:
- `grep --line-buffered` -> flushes every line immediately
- `awk '{...; fflush()}'` -> explicitly flushes every line
- Avoid `head` -- it can't flush; it only outputs once N matches accumulate

**This is grizzled sysadmin tribal knowledge written into a tool prompt = Claude avoids the pitfalls from the start.** The designers clearly know Claude isn't good at these low-level details, so they write them directly into the prompt: you must use `--line-buffered` / `fflush()`, and avoid `head`.

**Silence is not success -- observability completeness philosophy**

> **Coverage -- silence is not success.** When watching a job or process for an outcome, your filter must match every terminal state, not just the happy path. A monitor that greps only for the success marker stays silent through a crashloop, a hung process, or an unexpected exit -- and silence looks identical to "still running." Before arming, ask: *if this process crashed right now, would my filter emit anything?* If not, widen it.

I consider this the **most profound statement** in the entire Monitor prompt. It's not about "how to use the tool" -- it's about "how to design observability." The core of observability design isn't "how to see the good" -- it's **"how not to miss the bad."**

- Naive approach: `tail -f run.log | grep --line-buffered "elapsed_steps="` -- only watching for progress signals
- Consequence: If the task crashes, there's no progress and no crash report; the user thinks "it's still running"
- Correct approach: `tail -f run.log | grep -E --line-buffered "elapsed_steps=|Traceback|Error|FAILED|assert|Killed|OOM"` -- **covering both progress + failure signals**

The **soul-searching question** in the original text -- *"if this process crashed right now, would my filter emit anything?"* -- directly teaches Claude the SRE daily self-reflection mindset: before arming any monitor, ask yourself -- if the task crashed right now, would my filter catch it? Writing this operational instinct into a tool prompt is effectively **teaching an AI "the thinking habits of a senior engineer" explicitly.**

**Output volume control -- selective does not equal only good news**

> Every stdout line is a conversation message, so the filter should be selective -- but selective means "the lines you'd act on," not "only good news."

**"Selective does not equal only good news"** -- this prevents Claude from misinterpreting "selective" as "filter out bad news." What you select is "lines you would act on," regardless of whether they're good or bad. This corroborates the silence philosophy above.

**Rate limiting warning -- the system actively stops high-volume monitors**

> Monitors that produce too many events are automatically stopped; restart with a tighter filter if this happens.

If a Monitor outputs 100 lines per second (e.g., a misconfigured `tail -f verbose.log` with no filter), the runtime will automatically stop that monitor because the conversation would be flooded. After Claude receives a "monitor was stopped due to high output rate" notification, it needs to **rewrite a more selective filter** and restart.

This prompt sets Claude's expectations: failure -> fix filter -> retry, rather than "why did it stop on its own?" This is the **core mechanism protecting conversation readability** -- forcing Claude to write high-quality filters.

**200ms batching transparency -- keeping multi-line events together**

> Stdout lines within 200ms are batched into a single notification, so multiline output from a single event groups naturally.

A hidden optimization: consecutive stdout lines within 200ms are merged into a single notification. Because a single "event" is sometimes multi-line (e.g., a Python Traceback outputs 5-10 lines at once), if each line sent a separate notification, the conversation would fragment. The 200ms window keeps "one event" presented as a whole.

**Telling Claude about the batch mechanism** -- so Claude knows a multi-line Traceback will arrive as one message and doesn't worry about "one event being split into 5 messages."

**Command vs WS preference -- built-in WebSocket is a first-class citizen**

> Prefer this [ws source] over `command: 'websocat wss://...'` -- it avoids the extra process and line-buffering pitfalls.

**Explicitly directs Claude to prefer the built-in ws**, not the websocat command line. The reasoning is made clear (one fewer process, one fewer layer of shell escaping, one fewer buffering pitfall), so Claude understands **"why" rather than just memorizing "which one to use."**

Typical AI tool designs wouldn't think to make WebSocket a first-class citizen. Behind this is the designer's concrete imagination of "Claude will actually use this": agent-to-agent communication, subscription-based deployment events, long-lived push connections -- all use WebSocket. This is a **classic design of "using tools to eliminate fragility."**

#### 3. Field-Level Descriptions

Monitor has 5 fields:

- `command` -- shell command (data source A)
- `ws` -- WebSocket configuration (data source B, containing url + protocols); mutually exclusive with command
- `description` -- description (appears in every notification)
- `timeout_ms` -- timeout (default 300000 = 5 minutes; maximum 3600000 = 1 hour)
- `persistent` -- boolean; true = stays alive for the entire session (ignores timeout)

Few fields, but each has non-trivial design behind it:

**command and ws are mutually exclusive -- dual data sources, pick one**

This is Monitor's most distinctive field design. Shell commands go through stdout; WebSocket goes through frames. They're mutually exclusive but **semantically fully aligned**:

- Shell command: each line of stdout = one event
- WebSocket: each text frame = one event (even if the frame contains multiple lines internally, it counts as one notification)

For Claude, it only needs to remember one mental model -- "one event = one notification" -- but can connect to two different physical data sources. Binary frames are normalized to `[binary frame, N bytes]` placeholders without breaking stdout semantics. Server close / error -> ends monitoring; the close code or error message is reported.

**description is a visible label on every notification**

> Write a specific `description` -- it appears in every notification ("errors in deploy.log" not "watching logs").

The description isn't a comment for Claude's own reference; it's a **label displayed in every notification**. So naming should be specific ("Training log: progress + errors") rather than vague ("watching logs"), letting Claude see at a glance "who sent this" when a notification arrives.

This is a **classic design of "every field has a user-visible location"** -- field naming can't be sloppy because it will appear repeatedly in the event stream.

**timeout_ms hard ceiling**

Default 5 minutes; maximum 1 hour. This limit exists to **prevent Claude from forgetting a monitor is still running**. If Claude starts a monitor and then forgets about it, timeout acts as a safety net -- no zombie listeners.

Scenarios exceeding 1 hour must explicitly opt-in to `persistent: true`, making Claude explicitly declare the intent "I know this is long-term monitoring."

**persistent -- first-class entry point for session-level monitoring**

```
Monitor(
  command: "...",
  persistent: true
)
```

`persistent: true` ignores timeout and stays alive until the session ends or TaskStop manually stops it. Used for long-term monitoring: PR / issue tracking, log tailing, server status. **Default false** is a **conservative bias** -- long-term monitoring is dangerous behavior that requires Claude to actively opt in.

#### 4. Schema Validation Rules

Monitor's schema is moderately complex -- the key constraints are at the harness / runtime layer:

| Field | Type | Constraints |
|---|---|---|
| `command` | string | Mutually exclusive with `ws` |
| `ws` | object | Mutually exclusive with `command`; contains url + protocols |
| `description` | string | Required |
| `timeout_ms` | number | Optional, default 300000, max 3600000 |
| `persistent` | boolean | Optional, default false |

The real hard constraints aren't in the schema; they're in the runtime:

1. **command / ws pick one** -- providing both or neither causes an error
2. **description is required** -- because it must be displayed in notifications; empty is not allowed
3. **timeout_ms ceiling of 3600000** -- exceeding it is hard-rejected (when not persistent)
4. **Rate limiting runtime interception** -- too many events -> auto-stop and notify Claude
5. **persistent + timeout_ms semantics** -- when persistent=true, timeout_ms is ignored; no conflict, no error

These constraints are all **loud fail or loud stop**: either it won't start (parameter error), or it starts but gets explicitly terminated (rate limit). There's no silent continuation that leads to a "Monitor appears to be running but isn't actually doing anything" dangling state.

---

### Division of Labor with Neighboring Tools

Monitor contrasts with the previous twelve tools, completing the **waiting primitive triumvirate**:

| Dimension | Bash `run_in_background` | CronCreate | Monitor |
|---|---|---|---|
| What it waits for | One-time task completion | A time point arriving | **Event stream** |
| Trigger count | 1 time (command exits) | N times (each match fires) | **1 notification per event** |
| Wake-up mechanism | Task exit notification | Time-point trigger | **Each stdout line / WS text frame wakes** |
| Input source | Command | Cron expression | **Command + WebSocket** |
| Typical scenario | "Wait for CI to finish" | "Check every 5 minutes" | **"Alert when error log appears"** |
| Conservative bias | "Notify when it exits" | "Fire when the time comes" | **"Only emit actionable signals"** |

The previous 12 tools all "wait for one thing" or perform "synchronous actions." Monitor "waits for an event stream" -- transforming Claude from an executor that "actively polls" into an observer that "deploys a listening sentry and reports when the external world moves."

**Monitor vs Cron comparison** -- both "wake Claude periodically," but the trigger conditions are fundamentally different:

- Cron is **time-driven**: fires when the scheduled time arrives (regardless of whether anything happened)
- Monitor is **event-driven**: fires when an event occurs (regardless of how long it's been)

These correspond to two semantics of "waiting": waiting for the calendar vs. waiting for the external world to change.

**Monitor vs Bash `run_in_background` comparison** -- one is a point, the other is a line:

- Bash background: waits for **one thing to complete** (start -> block -> notify once -> end)
- Monitor: waits for **an event stream to keep arriving** (start -> block -> notify once per event -> until timeout / active stop / command exits)

If the task is "wait for CI to finish," use Bash `run_in_background`; if the task is "watch the log and yell at me for every error," use Monitor.

**Monitor vs Task family comparison** -- both involve **cross-temporal state**, but in opposite directions:

- Task family: **stores "things to do" in the system** -- Claude must actively List / Get to know about them
- Monitor: **pulls an event stream from the external world** -- events push to Claude when they arrive

The former is pull; the latter is push. **The "anti-polling principle" is most apparent in Monitor** -- it explicitly states that you cannot use `tail -f` or `while true` for a single notification; that wastes monitor resources.

**Monitor's position in the tool ecosystem**: It upgrades "waiting for the external world to change" from Bash's primitive form (`sleep + poll`) into a **structured event stream primitive**. For the first time, "waiting" becomes a first-class citizen in Claude's toolbox.

---

### Summary

Monitor's elegance lies not in the functionality itself -- "letting AI continuously monitor" -- but in how its signal distribution is **extremely biased toward the observability methodology in the tool description**:

- **Naming** -- minimal; one word from SRE context
- **Tool-level description** -- extremely long; 8 segments of constraints covering notification selection / event stream modeling / buffering textbook / silence is not success / output volume / rate limiting / 200ms batching / data source preference
- **Field-level descriptions** -- 5 fields, each with non-trivial decisions behind it (command/ws mutual exclusion, description visible in every notification, timeout_ms hard ceiling preventing forgotten monitors, persistent explicit opt-in)
- **Schema validation** -- moderate; the real hard constraints are at the runtime layer (command/ws pick one, description required, timeout ceiling, rate limiting active stop)

What makes Monitor distinctive is that it **shifts the emphasis of "event stream tool completeness" from parameter validation to prompt education**: the schema only locks down the basic shape, but the tool description packs in grizzled sysadmin intuition about Unix pipe buffering + SRE observability philosophy of silence-is-not-success + conversation-protecting rate limiting strategies. It effectively takes the general capability of "Claude deploying a reliable event listening sentry" and distills it into a waiting primitive that is **event-driven, failure-visible, flood-protected, and dual-data-source.**

The next article continues with [Background Mechanism](background.md) -- the final installment of the series. The previous 13 articles all dissected **individual tools**; this one crosses tool boundaries to examine how `run_in_background`, a cross-cutting parameter, permeates Bash / Agent / Task family / Monitor, elevating "async" into a first-class semantic in Claude Code.
