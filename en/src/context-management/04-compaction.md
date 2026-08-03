> This is the 4th article in the series, building on the three invariants established in the previous three: the messages array only appends and never deletes, tool_use / tool_result must be paired, and role must strictly alternate (see [02 · Three Invariants, From One Message to the Message Array](02-message-invariants.md)). These three "can't-change" rules are the root reason compaction mechanisms exist — the array can't shrink on its own, only the harness can actively intervene.
>
> The previous article, [03 · Prompt Cache Is the Skeleton — Why Everything Else Grew the Way It Did](03-prompt-cache.md), covered how cache is the foundation everything else is built on. This one is about **compaction** — but compaction isn't one mechanism, it's **six working together**. Each has a different trigger scenario, a different retention strategy, and a different attitude toward cache.
>
> This article focuses on **mechanism and design** — what problem each of the 6 variants solves, how they divide labor, and 3 counterintuitive things about post-compact. Exact source locations are in the reference section at the end.

## Things You Might Not Have Sorted Out

You've probably heard of `/compact` in Claude Code — but if that's all you know, you're missing more than half the picture:

1. **When I'm running a conversation and context is about to fill up, when do I hit `/compact` myself, and when does the harness compact on its own?**
2. **Is `/compact` just a cheap small model summarizing things?**
3. **After compaction, are the files I read earlier still there? Do I need to Read them again?**
4. **What's the difference between `/compact` and `/clear`? One summarizes, one doesn't — but why keep two commands?**
5. **`/rewind` can also "go back to a previous state" — how does it relate to compaction?**
6. **I heard there's a `/fork` — why doesn't anything happen when I type it?**

The one-line answer: **Claude Code has 6 compaction variants working together, covering the full spectrum of trigger scenarios from "user-initiated" to "the API has already errored out" — plus `/clear` and `/rewind` drawing the boundaries, plus `/fork` as an uncompiled foreshadowing.**

## TL;DR

| Dimension | One-liner |
|---|---|
| **Why compaction is needed** | The three invariants of the messages array mean it only appends, never deletes — once it gets long enough, something has to intervene |
| **6 variants coexist** | `/compact` manual / auto-compact threshold / micro-compact intra-turn trimming / reactive-compact emergency / sessionMemoryCompact cross-session / contextCollapse gradual rollout |
| **`/compact` uses the main model, not Haiku** | Counterintuitive — most people assume a cheap Haiku summary, but it actually uses mainLoopModel, because summary quality *is* the core business here |
| **9-section XML structure** | The `<analysis>` scratchpad gets stripped; the 9-section `<summary>` survives, covering Primary Request / Files / Errors / All user messages, and more |
| **auto-compact's threshold isn't 80%** | It's an absolute value: `context - 20K reserved - 3K buffer`. The "80%" from the official blog post isn't in the source code |
| **Post-compact reattaches 5 files / 50K tokens** | Hard budget: 5-file cap, 5K per file, 50K total, 25K for skills |
| **3 counterintuitive reattachment rules** | Root CLAUDE.md gets reattached / nested doesn't / skill listing deliberately doesn't get reattached — cache wins over memory completeness |
| **`/clear` doesn't summarize** | Full reset of AppState + new session ID + reruns SessionStart hooks — this is where it diverges from `/compact` |
| **`/rewind` granularity** | Can only land on user messages, never mid-way through a tool_use / tool_result pair — preserves the three invariants |
| **`/fork` isn't compiled in** | Gated behind a feature flag, not yet enabled; absorbed by `/branch` for now. Real fork lives in [06 · Sub-agent Isolation](06-sub-agent.md) |

## 1 · Why "Compaction" Is Six Things, Not One

First, the premise: the three invariants of the messages array ([02 · Three Invariants, From One Message to the Message Array](02-message-invariants.md)) — **append-only, never delete**; tool_use / tool_result **must be paired**; role **must strictly alternate**.

These three invariants mean the messages array **can only grow, never shrink**. Run a conversation for 20 turns and the array might already have dozens of messages. Run it for 100 turns and it's hundreds. And every LLM call has to resend the whole thing — the 200K ceiling gets hit sooner or later.

So compaction has to happen. But **when it happens and how it happens** is covered by six different variants:

| Variant | Who triggers it | When | What it does |
|---|---|---|---|
| **`/compact`** | User-initiated | User presses it, immediately | 9-section summary + reattach last 5 files |
| **auto-compact** | Harness, automatic | End of each turn, threshold reached | Same as `/compact`, but the user didn't ask for it |
| **micro-compact** | Harness, automatic | Mid-turn, low cost | Only drops stale tool_results, no summarization |
| **reactive-compact** | Harness, automatic | API returns `prompt_too_long` | Emergency trimming, up to 3 attempts |
| **sessionMemoryCompact** | Harness, automatic | Session ends | Writes to disk, persists across sessions |
| **contextCollapse** | Feature-flag gated | Gradual rollout | More aggressive, cuts sharply |

**Why six**: each one has a niche nobody else can fill —
- `/compact` is the **user-initiated** entry point — the user might sense that compaction is needed (say, right after finishing a big chunk of work and wanting to switch topics), something the harness has no way to predict on its own
- auto-compact is a **harness-initiated** threshold trigger — the user isn't aware of it, but context is about to fill up
- micro-compact is **intra-turn** low-cost cleanup — the threshold hasn't been hit, but there are stale tool_results in the history, so it quietly discards a few
- reactive-compact is emergency recovery **after the API has already errored** — nothing else caught it in time, so it's pure firefighting
- sessionMemoryCompact is **cross-session** — it doesn't solve the current session's context problem, it solves "what will I remember next time I come back"
- contextCollapse is the **gradual-rollout aggressive version** — for when regular compaction isn't enough, so it hits harder

**This is a completely different mental model from a single `/compact`** — Claude Code's compaction is **layered defense**, with each layer solving the problem at its own level.

## 2 · `/compact` in Depth — the Most Typical, Manual Case

`/compact` is the most typical entry point — the user presses it deliberately, optionally with `[custom instructions]` (e.g. "keep the database schema discussion, drop the UI styling stuff").

**This step has its own dedicated prompt.** `/compact` doesn't send the command as-is to the model — instead the program fires off a separate "summarize the current conversation" LLM request: the system prompt tells the model its job is to summarize the conversation, and a dedicated compaction prompt specifies the 9-section XML output structure below. Any `[custom instructions]` the user attached also get folded into this request, to steer what the summary emphasizes.

### Counterintuitive: It Uses the Main Model, Not Haiku

Most people's assumption: summarization is a **secondary task**, so it should use a cheap Haiku or some background model.

**What the source actually does**: it uses **mainLoopModel** — that is, whatever main model your session is currently on (Opus / Sonnet). `querySource` is tagged `'compact'`, `thinkingConfig` is set to `disabled` (summarization doesn't need a chain of thought), and `systemPrompt` is a single plain sentence: "You are a helpful AI assistant tasked with summarizing conversations."

**Why the main model**: summary quality *is* the core business here — the resulting summary replaces dozens to hundreds of messages in the array, and every downstream inference in the session builds on that summary. If Haiku misses a key piece of context (say, the root cause of some error), every subsequent answer gets distorted. Using the main model keeps **the quality of the summary consistent with the quality of the conversation**.

The cost is that compaction itself is expensive — a single `/compact` burns thousands to tens of thousands of tokens of inference. But compared to "a distorted summary sends the next few dozen turns in circles," a few thousand tokens is a bargain.

### The 9-Section XML Structure

`/compact` has the LLM output a structured summary wrapped in two layers of XML tags:

```
<analysis>
   ... draft-style thinking ...
</analysis>

<summary>
1. Primary Request and Intent
2. Key Technical Concepts
3. Files and Code Sections
4. Errors and fixes
5. Problem Solving
6. All user messages
7. Pending Tasks
8. Current Work
9. Optional Next Step
</summary>
```

**What the two XML layers are for**:
- `<analysis>` is the **scratchpad** — the LLM can think freely inside it, and it gets **stripped out by `formatCompactSummary`** once processing is done
- `<summary>` is the **final product** — only this section survives, replacing the original messages history

**The core idea behind the 9-section structure**: compaction isn't simply "shortening the conversation" — it's **reorganizing information by topic**. In a natural conversation history, discussion of a single bug might be scattered across 10 messages (user reports an error → LLM tries a fix → fails → user adds more info → LLM tries again ...) — the 9-section structure **files all of that under "Errors and fixes"**, so after compaction it reads as one clean, itemized list.

**Section 6, "All user messages," is a special case**: the LLM is instructed to **preserve every user message in full** — no summarizing allowed. Because user messages are the only anchor that expresses "what the user wants" — dropping one might mean dropping a whole direction. LLM replies can be summarized; user messages can't.

### customInstructions

The `/compact` command accepts an optional argument — `argumentHint: <optional custom summarization instructions>`.

Example usage:

```
/compact keep the database schema discussion, ignore anything about UI styling
```

This custom instruction gets folded into the summarization prompt, steering the LLM to weight certain kinds of information more heavily. It's a **manual intervention knob** for the user — sometimes the user knows better than the harness which parts actually matter.

## 3 · auto-compact — the Threshold Isn't 80%

`/compact` is user-initiated; auto-compact is the harness acting on its own. After every LLM call ends, the harness checks the context length, and if it's over the threshold, triggers a compaction automatically.

### Counterintuitive: the Threshold Is an Absolute Value, Not a Percentage

Anthropic's official blog says auto-compact "triggers when context reaches 80%."

**What the source actually does**: the threshold is an **absolute value**, not a percentage. The formula:

```
trigger threshold = effectiveContextWindow - 20K reservedOutput - 3K buffer
```

Breaking it down:
- **effectiveContextWindow** — the current model's context ceiling (say, 200K)
- **20K reservedOutput** — space reserved for the LLM's reply — the 200K context can't be entirely filled by input, some has to be left for output
- **3K buffer** — a safety margin, in case the tokenizer's estimate is slightly off, so it doesn't slam into the hard ceiling

For a 200K model: trigger threshold = 200K - 20K - 3K = **177K** — about 88.5%. For a 100K model (some fallbacks, for instance): trigger threshold = 100K - 20K - 3K = 77K — about 77%.

**Why an absolute value instead of a percentage**: reservedOutput is a **fixed 20K**, not proportional — because a reasonable LLM reply length has nothing to do with the size of the context window. A single reply of 20K tokens is already enough to write a short essay. Using an absolute value guarantees "the space reserved for output doesn't go to waste just because the ceiling got bigger."

**Env override**: there's an environment variable, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, that can switch the threshold to a percentage — but it's not a percentage by default, it's an explicit opt-in.

**Where "80%" comes from**: possibly an early design-doc phrasing from the Anthropic team, or a rough approximation for a typical model. But you won't find "80%" anywhere in the source. This is the first entry in the "official docs vs. source discrepancies" table at the end of [00 · Prologue — Claude Code's 200K Ledger](00-intro.md).

## 4 · micro / reactive / sessionMemory / contextCollapse — 4 Minor Variants

The two above are the leads; the remaining four are supporting cast — but drop any one of them and the system is missing a chunk.

### micro-compact — Low-Cost Intra-Turn Pruning

`/compact` and auto-compact are both heavyweight operations triggered **at the end of a turn** — they fire off an LLM request to do summarization, at a cost of thousands of tokens.

**micro-compact is lightweight cleanup within a turn** — no LLM call, no summarization — it does exactly one thing: **scan through the history, find tool_results that are already stale, and quietly swap them out for a placeholder**.

**What counts as stale**: the typical case is **file dedup** — the same file has been read 3 times, and the tool_results from the first 2 reads are already outdated (the most recent read is more complete) — so the earlier two can be trimmed. The harness tracks each file's latest version with `readFileState` (see [07 · Meta Mechanisms](07-meta-mechanisms.md) for details), and micro-compact uses this to decide which old reads can be discarded.

**The replacement placeholder**: a fixed English string, `FILE_UNCHANGED_STUB`:

> File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.

**Not** a shorthand marker like `[...]` — it's a **complete English instruction**. Because when the LLM sees this message, it needs to know "go look at the results of that later Read instead" — a natural-language instruction is far more unambiguous than a symbol.

**micro-compact preserves all three invariants**: tool_use / tool_result pairing isn't broken — the tool_use is still there, the tool_result is still there — only the **content** of the tool_result gets swapped. The pairing structure stays intact; only the payload gets trimmed.

### reactive-compact — Only Fires When the API Already Errored

Everything above is **preventive** — it acts before the API errors. reactive-compact is **emergency** — it only fires once the API has already returned a `prompt_too_long` error.

Why things reach this point at all:
- the user disabled auto-compact (there's an environment variable to turn it off)
- or auto-compact's estimate was off — the actual token count came in higher than the harness calculated
- or the user installed a pile of MCPs, and an MCP suddenly mounted tens of thousands of tokens of schema, pushing context past the threshold all at once

How reactive-compact handles it:
- **at most 3 attempts** — `RECOVERY_LIMIT = 3`
- each attempt trims part of the history (from the head or the tail), then resends the request
- if all 3 attempts fail, it throws `{ reason: 'prompt_too_long' }` up to the SDK layer

This is **layer 4** of the 8-layer recovery stack discussed in [07 · Retry and Error Recovery — 8 Layers of Recovery Stacked](../agent-loop/07-retry-recovery.md). The specific trimming strategy is called `truncateHeadForPTLRetry` — it trims from the **head** (trimming the tail would break tool_use / tool_result pairing, so the head is the relatively safe side).

**reactive-compact is hidden inside errors** — the user never sees "prompt_too_long appeared, then went away" — they only see an error if all 3 attempts fail. This is consistent with the "error withholding" philosophy discussed in [05 · QueryEngine Main Loop — the Full State Machine](../agent-loop/05-query-engine.md).

### sessionMemoryCompact — Cross-Session Persistence

Everything above is compaction **within the current session** — once it's done, the messages array is shorter, and the session keeps running.

sessionMemoryCompact is different — its goal isn't to shrink the current session, it's to make sure **the next new session** can pick up where the last one left off.

The workflow:
- when a session ends (or after a period of idleness), the harness produces a summary of the current session's messages array
- the summary gets written to disk under `~/.claude/projects/<project>/memory/`
- the next time a session opens on the same project, this memory gets loaded at the start — effectively "last time's memory"

**Difference from auto-compact**:
- auto-compact: after summarizing, it gets slotted back into the **head of the current session's messages array**
- sessionMemoryCompact: after summarizing, it gets **written to disk**, to be read next time

**Difference from MEMORY.md**: MEMORY.md is memory the **user can edit by hand**; sessionMemoryCompact is written **automatically by the harness**. The two work together — one manual, one automatic. See [05 · The CLAUDE.md Family](05-claude-md-family.md) for the specific mechanism.

### contextCollapse — the Aggressive Version, Still Behind a Feature Flag

Everything up to this point has been "gentle" — the structure is preserved, only the content gets compressed. contextCollapse is harsher — it directly **cuts history sharply**, with no fine-grained summarization.

**Why it needs to be harsher**: there's an extreme case — context has already blown **way past** the threshold (say, the user disabled all the auto mechanisms, or a single batch dropped in tool_results for 100 large files) — regular compaction isn't enough, the summary still comes out too long. That's when you need **aggressive discarding**.

contextCollapse exists in the source, but it's **gated behind a feature flag** — off by default, only triggerable for a subset of users in gradual rollout. Its retention strategy is more aggressive than `/compact`'s — it just throws away a chunk of history rather than summarizing it.

This is **tier 1** (aggressive compaction) of the three-tier prompt_too_long recovery discussed in [07 · Retry and Error Recovery — 8 Layers of Recovery Stacked](../agent-loop/07-retry-recovery.md), with reactive-compact as **tier 2** — a progression: try gently first, get more aggressive if that fails, and only then hand it off to the user.

## 5 · Post-Compact Reattachment — the 5-File / 50K-Token Budget

Now let's dig into an operation that's already come up repeatedly: **post-compact reattachment**.

After `/compact` / auto-compact finish summarizing, the messages array looks like this:

```
[the pre-compaction messages array: dozens of messages]
                    ↓
[9-section summary] (a user message wrapping a <system-reminder>)
+ [user messages after the boundary: kept verbatim]
```

But **a summary alone isn't enough** — some "structured context" has to be reattached:
- files the user read earlier — the summary can only say "read foo.ts," the actual content is gone
- the skill the user is currently using — the summary might mention it, but not the actual body
- CLAUDE.md — project rules can't be safely reduced to a summary

So post-compact needs to **actively reattach** this structured context. But reattachment **must be budgeted** — otherwise "right after compacting, it gets long again," wasting the whole exercise.

### The Hard Budget Table

Claude Code's reattachment budget comes down to a few hardcoded constants:

| Budget item | Value | Meaning |
|---|---|---|
| **POST_COMPACT_MAX_FILES_TO_RESTORE** | 5 | At most 5 files reattached — beyond that, the LLM Reads them again as needed |
| **POST_COMPACT_TOKEN_BUDGET** | 50K | Total token ceiling for all reattached files |
| **POST_COMPACT_MAX_TOKENS_PER_FILE** | 5K | At most 5K tokens per file — large files get auto-truncated |
| **POST_COMPACT_MAX_TOKENS_PER_SKILL** | 5K | At most 5K per skill body |
| **POST_COMPACT_SKILLS_TOKEN_BUDGET** | 25K | Total token ceiling for all reattached skills |

**Which 5 files get reattached**: the harness tracks the last-access time of every file, and reattaches the most recent 5. The logic is "what the user was recently paying attention to is what they're most likely to keep paying attention to."

**Why 5, not 3 or 10**: it's a **trade-off** —
- too few: files the user is about to keep discussing get missed, requiring a re-Read, wasting a turn
- too many: the reattached files eat into the budget themselves — 5 files × 5K = 25K tokens, plus 25K for skills, plus the summary itself — that's already tens of thousands of tokens

5 is the balance point the Claude Code team landed on between **"don't make the user re-read something right away"** and **"don't let compaction just grow back long again."**

## 6 · 3 Counterintuitive Things About Post-Compact

Beyond the budget, post-compact reattachment has 3 more counterintuitive behaviors — each pointing at the same underlying philosophy: **think from a cache perspective, not a semantic one** (see [03 · Prompt Cache Is the Skeleton — Why Everything Else Grew the Way It Did](03-prompt-cache.md)).

### Counterintuitive #1 · Root CLAUDE.md Gets Reattached, Nested Doesn't

After `/compact`, CLAUDE.md should be reattached — the summary might not fully capture the project's rules.

But **only the root/project CLAUDE.md gets reattached — nested CLAUDE.md doesn't**.

- **root/project** — the CLAUDE.md at the project root, the rules for the whole project, must be reattached
- **nested** — CLAUDE.md files in subdirectories (say, `src/frontend/CLAUDE.md`), relevant only to files in that particular subdirectory — **not reattached**

**Why nested doesn't get reattached**: a nested CLAUDE.md is only needed when the user is **actually operating on files in that subdirectory** — if the topic after compaction has nothing to do with that subdirectory, reattaching it wastes tokens. The harness keeps a `nestedMemoryAttachmentTriggers` mechanism instead — the next time a file in that subdirectory gets read, the nested CLAUDE.md gets **reattached automatically** (triggered via attachment) — reattached only when needed, and not eating into the budget otherwise.

**This is a just-in-time retrieval strategy** — see strategy 4 in [00 · Prologue — Claude Code's 200K Ledger](00-intro.md).

### Counterintuitive #2 · Skill Listing Deliberately Doesn't Get Reattached

Before `/compact`, Claude Code keeps a "set of skill names already sent" — used for incremental injection (see case 2 in article 03).

The intuitive expectation: after compaction, the summary is just text, and the LLM's memory of "what skills are available" has faded — so this set should be **cleared**, letting the skill listing get resent in full.

**What the source actually does**: it's **deliberately not cleared** — the set stays put, and post-compact the skill listing **does not get resent**.

The source comment states the reason directly:

> The post-compact skill listing is pure cache_creation (~4K tokens) — not resending it actually preserves the cache.

**This is cache-priority taken to its logical extreme**:
- The intuitive move: preserve the completeness of the LLM's "skill memory"
- The counterintuitive move: keeping the 4K-token cache prefix intact is a better deal — over the course of a session it can save dozens of times that cost

**The cost**: the LLM's memory of the skill list fades a little — this doesn't affect the user explicitly invoking a skill via slash-command, only the scenario where the LLM "proactively recalls that a skill could be used." The team weighed it and chose to preserve the cache.

### Counterintuitive #3 · FILE_UNCHANGED_STUB Is an English Instruction, Not a Marker

Covered earlier in the micro-compact section:

> File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.

**Why not use a shorthand marker** like `[...]` or `<file:unchanged>`:
- A marker requires the LLM to have **seen it during training** — an unfamiliar symbol just confuses the model
- Full English natural language — the LLM understands it directly — the message itself is an instruction
- A marker needs documentation to explain it — a full English sentence explains itself

**This is product documentation written for the LLM, not an internal harness marker**. The LLM is the "user" here — every piece of meta-information you write needs to be written in a way the LLM can understand — in its language, not yours.

This pattern of "meta-information written in natural language" shows up throughout Claude Code — the CLAUDE.md wrapped in `<system-reminder>` is also a full English block (see [05 · The CLAUDE.md Family](05-claude-md-family.md)), and the date_change reminder is also complete English. See [07 · Meta Mechanisms](07-meta-mechanisms.md) for more.

## 7 · `/clear` and `/rewind` — When to Use Which

That covers all 6 compaction variants. But from the user's perspective there are two more entry points related to "cleaning up history" — `/clear` and `/rewind`. They **aren't** compaction — but they draw a boundary against compaction that's worth clarifying here.

### `/clear` — No Summarizing, Just Resetting

**The core difference from `/compact`**:
- `/compact` — preserves information, just compresses it — the messages array shrinks, but semantic continuity is preserved
- `/clear` — **a full reset** — the messages array is emptied, everything starts from zero

What `/clear` specifically resets:
- the messages array: cleared
- tasks in AppState (running task tracking)
- attribution (message attribution — who triggered what)
- fileHistory snapshots (file history snapshots)
- standaloneAgentContext (cached independent sub-agent context)
- MCP state (MCP connection state)
- plan-slug cache
- session metadata
- **regenerates the session ID** — effectively a brand-new session
- **reruns SessionStart hooks** — giving hooks a chance to reinitialize the environment

**Why `/clear` needs its own entry point**: sometimes the user wants to **switch tasks completely** — the bug they were discussing is fixed, and now they want to start on a completely unrelated feature. `/compact` keeps a summary around — but the user doesn't need that information, and it would actually distract the LLM from the new task.

**Mnemonic**: **staying on topic, use `/compact`; switching topics entirely, use `/clear`**.

### `/rewind` — Timeline-Level Rollback

`/rewind` (called `/checkpoint` in some versions) is cleanup on a different axis entirely — **going back to a specific earlier point in time**.

The core difference from `/compact` / `/clear`:
- `/compact` / `/clear` — operate on the **current** point in time, clearing part or all of it
- `/rewind` — **rewinds** in time to a previous point

**Granularity**: it can only land on **user messages** — never in the middle of a tool_use / tool_result pair.

**Why only user messages**: this is dictated by the three invariants —
- if rewind lands after a tool_use but before its tool_result — pairing breaks
- if it lands after a tool_result but before the assistant's reply — role alternation breaks
- **only the moment right before a user message is a "clean cross-section"** — the history before every user message is a complete turn boundary, satisfying all three invariants

The specific filtering logic is called `selectableUserMessagesFilter` — it filters out tool_result / synthetic / meta / compact-summary / command-output, leaving only **genuine user messages**. The list the user sees to choose from is every moment they actually hit enter in the past.

**Restore options**: after selecting a user message, there are 6 ways to restore:
- **both** — restore conversation + code (files roll back to their state at that point)
- **conversation** — restore conversation only, code untouched
- **code** — restore code only, conversation untouched
- **summarize** — summarize the intervening span into one block instead of discarding it entirely
- **summarize_up_to** — summarize up to a certain point
- **nevermind** — cancel

**This ties into the "rewind paradox" discussed in [07 · Meta Mechanisms](07-meta-mechanisms.md)** — when rewinding, the in-memory messages array gets truncated directly — but the on-disk record is **append-only**, preserving the full history from before the rewind, just marking the rewind point. This is the core of "memory is flat, disk is a tree."

### One Table: 3 Entry Points for Cleaning Up History

| Entry point | Preserves info | Time axis | When to use |
|---|---|---|---|
| `/compact` | Yes — 9-section summary | Current, compressed | Staying on topic, but history is too long |
| `/clear` | **No** — fully cleared | Current, reset | Switching topics entirely |
| `/rewind` | Yes — but rolled back | Rewind, truncated | Want to undo a specific action |

## 8 · `/fork` — an Uncompiled Foreshadowing

You may have seen a `/fork` command mentioned somewhere. But if you actually type `/fork`, nothing happens — or it gets recognized as `/branch`.

**What the source actually does**: the `/fork` command definition **exists**, but it's gated behind a feature flag:

```
featureFlag: 'FORK_SUBAGENT'
```

If this flag isn't enabled — which is the default state for most users — `/fork` is **not compiled into** the UI, the input isn't recognized, and it gets absorbed by the `/branch` command instead.

**Why `/fork` is kept around at all**: the real fork implementation lives in `tools/AgentTool/forkSubagent.ts` — this is a **sub-agent** topic (see [06 · Sub-agent Isolation](06-sub-agent.md)), not a compaction topic. Fork is the mechanism by which an **independent sub-agent inherits the parent's context** — it uses a placeholder to flatten all tool_results to preserve cache, letting 100 forks share the same cache prefix (case 3 in [03 · Prompt Cache Is the Skeleton — Why Everything Else Grew the Way It Did](03-prompt-cache.md)).

Consider this just foreshadowing — seeing `/fork` do nothing isn't a bug, it's an entry point into the sub-agent topic, which article 06 covers in full.

## 9 · The Full Division of Labor Across the Six Variants

Now let's walk through the 6 compaction variants + 2 non-compaction entry points, organized by **trigger scenario**:

```
User's perspective:
  ┌─ actively wants to compact     → /compact  (with customInstructions)
  ├─ actively wants to switch topic → /clear
  └─ actively wants to undo         → /rewind

Harness, automatic:
  ┌─ end of turn, threshold hit    → auto-compact
  ├─ mid-turn, found stale data    → micro-compact
  ├─ API already errored, rescue   → reactive-compact
  ├─ session ended                 → sessionMemoryCompact (cross-session)
  └─ gradual rollout, aggressive   → contextCollapse
```

**What the six variants achieve together**: the messages array never spirals out of control **at any point in time** —
- normally: auto-compact quietly scans, and compacts once the threshold hits — the user doesn't notice
- when the user wants to intervene: `/compact` + customInstructions — fine-grained control
- when things go wrong: reactive-compact — the last line of defense
- across sessions: sessionMemoryCompact — memory carries over to next time
- in extreme cases: contextCollapse — the nuclear option, still in gradual rollout

**None of them can substitute for another** — different scenarios, different triggers, different retention strategies. That's what "six siblings" means here — not six abstraction layers, but six **independent trigger paths** that together cover the full spectrum from "the user asked for it" to "the API has already blown up."

## 10 · Summary

- **The three invariants mean the messages array only grows, never shrinks** — something has to actively intervene, and that's compaction
- **6 compaction variants coexist** — `/compact` / auto / micro / reactive / sessionMemory / contextCollapse — each solving the problem at its own layer
- **`/compact` uses the main model, not Haiku** — summary quality *is* the core business
- **9-section XML structure + full preservation of user messages** — reorganizing by topic, not simply shortening
- **auto-compact's threshold isn't 80%** — it's an absolute value, `context - 20K reserved - 3K buffer`
- **Post-compact reattaches 5 files / 50K tokens** — a hard budget; reattachment itself has to be cost-controlled
- **3 counterintuitive reattachment rules** — root CLAUDE.md reattached / nested not / skill listing deliberately not reattached — cache wins over memory completeness
- **`/clear` is a full reset** — draws a clear boundary against `/compact`: staying on topic, use compact; switching topics, use clear
- **`/rewind` can only land on user messages** — an inevitable consequence of the three invariants
- **`/fork` isn't compiled in** — gated behind a feature flag; the real fork is a sub-agent topic

One line: **compaction isn't a single operation — it's an entire set of trigger paths, each shaped by the three invariants of the messages array, the cache-first philosophy, and the just-in-time reattachment budget.**

Next up: [05 · The CLAUDE.md Family](05-claude-md-family.md), covering the other half of Claude Code's structured notes — the 4-layer CLAUDE.md loading order, `@import` recursion, `<system-reminder>` channel injection, and the details of why nested CLAUDE.md deliberately doesn't get reattached post-compact.

---

## References

**Claude Code source locations** (v2.1.220):
- `src/services/commands/compact/index.ts` — `/compact` command entry, customInstructions parameter
- `src/services/commands/compact/prompt.ts` — the 9-section XML structure
- `src/services/compact/compact.ts` — main compaction flow, post-compact reattachment, reactive-compact
- `src/services/compact/autoCompact.ts` — auto-compact threshold calculation
- `src/services/compact/microCompact.ts` — intra-turn tail pruning
- `src/services/compact/sessionMemoryCompact.ts` — cross-session persistence
- `src/services/compact/contextCollapse.ts` — feature-flag-gated aggressive variant
- `src/tools/FileReadTool/prompt.ts` — the `FILE_UNCHANGED_STUB` constant
- `src/services/commands/conversation.ts` — `/clear` command, AppState reset
- `src/services/commands/MessageSelector.tsx` — `/rewind` UI, `selectableUserMessagesFilter`
- `src/services/commands/commands.ts` — `/fork` feature flag `FORK_SUBAGENT`
- `src/services/commands/branch/index.ts` — the `/fork` fallback when disabled
- `src/tools/AgentTool/forkSubagent.ts` — the real fork implementation (sub-agent topic)

**Related articles**:
- [00 · Prologue — Claude Code's 200K Ledger](00-intro.md) — the 4 major strategies, the 31-item mechanism matrix
- [01 · Agent Loop — How Context Gets Assembled](01-agent-loop.md) — the origin of the append-only messages array
- [02 · Three Invariants, From One Message to the Message Array](02-message-invariants.md) — the three constraints compaction must respect
- [03 · Prompt Cache Is the Skeleton — Why Everything Else Grew the Way It Did](03-prompt-cache.md) — the philosophy behind post-compact's counterintuitive choices
- [04 · The 7 Meanings of stop_reason, From "Done Answering" Onward](../agent-loop/04-stop-reason.md) — the context_window_exceeded trigger point
- [05 · QueryEngine Main Loop — the Full State Machine](../agent-loop/05-query-engine.md) — compaction as a first-class transition
- [07 · Retry and Error Recovery — 8 Layers of Recovery Stacked](../agent-loop/07-retry-recovery.md) — reactive-compact is layer 4
- [05 · The CLAUDE.md Family](05-claude-md-family.md) — why nested CLAUDE.md deliberately doesn't get reattached
- [06 · Sub-agent Isolation](06-sub-agent.md) — the real fork, in full
- [07 · Meta Mechanisms](07-meta-mechanisms.md) — the rewind paradox, memory flat vs. disk tree

**Anthropic official sources**:
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — the 4-strategy framework
- [Claude Code memory & context](https://code.claude.com/docs/en/memory) — the official docs mention auto-compact's "80%," which doesn't match the source — see section 3 of this article
