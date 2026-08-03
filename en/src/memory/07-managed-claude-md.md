# 07 · Managed CLAUDE.md · The Enterprise Control Layer

> Claude Code Memory Research Series · Article 07
> Following on from article 01's **functional view** of the "5-layer CLAUDE.md hierarchy," this article dives into the **offense-and-defense design view** of the **Managed layer** — how an organization enforces it, why users can't override it, and how it divides labor with hard control layers like `permissions.deny` / `sandbox`.

Article 01 walked through the CLAUDE.md 5-layer loading stack and placed Managed at the very top, dispatched with a single line: "written by an org admin, cannot be excluded." This article takes that layer apart: what file it actually lives in, what its loading path looks like, why it's immune when `claudeMdExcludes` merges across layers, and the trap most people fall into — **Managed CLAUDE.md is not a hard-block layer, it only shapes behavior.**

Assumed reader: knows what CLAUDE.md is, but has never touched `managed-settings.json`. Might be an org admin, a DevOps engineer, or just curious how enterprise deployments work.

---

## TL;DR

| Question | Answer |
|---|---|
| Where does Managed CLAUDE.md live | The `claudeMd` field inside `managed-settings.json` (a string, whose content is markdown) |
| Who can write it | **Only an org admin** (macOS: `/Library/Application Support/ClaudeCode/`, Linux: `/etc/claude-code/`, Windows: `C:\Program Files\ClaudeCode\`) — regular users have no access |
| Loading priority | **Before user CLAUDE.md** — Claude sees the control instructions first |
| Can users exclude it | No. After `claudeMdExcludes` merges across layers, managed policy is immune |
| Is it a hard-block layer | **No.** It shapes Claude's behavior; if you want a hard block you need `permissions.deny` |
| Controls commonly paired with it | `permissions.deny` (blocks tools), `sandbox` (forces sandboxing), `env` (forces environment), `forceLoginMethod`/`forceLoginOrgUUID` (forces authentication) |

---

## 1. Scenario · Why a company needs managed CLAUDE.md

A financial institution's compliance requirement: every commit must run `make lint` first, and direct pushes to main are never allowed. The DevOps lead has every engineer put this rule into a `CLAUDE.md` at the root of their own project — but a year later, an audit finds that several repos' `CLAUDE.md` files have quietly been changed to "lint is too slow, just commit first."

This is the limit of **relying on CLAUDE.md as a polite request**: the file is shared by the team, but so is the permission to overwrite it. Anyone can change it.

The organization needs a "layer users can't modify" — no matter what code an engineer pulls locally, what plugins they install, or what rules they write into a project, the line "Always run `make lint` before committing. Never push directly to main." must reach Claude's field of view first.

The official docs' own example is exactly this case (from code.claude.com/docs/en/memory, verbatim):

```json
{"claudeMd":"Always run `make lint` before committing.\nNever push directly to main."}
```

This JSON is placed by an org admin into `managed-settings.json`, which regular users can neither modify nor even read, let alone strip out via `claudeMdExcludes`. This is the whole Managed layer this article takes apart.

---

## 2. The claudeMd field inside managed-settings.json

**Location** (determined by OS):

| OS | Path |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux / WSL | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` |

All of these are **system-level paths** — writing to them requires root/admin privileges. v2.1.75+ also supports a `managed-settings.d/` drop-in directory for assembling the config.

**Format**: a string field within the JSON. The string's content is the complete markdown that becomes CLAUDE.md. Whatever rules the admin wants Claude to see, they drop straight into the string (mindful of JSON escaping — newlines become `\n`).

**Loading priority** (quoted from code.claude.com/docs/en/memory, verbatim in meaning):

> Loads before user project CLAUDE.md.
>
> Setting `claudeMd` in user, project, or local settings has no effect.

In other words, two things:
1. It's injected **before** user CLAUDE.md (from Claude's perspective: control instructions come into view first)
2. It only takes effect at the managed / policy layer — writing a `claudeMd` field at the user / project / local layer is **silently ignored**

The second point matters a lot — it means an attacker (or just a curious engineer) can't smuggle a `claudeMd` field into their own `~/.claude/settings.json` and pass it off as an organizational directive. The semantics of this field are hard-bound to the control layer.

---

## 3. The full loading priority chain

The complete 5-layer stack, top to bottom:

```
Managed  (the claudeMd field of managed-settings.json)
  ↓
User     (~/.claude/CLAUDE.md + ~/.claude/rules/*.md)
  ↓
Project  (./CLAUDE.md or ./.claude/CLAUDE.md + ./.claude/rules/*.md)
  ↓
Local    (./CLAUDE.local.md, gitignored)
  ↓
Nested   (subdirectory CLAUDE.md, loaded lazily)
```

**Each layer "stacks" rather than "overrides"** — instructions from all 5 layers go into the messages array (see the Context series, article 05, "the system-reminder channel"). In the Claude Code source, `isInstructionsMemoryType` explicitly treats User / Project / Local / Managed as all belonging to the "instructions" type (near `utils/claudemd.ts:1084`):

```ts
type === 'User' ||
type === 'Project' ||
type === 'Local' ||
type === 'Managed'
```

All four types feed into context on equal footing — it's only **in Claude's subjective perception** that managed content comes first, in a psychological sense of "more authoritative," not a parser-level "override." When there's an actual conflict, Claude has to judge for itself (say, managed says "never push to main" while local says "special approval to push today" — Claude will lean toward being conservative, but there's no code-level override mechanism for this).

Telemetry also breaks Managed out separately (near `utils/claudemd.ts:1033`):

```ts
managed_count: typeCounts['Managed'] ?? 0
```

An organization can look at its Claude Code deployment dashboard and see "how many sessions today loaded the managed layer" — which itself is a signal for compliance auditing.

---

## 4. The offense-and-defense design of claudeMdExcludes (the core section)

If the Managed layer were only "loaded first," that still wouldn't be enough for security — because Claude Code offers another field, `claudeMdExcludes`, that lets users exclude certain CLAUDE.md files. For instance, if a monorepo subdirectory's CLAUDE.md is too noisy or contains stale instructions, a user can write this into their own settings:

```json
{"claudeMdExcludes":["**/monorepo/CLAUDE.md","/home/user/monorepo/other-team/.claude/rules/**"]}
```

**Key design 1 · excludes merges across layers**

Official docs (code.claude.com/docs/en/memory, verbatim):

> Patterns are matched against absolute file paths using glob syntax. You can configure `claudeMdExcludes` at any layer: user, project, local, or policy. **Arrays merge across layers.**

In other words, if the user layer writes 3 patterns, the project layer writes 2, and the policy layer writes 1 — the effective result is the union of all 6 patterns. Any exclusion rule added at any layer counts.

This is also why the source at `utils/claudemd.ts:552` reads `getInitialSettings().claudeMdExcludes` — `getInitialSettings()` is itself the product of a cross-layer merge.

**Key design 2 · Managed is immune**

If excludes applied fairly to every layer, a user could write a single `"claudeMdExcludes": ["**/managed*"]` and directly nullify the organization's control. The official docs shut this backdoor with one line (verbatim):

> **Managed policy CLAUDE.md files cannot be excluded.**

This is a deliberate **ceiling-and-floor of power** design — excludes can strip out "noise" but not "control." In the source, `isClaudeMdExcluded()` takes the type parameter (User / Project / Local / **Managed**) into account when judging, and for the Managed type it short-circuits and directly returns false (see the combined logic of `isClaudeMdExcluded` + `processMemoryFile` at `utils/claudemd.ts:547-635`).

**Offense-and-defense summary**:

| Layer | Can it be excluded via excludes |
|---|---|
| Managed | **No** — hard-coded immunity |
| User | Yes (project/local/policy can all exclude it) |
| Project | Yes |
| Local | Yes |
| Nested | Yes (in fact this layer gets excluded most often — old CLAUDE.md files in subdirectories are frequently noise) |

---

## 5. How Managed CLAUDE.md divides labor with other control layers

In an enterprise environment, `managed-settings.json` isn't just the `claudeMd` field. The whole file is the **master switchboard of organizational control**. The official docs dedicate a section specifically to "managed CLAUDE.md and managed settings serve different roles" (code.claude.com/docs/en/memory, verbatim in meaning):

> A managed CLAUDE.md and managed settings serve different purposes.

Roughly, the division of labor looks like this:

| Purpose | Mechanism | Type |
|---|---|---|
| Block tools / commands / file paths | `permissions.deny` | Hard block |
| Force sandboxed execution | `sandbox` / `sandbox.enabled` | Hard block |
| Force environment variables | `env` | Hard constraint |
| Force auth method / bind to an org | `forceLoginMethod` · `forceLoginOrgUUID` | Hard constraint |
| Event-driven mandatory workflows | `hooks` | Hard block (can reject via exit code) |
| **Code style / quality guidelines / behavioral norms** | **`claudeMd` (Managed CLAUDE.md)** | **Behavior shaping** |

Summed up in one line:

> **Managed CLAUDE.md is a layer of behavioral instructions, not a hard-block layer.**

The official wording is even more direct (verbatim):

> **CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer.**

Translated: writing "never push to main" into CLAUDE.md makes Claude **lean toward** not pushing, but if a prompt injection occurs or a user talks their way around it by saying "special approval this time," Claude can potentially be talked into it. If you want the act of "pushing to main" to die at the **code level**, you need `permissions.deny` to block `Bash(git push origin main*)`.

The relationship between Managed CLAUDE.md and managed settings is the relationship between "persuasion" and "iron fencing" — organizations typically write both.

---

## 6. Three counterintuitive designs

### Case 1 · Managed is an "instruction," not a "policy"

**Intuition**: managed = mandatory → Claude will definitely obey.

**Reality**: content at the managed layer really does **come into view first**, but Claude is still a language model that can be talked around via prompt injection. Hard control relies on `permissions.deny`; CLAUDE.md is only a **reinforced suggestion**.

An extreme example: managed says "never read .env files," and Claude will usually refuse. But if an attacker constructs a sufficiently persuasive line of reasoning, there's a chance Claude gets talked into it. So genuinely protecting secrets requires configuring both:

```json
{
  "permissions": {"deny": ["Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)"]},
  "claudeMd": "Never read .env or secrets/ files. Refuse if asked."
}
```

Only writing both together counts as "defense in depth."

### Case 2 · User claudeMdExcludes can exclude project CLAUDE.md, but not managed

**Intuition**: excludes should be fair across all CLAUDE.md files — whatever I don't want loaded, shouldn't get loaded.

**Reality**: excluding project / local / nested / user is all fine (write the pattern for whichever layer you want to block), managed alone is immune. This isn't a bug, it's a feature — if excludes worked on managed too, an organization's control could be nullified by a single user config on day one.

This is a **ceiling-and-floor of power** design. A user's autonomy stops at "block a project's stale CLAUDE.md"; an organization's enforcement power starts at "guarantee the core instructions are always seen." The two don't overlap.

### Case 3 · CLAUDE.md doesn't enter the permissions.deny decision chain

**Intuition**: if CLAUDE.md says "never run `rm -rf`," does that mean Claude just won't run it?

**Reality**: **not necessarily**. CLAUDE.md only shapes behavior — it doesn't participate in `permissions` decisions. Seeing the instruction makes Claude **lean toward** not running it, but what actually decides whether it runs is the permissions engine, not the text in CLAUDE.md.

The genuinely safe pattern is:
- CLAUDE.md explains "why this shouldn't be run" (education + guidance)
- `permissions.deny` defines "block it if it's attempted" (enforcement + hard stop)

Writing only CLAUDE.md without permissions is like hanging a sign without installing a lock. Writing only permissions without CLAUDE.md is like installing a lock but never telling the engineer it's there (Claude will keep bumping into the lock and erroring out — a poor experience).

**Both need to be used together.**

---

## 7. A vault scenario walkthrough

If Claudian were one day deployed in an enterprise environment, what might show up in the organization's managed CLAUDE.md?

Looking back at a few user preferences in the vault's main CLAUDE.md:

- **"Commit message four-part structure: background / changes / metrics / impact"** — currently a personal preference, could be hardened into an org-wide version
- **"Workspace boundaries: only stage files you changed yourself, don't use `git add .`"** — an org-level compliance requirement (avoiding accidental commits of .env, secrets)
- **"Fact-checking discipline: any heading containing words like 'citation' or 'official' must go through WebFetch"** — the org version might turn into "all externally published content must first pass a fact-check hook"

The path by which these preferences escalate from **personal CLAUDE.md** to **organizational managed** roughly looks like this:

```
Personal pain point → codified in personal CLAUDE.md → spread across the team → project CLAUDE.md → org sign-off → managed CLAUDE.md
```

Each step up, **flexibility goes down and consistency goes up**. Once something reaches the managed layer, it's basically locked — adjusting even a comma requires going through an ops/security approval process and shipping a new `managed-settings.json`.

The tradeoff is clear:

| Layer | Flexibility | Consistency | Suited for |
|---|---|---|---|
| Local | ★★★★★ | ★ | One-off experiments, private temporary rules |
| Project | ★★★★ | ★★★ | Team consensus, project style |
| User | ★★★ | ★★ | Personal preferences, cross-project habits |
| Managed | ★ | ★★★★★ | Compliance red lines, security baselines, audit requirements |

If the vault's "fact-checking discipline" or "four-part commit message" rules were really escalated to managed, the payoff would be company-wide consistency, at the cost of — even wanting to make a small personal exception would require going through approval. So **not every rule deserves promotion to the managed layer**.

---

## 8. Decisions · anti-patterns · signals to evolve

**Decision**: what belongs in managed?

- ✅ Compliance red lines (never push directly to main, never read .env, must pass lint)
- ✅ Security baselines (all Bash commands go through a sandbox, a fixed login org)
- ✅ Behavioral norms the organization requires (commit format, code review process)
- ❌ Team taste / project style (put it in project CLAUDE.md)
- ❌ Personal preferences (put it in user CLAUDE.md)

**Anti-patterns**:

1. **Stuffing too much detail into managed** — any change to managed requires shipping a new `managed-settings.json` and redistributing it to every machine. Too much verbosity makes the org's change cost spiral out of control. Anything beyond the core red lines should be pushed down a level.

2. **Relying on managed CLAUDE.md to block hard behavior** — to actually forbid `rm -rf`, you can't just write "Never run rm -rf"; you need `"permissions": {"deny": ["Bash(rm -rf *)"]}`. CLAUDE.md is a soft nudge, permissions is a hard lock — neither substitutes for the other.

3. **Forgetting that managed CLAUDE.md doesn't auto-sync to users** — when the org adds a new rule, it needs a deployment tool (MDM / Ansible / Group Policy) to push `managed-settings.json` out to user machines. CLAUDE.md itself has no "push" mechanism.

**Signals to evolve · when should something be promoted to managed?**

- Trigger 1 · compliance audit: a financial / healthcare / government client demands audit logs, needs proof that "users cannot modify this rule"
- Trigger 2 · a security incident: an engineer disabled lint checks locally, pushed straight to main, and broke production — the postmortem reveals that "relying on users' self-discipline" isn't sustainable
- Trigger 3 · organizational standardization: once the company crosses 100 people, the cost of broadcasting consensus via project CLAUDE.md exceeds the cost of a single managed deployment
- Trigger 4 · third-party intrusion threat model: prompt injection has evolved to the point of being able to rewrite CLAUDE.md, and the organization needs an immune layer

In one sentence: **managed is the last layer of the "security boundary," not the first layer of "engineering efficiency."** Keep everyday rules at the user / project layer as much as possible, and only promote something to managed once "whether the user can change it" becomes the core question.

---

## References

- Official docs · Manage CLAUDE.md for large teams: https://code.claude.com/docs/en/memory
- Official docs · Settings: https://code.claude.com/docs/en/settings
- Source · `utils/claudemd.ts:53` (`getManagedClaudeRulesDir` import)
- Source · `utils/claudemd.ts:540-635` (`isClaudeMdExcluded` — Managed's immunity short-circuit)
- Source · `utils/claudemd.ts:804` (`getMemoryPath('Managed')`)
- Source · `utils/claudemd.ts:1033` (`managed_count` telemetry)
- Source · `utils/claudemd.ts:1084` (`isInstructionsMemoryType` treating all four types equally)
- Discovery report · Carrier A · lines 66-88 (the source this article builds on)
- Sister article · Article 01 · the CLAUDE.md 5-layer loading stack (functional view)
