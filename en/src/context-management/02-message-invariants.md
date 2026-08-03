The previous article, [01 · Agent Loop · How Context Gets Assembled](01-agent-loop.md), established that every LLM call in Claude Code has to resend the entire messages array from scratch. That article's focus was the loop's perspective — the messages array was just a passively carried container.

This one flips that around: **the messages array itself is the protagonist**. What shape does each message take? What pattern does the array's growth follow? What structural constraints, if violated, get the API to refuse service? Every topic in the articles that follow — compaction, recovery, CLAUDE.md injection, sub-agent isolation, the system-reminder channel — is built on the three invariants this article lays out.

Understanding the messages array means answering a few questions:

- What does each message in the array look like?
- What pattern governs the array's growth?
- Which structural constraints can never be broken?
- When a structural constraint does get broken, how does Claude Code respond?

## What a Single Message Looks Like

You type "help me look at this bug" into Claude Code and hit enter. Claude Code packages that into a **message**:

```
{
  role: 'user',
  content: 'help me look at this bug',
  uuid: 'a3f2...(36 chars)',
  timestamp: '2026-07-30T14:23:11Z'
}
```

**Four fields**: role (who said it), content (what was said), uuid (identity), timestamp.

Once the loop starts turning, two more categories of message show up in the array — the model's replies and the results of tool execution. Those two are structurally a bit more involved; we'll look at them in context as they come up.

## How the LLM Knows Which Tools It Can Call

In the example above, the LLM says "I'll call Read" — which presupposes it **knows Read exists**. Where does that knowledge come from?

Every LLM call, besides the messages array, also carries a **tools declaration**:

```
POST /messages
{
  system:   "...",     ← system prompt
  tools:    [...],     ← list of available tools
  messages: [...]      ← conversation history (this article's protagonist)
}
```

Each entry in the tools list looks like this:

```
{
  name: 'Read',
  description: 'Read the contents of a file, supports offset / limit pagination, ...',
  input_schema: {
    type: 'object',
    properties: {
      file_path: { type: 'string' },
      offset:    { type: 'number' },
      limit:     { type: 'number' }
    },
    required: ['file_path']
  }
}
```

Three key fields:
- **name** — the tool's name; the LLM's reply refers back to this via `tool_use.name`
- **description** — explains what the tool does, when to use it, and its boundaries; the LLM decides whether to call it based on this text
- **input_schema** — the JSON Schema for the arguments; the `tool_use.input` the LLM outputs must conform to this schema

Only once the LLM has received the tools list does it know what's callable in the current session. A tool that isn't in the tools list will never get called — the model was trained to "only call what's listed in tools."

**Tools form the third segment of the API request** — like the system prompt, it's relatively stable within a session and gets resent on every call. The actual content of tools (which tools exist, how they're organized, dynamic registration) is covered in the later Loop series. A deep dive into the tool definition itself — the 4-layer contract, JSON Schema constraints, how Claude reads a tool's description — lives in the Claude Code tools research series' prerequisite article (tool mechanism).

From here on, we'll treat tools as **already declared** background and focus entirely on the messages array itself.

## Why a Messages Array Has to Be Maintained at All

**Recap from the previous article**:

- The LLM is stateless — every call retains no history
- For the LLM to carry a coherent thread forward, the client has to accumulate a history of its own
- Every message that has occurred (user input / LLM reply / tool result) gets appended to the array, and the array is resent in full on every call

The array isn't a design choice — it's the inevitable consequence of a stateless loop + API. This article won't re-derive that; it goes straight to zooming in on the array itself.

## A Single Call Can Involve Multiple Tools

If the LLM decides it needs to read two files at once, a single assistant message can carry two `tool_use` blocks:

```
{ role: 'assistant', content: [
    { type: 'text',     text: 'Reading both files in parallel' },
    { type: 'tool_use', id: 'toolu_A', name: 'Read', input: { file: 'auth.py' } },
    { type: 'tool_use', id: 'toolu_B', name: 'Read', input: { file: 'login.py' } }
  ] }
```

Once the harness has this, it kicks off both Read calls simultaneously. When they finish, **both results get packed into a single user message**:

```
{ role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'toolu_A', content: '<auth.py>' },
    { type: 'tool_result', tool_use_id: 'toolu_B', content: '<login.py>' }
  ] }
```

**Why cram both tool_result blocks into one message** instead of two: because the Anthropic API enforces a constraint — **user and assistant messages must strictly alternate**. Two consecutive user messages aren't allowed. So the harness has no choice but to **aggregate** the results of concurrent tools into one.

**Here's the catch**: the two tools finish at different times. `auth.py` returns instantly; `login.py` takes 5 seconds. Which one lands first in the tool_result array?

**Claude Code's answer: completion order.** Whichever finishes first goes in first. So the order of tool_result entries in the array **doesn't necessarily match** the order the corresponding tool_use blocks were declared in.

**But that's not actually a problem** — because pairing is done via `tool_use_id` (`toolu_A` / `toolu_B`), not position. The API only requires that "every tool_use has a corresponding tool_result with a matching id" — position is irrelevant.

This is where the first **germ of an invariant** appears.

## The Pairing Invariant: Every tool_use Must Have a tool_result

Suppose the LLM declared 3 tool_use blocks, but the harness only returned 2 tool_result blocks — one short.

What happens? **The next call to the LLM, the API returns a flat 400 error**:

> `messages.0.content: unexpected tool_use_id`

The reasoning: the LLM issued a tool-call request, and it must be given a matching result. Miss one, and the API judges the conversation structurally broken and refuses service.

**And so the first hard constraint on the messages array emerges**:

> **Every `tool_use` block must have exactly one `tool_result` block with a matching `tool_use_id`. Miss one, and the API is bricked.**

This constraint turns the messages array from "a loosely structured list of messages" into "data that must maintain a specific structure."

**This invariant is what spawns an entire family of repair mechanisms** — interruption, compaction, and rewind all break pairing in their own way, and each needs its own repair strategy. Those live in dedicated later articles. For the main narrative, it's enough to know that "pairing is a hard constraint."

## isMeta — A Message the Harness Slips to the LLM

So far, the roles that have shown up in the messages array are:

- user messages that a real user actually typed
- assistant messages the LLM produced
- tool_result messages the harness generates (riding on the user role)

There's a fourth category: **messages the harness actively injects for the LLM, but doesn't want shown in the UI**.

A few examples:

- At session start, the harness needs to tell the LLM today's date / the project's CLAUDE.md contents
- After a user interruption, the harness needs to synthesize an "Interrupted by user" message to patch a broken tool_result pairing
- After a compaction, the harness needs to inject a summary saying "here's what the past conversation was condensed into"
- Once an MCP server connects, the harness needs to notify the LLM that "new tools are now available"

These messages **must be visible to the LLM** — but if they showed up in the UI, the user would be baffled: "I never said that."

**Claude Code's solution**: tag the message with `isMeta: true`:

```
{ role: 'user', isMeta: true, content: '<system-reminder>...</system-reminder>' }
```

The semantics of `isMeta`: **this is a meta-message injected by the harness, not a real user** — the UI layer skips over anything with `isMeta` set.

**But here's the catch**: `isMeta` is a field internal to the harness — **the Anthropic API doesn't recognize it at all**.

When serialized and sent to the API:

```
{ role: 'user', content: '<system-reminder>...</system-reminder>' }
                                          ↑
                          no isMeta here — this is just an ordinary user message
```

So how does the LLM know this isn't something the user said?

**Through the `<system-reminder>` text tag embedded in the content.** The harness wraps these meta-messages in `<system-reminder>...</system-reminder>`. And the system prompt explicitly trains the LLM: **when you see `<system-reminder>`, this is a meta-instruction injected by the harness, not something the user said**.

**In other words**: a meta-message's identity rests **entirely on a textual convention** — structurally it's indistinguishable from a user message at the API level, and only the LLM's recognition of the tag reveals its true origin.

This design has a consequence: **if your CLAUDE.md or a user message happens to contain a `<system-reminder>` tag, the LLM will treat that segment as a meta-instruction**. This is a theoretically injectable attack surface, and there's no filtering of that string visible anywhere in Claude Code.

## The Three Invariants

At this point, the shape of the messages array has been fully unfolded:

- On the surface it's a **flat array** (the in-memory view)
- Underneath it's a **parent-child linked list** (the on-disk view)
- Every message carries role / content / uuid / timestamp / optional isMeta / optional parentUuid
- tool_use and tool_result must be strictly paired
- Meta-messages ride in on the user role, identified via the `<system-reminder>` text convention

Every operation (compact / rewind / interrupt / fork / sub-agent) has to respect this **same set of invariants**. They boil down to three:

### Invariant 1 · Append Only — No Update, No Delete, No Reorder

- The in-memory array can only be appended to at the tail — existing messages can never be modified
- The on-disk JSONL is append-only — never overwritten, never deleted
- Change the position of a message and the parentUuid chain breaks — the on-disk leaf can no longer trace its way back
- Does rewind break this? Rewind is a **memory-level slice — the disk is untouched** — the disk still only ever appends

**Why this one is so rigid**: because the moment update / delete were allowed, the entire session's state would lose any "deterministic path back" — recovering a session, you'd have no way to know which version to treat as authoritative.

### Invariant 2 · tool_use ↔ tool_result Must Be Paired

- Every tool_use must have a corresponding tool_result with a matching `tool_use_id` — miss one and the API returns a flat 400
- The reverse also holds — a tool_result referencing a nonexistent tool_use is likewise disallowed
- Position doesn't matter — only the id match does — parallel tools are allowed to return in completion order
- Any operation that breaks pairing (interrupt / compact / rewind) **must repair it** — patch the orphan, strip the dangling reference

**Why this one is so rigid**: because the Anthropic API enforces it server-side as a structural constraint — the client has no say in the matter.

### Invariant 3 · Roles Strictly Alternate, Meta-Messages Ride the User Role

- The API only allows user / assistant to strictly alternate — two consecutive user messages with real content aren't allowed
- Meta-messages (CLAUDE.md injection, date changes, interrupt synthesis, compaction summaries) must go out on the user role, wrapped in `<system-reminder>` text so the LLM can recognize them
- Two adjacent user messages (say, a CLAUDE.md injection plus a tool_result) **must be merged into one** before they can go out — in the source this operation is called `smoosh`
- The merge works by concatenating the two content arrays together and packing them into a single user message

**Why this one is so rigid**: the training data taught the model a "user - assistant - user - assistant" alternating pattern. Two consecutive user messages, and the model will conclude the conversation should end, prematurely emitting a stop sequence. **Non-compliant structure doesn't just trigger an API error — it degrades the model's behavior.**

## Only on Top of These Three Invariants Do Higher-Level Features Make Sense

Once these three invariants are lodged in your head, every topic in the rest of the Loop series clicks into place much more smoothly:

- **compact** is "summarize a batch of old messages into one, while keeping tool_use/tool_result intact"
- **rewind** is "an in-memory slice plus a new conversationId, disk untouched"
- **interrupt** is "patch in every missing tool_result so pairing is complete again"
- **fork subagent** is "reuse the messages array but swap tool_result for a placeholder"
- **sub-agent** is "start a fresh messages array, but chain its parentUuid back to the parent"
- **CLAUDE.md injection** is "prepend an `isMeta: true` user message wrapped in `<system-reminder>`"

Each one is a specific design choice made **within the constraints of these invariants**. When later articles cover each topic, they'll come back and reference these three.

**Next up**, [03 · Prompt Cache Is the Skeleton — Why Everything Else Grew the Way It Did](03-prompt-cache.md) covers Prompt Cache — the cost of resending the entire messages array on every call, and how only caching makes that sustainable. Every design choice in caching, traced to its root, is shaped behind the scenes by the three invariants covered in this article.
