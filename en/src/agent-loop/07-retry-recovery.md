The previous few articles covered what the loop does when it hits an error it **can recover from on its own**: bumping `max_tokens` and retrying, triggering compact when context is full, switching models on a refusal `stop_reason`. But all of these are **semantic-level** errors — the LLM's result isn't what it should be.

Real products also face a whole other class of **infrastructure-level** errors:

- the network is down, the request never even went out
- the API returns 500 — internal server error
- the API returns 429 — rate limit exceeded
- the API returns 529 — overloaded, Anthropic's cluster is under heavy load
- the API returns an error saying `prompt_too_long` — the messages array has grown too large

This article covers how these errors get handled: retry, backoff, model fallback, compact recovery. The core question: **when the loop hits an infrastructure error, what does it do — when does it retry, when does it give up, when does it switch models, when does it compact?**

## Every API Call Is Wrapped in withRetry

Claude Code never makes a **bare call** to the LLM — every call goes through a `withRetry` wrapper. One logical "call_llm" might sit on top of 1-10 actual HTTP requests.

The core of `withRetry`:

- **DEFAULT_MAX_RETRIES = 10** — 10 retries max by default
- overridable via the environment variable `CLAUDE_CODE_MAX_RETRIES`
- on failure, decide whether this failure **is retryable** (see the next section)
- if retryable, sleep per the backoff strategy and resend; if not, throw straight up to the loop

From the loop's point of view, one call either succeeds or fails — everything in between is hidden inside `withRetry`. The loop only ever sees the "final result."

## Deciding Whether to Retry — the Server Has the Final Say

The naive approach: let the client **decide for itself** which errors are retryable — 500s yes, 429s yes, 400s no.

**Claude Code's choice**: prefer to **ask the server**.

The Anthropic API attaches a header to error responses:

```
x-should-retry: true
```

or:

```
x-should-retry: false
```

**If the server says retry, retry; if it says don't, don't** — regardless of status code.

**Why trust the server**:
- a client-side heuristic (e.g. "retry all 5xx") is wrong in some edge cases — some 500s are actually "something's wrong with the request itself," and retrying is pointless
- the server knows the internal cluster state — an error that looks like a rate limit might actually mean "the model for this request is unavailable," and retrying doesn't help
- the server can **adjust retry semantics dynamically** — it can change behavior at deploy time without the client needing to ship a new release

**Only fall back to a heuristic if the header is missing** — checking status code, error type, or strings in the error body. For example, if the body contains `"type":"overloaded_error"`, it's judged retryable.

**This design pattern is extremely common in production systems** — let the **server drive the decision**, with the client only providing a fallback. The benefit is **decoupled evolution**: the server can adjust its logic anytime without the client needing a new release.

## Backoff Strategy — Prefer Retry-After, Fall Back to Exponential Backoff

Once a failure is judged retryable — **how long should it wait before retrying**?

Claude Code again defers to the server first:

- if the response header has `Retry-After: 30` (seconds), sleep 30 seconds
- if the response header has `Retry-After: <HTTP date>`, sleep until that point in time
- if neither is present, fall back to **exponential backoff** — 1s, 2s, 4s, 8s, 16s, 32s...

**Why prefer server-specified backoff**:
- the server knows exactly when the rate limit resets (it has a precise window)
- client-side exponential backoff is **blind** — you might sleep for 32 seconds while the server actually recovers after 5, and you waited for nothing
- or the other way around — your exponential backoff hits 8 seconds and fires, but the server still hasn't recovered, and the retry fails again

**Server-specified backoff** eliminates that blindness, keeping retries as efficient as possible.

There's a special pattern here too: **persistent retry** — when hitting a rate limit, instead of exponential backoff, use the rate-limit window's reset time directly. For example, if the limit is "100 requests per minute" and it's used up, just sleep until the next minute starts. This is the most precise retry cadence there is.

## The Special Handling of 529 Overloaded

Anthropic's 529 status code carries a special meaning: **"our cluster is under heavy load, there's no capacity to handle your request right now."**

This differs from 429 (rate limit) — 429 means "you're requesting too fast," 529 means "our servers are busy."

Retrying 529 blindly would **make the cluster load even worse** — everyone getting 529s retries at once, and the load **amplifies instead of shrinking**. This is the classic "retry storm" of distributed systems.

**How Claude Code handles it**:

- **non-foreground query sources fail immediately** — no retry — to avoid amplifying the load. What counts as non-foreground? Things like the `compact` query source or the `session_memory` query source — these are background tasks the user isn't directly waiting on, so if they fail, they fail; no need to pile more pressure onto the cluster
- **foreground queries do retry** — the user is waiting, so a retry is worth it — but there's still a cap: `MAX_529_RETRIES`. Once consecutive 529s hit that cap, a `FallbackTriggeredError` is thrown

`FallbackTriggeredError` triggers the next step: **fallback model swap** — covered in the next section.

**This design reflects Claude Code's mature handling of production SLAs**: not all requests are equal. A failed background task is fine (it'll come around again); a failed foreground request needs saving — even a smaller model beats leaving the user hanging.

## Fallback Model Swap — Keep the Current Turn, Try a Different Model

When the 529 cap is hit, or some other fatal error occurs, Claude Code doesn't throw straight to the user — it attempts a **fallback**:

```
Primary model is claude-opus-4-6
529 fails 3 times in a row, throws FallbackTriggeredError
   ↓
Claude Code catches it, tries switching to fallback_model (e.g. claude-sonnet-4-6)
   ↓
Uses the same messages array, swaps in the new model, resends
```

The key design decision: **this swap does not count as a new turn** — `turnCount` isn't incremented. Looking at the loop's state machine, the fallback swap lives **inside the inner while**, not the **outer while** (the layer where `turnCount` increments).

**Why preserve the turn**:
- the user pressed Enter once, expecting "one round of Q&A" — an automatic fallback in the middle shouldn't count against the turn budget
- the `maxTurns` safety cap the user configured shouldn't get consumed by a fallback

**A technical detail: stripping signature blocks**

The **thinking signature is incompatible across different models**. The assistant message output by the primary model might contain:

```
{ type: 'thinking', signature: '...', thinking: '...' }
```

That `signature` is **model-specific**. If you resend that history to a different model, the server will reject it (signature mismatch).

**The fix**: before the swap, scan through the messages and **strip out every signature field**. From the user's and the LLM's point of view, the thinking content is still there — only the metadata got stripped.

## Prompt Too Long — Three Tiers of Recovery

The previous article covered handling the `context_window_exceeded` `stop_reason`. But there's another form this error can take: the API returning a `prompt_too_long` error directly — more explicit, more forceful.

Claude Code has **three tiers of recovery** for this:

**Tier 1 · Context Collapse Drain**

Not a simple compact — an **aggressive compression**, forcibly stripping out a large batch of old messages. This is a mechanism currently in feature-flag rollout — see the Context Management series, article 04 (The Six Siblings of Compaction) for details.

**Tier 2 · Reactive Compact**

The standard `/compact` flow, but triggered "reactively" — the API has already errored out before this fires, rather than a proactive threshold trigger.

**Tier 3 · Throw to the User**

If both prior tiers fail, throw `{ reason: 'prompt_too_long' }` up to the SDK layer, and the user sees an explicit error.

**The key design here**: **during this recovery process, the error is hidden from the SDK caller**. The user/SDK never sees "a `prompt_too_long` appeared, then vanished" — only if all three tiers genuinely fail does the error surface.

**This is consistent with the "withhold errors" philosophy covered in [05](05-query-engine.md)** — the loop is a recovery engine, doing everything it can to recover on its own, and only throwing what it truly cannot recover from.

## Max Output Tokens Gets Three Chances

`stop_reason === 'max_tokens'` (output hit the ceiling) has a similarly staged recovery:

- **First `max_tokens`**: bump the `max_tokens` ceiling and resend
- **Second `max_tokens`**: still hits the ceiling even after the bump — inject a `[Output token limit hit, continue]` user message, so the LLM explicitly knows it needs to keep going
- **Third `max_tokens`**: still hitting the ceiling — give up, throw to the user

`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`.

**Same three-tier recovery pattern as `prompt_too_long`.** The loop keeps giving itself more chances.

## The Layers of Error Recovery, Summarized

When an API call errors out, how many layers of recovery does the loop have? From nearest to furthest:

1. **Inside withRetry — network/500/529 etc., exponential-backoff retry** — up to 10 times
2. **Outside withRetry — fallback model swap** — switch models and retry when the primary model can't recover
3. **Within a loop iteration — signature stripping on model switch** — for compatibility across different models' thinking formats
4. **Across loop iterations — `prompt_too_long` three-tier compression recovery** — collapse → compact → throw
5. **Across loop iterations — `max_tokens` three-tier recovery** — escalate → inject continue → throw
6. **Across loop iterations — `reactive_compact` / `stop_hook` / `max_output` each with their own transitions** — see [05](05-query-engine.md)
7. **Main loop — the `maxTurns` hard safety cap** — the final termination when none of the above recoveries work
8. **Main loop — withholding errors up to the SDK layer** — only the truly unrecoverable error gets thrown to the user

**8 layers of recovery, stacked together** — ensuring that after the user presses Enter once, the loop does everything it can to reach a final result on its own, and only pulls the user back in when there's truly no way to save it.

## Summary

- **Every API call is wrapped in withRetry** — up to 10 retries, exponential backoff
- **Whether to retry is decided by the server's `x-should-retry` header** — client-side heuristics only serve as a fallback
- **Backoff timing is decided by the `Retry-After` header** — the server knows best when it'll recover
- **529 overloaded gets special treatment** — non-foreground requests fail immediately, to avoid a "retry storm"
- **Fallback model swap** — switches to a fallback model when the primary can't recover, `turnCount` doesn't increment, signatures get stripped
- **`prompt_too_long` three-tier recovery** — collapse → compact → throw
- **`max_tokens` three-tier recovery** — escalate → inject continue → throw
- **8 layers of recovery stacked together** — keeping the loop as self-healing as possible

The next article, 08 · Interrupt · Handling User Interruption, covers the other side of the loop: errors the loop can't heal from on its own, but that the user can **actively interrupt**. When the user hits Ctrl-C, what happens to an LLM request that's already mid-stream, what happens to a tool that's already executing, and how does the messages array stay structurally valid.

---

## References

**Primary file locations** (v2.1.220):
- `src/services/api/withRetry.ts` — the `withRetry` wrapper, `DEFAULT_MAX_RETRIES`, `shouldRetry`
- `src/services/api/errors.ts` — error classification, `getErrorMessageIfRefusal`
- `src/query.ts` — fallback model swap logic, the `attemptWithFallback` inner while
- `src/query.ts` — `truncateHeadForPTLRetry`, the `prompt_too_long` three-tier recovery
- `src/services/compact/compact.ts` — the reactive-compact trigger point

**Related articles**:
- [04 · From "Answer Complete" to the 7 Meanings of stop_reason](04-stop-reason.md) — the recovery triggered by max_tokens / refusal
- [05 · QueryEngine Main Loop · The Full State Machine](05-query-engine.md) — recovery as a first-class transition
- 08 · Interrupt · Handling User Interruption · next article · manual user intervention when self-healing isn't possible
- [04 · The Six Siblings of Compaction](../context-management/04-compaction.md) — reactive-compact in detail

**Anthropic official docs**:
- [Handling errors](https://platform.claude.com/docs/en/api/errors) — the semantics of the `x-should-retry` / `Retry-After` headers
