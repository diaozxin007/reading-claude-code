The previous chapter, [00 · Introduction · From a Chat Window to the Loop](00-intro.md), laid out the loop's 5-line skeleton — call the LLM · check for tool_use · execute if present, exit if not.

This chapter digs into the **first thing** that happens at every step of the loop: how does the LLM know which tools it can call? Between declaring an intent to call a tool and the tool actually executing, what's missing?

Getting this step right means answering a few questions:

- What tells the LLM it can call Read in the current session?
- If the LLM says it wants to call Read, does it actually get called?
- If not, what happens in between?
- Who decides whether a given call is allowed to proceed?

## Tools — the Third Segment of an API Request

The previous chapter covered the loop by noting that every call to the LLM sends a messages array. A complete API request actually has more than just the messages segment:

```
POST /messages
{
  system:   "...",     ← system prompt
  tools:    [...],     ← list of available tools (the subject of this chapter)
  messages: [...]      ← conversation history
}
```

All three segments get sent to the LLM together. The messages segment changes every turn; the tools and system segments stay relatively stable within a session.

**The LLM only calls tools listed in the tools segment** — during training it learned that "the `name` in a tool_use must be picked from the tools declaration." A tool not in the tools list simply won't be called by the model — because as far as the model is concerned, it doesn't exist.

So for the LLM to be able to call Read, Claude Code must have **already declared** Read in the tools segment.

## What a Tool Declaration Looks Like

The tools segment is an array, with each element declaring one tool. A tool declaration has three fields:

- **name** — the tool's name, the exact string the LLM will use in `tool_use.name` in its reply
- **description** — explains what the tool does, when to use it, when not to, and what its boundaries are
- **input_schema** — a JSON Schema for the parameters, declaring what input the tool accepts; the LLM's `tool_use.input` output must conform to this schema

What does the LLM rely on to decide whether to call a given tool? **Entirely on the description.** The clearer your description, the more accurately the LLM judges. A poorly written tool description leads the LLM to misuse it in the wrong scenario, or ignore the tool altogether.

A deeper breakdown of tool definitions themselves — the 4-layer contract, the concrete constraints of JSON Schema, how Claude Code organizes multiple tools, MCP's dynamic registration — is covered in the preliminary chapter of the tools research series. For this chapter, all you need to know is: the tools segment is a **menu of tools presented to the LLM** — once fixed, it's sent along with every call to the LLM.

## Between the LLM Outputting tool_use and the Tool Executing, There's One More Step

Now the LLM has received the tools segment, sees that Read exists, and also sees your question ("help me look at auth.py") — its reply carries a tool_use:

```
{
  role: 'assistant',
  content: [
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file_path: 'auth.py' } }
  ]
}
```

**What happens next?**

Per the loop skeleton, this should be "execute the tool · get the result · append the message." But in reality, **there's one more step sandwiched in between**:

**Permission approval.**

Reading an ordinary file might pass automatically. But if the LLM says it wants to:
- Run `Bash rm -rf /some/dir` — delete a directory, dangerous, must have user confirmation
- `Edit /etc/passwd` — modify a sensitive system file, must confirm
- Call `Bash` for the first time with a new command — the user may need to sign off on each new kind of command

In these cases, Claude Code **does not execute the tool directly** — it first pops up an approval prompt and waits for the user to click "Allow" or "Deny" before continuing.

## This Is the **Sole Exception** to "No One Steps Into the Middle of the Loop"

The previous chapter established a key premise: **the loop runs automatically, with no user involvement in the middle**.

**Permission approval is the sole exception to this premise.**

Why must there be this exception? Because the loop keeps turning on its own, with nobody in the middle. Without this interception layer of permission approval, if the LLM says it wants to run `rm -rf`, the loop would just go along with it, the user wouldn't have time to react, and the files would be gone.

The point of permission approval is precisely this: **to deliberately bring the user briefly back into view during the loop's automatic flow** — only at this one point of approval, nowhere else does it let the user intervene.

Other related mechanisms follow the same idea, but each intervenes differently:
- **Permission approval** — blocks the loop, waiting for user input (the loop stops, a prompt pops up, the user decides)
- **interrupt** — the user actively interrupts the loop (the loop is running, the user hits Ctrl-C, only then does the loop stop)
- **maxTurns** — requires no user involvement; stops automatically once the turn limit is reached (a hard safety net)

The three complement each other, covering three "necessary exceptions" to the premise that "the loop runs automatically."

## The 6-Tier Source of Approval Rules

Users don't want to be interrupted **every single time** — if the user had to click Allow for every Read, they'd go mad. So Claude Code's permission system needs to **remember the user's preferences**: which tools/commands pass automatically, which need to be asked about every time, and which are forever forbidden.

These preferences come from **6 different tiers**:

| Source | Priority | Scope | Example |
|---|---|---|---|
| **denyRule** (explicit deny) | Highest | Always denied, no asking | `Bash(rm -rf *)`, forever forbidden |
| **askRule** (explicit ask) | Second-highest | Asked every time, can't be remembered as "always allow" | `Bash(git push)`, confirmed every time |
| **classifier auto-judgment** | Medium | Auto-passes what the AI system itself judges safe | Read-only Grep / Read usually pass automatically |
| **alwaysAllow** (always allow) | Medium | Remembered once the user has explicitly clicked "always allow" | `Read(*)`, allows all file read operations |
| **defaultMode** | Low | System-level default mode | Default policy, e.g. "all reads allowed, writes need asking" |
| **abortController already aborted** | Top priority | User has already interrupted, deny outright | After the user hits Ctrl-C, all remaining approvals are skipped |

These rules come from **multiple configuration file tiers**:
- **`cliArg`** — arguments passed at CLI startup, valid for one session
- **`session`** — after the user clicks "always allow" in the current session, valid only for **this session**
- **`localSettings`** — the project's `.claude/settings.local.json`, applies only to the current user, not checked into git
- **`projectSettings`** — the project's `.claude/settings.json`, checked into git, shared by the team
- **`userSettings`** — the user's global `~/.claude/settings.json`
- **`managedSettings`** — enterprise-admin-level, users cannot override

**Before every approval, the system checks in the order above**: abort first, then deny, then ask, then classifier, then alwaysAllow, and finally default. As soon as one tier matches, a conclusion is reached immediately.

## How an Approval Blocks the Loop

Suppose none of the current rules can reach an automatic conclusion — the only option is to ask the user. At the loop level, this step looks like this:

```
loop turns to a given step · LLM outputs tool_use
    ↓
about to execute the tool · runs a permission check first
    ↓
none of the automatic rules match · needs the user to decide
    ↓
【loop blocks · Promise pending】
    ↓
the UI layer pops up an approval dialog (rendered by the Ink layer)
    ↓
user clicks "Allow" · Promise resolves
    ↓
loop continues · tool actually executes
```

**Key point**: the loop isn't "polling whether the user has clicked yet" — it's **awaiting a Promise**. The UI layer receives the user's click, resolves this Promise, and only then does the loop continue. If the user spends 10 seconds thinking on the approval popup, the loop blocks for 10 seconds — doing nothing at all.

**Side effect**: while an approval is blocking, **no LLM API call is in progress** — because the loop is stuck at this approval step, not yet at the next call_llm. In other words, the time the user spends thinking **doesn't count toward API cost** — a hidden benefit of the permission system.

## 3 Approval Sources Judge Simultaneously — Whichever Returns First Wins

Above we said "the UI layer receives the user's click, resolves the Promise" — but the real design is cleverer: **the resolution of an approval can come from 3 different sources**:

1. **User click** (the UI layer's "Allow" / "Deny" buttons)
2. **PermissionRequest hook** (a user or team has configured an auto-approval hook in `settings.json`, triggered via command line / HTTP)
3. **AI classifier** (Claude Code's built-in classifier, judging whether this operation is obviously safe)

These 3 sources **start judging simultaneously**. This is a `race`: whichever gives a result first is adopted, and the wait ends there; the results the other two sources return afterward no longer take effect.

Why design it this way?

- User click is slowest (typically 3-10 seconds), but has absolute authority
- Hook is medium (hundreds of milliseconds to a few seconds), flexible and programmable
- Classifier is fastest (tens of milliseconds of AI inference), but may be conservatively deny

**If judged sequentially** — wait for the hook first, then the classifier, then finally ask the user — the total wait time could be the sum of all three durations. By having all three judge simultaneously, only the fastest one needs to be waited for, so the approval flow responds faster.

**But concurrency requires guarding against double-resolve** — if a Promise is resolved twice, it crashes. Claude Code uses a mechanism called `ResolveOnce` — whichever of the three arrives first **claims** it, and any subsequent claim attempts by the other two are rejected. This guarantees the Promise is only resolved once.

**This reflects a design insight**: letting multiple sources race, rather than deciding a serial priority order upfront, is a direct product of the permission system's pursuit of "fastest possible user experience." A race condition is usually a bug — here it's flipped into a **feature**.

## Subagent Permissions Are Not Inherited

In the main conversation, the user may have already clicked "always allow Bash" — an alwaysAllow rule is recorded at the session tier.

Now, the main conversation spawns a [subagent](09-sidechain.md) (having another AI independently run a task) — and has the subagent also run Bash commands.

**Does the main conversation's alwaysAllow get passed to the subagent?**

**No.**

Claude Code's default behavior is: when a subagent starts, **it clears the main conversation's session-tier approvals** — only the CLI-argument tier (fixed startup config) is retained, while the session tier is replaced with the subagent's own `allowedTools` (declaring what the subagent is allowed to call).

Why design it this way? Because the main conversation's alwaysAllow is **the user's trust in the main conversation**. A subagent is a different AI — the user doesn't have the same level of trust in it. Not inheriting = more conservative = safer.

The cost is that the subagent may need to go through permission approval again — but **conservative-by-default beats trusting-by-default** is a basic principle of security systems.

## Conclusion

- **The tools segment is the third segment of the API request**, declaring what tools are available in the current session. The LLM relies on the description to decide whether to call one
- **After the LLM outputs a tool_use, and before the tool actually executes, there is a "permission approval" step** — this is the **sole exception** to "no one steps into the middle of the loop"
- **Permission rules have 6 tiers of sources**, judged in order abort > deny > ask > classifier > alwaysAllow > default
- **The way approval blocks the loop is by awaiting a Promise** — time the user spends thinking doesn't count toward API cost
- **3 approval sources race simultaneously** — user / hook / classifier, whichever is fastest wins, with `ResolveOnce` as a backstop against double-resolve
- **Subagent permissions are not inherited** — a conservative security default

The next chapter, 02 · Hooks · Insertion Points on the Loop, covers what happens **after approval**: between a tool_use and the tool actually executing, besides permission approval, there's a more general mechanism — hooks — that lets users insert custom logic at 26 different points in the loop. Permission approval is a specialization of hooks; hooks are the general answer to "the user wants to insert custom logic into the loop."

---

## References

**Key file locations** (v2.1.220):
- `src/utils/permissions/permissions.ts` — main flow of `hasPermissionsToUseTool`
- `src/hooks/toolPermission/handlers/interactiveHandler.ts` — the interactive approval Promise
- `src/hooks/toolPermission/PermissionContext.ts` — `ResolveOnce` claim
- `src/utils/permissions/PermissionUpdate.ts` — alwaysAllow persistence
- `src/utils/settings/types.ts` — the `permissions` schema in settings.json
- `src/types/permissions.ts` — the 6-tier `PermissionRuleSource`
- `src/tools/AgentTool/runAgent.ts` — subagent permission clearing

**Related series**:
- Claude Code Tools Research Series — Preliminary Piece (Tool Mechanics) — the 4-layer contract of tool definitions, JSON Schema, system prompt organization
- [02 · Three Invariants From a Single Message to a Message Array](https://readingclaude.club/zh/context-management/02-message-invariants) — the position and constraints of tool_use within the message array

**Anthropic official docs**:
- [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) — the API format for tool declarations
