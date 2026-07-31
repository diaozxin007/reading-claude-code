This is the fifth article in the Claude Code tools research series. The previous four covered the "interaction primitive trio" (Ask / EnterPlanMode / ExitPlanMode) and the search duo [Grep + Glob](grep-glob.md). The former addresses "how AI and users align," while the latter solves "how Claude locates relevant files within a project."

Once Claude has file paths in hand, it needs to **perceive what those files currently look like** — that's what **Read** does. It's the pivotal link in the execution primitive chain: catching the coordinates located by Grep/Glob and establishing the "perception commitment" trust chain for the subsequent Edit / Write operations.

> Start with the [prerequisite article](../tool-mechanism.md) for this series — it explains what tools are and how Claude uses them. This article follows the 4-layer skeleton proposed there.

## Read

Among all tools, Read is **the most fundamental and most easily underestimated**. On the surface it just "reads a file," but it plays a critical role: **Claude's only compliant channel for perceiving the external world**.

Without Read, Claude can only construct its understanding of a project from training-time memory (outdated) + snippets users paste in chat (partial) + hallucination (dangerous). With Read, every modification Claude makes has a real foundation to stand on.

### Purpose

Read is Claude Code's built-in **file content reading tool**. What it does is straightforward: given an absolute path, return the file contents — but its responsibilities go far beyond "reading a file":

1. **Provides Claude with the true disk state** — rather than letting it rely on training memory / user pastes / hallucinated guesses
2. **Prerequisite for Edit** — Read establishes tracking state at the harness layer so Edit can safely make changes
3. **Unified multimodal perception entry point** — text / images / PDF / Jupyter notebooks all go through this one tool
4. **Safe reading of large files** — pagination (offset + limit) prevents consuming the entire context in one shot

### A Concrete Example

**Scenario**: The user says **"There's a bug in `auth/middleware.ts` with the token validation — check the verifyToken part."**

Claude directly calls Read:

- `file_path`: `/Users/xxx/project/src/auth/middleware.ts` (**absolute path**)

**Runtime returns**:

```
     1	import jwt from 'jsonwebtoken';
     2	
     3	export async function verifyToken(req, res, next) {
     4	  const token = req.headers.authorization;
     5	  if (!token) return res.status(401).send('unauthorized');
     6	  
     7	  try {
     8	    const decoded = jwt.verify(token, process.env.JWT_SECRET);
     9	    req.user = decoded;
    10	    next();
    11	  } catch (err) {
    12	    return res.status(401).send('invalid token');
    13	  }
    14	}
```

**Every line has a line number + tab prefix** — Claude can pinpoint locations precisely. Looking at line 4 `req.headers.authorization` immediately reveals the bug: it doesn't strip the `Bearer ` prefix.

This output demonstrates several key characteristics of Read:

- **Absolute path in, real disk content out** — what Claude gets is the **current** disk state, not training memory, not chat history, not hallucination
- **Line number prefix establishes a coordinate system** — the user says "the bug on line 4" and Claude can locate it instantly; Claude says "jwt.verify on line 8" and the user can find it immediately
- **Default 2000 lines** — large files won't blow up the context in one shot

**Other input forms**:

- **Large files** (e.g., 5000 lines): only the first 2000 lines are read by default; you can specify `offset: 2000, limit: 1000` to read lines 2001-3000
- **Screenshots / images**: the runtime detects the extension and **presents them visually** to Claude (not as text), so Claude can "see" error dialogs, stack traces, field values
- **PDF**: must specify `pages: "1-5"` for documents over 10 pages, maximum 20 pages per request, preventing large documents from blowing up the context
- **Jupyter notebook**: returns all cells with their code + output + Markdown, presented together

**Core value**: Read is Claude's **only compliant channel** for perceiving the external world — replacing "guessing / memory / hallucination" with "knowing." All subsequent Edit / Write / Bash operations are built on this perception commitment.

### Trigger Conditions

The tool's official description is clear: **"Assume this tool is able to read all files on the machine"** — Claude shouldn't agonize over "should I read this file or not"; if it's needed, just read it.

**When to use Read**:

- **Before modifying a known file** — the required prerequisite before Edit / Write
- **Understanding project structure** — reading `package.json` / `tsconfig.json` / `CLAUDE.md` to establish baseline project understanding
- **User @filename** — files the user references with `@` in their message; Claude should proactively read them
- **User linked_note** — `<linked_note>` appearing in system context; read directly
- **Reading images / PDF / notebooks** — the entry point for multimodal perception
- **Embedded images in wikilinks** — when encountering `![[image.png]]` while reading documentation, proactively Read the image to establish complete context

**When NOT to use Read**:

- **A file you just Edited to "verify"** — the harness tracks state; if Edit succeeded, the change took effect; re-reading is wasteful
- **Listing directory contents** — use Glob or bash `ls`; Read cannot read directories
- **Searching for keywords in a file** — use Grep; Read fetches a full section and isn't suited for searching
- **"Verifying" your own previous output via hallucination** — if Edit / Write succeeded, Claude doesn't need to second-guess itself

An interesting **anti-waste principle**: the official docs explicitly state `Do NOT re-read a file you just edited to verify` — meaning the harness tracks file state for you, and Claude doesn't need to repeatedly confirm like a human programmer would.

### Technical Implementation

#### 1 · Naming

`Read`

Minimalist naming — a single verb covers all responsibilities. Files, images, PDFs, Jupyter notebooks all go through this one verb, not `ReadFile` / `LoadImage` / `ParsePDF`. **Unified naming corresponds to a unified entry point** — Claude doesn't need to remember multiple tool names; the runtime dispatches based on file extension.

Field names are also an intuitive set: `file_path` / `offset` / `limit` / `pages` — anyone who's written a pagination API understands at a glance.

#### 2 · Tool-Level Description

Read's description is organized around four things: **capability declaration / pagination triggers / multimodal hints / anti-waste prohibitions**.

**Full permission declaration**

> Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid.

This trains Claude **not to question user-provided paths**, not to hesitate about "can I read this file?" Trust the user + trust the tool, execute directly. This eliminates Claude's "excessive caution" tendency.

**Absolute path hard constraint**

> The file_path parameter must be an absolute path, not a relative path

Key word **must be** — hard requirement. Claude Code is an agent that operates across sessions and across CWDs; relative paths become ambiguous in different contexts: Claude thinks CWD is `~/project`, but it's actually `~/project/src`. Forcing absolute paths removes CWD dependency — **every Read call is self-descriptive**.

**Pagination trigger condition**

> When you already know which part of the file you need, only read that part. This can be important for larger files.

This isn't a hard rule; it's an **optimization suggestion** — reminding Claude "you don't need to read from the beginning every time." It trains Claude to develop a "read on demand" instinct.

**Multimodal capability declaration**

> This tool allows Claude Code to read images (eg PNG, JPG, etc). When reading an image file the contents are presented visually as Claude Code is a multimodal LLM.

Key phrase **presented visually** — explicitly telling Claude: images aren't converted to text descriptions; they **enter your visual understanding directly**. This prompt builds Claude's instinct that "Read image = I can see it," not "Read image = I read an alt description."

**PDF pagination enforcement**

> For large PDFs (more than 10 pages), you MUST provide the pages parameter to read specific page ranges (e.g., pages: "1-5"). Reading a large PDF without the pages parameter will fail. Maximum 20 pages per request.

Key words **MUST / will fail** — hard block. Same design philosophy as Edit's Read-first requirement: **non-compliant calls are disallowed, rather than allowed with erroneous results**.

**Social instruction for handling screenshots**

> You will regularly be asked to read screenshots. If the user provides a path to a screenshot, ALWAYS use this tool to view the file at the path. This tool will work with all temporary file paths.

This is **social behavior training** — explicitly telling Claude "when users give you a screenshot path, just read it." It prevents Claude from hesitating with "the user gave me a path — should I read it?"

**Empty file behavior contract**

> If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.

This prompt lets Claude know in advance that **empty files won't return an empty string**, preventing it from mistakenly thinking "the tool broke" when seeing a reminder. This is a design of **replacing silent failure with helpful error messages**.

**Anti-waste (don't verify)**

> Do NOT re-read a file you just edited to verify — Edit/Write would have errored if the change failed, and the harness tracks file state for you.

This one is particularly interesting — it's **overriding one of Claude's instinctive tendencies**. Claude may have learned the programming instinct of "verify after modifying code" during training, but in Claude Code verification is wasteful because the harness already tracks state. This prompt explicitly turns off this redundant behavior.

#### 3 · Field-Level Description

Read has 4 fields:

- `file_path` — **absolute path** to the target file (relative paths not accepted)
- `offset` — which line to start reading from (optional, default 0)
- `limit` — maximum number of lines to read (optional, default 2000)
- `pages` — page range for PDF (e.g., `"1-5"`, only applies to PDFs)

**Several key design points**:

**The dual role of line number + tab prefix**

When Read returns content, each line is prefixed with `line number + tab + actual content`. This design kills two birds with one stone:

- **Gives Claude a coordinate system** — Claude can say "the bug on line 42" and the user can locate it
- **Creates a trap for Edit** — the prefix isn't actual file content; it must be stripped when Editing (discussed in detail in the next article on Edit)

The line number prefix is **the same thing** serving both "perception-friendly" and "operation trap" roles. This is why Edit's prompt dedicates an entire paragraph warning about this trap — **it's a necessary output of Read and a necessary filter for Edit**.

**Pagination mechanism: offset + limit**

Why default to 2000 lines?

- Claude's single-turn context is limited; stuffing in an entire large file would blow it up
- In most scenarios, only a section of the file is needed (e.g., a specific function)
- It forces Claude to learn "read on demand" rather than "read everything"

The existence of pagination also implies a philosophy: **Claude doesn't need to see an entire file to modify a section of code** — just as a human programmer opening a 5000-line file just scrolls to the verifyToken function area.

**Unified multimodal entry point**

Read isn't a tool that "can only read text." Images / PDFs / notebooks all go through the same tool call:

- **Images (PNG/JPG/GIF/WebP)** — runtime detects the extension and feeds the image to Claude as visual tokens, not text description
- **PDF** — runtime extracts text (forced page specification for documents over 10 pages to prevent blowup), embedded images are preserved
- **Jupyter notebook** — cell structure, code, output, Markdown all returned

**This is a "unified perception layer" design** — Claude doesn't need to learn different tools for different formats; everything is Read. The runtime is responsible for normalizing various formats into input Claude can consume.

**Harness collaboration with Edit**

One of Read's hidden responsibilities is **establishing tracking state for Edit**. The runtime records: "which files Claude has Read in this session." When Claude calls Edit, the runtime checks this record — if the file hasn't been read, it throws an error.

This collaboration makes Read not just "reading a file" but a **"perception commitment"** — Claude commits that "I know what this file currently looks like." This commitment is consumed by Edit, forming the complete trust chain of "modifying code based on real state."

#### 4 · Schema Validation Rules

Read's schema layer has almost no hard constraints, except one:

| Field | Type | Constraint |
|---|---|---|
| `file_path` | string | Required, must be absolute path |
| `offset` | integer | Optional, default 0 |
| `limit` | integer | Optional, default 2000 |
| `pages` | string | Optional, **required** when PDF > 10 pages |

**Default values are Read's core design** — the 2000-line default lets Claude land in the "sufficient but not explosive" sweet spot with default values. The PDF > 10 pages enforcement of pages is the only hard block, preventing large documents from consuming the entire context in one shot.

---

### Division of Labor with Neighboring Tools

Read contrasts with the tools from the previous four articles:

| Dimension | Three Interaction Primitives | Grep + Glob | Read |
|---|---|---|---|
| Role | Collaborative alignment | Locating coordinates | Perceiving the external world |
| Frequency | Key decision points | High-frequency daily use | High-frequency daily use |
| Input | Structured (Ask) / empty (both PlanModes) | pattern (no path knowledge needed) | file_path + pagination (path knowledge needed) |
| Output | User decisions | Path lists / matching lines / counts | Complete file content |
| Conservative bias | "When uncertain, plan" | "Search on demand before full reading" | "When uncertain, just read it" |

**Grep+Glob to Read trust chain** — a **smooth handoff** from search to perception:

- Grep/Glob output **coordinates** (file paths + optional line numbers), but only include matching line fragments
- Read consumes these coordinates — picking out files that truly need deeper examination, pulling complete context
- Read establishes **perception commitment**, handed off to Edit / Write downstream

**The relationship between Read and Edit** — the tightest tool partnership in Claude Code:

- **Perception commitment**: Read is the commitment "I know what this file currently looks like"
- **Operation basis**: Edit consumes this commitment, performing precise replacements based on accurate content in Claude's memory
- **Shared trap**: the line number prefix is Read's necessary output and simultaneously Edit's necessary filter
- **State machine collaboration**: harness layer tracks Read state -> validates during Edit -> errors if missing

If AskUserQuestion / EnterPlanMode / ExitPlanMode form a **collaborative alignment pipeline** from three primitives, then Grep+Glob -> Read -> Edit / Write is the **complete execution pipeline** — locate, perceive, execute, sharing a common harness tracking state, combining to form the complete closed loop of "safely modifying code."

---

### Summary

Read's elegance lies not in its "file reading" functionality itself, but in how its signal distribution **concentrates entirely on the tool-level description and field design**:

- **Naming** — minimalist, one verb covering multimodal (text / images / PDF / notebooks)
- **Tool-level description** — lengthy, 8 constraints stringing together "capability declaration, pagination triggers, multimodal hints, anti-waste prohibitions"
- **Field-level description** — 4 fields but each with non-trivial design (absolute path / line number dual role / pagination / PDF pages)
- **Schema validation** — minimalist, only one hard block: "PDF > 10 pages requires pages"

Read's most unique quality is that it's a **perception primitive** — replacing "guessing / memory / hallucination" with "knowing," and **committing** that "knowing" to downstream Edit / Write in the form of harness tracking state. This commitment is the **trust foundation** of the entire execution primitive system.

The next article continues with [Edit](edit.md) — examining how the perception commitment established by Read gets consumed by Edit into precise string replacements one after another.
