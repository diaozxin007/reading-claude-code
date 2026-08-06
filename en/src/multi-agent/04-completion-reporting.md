## What "it's done" actually hands back

The previous piece left a question open: whether you wait or not, however long you wait, you eventually have to face the moment when "it's done." What exactly gets handed back at that moment?

## By default, what comes back is just the last thing it said

When an agent finishes a job, there's no format requirement by default — **the last piece of text it produces is, directly, the deliverable**. The tool description puts this plainly:

> "Subagents are told their final text IS the return value (not a human-facing message), so they return raw data."

There's a detail here that's easy to miss: what comes back isn't "a human-friendly summary" — it's raw data, and the subagent itself has been told as much. So when it composes that final message, it's thinking "this text is the data itself," not "let me write a readable wrap-up for a human." This distinction determines the shape of what you get by default: a piece of prose that may well be substantive, but has no fixed fields and no structure you can read programmatically.

## A report is a statement of intent, not proof of fact

Once you have that text, can you simply trust it? The tool description carries a specific warning:

> "Trust but verify: an agent's summary describes what it intended to do, not necessarily what it did. When an agent writes or edits code, check the actual changes before reporting the work as done."

**"Describes what it intended to do" is not the same as "what it actually did."** This matters especially for work involving writes — if a subagent says "I've replaced all the old interfaces," that doesn't mean every one was actually replaced. You need to go back and check the actual file changes, or run the tests to confirm, rather than declaring the task complete the moment you receive that text.

## Fixed format has to be explicitly requested

Prose is good enough on its own, but if you need to **process the result with code** afterward — say, read a specific field out of it — free-form text is inconvenient to parse. Agent calls inside `Workflow` scripts have an extra option: you can explicitly require the other party to return a result conforming to a fixed structure, rather than an arbitrary block of text. A result that doesn't meet the format is rejected, and the agent has to retry until it produces something that does.

Whether you need this "fixed format" guarantee depends on whether, after getting the result, **a human reads it next** or **code processes it next**. Prose is fine for the former; only the latter is worth the extra step of enforcing a format.

## A specific trap: trying to read the raw output file directly

When a background task finishes, the notification comes with a path pointing to an output file. There's an easy trap here, and the tool description specifically distinguishes a few cases:

- If what ran in the background was a command — reading that output file directly is safe; it's just standard output and standard error.
- But if what ran in the background was an agent — **don't read that output file directly**. It's not a clean result text; it's the complete record of that subagent's entire conversation (a raw, message-by-message log), which can be huge, and reading it in directly can blow up your own context.

**Even though both cases present as "background task done, here's a file path," the correct way to consume it is completely different for an agent versus an ordinary command** — a command's output file is the result itself, while an agent's output file is a record of the process. The actual result needs to come through the agent's own reporting mechanism (the tool call's return value, or the summary carried by the notification itself), not by "opening that file and taking a look."

## Back to why the shared task board doesn't hold results

The opening piece left a thread hanging: task management and result management are two separate things. Now it's clearer why — the shared task board (the `Task` family) is responsible for the layer of state that answers "who's working on what, and how far along." None of its fields are meant to hold "what got produced." The actual result, whether prose or fixed format, is always sent back through **the reporting mechanism of the agent that did the work** — a completely separate line from the status marker on the Task board. One line tells you "is it done or not"; the other tells you "what did it actually produce."

## The interface this piece leaves open

At this point, the four questions that need answering for dispatching a single agent — context, permissions, foreground/background, and reporting — all have concrete answers. But one question remains, and it only surfaces when **there's a whole batch of work to divide up at once**: who decides the order and ownership of that work? That's the question for the next piece.

## References

- Primary sources this piece is built on: the schema option description for `agent()` in the `Workflow` tool, and the warning notes on local_agent output in `TaskOutput` (directly readable within the toolset — verified word for word)
- No source-level discovery has been done yet on the concrete storage structure of `.output` files or the retry mechanics after a schema validation failure — left for a future piece if discovery turns up more
- Callback: [Opening · From One Agent to a Team](00-intro.md) (the separation of task management from result management lands concretely here)
