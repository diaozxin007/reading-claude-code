Open Claude Code · type "help me look at this bug" · hit Enter.

The window starts scrolling. It reads `auth.py` · then reads `login.py` · runs a `grep` · changes one line of code · runs the tests · and finally tells you "done — the cause was X."

**It looks like you're chatting with someone who remembers the earlier conversation, uses tools, and waits for you to reply.**

But if you go ask the Anthropic API — **the LLM itself is stateless**. Every time you call it, the server has no idea what you asked last time. To make it "remember" the earlier conversation, you have to resend **every message** from the very start, in full, every single time.

So a middle layer emerges — the **harness**. It remembers the history, and packages that history up every time it calls the LLM. The "continuous conversation" you see in the chat window is, underneath, this:

```
Turn 1: harness sends [1 message] → LLM returns a reply
Turn 2: harness sends [3 messages] → LLM returns a reply
Turn 3: harness sends [5 messages] → LLM returns a reply
...
```

The messages array only ever grows — the LLM remembers nothing, the harness remembers everything.

Next question: **one user input = how many LLM calls?**

Take that bug fix just now: read 2 files, ran a grep, made 1 Edit, ran the tests — 5 tool calls. Every time a tool finishes running, the harness has to stuff the result (tool_result) back into messages, then call the LLM again to let it decide what's next.

So behind "one user input" sit **5-10 LLM calls** — the user hits Enter → call A (LLM says "I want to read a file") → harness reads the file → call B (LLM says "I want to read another one") → ... until the LLM returns a message with no tool request, and only then, from the user's point of view, does this turn end.

**This is the loop.**

In Anthropic's official docs, this loop looks like this:

```python
while True:
    response = call_llm(messages)
    if response.has_tool_use:
        results = execute_tools(response.tool_use)
        messages.append(response)
        messages.append(results)
    else:
        break
```

Translated:

- **while True** — loop, unless it actively breaks out
- **response = call_llm(messages)** — send the current messages array in full to the LLM, get a reply back
- **if response.has_tool_use** — check whether the LLM's reply contains a tool call
- **execute_tools + double append** — if there's a tool call, run it, and append both the LLM's reply and the tool result to the array
- **else break** — if there's no tool call, exit the loop, this turn is over

**The core action of these 5 lines**: call the LLM · check for tool_use · if there is one, execute and append · if not, exit.

One key point: **the user only shows up at the beginning and the end of this loop.** The user hits Enter and the loop starts turning — everything in between, "call the LLM · execute the tool · append the result · call the LLM again," is entirely the program running on its own, never asking the user, never waiting on the user. Not until the LLM returns a reply with no tool call does the loop stop, the final result gets shown to the user, and only then is this turn considered over.

This is the most fundamental difference between Claude Code and a chatbot — a chatbot waits on a human every single turn, an agent only waits on a human at the beginning and the end, and turns entirely on its own in between. And precisely because the loop keeps turning on its own, a whole set of mechanisms had to follow:

- **interrupt** — if the user wants to stop, they have to interrupt; otherwise the loop won't stop
- **permission approval** — dangerous operations (like `rm -rf`) have to be interceptable, because the loop itself never hesitates
- **maxTurns circuit breaker** — what if the loop ends up running forever
- **hooks** — if the user wants to inject custom logic into the loop, it has to go through a hook, because there's no human in the loop during execution

Without this premise of an "automatic loop," none of these mechanisms would be necessary.

**But those 5 lines are only the happy path.** A real product also has to handle:

- context filling up — what happens when 200K isn't enough
- the API failing — network down / rate limit / server overload — which to retry and which not to
- the model refusing — safety policy triggered, prompt the user to switch models
- the user interrupting — after Ctrl-C, what happens to the tool that was mid-run, what happens to a half-finished tool_use
- tools crashing — don't throw an exception, turn it into a `tool_result is_error` and let the model see it
- max_tokens being hit — output got truncated, should a "continue" be injected to let it keep going
- output being too long — or falling back to a different model
- multiple tool_use calls — run them in parallel or in sequence, which ones can run in parallel and which can't
- the user sending another message mid-turn — queue it, handle it once this turn finishes
- the user adding hooks in `.claude/settings.json` — every tool execution, every session start/stop, all of it has to pass through hooks
- a tool's first run needing user approval — block the loop, wait for the UI to get a "yes"
- a sub-agent being spawned — it runs through the same loop, but you need to distinguish who's the main thread and who's the sub-agent

**Every single one of these is complexity those 5 lines never covered.**

Claude Code weaves all these dozen-plus cases into the main loop — so those 5 lines turn into this:

```
while (true) {
    Decide the path based on state.transition.reason:
        - next_turn                    → normal LLM call
        - collapse_drain_retry         → context full · trigger context-collapse
        - reactive_compact_retry       → retry after passive compact
        - max_output_tokens_escalate   → raise the max_tokens ceiling
        - max_output_tokens_recovery   → inject a continue message and retry
        - stop_hook_blocking           → stop hook blocks termination · force continuation
        - token_budget_continuation    → continue in output token budget mode

    Call the LLM · handle streaming

    Capture stop_reason:
        - end_turn                     → check for tool_use · if none, completed
        - tool_use                     → go to runTools
        - max_tokens                   → go to max_output_tokens recovery
        - refusal                      → prompt /model
        - context_window_exceeded      → trigger reactive-compact

    Execute tools:
        - batch by isConcurrencySafe · parallel/sequential
        - each tool_use error → convert to is_error tool_result · don't throw
        - support StreamingToolExecutor · start the tool while still streaming-parsing the JSON

    Append tool_result to messages

    Check the various termination conditions:
        - AbortController.aborted      → aborted_tools
        - turnCount > maxTurns         → max_turns
        - PostToolUse hook block       → hook_stopped
        - autoCompact threshold hit    → go to compact
        - prompt_too_long error        → withhold + recover

    Continue to the next iteration ...
}
```

Every article that follows expands on one piece of this.
