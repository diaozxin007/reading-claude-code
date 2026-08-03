> Article 01 of this series — follows [00 · Intro · Claude Code's 200K Ledger](00-intro.md). This article nails down the agent loop, so that in the next five articles, every mention of "messages array," "resending history," or "appending each turn" has a concrete shape to point back to.
>
> **Why this article comes first**: every discussion of context management rests on the premise of "what context actually is." And you only know what context is once you've seen the agent loop clearly.
>
> This article doesn't touch cache or compaction — first build the **base model**, then talk about optimization.

## A Few Things You Might Not Have Nailed Down

Using Claude Code feels like this: a chat window, you type, it replies, and in between it might read a few files, run a few commands, then keep talking to you.

But have you ever stopped to ask:

1. **Does it "remember" the previous conversation, or does it look at everything again from scratch each time?**
2. **When it runs the `Read` tool, how many round trips does it actually make with the LLM — one, or several?**
3. **The 200K context ceiling — where does that 200K get counted from and to? The total of an entire conversation? Or the input of a single call?**
4. **20 turns into the same conversation, is the earlier content still there? Could it get "forgotten"?**
5. **What form does the text you type actually take once it enters the LLM's input — does it go in verbatim, or does the harness wrap it first?**

If you can't answer these, then everything later about cache / compaction / checkpoints / CLAUDE.md is a castle in the air. This article settles them.

## TL;DR

| Question | Answer |
|---|---|
| Is the LLM stateful? | **Stateless** — every call is brand new. Whatever it "remembers" is entirely because the harness resends the full history every time |
| How many LLM calls happen in one "conversation"? | Each user input triggers **multiple** LLM calls in one turn — one more for every tool call |
| What is context? | A messages array — the complete history from the start of the session to now, fully resent on every LLM call |
| What unit is 200K? | The input token ceiling for a **single LLM call**, not a "cumulative session ceiling" |
| Does the messages array shrink naturally? | **No** — it only grows, unless the harness actively runs a compaction operation |
| What does your typed message look like once it enters the LLM? | A `<system-reminder>`-wrapped block of metadata (CLAUDE.md, date, etc.) gets prepended before it — the original text follows |

## 1 · The LLM Is Stateless — the Starting Point for Everything

**The single most counterintuitive fact to establish first**: the LLM itself is **stateless**.

You open Claude Code and talk to it for 10 turns. You'd assume something like this:

```
You say 10 turns worth of things
    ↓
Claude keeps these 10 turns in mind
    ↓
Turn 11 · Claude replies based on what it kept in mind
```

**Wrong.** What actually happens:

```
Turn 1:  harness sends [messages array: 1 entry] to the LLM
Turn 2:  harness sends [messages array: 3 entries (turn 1's user message + LLM reply + your new message)] to the LLM
Turn 3:  harness sends [messages array: 5 entries] to the LLM
...
Turn 11: harness sends [messages array: 21 entries] to the LLM
```

**Every single LLM call is brand new — what it "sees" is entirely determined by whatever the harness stuffs into it this time.**

- You think Claude "remembers" what you said earlier — actually the harness stuffed everything you've said into this call's input
- You think Claude "read" that file — actually the harness stuffed the `Read` output into this call's input
- You think Claude "still remembers" CLAUDE.md — actually the harness stuffs CLAUDE.md in front of the input every single time

**The harness is the "carrier of memory."** The LLM remembers nothing; the harness remembers everything.

This is why this series is called "Claude Code Context Management Research" — **it's not researching how the LLM manages memory, it's researching how the harness (Claude Code itself) decides what to stuff into the LLM each time.**

## 2 · How Many LLM Calls Actually Happen in One "Conversation"

From the user's perspective, a conversation looks like this:

```
You: "help me look at this bug"
Claude: Sure, let me read auth.py first ... I see it now, the cause is X, need to change Y. Done.
```

**Looks like one interaction.** In reality, in between, Claude will:

1. Read `auth.py`
2. Read `login.py` (which `auth.py` references)
3. Run `grep` to find related calls
4. Use Edit to change the file
5. Run tests to confirm

**Every single tool call corresponds to its own independent LLM call.**

Here's what the actual call flow looks like:

```
─── Call 1 ────────────────────────────────────
harness → LLM: messages = [
   { role: 'user', content: 'help me look at this bug' }
]
LLM → harness: { text: 'Sure, let me read auth.py first',
                tool_use: { name: 'Read', input: { file: 'auth.py' } } }
harness runs Read, gets the file contents

─── Call 2 ────────────────────────────────────
harness → LLM: messages = [
   { role: 'user', content: 'help me look at this bug' },
   { role: 'assistant', content: [<text>, <tool_use>] },
   { role: 'user', content: [<tool_result: auth.py contents>] }
]
LLM → harness: { text: 'I see auth.py depends on login.py, reading further',
                tool_use: { name: 'Read', input: { file: 'login.py' } } }
harness runs Read

─── Call 3 ────────────────────────────────────
harness → LLM: messages = [
   { role: 'user', content: 'help me look at this bug' },
   { role: 'assistant', content: [<text>, <tool_use: auth.py>] },
   { role: 'user', content: [<tool_result: auth.py contents>] },
   { role: 'assistant', content: [<text>, <tool_use: login.py>] },
   { role: 'user', content: [<tool_result: login.py contents>] }
]
LLM → harness: ...

...(possibly 3-5 more calls follow)...

─── Call N ────────────────────────────────────
harness → LLM: messages = [...(everything accumulated so far)...]
LLM → harness: { text: 'Done — the cause was X, I changed it to Y.' }
                (no tool_use — this turn is over)
```

**The signal that "one turn" has ended is the LLM returning a reply with no `tool_use`.** In other words, the LLM saying "I'm done talking, your turn." From the user's perspective this reads as "Claude replied" — under the hood it took 5-10 LLM calls.

**Key observations**:

- **Every call appends something new to the end of the existing messages array** (the LLM's output plus the tool_result)
- **Every call sends the entire messages array in full** — whether it's the 1st call or the 10th
- **After 20 turns, a single LLM call might already need to send 50K+ tokens** — because the messages array has already grown to dozens of entries

## 3 · Context Is a Messages Array That Only Grows

The call flow above already gives it away: **context is a messages array, running from the start of the session to now.**

Its **only two basic operations** are:

- **append**: after the LLM outputs, the harness appends the assistant message to the array; after a tool finishes running, the harness appends the tool_result; when the user sends a new message, it gets appended too
- **prepend** (once, at session start): the harness stuffs a block of metadata at the very front of the array — more on this below

**What it does NOT support**:

- ❌ **Modification** — earlier messages can't be changed. If they were, the LLM would believe "the earlier conversation went differently"
- ❌ **Deletion** — earlier messages can't be removed. Removing them would break later references (e.g., `tool_use` and `tool_result` must stay paired)
- ❌ **Reordering** — earlier messages can't be swapped around. The LLM relies on order to understand cause and effect

**These three constraints together are the premise for every discussion in the rest of this series**:

- **Compaction is really "append a summary + discard everything before it,"** not "edit the earlier messages"
- **Why cache prefix matching works** — because messages only ever get appended, never modified, so the prefix is naturally stable
- **`isMeta: true` messages** — a marker the harness uses to avoid polluting the real conversation history

## 4 · 200K Is a "Per-Call" Ceiling, Not a "Cumulative Session" Ceiling

A very common misunderstanding:

> "This session has already used 150K of context, so I should `/compact` before hitting 200K"

**This understanding** is partly right **but imprecise**. The accurate version is:

- 200K is the **input** token ceiling for **a single LLM call**
- When you say "the session has used 150K," what you actually mean is "**the most recent call's input** was roughly 150K"
- The session history itself has no "cumulative ceiling" — you can hold 100 turns of conversation, as long as **every single call** stays under 200K

But because the messages array only grows and never shrinks, **every call's** input keeps growing, and sooner or later it hits 200K. Before it does, something has to be done.

**"Something has to be done"** is what article 03 · The Six Siblings of Compaction covers.

**Concretely, here's what fills up the 200K**:

```
What a single LLM call's full input looks like, stitched together:

┌────────────────────────────────────────────┐
│ tools segment: schemas of tools currently    │  ~20-30 KB
│ available to the model                       │
│    built-in tools (Read / Edit / Bash /      │
│    Agent, etc.)                              │
│    + loaded MCP tool schemas                 │
│    + ToolSearch, used to find MCP tools       │
│      on demand                               │
├────────────────────────────────────────────┤
│ system prompt segment:                       │  ~15-25 KB
│    main prompt · tool-use instructions ·     │
│    environment info (cwd / git / platform) · │
│    org-level config (allowed tool set)       │
├────────────────────────────────────────────┤
│ messages segment:                            │  grows
│    [prepended user msg: CLAUDE.md · date]    │  ~2-10 KB
│    [Skill names and blurbs · system-reminder]│
│    [invoked Skill's SKILL.md · tool_result]  │
│    [MCP server instructions · system-reminder]│
│    turn 1: user message + assistant reply    │
│    turn 1's tool_use / tool_result pair(s)   │
│    turn 2: user message + assistant reply    │
│    turn 2's tool_use / tool_result pair(s)   │
│    ...(all history turns)...                 │
│    latest turn: user message (awaiting LLM)  │
└────────────────────────────────────────────┘

all three segments' tokens combined ≤ 200K
```

So **MCP and Skills don't disappear — they're just distributed across different locations**:

- **MCP tool schemas** live in the `tools` segment. When there are a lot of them, some are loaded lazily — the model first finds them via `ToolSearch`, then adds the needed schema into the available tool set.
- **MCP server usage instructions** aren't placed into the fixed system prompt — they're added incrementally into the `messages` segment via `system-reminder`.
- **The Skill list** contains only names and short blurbs, added into the `messages` segment via `system-reminder`. Only once a Skill is actually invoked does its `SKILL.md` body enter context, via `tool_result`.

**The tools + system prompt segments barely change** — they sit at a steady 30-50 KB. Which means the **usable space in the messages segment is really only ~150-170K**. Once the messages segment actually fills up 150K, it's time to compact.

## 5 · What Your Typed Message Looks Like Once It Enters the LLM

One more detail worth zooming into: the text you type into Claude Code — "help me look at this bug" — what does it look like once it's in the LLM's input?

**If it's the first message of the session**, here's what it looks like entering the LLM:

```
messages: [
   {
     role: 'user',
     isMeta: true,                              ← harness marker · indicates this isn't a "real" user message
     content: '<system-reminder>
        As you answer the user's questions, you can use the following context:
        # claudeMd
        <Contents of ~/.claude/CLAUDE.md (user's private...):
        <your global CLAUDE.md content>

        Contents of /repo/CLAUDE.md (project instructions...):
        <project CLAUDE.md content>

        # currentDate
        Today's date is 2026-07-30.

        IMPORTANT: this context may or may not be relevant to your tasks.
        </system-reminder>'
   },
   {
     role: 'user',
     content: 'help me look at this bug'          ← the actual user message
   }
]
```

**Observations**:

1. **What you typed is unchanged** — it's still exactly "help me look at this bug"
2. **A message marked `isMeta: true` gets prepended by the harness**, packed full of meta-context (CLAUDE.md / date)
3. **The meta-context is wrapped in `<system-reminder>`** — seeing the SR tag tells the LLM this isn't something the user said, it's something the harness stuffed in

This opens the door to a few key downstream mechanisms:

- **`<system-reminder>` is the harness's meta-communication channel with the LLM** — covered in 06 · Meta Mechanisms · A Taxonomy of system-reminder + File State, which has 20+ trigger conditions
- **`isMeta: true` is the harness marking "this isn't a real user message"** — mentioned above, and the harness needs a taxonomy of message types too
- **CLAUDE.md goes through the prepend position in the messages segment, not the system prompt** — this counterintuitive design has concrete reasons behind it, covered in both [05 · The CLAUDE.md Family](05-claude-md-family.md) and [03 · Prompt Cache Is the Skeleton](03-prompt-cache.md)

## 6 · The Full Picture of the Agent Loop

Putting all the pieces above together, here's the complete agent loop diagram:

```
                    ┌────────────────────┐
     user input ──→ │ append to end of    │
                    │ messages            │
                    └────────────────────┘
                              │
                              ▼
        ┌───────────────────────────────────────┐
        │  Assemble one LLM call's input:        │
        │  [tools] + [system prompt] + messages  │
        └───────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  LLM (stateless)  │
                    └──────────────────┘
                              │
                              ▼
             ┌──────────────────────────────┐
             │  LLM returns: text ± tool_use │
             │  appended as assistant msg    │
             └──────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Has tool_use?    │
                    └──────────────────┘
                     │              │
                    yes             no
                     │              │
                     ▼              ▼
    ┌──────────────────────┐   ┌──────────────────┐
    │ Run the tool          │   │  Turn ends        │
    │ tool_result appended   │   │  wait for next     │
    │ to end of messages    │   │  user input        │
    └──────────────────────┘   └──────────────────┘
                     │
                     └──── loop back to "assemble one LLM call" ──→
```

**This diagram is the bedrock for every discussion the rest of this series.** Every article after this one is layering a different **twist** or **optimization** on top of this loop:

- **Compaction**: notice messages have gotten too long, compress the old ones into a single summary before assembling
- **The CLAUDE.md family**: during assembly, besides tools/system/messages, prepend meta-info at the head of messages too
- **Sub-agent isolation**: for heavy lifting, don't do it in the current loop — fork off an **independent loop** and only bring back the result
- **JIT retrieval**: before assembly, keep a Skill's body or a large file's content out of messages whenever possible
- **Prompt cache**: every call resends the full prefix, but the server notices the prefix matches last time and reuses the earlier computation
- **`<system-reminder>`-style meta mechanisms**: besides appending "real messages," the harness also appends all sorts of meta-instructions and notices

## 7 · The Cost Ledger for One Real Call

With the loop model in hand, we can now run the numbers.

Suppose a simple "read a file, change one spot" task takes 5 LLM calls, with the messages array growing from 1 entry to 11:

| Call # | # of messages | tools + system | total input tokens | Notes |
|---|---|---|---|---|
| 1 | 1 (user message only) | 50K | ~52K | cheapest, right at the start |
| 2 | 3 (+ assistant + tool_result) | 50K | ~55K | tool_result might be ~3K |
| 3 | 5 | 50K | ~60K | keeps reading files |
| 4 | 7 | 50K | ~65K | review before Edit |
| 5 | 11 (Edit done, tests run) | 50K | ~75K | wrapping up |

**Without cache**, the 5 calls total ~305K tokens of input. **Across those 5 calls**, starting from call 2, **every single one resends everything that came before**.

With cache:
- Call 1 pays full price on ~52K (1.25x write cost)
- From call 2 on: the tools + system segment (50K) is already cached — only the read cost applies (0.1x) — effectively equivalent to paying full price on ~5K, plus the new message, so the full-price portion is only ~5K + 3K
- Calls 3-5 follow the same pattern

**Once cache hit rate is high, a single call's effective cost drops from 60K tokens to 8K tokens — a difference of over 7x.**

**This is exactly why** Claude Code builds its entire harness around prompt cache — without cache optimization, the cost of the agent loop would balloon **quadratically** with the number of conversation turns (the amount sent per turn grows linearly, times more turns sending more each time).

This is also why the next article, [02 · Three Invariants, from a Single Message to the Messages Array](02-message-invariants.md), starts by nailing down the structural constraints of the messages array, before [03 · Prompt Cache Is the Skeleton — Why Everything Else Is Shaped the Way It Is](03-prompt-cache.md) covers the foundation — cache isn't an accelerator, it's the necessary condition for the agent loop to be **sustainable on cost**.

## 8 · Summary

- **The LLM is stateless** — every "memory" is something the harness resends each time
- **One user input = multiple LLM calls** — one more call after every tool invocation
- **Context is a messages array that only grows** — it can only be appended to, never edited/deleted/reordered
- **200K is a per-call input ceiling**, not a cumulative session total
- **What gets sent on every call = tools segment + system prompt segment + the entire messages array** — three segments stitched together
- **User input gets meta-info prepended before it enters the LLM** — CLAUDE.md / date / etc., via an SR-wrapped `isMeta: true` user message
- **Cost grows quadratically with conversation turns** — this is the fundamental reason cache exists

In one sentence: **Claude Code's harness does the same thing every single round — assemble the messages array, send it to a stateless LLM, process the response, append the new messages, then assemble again.** Every context management mechanism is a variant or optimization of this one loop.

The next article, [02 · Three Invariants, from a Single Message to the Messages Array](02-message-invariants.md), zooms into the messages array itself: what shape each message takes, what structural constraints apply, and what happens when those constraints get broken.

---

## References

- Anthropic official docs: [Messages API](https://platform.claude.com/docs/en/api/messages) — role / tool_use / tool_result formats
- Anthropic official docs: [Tool use](https://platform.claude.com/docs/en/build-with-claude/tool-use) — loop semantics
- [00 · Intro · Claude Code's 200K Ledger](00-intro.md) — the full ledger of 4 strategies × 20+ mechanisms
- Later in this series:
  - [02 · Three Invariants, from a Single Message to the Messages Array](02-message-invariants.md)
  - [03 · Prompt Cache Is the Skeleton — Why Everything Else Is Shaped the Way It Is](03-prompt-cache.md)
  - 03 · The Six Siblings of Compaction (not yet written)
  - 04 · The CLAUDE.md Family (not yet written)
  - 05 · Sub-agent Isolation (not yet written)
  - 06 · Meta Mechanisms · A Taxonomy of system-reminder + File State (not yet written)
