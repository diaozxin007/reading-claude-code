The previous article, [00 · Intro · From Chat Window to Loop](00-intro.md), laid out the loop's 5-line skeleton: call the LLM, check for `tool_use`, run it if present, exit if not.

This article digs into the **first thing** that happens at every step of the loop: how does the LLM know which tools it can call? And once it declares a call, what still stands between that declaration and the tool actually running?

Getting this straight means answering a few questions:

- How does the LLM know Read is available in the current session?
- If the LLM says it wants to call Read, does that call actually happen?
- If not, what happens in between?
- Who decides whether a given call is allowed to proceed?

## Tools — the Third Segment of the API Request

The previous article described the loop as sending a messages array on every LLM call. But a full API request actually has more than just messages:

```
POST /messages
{
  system:   "...",     ← system prompt
  tools:    [...],     ← list of available tools (this article's subject)
  messages: [...]      ← conversation history
}
```

All three segments get bundled together and sent to the LLM. The messages segment changes every turn; the tools and system segments stay relatively stable within a session.

**The LLM only calls tools that are listed in the tools segment** — it was trained to treat `tool_use.name` as something that must be picked from the declared tools. A tool that isn't in the tools list simply won't get called, because the model has no idea it exists.

So the LLM being able to call Read presupposes that Claude Code has already **declared** Read in the tools segment.

## What a Tool Declaration Looks Like

The tools segment is an array, with each element declaring one tool. A tool declaration has three fields:

- **name** — the tool's name, the string that shows up in `tool_use.name` on the LLM's reply
- **description** — explains what the tool does, when to use it, when not to, and what its boundaries are
- **input_schema** — a JSON Schema for the parameters, declaring what shape of input the tool accepts; the LLM's `tool_use.input` must conform to this schema

What does the LLM rely on to decide whether to call a given tool? **Entirely the description.** The clearer your description, the more accurately the LLM judges. A poorly written description leads the LLM to use the tool in the wrong situation, or ignore it altogether.

A deeper breakdown of tool definitions themselves — the 4-layer contract, the specific constraints of JSON Schema, how Claude Code organizes multiple tools, MCP dynamic registration — is covered in the prerequisite article of the tools research series. All this article needs is: the tools segment is a **menu of tools handed to the LLM**, fixed once and sent along with every LLM call thereafter.

## From LLM Output of tool_use to Tool Execution — There's a Step In Between

Now the LLM has received the tools segment, sees that Read exists, sees your question ("help me look at auth.py"), and replies with a `tool_use`:

```
{
  role: 'assistant',
  content: [
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file_path: 'auth.py' } }
  ]
}
```

**What happens next?**

By the loop skeleton, this should be "run the tool, get the result, append the message." But in reality, **there's a step wedged in between**:

**Permission approval.**

Reading an ordinary file might get auto-approved. But if the LLM says it wants to:
- `Bash rm -rf /some/dir` — delete a directory, dangerous, must get user confirmation
- `Edit /etc/passwd` — modify a sensitive system file, must confirm
- The first call of a given `Bash` command — the user may need to sign off on each new command at least once

In these cases, Claude Code **does not execute the tool directly** — it first pops up an approval prompt and waits for the user to click "allow" or "deny" before continuing.

## The One Exception to "No One Participates Mid-Loop"

The previous article established a key premise: **the loop is an automatic cycle, with no user involved in the middle.**

**Permission approval is the sole exception to this premise.**

Why must this exception exist? Because the loop keeps turning on its own, with nobody watching in between. Without this interception layer of permission approval, if the LLM says it wants to `rm -rf`, the loop would just do it — the user wouldn't have time to react, and the files would already be gone.

The point of permission approval is: **to deliberately bring the user briefly back into the picture while the loop is otherwise running automatically** — only at this one point of approval, nowhere else.

Other related mechanisms follow the same logic, but each intervenes differently:
- **Permission approval** — blocks the loop, waiting on user input (the loop stops, a dialog pops up, the user decides)
- **Interrupt** — the user actively interrupts the loop (the loop is running, the user hits Ctrl-C, only then does the loop stop)
- **maxTurns** — no user involvement needed, automatically stops once a turn limit is hit (a hard safety valve)

The three complement each other, together covering the "necessary exceptions" to the premise that "the loop runs automatically."

## The 6 Levels of Approval Rule Sources

Users don't want to be interrupted **every single time** — if every Read required a click to allow, users would go mad. So Claude Code's permission system needs to **remember user preferences**: which tools/commands to auto-approve, which to ask about every time, and which to always forbid.

These preferences come from **6 different levels**:

| Source | Priority | Scope | Example |
|---|---|---|---|
| **denyRule** (explicit deny) | highest | always deny, never ask | `Bash(rm -rf *)` — permanently forbidden |
| **askRule** (explicit ask) | second highest | always ask, can't be remembered as "always allow" | `Bash(git push)` — must confirm every time |
| **classifier automatic judgment** | medium | AI system itself judges an action safe and auto-approves | read-only Grep / Read typically auto-pass |
| **alwaysAllow** | medium | remembered once the user has explicitly clicked "always allow" | `Read(*)` — allow all file read operations |
| **defaultMode** | low | system-level default policy | default policy, e.g. "allow all reads, ask for writes" |
| **abortController already aborted** | top priority | user has already interrupted, deny outright | after the user hits Ctrl-C, all remaining approvals are skipped |

These rules come from **multiple layers of config files**:
- **`cliArg`** — arguments passed when launching the CLI, valid for one session
- **`session`** — after the user clicks "always allow" in the current session, valid only for **this session**
- **`localSettings`** — the project's `.claude/settings.local.json`, only for the current user, not checked into git
- **`projectSettings`** — the project's `.claude/settings.json`, checked into git, shared by the team
- **`userSettings`** — the user's global `~/.claude/settings.json`
- **`managedSettings`** — enterprise administrator level, the user cannot override

**Before every approval, the system checks in the order above**: abort first, then deny, then ask, then classifier, then alwaysAllow, and finally default. As soon as one level matches, the conclusion is reached.

## How an Approval Blocks the Loop

Suppose none of the current rules can reach an automatic conclusion — the only option is to ask the user. At the loop level, this looks like:

```
loop reaches a turn where the LLM outputs tool_use
    ↓
about to run the tool, first run the permission check
    ↓
none of the automatic rules match, needs the user to decide
    ↓
【loop blocks · Promise pending】
    ↓
UI layer pops up an approval dialog (rendered by the Ink layer)
    ↓
user clicks "allow" · Promise resolves
    ↓
loop continues · tool actually runs
```

**The key point**: the loop isn't "polling whether the user has clicked yet" — it's **awaiting a Promise**. The UI layer receives the user's click and resolves this Promise, and only then does the loop continue. If the user spends 10 seconds thinking on the approval dialog, the loop blocks for 10 seconds — doing nothing.

**Side effect**: while blocked on approval, **no LLM API call is in flight** — because the loop is stuck at the approval step, it hasn't reached the next call_llm yet. In other words, the time the user spends thinking **doesn't count toward API cost** — a hidden upside of the permission system.

## 3 Approval Sources Judge Simultaneously — Whoever Returns First Wins

Above we said "the UI layer receives the user's click and resolves the Promise" — but the real design is more clever: **the approval's resolution can come from 3 different sources**:

1. **User click** (the UI layer's "allow" / "deny" buttons)
2. **PermissionRequest hook** (the user or team configured an auto-approval hook in `settings.json`, triggered via command line / HTTP)
3. **AI classifier** (Claude Code's built-in classifier, judging whether an operation is obviously safe)

These 3 sources **start judging at the same time**. This is a `race`: whichever finishes first has its result adopted, ending the wait; whatever the other two sources return afterward no longer applies.

Why design it this way?

- User click is slowest (usually 3-10 seconds), but absolutely authoritative
- Hook is medium speed (hundreds of milliseconds to a few seconds), flexibly programmable
- Classifier is fastest (tens of milliseconds of AI inference), but may deny conservatively

**If they were checked sequentially** — wait for the hook, then the classifier, then finally ask the user — the total wait could be the sum of all three. By having all three judge concurrently, only the fastest one's time needs to be waited on, so the approval flow responds faster.

**But concurrency requires guarding against double-resolve** — if a Promise gets resolved twice, it crashes. Claude Code uses a mechanism called `ResolveOnce`: whichever of the three arrives first **claims** the resolution, and any subsequent claim attempts from the other two are rejected. This guarantees the Promise is resolved exactly once.

**This reveals a design insight**: letting multiple sources race, rather than deciding a priority order and running them serially, is a direct product of the permission system's pursuit of "fastest possible user experience." A race condition is usually a bug — here it's flipped into a **feature**.

## A Subagent's Permissions Don't Inherit

In the main conversation, the user may have already clicked "always allow Bash" — a session-level alwaysAllow rule gets recorded.

Now the main conversation spawns a [subagent](09-sidechain.md) (having another AI run something independently) — and has the subagent also run Bash commands.

**Does the main conversation's alwaysAllow carry over to the subagent?**

**No.**

Claude Code's default behavior is: when a subagent starts up, it **clears the main conversation's session-level approvals** — only the CLI-argument level (fixed startup config) is kept, and the session level is replaced by the subagent's own `allowedTools` (declaring what the subagent is allowed to call).

Why design it this way? Because the main conversation's alwaysAllow represents **the user's trust in the main conversation**. A subagent is a different AI — the user hasn't extended it the same trust. Not inheriting = more conservative = safer.

The cost is that the subagent may need to go through permission approval all over again — but **defaulting to conservative beats defaulting to trust**, a basic principle of safety systems.

## Summary

- **The tools segment is the third segment of the API request** — it declares what tools are available in the current session. The LLM decides whether to call one based on its description
- **Between the LLM outputting tool_use and the tool actually running, there's a "permission approval" step** — the sole exception to "no one participates mid-loop"
- **Permission rules have 6 levels of sources**, checked in order: abort > deny > ask > classifier > alwaysAllow > default
- **The way approval blocks the loop is by awaiting a Promise** — the user's thinking time doesn't count toward API cost
- **3 approval sources race simultaneously** — user / hook / classifier, whichever is fastest wins, with `ResolveOnce` guarding against double-resolve
- **Subagent permissions don't inherit** — a conservative safety default

The next article, 02 · Hooks · Insertion Points on the Loop, covers what comes **after approval**: between a `tool_use` and the tool actually running, beyond permission approval, there's a more general mechanism — hooks — that lets users insert custom logic at 26 different points in the loop. Permission approval is a specialization of hooks; hooks are the general answer to "the user wants to insert custom logic into the loop."

---

## References

**Primary file locations** (v2.1.220):
- `src/utils/permissions/permissions.ts` — the `hasPermissionsToUseTool` main flow
- `src/hooks/toolPermission/handlers/interactiveHandler.ts` — the interactive approval Promise
- `src/hooks/toolPermission/PermissionContext.ts` — `ResolveOnce` claim
- `src/utils/permissions/PermissionUpdate.ts` — alwaysAllow persistence
- `src/utils/settings/types.ts` — the `permissions` schema in settings.json
- `src/types/permissions.ts` — the `PermissionRuleSource` 6-level hierarchy
- `src/tools/AgentTool/runAgent.ts` — subagent permission clearing

**Related series**:
- Claude Code Tools Research Series — Prerequisite (tool mechanics) — the 4-layer contract of tool definitions, JSON Schema, system prompt organization
- [02 · Three Invariants, from a Single Message to the Messages Array](../context-management/02-message-invariants.md) — where tool_use sits in the messages array and its constraints

**Anthropic official docs**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) — the API format for tool declarations
