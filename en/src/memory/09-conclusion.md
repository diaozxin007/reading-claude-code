# 09 · Closing · From a Single Piece of Information to Five Memory Carriers

> **TL;DR**: Memory isn't one feature — it's a set of carriers with different time scales, authors, and sharing scopes. First ask "can this still be derived from project state in the future?" Then ask "is this an explicit rule or a collaborative observation?" Finally ask "does it belong to an individual, a project, a specific agent type, or a team?" Picking the wrong carrier is more dangerous than not recording anything at all: transient state pollutes long-term behavior, personal preferences leak into the team, and derivable facts quietly go stale.

The previous article, [08 · After Compaction · Which Memories Come Back Automatically](08-post-compaction.md), showed that persistent files and what's currently resident in context are two different things. This closing article doesn't add a new mechanism — it answers one practical question: **when you have a piece of information in hand, where should it be committed to?**

## One Overview Diagram · Memory ≠ Context

```text
current messages[]
  │ useful only for the current session
  ├──────────────→ task / plan / stays in the conversation
  │
  │ still useful across sessions
  ▼
can it be re-derived from code, git, or config?
  ├─ yes → don't record it · look it up again next time
  └─ no
      │
      ├─ explicitly stated by user/organization → CLAUDE.md family
      ├─ observed by Claude during collaboration → auto memory
      ├─ experience of a specialized agent type → agent memory
      ├─ background shared by the whole project team → team memory
      └─ storage a general-purpose API app builds itself → memory_20250818
```

The first cut is always "can it be derived." Code structure, function signatures, git history, and directory layout should be read again; copying them into memory just creates a second copy that will eventually go stale.

## Five Carriers Are Not Five Tiers

This series has laid out the full landscape with five carriers, but they aren't an inheritance stack going from low to high.

| Carrier | Who produces it | Sharing scope | How it's activated | Suitable content |
|---|---|---|---|---|
| CLAUDE.md family | user/team/admin | user, project, local, nested, managed | at session start / on path reach | explicit rules and instructions |
| auto memory | main agent + extraction agent | current user and project | index at start + read topics on demand | preferences, feedback, non-derivable background |
| API memory tool | Claude inside an application | defined by the application itself | `view` tool | cross-session workspace |
| agent memory | a specific agent type | user/project/local scope | agent spawn | specialized role experience |
| team memory | organization members and agents | members of the corresponding GitHub repo's org | pull at start + dual index | shared team conventions and background |

Sub-agent memory and team memory aren't simply a "pass-through layer" or a "sync layer": both have their own persistent directories, prompts, and lifecycles. The newer source in particular shows that team memory syncs through a server-side API, not through git files inside the repo.

## Decision Question 1 · Is This a Rule or an Observation

### Explicit rule → CLAUDE.md

"Use the four-part format for commit messages," "only modify files you're responsible for," "this repo uses pnpm" — these are intentions expressed by the user. They should go into CLAUDE.md or `.claude/rules/`, because the user needs authoritative text that's visible, reviewable, and directly editable.

### Collaborative observation → auto memory

"The user is a senior Go engineer but new to React," "the real-database test approach was confirmed to work last time," "the external background of this incident isn't in git" — these are observations formed through interaction, and fit auto memory.

A useful promotion rule: when the same piece of feedback has been confirmed repeatedly by the user and has become a stable project norm, it should be **promoted** from private memory to CLAUDE.md or team memory, rather than staying permanently at the level of a model observation.

## Question 2 · Current Work or Future Collaboration

| Information | Correct carrier |
|---|---|
| "Fix A first, then run test B" | task / plan |
| "This branch still has two TODOs left" | current session, task, or handoff doc |
| "From now on all migration tests must connect to a real database" | project CLAUDE.md or team feedback memory |
| "The user doesn't like a summary repeated at the end of replies" | private feedback memory |

The temptation with memory is "it carries across sessions anyway, so writing a bit more can't hurt." In practice, short-term state is the most likely to go bad. Treating an old branch's TODO as current fact in the next session is worse than not recording it at all.

## Question 3 · Who Should See It

### Only the current user

Communication preferences, personal role, and undisclosed work background go into private auto memory. Don't default to team just because the current repo happens to be a team project.

### All project members

Background that can't be inferred from code, and that every contributor should follow, goes into team memory; if it's a mandatory rule rather than background, project CLAUDE.md fits better. The distinction between the two:

- CLAUDE.md is explicit governance text, reviewed together with the repo;
- team memory is a shared observation that accumulates continuously through collaboration and syncs via the server.

### A specific agent type

Only experience that reviewer, security-researcher, or migration agents need goes into agent memory. Then choose user/project/local scope based on whether it's cross-project general knowledge, project-shared, or private to this machine.

### Organization-level rules that can't be overridden

Compliance, security, and enterprise policy go into managed CLAUDE.md. It provides behavioral guidance; the actual hard blocking should still be carried by permission deny, sandbox, and hooks.

## Question 4 · Whether It Belongs in the General-Purpose Memory Tool

`memory_20250818` is a client-side storage primitive that the API offers to applications. Choose it only when you're building your own agent product and need the `/memories` namespace and its six file operations. Claude Code's internal auto memory doesn't reuse this tool type; conflating the two will misjudge storage responsibility and security boundaries.

The key question for the API memory tool is "how does the application persist data, isolate tenants, and prevent traversal"; the key question for Claude Code's auto memory is "how does the product classify, when does it extract, and how does it recall." The two operate at different levels.

## Information Can Migrate · It Shouldn't Be Stuck Forever at Its First Landing Point

```text
a transient fact from one conversation
  ↓ reused multiple times
private auto memory
  ↓ repeatedly confirmed and becomes project consensus
team memory / project CLAUDE.md
  ↓ becomes mandatory organizational policy
managed CLAUDE.md + enforcement
```

Reverse migration matters just as much:

- an outdated CLAUDE.md rule should be deleted, not left in place for a new rule to "override";
- a preference in team memory that only applies to one individual should be demoted to private;
- a project-specific case in agent user memory should be demoted to project/local scope;
- memory that can be reliably re-derived from code should be deleted and looked up again instead.

This isn't a side task for garbage collection — it's central to keeping the memory system trustworthy.

## A Concrete Judgment Call

Suppose the user says:

> Last quarter, mock databases caused migration tests to give false positives. From now on, all migration tests in this project must connect to a real database.

Break it into four steps:

1. Still useful in the future? Yes.
2. Can it be reliably re-derived from the current state of the code? Not necessarily — the code might not have been fully changed yet.
3. Personal preference or project convention? Clearly a project convention.
4. Needs strong governance or collaborative background? If it must be enforced, write it into project CLAUDE.md; if it's first being recorded as team experience, write it into team feedback memory, including the Why and how to apply it.

Don't write it into user memory, and don't leave it only in the current task. Which carrier to choose comes from lifecycle and audience, not from which conversation the sentence happened to appear in.

## Anti-Pattern Reference Table

| Anti-pattern | Consequence | Fix |
|---|---|---|
| Using CLAUDE.md as a log | Startup noise keeps growing | Keep only stable rules; archive history |
| Using MEMORY.md as the body text | Entry-point budget gets exhausted | Index + topic files |
| Saving derivable code facts | Creates a stale copy | grep/git/Read next time instead |
| Writing private preferences into team | Privacy leakage and behavior pollution | Keep user/feedback private |
| Writing short-term TODOs into long-term memory | Old state resurrects across sessions | task/plan/handoff doc |
| Reusing an agent type too broadly | Different roles' experience gets mixed together | Split types by responsibility |
| Treating sync as backup | Delete/conflict semantics don't match expectations | Understand server-wins and non-deleting propagation |
| Treating a prompt as enforcement | The model can still violate it | permissions/sandbox/hooks |

## Signs It's Time to Clean Up

- `MEMORY.md` approaching 200 lines → merge and promote stable rules.
- The same topic keeps getting renamed or duplicated → frontmatter description and classification have broken down.
- Frequent private/team conflicts → scope choice or team convention is unclear.
- Having to re-explain the same thing after every compact → that information never made it into the right persistent carrier, or the index/hook isn't retrievable.
- CLAUDE.md eats a lot of context on every startup → push path-specific rules down into rules/nested, and move observations out into memory.
- Agent memory conflicts across projects → user scope is too broad.

## The Series' Final Conclusion

Claude Code doesn't have a single unified "long-term brain." It splits memory into multiple reviewable files, different scopes, different triggers, and different sync protocols. The cost of doing this is more concepts and names that are easy to confuse; the payoff is that every piece of information can have a clear author, audience, lifecycle, and recovery path.

Condensed into one line:

> **The user expresses intent → CLAUDE.md; Claude records non-derivable observations → auto memory; a specialized role accumulates experience → agent memory; the team shares observations → team memory; an application developer builds their own cross-session storage → API memory tool.**

And how all these files make their way back into a 200K request takes us back to the sister series, [00 · Opening · Claude Code's 200K Ledger](../context-management/00-intro.md). Memory decides what survives across sessions; Context decides how it gets packed into the model this time around.

## References

- 00 · Discovery report · the checklist of 5 major carriers from CLAUDE.md to memories
- [01 · The CLAUDE.md Family · 5-Layer Hierarchy and 3 Mixing Patterns](01-claude-md-family.md)
- [02 · Auto Memory · From One Correction to MEMORY.md](02-auto-memory.md)
- [03 · Anthropic API Memory Tool · The memory_20250818 Client-Side Memory Primitive](03-api-memory-tool.md)
- [04 · Subagent Memory · From Agent Type to a Three-Layer Persistent Directory](04-subagent-memory.md)
- [05 · Memory Extraction Pipeline · From the End of a Turn to a Restricted Fork](05-extraction-pipeline.md)
- [06 · Team Memory Sync · From Local Dual Directories to Server-Side Sync](06-team-memory-sync.md)
- [07 · Managed CLAUDE.md · The Enterprise Governance Layer](07-managed-claude-md.md)
- [08 · After Compaction · Which Memories Come Back Automatically](08-post-compaction.md)
- Claude Code official docs: [Manage Claude's memory](https://code.claude.com/docs/en/memory)
- Anthropic API official docs: [Memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
