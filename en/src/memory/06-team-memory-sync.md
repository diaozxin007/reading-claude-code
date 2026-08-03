# 06 · Team Memory Sync · From Local Dual Directories to Server-Side Sync

> **TL;DR**: Team memory is not `.claude/team-memory/` committed into git. On the local machine it lives under the `team/` subdirectory of the auto-memory path, uses the GitHub remote's `owner/repo` as the server-side scope, and syncs through the Anthropic API — pulled at session start, pushed on a debounce after file changes. Private and team memory each have their own `MEMORY.md`; the classification prompt decides which side a note is written to, and the sync layer only handles transport, not semantic re-judgment.

The previous article, [05 · Memory Extraction Pipeline · From End-of-Turn to a Restricted Fork](05-extraction-pipeline.md), stopped at "the memory file gets written to disk." If the piece of information isn't a personal preference but a testing constraint every project member should know, the next step isn't a git commit — it's entering team memory sync.

## Dual Directories · Local Form Is Split First

Once team memory is enabled, the same project has two roots:

```text
~/.claude/projects/<project>/memory/
├── MEMORY.md                 # private index
├── user-role.md
├── feedback-response.md
└── team/
    ├── MEMORY.md             # team index
    ├── feedback-testing.md
    └── project-release.md
```

The team path is not a directory inside the repo — it's `join(getAutoMemPath(), 'team')`. It's dependent on auto memory, so when auto memory is disabled, team memory is necessarily disabled too. See `memdir/teamMemPaths.ts:66-94`.

This corrects a common misreading: "team" denotes shared semantics, not direct sharing through a git worktree. The GitHub remote's only job is to supply the server with a repo identity.

## Scope Is a Content-Classification Problem, Not Something the Sync Layer Guesses

The combined prompt writes scope into four memory types:

| Type | Scope tendency |
|---|---|
| `user` | Always private |
| `feedback` | Private by default; only clear project-level conventions go to team |
| `project` | Private or team, strongly biased toward team |
| `reference` | Private or team, depending on whether the link is useful to the whole project |

When private feedback conflicts with team feedback, it should either not be saved, or the override should be explicitly recorded. This rule isn't a hard constraint enforced by the filesystem — it's a semantic constraint the prompt places on the model. See `memdir/memoryTypes.ts:37-106`.

Once a scope is chosen, saving is still a two-step process: the topic file is written into the corresponding directory, then the `MEMORY.md` in that same directory is updated. Both indexes make their way into session context, but team content is explicitly forbidden from holding sensitive data. See `memdir/teamMemPrompts.ts:17-99`.

## Sync Target · GitHub Repo Identity + Anthropic Server

The team sync service's API is keyed on the GitHub `owner/repo`:

```text
GET /api/claude_code/team_memory?repo=<owner/repo>
PUT /api/claude_code/team_memory?repo=<owner/repo>
```

Only authenticated org members sharing the same repo see each other's data. Without a `github.com` remote, the watcher simply never starts; a non-GitHub remote doesn't fall back to local git sync — it just has no server scope. See `services/teamMemorySync/index.ts:1-24` and `services/teamMemorySync/watcher.ts:231-265`.

## Session Start · Server Wins First

The startup flow is:

1. Check the build feature flag, the runtime gate, OAuth, and the GitHub remote;
2. Create an independent `SyncState`;
3. Pull from the server first;
4. Only start the local directory watcher after the pull finishes.

The watcher is deliberately delayed so that files landed by the pull don't turn around and trigger a pointless push. Even if the server has no content, an empty directory must still be created and the watcher started — otherwise the first team memory write could fall into a bootstrap dead zone. See `services/teamMemorySync/watcher.ts:245-304`.

The per-key conflict rule for pulls is **server wins**: remote content overwrites the local file of the same name. There's no three-way merge here. Team memory is meant for short, unambiguous rules and background — not a large document multiple people edit at once.

## Local Changes · Watcher + Explicit Notification, Belt and Suspenders

The directory uses `fs.watch({recursive:true})`, which covers subdirectories. Change events go through a debounce before triggering a push; the PostToolUse path for FileWrite/Edit also calls an explicit notification, to guard against the watcher missing an event on the same tick it starts, or the platform coalescing rapid writes. Both paths ultimately just reset the same debounce timer. See `services/teamMemorySync/watcher.ts:147-228,307-319`.

A push doesn't upload every file each time. `SyncState.serverChecksums` stores a content hash for each key on the server, and only keys whose local hash differs from the known server checksum get uploaded. The server behaves as an upsert: keys not included in this payload are left untouched. See `services/teamMemorySync/index.ts:14-24,100-109`.

## Why Deletion Doesn't Sync

The server API's current semantics have no delete propagation:

- Deleting a local file does not delete the server-side key;
- The next pull writes it right back to local disk.

This is a conservative, data-protective choice, but it also means "forgetting a piece of team memory" can't be done with a local `rm`. The sync layer would rather resurrect a piece of deleted content than let one accidental deletion propagate across the whole organization. See `services/teamMemorySync/index.ts:14-20`.

## Size, Conflicts, and Failure

The sync implementation carries several further engineering boundaries:

- A single entry has a local pre-check cap of 250KB;
- The PUT body targets roughly 200KB and is split into sequential batches;
- There's no hardcoded cap on entry count — it's learned from a structured 413 returned by the server;
- ETag/checksum conflicts get a limited number of retries;
- Graceful shutdown only has a short budget, so push is best-effort.

See `services/teamMemorySync/index.ts:71-91` and `services/teamMemorySync/watcher.ts:321-340`.

Team memory is not a reliable message queue. It provides background sync across members, but it doesn't promise the very last write at process exit will always succeed.

## Path Safety · Server Keys Aren't Trusted Either

The server returns relative keys, and the client still has to guard against traversal. The checks cover:

- Null bytes;
- URL-encoded `../`;
- Traversal formed after Unicode NFKC normalization;
- Windows backslashes;
- Absolute paths;
- Directory escapes after `resolve()`;
- Symlink and dangling-symlink escapes.

Symlinks in particular: a string-prefix check alone can't stop `team/link → ~/.ssh`. The source resolves the realpath of the "deepest existing ancestor," then confirms that real path is still inside the real team directory. See `memdir/teamMemPaths.ts:17-63,96-171,222-283`.

## Who Wins When Private and Team Conflict

There are two kinds of "conflict" that shouldn't be conflated:

1. **Semantic conflict**: private feedback contradicts a team convention. The memory prompt requires either avoiding the save or explicitly recording an override.
2. **Transport conflict**: the local team file and the server differ on the same key. On pull, server wins; on push, checksum/ETag detects it and retries.

The former needs the model to understand content; the latter only deals with byte versions. Stuffing semantic merging into the sync service would force the infrastructure to understand Markdown rules — which is exactly why the two layers are kept deliberately separate.

## Decisions · Anti-Patterns · Evolution Signals

### Decisions

- The dual-directory split partitions private/team at write time, so the sync layer never has to read private content and then decide.
- Repo identity comes from the GitHub remote; content is synced by the Anthropic server.
- Server-wins pull plus non-propagated deletes favors avoiding data loss over automatic merging.
- Checksum deltas keep the upload cost of everyday small edits low.

### Anti-Patterns

- Assuming the team directory should be `git add`-ed — it lives in the user's config directory, not the repo worktree.
- Putting personal communication preferences into team memory — they'd propagate to every project member.
- Writing secrets into team memory and relying on the sync layer to catch them — neither the prompt nor secret scanning is a substitute for a real confidentiality boundary.
- Assuming a local delete means the remote has forgotten too — the next pull resurrects it.

### Evolution Signals

- Frequent server-wins overwrites on the same filename → topic granularity is too coarse, or multiple people are editing at once.
- Pushes frequently split into many batches → memory content has ballooned into a document library.
- Growing numbers of private overrides → the team convention isn't accurate enough, or scope was chosen wrong.
- A need to share across a non-GitHub repo → the current repo-identity binding becomes a product limitation.

## Summary

Team memory's real architecture is: **the model routes by scope → local private/team dual directories → GitHub repo identity → Anthropic server pull/push**. It doesn't have all members co-editing a single git file — instead it splits semantic classification and byte-level sync into two layers. That way the privacy boundary is decided before the write happens, and the sync layer only has to deal with versions, batching, conflicts, and safety.

The next article, [07 · Managed CLAUDE.md · The Enterprise Control Layer](07-managed-claude-md.md), turns to the other side of organizational power: teams can share experience, but admins still need a layer of mandatory instructions that neither a project nor a user can override.

## References

- Claude Code source: `memdir/teamMemPaths.ts:17-94,96-291`
- Claude Code source: `memdir/teamMemPrompts.ts:17-99`
- Claude Code source: `memdir/memoryTypes.ts:37-106`
- Claude Code source: `services/teamMemorySync/index.ts:1-109`
- Claude Code source: `services/teamMemorySync/watcher.ts:147-340`
- Claude Code source: `services/teamMemorySync/secretScanner.ts`
- Claude Code source: `services/teamMemorySync/teamMemSecretGuard.ts`
