## When One Agent Isn't Enough

Picture a concrete request: "Review this change, check for performance issues while you're at it, and verify the docs were updated to match."

A single agent can get all of this done—read the diff, analyze performance, check the docs, working through each step serially. But there's something uncomfortable about this: these three tasks are **independent of one another**, none depends on the others' conclusions, yet they're forced into a queue, each waiting on the one before it.

A natural thought follows: could several agents work at once, each handling its own piece without interfering with the others, and then merge the results at the end?

The [Loop series](../agent-loop/00-intro.md) already covered this: the core of a single agent is a loop that keeps "sending the full history → receiving a response → deciding whether to continue." This loop has no built-in notion of "spawning a copy"—it only knows its own message array, and works through it step by step. To hand work off to another agent, you have to reach out of this closed loop toward another one.

## Dispatching an Agent Means Answering Four Questions

Regardless of which tool is used to "reach toward another loop," once the decision is made to hand off work, four questions are unavoidable:

- **Where does the context come from**: does the recipient start from scratch, or can it see what we've discussed before? Is everything handed over as-is, or is it trimmed first?
- **What tools can it use**: what capabilities does the recipient have? The same full toolkit as the dispatcher, or restricted to read-only, no editing?
- **How does it run**: does the dispatcher stand by and wait for it to finish, or does it run in the background while the dispatcher moves on to other work?
- **How does completion get reported**: how does it signal "I'm done"—a free-form message, or a result in a fixed structure?

This isn't an arbitrary checklist—these four questions map onto four design choices that can be verified word-for-word in the toolset. Let's go through them one at a time.

### Context: A Fresh Start, or Picking Up Where It Left Off

The `Agent` tool's description is blunt about this: the dispatched agent **"hasn't seen this conversation, doesn't know what you've tried"**—zero inheritance. Its only source of information is the task description given this time, so that description has to be self-contained, spelling out what to do, why, and which approaches have already been ruled out. It can't be expected to guess.

But the same tool description leaves a back door open: if an agent has already been dispatched and you want to keep talking to it, you can use `SendMessage` and name it—what gets continued this time isn't "my" context, but **its own** accumulated history. In other words, "where does the context come from" isn't an either/or between two separate mechanisms—it's two answers to the same question: start fresh each time (zero inheritance), or find the same agent again and continue from its own history (continuation).

### Tool Permissions: Who Can Do What

The `Agent` tool has a `subagent_type` field that determines what tools the dispatched agent has access to. This isn't free-form text—it's chosen from a runtime enum: some types get the full toolset, others have write access stripped out (a read-only search type, for instance, explicitly denied Edit / Write), with the permission boundary following the type.

Agents spawned from `Workflow` scripts draw on the same registry—you can specify the same types as the `Agent` tool, and additionally pull in MCP tools already connected to the session as needed, rather than dumping all of them in at once.

### Foreground or Background: To Wait or Not to Wait

The `Agent` tool has a `run_in_background` field that **defaults to true**—dispatched work runs in the background by default and notifies automatically when done, with no need to wait in place. The tool description explicitly warns "do NOT sleep, poll, or proactively check on its progress"—if the design defaults to background, it shouldn't be treated as synchronous after the fact. Only switch it to foreground manually when the result is genuinely needed before proceeding.

`Workflow` takes this further—the script invocation itself is **always** run in the background, no matter how many agents are running concurrently inside it, none of it blocks the current conversation.

### Reporting: A Free-form Message, or a Fixed Structure

By default, when an agent finishes a task, what comes back is **the last thing it said**—no enforced format. This is fine when the task itself is fairly open-ended (say, "look into this piece of code"), but if the result needs to be processed programmatically afterward (say, reading a specific field out of it), free-form text is inconvenient.

Agent calls inside `Workflow` add an extra option: you can require the response to conform to a fixed structure, rather than an arbitrary message. Whether this "fixed structure" guarantee is needed depends on whether a human reads the result afterward, or code processes it.

## These Four Questions Are Four Dimensions of the Same Thing, Not Four Mutually Exclusive Choices

Looking back, these four questions are independent of each other—**context** (fresh start / continuation), **permissions** (which tool type), **foreground/background** (wait / don't wait), **reporting** (free text / fixed structure). A specific act of "dispatching an agent" is a matter of picking one point on each of these four axes, not choosing from a menu of "preset packages."

This is also why "delegating a one-off task" and "keeping a persistent collaborator around" look like two different modes of collaboration, but turn out on closer inspection to just be two different values on the **context** axis—the other three axes are chosen independently of that one.

## At Larger Scale, a New Question Emerges: Who Does Which Piece

Everything above concerns what needs to be decided when dispatching **a single** agent. But if what's being dispatched at once is a **batch** of mutually independent tasks—say, checking ten files individually—a new question emerges, and it only makes sense once more than one agent is working at the same time: **who decides the division of labor?**

There are two fundamentally different answers here:

- A **shared task board**—all the work is laid out, and whoever has capacity claims a piece; the order isn't fixed in advance. This path is already covered in detail in [the Task family](../state/task-family.md), which explains how `owner` claiming and `blockedBy` dependencies work—no need to repeat it here; go read that piece for details.
- A **hardcoded script**—the code specifies in advance "how many phases this batch of work is divided into, which phase waits on which," with no runtime claiming involved; the division of labor doesn't shift depending on who happens to move fastest. This is unique to `Workflow`, and this series will cover it in depth.

## Where This Series Is Headed

The first four questions each get their own installment. The fifth question—"who divides the work"—mainly unpacks the `Workflow` half of things, and the series wraps up with two cross-cutting synthesis questions:

- **01** Context—how `Agent`'s zero inheritance and `SendMessage`'s continuation actually guarantee that "the one found again is the same one"
- **02** Tool permissions—how the `subagent_type` runtime enum works, and how `Workflow`'s on-demand MCP tool access relates to this registry
- **03** Foreground/background—the default reversal of `run_in_background`, and how the concurrency ceiling inside `Workflow` is set
- **04** Reporting—free text vs. fixed-structure results, and exactly what steps "this task is done" notifications go through; **task management and result management are two separate systems**—the `Task` family only tracks "who's working, how far along" as state, with no "output" field; what `TaskList`/`TaskGet` pull back is always just status. The actual deliverable (the result) travels through a separate channel entirely (file changes themselves, or the sub-agent's own reporting mechanism). These two systems each manage their own layer, unaware of each other—this piece unpacks that
- **05** Who divides the work—how deterministic orchestration is written inside `Workflow` scripts, and what's traded away for that determinism compared to a shared task board (a brief comparison with the Task family, with details linked back to that piece)
- **06** The boundary between isolation and sharing—when several agents run at once, are their contexts fully separate? Is anything shared (for instance, is token consumption tallied as one total, or counted separately per agent)?
- **07** Wrap-up—answering a more fundamental question: when is multi-agent actually needed, and when does it just make something more complicated than it needs to be?

## References

- Primary source this piece draws on: the schema descriptions for the `Agent` / `SendMessage` / `Workflow` tools (directly readable within the toolset, verified word-for-word)
- No source-level discovery has been done yet—mechanisms concerning "how this is implemented internally" are left to their respective installments; discovery material will be added there if it surfaces
- Existing material this series does not repeat: [Agent](../power/agent.md) (worktree isolation, fork-depth limits, the two red lines of "never outsource understanding" / "trust but verify") · [The Task family](../state/task-family.md) (owner claiming, blockedBy dependencies, multi-Claude collaboration)
- Companion series: [09 · Sidechain · From Sub-agents to agentId Routing](../agent-loop/09-sidechain.md) (single-agent perspective on sub-agent launching and message routing) · [06 · Sub-agent Isolation · From Independent Context to the .output Trap](../context-management/06-sub-agent.md) (single-agent perspective on context isolation)
