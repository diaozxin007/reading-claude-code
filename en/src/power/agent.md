---

This is the ninth article in the Claude Code tools research series. The previous eight articles covered three main threads:

- **Interaction primitive trio** ([Ask](../interaction/ask-user-question.md) / [EnterPlanMode](../interaction/enter-plan-mode.md) / [ExitPlanMode](../interaction/exit-plan-mode.md)) — aligning with the user
- **Execution primitive chain** ([Grep + Glob](../execution/grep-glob.md) → [Read](../execution/read.md) → [Edit](../execution/edit.md) / [Write](../execution/write.md)) — locating, perceiving, and modifying files
- **General-purpose fallback** [Bash](bash.md) — the only "boundaryless" tool that can operate on the real world

At this point, Claude already has the ability to independently complete an entire "modify code + run tests + commit" engineering workflow. But there's a class of problems that **none of these tools can solve**:

- "In this 100K-line codebase, which places use the legacy API?" — Grep returns hundreds of matches, reading them all would blow the context
- "I want to refactor the auth module — do some research first" — involves multiple subsystems, a single Claude can't digest it all at once
- "There's a bug somewhere — help me trace from this error message to the root cause" — requires multiple exploratory searches, each might fail, and results need synthesis

What these problems have in common: **the task either exceeds a single Claude's context capacity in scale, or involves multiple rounds of trial and error with results that need synthesis**. One Claude isn't enough — you need **multiple Claudes collaborating**.

This is why the Agent tool exists.

> Start this series with the [prerequisite article](../tool-mechanism.md) — it explains what a tool is and how Claude uses them. This article follows the 4-layer skeleton proposed in the prerequisite.

## Agent

Agent is the **most unique tool** in Claude Code — what it does is **spawn a new Claude instance** to complete a subtask. In software engineering terms, this is "forking a process"; in organizational management terms, this is "delegating to a subordinate."

The first eight tools are all "Claude doing it personally." Agent is "Claude being a manager." This perspective shift upgrades Claude Code from "one AI assistant" to "one AI team."

### Purpose

Agent is Claude Code's built-in **subtask spawning tool**. What it does: accept a natural language prompt, spawn a new Claude instance (called a subagent) to execute in an **independent context**, and return the result to the main Claude upon completion.

The core problem it solves is "a single Claude's context is limited, but real engineering tasks often exceed that limit":

1. **Context isolation** — the subagent uses its own context pool, not consuming the main Claude's tokens
2. **Specialized division of labor** — different subagent types (claude / Explore / Plan / vercel:xxx) are preset for different tasks
3. **Parallel execution** — multiple Agent calls can run concurrently, trading wall-clock time for context space
4. **Focused results** — what the subagent returns is a **final report**; all intermediate tool calls, searches, and trial-and-error stay on the subagent's side, the main Claude only sees conclusions

What makes Agent special is that it **inverts the concept of "tool"**: the first eight tools are "Claude uses tools to do things," Agent is "Claude has another Claude use a bunch of tools to do things." It's a **meta-tool** — a tool that can create Claudes.

### A Concrete Example

**Scenario**: The user says **"I want to refactor the auth module — first help me organize all auth-related code in the project and output a research report."**

The difficulty of this task:

- **Unknown scale** — auth code could be scattered across `src/auth/`, `middleware/`, `lib/security/`, `pages/api/*`
- **Multiple rounds of exploration** — each entry point found requires following dependencies and callers
- **Needs synthesis** — the final output should be a **structured report**, not a pile of scattered grep results

If the main Claude does it alone:

- Glob for related files — hundreds of matches
- Read them all — context blows up
- Read in batches — forgets what was read before
- When it's time to write the report, key context has already been pushed out

#### How Agent Solves This

The main Claude calls Agent, dispatching a subagent to complete the research:

```
Agent(
  description: "Research auth module architecture",
  subagent_type: "general-purpose",
  prompt: """
Research all auth-related code in this project and output a structured report.

Specific requirements:
- Find all auth-related files (login / logout / session / token / permission / role)
- Summarize each file's responsibility in one sentence
- Map out the call relationships between modules (who calls whom)
- Identify the 3 most refactoring-worthy spots and explain why

Constraints:
- Read-only — don't modify any files
- Keep the report under 500 words — don't paste code
- If you find key decisions that need user input, mark them "[needs user decision]" in the report
"""
)
```

**What happens at runtime**:

- The runtime spawns a new Claude instance (subagent)
- The subagent gets a **fresh context** (without the main Claude's conversation history)
- The subagent has its own toolbox (by default includes Read / Grep / Glob / Bash, etc.)
- The subagent searches, reads, thinks, and synthesizes within its own context
- Upon completion, the subagent returns a **final report** (structured text) to the main Claude

What the main Claude receives:

```
Agent report (500 words):

## Auth Module Architecture

**Core files**:
- src/auth/middleware.ts (JWT verification main entry)
- src/auth/routes.ts (login / logout / refresh routes)
- src/lib/session-store.ts (Redis session storage)
- src/models/permission.ts (RBAC permission model)

**Call relationships**:
API request → middleware.ts → session-store.ts → pass → business code
Login → routes.ts → jwt.sign → session-store.set

**3 refactoring suggestions**:
1. middleware.ts mixes JWT verification with session checks — suggest splitting
2. permission.ts uses hardcoded roles — suggest database configuration
3. Session TTL is scattered across 5 places — suggest centralizing in constants

[Needs user decision]:
- Keep JWT or switch entirely to session cookies?
- Introduce casbin for the permission layer?
```

**Key points**:

- The main Claude's context only retains the subagent's **report** (500 words), not the contents of dozens of files
- The subagent might have made 50+ tool calls internally (Grep / Read / Glob), all within its own context pool — the main Claude is completely unaware
- After receiving the report, the main Claude can continue discussing with the user, Ask for clarification, or EnterPlanMode to elaborate

#### Key Insight: Dispatching Isn't "Outsourcing" — It's "Context Isolation"

Many people first using Agent misunderstand it as "having another Claude do my work" — like hiring an intern. This analogy isn't quite right.

**Agent's real value isn't "saving Claude's effort" — it's "saving Claude's context."** The same tokens are consumed either way, but the main Claude's context pool only needs to hold the final report, not all intermediate grep outputs and file contents. **Trading wall-clock time and total token count for context space.**

This is like when human engineers on large projects say "I won't look at the details of this part — let XX research it and give me a conclusion" — it's not laziness, it's **limited cognitive bandwidth requiring selective attention**.

### Trigger Conditions

**Scenarios where you should use Agent**:

- **Cross-file research** — "how is the auth code organized" / "where is the legacy API used"
- **Multi-round exploratory search** — "there's a bug, trace from this error message to root cause"
- **Scale that would blow context** — needing to read dozens or hundreds of files
- **Parallelizable subtasks** — "research three different modules simultaneously"
- **Need for specialized subagents** — use `Explore` for searching, `Plan` for architecture design, `vercel:xxx` for specific domains

**Scenarios where you should NOT use Agent**:

- **Single known-target operation** — just editing one line of code, use Edit directly, don't have Agent go in circles
- **Tasks requiring user interaction** — subagents generally can't converse with users directly; if clarification is needed, the main Claude asks personally
- **When the process itself has value** — if the user wants to see every step of Claude's thinking (teaching scenarios), Agent hides the process and only shows results
- **Low-information tasks** — spawning a subagent has startup cost; simple tasks are actually slower

A **core heuristic**: **If the key information volume << conclusion information volume, dispatch an Agent.** Researching 100 files to produce a 500-word report is 100x information compression — perfect Agent scenario. Editing one line of code, compression ratio near 1 — don't dispatch Agent, do it yourself.

### Technical Implementation

#### 1 - Naming

`Agent`

One word covers all responsibilities, but the word choice is quite deliberate. It's not called `Fork` / `Spawn` / `Delegate` — it's called **Agent**, directly borrowing the AI field term "intelligent agent." This hints to Claude: what you're dispatching isn't "a function call" or "a process," it's **another entity capable of autonomous decision-making**.

Field names also carry semantic weight:

- `prompt` — the main input, literally called "prompt," same name as what users give Claude — implying "you're writing instructions for a subordinate"
- `subagent_type` — explicitly says this is a "sub-agent," the sub- prefix emphasizing hierarchy
- `description` — 3-5 word short description, differentiated from other tools' `description` (other tools' `description` is schema meta; here it's for runtime display)
- `isolation` — "isolation level," directly implying this is a switch trading off "independence" vs "collaboration"
- `run_in_background` — literally expresses "run in background," aligned with Bash's same-named parameter, but **default value is reversed** (Bash defaults foreground; Agent defaults background) — this default reversal itself is an important signal (detailed in next section)

#### 2 - Tool-Level Description

Agent's tool-level description **is the longest of all tools**. This isn't verbosity but because Agent involves many behavioral contracts, many error patterns, and fuzzy boundaries. It revolves around four things: **when-to-use/not-to-use boundaries / prompt writing style / communication protocol / anti-AI anti-pattern red lines**.

**Opening sentence: Positioned for "multi-step, cross-codebase"**

> Launch a new agent to handle complex, multi-step tasks. Each agent type has specific capabilities and tools available to it.

"complex, multi-step" — two words that narrow Agent's use cases — **single-step tasks, operations with clear targets, don't use Agent**. This is the first line of defense against "Agent sounds powerful so let's overuse it."

**Specific counter-examples for "don't use Agent"**

> If the target is already known, use the direct tool: Read for a known path, `grep` via the Bash tool for a specific symbol or string. Reserve this tool for open-ended questions that span the codebase, or tasks that match an available agent type.

This trains Claude to distinguish via **enumerated counter-examples**: "known path → use Read directly" / "finding specific symbol → grep directly." **Specifically known operations use direct tools; open-ended cross-codebase questions use Agent** — this is the most critical boundary rule in Agent's description.

**Encouragement of parallel calls**

> If the user specifies that they want you to run agents "in parallel", you MUST send a single message with multiple Agent tool use content blocks.

**Parallelism is Agent's key dividend.** Three Agent calls sequentially = 3x time; three Agents in one message = 1x time. This description explicitly trains Claude's intuition for "independent tasks use parallelism" — using the capitalized `MUST` to emphasize this isn't optional.

**Default value reversal for "background running"**

> Agents run in the background by default. When an agent runs in the background, you will be automatically notified when it completes — do NOT sleep, poll, or proactively check on its progress.

This says two things: ①Agent **defaults to background** (opposite of Bash, which defaults to foreground); ②the main Claude **should not poll** — there's a notification mechanism that proactively delivers results.

The design intent behind the default reversal is clear: **Agent is inherently a long task**; short tasks don't even need Agent. Making long tasks default to background lets the main Claude continue doing other things — this is **encoding best practices via defaults**.

**The "never delegate understanding" red line**

> **Never delegate understanding.** Don't write "based on your findings, fix the bug" or "based on the research, implement it." Those phrases push synthesis onto the agent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, what specifically to change.

**This is the most important rule in Agent's description.** It prevents a particularly bad usage pattern: the main Claude dispatches Agent to research, gets back a report, then dispatches another Agent to "fix the bug based on the research" — **outsourcing synthesis and decision-making to the subagent**.

The problem? **Synthesis is the main Claude's core job.** Dispatching subagents to search is correct, but after getting search results you must **yourself** read, think, and decide next steps. If you outsource synthesis too, you become a "relay" — understanding nothing at each step, ultimately losing control.

Using **bold + specific counter-examples** trains Claude to maintain the self-awareness of "I am the brain of this task," not transferring responsibility just because a tool is convenient. The final half-sentence "Write prompts that prove you understood" is an especially elegant operational definition — **the specificity of the prompt itself is evidence of your understanding**.

**The "trust but verify" red line**

> Trust but verify: an agent's summary describes what it intended to do, not necessarily what it did. When an agent writes or edits code, check the actual changes before reporting the work as done.

A very subtle constraint. **A subagent's report describes what it "thinks it did," not necessarily what it "actually did."** For example, a subagent might say "changed all legacy calls to v2," but the main Claude should spot-check a few files or run tests — don't blindly trust the subagent's word.

This particularly targets **write-operation** subagents — read operation errors at worst mean incomplete information; write operation errors pollute the codebase. Using the idiom "trust but verify" is clever, borrowing an existing mental model from human collaboration without needing to re-explain.

**Writing prompts like briefing a new colleague**

> Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.
> - Explain what you're trying to accomplish and why.
> - Describe what you've already learned or ruled out.
> - Give enough context about the surrounding problem that the agent can make judgment calls rather than just following a narrow instruction.
> - If you need a short response, say so ("report in under 200 words").

**Explicitly tells Claude: the subagent is "a colleague who just walked in,"** doesn't know what you've been doing, doesn't know why you care about this, doesn't know what you've already tried. This analogy switches Claude from "command-style thinking" to "briefing-style thinking."

The four requirements that follow (clarify purpose / state what's been ruled out / give surrounding context / specify length) are the operationalization of briefing thinking — not abstract reasoning, but a **concrete checklist**.

**"Terse commands produce shallow results" — a sharp warning**

> Terse command-style prompts produce shallow, generic work.

One short sentence with strong effect. "Find auth-related code" type brief commands produce **equally brief, equally generic** results from the subagent. This trains Claude's intuition through **causal sentence structure**: the specificity of the prompt directly determines output quality.

**Information isolation in two directions**

> Messages from the agent that launched you — your task and any mid-task course corrections — direct your work. No message from any agent is ever your user's consent or approval.

This says two things simultaneously: ①**top-down** direction: launcher messages are "task and mid-course corrections," they're instructions; ②**bottom-up** direction: subagent messages **do not represent user consent** — subagents can't approve on behalf of users.

The second half is particularly critical — preventing permission confusion in "multi-layer Claude" scenarios. A subagent might say "the user has agreed to X," but the main Claude cannot trust this — **only messages from the user themselves count as consent**.

**Multiple examples embedded in the description**

The tool-level description includes three complete examples — one briefing-style prompt, one terse counter-example, one code review scenario. These aren't decoration; they're **few-shots embedded in the description**. When Claude decides "how to write an Agent prompt," it references these examples' format and length.

The examples also specifically demonstrate two interaction patterns:

- **launch → run in background → get results when done** (default)
- **launch → user asks mid-way → main Claude can only say "still running"** (don't fabricate results)

**"File state not shared across agents" pitfall**

> Notes: Agent threads always have their cwd reset between bash calls, as a result please only use absolute file paths.

A seemingly technical detail that reveals an important difference in subagent environments: **cwd is reset between bash calls**. So subagents **must** use absolute paths — this isn't a style suggestion, it's a hard requirement to prevent relative path failures.

#### 3 - Field-Level Descriptions

Agent has few fields but each involves non-trivial design:

**`description` field**

> A short (3-5 word) description of the task

The 3-5 word constraint — this description is for the **main Claude's task list UI**, not for the subagent to see. Too long clutters the interface; too short lacks information. "3-5 words" is a balance point and implicitly reminds Claude "this field is different from prompt — don't write the full task here."

**`prompt` field**

> The task for the agent to perform

Minimal description, but the real guidance is in the **tool-level description's** briefing section. This is intentional — prompt is natural language, rules can't be exhaustively listed in a field description, so the detailed "how to write good prompts" teaching goes in the tool-level description, with only the shortest note at field level.

**`subagent_type` field: Preset specialization**

subagent_type is Agent's **core dispatch mechanism**. It's not free text but selected from a **runtime enum**. The system prompt lists currently available subagent types before each call:

- **claude** — general-purpose, has all tools
- **Explore** — fast read-only search, only has Read / Grep / Glob, explicitly cannot modify files
- **general-purpose** — complex research, multi-step tasks
- **Plan** — architecture designer, only designs, doesn't implement
- **vercel:xxx** — Vercel ecosystem domain-specific (deployment, performance optimization, AI architecture, etc.)

Choosing the right type = giving the subagent **the correct mindset from the start**. Dispatch Explore for "where is X defined," dispatch Plan for "how should we structure this," dispatch general-purpose for tasks requiring exploration + synthesis.

Key design point: **subagent_type is a runtime enum, not a compile-time constant** — users/projects can configure custom subagent types (like `vercel:ai-architect`), and Claude Code dynamically injects the available agents list in each session. This makes Agent naturally support **domain extension**.

**`model` field: Model override**

> Optional model override for this agent. Takes precedence over the agent definition's model frontmatter.

Allows specifying a different model for the subagent — e.g., the main Claude is Opus but dispatches Haiku for simple research to save cost. This is a **cost control mechanism**: not all subtasks warrant the strongest model.

**`isolation` field: Worktree isolation**

> "worktree" creates a temporary git worktree so the agent works on an isolated copy of the repo.

Some tasks need the subagent to **modify files**, but you don't want it polluting the main working tree. Set `isolation: "worktree"`:

- Runtime allocates an independent git worktree for the subagent
- The subagent can modify anything it wants inside
- After completion, the main Claude can choose to merge into the main working tree, or discard
- If the subagent made no changes, the worktree is automatically cleaned up

This is the mechanism for "letting subagents experiment boldly without breaking the main branch." The field description specifically states "if the agent makes no changes, worktree is automatically cleaned up" — clarifying "when automatic cleanup happens" so Claude dares to use this mechanism without worrying about leaving garbage.

**`run_in_background` field: Default reversal**

> Agents run in the background by default; you will be notified when one completes. Set to false to run this agent synchronously when you need its result before continuing.

**Defaulting to true is unique to Agent** (Bash defaults to false). This reversal makes sense:

| Tool | Typical task | Default |
|---|---|---|
| Bash | Single command, fast | Foreground (need results immediately) |
| Agent | Multi-step research, slow | Background (keep doing other things while it runs) |

The field description specifically hints: only manually set `run_in_background: false` if you need the result before continuing. This trains Claude to judge "is this Agent call blocking?"

#### 4 - Schema Validation Rules

Agent's schema validation is lightweight:

| Field | Type | Constraint |
|---|---|---|
| `description` | string | Required |
| `prompt` | string | Required |
| `subagent_type` | enum | Optional, selected from runtime enum |
| `model` | enum | Optional, sonnet / opus / haiku / fable |
| `isolation` | enum | Optional, worktree / remote |
| `run_in_background` | boolean | Optional, defaults to true |

**Key validation points**:

- **subagent_type is a runtime enum** — not hardcoded; before each tool call the harness injects currently available types, wrong names get rejected
- **model is a finite enum** — can only select from currently supported models, writing "gpt-4" gets directly rejected
- **description and prompt are both required** — but no hard length constraints; length is guided by soft rules in tool-level description (3-5 words / briefing-style)

**The key hard constraints aren't in the schema but in runtime**:

1. **Fork depth limit** — subagents generally **cannot spawn sub-subagents**. This prevents infinite recursion — imagine a subagent spawning a subagent spawning a subagent... tokens would be consumed exponentially
2. **Communication only at start and end** — runtime blocks mid-task bidirectional communication; the main Claude only passes the prompt at the beginning and gets the report at the end
3. **cwd reset** — bash calls within subagents have their cwd reset between calls, preventing relative path state accumulation

These runtime constraints are **structural defenses** — not type constraints expressible in schema, but isolation at the **execution environment** level. Agent uses runtime isolation to backstop prompt-level soft rules: if Claude forgets that "the subagent is a new colleague," runtime forces it to experience this through "complete context isolation + cwd reset."

---

### Division of Labor with Neighbor Tools

Agent forms a complete contrast with the tools from the previous eight articles:

| Dimension | Interaction trio | Grep + Glob | Read | Edit / Write | Bash | Agent |
|---|---|---|---|---|---|---|
| Role | Collaborative alignment | Locate coordinates | Perceive externals | Modify files | Command execution | **Spawn Claude** |
| Capability boundary | Limited, structured | Limited, search | Limited, read | Limited, write | Unlimited, real world | **Unlimited, recursive Claude** |
| Primary function | Align with user | Location | Perception | Modify code | Modify real world | **Compress info, isolate context** |
| Communication model | Interactive | Single call | Single call | Single call | Single call | **Fork + join (one-time briefing)** |
| Primary dividend | User alignment | Location precision | Perception commitment | Precise modification | Engineering workflow | **Context space** |

**Complete view of Claude Code's tool ecosystem**:

The first eight tools enable Claude to **independently complete** an entire workflow from "understanding requirements" to "delivering code." This "solo operation" mode suits small-to-medium tasks.

Agent opens a new door: **multi-Claude collaboration**. It extends Claude Code from "one AI assistant" to "a self-organizing AI team." When task scale exceeds a single Claude's cognitive bandwidth, dispatching subagents is the only elegant solution.

**Key philosophy**: Agent's existence acknowledges an honest fact — **a single Claude's context is finite, not all tasks can fit inside it**. This isn't a defect; it's by design. Human engineers facing large projects don't look at everything themselves either — they use organization, division of labor, and abstraction to compress information layer by layer. Agent lets Claude learn the same skill.

From this perspective, Agent isn't just "a tool" — it's Claude Code's **scaling primitive**. With it, Claude Code can truly handle tasks at the scale of "refactoring a 100K-line codebase."

---

### Summary

Agent's elegance lies not in the functionality of "letting AI dispatch AI" itself, but in how its signal distribution is **extremely skewed toward the tool-level description**:

- **Naming** — `Agent`, one word borrowing an AI concept; field names (`prompt` / `subagent_type` / `isolation` / `run_in_background`) are self-explanatory; `run_in_background`'s default reversal is itself a signal
- **Tool-level description** — **ultra-long**, the longest of all tools. Covers four areas: when-to-use/not-to-use boundaries / briefing metaphor for prompt writing / communication protocol / two anti-AI anti-pattern red lines (never delegate understanding · trust but verify), with three complete examples as few-shots
- **Field-level descriptions** — 6 fields, each with non-trivial design decisions (3-5 word UI display / runtime enum dispatch / model cost control / worktree isolation / background default reversal)
- **Schema validation** — minimal, only finite enum constraints. The real hard constraints aren't in schema but in **runtime isolation**: fork depth limits, communication only at start/end, cwd reset

Agent's uniqueness is that it **puts the center of gravity for "dispatching another Claude" — a high-risk capability — on prompt-level behavioral contracts**: the schema layer barely governs (six fields, pass whatever), field-level descriptions are brief and restrained, but the tool-level description uses **extensive natural language + specific counter-examples + few-shot examples** to repeatedly train Claude on "when to dispatch / how to dispatch / how to verify after dispatching." This is because Agent's error patterns (delegating understanding / blindly trusting reports / abusing concurrency / overly terse prompts) are all **semantic-level**, which schema validation cannot intercept.

Agent's two anti-AI anti-pattern red lines deserve special appreciation:

- **Never delegate understanding** — dispatching subagents to search and research is fine, but **synthesis and decision-making** are responsibilities the main Claude cannot shirk. This prevents the slippery slope of "Claude becoming an orchestrator that doesn't understand any step"
- **Trust but verify** — subagent reports are intention statements, not actual results. Especially for write operations, the main Claude must **verify actual changes** before declaring the task complete

These two together form Agent's **cognitive safety belt** — preventing "dispatching Claude" as a scaling primitive from becoming a "buck-passing primitive." It converges the general capability of "AI dispatching AI" into a meta-tool with **context isolation, information compression, non-delegated responsibility, and verified results**.

Next up: tearing down [Task Family](../state/task-family.md) — Agent is "dispatching subagents to do work," Task Family is "managing that work." The TaskCreate / TaskUpdate / TaskList / TaskGet / TaskStop / TaskOutput six-piece set is Claude's "externalized working memory," and the most rigorously dual-structured family in the entire tool ecosystem.
