Previous chapter [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) laid out **permission approval** in the loop — a layer sitting between the LLM emitting a tool_use and the tool actually executing, letting the user weigh in.

But users want to inject custom logic into the loop in ways that go beyond "approve or deny a tool." They might want to:

- **Inspect every Bash command before it runs** (pre-tool interception)
- **Run a formatter after every Edit** (post-tool cleanup)
- **Load team-shared project rules at the start of every session** (session-start hook)
- **Snapshot the current conversation before every compaction** (pre-compact backup)
- **Force the loop to keep going for another turn when it's about to stop** (stop blocking)

**All of these need hooks**. Hooks are Claude Code's general answer to "let the user inject custom logic into the loop."

Permission approval is a specialization of hooks — the general hooks mechanism covers 20+ distinct insertion points.

Understanding hooks means answering a few questions:

- How many kinds of hooks are there, and where in the loop does each one attach?
- What does a hook receive, what can it return, and what can it do?
- Can a hook **block** an action (e.g., forbid a particular tool call)?
- Can a hook **modify** the outcome of an action (e.g., alter tool_result content)?
- What happens if a hook hangs — is there a timeout?

## 26 hook events

Claude Code has **far more hook attachment points** than people usually assume. Here's the complete list, grouped by where they sit in the loop's lifecycle:

**Session lifecycle**:
- `SessionStart` — when a new session begins
- `SessionEnd` — when a session exits
- `Setup` — during initial configuration (Setup phase)
- `ConfigChange` — when configuration files change

**User input / submission**:
- `UserPromptSubmit` — before the user's Enter-press is submitted
- `Elicitation` / `ElicitationResult` — when user clarification is needed, and after it's received

**Tool lifecycle**:
- `PreToolUse` — before every tool execution
- `PostToolUse` — after every successful tool execution
- `PostToolUseFailure` — after a failed tool execution
- `PermissionRequest` — when permission approval is triggered (one of the race participants from the previous chapter)
- `PermissionDenied` — after permission is denied

**Turn / Stop**:
- `Stop` — when the loop is about to end (the LLM returns without a tool_use, ready to exit)
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
- `Setup` — initial configuration (duplicate — already listed above)

**26 events in total**. Each corresponds to a specific moment in the loop; users register handler logic for that event in `settings.json`, and Claude Code invokes it automatically when that moment arrives.

## 4 kinds of executors — how a hook actually runs

Users register a hook in `settings.json` and can implement its handler logic in 4 different ways:

**1 · `command` — a shell command**

The most common approach: declare a shell command, and Claude Code spawns a subprocess to run it at the appropriate moment.

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

The hook receives input via environment variables (e.g., `$CLAUDE_FILE_PATHS`) and communicates its decision back via stdout / exit code.

**2 · `prompt` — a prompt**

Send a prompt to the LLM and let it handle the decision:

```json
{ "type": "prompt", "prompt": "Analyze whether this change introduces a security issue. Reply only YES or NO." }
```

The hook body is **another model call**. Used for complex judgment calls — when the user doesn't want to write rules and would rather let the AI decide.

**3 · `agent` — a subagent task**

Launch a full subagent (the hook-form of the Agent tool):

```json
{ "type": "agent", "agentType": "general-purpose", "prompt": "..." }
```

Heavier than `prompt` — but lets the subagent run its own complete loop.

**4 · `http` — an HTTP webhook**

Send the event to an external service over HTTP:

```json
{ "type": "http", "url": "https://internal-hooks.company.com/pre-tool-use" }
```

Used for **cross-machine** automation — for example, a company's security team runs a central policy service, and every Claude Code user's `PreToolUse` events get sent there for a decision.

**Different executors cover different levels of complexity**: command (a simple script), prompt (a single LLM judgment), agent (a full subagent), http (cross-machine policy).

## Can a hook block, and can it modify?

The key question: is a hook merely an **observer**, or can it actually **influence** the loop's behavior?

**Answer: it can observe, and it can influence — but it depends on the event type.**

**Block**: a hook returns the decision `block`, or exits with code 2, and the loop takes the blocking branch. For example, if `PreToolUse` blocks, that tool simply doesn't execute (it falls back to an `is_error` tool_result).

**Modify**: a hook can attach `additional_context` in its return value — a chunk of extra content that gets inserted into the tool_result as an `<attachment>`, which the LLM will see the next time it reads that tool_result. This capability lives mainly in `PostToolUse` — the hook observes the tool's result and appends an "annotation" for the LLM.

**Decision shape** (the hook's return body):

```json
{
  "continue": true,             // false = abort the entire loop
  "decision": "block",           // or "approve", or undefined
  "reason": "...",               // the reason for blocking, visible to the LLM
  "additional_context": "..."    // annotation appended to the tool_result
}
```

Mapped onto the loop's state machine, a hook block moves the loop from its "normal advance" branch into a "blocking / recovery" branch.

**The block semantics differ by hook event**:
- **PreToolUse block** — the tool doesn't execute; an `is_error` tool_result tells the LLM why
- **PostToolUse block** — a `hook_stopped_continuation` attachment is appended, and the loop force-exits
- **Stop block** — when the loop is about to end, the hook intercepts it and forces another turn (a user can effectively tell the LLM "don't stop — think it through some more")
- **UserPromptSubmit block** — the user's input is rejected outright, never enters `messages`, and the UI shows a notice

**This reveals a design insight**: hooks aren't a simple pub-sub event system — they're **programmable intervention points in the loop** that let the user redirect which branch the loop takes.

## Sync or async

**Sync by default** — the hook blocks the loop until it returns.

**Default timeout**: `TOOL_HOOK_EXECUTION_TIMEOUT_MS = 10 min`. Ten minutes is a generous ceiling — because a hook might be an LLM call, might be triggered by CI, and typically takes anywhere from a few seconds to a few minutes. Past 10 minutes, the hook is killed and the loop moves on.

**But it can also be configured as `async`**:

```json
{ "type": "command", "command": "...", "async": true }
```

- **`async: true`** — fire-and-forget; the hook launches and returns immediately, and the loop doesn't wait
- **`asyncRewake: true`** — a more special case — after launching async, **if the hook exits with code 2, it re-wakes the LLM** — meaning "I've been thinking in the background for a while, I have something to say now, please bring the model back to process it"

**`asyncRewake` is a subtle mechanism** — it lets a background task actively notify the loop to wake up and continue once it finishes. For example: a code analysis that takes 5 minutes, which the user doesn't want to wait for inline — run it async, and once the result is ready, it automatically returns to the conversation to continue. It's an elegant implementation of "event-driven loop wakeup."

## What happens when a hook fails

If a hook errors out (non-zero, non-2 exit code; malformed JSON; a thrown exception), **the loop doesn't crash** — it takes the `non_blocking_error` branch:

- The error is logged
- The tool still executes (in the pre-tool case), or the result is simply accepted as-is (in the post-tool case)
- The user sees no visible error

**Design philosophy: a hook is optional enhancement, not part of the critical path**. If a hook dies, the main flow is unaffected — the enhancement it was meant to provide simply doesn't happen this time.

**But there's an exception**: if a hook explicitly returns `decision: block` or `continue: false`, that's a valid decision from the hook, and the loop honors it. Only **unexpected errors** are non-blocking — an explicit block decision always takes effect.

## The relationship between hooks and permission approval

The previous chapter covered permission approval — a race among 3 sources: the user clicking, a hook, and the classifier.

**The hook there** is the `PermissionRequest` hook. When a user registers this hook in `settings.json`, they're entering the race — supplying an automated approval judgment.

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

When Claude Code needs an approval decision, it launches `ci-safety-check.sh`, which might query an internal security policy database and quickly return "allow" or "deny." The user's UI hasn't even popped up yet, and the hook has already answered.

**This explains the race design from the previous chapter** — the hooks system turns "the approval decision" into a **pluggable problem**. Whoever answers fastest wins: the user clicking (slow but authoritative), the hook (medium), the classifier (fast). All three cooperate, and whoever finishes first wins.

## The generality of hooks relative to permission approval

Permission approval focuses on one thing: **whether a given tool call passes or not**.

Hooks generalize this capability — users can **inject decisions / observe / append content / block subsequent steps** at **26 distinct points**. Permission approval is one specialization of that general hooks capability (the `PermissionRequest` event).

**The value of this generalization**:
- A session-start hook can inject team-level configuration (e.g., uniformly loading project rules)
- A pre-tool hook can build an audit log (recording every call)
- A pre-compact hook can create backups (snapshotting the current conversation to disk)
- A Stop hook can force the loop to run one more turn (e.g., "don't stop until the tests have run")
- A cwd-change hook can automatically load rules for a different project

**Each of these is a "programmable intervention point on the loop"** — users can write custom logic at these points without touching Claude Code's source code.

## Conclusion

- **26 hook events** cover every stage of the loop's lifecycle
- **4 kinds of executors**: command (shell command), prompt (LLM judgment), agent (subagent), http (webhook)
- **Block and modify** — a hook can block an action, append content to a tool_result, or force a state transition in the loop
- **Sync / async / asyncRewake** — sync with a 10-minute timeout by default; async is fire-and-forget; asyncRewake automatically re-wakes the LLM once a background task completes
- **Failures are non-blocking** — if a hook dies, the loop continues, unless it returned an explicit block decision
- **Permission approval = a specialization of hooks** — the `PermissionRequest` event is what makes permission approval programmable

Next chapter [03 · From File Reads to Parallel Scheduling](03-parallel-scheduling.md) covers the **concrete mechanics** of tool execution: when multiple tool_use calls arrive at once, are they run in parallel or in sequence? What happens when a tool crashes? Which tools can safely run in parallel, and which must run sequentially?

---

## References

**Primary file locations** (v2.1.220):
- `src/entrypoints/sdk/coreTypes.ts` — the enum of 26 hook events
- `src/schemas/hooks.ts` — the 4 executor kinds (command / prompt / agent / http)
- `src/utils/hooks.ts` — the central dispatcher, `executeHooks()`, `executePreToolHooks()`, etc.
- `src/services/tools/toolHooks.ts` — pre/post tool hook trigger points
- `src/query/stopHooks.ts` — Stop hook logic for blocking the loop
- `src/hooks/toolPermission/PermissionContext.ts` — the permission hook's participation in the race

**Related chapters**:
- [01 · From Tool Declaration to Pre-Execution Approval](01-tool-permission.md) — permission approval as a specialization of hooks
- [03 · From File Reads to Parallel Scheduling](03-parallel-scheduling.md) — next chapter: the concrete mechanics of tool execution

**Official Anthropic docs**:
- [Claude Code hooks](https://code.claude.com/docs/en/hooks) — the configuration format for the `hooks` section in `settings.json`
