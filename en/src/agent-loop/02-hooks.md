The previous article, [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md), covered **permission approval** in the loop — the interception layer between the LLM emitting a `tool_use` and the tool actually running, where the user gets a say.

But users want to inject custom logic into the loop for more than just "approve or deny a tool." They might want to:

- **Inspect a command before every Bash execution** (pre-tool interception)
- **Run a formatter after every Edit** (post-tool cleanup)
- **Load team-shared project rules at the start of every session** (session-start injection)
- **Back up the current conversation before every compaction** (pre-compact snapshot)
- **Force the loop to keep going for one more round when it's about to stop** (stop blocking)

**All of these need hooks.** Hooks are the general-purpose answer to "how does a user inject custom logic into the loop."

Permission approval is a specialization of hooks — the general hook mechanism covers 20+ different injection points.

Understanding hooks means answering a few questions:

- How many kinds of hooks are there, and where in the loop does each one attach?
- What does a hook receive, what does it return, and what can it do?
- Can a hook **block** an action (e.g., forbid a tool from running)?
- Can a hook **modify** the outcome of an action (e.g., alter tool_result content)?
- What happens if a hook hangs — is there a timeout?

## 26 Hook Events

Claude Code has **far more hook attachment points than people usually assume**. The full list, grouped by where they sit in the loop's lifecycle:

**Session lifecycle**:
- `SessionStart` — when a new session begins
- `SessionEnd` — when a session exits
- `Setup` — initial configuration, during the setup phase
- `ConfigChange` — when a config file changes

**User input / submission**:
- `UserPromptSubmit` — before the user's Enter press is processed
- `Elicitation` / `ElicitationResult` — when clarification is needed from the user, and after it's received

**Tool lifecycle**:
- `PreToolUse` — before every tool executes
- `PostToolUse` — after every tool executes successfully
- `PostToolUseFailure` — after a tool execution fails
- `PermissionRequest` — when permission approval is triggered (one of the race participants from the previous article)
- `PermissionDenied` — after permission is denied

**Turn / stop**:
- `Stop` — when the loop is about to end (the LLM returned without a `tool_use`, ready to exit)
- `StopFailure` — when stop handling errors out

**Task family**:
- `TaskCreated` — when a Task is created
- `TaskCompleted` — when a Task completes

**Compaction**:
- `PreCompact` — before compaction runs
- `PostCompact` — after compaction runs
- `InstructionsLoaded` — after instructions (including CLAUDE.md, etc.) are loaded

**Subagent**:
- `SubagentStart` — when a subagent starts
- `SubagentStop` — when a subagent stops
- `TeammateIdle` — in team-collaboration scenarios, when a teammate goes idle

**File / workspace**:
- `FileChanged` — when a file is changed externally
- `CwdChanged` — when the cwd changes
- `WorktreeCreate` / `WorktreeRemove` — worktree creation / removal

**Miscellaneous**:
- `Notification` — when a notification fires
- `Setup` — initial configuration (duplicate entry, already listed above)

**26 events in total.** Each one corresponds to a specific moment in the loop. The user registers handler logic for that event in `settings.json`, and Claude Code automatically invokes it when that moment arrives.

## 4 Kinds of Executors — How a Hook Actually Runs

When a user registers a hook in `settings.json`, they can implement the handler logic in 4 different ways:

**1 · `command` — shell command**

The most common approach: declare a shell command, which Claude Code spawns a subprocess to run at that moment.

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{ "type": "command", "command": "npx prettier --write $CLAUDE_FILE_PATHS" }]
    }]
  }
}
```

The hook gets its input via environment variables (e.g., `$CLAUDE_FILE_PATHS`) and passes its decision back via stdout / exit code.

**2 · `prompt` — a prompt**

Send a prompt to the LLM and let it handle things:

```json
{ "type": "prompt", "prompt": "Analyze whether this change introduces a security issue. Reply only YES or NO." }
```

The hook's body is **another model call**. Used for complex judgment calls — the user doesn't want to write rules, they'd rather let the AI decide.

**3 · `agent` — an agent subtask**

Launch a full subagent (the hook-shaped version of the Agent tool):

```json
{ "type": "agent", "agentType": "general-purpose", "prompt": "..." }
```

Heavier than `prompt`, but lets the subagent run its own complete loop.

**4 · `http` — HTTP webhook**

Send the event to an external service over HTTP:

```json
{ "type": "http", "url": "https://internal-hooks.company.com/pre-tool-use" }
```

Used for **cross-machine** automation — for example, a company's security team maintains a central policy service, and every Claude Code user's `PreToolUse` gets sent there for a decision.

**Different executors cover different levels of complexity**: command (simple scripts), prompt (a single LLM judgment), agent (a full subagent), http (cross-machine policy).

## Can a Hook Block, Can It Modify

The key question: is a hook merely an **observer**, or can it **influence** the loop's behavior?

**Answer: it can observe, and it can influence — but it depends on the event type.**

**Block**: a hook returns a `block` decision, or exits with code 2, and the loop takes the blocking branch. For example, if `PreToolUse` blocks, that tool simply doesn't run (it falls back to a tool_result with `is_error`).

**Modify**: a hook can attach `additional_context` in its return value — a chunk of extra content that gets inserted into the tool_result as an `<attachment>`, which the LLM will read the next time it sees that tool_result. This capability mainly lives in `PostToolUse` — the hook observes the tool's result and appends an "annotation" for the LLM.

**Decision shape** (what a hook returns):

```json
{
  "continue": true,             // false = abort the whole loop
  "decision": "block",           // or "approve" or undefined
  "reason": "...",               // the reason for blocking; the LLM will see this
  "additional_context": "..."    // annotation appended to the tool_result
}
```

Mapped onto the loop's state machine, a hook block moves the loop from "proceeding normally" into a "blocking / recovery" branch.

**The semantics of blocking differ by hook event**:
- **PreToolUse block** — the tool doesn't run; an `is_error` tool_result is generated to tell the LLM
- **PostToolUse block** — a `hook_stopped_continuation` attachment is appended, and the loop is forced to exit
- **Stop block** — the loop, about to end, gets intercepted by the hook and is forced to run one more round (the user can tell the LLM "don't stop yet, think it over some more")
- **UserPromptSubmit block** — the user's input is rejected outright, never enters the messages array, and the UI shows a notice

**This reveals a design insight**: hooks aren't a simple pub-sub event system — they're **programmable intervention points on the loop**, letting the user change which branch the loop takes.

## Sync or Async

**Sync by default** — the hook blocks the loop until it returns.

**Default timeout**: `TOOL_HOOK_EXECUTION_TIMEOUT_MS = 10 min`. Ten minutes is a generous ceiling — because a hook might be an LLM call, or a CI trigger, and those typically take anywhere from a few seconds to a few minutes. Past 10 minutes the hook gets killed and the loop moves on.

**But it can also be configured as `async`**:

```json
{ "type": "command", "command": "...", "async": true }
```

- **`async: true`** — fire-and-forget: the hook starts, then immediately returns control, and the loop doesn't wait
- **`asyncRewake: true`** — a more special case: after starting async, **if the hook exits with code 2, it re-wakes the LLM** — meaning "I've been thinking in the background for a while, and now I have something to say — please bring the model back to handle it"

**`asyncRewake` is a subtle mechanism** — it lets a background task **actively notify the loop to wake up and keep processing** once it's done. For example: a code analysis that takes 5 minutes — the user doesn't want to wait in the original conversation, so it runs async, and once the result is ready it automatically returns to the conversation to continue. It's an elegant implementation of "the loop waking up on an event."

## What Happens When a Hook Fails

When a hook errors out (non-zero and non-2 exit code, malformed JSON, a thrown exception), **the loop doesn't crash** — it takes the `non_blocking_error` branch:

- The error is logged
- The tool still runs (in the pre-tool case), or the result is simply used as-is (in the post-tool case)
- The user sees no obvious error

**Design philosophy: a hook is an optional enhancement, not part of the critical path.** A broken hook doesn't affect the main flow — it just means whatever enhancement that hook was supposed to provide didn't happen this time.

**But there's an exception**: if a hook explicitly returns `decision: block` or `continue: false`, that's a valid decision from the hook, and the loop honors it. Only **unexpected errors** go non-blocking — an explicit block decision always takes effect.

## The Relationship Between Hooks and Permission Approval

The previous article covered permission approval — a race between 3 sources: the user clicking, a hook, and the classifier.

**The hook in that race** is the `PermissionRequest` hook. When a user registers this hook in `settings.json`, they're entering the race — supplying a judgment that can auto-approve.

**For example**:

```json
{
  "hooks": {
    "PermissionRequest": [{
      "hooks": [{ "type": "command", "command": "./ci-safety-check.sh" }]
    }]
  }
}
```

When Claude Code needs approval, it launches `ci-safety-check.sh`, which might query an internal security policy database and quickly return "allow" or "deny." The user's UI hasn't even popped up yet, and the hook has already answered.

**This is what explains the race design from the previous article** — the hooks system turns "the approval decision" into a **pluggable problem**. Whoever answers first wins: the user clicking (slow but authoritative), a hook (medium speed), a classifier (fast). All three cooperate, and whichever finishes first wins.

## Hooks Generalize Permission Approval

Permission approval focuses on one thing: **whether a given tool call is allowed to go through.**

Hooks generalize this capability — users can **inject decisions / observations / extra content / blocking** at **26 different points**. Permission approval is one specialization of that general hook capability (the `PermissionRequest` event).

**Where this generalization pays off**:
- A session-start hook can do team-level configuration injection (e.g., uniformly loading project rules)
- A pre-tool hook can do audit logging (recording every call)
- A pre-compact hook can do backups (snapshotting the current conversation to disk)
- A stop hook can force the loop to run one more round (e.g., "don't stop until the tests pass")
- A cwd-change hook can automatically load rules for a different project

**Every one of these is a "programmable intervention point on the loop"** — users can write custom logic at these points without touching Claude Code's source.

## Summary

- **26 hook events** cover every stage of the loop's lifecycle
- **4 kinds of executors**: command (shell command), prompt (LLM judgment), agent (subagent), http (webhook)
- **Block and Modify** — a hook can block an action, append content to a tool_result, or force a state transition in the loop
- **Sync / async / asyncRewake** — sync by default with a 10-minute timeout; async is fire-and-forget; asyncRewake automatically re-wakes the LLM once a background task finishes
- **Failure is non-blocking** — a broken hook lets the loop continue, unless it returned an explicit block decision
- **Permission approval = one specialization of hooks** — the `PermissionRequest` event is what makes permission approval programmable

The next article, [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md), covers the **concrete mechanics** of tool execution: when multiple `tool_use` calls arrive at once, are they run in parallel or in sequence? What happens when a tool crashes? Which tools can safely run in parallel, and which must run sequentially?

---

## References

**Key file locations** (v2.1.220):
- `src/entrypoints/sdk/coreTypes.ts` — the enum of 26 hook events
- `src/schemas/hooks.ts` — the 4 kinds of executors (command / prompt / agent / http)
- `src/utils/hooks.ts` — the central dispatcher, `executeHooks()`, `executePreToolHooks()`, etc.
- `src/services/tools/toolHooks.ts` — pre/post tool hook trigger points
- `src/query/stopHooks.ts` — stop-hook loop-blocking logic
- `src/hooks/toolPermission/PermissionContext.ts` — how the permission hook joins the race

**Related articles**:
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) — permission approval is a specialization of hooks
- [03 · From Reading Files to Parallel Scheduling](03-parallel-scheduling.md) — next up: the concrete mechanics of tool execution

**Anthropic official docs**:
- [Claude Code hooks](https://code.claude.com/docs/en/hooks) — the configuration format for the `hooks` section in `settings.json`
