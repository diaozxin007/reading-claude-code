> This is the opening article of the "Claude Code Context Management Research Series" — first we build a panoramic map, then dive in one piece at a time. This piece stakes out the main thread: **prompt cache is the foundation underneath everything Claude Code does**. Then it covers the 4 major strategies and 31 concrete mechanisms sitting on top of that foundation. The goal is to give the following 6 articles an architecture diagram they can hang new knowledge on.
>
> This series is based on the leaked Claude Code v2.1.220 source (Bun + TypeScript + Ink) — every conclusion can be traced back to a specific `file:line`.

## Starting from an observable phenomenon

You may have noticed this before:

> **20 turns into a conversation, a response comes back much faster than the previous one — with no "cache loaded" indicator anywhere in sight.**

This isn't your imagination — it's **prompt cache** at work. Every time Claude Code calls the LLM, it resends **every message from the start of the conversation**. The server notices the prefix matches last time, reuses the previous computation, and returns much faster at roughly a tenth of the cost.

Cache isn't simply an "accelerator" — it's the **foundation everything in Claude Code is built on**.

Anthropic's Thariq Shihipar put it bluntly:

> **"At Claude Code, we build our entire harness around prompt caching."**

The first time you read that line it sounds like marketing copy. Once you actually read the Claude Code source, you find it's literal: **from where CLAUDE.md gets injected, to how sub-agents are constructed, to how skill listings get sent incrementally, to how the date is announced across midnight — every design decision that looks counterintuitive traces back to "built to protect the cache."**

This article covers that foundation, and the entire context management architecture it shapes in turn.

## The three iron laws of cache

To understand Claude Code's context design, you first need to memorize the **three underlying rules** of Anthropic's prompt cache. These aren't specific to Claude Code — every application built on the Anthropic API has to deal with them.

**Iron law 1 — prefix matching from the start**

Cache is **prefix matching from the very beginning**. If the first 25,000 tokens of a request are identical to last time, the computation for those 25,000 tokens can be reused, and you only pay full price for the new tokens after that. It's strictly anchored to the first token of the request, matching up to the first differing byte.

**Iron law 2 — one byte changes, the prefix breaks**

If a single byte in the prefix changes, everything after it counts as "new" and has to be recomputed. That means: **any instability anywhere in the system prompt invalidates the cache for everything downstream.**

**Iron law 3 — breakpoints decide where cache starts**

The Anthropic API lets you attach up to 4 `cache_control` breakpoints per request. A breakpoint means "everything before this position needs to be written to cache" — more breakpoints let you cover more layers of stability. Reading from cache is cheap (0.1x cost); writing to cache is slightly more expensive (1.25x, 5-minute TTL).

These three laws yield three design principles:

- **Put stable things up front, put changing things at the back** — that way when the changing things change again, they don't touch the cache ahead of them
- **Separate different stability tiers with different breakpoints** — a bust in one tier shouldn't drag the others down with it
- **Anything that doesn't need to be in a stable segment shouldn't be** — cramming something volatile into a stable segment drags everyone else down too

**Every piece of Claude Code's context design is a direct consequence of these three principles.** Every specific mechanism covered later traces back here.

## What cache shapes in return — a counterintuitive observation

It took a long time using Claude Code before this sank in:

**There is no module called "context management."**

Intuitively you'd expect to find a `ContextManager` class somewhere in the source, responsible for counting the window, compacting, injecting, and so on. That's not how it works:

- Compaction logic is scattered across 6 different files (`compact/` has `compact.ts`, `autoCompact.ts`, `microCompact.ts`, `sessionMemoryCompact.ts` — not even counting the `contextCollapse` feature flag or the reactive-compact branch at the API layer)
- CLAUDE.md injection code lives in `utils/claudemd.ts`, Skill injection code lives in `SkillTool.ts`, MCP schema injection code lives in `toolSearch.ts` — all three inject in **completely different ways**
- There are two functions for assembling `<system-reminder>` tags (`wrapInSystemReminder` and `wrapMessagesInSystemReminder`, both in `messages.ts`) — but the SR content itself has 20+ different trigger conditions scattered across a dozen locations

**This isn't a lack of design — it's the inevitable result of cache.**

Cache is a **cross-cutting concern** — it isn't a feature module, it's something **every feature has to participate in**. It's similar to logging: you don't write a `LogManager` class and require every piece of code to route through it — you define a logger interface, and every module uses it by convention.

Same story with cache:
- The CLAUDE.md system manages its own way of entering the messages segment (not the system prompt)
- The Skill system manages its own way of doing deltas (not resending everything)
- Compaction manages its own trigger timing (without touching the system segment)

Forcing all of this into a single `ContextManager` would create a **god object** — anyone changing a feature would have to touch it, and as a result nobody would dare touch it.

Claude Code's choice: **no central ContextManager, but one iron invariant — protect the cache.** Every feature guards that invariant on its own; it doesn't matter which file the implementation actually lives in. It's the same logic as a microservices architecture — no central database, but an API contract.

## The 4 major strategies are concrete designs that yield to cache

In Anthropic's September 2025 blog post [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), they lay out 4 major context management strategies explicitly. But once you read the source, you find: **every concrete form each of these 4 strategies takes is kneeling in front of cache — any approach that can't protect the cache doesn't even make the shortlist.**

| Strategy | What it solves | The key cache concession |
|---|---|---|
| **Compaction** | Sessions get long — context eventually fills up | The compaction summary **only touches the messages segment**, leaving the tools/system segment cache untouched |
| **Structured note-taking** | Project/user preferences can't be carried through conversation history alone | CLAUDE.md **doesn't go into the system prompt** — it goes through the messages segment as an SR user message, so changes only affect the messages cache |
| **Sub-agent decomposition** | The exploration cost of a single task can fill up context | Fork sub-agents replace every `tool_result` with a **placeholder**, letting 100 forks share the exact same cache prefix |
| **Just-in-time retrieval** | You don't know which data you'll need, but you can't stuff it all into context either | Skill listings use **deltas rather than the full list**, MCP schemas use **server-side defer_loading** — both are concrete ways to avoid busting cache |

**Under each strategy you can list a batch of "looks weird but that's genuinely how the source is written" designs** — every one of them is a direct consequence of cache:

- CLAUDE.md gets prepended in the messages segment — **not** placed in the system prompt — because CLAUDE.md changes
- Skill listings are injected incrementally — **not** resent in full every turn — because resending in full busts cache every single turn
- Inside a fork sub-agent, every `tool_result` is replaced with `"Fork started — processing in background"` — **making the prefix bytes of 100 forks completely identical**
- Today's date is **not hardcoded** into the system prompt — it's sent as a one-off `date_change` system reminder — because hardcoding it into system means every session worldwide loses its cache the moment midnight rolls over
- MCP instructions are injected as deltas, because MCP connections are asynchronous — every new connection would otherwise bust the system cache
- The `<env>` block is memoized, not refreshed — after a `cd`, cwd inside it is actually stale — **this isn't a bug, it's intentional, to protect the cache**
- The `skipCacheWrite` message breakpoint retreats to the second-to-last message — a one-off, fire-and-forget side question shouldn't pollute the main-line cache
- `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` splits the prompt into a static/dynamic segment — only the static segment carries `cache_control`; the dynamic segment (env / language / MCP) can change every turn without affecting the static segment's hit rate

**Once you've read through this list, it clicks**: Claude Code doesn't design a feature first and then think about cache afterward — it **looks at the cache constraint first, and works every feature backward from there**.

## The panoramic map — a matrix of 31 mechanisms

The table below is the core index for this whole series — which mechanisms get torn apart in each later article all comes from here. **Every single row, traced to the root, exists to protect cache** — as you read, try guessing which of the three iron laws each row maps to.

| Strategy | Concrete mechanism | One-line summary | Which article covers it |
|---|---|---|---|
| **compaction** | `/compact` manual compaction | User-triggered, can carry custom instructions | 04 |
| **compaction** | auto-compact | Threshold-triggered, runs between turns | 04 |
| **compaction** | micro-compact | Low-cost in-turn tail pruning | 04 |
| **compaction** | reactive-compact | Emergency response when the API returns `prompt_too_long` | 04 |
| **compaction** | sessionMemoryCompact | Cross-session persistence | 04 |
| **compaction** | contextCollapse | An aggressive variant currently in feature-flag rollout | 04 |
| **compaction** | `/clear` | No summarization — just a reset; draws the line against `/compact` | 04 |
| **compaction** | `/rewind` | Timeline-level rewind, can only target user messages | 04 |
| **note-taking** | CLAUDE.md 4-layer loading (user / project / .claude / local) | Walks upward from cwd, concatenating layer by layer | 05 |
| **note-taking** | `.claude/rules/*.md` path-scoped | Uses the `paths:` frontmatter matched via picomatch | 05 |
| **note-taking** | `@import` recursion (5-hop) | `@filename` inside CLAUDE.md gets expanded | 05 |
| **note-taking** | MEMORY.md auto memory | Loaded at session start, 40K character budget | 05 |
| **note-taking** | Todo v2 persistent tasks | Persisted to disk as JSON, operated via TaskCreate/Get/List/Update | 05 |
| **note-taking** | `prependUserContext` injection channel | Packaged as a `<system-reminder>` user message prepend | 05 |
| **sub-agent** | Agent tool's independent context | Starts a fresh system prompt by default | 06 |
| **sub-agent** | fork sub-agent (the sole exception) | Inherits the parent's context, uses placeholders to protect cache | 06 |
| **sub-agent** | `isolation: worktree` | git worktree + `AsyncLocalStorage` cwd | 06 |
| **sub-agent** | Task family's 2 coexisting stores | Todo v2 on disk plus an in-memory store for running tasks | 06 |
| **sub-agent** | The `.output` symlink trap | For local_agent it's a full JSONL — reading it blows up context | 06 |
| **sub-agent** | SendMessage mailbox system | File-based cross-agent communication | 06 |
| **JIT** | Read offset/limit + 2000-line truncation | Large files are silently truncated by default | 07 |
| **JIT** | `readFileState` LRU-100 | Files are cached after being read — the 100-entry cap has a gotcha | 07 |
| **JIT** | Read dedup (`FILE_UNCHANGED_STUB`) | An undocumented mechanism — a second Read returns an instruction instead of bytes | 07 |
| **JIT** | Skill body injected on demand | Listing only sends frontmatter — the body gets embedded when actually used | 07 |
| **JIT** | Skill listing sent incrementally | Tracked via `sentSkillNames` — only the delta is sent | 07 |
| **JIT** | MCP ToolSearch (server-side) | Client flags `defer_loading` — the server hides the schema | 07 |
| **JIT** | MCP instructions delta | Avoids cache invalidation when an MCP connects late | 07 |
| **foundation** | Agent Loop — the messages array only ever grows | LLMs are stateless — the harness resends history every time | 01 |
| **foundation** | The 3 invariants of the messages array | Append-only / tool_use pairing / strict role alternation | 02 |
| **foundation** | Prompt Cache's 4 breakpoints | 1 tools + 2 system + 1 messages — covering 4 layers of stability | 03 |
| **foundation** | `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` | The sentinel that splits the static/dynamic segments | 03 |
| **meta** | 20+ `<system-reminder>` types | Six categories: static appendix / cadence / event / delta / user context / mode switch | 07 |
| **meta** | `<env>` block memoization | cwd goes stale, but it's intentional to protect the cache | 07 |
| **meta** | Cyber-risk notice attached to Read | Appended to every Read except on opus-4-6 | 07 |

That's **31 items** — and it isn't even exhaustive (there's another batch behind feature flags that are currently switched off in the source).

## A visualization — what cache looks like in a single request

The skeleton above is abstract. Here's what a concrete request actually looks like — say the user types "help me add user login to this app" — the context shapes up like this:

```
─────────────────────────────────────────────────────────────
1. Static segment (carries cache_control · stable for the whole session)
─────────────────────────────────────────────────────────────
  ├─ tools list (cache_control attached to the last schema)
  ├─ system prompt · static portion
  │    ├─ Claude Code main prompt
  │    ├─ overview of tool descriptions
  │    ├─ SR teaching ("Tool results may include <system-reminder>…")
  │    └─ <env> block (cwd, git, platform, model, cutoff)
  └─ <SYSTEM_PROMPT_DYNAMIC_BOUNDARY>          ← sentinel · divides static/dynamic segments

─────────────────────────────────────────────────────────────
2. Dynamic segment (no cache_control · allowed to change every turn)
─────────────────────────────────────────────────────────────
  ├─ session guidance (allowed toolset · skill command table)
  ├─ MCP instructions (resent every turn if delta mode is off)
  ├─ output style
  └─ language

─────────────────────────────────────────────────────────────
3. Messages segment (breakpoint at messages.length-1 · covers all history)
─────────────────────────────────────────────────────────────
  ├─ [prepend user msg · isMeta:true]        ← this is how CLAUDE.md gets in · NOT via system!
  │    <system-reminder>
  │       # claudeMd
  │       ~/.claude/CLAUDE.md (global)  ← expanded via @import, 5-hop
  │       /repo/CLAUDE.md (project)
  │       ~/.claude/rules/*.md (path-matched ones)
  │       # currentDate
  │       Today's date is …
  │    </system-reminder>
  ├─ user message: "help me add login"
  ├─ alternating tool_use / tool_result (a few rounds of Read / Edit / Bash)
  │    every Read has a <system-reminder> cyber-risk tail attached
  │    every Edit goes through a readFileState LRU check
  ├─ [cadence trigger at 10 turns]
  │    <system-reminder>
  │       The TodoWrite tool hasn't been used recently…
  │    </system-reminder>
  └─ the current turn's new user message

─────────────────────────────────────────────────────────────
4. Edge cases: channels that only appear when something special happens
─────────────────────────────────────────────────────────────
  ├─ context nearly full → auto-compact (between turns)
  ├─ API returns prompt_too_long → reactive-compact (emergency)
  ├─ after generating a skill → skill listing delta
  ├─ a file gets modified externally → edited_text_file SR ("Note: X was modified…")
  ├─ crossing midnight → date_change SR
  └─ sub-agent spawns → brand new context · <usage> backfilled
```

**A few observations** (each one a direct consequence of cache):

1. **CLAUDE.md doesn't go through the system prompt** — because CLAUDE.md changes, and if it were in the system prompt, any change would bust the large cache. It goes through the messages segment prepend instead — changes there only affect the messages cache
2. **`<system-reminder>` is a single bus** — every scenario that needs to "notify the model of a meta-instruction" routes through this one channel, because the messages segment already changes anyway, so appending an SR there does the least damage to cache
3. **The static and dynamic segments are split explicitly** — via a literal sentinel (not a heuristic) — the cache boundary has to be explicit, not guessed
4. **Even the every-10-turns cadence reminder goes through the messages segment** — it's not wall-clock based, it runs once during message normalization before every API call

## The questions the remaining 7 articles will answer

The learning goal here is to **answer questions**, not enumerate mechanisms. Each article maps to a specific question — if the question isn't resolved, the mechanisms that follow are just loose beads.

| # | Title | Question you'll be able to answer after reading |
|---|---|---|
| **01** | Agent Loop — how context gets assembled | Is the LLM stateful or stateless? How many round trips does the harness actually make to the LLM in one conversation? How does the messages array grow? |
| **02** | From a single message to the 3 invariants of the messages array | What shape does each message in the array take? What's the hard constraint requiring tool_use/tool_result to pair up? How do isMeta and the `<system-reminder>` channel work? |
| **03** | Prompt Cache is the skeleton — why other mechanisms end up the way they do | How exactly do the "three iron laws" from this article map onto the 4 breakpoint distribution? How many segments does `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` actually split things into, and what hangs on each? A full case-by-case breakdown of 6 counterintuitive designs |
| **04** | The Compaction sextet — `/compact`, `/clear`, `/rewind` + auto + micro + reactive | What happens when context fills up? What model does `/compact` use to summarize? Which files get reattached after a compaction? Why can't you find the "80% threshold" Anthropic's official blog mentions anywhere in the source? |
| **05** | The CLAUDE.md family — 4-layer loading + `@import` + rules + MEMORY.md | What static instructions get loaded at the start of a session? How many levels deep does `@filename` recursion actually go? How does `.claude/rules/` take effect based on path? Is MEMORY.md's cap measured in lines or bytes? |
| **06** | Sub-agent isolation — Agent + fork + Task + SendMessage | Can a sub-agent actually see anything from the parent? How is worktree isolation implemented? Why does reading the `.output` file blow up context? What do the two task stores each do? |
| **07** | Meta mechanisms — `<system-reminder>` typology + file state + Read dedup + ToolSearch | Exactly how many types of SR are there? What triggers each one? How does the readFileState 100-entry cap gotcha get triggered? Is ToolSearch client-side BM25 or server-side defer? |

## 8 places where the official docs and the source disagree

This round of discovery had a side benefit — **8 places where Anthropic's official documentation says one thing and the source does another**. They're listed here so you can carry this "gotcha list" into the articles that follow — knowing these in advance should make every source-level fact more interesting to read:

| # | What the official docs say | What the source actually does |
|---|---|---|
| 1 | `@import` recursion caps at 4 hops | It's 5 hops (`MAX_INCLUDE_DEPTH = 5`) |
| 2 | A 1000-pattern / 4 MiB memory budget | Doesn't exist at all — the actual limit is `MAX_MEMORY_CHARACTER_COUNT = 40_000` |
| 3 | MEMORY.md frontmatter uses `node_type: memory` | It actually uses three fields: `name / description / type` |
| 4 | auto-compact triggers at 80%/90% of context | It's an absolute value: `contextWindow - 20K reservedOutput - 3K buffer` |
| 5 | `/compact` summarizes with Haiku | It uses `mainLoopModel` (the same model as the main conversation) |
| 6 | ToolSearch: "10% context if schemas fit" | The 10 is a Bernoulli auto-defer probability, not a context-size threshold |
| 7 | Skill bodies are lazy-loaded | The body is **eager-loaded from disk**, but **injection into context is late** (these are different things) |
| 8 | Read dedup isn't mentioned at all | It's in the source, gated behind a killswitch (`tengu_read_dedup_killswitch`) currently in rollout |

These aren't Anthropic lying to anyone — it looks more like the docs lagging behind the source, or the product team and docs team simply falling out of sync. But for anyone doing deep research, **the source is the only ground truth**. Every article from here on opens a small "official vs. source" section — that's part of what differentiates this series from anything else you'll find on the subject.

## Summary

In one sentence: **Claude Code is a system that looks at the prompt cache constraint first, then works every piece of context design backward from it.**

- **Cache's three iron laws**: prefix matching from the start, one byte breaks the prefix, breakpoints decide where cache starts
- **Three design principles**: stable things up front, changing things at the back, breakpoints separate stability tiers
- **No central ContextManager, but one iron invariant** — cache is a cross-cutting concern, and every feature guards it on its own
- **The 4 major strategies are concrete designs that yield to cache** — every form each one takes traces back to "must not bust the large cache"
- **31 concrete mechanisms scattered across the source** — every one of them, traced to the root, exists to protect cache
- **8 places where the official docs and the source disagree** — one of this series' differentiators

The remaining 7 articles unfold in the order `Agent Loop → messages array invariants → Prompt Cache's concrete design → the 4 strategies → meta mechanisms`. Next up: [01 · Agent Loop — how context gets assembled](01-agent-loop.md), which lays out exactly what shape the messages array takes. Then [02 · From a single message to the 3 invariants of the messages array](02-message-invariants.md) covers the structural constraints. Then [03 · Prompt Cache is the skeleton — why other mechanisms end up the way they do](03-prompt-cache.md) unpacks how this article's three iron laws land on Claude Code's actual 4 breakpoints.

---

## References

- Anthropic blog: [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (September 2025)
- Anthropic blog: [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
- Anthropic blog: [Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)
- Anthropic docs: [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) — the underlying cache mechanism documentation
- Simon Willison (2026-02-20) — Thariq Shihipar quote — [claude-code tag](https://simonwillison.net/tags/claude-code/)
- Claude Code docs: [code.claude.com/docs/en](https://code.claude.com/docs/en) (note: `docs.anthropic.com/en/docs/claude-code/*` now 301-redirects here)
- Claude Code source (leaked v2.1.220) — local path
- This series' full discovery report: 00 · Discovery report · the 4 major strategies and a checklist of 20+ mechanisms
- Related notes in the vault:
  - Deep dive on System Prompt — the underlying mechanics of system prompt / prompt cache
  - Study notes s08 — Context Compact L1-L4
  - Claude Code Tools Research Series (9) Agent — Agent tool's independent context
  - Claude Code Tools Research Series (5) Read — readFileState / empty file
