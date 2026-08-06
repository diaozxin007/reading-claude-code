# Preface · From "Help Me Fix a Bug" to a Production-Grade Agent

Open Claude Code and type a single line:

> Help me look at this bug.

What happens next looks perfectly natural: Claude searches the codebase, reads files, modifies the implementation, runs tests. When something fails, it adjusts its approach; when context is about to fill up, it compresses history; the next time you open the project, it may still remember rules you left behind.

But the moment you pull this process apart, the questions multiply fast:

- How does the model know which tools it has access to?
- The user types once — how does the agent keep working across many turns?
- What exactly goes into the 200K context window on every single call to the model?
- Once a conversation ends, what information survives into the next session?
- How does a piece of reusable operational knowledge enter the current task only when it's actually needed?
- How does an action the model was never shipped with become a new Tool, without touching Claude Code's core code?
- When one piece of work splits into several independent jobs, how do you hand them out to multiple agents at once without them stepping on each other?

These seven questions map directly onto the seven parts of this book: **Tools, Agent Loop, Context, Memory, Skills, Multi-Agent Collaboration, and MCP.**

## Claude Code Is Not Just a Set of Tools

The natural starting point for studying Claude Code is its tools — Read, Edit, Bash, and the rest. They're the most visible part of the system, and a good entry point.

Read the Tool descriptions closely, and you'll find them packed with constraints that look overly verbose at first glance:

- Edit requires the file to be read before it can be modified.
- Read prefixes every line with a fixed line-number format.
- Bash carries extensive security warnings around Git operations.
- WebFetch reminds the model to check for a dedicated capability first.

None of these constraints are decoration. Every field, every sentence of the prompt, every runtime interception exists to fix some specific mistake the model used to make.

> **The shape of a tool is itself a piece of working methodology.**

But dig deeper into Tools, and it becomes clear they only answer "what can the agent do" — they can't explain the whole system.

- Without a Loop, a tool can only be invoked once; it can't turn into an autonomous task.
- Without Context management, history keeps growing unbounded, and the model has no way to know what it should be looking at right now.
- Without Memory, once a session ends, important information has no way to survive across time.
- Without Skills, the same operational knowledge has to be re-explained every single time — it never accumulates into a reusable capability.
- Without multi-agent collaboration, only one agent can move a task forward at a time; even independent subtasks have to queue up one after another.
- Without MCP, Claude can only use the tools it shipped with, and is powerless against any action that simply doesn't exist for the model out of the box.

So this book ultimately organizes into seven interconnected threads of investigation:

```text
Tools                       —— what capabilities the agent has
Loop                        —— how those capabilities keep running
Context                     —— what the model sees on each run
Memory                      —— what survives once time crosses a session boundary
Skill                       —— how reusable operational knowledge unfolds on demand
Multi-Agent Collaboration   —— how one piece of work splits across several agents at once
MCP                         —— how the model gets a brand-new action it wasn't shipped with
```

Only together do these seven parts form the complete shape of a production-grade agent.

## Part One · Tools · How Capabilities Are Handed to the Model

Part One starts with the Tool protocol and works through Claude Code's core tools one by one.

The focus here isn't just "what parameters does this tool take" — it's a four-layer contract:

1. How the **Schema** describes a capability to the model.
2. How the **Prompt** guides the model toward using it correctly.
3. How the **Runtime** enforces constraints that can't be guaranteed by the model's self-discipline alone.
4. How the **Tool Result** gets fed back to the model, shaping its next decision.

This part answers: **how do you design a tool the model will actually use well, and not easily misuse.**

## Part Two · Agent Loop · How a Single Input Becomes Continuous Execution

An ordinary chat model answers once and stops. An agent keeps calling the model and its tools continuously after a single user input.

Part Two starts from a five-line loop pseudocode and expands outward to cover:

- Tool declaration and permission approval
- Hooks and parallel scheduling
- `stop_reason` and state transitions
- Streaming and character-by-character display
- Retries, recovery, and interruption
- How the main agent and sub-agents share the same loop

This part answers: **how "an AI autonomously driving a task forward" actually happens, mechanically.**

## Part Three · Context · What Actually Gets Sent on Every Call

An LLM itself has no session state. The fact that "Claude remembers what was just said" is really the client resending the relevant information on the next call.

That raises a fresh set of questions:

- How do tools, the system prompt, and the messages array together consume the context window?
- Why does the messages array have a structure that must not be broken?
- Why does Prompt Cache end up reshaping the entire system?
- Why does CLAUDE.md live in messages instead of a fixed system prompt?
- Once history grows too long, how does Compaction compress it without breaking the task?

This part answers: **within a fixed context budget, how do you keep loading the model with the right information.**

## Part Four · Memory · What Information Survives Across Sessions

Context solves the current call; Memory solves the span of time.

Part Four follows the full lifecycle of information:

- Who writes the information down?
- Does it go into CLAUDE.md, MEMORY.md, or the Memory Tool?
- Does it belong to an individual, a project, a team, or a specific sub-agent?
- When does the next session reload it?
- After Compaction, which memories come back automatically?

This part answers: **once a conversation ends, how does information keep surviving, and how does it re-enter context in the future.**

## Part Five · Skills · How a Body of Operational Knowledge Becomes a Callable Capability

The first four parts describe how an agent that's already equipped with tools operates. But the tools themselves don't multiply on their own — a body of operational knowledge worth reusing (what to check first, what to do next, when to stop) can, by default, only be conveyed by the user retelling it every single time.

Part Five starts from this concrete friction and expands outward to cover:

- Progressive disclosure: the description stays permanently on the candidate list, while instructions only unfold once selected
- Discovery and invocation: whether Claude judges relevance on its own, or the user calls it out directly with `/skill-name`
- Execution boundaries: whether instructions run in the current conversation or get dispatched to an independent subagent
- Permission governance: whether a Skill can be trusted to touch Bash or touch production
- Distribution: from a personal folder to a team-shared Plugin

This part answers: **how does a body of operational knowledge stay around long-term, yet only enter the current task's context when it's genuinely needed.**

## Part Six · Multi-Agent Collaboration · How One Piece of Work Gets Split Across Several Agents at Once

The first five parts all describe how a **single** agent operates — the Loop is its execution cycle, Context is what it sees on each call, Memory is what it leaves behind across sessions, Skill is the capability it unfolds on demand. But real tasks often split into several genuinely independent pieces of work, and a single agent can only line them up in one queue: the next piece has to wait until the previous one is done.

Part Six starts from this boundary and expands outward to cover:

- How context gets handed to a dispatched agent: starting from scratch, or continuing an existing history
- How permissions are set: which tools a dispatched agent can use, and whether that's a pre-registered package
- Foreground or background: whether to wait in place for it to finish, and why the default runs opposite to ordinary commands
- What counts as "done": is a plain message enough, or must the result follow a fixed format
- Who decides the division of labor for a batch of independent jobs: a shared task board contested at runtime, or a script written in advance
- The boundary between isolation and sharing: file changes can be isolated as needed, but token spend is always drawn from one shared account

This part answers: **how do you split work that one agent can't finish across several agents, without collaboration itself becoming a new source of trouble.**

## Part Seven · MCP · How the Model Gets a New Action

Skills solve "how existing tools get combined and used"; but if the model has no action at all that can connect to Jira, or to an internal company service, no amount of good instructions has anywhere to land.

Part Seven starts from this boundary and expands outward to cover:

- Connection lifecycle: where an MCP server's configuration lives, and how the handshake completes
- Transport: local subprocesses and remote services are two different ways of connecting
- Tool exposure: how an external action gets renamed and wrapped into just another entry in the Tool list
- Permissions: how server-level authorization syntax differs from Tool-level permission rules
- Authentication: how OAuth and enterprise single sign-on make "staying connected" repeatable
- The reverse role: Claude Code itself can also act as an MCP server

This part answers: **without touching Claude Code's core code, how does the model gain a brand-new capability it wasn't shipped with.**

## How the Seven Parts Relate to Each Other

These seven parts aren't seven independent bodies of knowledge.

A complete cycle of agent behavior typically looks like this:

```text
Memory supplies information that survived across sessions
              ↓
Context loads the information needed for the current request
              ↓
Loop drives the model to keep judging and acting
              ↓
Tools read, modify, and query the outside world
              ↓
Tool Result returns to Context, and the Loop continues to the next round
              ↓
Information worth keeping long-term settles back into Memory
```

Skills and MCP aren't outside this operating chain — they act on the topmost layer, Tools. A Skill packages reusable operational knowledge into a candidate capability; MCP turns an action the model wasn't shipped with into a new Tool. Once either takes effect, it ultimately feeds into the Tools stage of the diagram above, and runs through the same Loop, Context, and Memory.

Multi-agent collaboration sits somewhere different — it's not adding a new capability at the Tools layer, it's running **this entire diagram several times at once**. A single agent is one pass through this chain; multi-agent collaboration answers the question of what happens when several passes exist simultaneously: does each one's Context start from scratch, are permissions independent of one another, do they need to wait on each other, how do results get merged, which resources are kept separate, and which ones actually draw from the same account.

It can also be compressed into seven lines:

> Tools talk about capability.
>
> Loop talks about execution.
>
> Context talks about information.
>
> Memory talks about time.
>
> Skill talks about how to do it.
>
> Multi-agent collaboration talks about splitting the work across several agents.
>
> MCP talks about what becomes possible.

## The Research Method Behind This Book

This book doesn't walk through the source tree explaining classes and functions one by one. Instead, it follows a relatively stable line of reasoning:

1. **Start from observable phenomena** — what does the user actually see on screen?
2. **Find the underlying constraints** — what does the API, the model, or the runtime environment not allow?
3. **Reconstruct the mechanism** — how does Claude Code organize the system under these constraints?
4. **Analyze the trade-offs** — why this design, rather than the more intuitive alternative?

The Tools section additionally uses a six-part breakdown — purpose, a concrete example, trigger conditions, technical implementation, prompt/schema, and summary. Loop, Context, Memory, Skills, and MCP each unfold around their own main thread.

The goal isn't to memorize implementation details, but to understand:

> **Given the same constraints, why a mature agent system ends up looking the way it does.**

## The Boundary Between Fact and Version

This book draws on three kinds of material:

- Anthropic's official documentation and publicly available Tool descriptions
- Research into the Claude Code v2.1.220 source code
- Actual runtime behavior and reproducible verification

To keep fact and inference distinct, the text follows a few disciplines:

- Direct quotations are kept in the original English wherever possible, with sources cited.
- Source-level conclusions are pinned down to file locations at the end of the text.
- Explanations that can't be directly proven are explicitly marked as inference or design interpretation.
- Claude Code keeps evolving; version-specific conclusions should be read alongside the research version noted in the text.

## What This Book Is Not

- **Not a Claude Code user manual** — installation, keyboard shortcuts, and everyday commands aren't the main thread.
- **Not a general prompt-engineering tutorial** — prompts only appear when explaining a specific mechanism.
- **Not a line-by-line source code commentary** — the focus is on constraints, architecture, and design trade-offs.
- **Not the one correct agent architecture** — Claude Code is one mature example, not a template every system has to copy.

## How to Read This Book

### Building a Systematic Understanding of Agents for the First Time

Read from the beginning, in order: Tools → Loop → Context → Memory → Skills → Multi-Agent Collaboration → MCP. The first four parts widen in time scale progressively, and earlier concepts become the foundation for later ones. Skills and MCP loop back to the Tools layer and answer "how does the pool of capabilities itself keep growing." Multi-Agent Collaboration spans across the middle, answering "how does this whole mechanism, built for a single agent, extend to several agents existing at once."

### Already Building an Agent

Feel free to jump straight to the part closest to your current problem:

- Designing a Tool right now → Part One
- Implementing an autonomous execution loop → Part Two
- Working through token spend, cache, or compaction → Part Three
- Designing cross-session memory → Part Four
- Designing a reusable operational workflow → Part Five
- Orchestrating multiple collaborating agents, splitting up tasks → Part Six
- Integrating an external tool or MCP server → Part Seven

Each chapter tries to preserve prerequisite context and relevant links so you can skip around, but within each part, reading in order is still recommended.

## Contributing

- Found a factual error, or have new verification results → open an [Issue](https://github.com/diaozxin007/reading-claude-code/issues)
- Want to fix wording or add a chapter → PRs are welcome
- English version → see the [en/ directory](https://github.com/diaozxin007/reading-claude-code/tree/main/en)

---

Start with Part One's [Tool Mechanism: How Claude Uses Tools](tool-mechanism.md) and see how a single capability first gets handed to the model.
