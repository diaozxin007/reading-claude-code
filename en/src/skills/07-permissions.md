# 07 · Permission Governance · From Callable to Safely Executable

> **TL;DR**: Skill security breaks down into at least four layers: who can activate a Skill, which Tools are visible once activated, which Tools can bypass confirmation prompts, and which system resources a command can ultimately reach. `allowed-tools` is a temporary pre-approval, not a Tool allowlist; `disallowed-tools` is an exclusion for the current turn, not an OS sandbox; and invocation switches control entry points, not external system permissions. High-risk Skills need to combine instructions, permissions, hooks, sandboxing, and human confirmation together.

The previous article, [06 · Execution Boundary · From Inline to Forked Subagent](06-execution-boundary.md), determined whether a Skill unfolds in the current conversation or as an independent worker. Either way, the instructions may ultimately require Claude to call Bash, Edit, MCP tools, or other capabilities.

This is where a dangerous shortcut in reasoning tends to appear:

```text
User invokes /deploy
  → User consents to deployment
  → The Skill has allowed-tools written into it
  → All subsequent operations are safe
```

None of these three steps actually implies the next one. Invocation intent, tool availability, approval policy, and actual isolation are distinct security layers.

## Draw the Four Gates First

```text
Gate 1 · Skill invocation
  Who can start this workflow?
        ↓
Gate 2 · Tool availability
  Which Tools can the running Claude see?
        ↓
Gate 3 · Permission decision
  Is a given Tool call allowed, asked about, or denied?
        ↓
Gate 4 · Execution boundary
  What do the process, file system, network, and external services ultimately permit?
```

The corresponding mechanisms might be:

| Security question | Primary mechanism |
|---|---|
| Can Claude call the Skill proactively | `disable-model-invocation`, Skill permission rules |
| Does the user see `/skill-name` | `user-invocable`, visibility settings |
| Which Tools bypass confirmation when a Skill is active | `allowed-tools` |
| Which Tools are temporarily unavailable | `disallowed-tools` |
| Is a deterministic check run before every call | Hooks, permission rules |
| What files and network Bash can access | Sandbox, OS permissions, containers |
| What MCP / API can do | External authentication, server-side authorization, scope |

No single column can carry the entire security chain by itself.

## Layer One · Controlling Skill Entry

The 04th article already introduced two frontmatter fields:

```yaml
disable-model-invocation: true
user-invocable: false
```

They control the normal invocation paths:

- Disabling model invocation ensures a workflow with side effects can only be started explicitly by the user.
- Hiding the user entry point lets a reference-type capability be loaded by Claude only on an as-needed basis.

Beyond that, Claude Code permissions can also control the entire Skill tool, or a specific Skill:

```text
Skill
Skill(release-check)
Skill(deploy *)
```

Conceptually, this allows three kinds of policy:

- Prohibit the model from using any Skills at all.
- Allow only specific Skills.
- Allow or deny a specific Skill invocation with particular arguments.

However, `user-invocable: false` only governs the user menu and direct entry point — the official documentation explicitly notes that it does not block Skill tool access. To actually prevent Claude from invoking a Skill programmatically, you need `disable-model-invocation` or permission rules.

UI visibility is not a security boundary. Hiding a button never equals disabling a capability.

## Layer Two · `allowed-tools` Is a Temporary Pre-Approval

A commit Skill might be written as:

```yaml
---
name: commit
description: Review and commit the current changes
disable-model-invocation: true
allowed-tools:
  - Bash(git status *)
  - Bash(git diff *)
  - Bash(git commit *)
---
```

What `allowed-tools` does: within the turn where this Skill is activated, the listed Tool patterns no longer require asking the user each time.

What it is *not*:

- "The Skill can only use these Tools."
- A permanent session allow rule.
- A bypass of all project permission settings.
- A grant of OS-level privileges to the shell process beyond what the OS itself allows.
- Something that stays in effect for every subsequent user turn.

Think of it as the Skill's **temporary declaration of the permission requirements** for its own workflow:

```text
Skill instructions remain in context long-term
  ≠
allowed-tools grant remains in permission state long-term
```

Official documentation clarifies that the grant is cleared once the user sends the next message. If confirmation-free operation needs to continue, the Skill must be invoked again; if the entire session should allow it, formal permission allow rules should be configured instead.

This lifecycle mismatch matters: instructions and permissions do not persist in sync with each other.

## `allowed-tools` Does Not Shrink the Tool Set

The field name is easy to misread as an allowlist. In fact, it lists which Tools get pre-approved — Tools not listed are still potentially visible and callable, they just continue to follow the original permission policy. For example, `allowed-tools: Read Grep` does not result in "only Read/Grep are available" — it results in "Read/Grep get pre-approved for this turn, other Tools continue to be judged against the baseline policy."

If the goal is to build a read-only Skill, listing only `allowed-tools: Read Grep` is not enough. Claude may still request Edit or Bash.

To actually narrow available capabilities requires:

- The Skill's `disallowed-tools`
- A Subagent's `tools` allowlist
- Permission deny rules
- A read-only agent type or sandbox

"Confirmation-free" and "not callable" must be expressed with different terms.

## `disallowed-tools` · Temporarily Removing Capabilities

A Claude Code Skill can declare:

```yaml
disallowed-tools:
  - Edit
  - Write
```

This removes the specified Tools from the available pool for the scope in which the Skill is active. It's well-suited for expressing the negative capabilities of the workflow itself:

- An audit Skill should not modify files.
- A background loop should not prompt the user.
- A research process should not send external messages.

But it's still a tool-level restriction within the Claude Code runtime:

- It is not equivalent to OS-level read-only file access.
- It does not stop an un-disabled Bash command from indirectly modifying files.
- It does not substitute for external service permissions.
- The restriction is cleared once the invocation lifecycle ends.

For example, disallowing only Edit and Write while leaving Bash available does not imply "files absolutely will not be written." Security goals should be audited by capability effect, not just by Tool name.

## Permission Rules · Governing Skills and Tools Separately

A high-risk Skill typically needs two layers of rules:

```text
Skill(deploy-production *)
  Controls whether the deployment workflow can be started

Bash(kubectl apply *) / MCP deploy tool
  Controls the actual deployment action within the workflow
```

The first layer blocks workflows that shouldn't happen. The second layer can still intercept the specific action even if the Skill gets loaded. This is defense in depth: if you only allow/deny at the Skill layer, Claude might still request the same Tool directly without going through the Skill. If you only govern at the Tool layer, then costly or sensitive instructions could still be loaded incorrectly. The two layers address different risks.

## Workspace Trust · Project Skills Are Executable Configuration

A Project Skill can appear alongside an unfamiliar Git repository. It contains more than just Markdown:

- `allowed-tools` might request broad pre-approvals.
- Dynamic context might execute shell commands during the loading phase.
- Scripts might access files and the network.
- References might contain malicious prompt injection.
- Hooks might run automatically at points in a Tool's lifecycle.

So opening a repository shouldn't treat `.claude/skills/` as an ordinary documentation directory. It's closer to executable development configuration provided by the project.

Claude Code connects project configuration to workspace trust. Permission grants inside a project Skill only take effect once the user trusts that workspace.

"Trust" is also not a substitute for file-by-file security review. It merely means the user accepts that this directory's configuration will participate in execution. When introducing a third-party Skill, it's still worth checking:

1. The `SKILL.md` instructions.
2. Dynamic shell placeholders.
3. `allowed-tools` / `disallowed-tools`.
4. What files, network, and credentials the scripts access.
5. References and the source of external content.
6. Hooks.
7. The Plugin or dependency update path.

The official security guidance can be summarized as: **treat a Skill like installing software, not like collecting a prompt.**

## Dynamic Shell · Permission Happens Before Claude Reads It

The 05th article introduced this:

```markdown
!`git diff --stat`
```

The command runs before the rendered instructions reach Claude. Even though it's just context preprocessing, it's still actual shell execution.

This is why there's a separate governance switch, `disableSkillShellExecution`. Organizations can allow Skills to provide instructions while disabling dynamic shell execution during the loading phase for user, project, and Plugin Skills.

This policy has real value:

```text
Allow prompt-based workflows
  But do not allow prompt preprocessing to automatically execute local commands
```

Authors can convert dynamic commands into explicit Tool steps, returning them to the normal permission loop. One extra round trip buys a clearer approval and audit path.

## Hooks · Turning Suggestions into Fixed Checkpoints

Skill instructions might say:

```text
Check whether the command touches production before every Bash run.
```

This is behavioral guidance — Claude may still misunderstand or miss it. A Skill-scoped Hook, on the other hand, can run a check at a fixed event in a Tool's lifecycle.

```text
Skill activated
  ↓
Claude requests Bash
  ↓
PreToolUse Hook
  ├─ Allow
  ├─ Ask for confirmation
  └─ Block
```

The advantage of a Hook is that its trigger timing is deterministic. It's well-suited for:

- Intercepting dangerous commands
- Validating parameters
- Automatically formatting after edits
- Running validation at the end of a workflow
- Logging audit events

But the Hook script itself is also code, and it likewise needs permissions, input validation, and maintenance. Shifting prompt-level risk onto an unaudited shell hook doesn't automatically make things safer.

This can be summarized with one dividing principle:

> **The Skill tells Claude how to do something; the Hook guarantees that a given lifecycle check definitely happens.**

## Sandbox · The Execution Boundary Beyond Tool Policy

Permission mainly decides "whether an operation is allowed to be initiated." Sandbox decides "even if the operation is allowed, what it can actually reach."

For example, once Bash is approved:

```text
Permission layer
  Allows the command to execute

Sandbox layer
  Restricts writable paths and network access

OS / container layer
  Restricts process identity and system resources
```

For highly automated Skills, a sandbox is often more reliable than repeated permission prompts. It can pre-define a workspace, letting Claude execute freely within the boundary while being unable to reach beyond it.

But a sandbox also can't determine business-level authorization. A process being able to access the network doesn't mean it should call a production API; having a local kubeconfig doesn't mean the Skill should be granted production deploy permission.

## External Tools · Final Authority Lives on the Server Side

A Skill might call an MCP tool, a cloud CLI, or an API:

```text
Skill allowed-tools
  Allows Claude to request the deploy tool
        ↓
MCP / CLI credential
  Determines whose identity the client accesses with
        ↓
External service authorization
  Determines which environment the account can deploy to
```

The local allow rule only affects whether Claude Code lets the call through. The actual data scope, write permissions, and audit logs are still controlled by the external system.

So sensitive Skills should use least-privilege credentials:

- Read-only tokens should not be used for write operations.
- Staging and production credentials should be kept separate.
- Destructive actions should require server-side confirmation or approval.
- Secret isolation should not be delegated to Skill instructions.
- Tool results containing external content should continue to be treated as untrusted data.

A Skill can orchestrate an authorization system — it can't replace one.

## Managed Skills · Unified Distribution Is Not Absolute Enforcement

Organizations can deploy managed Skills to uniformly provide compliance checks, security review, and internal processes.

It's well-suited for establishing:

- Organizationally approved working methods
- Unified references and scripts
- Default permissions and hooks
- Centrally updated capability versions

But writing a single line — "prohibit uploading sensitive data" — into a managed Skill is still just a prompt instruction. Actually enforcing a hard block requires deny rules, network policy, sandboxing, DLP, or server-side authorization.

This is consistent with the conclusion of [07 · Managed CLAUDE.md · The Enterprise Governance Layer](../memory/07-managed-claude-md.md): a managed prompt provides behavioral guidance that ordinary projects can't easily override, but enforcement still has to land on a deterministic control plane.

## A Security Matrix

| Mechanism | What it controls | Lifecycle | What it can't guarantee |
|---|---|---|---|
| `disable-model-invocation` | Whether Claude proactively calls the Skill | Skill definition | The user won't invoke it; disk files aren't readable |
| `user-invocable` | Whether the user entry point is displayed | Skill definition | Claude can't call it |
| `Skill(name)` rule | A specific Skill tool call | Permission policy | Tools inside the Skill are automatically safe |
| `allowed-tools` | Some Tools temporarily bypass confirmation | The turn in which invoked | Only these Tools remain; permanent authorization |
| `disallowed-tools` | Temporarily removed Tools | The scope of invocation | OS-level isolation; indirect side effects |
| Hook | Checks at fixed events | Skill / session lifecycle | The Hook code itself is correct |
| Sandbox | File and network execution boundary | Process / session | Business-level authorization is correct |
| External auth | Server-side resource permissions | Credential / policy | The prompt isn't being injected |

Security auditing should go row by row — you shouldn't declare a Skill "safe" just because you saw one particular field.

## A Combination Template for High-Risk Skills

Using production deployment as an example:

```text
Entry point
  disable-model-invocation: true
  User must invoke it explicitly

Instructions
  Verify environment, version, and approval status first
  Must not execute without confirmation

Tool permissions
  Only read-only checks are pre-approved
  The actual deployment still requires confirmation

Hooks
  PreToolUse validates the target environment

Sandbox / credentials
  Only staging credentials by default
  Production uses a separate short-lived authorization

External service
  Server-side RBAC + audit log + rollback
```

If any single layer fails, there's still a chance for a later layer to block it. Defense in depth is more trustworthy than "writing a very stern prompt" — and that's the conclusion this article is converging on: **Invocation determines who can start; Tool policy determines how an action can be requested; Hooks determine which checks are mandatory; Sandbox and external authorization determine what an action can ultimately reach.**

## Coming Up Next

Once a Skill has been discovered, invoked, and executed safely — will the instructions still be there in the next turn? Does modifying the file on disk immediately affect the copy already loaded? And how much survives after compaction? The next article, [08 · Lifecycle · From a Single Load to Compaction](08-lifecycle.md), will break this down into four states: the source file, the invocation record, the conversation content, and post-compact recovery.

## References

- Anthropic Claude Code official documentation: [Pre-approve tools for a skill](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Restrict Claude's skill access](https://code.claude.com/docs/en/slash-commands)
- Anthropic Claude Code official documentation: [Configure permissions](https://code.claude.com/docs/en/permissions)
- Anthropic Claude Code official documentation: [Hooks in skills and agents](https://code.claude.com/docs/en/hooks)
- Anthropic Platform official documentation: [Agent Skills security considerations](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- Previous article: [06 · Execution Boundary · From Inline to Forked Subagent](06-execution-boundary.md)
- [01 · From Tool Declaration to Pre-Execution Approval](../agent-loop/01-tool-permission.md)
- [02 · Hooks · Programmable Intervention Points on the Loop](../agent-loop/02-hooks.md)
