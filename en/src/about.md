# About

## About the Author

**diaozxin007** — a backend engineer with a Java background, currently focused on AI Agent applications and practical engineering.

### Related Projects

- **[jooj](https://github.com/diaozxin007/jooj)** — A stripped-down Java clone of Claude Code. This book's **meta-prerequisite** — writing jooj is what gave me the concrete sense for the design tradeoffs behind the official version.
- **[text2diagram](https://text2everything.vip/)** — A natural-language-to-Mermaid Agent app. Chat-based agent + repair loop architecture, supporting multiple diagram types.
- **Blog** — [xilidou.com](https://xilidou.com) — notes on AI Agents, distributed systems, and Java engineering.

### GitHub / Contact

- **GitHub**: [@diaozxin007](https://github.com/diaozxin007)
- **Issues**: found an error / have a suggestion / want to contribute → [reading-claude-code Issues](https://github.com/diaozxin007/reading-claude-code/issues)

---

## About This Book

### Scope

*Reading Claude Code, Together* — a deep dive into 16 core tools from Claude Code's official `<functions>` block, unpacking layer by layer the design philosophy behind each one.

Not a Claude Code user manual. Not an AI prompt engineering tutorial. **A close reading of tool design.**

### The Writing Process

The prose was written entirely through **human + Claude collaboration**. The methodology:

1. Each chapter follows a **six-part structure** (purpose / concrete example / when to fire it / schema design / prompt breakdown / summary)
2. Every citation of a tool description **must quote the original English** — a fact-checking discipline
3. Each review finding feeds back into the methodology, becoming an accelerator for the next chapter

From zero to 16 chapters + preface + appendix, the effort took about two days end-to-end. **Methodology quality is the ceiling for AI productivity.**

### Tech Stack

| Layer | Tool |
|---|---|
| **Writing** | Obsidian + Claude Code |
| **Static site generator** | [mdBook](https://rust-lang.github.io/mdBook/) (from the Rust ecosystem) |
| **Continuous build & deploy** | GitHub Actions — push to `main` auto-builds and deploys |
| **Hosting** | GitHub Pages |
| **Domain** | `diaozxin007.github.io/reading-claude-code/` (GitHub subdomain for now) |
| **Bilingual** | Chinese + English dual sites, each a standalone mdBook project, linked via hreflang |

### License

**MIT License.** You may:

- ✅ Read and share freely
- ✅ Quote passages (with attribution)
- ✅ Fork for personal learning
- ✅ Submit PRs to fix text / add chapters

Please **do not**:

- ❌ Print unmodified as commercial books
- ❌ Copy content without crediting the source

### References & Credits

- **[Claude Code](https://www.anthropic.com/claude-code)** — by Anthropic. This book is entirely based on analyzing tool descriptions from the official v0.5+ version.
- **[Anthropic Docs](https://docs.anthropic.com/)** — for anything on tool call mechanics.
- **[mdBook](https://rust-lang.github.io/mdBook/)** — for enabling this book to publish as a static site.
- **[jooj](https://github.com/diaozxin007/jooj)** — the **meta-prerequisite** of this book.

### Feedback

Found an error, have a better angle, want to contribute a chapter — all welcome:

- **Issue**: [github.com/diaozxin007/reading-claude-code/issues](https://github.com/diaozxin007/reading-claude-code/issues)
- **PR**: submit directly, I'll review

---

Back to [Preface](preface.md).
