# 03 · Anthropic API Memory Tool: From Date-Versioned Protocol to a Client-Side Memory Filesystem

> This article still belongs to the **Memory research series**, answering "how does information survive across sessions." But `memory_20250818` is itself a tool, so the body follows the Tools series' breakdown method: **purpose → concrete example → trigger conditions → technical implementation → prompt / schema → summary**.
>
> The companion article [02 · Auto Memory: From a Single Correction to MEMORY.md](02-auto-memory.md) covers Claude Code's own product-internal Auto Memory. This article covers the general-purpose Memory Tool provided by the Anthropic Messages API. The two solve similar problems, but they are not the same implementation.

## TL;DR

| Dimension | Conclusion |
|---|---|
| **What it is** | A tool for which Anthropic provides the schema, and the client is responsible for execution |
| **Request config** | `{"type":"memory_20250818","name":"memory"}` |
| **Date suffix** | `20250818` is the tool protocol version, not the memory creation date |
| **Invocation** | Claude emits a `tool_use`; the application executes it and returns a `tool_result` |
| **Command set** | `view` / `create` / `str_replace` / `insert` / `delete` / `rename` |
| **Storage location** | Controlled by the client — can map to disk, a database, or object storage |
| **Path namespace** | The paths the model sees all start from `/memories` |
| **Cross-session key** | Different sessions must connect to the same persistent store |
| **Does Claude Code use it** | The research version v2.1.220 does not use this API; it has its own Auto Memory |

---

## 1 · Purpose — Giving the Agent a Filesystem It Can Use Across Sessions

What the Memory Tool solves is not "how much can the current conversation remember," but:

> After the current session ends, which pieces of information can be preserved, and re-read the next time a session starts?

It provides four core capabilities:

1. **Cross-session persistence** — task progress, user preferences, and project decisions don't have to stay resident in messages forever.
2. **On-demand reading** — Claude looks at the directory first, then reads the relevant files; there's no need to stuff the entire history into context up front.
3. **Model-managed maintenance** — Claude can decide on its own when to create, modify, move, or delete memory files.
4. **Storage rights stay with the application** — Anthropic defines the interaction protocol, but does not persist files on the application's behalf.

This is a form of just-in-time retrieval: context only holds what's currently needed, long-term information sits outside context, and it's pulled back in via a tool call when needed.

---

## 2 · A Concrete Example — A New Session Reads Support Rules First

Suppose a customer-service agent saved refund rules in a previous session. In the new session, the user says:

> Help me respond to this customer service ticket.

Claude doesn't need the user to paste the rules again — it first calls the Memory Tool:

```json
{
  "type": "tool_use",
  "id": "toolu_01",
  "name": "memory",
  "input": {
    "command": "view",
    "path": "/memories"
  }
}
```

The application maps `/memories` to its own storage and returns the directory listing:

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01",
  "content": "1.5K\t/memories/customer_service_guidelines.xml\n2.0K\t/memories/refund_policies.xml"
}
```

Claude finds the relevant file and issues another read:

```json
{
  "type": "tool_use",
  "id": "toolu_02",
  "name": "memory",
  "input": {
    "command": "view",
    "path": "/memories/customer_service_guidelines.xml"
  }
}
```

The application returns the file contents, and Claude uses it to answer the current ticket. The full chain looks like this:

```text
User raises a task
    ↓
Claude calls memory.view
    ↓
Application reads its own persistent store
    ↓
Application returns tool_result
    ↓
Claude continues the task using the retrieved memory
```

The important thing here isn't "one more file-reading tool" — it's that **the new session is still connected to the old storage**. If the application created a fresh in-memory dictionary for every session, this tool would appear to work, but Memory wouldn't actually be implemented.

---

## 3 · Trigger Conditions — When It Should Be Used

### Good fit

- The agent runs across multiple sessions and needs to preserve task progress or long-term decisions.
- You don't want to keep the entire history resident in context, and prefer on-demand reads instead.
- The application needs to control where data is stored, encryption, tenant isolation, and deletion policy itself.
- You want to reuse a memory file-operation protocol Claude is already familiar with, instead of designing a new tool schema from scratch.

### Not necessarily needed

- The information is only valid for the current session — leaving it in messages is enough.
- The content is small and needs to be visible on every call anyway — injecting it into the system prompt or a fixed context block is simpler.
- The application already has a mature database-retrieval tool that only needs precise queries, not a model-maintained file tree.
- You're using Claude Code's built-in Auto Memory — it runs its own `MEMORY.md` and extraction pipeline, and doesn't depend on `memory_20250818`.

### Boundaries with neighboring mechanisms

| Mechanism | Problem it solves | When information enters context |
|---|---|---|
| **messages** | Conversation history for the current session | Resent on every call |
| **Compaction** | Current history is too long | Long history replaced by a summary |
| **Memory Tool** | Information survives across sessions | Enters when Claude proactively calls `view` |
| **Claude Code Auto Memory** | Claude Code automatically deposits long-term information | `MEMORY.md` loaded at session start; topic files read on demand |
| **Ordinary retrieval tool** | Look up facts from a business database | Enters once a query hits |

---

## 4 · Technical Implementation — A Standard Tool Loop

### 4.1 · A One-Line Tool Definition

The request's `tools` array only needs to add:

```json
{"type": "memory_20250818", "name": "memory"}
```

These two fields carry different responsibilities:

- **`name: "memory"`** is the tool name. The `tool_use.name` Claude emits is `memory`.
- **`type: "memory_20250818"`** selects the protocol version of this tool.

`20250818` is a date-based version identifier. When the schema, behavior, or model support scope of an Anthropic-provided tool changes, a new date version can be published while the old one is kept around, so existing integrations aren't silently broken.

You can think of it this way:

> `name` determines which tool Claude calls; `type` determines which version of the interface the client and API communicate over.

### 4.2 · Which Category of Tool It Belongs To

Anthropic tools fall into three categories:

| Type | Who defines the schema | Who executes it |
|---|---|---|
| **User-defined tool** | Application | Application |
| **Anthropic-schema client tool** | Anthropic | Application |
| **Server tool** | Anthropic | Anthropic's servers |

The Memory Tool belongs to the second category:

- Anthropic defines the name, input schema, and model usage habits.
- The application does not need to declare an `input_schema`.
- Claude emits a standard `tool_use`.
- The application performs the file operation and returns a `tool_result`.

So it is neither an ordinary custom tool, nor a server tool where Anthropic hosts the storage for you.

### 4.3 · Six Commands

| Command | Purpose | Key parameters | Key constraints |
|---|---|---|---|
| `view` | List a directory or read a file | `path`, optional `view_range` | Long text is paginated; text carries line numbers; images can also be read |
| `create` | Create a file | `path`, `file_text` | What happens if the file already exists is left to the implementation |
| `str_replace` | Precise text replacement | `path`, `old_str`, optional `new_str` | `old_str` must match verbatim and uniquely |
| `insert` | Insert by line | `path`, `insert_line`, `insert_text` | `0` means the start of the file |
| `delete` | Delete a file or directory | `path` | The `/memories` root cannot be deleted |
| `rename` | Move or rename | `old_path`, `new_path` | The root cannot be renamed; the target must not conflict |

This interface isn't like a KV store's `get`/`set` — it's more like a scaled-down text editor. Claude can `view` first, then use `str_replace` to precisely edit a local portion, without rewriting the entire memory file each time.

### 4.4 · Why the `view` Format Is So Strict

When reading text, the official recommendation is to prefix each line with a fixed-width line number:

```text
     1	Hello World
     2	This is line two
    10	Line ten
```

The core format is:

- Line numbers start at 1.
- Width is 6, right-aligned.
- A tab separates the line number from the body text.
- Long files are paginated via `view_range`.

This isn't for visual formatting — it gives subsequent edits a stable coordinate system. Only once Claude sees precise text can it generate a unique `old_str` to complete a replacement.

### 4.5 · Storage Is Entirely Up to the Client

The `/memories` the model sees is just a logical prefix. The application can map it to:

- A local filesystem
- A per-user database namespace
- Object storage such as S3 / R2
- Enterprise storage with encryption and auditing

Truly achieving cross-session persistence requires satisfying three conditions:

1. Different sessions of the same user route to the same store.
2. Data survives process or container restarts.
3. Concurrent sessions modifying the same file have a versioning or locking mechanism.

Some Anthropic SDKs provide Memory Tool helpers and local-filesystem examples, but the tool itself being GA doesn't mean every SDK helper has left the beta namespace.

### 4.6 · Security Boundary

The Memory Tool hands paths generated by the model to the application for execution, so the client must bear the responsibility for filesystem security.

The most dangerous mistake is checking only:

```python
path.startswith("/memories")
```

because `/memories/../../secrets.env` still passes that check. The correct approach is:

```python
from pathlib import Path

MEMORY_ROOT = Path("/var/data/user_memory").resolve()

def resolve_memory_path(path: str) -> Path:
    if not path.startswith("/memories"):
        raise ValueError("Invalid path")

    relative = path[len("/memories"):].lstrip("/")
    resolved = (MEMORY_ROOT / relative).resolve()
    resolved.relative_to(MEMORY_ROOT)
    return resolved
```

A production implementation also needs to handle, at minimum:

- URL-encoded or other forms of path traversal
- A second check before sensitive information gets written
- Limits on single-file size, file count, and read length
- Auditing or a recycle bin for delete and overwrite operations
- Multi-user data isolation
- Concurrent write conflicts

The model will usually try to avoid saving sensitive data on its own, but that is not a security boundary. The real, strong guarantee has to be provided by the client.

---

## 5 · Prompt and Schema — How the Tool's Shape Teaches the Model to Work

### 5.1 · Why You Can't Customize the Name and Schema

An ordinary tool has its `name`, `description`, and `input_schema` filled in by the developer. The Memory Tool doesn't need that, because Anthropic has already defined and trained this interface.

This means:

- `name` must be `memory`.
- `type` must select a supported Memory Tool version.
- Parameter names and command structure are provided by Anthropic.
- The application's main degree of freedom is in the **execution and storage layer**, not the tool's shape.

The benefit of a fixed interface is that the model doesn't need to relearn some ad hoc "memory protocol" invented by each application; the cost is that the application has to adapt to an existing schema.

### 5.2 · The API Automatically Injects Behavioral Guidance

Once the Memory Tool is enabled, the API supplements the model with a memory protocol. The most central line is:

> ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.

This guidance also asks the model to assume context could be interrupted at any time, and to record progress promptly. It shapes two behavioral habits:

1. **Read first at the start of a new session** — restore prior state before continuing the task.
2. **Write promptly during the task** — don't wait until everything is finished to save, to avoid losing intermediate progress on interruption.

The protocol itself doesn't enforce at runtime that "the first step must be `view`," but the prompt nudges the model toward doing so. This is exactly the design pattern that recurs throughout the Tools series: **use the prompt to shape the correct path first, then let the client hold the hard boundary.**

### 5.3 · The Returned String Is Also a Soft Protocol

The application is free to structure its `tool_result` text, but the officially recommended directory format, error templates, and success messages are not arbitrary copy. Claude is familiar with these patterns, and seeing responses like "path does not exist" or "match is not unique" makes it more likely to take the correct recovery action.

So when customizing tool results, the safer approach is:

- Keep the core official semantics and structure.
- Put custom error codes, trace IDs, and similar details at the end.
- Keep user-facing localized copy separate from the tool result meant for the model.

Here, the tool result is not just an execution outcome — it's also an input to the model's next decision.

### 5.4 · Three Easily Misunderstood Design Points

#### `create` doesn't necessarily mean "create only"

The model may interpret `create` as "create or overwrite," while a reference handler might return an error if the file already exists. The client must explicitly choose a semantic: allow overwrite, reject overwrite, or auto-backup before overwriting. The worst outcome is ambiguous semantics, where the same request produces different results on different backends.

#### `view` doesn't only read text

The memory directory may contain `.jpg`, `.jpeg`, `.png` files. If an application claims to support the full official behavior, it needs to be able to return an image content block, rather than assuming every file can be UTF-8 decoded by default.

#### Error text can be customized, but shouldn't be arbitrary

Claude can understand natural-language errors, but the closer the error stays to a familiar structure, the more stable error recovery becomes. The protocol allowing freedom doesn't mean every phrasing has equal effect.

---

## 6 · Back to the Memory Theme — Its Impact on Context and Product Design

### 6.1 · Memory, Context Editing, and Compaction

A long-running agent usually needs three mechanisms at once:

- **Context Editing** cleans up old tool results that are no longer needed.
- **Compaction** produces a summary as the history approaches the context window ceiling.
- **Memory Tool** preserves information that must survive across summaries and across sessions.

They operate on different timescales:

```text
temporary results from the last few turns ── Context Editing
long history within the current session ── Compaction
long-term information spanning multiple sessions ── Memory Tool
```

Memory files shouldn't become a dumping ground where "the entire history gets copied over again." What belongs there is long-term decisions, task progress, stable preferences, and whatever is necessary to resume the task next time.

### 6.2 · Why Claude Code Doesn't Use It

In the Claude Code v2.1.220 source studied for this article, no `memory_20250818` tool definition was found. Claude Code's Auto Memory is a separate product implementation:

| Dimension | API Memory Tool | Claude Code Auto Memory |
|---|---|---|
| **Read entry point** | Claude proactively calls `memory.view` | `MEMORY.md` index injected at session start, details read on demand |
| **Who writes** | The current model writes autonomously via the tool | The main agent writes directly, or an extraction fork fills gaps |
| **Edit interface** | Six memory commands | Claude Code's Read / Edit / Write and the `/memory` UI |
| **Storage design** | Decided by the application | Claude Code prescribes the directory and file structure |
| **Product capability** | A general-purpose protocol primitive | Product capabilities such as private, team, and agent scope |

Verification clues include:

- No `memory_20250818` literal appears in the source.
- `src/tools/` has no MemoryTool.
- Session Memory uses the filesystem API directly.
- Memory extraction uses Claude Code's own Read / Edit / Write.

So **the API Memory Tool and Claude Code Auto Memory should not be conflated**. The former gives agent developers a general-purpose protocol; the latter is a memory system Claude Code built around its own product experience.

### 6.3 · Two Paths for Building Your Own Agent

If you're building your own agent on top of the Anthropic API, there are two main choices:

- **Adopt the Memory Tool** — reuse the ready-made schema and model behavior, and implement the client-side handler, persistence, and security boundary.
- **Build your own memory system** — decide for yourself when to extract, how to index, how to inject into context, how to garbage-collect, and whether to provide a manual editing interface.

The former gets you closer to "usable cross-session memory, quickly"; the latter suits systems that need complex scopes, team collaboration, approval flows, and productized management.

---

## 7 · Summary — Tool Is the Implementation Form, Memory Is the Functional Theme

The most valuable takeaway from the Memory Tool isn't the six commands — it's the division of labor:

- Anthropic fixes the tool schema and model behavior.
- Claude decides when to read and write.
- The client is responsible for execution, persistence, and security.
- Memory stays outside context, and only enters via the tool when needed.

### Design trade-offs

1. **Client-side storage, not Anthropic-hosted** — stronger data control, but the application bears the security and operational responsibility.
2. **A file tree, not a simple KV store** — more expressive, but the interface and concurrency control are more complex.
3. **Prompt shapes behavior, client enforces the hard constraints** — the model handles judgment, the program guards the bottom line.
4. **A date-versioned protocol** — the interface can evolve without breaking existing integrations.

### Common anti-patterns

- Checking the path with only `startswith("/memories")`.
- Storing memory in session-local memory, so it all disappears on process restart.
- Skipping user isolation and concurrency control.
- Writing the entire history into Memory, recreating an unboundedly growing context by another name.
- Relying solely on the model to avoid saving sensitive information.
- Customizing the schema or error text while ignoring the protocol shape the model already knows well.

### Evolution signals

- Claude frequently scans irrelevant directories → add indexing, or redesign the file structure.
- The same information gets written repeatedly → add deduplication, or a dedicated extraction pipeline.
- File count keeps growing → add retention limits, capacity limits, and GC.
- Team sharing, permissions, and approval are needed → evolve from the general-purpose Memory Tool to a product-grade memory system.

In one sentence:

> **`memory_20250818` is a date-versioned tool protocol; through the shape of a tool, it turns client-controlled storage into cross-session memory that Claude can maintain autonomously.**

The next article, [04 · Sub-agent Memory: From Agent Type to a Three-Tier Persistent Directory](04-subagent-memory.md), returns to Claude Code's product internals, looking at how sub-agent memory persists across user / project / local scopes.

---

## References

### Anthropic official

- [Memory Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- [Tool reference — Anthropic-provided tools and date versioning](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference)
- [Tool use overview](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)
- [Context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing)
- [Compaction](https://platform.claude.com/docs/en/build-with-claude/compaction)
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

### SDK examples

- [Python SDK memory example](https://github.com/anthropics/anthropic-sdk-python/blob/main/examples/memory/basic.py)
- [TypeScript SDK memory example](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/examples/tools-helpers-memory.ts)
- [C# SDK memory example](https://github.com/anthropics/anthropic-sdk-csharp/tree/main/examples/MemoryToolExample)
- [Java SDK memory example](https://github.com/anthropics/anthropic-sdk-java/blob/main/anthropic-java-example/src/main/java/com/anthropic/example/BetaMemoryToolExample.java)

### Claude Code v2.1.220 source locations

- `src/services/SessionMemory/sessionMemory.ts` — Session Memory uses the filesystem API directly
- `src/services/extractMemories/extractMemories.ts` — the extraction fork uses Read / Edit / Write
- `src/commands/memory/memory.tsx` — the `/memory` manual editing UI
- `src/tools/` — no MemoryTool definition

### Related articles in this series

- [02 · Auto Memory: From a Single Correction to MEMORY.md](02-auto-memory.md) — Claude Code Auto Memory
- [05 · Memory Extraction Pipeline: From Turn End to a Restricted Fork](05-extraction-pipeline.md) — the full flow of the extraction fork
- [04 · The Six Siblings of Compaction: From Manual to Everywhere](../context-management/04-compaction.md) — Compaction's impact on context
