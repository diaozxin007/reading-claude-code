This is the second article in the Claude Code tools research series. The previous one dissected [AskUserQuestion](ask-user-question.md) — a structured questioning tool that lets users pick from options. This one covers its **sibling tool** — EnterPlanMode.

> This series assumes you have read the [prerequisite article](../tool-mechanism.md) — which explains what tools are and how Claude uses them. This article follows the 4-layer skeleton proposed there.

## EnterPlanMode

Like AskUserQuestion, this is a high-frequency tool you see every day. But its design is "heavier" than Ask — it does not ask a single question; instead, it **switches Claude into an entirely new working mode**.

### Purpose

EnterPlanMode is Claude Code's built-in **"planning mode entry" tool**. What it does is simple and forceful: it switches Claude from the default "think-as-you-go" mode into a **read-only exploration + solution design** planning mode. Only after obtaining explicit user approval of the plan does Claude return to code-writing mode.

The core problem it solves is "alignment between AI and user on the approach":

1. **Prevents going off-course halfway through** — makes Claude align with the user on the approach before modifying any file
2. **Enforces read-only exploration** — once in planning mode, Edit / Write / NotebookEdit are disabled; it is physically impossible to "sneak in changes while exploring"
3. **Clarifies decision boundaries** — the user sees the complete plan and can approve / reject / request revisions, rather than discovering a wrong direction only when reviewing the PR
4. **Produces a traceable planning artifact** — Plan mode produces a written plan file, not a message that scrolls past in chat; it can be referenced and revised

### A Concrete Example

**Scenario**: The user tells Claude **"Help me refactor this authentication module — replace JWT with session cookies."**

The request sounds clear, but in practice it spans: login routes / token-generation middleware / frontend storage layer / session expiration strategy / database schema (should we create a sessions table?) / backward compatibility for existing API consumers. **Multiple files, multiple decisions, multiple dependencies.**

#### Counter-example: Without EnterPlanMode

Claude can only guess an approach from context and start coding immediately:

- Opens `auth/middleware.ts` — rewrites it to read session cookies
- Opens `auth/routes.ts` — removes JWT signing, replaces with `req.session`
- Opens `frontend/api.ts` — removes the `Authorization` header logic
- Opens `models/user.ts` — adds a `sessionId` field
- Halfway through, discovers: 3 other services verify against this API using JWT...

The user sees the diff and is baffled: "I wanted sessions for the web client only — the backend services' JWT should stay! You replaced the entire API auth — what now?"

Problems surfaced in this round:

1. **A directional mistake is only caught 5 steps later** — 4 files already changed, rollback is painful
2. **Decision boundaries are blurry** — "Replace all auth or just web-side?" — a critical fork Claude guessed wrong on with no one to intervene
3. **User cannot see the big picture** — they only see a pile of diffs and have to reverse-engineer the plan
4. **Important side effects go unannounced** — Should we create a sessions table? Use in-memory or Redis for session expiration? These thoughts flickered through Claude's mind but were never written down
5. **High rollback cost** — every step consumed tokens and cognitive effort; overturning it all is pure waste

**Core pain point**: "Think-as-you-go" makes Claude start producing diffs while the **approach is still unformed** — the user cannot see the big picture until the very end.

#### How EnterPlanMode Solves This

Claude first declares "I want to enter plan mode" and requests user approval — **note that this step itself is an interactive confirmation**; if refused, Claude falls back to default mode. Once the user approves:

**Step 1 - Enter read-only exploration**

Claude's toolbox is narrowed:
- Can use: Read / Glob / Grep / Agent / AskUserQuestion / ExitPlanMode
- Disabled: Edit / Write / NotebookEdit

It is physically impossible to modify any file. All exploration is read-only.

**Step 2 - Understand the project's current state**

- Uses Grep to find everywhere JWT is used — discovers that besides the web client, 3 internal services also use it
- Uses Read to inspect the existing validation logic in `auth/middleware.ts`
- Uses Glob to locate all auth-related test files
- Uses Agent to dispatch a general-purpose subagent to research "Does the project have an existing session store convention?"

**Step 3 - At a critical fork, uses AskUserQuestion to clarify**

For example, asks the user:
- "Replace web-side only" or "replace everything"?
- Session store: memory / Redis / DB?

— This brings us back to the Ask clarification pattern from the previous article. **Ask and EnterPlanMode are natural companions.**

**Step 4 - Write the plan**

Claude writes the full plan into a plan file: scope, affected files, migration steps, risks, rollback strategy. **This is a citable, revisable artifact — not chat history.**

**Step 5 - ExitPlanMode requests approval**

The user sees the complete plan and decides:
- Approve -> Claude returns to code-writing mode and executes per the plan
- Revise -> provides feedback; Claude revises the plan
- Reject -> change direction

**Not a single file was modified before approval.** The user's tokens, time, and cognitive effort are not wasted on a wrong direction.

#### Comparing: Which counter-example pain points does this solve?

| Counter-example pain point | EnterPlanMode's solution |
|---|---|
| Directional mistake caught only 5 steps later | No file can be modified before ExitPlanMode approval |
| Blurry decision boundaries | AskUserQuestion can clarify critical forks inside plan mode |
| User cannot see the big picture | The plan file is a complete proposal, not a pile of diffs |
| Important side effects go unannounced | Forced explore -> design -> present flow gives Claude time to think thoroughly |
| High rollback cost | Exploration is read-only; a rejected plan requires no code rollback |

### Trigger Conditions

The tool's official description states an interesting principle: **"Non-trivial implementation tasks default to planning"** — this is a **conservative default**.

**7 categories** of "should use plan" scenarios:

- **New feature implementation** — no matter how small, adding any piece of functionality from scratch involves implicit decisions (where to put it, what happens on click, how to handle errors...)
- **Multiple reasonable approaches** — "Add caching" could mean Redis / in-memory / file; "real-time updates" could mean WebSocket / SSE / polling — the choice itself is design
- **Modifying existing behavior** — "Update the login flow" — what exactly changes? Clarify before acting
- **Architectural decisions** — choosing patterns, dependencies, data flow directions — all require user sign-off
- **Changes touching more than 3 files** — impact surface too large for diffs alone to convey the full picture
- **The requirement itself is unclear** — "Make the app faster" — need to profile first, discuss optimization direction
- **User preferences affect the implementation** — if you would use AskUserQuestion to clarify, you should even more so use EnterPlanMode to explore

**4 categories** of "should NOT use plan" scenarios:

- **Single-line fixes** — fixing a typo, an obvious off-by-one
- **Adding a single function with a very clear requirement** — just write it, no need for preamble
- **The user already gave very specific, detailed instructions** — the user is already doing the planning; Claude planning again is redundant
- **Pure research / exploration tasks** — these should use the Agent tool; they do not involve subsequent implementation

An **interesting bias**: the official text says "err on the side of planning" — **when in doubt, lean toward planning**. This default itself reveals the designers' stance: **bias toward alignment over speed**.

### Technical Implementation

#### 1 - Naming

`EnterPlanMode`

Compared to AskUserQuestion which has signals across all 4 layers, EnterPlanMode's signal distribution is very different — **naming takes on the role that schema would normally play**:

- `Enter` — a verb implying "entering a state" (not fetching data, not executing an action)
- `PlanMode` — a state name, paired with `ExitPlanMode` to form a duality

A counterfactual design: if it were called `SetMode(mode: "plan")`, the model would treat it as "setting a property" — casually toggling it on and off. The current naming encodes it as a **ceremonial state transition** — requiring an explicit Enter and an explicit Exit. The semantics are far stronger than a parameterized SetMode.

This is also why the schema layer can be empty — naming has already locked down the semantics; schema does not need to serve as a fallback.

#### 2 - Tool-Level Description

EnterPlanMode's description revolves around four things: **when to use / when not to use / division of labor with neighbors / what happens at runtime**.

**The conservative bias in the opening**

> Prefer using EnterPlanMode for implementation tasks unless they're simple.

One sentence reshapes Claude's behavioral tendency — "when unsure, plan first" rather than "when unsure, just do it." This writes a **conservative default gear** into the top of the tool.

**Quantified thresholds for 7 use cases**

The "When to Use This Tool" section lists 7 numbered headings, each with specific judgment cues. The most typical one:

> Multi-File Changes: The task will likely touch more than 2-3 files

It provides a **quantified threshold** (2-3 files) rather than a subjective feeling. This reduces disagreement within Claude about "should I use plan mode or not" — subjective intuition is compiled into an objective rule.

**Boundary with AskUserQuestion**

> If you would use AskUserQuestion to clarify the approach, use EnterPlanMode instead

This converts a fuzzy boundary (when to use Ask vs. when to use plan) into an explicit rule: **Ask only solves point clarifications; when approach-level forks are involved, open plan mode directly.** This avoids the anti-pattern of "using Ask to ask a bunch of questions to piece together an approach" — that kind of Ask loop is a terrible experience.

**Boundary with Agent**

> Pure research/exploration tasks (use the Agent tool with explore agent instead)

This clarifies another boundary: **Pure research with no intent to implement should not use EnterPlanMode.** Why? Because EnterPlanMode is "planning before implementation." If you do not intend to implement, entering plan mode is idle spinning — dispatching a subagent with Agent to do research is more appropriate.

**User approval is a hard requirement**

> This tool REQUIRES user approval - they must consent to entering plan mode

This is not "AI unilaterally switching state" — the user is the gatekeeper of the process. This also explains why it is a zero-parameter tool call: the call itself is a "request for permission," not an execution.

**Default when unsure**

> If unsure whether to use it, err on the side of planning - it's better to get alignment upfront than to redo work

This is the **value statement** for the entire prompt — rather than doing it wrong and rolling back, spend an extra round on alignment. This value also appeared in the AskUserQuestion article — **Claude Code's entire tool ecosystem is biased toward alignment**.

**Social etiquette framing**

> Users appreciate being consulted before significant changes are made to their codebase

This sentence trains Claude's **social intuition** — it is not just an efficiency consideration; planning itself is a gesture of "respecting the user's ownership of their codebase." This framing makes Claude see "planning first" not as an interruption, but as collaborative etiquette.

#### 3 - Field-Level Description

**Empty.**

EnterPlanMode has no input parameters — the schema is an empty object `{}`. So the field-level description layer simply does not exist. All intent is pushed up into the tool-level description.

#### 4 - Schema Validation Rules

**Empty.**

The `input_schema` is an empty object — no fields, no types, no constraints. The act of calling itself = the intent to switch state; no data needs to be passed.

The "emptiness" of this layer is itself a design signal: **permission narrowing is implemented at the tool layer, not the parameter layer.** Claude does not need to "apply for" certain permissions or "declare" which mode to enter. The official runtime automatically executes the following actions after Claude calls EnterPlanMode:

1. Requires user approval — just like Ask, entering plan mode requires the user to click "agree to enter plan"
2. The tool whitelist is narrowed — after entering, Edit / Write / NotebookEdit are disabled
3. CWD-related caches are rewritten — system prompt sections / memory files / plans directory are all refreshed, ensuring a clean plan mode context
4. Can only exit via ExitPlanMode — unlike AskUserQuestion which ends after asking, plan mode is a **persistent state**

---

### Division of Labor with Neighboring Tools

- **AskUserQuestion** — point clarification: "A or B?"
- **EnterPlanMode** — develop a complete plan (Ask can still be used during planning)
- **ExitPlanMode** — submit the plan for user approval

The complete decision pipeline formed by these three tools:

```
Encounter an unclear fork
    |
Ask to clarify (choose A / choose B)
    |
EnterPlanMode (enter planning mode)
    |-- Grep / Read / Glob / Agent to explore
    |-- Ask to clarify sub-questions (can be multiple times)
    +-- Write plan file
    |
ExitPlanMode (submit the plan)
    |-- User approves -> return to default mode, write code per plan
    |-- User revises -> feedback; Claude revises the plan
    +-- User rejects -> end
```

The previous article mentioned that AskUserQuestion **should not** be used inside plan mode to ask meta-questions like "Is the plan OK?" — restating the reason: **Because the user cannot see the plan until ExitPlanMode is triggered - there is nothing for the user to approve.** The question "Is this OK?" has no semantics at this point in the sequence.

---

### Summary

The elegance of EnterPlanMode lies not in the feature of "making AI think before acting" itself, but in its **extremely skewed signal distribution**: naming carries the core semantics (the Enter + PlanMode duality), the tool-level description is packed with behavioral constraints (7 use cases + conservative bias + social etiquette), and both the field-level description and schema are empty.

This teaches us something more fundamental: **an empty schema is itself a design choice.** When a tool's semantics is simply "state transition," parameterization would undermine that semantics — a parameterized SetMode invites casual toggling, while a zero-parameter EnterPlanMode is a ceremonial request for permission.

The next article continues by dissecting [ExitPlanMode](exit-plan-mode.md) — the final link in the three-tool decision pipeline, examining how the action of "submitting a plan for approval" is designed.
