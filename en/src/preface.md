# Preface

I previously studied Claude Code's design and wrote a bare-bones clone of Claude Code in Java — open-sourced at [jooj](https://github.com/diaozxin007/jooj). Claude Code's tools are all remarkably well-crafted. So I wanted to study them one by one. Let's learn together.

## Why I Wrote This Book

On the surface, Claude Code is just a bunch of unremarkable tool calls — Read / Edit / Bash and so on. But when you carefully read each tool's description, you'll find a wealth of seemingly "verbose" constraints:

- Edit forces you to Read the file before you can modify it
- Read prefixes every line with "line number + tab"
- Bash uses an entire paragraph to warn against using amend
- WebFetch repeatedly emphasizes "authenticated URLs will fail, check if there's an MCP tool first"

Where do these constraints come from?

The answer is: **hard-won lessons**. Behind every prompt constraint is an instance where the AI did something foolish, a user stepped on a landmine, or the Anthropic team distilled an insight from a postmortem.

**The shape of the tool itself is a methodology.**

This book aims to crack open these tools — examining how each field name, each prompt constraint, each runtime hard-block prevents the AI from making a specific mistake, what it encodes, and what it teaches Claude.

After that round of reverse engineering jooj, I developed a much deeper appreciation for many of the official version's design choices — those "simple"-looking fields are each the product of deliberate trade-offs. In a sense, this book is the output of that hands-on experience, just presented in a more readable format.

## What This Book Covers

Following the tools visible in Claude Code's official `<functions>` block, we dissect 16 tools in total:

- **Interaction primitives** (3) — AskUserQuestion / EnterPlanMode / ExitPlanMode: how the AI and user align
- **Execution primitives** (4) — Grep + Glob / Read / Edit / Write: locating, perceiving, and modifying files
- **General capabilities** (2) — Bash / Agent: unbounded fallback, spawning subagents
- **State & scheduling** (4) — Task family / Background / Cron / Monitor: spanning time and concurrency
- **Information access** (1) — WebFetch + WebSearch: breaking beyond local boundaries

Before those, there's an opening chapter — "Tool Mechanism" — that explains how Claude uses tools, laying the mental model foundation for all subsequent chapters.

## What This Book Does **Not** Cover

- Not a "Claude Code User Manual" — doesn't teach you how to install or configure keybindings
- Not an "AI Prompt Engineering Tutorial" — only covers tool-layer prompts, not general prompt techniques
- Not an "LLM Fundamentals Primer" — assumes the reader understands what tool calls and system prompts are

## How to Read This Book

**Read front to back**: chapters are organized by layer, and concepts from earlier chapters are reused later. The "Tool Mechanism" chapter in particular provides the mental model for the entire series.

**Skip around**: each chapter can be read independently. If you want to jump straight to how a specific tool is designed, go right ahead.

**Each chapter follows a six-part structure**:

1. **Purpose** — what problem this tool solves
2. **A concrete example** — using a real scenario to show "what happens without this tool vs. with it"
3. **Trigger conditions** — the boundaries of when to use it vs. when not to
4. **Technical implementation** — parameter design / runtime behavior / harness cooperation
5. **Prompt deep-dive** — dissecting each constraint in the official tool description line by line
6. **Summary** — what makes it elegant + comparison with other tools

## Fact-Checking Discipline

Wherever this book quotes a tool description, the **official original text** (in English, preserving the original wording) is used as much as possible. Translated or paraphrased content is explicitly marked with "My understanding is..." or similar labels to distinguish it.

This discipline comes from a self-own during the writing process — see the opening of the [AskUserQuestion](interaction/ask-user-question.md) chapter for details.

## Contributing

- Found a content error / have a better angle of observation → file an [Issue](https://github.com/diaozxin007/reading-claude-code/issues)
- Want to add a chapter / fix wording → PRs welcome
- English version → see the [en/ directory](https://github.com/diaozxin007/reading-claude-code/tree/main/en)

---

Ready? Start with the next chapter: [Tool Mechanism: How Claude Uses Tools](tool-mechanism.md).
