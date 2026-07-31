This is the third installment of the Claude Code tools research series. The first two dissected [AskUserQuestion](ask-user-question.md) and [EnterPlanMode](enter-plan-mode.md) — the first two stages of the decision pipeline: clarification and exploration. This one covers the final stage — ExitPlanMode: **submitting a plan for user approval**.

> Start with the [prerequisite article](../tool-mechanism.md) in this series — it explains what tools are and how Claude uses them. This article follows the 4-layer skeleton introduced there.

## ExitPlanMode

On the surface, this might be the **least remarkable** of Claude Code's three interaction tools. It doesn't have AskUserQuestion's multi-choice cards, nor EnterPlanMode's dramatic mode switch — it does just one thing: **trigger an "approve / reject" confirmation**.

But it's precisely this restraint of "doing nothing" that closes the entire three-tool pipeline.

### Purpose

ExitPlanMode is Claude Code's built-in **"exit plan mode and request approval" tool**. Its responsibility can be stated in one sentence: after composing a complete plan in plan mode, call this tool so the user can see the full plan and make a decision — **approve execution / ask Claude to revise / reject and change direction**.

The core problem it solves is "how does the AI get explicit user approval when transitioning from planning back to execution":

1. **Making the plan visible** — the full contents of the plan file are rendered in the UI for the user, not just a paragraph drifting by in chat
2. **Forcing an explicit decision** — the user must click approve / reject, cannot default to continuing, preventing Claude from jumping ahead
3. **One-click switch back to execution mode** — after approval, Claude automatically returns to default mode where Edit/Write are available
4. **Preserving a feedback channel** — the user can reject and request changes, rather than being stuck with "either follow the plan exactly or scrap everything"

### A Concrete Example

**Scenario**: Continuing the auth refactoring example from the previous article [EnterPlanMode](enter-plan-mode.md) — the user said "replace JWT with session cookies," Claude has already entered plan mode to explore, clarified with the user via Ask (web-only, Redis for sessions), and finished writing the plan file. Now it's ready to start writing code.

The question is: **How does Claude let the user know the plan is done and execution can begin?**

#### Counter-example: Without ExitPlanMode

Claude can only say in the chat: "I've finished my plan, roughly like this... [hundreds of words describing the plan] ... shall I start?"

The user runs into several problems:

1. **The plan is buried in chat** — hundreds of words of plan mixed in with prior exploration logs and clarification dialogue, hard to read
2. **No clear approval action** — the user replying "OK" / "sure" / "go ahead" / "thumbs up" all express agreement, but the semantics are ambiguous
3. **Claude has to parse consent semantics** — receiving "Sure, but could you add a device_id field to the sessions table?" (half-approval, half-revision), Claude doesn't know whether to proceed or revise the plan
4. **Mode switch lacks ceremony** — Claude's transition from "planning" to "execution" is **gradual**, potentially starting to write code mid-sentence, catching the user off guard
5. **High cost of rejection** — if the user spots a problem with the plan, they have to manually type out their concerns rather than having a proper "reject with reason" channel

**The deepest problem**: If Claude tries to solve this via AskUserQuestion asking "Is the plan OK?" — as mentioned in the previous article, **the user can't even see the full plan text before ExitPlanMode is triggered**. Using Ask to ask "OK?" is like asking the user to vote in a vacuum — completely meaningless.

#### How ExitPlanMode Solves This

After finishing the plan file, Claude directly calls ExitPlanMode (**the parameters are also empty** — see the technical implementation section below). The UI layer does several things:

**Step 1 - Display the full plan**

The interface reads from the plan file path specified by plan mode and renders a **standalone, structured, scrollable** plan view. What the user sees isn't "a paragraph drifting by in chat" but a formal plan document: scope / affected files / migration steps / risks / rollback.

**Step 2 - Provide three clear response channels**

- Approve — Claude returns to default mode and executes per plan
- Revise — the user inputs feedback, Claude goes back to plan mode to adjust
- Reject — end, change direction

**Step 3 - Mode switch is atomic**

The moment the user presses approve, the runtime does several things:
- Edit / Write / NotebookEdit go from disabled to available
- CWD-related caches are refreshed
- Claude receives an explicit "user has approved" signal and begins execution

**No semantic ambiguity, no slippery slope, no Claude jumping ahead.**

#### Comparing How the Two Approaches Address the Counter-example Pain Points

| Counter-example pain point | ExitPlanMode's solution |
|---|---|
| Plan buried in chat | UI renders plan file contents independently, not as a chat message |
| No clear approval action | User must click approve / revise / reject — explicitly enumerated |
| Claude has to parse consent semantics | Return value is a structured status (approved / not approved), not natural language |
| Mode switch lacks ceremony | Approval triggers atomic tool whitelist switch |
| High cost of rejection | "Revise" is a first-class entry point, user doesn't need to manually type "please revise" |

### Trigger Conditions

The official tool description is quite direct: **"Use only when you are in plan mode, have finished writing your plan to the plan file, and are ready for user approval."**

**When to use**:
- In plan mode, and the plan file is complete — **the only compliant invocation timing**

**When NOT to use**:
- **Pure research tasks** — the official text gives a counter-example: "search and understand the vim mode implementation" — this kind of task shouldn't use ExitPlanMode because you're not doing "implementation planning"
- **Plan isn't finalized** — a half-baked plan shouldn't be submitted for approval; finish it first
- **Trying to use it for general inquiries** — "Can I continue?" type questions should use another channel (if you really need to ask, use AskUserQuestion to clarify a specific fork, not to ask meta-questions)

An interesting heuristic: **only a plan worth citing deserves to trigger ExitPlanMode**. If your plan hasn't reached the level of "a readable, reviewable, challengeable document," then keep exploring in plan mode — don't rush to exit.

### Technical Implementation

#### 1 - Naming

`ExitPlanMode`

A perfect dual to `EnterPlanMode` — `Enter/Exit` is a standard in/out pairing, implying a "beginning and end" stateful operation rather than a one-way switch. The naming directly borrows from the established paradigm of file descriptor open/close, lock acquire/release — the semantics need no explanation.

If it were called `SubmitPlan` or `RequestApproval`, the semantics would drift toward "submitting some data / requesting some permission," weakening its core meaning as a **mode exit signal**.

#### 2 - Tool-level Description

ExitPlanMode's description revolves around three things: **when to use it / parameters don't carry plan content / don't use Ask for meta-questions**.

**Strict applicability boundary (opening)**

> Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

Three conditions stacked: **in plan mode + plan file is complete + ready for approval**. If any one is not met, don't call it.

**Transparency about the parameter mechanism**

> This tool does NOT take the plan content as a parameter - it will read the plan from the file you wrote

Explicitly tells Claude: **don't try to stuff plan content into the tool call parameters**. The UI will read from the plan file itself. This prevents Claude from redundant copying — saving tokens while ensuring "what the UI displays matches the plan file."

**The implicit semantics of approval**

> This tool simply signals that you're done planning and ready for the user to review and approve

The keyword is **signal** — this tool doesn't handle rendering logic or approval decisions; it only emits a signal. Rendering, voting, and state switching are all handled by the runtime. **The tool call is the lightest possible "signal emitter"** — a very Unix-philosophy design.

**Boundary with research tasks**

> IMPORTANT: Only use this tool when the task requires planning the implementation steps of a task that requires writing code. For research tasks where you're gathering information, searching files, reading files or in general trying to understand the codebase - do NOT use this tool.

This echoes what was emphasized in the EnterPlanMode article: **plan mode is "planning before implementation," not "research to understand existing code."** Research tasks should use the Agent tool to dispatch subagents for investigation.

**The forbidden meta-question anti-pattern**

> **Important:** Do NOT use AskUserQuestion to ask "Is this plan okay?" or "Should I proceed?" - that's exactly what THIS tool does. ExitPlanMode inherently requests user approval of your plan.

This one is particularly elegant — it doesn't simply say "use ExitPlanMode not Ask," but argues from the perspective of **semantic equivalence**: **asking "is the plan OK?" via Ask and calling ExitPlanMode are the same semantic action; the latter is the correct expression**. Both previous articles mentioned this anti-pattern; this article provides the **definitive prohibition** at the description level.

**Clarification vs. approval request ordering**

Official Examples item 3:

> Initial task: "Add a new feature to handle user authentication" - If unsure about auth method (OAuth, JWT, etc.), use AskUserQuestion first, then use exit plan mode tool after clarifying the approach.

This makes explicit the **execution order** of Ask and ExitPlanMode within plan mode: clarify specific forks first, then submit the unified plan for approval. **Don't clarify and request approval at the same time** — let the process converge linearly.

#### 3 - Field-level Description

**Empty.**

There is one field `allowedPrompts` but it's marked deprecated ("Deprecated: no longer used") and is not actually used.

The historical trace of this field is interesting in itself: inferring from the field name, early versions may have allowed Claude to declare a batch of "operation types automatically permitted after user approval" (e.g., `run tests` / `install dependencies`) **at the same time as requesting approval**, letting Claude obtain composite permissions in one shot. It was deprecated, indicating the Claude Code team later chose a more conservative path: **approval is approval of the plan itself; permission expansion goes through other mechanisms** (like permissions.yaml). This is a trace of **permission design evolving from "approval implies authorization" to "approval is approval, authorization is authorization."**

#### 4 - Schema Validation Rules

**Empty.**

Same as EnterPlanMode — input_schema has only one deprecated field with no actual constraints. The act of calling itself = expressing intent; no data needs to be passed.

**Runtime responsibilities of the empty schema**:

1. Only available in plan mode — cannot be invoked from default mode
2. Triggers UI plan display — the UI knows the plan file path from plan mode state, reads and renders it
3. Waits for explicit user response — synchronous blocking, no default continuation
4. Approval triggers atomic mode switch — tool whitelist restored, caches refreshed, Claude receives the approval signal

All of this is handled by the runtime and requires no parameters from Claude — once again echoing EnterPlanMode's empty schema design: **permissions and state converge in the runtime; Claude only emits signals**.

---

### Division of Labor with Neighboring Tools

**The final stage of the decision pipeline** — the complete three-tool cycle:

```
User: "Help me refactor auth - replace JWT with sessions"
    |
Claude: There are a few forks that need confirmation
    |
AskUserQuestion (clarify: web-only, Redis session store)
    |
Claude: Got it - let me plan this out first
    |
EnterPlanMode (user approves entry)
    |-- Grep / Read / Glob exploration
    |-- Ask to clarify sub-questions (may ask several more times)
    +-- Write plan file
    |
ExitPlanMode (user sees the complete plan)
    |-- Approve -> default mode, execute per plan
    |-- Revise -> back to plan mode to adjust, then Exit again
    +-- Reject -> end
```

**The three tools each serve their role; only together do they form a complete "collaborative alignment"**:

- **AskUserQuestion** — Clarification: "A or B?" (point decisions)
- **EnterPlanMode** — Exploration: enter read-only mode, turn the plan into a document
- **ExitPlanMode** — Sign-off: let the user approve / revise / reject the entire plan

---

### Summary

The elegance of ExitPlanMode lies not in the "let the user approve a plan" functionality itself, but in that its signal distribution **is highly mirrored with EnterPlanMode** — dual naming (Enter/Exit), tool descriptions packed with behavioral constraints, and both fields and schema empty.

If AskUserQuestion is "let the user pick an option" and EnterPlanMode is "enter planning mode," then ExitPlanMode is the **most humble stage** in this system: it does nothing except emit a signal, yet it gives the entire process a terminus and gives the whole collaboration the ceremony of "sign-off."

**The three-tool pipeline closes here**:

> Claude Code decomposed "AI-human collaboration" into three composable, orchestratable, predictable interaction primitives: clarify, explore, sign-off. Each primitive is **restrained** — it does only one small thing — but together they can express any collaboration scenario.

The next article continues with [Grep + Glob](../execution/grep-glob.md) — switching from the "collaborative alignment" trio to the "code exploration" duo, examining how information-search tools encode "what to search / how to search / how much to return."
