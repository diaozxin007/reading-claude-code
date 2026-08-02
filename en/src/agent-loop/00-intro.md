Opening Claude Code · typing "help me look at this bug" · hitting Enter.

The window starts scrolling. It reads auth.py · then login.py · runs a grep · edits one line of code · runs the tests · and finally tells you "Done · the cause was X."

**It looks like you're chatting with someone who remembers the earlier conversation, uses tools, and waits for you to reply.**

But if you go and ask the Anthropic API — **the LLM itself is stateless**. Every time you call it · the server has no idea what you asked before. To make it "remember" the earlier conversation · you must resend **every message** from the very start, in full, every single time.

Hence a middle layer emerges — the **harness**. It remembers the history and packages that history each time it calls the LLM. What you see in the chat window as a "continuous conversation" actually looks like this underneath:

```
Round 1: harness sends [1 message] → LLM returns a reply
Round 2: harness sends [3 messages] → LLM returns a reply
Round 3: harness sends [5 messages] → LLM returns a reply
...
```

The messages array only ever grows — the LLM remembers nothing · the harness remembers everything.

Next question: **how many LLM calls does one user input trigger?**

Take that bug-fix example: it read 2 files, ran a grep, made one Edit, and ran the tests — 5 tool calls. After each tool execution completes, the harness has to stuff the result (tool_result) back into messages · then call the LLM again · so it can decide the next step.

So behind "one user input" sit **5–10 LLM calls** — the user hits Enter → call A (LLM says "I want to read a file") → harness reads the file → call B (LLM says "I want to read another one") → ... until the LLM returns a message with no tool request attached · only then, from the user's point of view, does this round end.

**This is the loop.**

In Anthropic's official documentation, this loop looks like this:

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

- **while True** — the loop, which runs until it explicitly breaks out
- **response = call_llm(messages)** — send the full current messages array to the LLM and get a reply back
- **if response.has_tool_use** — check whether the LLM's reply contains a tool call
- **execute_tools + double append** — if there's a tool call, execute it and append both the LLM reply and the tool result to the array
- **else break** — if there's no tool call, exit the loop · this round ends

**The core action in these 5 lines**: call the LLM · check for tool_use · if present, execute and append · if not, exit.

The key point: **the user only appears at the beginning and end of this loop**. The user hits Enter and the loop starts turning — everything in between, "call the LLM · execute the tool · append the result · call the LLM again," runs entirely on its own, asking nothing of and waiting for nothing from the user. Only when the LLM eventually returns a reply with no tool call attached does the loop stop, the final result is shown to the user, and this round is considered complete.

This is the most fundamental difference between Claude Code and a chatbot — a chatbot waits on a human every round · an agent only waits on a human at the start and the end · everything in between runs entirely on its own. And precisely because the loop keeps turning on its own, a whole series of mechanisms become necessary:

- **interrupt** — if the user wants to stop, they must actively interrupt · otherwise the loop won't stop on its own
- **permission approval** — dangerous operations (like `rm -rf`) must be able to halt the loop · because the loop itself never hesitates
- **maxTurns circuit breaker** — what if the loop ends up running forever
- **hooks** — if the user wants to inject custom logic into the loop, it has to go through a hook · because there's no human in the loop during execution

Without this premise of an "automatically running loop," none of these mechanisms would be necessary.

**But those 5 lines are just the happy path.** A real product has to handle:

- context filling up — what happens when 200K tokens won't fit
- API failures — network drops / rate limits / server overload · deciding what to retry and what not to
- model refusals — safety policy triggers · prompting the user to switch models
- user interruptions — after Ctrl-C, what happens to the tool that was mid-execution · what happens to a half-finished tool_use
- tools crashing — don't throw an exception · convert it into a `tool_result is_error` and let the model see it
- max_tokens being hit — output got truncated · should a "continue" be injected so it keeps going
- output being too long — or falling back to a different model
- multiple tool_use calls — run them in parallel or serially · which ones can run in parallel and which can't
- the user sending another message mid-run — queue it · handle it after this round finishes
- the user adding hooks in `.claude/settings.json` — every hook has to run before and after every tool execution, and on every session start/stop
- a tool running for the first time needing user approval — block the loop · wait for the UI to get a "yes"
- a sub-agent being spawned — it runs through the same loop · but you need to distinguish who's the main thread and who's the subagent

**Every single one of these is complexity the 5 lines of code never covered.**

Claude Code weaves more than a dozen of these situations into its main loop — and so those 5 lines of code become this:

```
while (true) {
    Decide the path based on state.transition.reason:
        - next_turn                    → normal LLM call
        - collapse_drain_retry         → context full · trigger context-collapse
        - reactive_compact_retry       → retry after reactive compact
        - max_output_tokens_escalate   → raise the max_tokens ceiling
        - max_output_tokens_recovery   → inject a continue message and retry
        - stop_hook_blocking           → stop hook blocks termination · force continuation
        - token_budget_continuation    → continue in output-token-budget mode

    Call the LLM · handle streaming

    Capture stop_reason:
        - end_turn                     → check for tool_use · if none, completed
        - tool_use                     → go to runTools
        - max_tokens                   → go to max_output_tokens recovery
        - refusal                      → prompt /model
        - context_window_exceeded      → trigger reactive-compact

    Execute tools:
        - batch by isConcurrencySafe · run in parallel/serially
        - on error for each tool_use → convert to an is_error tool_result · don't throw
        - support StreamingToolExecutor · start the tool while JSON is still streaming in

    Append tool_result to messages

    Check the various termination conditions:
        - AbortController.aborted      → aborted_tools
        - turnCount > maxTurns         → max_turns
        - PostToolUse hook block       → hook_stopped
        - autoCompact threshold hit     → go to compact
        - prompt_too_long error         → withhold + recover

    Continue to the next iteration ...
}
```

Each subsequent chapter expands on one of these pieces.
