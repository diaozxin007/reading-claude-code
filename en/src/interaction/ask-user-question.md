# AskUserQuestion

I've spent some time reverse-engineering the design of [Claude Code](https://www.anthropic.com/claude-code) and even wrote a stripped-down Java clone — open source at [jooj](https://github.com/diaozxin007/jooj). One thing that keeps striking me: **every tool Claude Code ships with is carefully designed.** So I'm starting a series to unpack them one by one.

This first post is about **AskUserQuestion** — one of the most commonly seen tools, and one whose design is easy to underestimate.

## What AskUserQuestion Actually Is

AskUserQuestion is Claude Code's built-in **structured question tool**. Instead of Claude emitting a plain-text question and waiting for the user to type back, this tool renders the question as an **interactive selection panel** — the user sees a set of predefined options (as cards), not a wall of text.

The core problem it solves is **efficient alignment between AI and user**:

1. **Lowers user effort** — clicking an option is faster than typing a reply
2. **Structured input** — Claude gets an unambiguous enum value, no natural-language parsing needed
3. **Converges ambiguity** — the preset options force a choice among concrete alternatives instead of a vague "you decide"
4. **Escape hatch** — the system always appends an implicit "Other" option so users are never boxed in

## A Concrete Example

Before diving into triggers, implementation, and prompt details, let's ground everything with a real scenario. Compare "life without AskUserQuestion" vs "life with it."

**Scenario:** the user tells Claude **"help me add user login to this app."**

That request is severely under-specified — no decision on auth method, no decision on where to store the credential. Claude can't just guess (the team might have conventions), and it can't infer from the code either (it's a new feature with no precedent).

### The Anti-Pattern: What Happens Without AskUserQuestion

Claude can only throw the question back as a plain-text prompt, something like:

> "Which auth method do you want? I'd suggest JWT, but session cookies or OAuth also work. Also, where should we store the credential — httpOnly cookie or localStorage?"

The user immediately hits several problems:

1. **High cognitive load** — one paragraph packs in 2 decisions and 5 options; the user has to parse the question before answering
2. **High answer cost** — they either type a reply ("JWT + httpOnly") or spend two hours Googling "JWT vs session cookies" before coming back
3. **High parsing cost for Claude** — a reply like "let's go with JWT, and the cookie one" forces Claude to figure out which option the user actually picked, with room for misinterpretation
4. **Recommendation drowns in text** — Claude says "I'd suggest JWT" but it's blended into the paragraph, easy to miss
5. **No fallback** — if the user wants an option Claude didn't list (e.g. magic email links), they have to break out with a separate explanation or accept being funneled into a three-way choice

**The core pain:** free-text form turns "collaborative alignment" into an expensive natural-language round-trip.

### The Fix: How AskUserQuestion Solves It

Claude constructs a single call containing **two questions**. The user sees two cards like this:

**Question 1** — Auth method

![Auth method selection card](images/ask-user-question-auth.jpg)

**Question 2** — Credential storage

![Credential storage selection card](images/ask-user-question-storage.jpg)

Each card has a short chip label at the top ("Auth method" / "Token storage"), followed by 3 / 2 options, plus an automatically appended "Other". Two clicks and Claude receives roughly:

- Question 1 → user picked **JWT (Recommended)**
- Question 2 → user picked **httpOnly cookie (Recommended)**

**Decision time compressed from minutes to seconds.** That's the point of AskUserQuestion — not "let the AI ask a question," but "make every clarification in the collaboration cheap."

### Side-by-Side: Each Pain Point Solved

| Anti-pattern pain | AskUserQuestion's fix |
|---|---|
| High cognitive load | Split into 2 independent cards, one decision at a time |
| High answer cost | Click instead of type; trade-offs sit right under each option |
| High parsing cost for Claude | Return value is an explicit label — no NL parsing needed |
| Recommendation drowns in text | "(Recommended)" suffix + first position — impossible to miss |
| No fallback | "Other" is auto-appended; a custom answer is always one field away |

Every design decision below traces back to exactly one of these pains. Keep this mapping in mind — you'll see each constraint in the tool description addressing a specific row in this table.

## When to Fire It

The tool description spells out the boundary: **only when you're blocked, and only when the decision is genuinely the user's.**

**Three "yes, ask" situations:**

- **Can't infer from the request** — the requirement itself is vague (e.g. "add login" with no auth method specified)
- **Can't infer from the code** — there's no existing pattern to mimic
- **No sensible default** — the choice involves taste, business rules, or architectural forks that AI shouldn't decide unilaterally

**Three "no, don't ask" situations:**

- **The answer is in the code** — spend time reading, don't interrupt the user
- **Only one obviously reasonable path** — just do it, explain in the commit message
- **In plan mode asking "is my plan OK?"** — that's ExitPlanMode's job, using Ask here is a duplication

A canonical anti-pattern: **avoid meta-questions like "does this plan look good?" or "can I proceed?"**. ExitPlanMode already exists to request approval — using Ask for the same purpose is pure redundancy.

## Schema Design

Reverse-engineering from the tool's input schema, the core structure looks like this:

Claude passes in a **list of questions** (1 to 4). Each question object has four parts:

- **question** — the full question text, ending with a `?`
- **header** — a very short chip label displayed at the top of the card (max 12 chars)
- **multiSelect** — boolean; whether multiple options can be selected (default false)
- **options** — a list of 2 to 4 options

Each option object has three fields:

- **label** — the display text the user sees (1 to 5 words)
- **description** — an explanation of what the option means / the trade-off
- **preview** — optional; when the difference between options needs visual comparison (mockups, code snippets), this content is rendered when the option is focused

A few key design choices:

1. **1–4 questions per call** — supports batched decisions (like "auth method + token storage" in one call), but prevents Claude from bombarding the user with 10 questions at once
2. **2–4 options per question** — forces Claude to pre-categorize, converging N possibilities into a small set of clickable choices instead of dumping a long list
3. **"Other" is implicit** — auto-appended by the UI, Claude doesn't hand-list it. This guarantees "options Claude thought of ≠ complete space" doesn't trap the user
4. **Recommendation mechanism** — if Claude has a preference, put it first + append "(Recommended)" to the label. The user spots it at a glance
5. **Return value shape** — keyed by question text, mapped to the selected label; a separate `annotations` field carries user notes for preview-based options

**The preview field** is a subtle-but-powerful escalation — when options differ visually (two UI mockups, two code styles), embedding the visual in `preview` lets the UI render it live as the option gets focus. Perfect for "which API shape" or "which layout" questions.

**Division of labor with EnterPlanMode / ExitPlanMode:**

- In plan mode: use AskUserQuestion to clarify "which approach" (before finalizing)
- In plan mode: do NOT use AskUserQuestion to ask "is my plan ready?" (use ExitPlanMode)
- Outside plan mode: use AskUserQuestion for any technical fork that needs user judgment

The three tools form a complete decision pipeline: **Ask clarifies → EnterPlanMode expands → ExitPlanMode commits.**

## Prompt Breakdown

Every sentence in the tool description encodes a behavior constraint. Let's decompose them.

**Constraint 1: Strict applicability boundary (opening sentence)**

> Use this tool only when you are blocked on a decision that is genuinely the user's to make: one you cannot resolve from the request, the code, or sensible defaults.

This trains Claude to **not interrupt** — when uncertain, the first move should be to check the code and try sensible defaults, not throw a question at the user.

**Constraint 2: Making the "Other" escape hatch transparent**

> Users will always be able to select "Other" to provide custom text input

Instead of hiding "Other" from Claude and letting it invent a custom option, the tool description states outright: "Other is auto-added; you don't list it." This prevents Claude from wasting one of its 2–4 option slots on a hand-rolled "custom" entry.

**Constraint 3: multiSelect semantics**

> Use multiSelect: true to allow multiple answers to be selected for a question

Use cases: pick multiple feature flags / multiple environments / multiple files to modify. Defaulting to `false` protects users from decision paralysis.

**Constraint 4: How to express a recommendation**

> If you recommend a specific option, make that the first option in the list and add "(Recommended)" at the end of the label

Interesting design point: **the recommendation isn't a separate field — it's encoded via convention (position + suffix).** The benefits:

- Keeps the schema simple; no `recommended: true` boolean field
- The UI just renders the label; no special-case handling
- Claude's endorsement must be **visible in the label** — impossible to hide in metadata, the user sees it immediately

**Constraint 5: Temporal ordering with plan mode**

> Plan mode note: To switch into plan mode, use EnterPlanMode (not this tool). Once in plan mode, use this tool to clarify requirements or choose between approaches BEFORE finalizing your plan. Do NOT use this tool to ask "Is my plan ready?", "Should I proceed?", or otherwise reference "the plan" in questions — the user cannot see the plan until you call ExitPlanMode for approval.

This is the most instructive passage — it locks in the **temporal ordering** of the workflow:

1. In plan mode: use Ask to clarify approach forks (e.g. "A or B?")
2. Once clarified: use EnterPlanMode to draft a full plan
3. **Finally**: use ExitPlanMode to request approval — **do NOT** loop back to Ask with "OK to proceed?"

Especially note the last clause — **"the user cannot see the plan until you call ExitPlanMode for approval"** — this is the *real reason* you shouldn't ask "is my plan OK?" in plan mode. It's not just redundancy: the user literally has nothing to approve until ExitPlanMode fires.

Three tools, each with a distinct role: **Ask (clarify) / EnterPlanMode (expand) / ExitPlanMode (commit)**. The constraint fundamentally prevents Claude from looping back into Ask to serve as its own approval mechanism.

**Constraint 6: The `header` chip is mandatory (enforced at the schema layer)**

> Very short label displayed as a chip/tag (max 12 chars). Examples: "Auth method", "Library", "Approach".

A UX constraint — the UI renders each question as a card with a chip at the top. The chip uses `header`, not the full question text. This forces Claude to condense a long question ("Which authentication method should we use for the login flow?") into a tight chip ("Auth method").

**Constraint 7: Questions must end with a question mark**

> Should be clear, specific, and end with a question mark.

Looks trivial, but it shapes the UI's tone — a question form vs a statement form triggers a completely different psychological response. Indirectly, this forces Claude to phrase the content as a **genuine query**, not a disguised instruction.

---

## Takeaway

The elegance of AskUserQuestion isn't in the surface feature "let the AI ask users questions." It's in how the schema constraints + prompt constraints together lock down **when to ask / how to ask / how it's rendered / how it composes with other tools**. It takes the general-purpose capability "AI asking questions" and refines it into a **predictable, composable, maintainable interaction primitive**.

Next post I'll unpack the next tool in the series. If you enjoyed this deep dive, follow along — and let me know in the comments which Claude Code tool you'd most like to see dissected next.

