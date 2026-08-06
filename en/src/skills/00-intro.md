# 00 · Introduction · From Repeated Pasting to a Callable Capability

> **TL;DR**: A Skill packages instructions, checklists, and multi-step workflows that would otherwise be pasted over and over into an on-demand capability. Claude only needs to know its name and purpose most of the time — the full instructions are loaded only when they're actually relevant, and the work itself is carried out with existing Tools. It participates in capability selection like a Tool, but it isn't a new atomic executor.

When you're about to cut a release, you probably end up saying something like this to Claude, again and again:

```text
First check the workspace state, then run the tests, generate a changelog,
verify the version number, and finally list the files ready for release.
Don't actually publish until you've gotten confirmation.
```

This isn't a static fact that holds true across the whole project — it shouldn't be stuffed into CLAUDE.md, forcing every task to pay a context cost for a workflow that's only occasionally used. Nor is it a single-action Tool — it has to sequence several things in order: check git status, run tests, read the changelog, summarize the risks. It's a piece of **operational know-how** that gets reused often, but has to be manually re-explained every single time.

Leave it in the chat, and you'll have to paste it again next session. This is exactly the problem Skill is meant to solve: **how do you make a piece of operational knowledge persist over the long term, while only pulling it into the current task when it's actually needed?**

## Store It as a Folder First — Sitting in the Candidate List Without Expanding

Save that release-checklist script as a folder called `release-check`:

```text
release-check/
└── SKILL.md
```

`SKILL.md` is split into two halves:

```markdown
---
name: release-check
description: Verify whether a version is ready for release; use this when preparing a release
---

1. Check workspace status
2. Run tests and the build
3. Verify the version number and changelog
4. Summarize risks and wait for user confirmation
```

The frontmatter lines (`name`, `description`) — which this series will refer to collectively as **metadata** — aren't the workflow body itself; they're an index entry in the capability catalog. They sit in Claude's candidate list most of the time, taking up almost no context. The actual four-step instructions — the body of SKILL.md outside the frontmatter, which this series will call **instructions** — are only expanded and read into the current context once a given task is judged to be "relevant to release-check."

Anthropic calls this staged loading **progressive disclosure**. The more Skills you install, the amount of context consumed at baseline doesn't scale up accordingly — because most Skills' bodies never actually get expanded.

## Choosing Whether to Use It Is the Same Motion as Choosing a Tool

When a user asks "is this version ready to ship," Claude isn't looking at an ordinary block of Markdown. It first has to judge: is the current task relevant to release-check, should it be invoked, and what happens after it is?

This closely mirrors the process of Tool selection — a Tool also presents its name, purpose, and inputs up front, and the model decides when to call it. release-check participates in selection the same way, via a discoverable description, and the user can also invoke it directly by name with `/release-check`.

So a Skill isn't just another filename for CLAUDE.md — CLAUDE.md holds standing rules carried into every session, while a Skill like release-check is a candidate sitting on the capability shelf, staying out of sight until it's selected.

But "participating in selection the same way as a Tool" doesn't mean it *is* a Tool.

## Tools Provide Actions, Skills Provide Methods

A Tool's endpoint is a deterministic executor — Read reads a file, Bash runs a command; the model issues a tool call, the runtime executes it, and a result comes back.

Once release-check is expanded, its endpoint isn't a single execution — it's a set of instructions: use Bash to check git status, run the tests, use Read to verify the changelog, and finally output only a risk summary and wait for user confirmation. The ordering of the four steps, what to look at before proceeding, and when to stop — all of that judgment lives in SKILL.md. What actually changes the outside world is still Bash, Read, and the other Tools that already exist.

**A Tool turns Claude from something that can only talk into something that can actually act. A Skill organizes "can act" into "knows how to reliably complete a category of work."**

## More Than Just Four Steps — It Can Carry Additional Material

If release-check consisted of nothing but those four steps of Markdown, it would already be more than a prompt stashed in chat history — it would have three properties a chat-stored prompt lacks: discoverable, reusable, and loaded on demand. But it's a folder, and more can be added to it — material that's packaged alongside the instructions but doesn't live in the SKILL.md body itself. This series will call this **supporting resources**:

A `references/version-policy.md` file that records this project's specific conventions around version numbers — something Claude only reads when it needs to judge "should this change bump the major version," and stays out of the way the rest of the time. A `scripts/validate-version.sh` script that hands off "is this version number formatted correctly" to a deterministic check, rather than making the model work it out from scratch each time. An `assets/release-report.md` template that the release report gets filled into.

The four-step instructions answer "what exactly needs to happen right now" — this is **Task content**. `version-policy.md` answers "what should be known when handling this category of problem" — this is **Reference content**. Both are loaded into context on demand, but the appropriate way to invoke each differs — the next post will break down this folder structure in detail.

## Questions Still Unanswered Once It's Installed

Once release-check is installed, a few questions still don't have answers: does it live alone in this project, or can it be shared with colleagues and rolled out company-wide? When a user types `/release-check` to invoke it by name, versus Claude reading the description and deciding on its own that "this task calls for it" — is that the same activation path? Once expanded, do the four steps keep running in the current conversation, or do they get dispatched to a separate subagent that runs them and returns only a summary? If SKILL.md says "Bash is allowed but network access isn't," who enforces that restriction?

These questions correspond respectively to **discovery** (how does Claude know this capability exists), **activation** (why was it selected at this particular moment), **execution** (which context do the instructions run in), and **governance** (who can distribute, invoke, and authorize it). They ultimately converge on a single criterion: **stable facts go into standing rules, atomic actions become Tools, reusable operational knowledge becomes a Skill** — but that's content for the closing post; for now, the questions are simply laid out.

This series will follow the full lifecycle of a Skill like release-check, answering these four questions in turn, rather than walking through the official documentation field by field.

## Three Layers of Content, Three Kinds of Cost

The folder structure of release-check isn't a matter of filing conventions — it's about scheduling when different pieces of content should appear:

| Layer | In context by default? | What it corresponds to in release-check |
|---|---|---|
| metadata | Yes | `name`, `description` |
| SKILL.md body | After activation | The four-step instructions |
| supporting resources | On demand | `version-policy.md`, `validate-version.sh`, `release-report.md` |

If the description is written too vaguely, Claude won't think of release-check even when a release task comes up; if it's written too long, every session pays a small context cost for those few lines. If the four-step instructions cram in too much detail, a single activation drags a large block of decision logic into the current task; if nothing tells Claude when to read the references, the files just sit there unused. Judgments that could be written as a script but are instead left in the instructions, relying on the model to work them out fresh each time, end up less reliable than the script would be.

## Coming Up Next

By now it should be clear that a Skill like release-check isn't just a prompt — it's a discoverable, expandable capability folder that can carry along additional resources. The next post, [01 · Capability Format · From a Single Markdown File to a Portable Folder](01-format.md), will first draw a clear line: within the release-check folder format, which parts are the minimal structure mandated by the open Agent Skills standard, and which parts are product capabilities Claude Code has added on top.

## References

- Anthropic Claude Code official documentation: [Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- Anthropic Platform official documentation: [Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Agent Skills open specification: [Specification](https://agentskills.io/specification)
- [Tool Mechanism: How Claude Uses Tools](../tool-mechanism.md)
- [00 · Introduction · Claude Code's 200K Ledger](../context-management/00-intro.md)
