The previous chapters explained how the loop **recovers on its own whenever it can** when it encounters errors—retrying with a higher `max_tokens`, triggering compact when the context fills up, and suggesting a model switch when `stop_reason` is refusal. But these are all **semantic-level** errors (the LLM result is not right).

Real-world products also face an entire class of **infrastructure-level** errors:

- The network is down—the request never goes out
- The API returns 500—internal server error
- The API returns 429—the rate limit has been exceeded
- The API returns 529—overloaded; the Anthropic cluster is under heavy load
- The API returns an error saying `"prompt_too_long"`—the combined messages are too long

This chapter explains how these errors are handled: retries, backoff, model fallback, and compact recovery. The central question is: **What should the loop do when it encounters an infrastructure error? When should it retry, give up, switch models, or compress the context?**

## Every API Call Is Wrapped in withRetry

Claude Code never makes a **bare** LLM call. Every call goes through a `withRetry` wrapper. A single logical `"call_llm"` may involve 1–10 actual HTTP requests behind the scenes.

The core behavior of `withRetry`:

- **DEFAULT_MAX_RETRIES = 10**—retry up to 10 times by default
- This can be overridden with the `CLAUDE_CODE_MAX_RETRIES` environment variable
- When a failure occurs, determine whether it **can be retried** (see the next section)
- If it can, sleep according to the backoff policy and resend; if it cannot, throw directly to the loop

From the loop's perspective, a call either succeeds or fails—all intermediate retries are hidden inside `withRetry`. The loop sees only the final result.

## Deciding Whether to Retry—the Server Has the Final Say

The naive approach is for the client to **decide for itself** which errors are retryable—500 is retryable, 429 is retryable, 400 is not.

**Claude Code's choice** is to **ask the server first**.

The Anthropic API includes a header in error responses:

```
x-should-retry: true
```

or:

```
x-should-retry: false
```

**If the server says to retry, retry; if it says not to, do not retry**—regardless of the status code.

**Why trust the server**:

- Client-side heuristics (such as "retry every 5xx") are wrong in some edge cases—for example, some 500 errors are caused by the user's request itself, so retrying is pointless
- The server knows the internal state of the cluster—an error may look like a rate-limit issue but actually mean "the model for this request is unavailable," in which case retrying serves no purpose
- The server can **dynamically adjust** retry semantics—deployment changes do not require a corresponding client release

**Only when the header is absent does the client fall back to heuristics**—checking the status code, error type, or strings in the error body. For example, if the body contains `"type":"overloaded_error"`, the error is considered retryable.

**This design pattern is extremely common in production systems**—let the **server drive the decision**, with the client providing only a fallback. The benefit is **decoupled evolution**: the server can adjust its logic at any time without requiring a new client release.

## Backoff Policy—Prefer Retry-After, Fall Back to Exponential Backoff

Once an error has been deemed retryable, **how long should the client wait before retrying**?

Claude Code again gives priority to the **server's guidance**:

- If the response includes `Retry-After: 30` (seconds), sleep for 30 seconds
- If the response includes `Retry-After: <HTTP date>`, sleep until that time
- If neither is present, fall back to **exponential backoff**—1s, 2s, 4s, 8s, 16s, 32s...

**Why prefer a server-specified delay**:

- The server knows exactly when the rate limit resets
- Client-side exponential backoff is **blind**—you may wait 32 seconds even though the server recovers after 5, wasting time
- Or the reverse: your 8-second backoff may expire before the server has recovered, causing the retry to fail again

**Server-specified backoff** eliminates this guesswork and makes retries as efficient as possible.

One special mode is **persistent retry**—when a rate limit is encountered, use the rate-limit window's reset time directly instead of exponential backoff. For example, if the limit is "100 requests per minute" and it has been exhausted, sleep until the next minute. This produces the most precise retry cadence.

## Special Handling for 529 Overloaded

Anthropic's 529 status code has a specific meaning: **"Our cluster is under heavy load, and no resources are currently available to process your request."**

This differs from 429 (rate limit)—429 means "you are sending requests too quickly," while 529 means "our servers are busy."

Blindly retrying a 529 can **increase cluster load**—everyone receives 529 responses, everyone retries, and the load is **amplified instead of reduced**. This is the classic "retry storm" in distributed systems.

**Claude Code's handling**:

- **Non-foreground query sources fail immediately**—no retries, preventing further load amplification. What counts as non-foreground? For example, `compact` and `session_memory` query sources. These are background tasks that the user is not directly waiting for; if they fail, they fail and can run again later—there is no reason to worsen cluster load
- **Only foreground queries are retried**—the user is waiting, so a retry is necessary—but there is still a limit: `MAX_529_RETRIES`. Once consecutive 529 responses reach that limit, Claude Code throws `FallbackTriggeredError`

The next step triggered by `FallbackTriggeredError` is a **fallback model swap**, covered in the next section.

**This design reflects Claude Code's mature approach to production SLAs**: not all requests are equal. A background task can fail and try again later; a foreground request from the user should be rescued—even using a smaller model is better than leaving the user waiting.

## Fallback Model Swap—Retry the Current Turn with Another Model

After reaching the 529 limit or encountering another fatal error, Claude Code does not immediately surface the error to the user. Instead, it attempts a **fallback**:

```
The primary model is claude-opus-4-6
529 fails three consecutive times · throw FallbackTriggeredError
   ↓
Claude Code catches it · attempts to switch to fallback_model (for example, claude-sonnet-4-6)
   ↓
Resend with the same messages array · using the new model
```

The key design decision: **this swap does not count as a new turn**—`turnCount` is not incremented. From the loop's state-machine perspective, the fallback swap occurs inside the **inner while**, not the **outer while** (the layer that increments `turnCount`).

**Why preserve the turn**:

- The user presses Enter once and expects "one question-and-answer exchange"; an automatic fallback in the middle should not consume a turn
- The user's configured maxTurns safeguard should not be consumed by fallback attempts

**Technical detail: stripping signature blocks**

**Thinking signatures are incompatible across models**. An assistant message produced by the primary model may contain:

```
{ type: 'thinking', signature: '...', thinking: '...' }
```

This `signature` is **model-specific**. If that history is sent to another model, the server rejects it because the signature does not match.

**The solution**: before the swap, scan the messages and **remove every signature field**. From the user's and LLM's perspective, the thinking content remains; only the metadata is stripped.

## Prompt Too Long—Three Levels of Recovery

The previous chapter covered handling the `context_window_exceeded` stop_reason. But the same problem can also appear as a direct `prompt_too_long` API error—a clearer and more forceful signal.

Claude Code has **three levels of recovery** for this error:

**Level 1 · Context collapse drain**

This is not ordinary compact; it is **aggressive compression** that forcibly removes a large batch of older messages. This mechanism is being rolled out behind a feature flag; see Context Chapter 04 (The Six Compaction Variants) for details.

**Level 2 · Reactive compact**

The standard `/compact` flow, but triggered "reactively"—only after the API has already returned an error, rather than proactively at a threshold.

**Level 3 · Surface the error to the user**

If both previous levels fail, throw `{ reason: 'prompt_too_long' }` to the SDK layer so the user sees an explicit error.

The **key design decision** is that **the error remains hidden from SDK callers during these recovery attempts**. The user or SDK never sees "`prompt_too_long` appeared and then disappeared"—the error becomes visible only if all three levels truly fail.

**This is consistent with the "error withholding" philosophy described in [05](05-query-engine.md)**—the loop is a recovery engine. It recovers on its own whenever possible and surfaces only errors it cannot recover from.

## Three Chances for Max Output Tokens

`stop_reason === 'max_tokens'` (the output reaches its limit) has a similar multi-stage recovery process:

- **First max_tokens**: raise the `max_tokens` limit and resend
- **Second max_tokens**: if the output still reaches the limit after the increase, inject a `[Output token limit hit, continue]` user message so the LLM explicitly knows to continue
- **Third max_tokens**: if the limit is reached again, give up and surface the error to the user

`MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`.

**Like prompt_too_long, this uses three levels of recovery**. The loop keeps giving itself another chance.

## Summary of Error-Recovery Layers

When an API call fails, how many layers of recovery does the loop have? From nearest to farthest:

1. **Inside withRetry · network/500/529 and similar errors · retry with exponential backoff**—up to 10 times
2. **Outside withRetry · fallback model swap**—switch models and retry when the primary model cannot recover
3. **Within a loop iteration · strip signatures when switching models**—maintain compatibility across models' thinking formats
4. **Between loop iterations · three-level prompt_too_long compression recovery**—collapse → compact → throw
5. **Between loop iterations · three-level max_tokens recovery**—escalate → inject continue → throw
6. **Between loop iterations · transitions for reactive_compact / stop_hook / max_output**—see [05](05-query-engine.md)
7. **Main loop · hard maxTurns safeguard**—the final termination mechanism when every preceding recovery layer fails
8. **Main loop · withhold errors from the SDK layer**—surface only errors that ultimately cannot be recovered from

**These eight recovery layers work together** to ensure that, after the user presses Enter once, the loop proceeds toward a final result on its own whenever possible and asks the user to intervene again only when recovery is impossible.

## Conclusion

- **Every API call is wrapped in withRetry**—up to 10 retries with exponential backoff
- **Whether to retry is determined by the server's `x-should-retry` header**—client heuristics are only a fallback
- **Backoff duration follows the `Retry-After` header**—the server knows best when it will recover
- **529 overloaded receives special handling**—non-foreground requests fail immediately to avoid a "retry storm"
- **Fallback model swap**—when the primary model cannot recover, switch to the fallback; do not increment turnCount; strip signatures
- **Three-level prompt_too_long recovery**—collapse → compact → throw
- **Three-level max_tokens recovery**—escalate → inject continue → throw
- **Eight stacked recovery layers**—ensuring the loop heals itself whenever possible

The next chapter, 08 · Interrupt · Handling User Interruptions, covers the other side of the loop—some errors cannot be healed by the loop itself, but the user can **actively interrupt** it. After the user presses Ctrl-C, what happens to an LLM request already streaming a response, what happens to a tool currently executing, and how does the messages array remain structurally valid?

---

## References

**Primary file locations** (v2.1.220):

- `src/services/api/withRetry.ts` · `withRetry` wrapper · `DEFAULT_MAX_RETRIES` · `shouldRetry`
- `src/services/api/errors.ts` · error classification · `getErrorMessageIfRefusal`
- `src/query.ts` · fallback model swap logic · `attemptWithFallback` inner while
- `src/query.ts` · `truncateHeadForPTLRetry` · three-level prompt_too_long recovery
- `src/services/compact/compact.ts` · reactive-compact trigger point

**Related chapters**:

- [04 · From Completion to the Seven Meanings of stop_reason](04-stop-reason.md) · recovery triggered by max_tokens / refusal
- [05 · QueryEngine Main Loop · Complete State-Machine Overview](05-query-engine.md) · recovery as a first-class transition
- 08 · Interrupt · Handling User Interruptions · next chapter · manual user intervention when self-healing is impossible
- [04 · The Six Compaction Variants](https://readingclaude.club/zh/context-management/04-compaction) · reactive-compact in detail

**Official Anthropic documentation**:

- [Handling errors](https://platform.claude.com/docs/en/api/errors) · semantics of the `x-should-retry` / `Retry-After` headers
