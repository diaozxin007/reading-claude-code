> This is the 03rd article in this series — following up on the main thread laid down in [00 · Introduction · Claude Code's 200K Ledger](00-intro.md): prompt cache is the foundation underneath everything Claude Code does. That opening piece covered the cache's **three iron laws** (prefix matching / one byte changed breaks the chain / breakpoints determine where cache starts) and the **three design principles** derived from them (stable stuff goes first / volatile stuff goes last / breakpoints isolate stability levels).
>
> This article covers how Claude Code actually turns those three principles into **a full mechanism** — exactly where the 4 cache breakpoints sit, how the static and dynamic segments are split, and how 6 counterintuitive designs all connect back to the same logic.
>
> This piece focuses on **principle and design**, not on sinking down to the code level. For specific function names and line numbers, see the reference section at the end.

## TL;DR

| Dimension | One-liner |
|---|---|
| **Claude Code's 4-breakpoint allocation** | Ordered by stability, high to low: end of tools → system static segment → system org segment → end of messages |
| **Explicit boundary between static/dynamic segments** | A sentinel string `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` draws the line — not heuristics |
| **Cache reshapes the shape of upper-layer design** | Anything that changes gets pushed back; anything stable stays put; a sentinel marks the boundary in between |
| **6 counterintuitive designs** | CLAUDE.md goes through SR instead of into system · Skill uses delta · fork uses a placeholder · env info is deliberately stale · daily date is sent as a standalone SR · MCP delta injection |
| **Shared philosophy** | Cache-static ≠ semantically static — chase cache-static, not semantically static |
| **Boundaries of the foundation** | Only meaningful for "same user, multiple turns" — short sessions / a new user every turn / prefixes that are inherently unstable all break the foundation |

## 1 · Claude Code's 4-breakpoint allocation

As covered earlier, the Anthropic API allows up to 4 breakpoints. Claude Code assigns these 4 breakpoints to 4 positions at **different stability tiers**.

### The stability pyramid

```
                    ┌──────────────────────┐
Most stable ▲  cross-session │ tools segment         │ Barely changes across an entire release
       │             ├──────────────────────┤
       │  cross-session │ system static segment │ main prompt · SR instructions · env info
       │             ├──────────────────────┤
       │  same session │ system org segment    │ allowed tool set · skill command table
       │             ├──────────────────────┤
       │  same session │  ⋯⋯⋯ dynamic segment ⋯⋯⋯      │ language · MCP instructions
       │             ├──────────────────────┤
       │  appended every turn │ messages segment      │ user messages · tool_result
Most volatile ▼
                    └──────────────────────┘
```

Claude Code allocates the 4 breakpoints as follows:

| Breakpoint | Position | What it preserves | Stability |
|---|---|---|---|
| **① End of tools** | End of the tools segment | All tool schemas (~20-30 KB) | Most stable: unchanged within an entire release |
| **② End of system static segment** | After main prompt / tool descriptions / SR instructions / env info | Main system prompt (~10-15 KB) | Stable: unchanged within a session |
| **③ End of system org segment** | After allowed tool set / skill command table | Org-level config (~3-5 KB) | Medium: occasionally changes |
| **④ End of messages** | End of the latest message | The full conversation history | Appended every turn |

**Why split it this way**: each breakpoint covers one stability tier. A change anywhere only busts **all breakpoints from that point onward** — it never drags down breakpoints that come before it, which are more stable.

For example:

- User sends a new message → only affects breakpoint ④'s cache match — ①②③ all hit
- MCP instructions change (in the dynamic segment) → only affects ④ — ①②③ all hit
- Org config changes (rare) → affects ③④ — ①② all hit
- Claude Code ships a new version with updated tool schemas → affects ①②③④, everything busts — but this only happens once every few weeks

**This is the value of stability tiering** — high-frequency changes only pay a high-frequency price, low-frequency changes only pay a low-frequency price.

## 2 · The static/dynamic boundary: a single string

Content-wise, Claude Code's system prompt looks like one continuous block — but from the cache's perspective it's **two segments concatenated**:

```
Static segment (has cache_control attached)
    +
[Boundary string __SYSTEM_PROMPT_DYNAMIC_BOUNDARY__]
    +
Dynamic segment (no cache_control attached)
```

**What the boundary is for**: the static segment's content doesn't change within a session, so attaching a breakpoint lets it enter cache. The dynamic segment can change every turn (e.g. MCP state) — attaching a breakpoint there would actually be a trap: it invalidates every turn, gets rewritten every turn, and pays write cost for nothing.

**How the boundary is implemented**: a sentinel string constant — the two segments are built by separate pieces of code, and a boundary string that will never appear in normal content is spliced in between. Right before serialization, the string is split at that boundary — the first half gets `cache_control`, the second half doesn't.

**The core idea behind this design**: **the cache boundary must be explicit** — it can't rely on heuristics (like "the first few lines are probably static"), because a single misjudgment busts the entire cache. A sentinel draws a clean line: which content goes into the static segment versus the dynamic segment is decided at coding time — zero decisions made at runtime.

**Cost**: one extra layer of concatenation logic, and the boundary string must never collide with real content. **Benefit**: deterministic cache hit rates.

## 3 · Six counterintuitive design cases

With the iron laws and the allocation in place, let's look at the **specific, counterintuitive** designs. Every case follows the same pattern: intuition says do it one way → but from the cache's perspective that would bust things → so the actual implementation looks different.

### Case 1 · CLAUDE.md doesn't go into the system prompt

**Intuition**: CLAUDE.md is "static instructions for the agent" — project rules, coding style, team conventions — it obviously belongs in the system prompt.

**Cache's perspective**: CLAUDE.md's content **does change**:

- The user edits their own CLAUDE.md
- Switching projects means CLAUDE.md's content changes entirely
- An `@import` expands to pull in a newly referenced file
- CLAUDE.md gets modified mid-session (hot reload)

If CLAUDE.md went into the system static segment: one change → breakpoint ② gets punched through → every cache after the tools segment busts.

**What actually happens**: CLAUDE.md **doesn't go into the system prompt** at all. Instead it's prepended into the user message position within the **messages segment**, wrapped in `<system-reminder>`.

**The benefit of this**:

- CLAUDE.md changes only affect breakpoint ④'s (messages segment) matching — and the messages segment is expected to change every turn anyway
- Breakpoints ①②③ are completely unaffected — the large cache covering tools + system stays intact

**A trade of "a smaller cache for a bigger one."** The user's experience of "CLAUDE.md takes effect" stays the same, but the bill is dramatically smaller on the back end.

### Case 2 · Skill listing sends deltas, not the full list every time

**Intuition**: list every available skill on every single turn so Claude knows what's available — the full list is simplest.

**Cache's perspective**: a full skill listing is a 5-20 KB block of text. If it's sent every turn:

- The messages segment prefix differs every turn (because the previous turn's listing has now become part of history)
- Breakpoint ④ fails to match — all prior history messages need recomputing
- Every turn costs an extra several thousand to tens of thousands of tokens in write cost

**What actually happens**: maintain a "set of skill names already sent" — every subsequent turn only sends **newly added** skills (a delta).

**An even sharper detail**: after `/compact`, this set **is not cleared** — meaning skill listings don't get resent after a compact. Intuitively you'd think post-compact should "reload the full context," right? But the source has an explicit comment to the effect that:

> The post-compact skill listing is pure `cache_creation` (~4K tokens) — not resending it actually preserves cache.

This shows **extreme cache-first thinking**: the model's memory of the skill list might fade slightly, but preserving 4K tokens of cache is worth far more — over the course of a session, the accumulated savings can be dozens of times over.

### Case 3 · All subagents forked from the same call share one placeholder

**Intuition**: forking lets a subagent continue the parent's work — it should carry the parent's full history, including every tool call result.

**Cache's perspective**: if a single conversation forks many subagents (say, batch-processing 100 URLs), and each subagent carries different tool_results, then:

- Every subagent's **history prefix differs** (because the tool_results differ)
- Every subagent starts a brand-new cache prefix → all misses
- 100 forks means 100 full cache writes — costs explode

**What actually happens**: across every fork's history, **every tool_result gets replaced with the exact same fixed string** — `"Fork started — processing in background"`.

**The effect**:

- All forks' history prefixes are **byte-for-byte identical**
- The first fork establishes the cache, and the other 99 all hit it
- For each fork, only the last few hundred words — the specific instructions handed to the subagent — actually vary

**This is the extreme end of prompt cache engineering** — a single placeholder buys a 100x cache hit rate in this scenario. The cost is that the subagent can't see the parent's actual tool_results — but a subagent needs "the task in context," not "the history in context." The parent's instructions convey that directly.

### Case 4 · Environment info is deliberately stale

**Observation**: after running `cd /new/dir`, the cwd Claude sees is still the old one.

**First instinct**: this is a bug.

**Cache's perspective**: the `<env>` block (containing cwd / git status / platform / model info) is attached in the system static segment. If cwd got refreshed after every `cd`:

- Breakpoint ② would get punched through
- Every cache after the tools segment busts
- Every `cd` would cost tens of thousands of tokens in write cost

**What actually happens**: `<env>` is computed once per session, memoized, and never refreshed on subsequent `cd`s.

**This is deliberate** — the Claude Code team made a trade-off:

- Places that actually need the real cwd (Bash · Read · Write · Edit) go through an independent `getCwd()` — reading from process state, always accurate
- The cwd in the system prompt is only there for "letting Claude roughly know which project it's in" — being a bit stale doesn't matter
- In exchange, `cd` never busts the cache — every `cd` saves tens of thousands of tokens in write cost

**This is a training exercise in trade-offs at the principle level**: if a piece of information "being a bit stale doesn't hurt correctness," lock it into cache; if it "must be real-time," route it through a different path that never enters cache.

### Case 5 · Daily date is sent as a standalone system reminder

**Intuition**: put today's date directly in the system prompt — "Today is 2026-07-30" — simplest approach.

**Cache's perspective**: if the date lives in the system prompt, then every day at midnight, the system segment cache for **every single Claude Code session on earth** invalidates simultaneously — the cost of a single API request suddenly jumps several times over.

**What actually happens**: the date **doesn't go into the system prompt**. Instead, a "the date has changed" `<system-reminder>` gets appended separately to the messages segment:

> The date has changed. Today's date is now 2026-07-30.

**Effect**:

- The system segment stays stable — breakpoints ②③'s cache is preserved
- Crossing midnight only affects a small chunk of the messages segment — breakpoint ④ changes minimally
- No global cache avalanche across every user at midnight

**The lesson from this design**: **anything tied to "time" cannot go into a cached segment** — time is constantly changing, and that's the cache's natural enemy.

### Case 6 · MCP instructions are injected incrementally

**Background**: an MCP (Model Context Protocol) server has its own instructions — telling the agent "how to use me." It's static guidance meant for the agent.

**Intuition**: connect to an MCP server once, splice its instructions into the system prompt, done.

**Cache's perspective**: MCP server connections are **asynchronous**:

- Some servers connect within a second
- Some take several seconds
- Some disconnect and reconnect mid-session
- Users can install new MCP servers mid-session

If instructions went into the system prompt:

- Every MCP state change → system segment changes → the big cache busts
- If a session sees MCP connect/disconnect 5 times, that's 5 full cache rebuilds

**What actually happens**: MCP instructions are injected incrementally — only when an MCP server **newly connects**, its instructions get appended to the messages segment via a `<system-reminder>`, covering just that batch of new connections.

**Effect**:

- The system segment stays stable
- MCP's dynamic changes only affect a small chunk of the messages segment
- Asynchronous MCP connections are supported without paying a cache tax

## 4 · The shared pattern across all 6 cases

Reading through the 6 cases above, you'll notice they all follow the same pattern:

```
① Intuition: this thing should go into the system segment because it's "semantically static"
② But it's actually unstable (it changes / connects asynchronously / is tied to time / is tied to the user)
③ If it went into the system segment, one change would bust a large chunk of cache
④ So the actual approach: route it through a different path — the SR channel in the messages segment,
   or deliberately don't refresh it, or use a placeholder to flatten out the differences
```

**The core idea is**: **"static" from the cache's perspective** ≠ **"static" from a semantic perspective**.

- Semantically static: CLAUDE.md is a fixed set of instructions for the agent — it's static
- Cache-static: content is unchanged down to the byte — only that counts as static

Every "seemingly weird" design in Claude Code is a trade-off made **in favor of cache-static rather than semantically static**.

This philosophy is the answer to "why other mechanisms are shaped the way they are," which [00 · Introduction · Claude Code's 200K Ledger](00-intro.md) raised at the outset — every specific mechanism covered in the next 4 articles, if you push far enough, traces back to this same logic.

## 5 · Boundaries of the foundation

The prompt cache foundation **isn't a universal truth** — it only holds under specific conditions. Here are the scenarios where this foundation **breaks down**:

| Scenario | Why the foundation breaks down |
|---|---|
| **A new user on every request** | Anthropic's cache is isolated per-user — switching users is an instant miss |
| **Sessions with only 1-2 turns** | Cache writes cost 1.25x — for something sent only once or twice, the write cost never pays itself back |
| **Prefixes that are inherently unstable** | E.g. every request needs fresh knowledge-base search results spliced in — the prefix changes every single time by nature |
| **Cost-insensitive scenarios** | Some use cases are constrained by latency, not cost |
| **Using another vendor's API (e.g. OpenAI, Gemini)** | Each vendor's cache mechanism is different — the design needs to be re-derived from scratch |

## 6 · Summary

- **Cache has three iron laws**: prefix matching · one byte changed breaks the chain · breakpoints determine where cache starts
- **The three iron laws lead to three design principles**: stable stuff goes first · volatile stuff goes last · breakpoints separate stability tiers
- **Claude Code uses all 4 breakpoints**: end of tools → system static → system org → end of messages — 4 stability tiers
- **The static/dynamic boundary uses an explicit sentinel**, not heuristic judgment
- **The shared philosophy across the 6 counterintuitive cases**: cache-static ≠ semantically static — chase cache-static, not semantically static
- **The foundation has boundaries** — it doesn't hold for short sessions / a new user every turn / prefixes that are inherently unstable

In one sentence: **Claude Code doesn't design a feature first and then think about cache — it looks at the cache constraints first, and works backward from there to design every feature.**

Next up, 02 · The Six Siblings of Compaction: even a mechanism like "compressing history," which seems unrelated to cache on the surface, has its specific trigger conditions / retention policy / reattachment budget all traceable back to the cache's perspective.

---

## References

**Anthropic official**:

- [Prompt caching · Anthropic docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) — the underlying mechanism
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — the 4-strategy framework
- Thariq Shihipar (Anthropic), quoted via [Simon Willison](https://simonwillison.net/tags/claude-code/) (2026-02-20)

**Claude Code source locations** (v2.1.220):

- Tools breakpoint location: `src/utils/api.ts` · `toolToAPISchema`
- System prompt segmentation: `src/utils/api.ts` · `splitSysPromptPrefix`
- CLAUDE.md injection: `src/utils/api.ts` · `prependUserContext`
- Breakpoint allocation: `src/services/api/claude.ts` · `addCacheBreakpoints`
- 1h TTL rollout: `src/services/api/claude.ts` · `should1hCacheTTL`
- Cache invalidation detection: `src/services/api/promptCacheBreakDetection.ts`
- Boundary string definition: `src/constants/prompts.ts` · `SYSTEM_PROMPT_DYNAMIC_BOUNDARY`
- Fork placeholder: `src/tools/AgentTool/forkSubagent.ts` · `FORK_PLACEHOLDER_RESULT`
- Skill listing delta: `src/utils/attachments.ts` · `sentSkillNames`
- MCP delta: `src/utils/attachments.ts`
- Date change SR: `src/utils/messages.ts`

**Related notes in this vault**:

- [00 · Introduction · Claude Code's 200K Ledger](00-intro.md) — the full ledger of 4 strategies × 20+ mechanisms
- Deep dive on System Prompt — general principles of prompt cache at the API layer (TTL thresholds / read-write costs / chat templates, etc. — complements this article)
