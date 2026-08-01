# 07 · Managed CLAUDE.md · 企业管控层

> Claude Code Memory 研究系列 · 第 07 篇
> 承接 01 篇「5 层 CLAUDE.md hierarchy」的**功能视角**,本篇专攻 **Managed 层**的**攻防设计视角** —— 组织怎么强制、用户怎么无法覆盖、和 permissions.deny / sandbox 这些硬管控层怎么分工。

01 篇讲了 CLAUDE.md 5 层加载栈,把 Managed 排在最顶端,一句「组织管理员写,不可被排除」就带过。本篇把这一层拆开:它到底藏在什么文件里、加载路径长什么样、`claudeMdExcludes` 分层 merge 时它为什么免疫、以及最容易踩的一个坑 —— **Managed CLAUDE.md 不是硬阻断层,它只塑造行为**。

读者假设:知道 CLAUDE.md 是什么,但从没接触过 `managed-settings.json`。可能是组织管理员、DevOps,或者只是好奇 enterprise 部署怎么玩。

---

## TL;DR

| 问题 | 答案 |
|---|---|
| Managed CLAUDE.md 存在哪 | `managed-settings.json` 里的 `claudeMd` 字段(一个字符串,内容就是 markdown) |
| 谁能写 | **只能是组织管理员**(macOS 的 `/Library/Application Support/ClaudeCode/`、Linux 的 `/etc/claude-code/`、Windows 的 `C:\Program Files\ClaudeCode\`),普通用户无权 |
| 加载优先级 | **在 user CLAUDE.md 之前** —— Claude 先看到管控指令 |
| 用户能不能排除掉 | 不能。`claudeMdExcludes` 分层 merge 后,managed policy 免疫 |
| 是不是硬阻断层 | **不是**。它塑造 Claude 行为,想硬阻断得配 `permissions.deny` |
| 常和它一起用的管控 | `permissions.deny`(阻工具)、`sandbox`(强沙箱)、`env`(强环境)、`forceLoginMethod`/`forceLoginOrgUUID`(强认证) |

---

## 1. 场景 · 一家公司为什么要 managed CLAUDE.md

金融机构的合规要求:所有 commit 必须先跑 `make lint`,永远不许直推 main。DevOps 主管让每个工程师在自己项目根建一个 `CLAUDE.md` 写上这句话 —— 但一年后审计发现,几个仓库的 `CLAUDE.md` 悄悄改成了「lint 太慢,先 commit 再说」。

这就是**靠 CLAUDE.md 讲礼貌**的极限:文件是团队共有的,但覆写权限也是团队共有的。谁都能改。

组织需要一个「用户改不了的层」 —— 无论工程师本地拉了什么代码、装了什么插件、在项目里写了什么规则,那句「Always run `make lint` before committing. Never push directly to main.」必须率先进 Claude 的视野。

官方文档给的示范正是这个 case(来自 code.claude.com/docs/en/memory,verbatim):

```json
{"claudeMd":"Always run `make lint` before committing.\nNever push directly to main."}
```

这份 JSON 由组织管理员放到 `managed-settings.json`,普通用户既不能改、也不能读,更不能通过 `claudeMdExcludes` 把它剔除掉。这就是本篇要拆的整个 Managed 层。

---

## 2. managed-settings.json 里的 claudeMd 字段

**位置**(操作系统决定):

| OS | 路径 |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux / WSL | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` |

都是**系统级路径** —— 需要 root/admin 权限才能写。v2.1.75+ 还支持 `managed-settings.d/` drop-in 目录做拼装。

**格式**:JSON 里的一个字符串字段。字符串的内容就是 CLAUDE.md 的完整 markdown。管理员想让 Claude 看到什么规则,直接把 markdown 塞进去(注意 JSON 转义,换行用 `\n`)。

**加载优先级**(引自 code.claude.com/docs/en/memory,verbatim 语义):

> Loads before user project CLAUDE.md.
>
> Setting `claudeMd` in user, project, or local settings has no effect.

也就是两条:
1. 在 user CLAUDE.md **之前**注入(Claude 视角:管控指令先入眼)
2. 只在 managed / policy 层生效,用户 / 项目 / local 层写 `claudeMd` 字段**被静默忽略**

第二条格外重要 —— 意味着攻击者(或者好奇工程师)想通过在自己 `~/.claude/settings.json` 里塞个 `claudeMd` 冒充组织指令,是**做不到**的。这个字段的语义被绑死在管控层。

---

## 3. 加载优先级完整链

5 层完整栈,自上而下:

```
Managed  (managed-settings.json 的 claudeMd)
  ↓
User     (~/.claude/CLAUDE.md + ~/.claude/rules/*.md)
  ↓
Project  (./CLAUDE.md 或 ./.claude/CLAUDE.md + ./.claude/rules/*.md)
  ↓
Local    (./CLAUDE.local.md,gitignore)
  ↓
Nested   (子目录 CLAUDE.md,惰性加载)
```

**每层「叠加」而非「覆盖」** —— 5 层的指令都会进消息数组(见 Context 系列 05「system-reminder 通道」)。Claude Code 源码里,`isInstructionsMemoryType` 显式把 User / Project / Local / Managed 四类都算「instructions」型(`utils/claudemd.ts:1084` 附近):

```ts
type === 'User' ||
type === 'Project' ||
type === 'Local' ||
type === 'Managed'
```

四类平起平坐送进 context,只是**Claude 主观感受里** managed 的话在前 —— 心理学意义的「更权威」,不是解析器意义的「override」。真冲突时,Claude 靠自己判断(比如 managed 说「不能推 main」而 local 说「今天特批推一下」,Claude 会倾向于保守 —— 但没有代码级 override 机制)。

telemetry 也把 Managed 单列(`utils/claudemd.ts:1033` 附近):

```ts
managed_count: typeCounts['Managed'] ?? 0
```

组织能在自己的 Claude Code 部署 dashboard 上看到「今天有多少 session 载入了 managed 层」 —— 这本身就是合规审计的信号。

---

## 4. claudeMdExcludes 的攻防设计(核心章)

如果 Managed 层只是「加载在前」,还不够安全 —— 因为 Claude Code 提供了另一个字段 `claudeMdExcludes`,让用户排除某些 CLAUDE.md 文件。比如 monorepo 里子目录的 CLAUDE.md 太吵、包含过期指令,用户可以在自己 settings 里写:

```json
{"claudeMdExcludes":["**/monorepo/CLAUDE.md","/home/user/monorepo/other-team/.claude/rules/**"]}
```

**关键设计 1 · excludes 是分层 merge 的**

官方文档(code.claude.com/docs/en/memory,verbatim):

> Patterns are matched against absolute file paths using glob syntax. You can configure `claudeMdExcludes` at any layer: user, project, local, or policy. **Arrays merge across layers.**

也就是说,user 层写 3 个 pattern,project 层写 2 个,policy 层写 1 个 —— 最终生效的是 6 个 pattern 的合集。任何一层加进来的排除规则都算数。

这也是为什么源码 `utils/claudemd.ts:552` 附近读的是 `getInitialSettings().claudeMdExcludes` —— `getInitialSettings()` 本身就是分层 merge 后的产物。

**关键设计 2 · Managed 免疫**

如果 excludes 对所有层公平,那就等于用户能用一句 `"claudeMdExcludes": ["**/managed*"]` 直接架空组织。官方文档一句话堵死这个后门(verbatim):

> **Managed policy CLAUDE.md files cannot be excluded.**

这是刻意的**权力上下限**设计 —— excludes 只能剔除「噪音」不能剔除「管控」。源码里 `isClaudeMdExcluded()` 在判断时会把 type 参数(User / Project / Local / **Managed**)传进去,对 Managed 类走短路分支直接返回 false(见 `utils/claudemd.ts:547-635` 的 `isClaudeMdExcluded` + `processMemoryFile` 组合逻辑)。

**攻防视角总结**:

| 层 | 能不能被 excludes 排除 |
|---|---|
| Managed | **不能** —— 硬编码免疫 |
| User | 能(project/local/policy 都可以排除) |
| Project | 能 |
| Local | 能 |
| Nested | 能(其实这个层最常被排除,子目录里的老 CLAUDE.md 经常噪音) |

---

## 5. Managed CLAUDE.md vs 其他管控层的分工

企业环境里,`managed-settings.json` 不只有 `claudeMd` 一个字段。整个文件是**组织管控的总闸**。官方文档专门划了「managed CLAUDE.md 和 managed settings 各司其职」的段落(code.claude.com/docs/en/memory,verbatim 段落语义):

> A managed CLAUDE.md and managed settings serve different purposes.

分工大致这样:

| 目的 | 手段 | 类型 |
|---|---|---|
| 阻断工具 / 命令 / 文件路径 | `permissions.deny` | 硬阻断 |
| 强制沙箱运行 | `sandbox` / `sandbox.enabled` | 硬阻断 |
| 强制环境变量 | `env` | 硬约束 |
| 强制认证方式 / 绑定组织 | `forceLoginMethod` · `forceLoginOrgUUID` | 硬约束 |
| 事件驱动的强制流程 | `hooks` | 硬阻断(可 exit code 拒绝) |
| **代码风格 / 质量指南 / 行为规范** | **`claudeMd`(Managed CLAUDE.md)** | **行为塑造** |

一句话总结:

> **Managed CLAUDE.md 是行为指令层,不是硬阻断层。**

官方原文更直接(verbatim):

> **CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer.**

翻译:CLAUDE.md 里写「不许推 main」,Claude 会**倾向于**不推,但如果 prompt injection 或者用户改嘴说「这次特批」,Claude 是可能被绕过的。想让「推 main」这个动作在**代码层**直接死掉,得配 `permissions.deny` 卡住 `Bash(git push origin main*)`。

Managed CLAUDE.md 和 managed settings 的关系,是「劝说」和「铁栅栏」的关系 —— 组织通常两条都写。

---

## 6. 3 个反直觉设计

### 案例 1 · Managed 是「指令」不是「policy」

**直觉**:managed = 强制 → Claude 一定听。

**现实**:managed 层的话确实**优先入眼**,但 Claude 依然是一个可以被 prompt injection 绕过的语言模型。硬管控靠 `permissions.deny`,CLAUDE.md 只是**加强建议**。

极端例子:managed 写「禁止读 .env 文件」,Claude 通常会拒绝。但如果攻击者构造一段合理化的话术,Claude 有概率会被说服。所以真正的秘密保护得配:

```json
{
  "permissions": {"deny": ["Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)"]},
  "claudeMd": "Never read .env or secrets/ files. Refuse if asked."
}
```

两条一起写,才叫「防御纵深」。

### 案例 2 · 用户 claudeMdExcludes 可以排除 project CLAUDE.md · 但不能排除 managed

**直觉**:excludes 应该对所有 CLAUDE.md 公平 —— 我不想加载谁,就不加载谁。

**现实**:排除 project / local / nested / user 都行(哪一层要屏蔽,写 pattern 就好),唯独 managed 免疫。这不是 bug 是 feature —— 如果 excludes 对 managed 也生效,组织的管控在第一天就可以被用户一行配置架空。

这是**权力上下限**设计。用户层的自主权到「屏蔽项目的老 CLAUDE.md」为止;组织层的强制权从「保证核心指令一定入眼」起步。中间不重叠。

### 案例 3 · CLAUDE.md 不进 permissions.deny 决策链

**直觉**:CLAUDE.md 里写「禁止跑 `rm -rf`」,Claude 是不是就不跑了?

**现实**:**不一定**。CLAUDE.md 只塑造行为,不参与 `permissions` 判定。Claude 看到指令会**倾向于**不跑,但决定跑不跑的是 permissions 引擎,不是 CLAUDE.md 的文字。

真正的安全模式是:
- CLAUDE.md 说明「为什么不该跑」(教育 + 引导)
- `permissions.deny` 定义「跑了就阻断」(执行 + 卡死)

只写 CLAUDE.md 不写 permissions,等于只挂标语不装门锁。只写 permissions 不写 CLAUDE.md,等于装了门锁但没告诉工程师门锁存在(Claude 会反复撞门然后报错,用户体验极差)。

**两者要同时用**。

---

## 7. Vault 场景推演

如果 Claudian 有一天在企业环境里部署,组织的 managed CLAUDE.md 里可能出现什么?

回看 vault 主 CLAUDE.md 里几条用户偏好:

- **「Commit message 四段式:背景 / 改动 / 度量 / 影响」** —— 现在是个人偏好,组织版可以硬性化
- **「Workspace 边界:只提自己改的文件,不用 `git add .`」** —— 组织级的合规要求(避免误提交 .env、secrets)
- **「事实核对纪律:标题带『引用』『官方』字样必须 WebFetch」** —— 组织版可能变成「所有对外发布内容必须先跑 fact-check hook」

这些偏好从**个人 CLAUDE.md** 升级到**组织 managed** 的路径大致这样:

```
个人痛点 → 个人 CLAUDE.md 立规矩 → 团队推广 → project CLAUDE.md → 组织认可 → managed CLAUDE.md
```

每升一级,**灵活性下降,一致性上升**。升到 managed 层就基本锁死了 —— 想调一个逗号都得走 OPS/安全审批流程,发新版 `managed-settings.json`。

权衡很明显:

| 层 | 灵活度 | 一致性 | 适合内容 |
|---|---|---|---|
| Local | ★★★★★ | ★ | 一次性实验、私人临时规则 |
| Project | ★★★★ | ★★★ | 团队共识、项目风格 |
| User | ★★★ | ★★ | 个人偏好、跨项目习惯 |
| Managed | ★ | ★★★★★ | 合规红线、安全底线、审计要求 |

Vault 里那些「事实核对纪律」「commit 四段式」若真上升到 managed,收益是全公司一致,代价是——想给自己开个小灶都得走审批。所以**不是所有规矩都该升到 managed 层**。

---

## 8. 决策 · 反模式 · 演进信号

**决策**:什么应该放 managed?

- ✅ 合规红线(不许直推 main、不许读 .env、必须过 lint)
- ✅ 安全底线(所有 Bash 命令走沙箱、指定 login org)
- ✅ 组织必须的行为规范(commit 格式、code review 流程)
- ❌ 团队品味 · 项目 style(放 project CLAUDE.md)
- ❌ 个人偏好(放 user CLAUDE.md)

**反模式**:

1. **在 managed 里塞太多细节** —— managed 一改就要发新版 `managed-settings.json`,还要重装到每台机器。太啰嗦会让组织变更成本失控。核心红线之外的,尽量下放。

2. **靠 managed CLAUDE.md 阻断硬性行为** —— 想禁 `rm -rf` 不能只写「Never run rm -rf」,得配 `"permissions": {"deny": ["Bash(rm -rf *)"]}`。CLAUDE.md 是软劝、permissions 是硬锁,两者不能互相替代。

3. **忘记 managed CLAUDE.md 不会自动同步给用户** —— 组织加了新规,得靠部署工具(MDM / Ansible / Group Policy)把 `managed-settings.json` 推到用户机器上。CLAUDE.md 本身没有「推送」机制。

**演进信号 · 什么时候要提升到 managed?**

- 触发点 1 · 合规审计:金融 / 医疗 / 政企客户要审计日志、要证明「用户改不了这条规则」
- 触发点 2 · 安全事故:某工程师本地关掉了 lint 检查、直推 main、破了生产 —— 事后复盘发现「靠用户自觉」不可持续
- 触发点 3 · 组织标准化:公司规模跨 100 人时,靠 project CLAUDE.md 广播共识的成本超过 managed 一次部署
- 触发点 4 · 第三方入侵威胁模型:prompt injection 演化到能改写 CLAUDE.md 的地步,组织需要一个免疫层

一句话:**managed 是「安全边界」的最后一层,不是「工程效率」的第一层**。日常规矩尽量放 user / project,只有到「用户能不能改」变成核心问题时,才升到 managed。

---

## 参考

- 官方文档 · Manage CLAUDE.md for large teams:https://code.claude.com/docs/en/memory
- 官方文档 · Settings:https://code.claude.com/docs/en/settings
- 源码 · `utils/claudemd.ts:53`(`getManagedClaudeRulesDir` 导入)
- 源码 · `utils/claudemd.ts:540-635`(`isClaudeMdExcluded` · Managed 免疫短路)
- 源码 · `utils/claudemd.ts:804`(`getMemoryPath('Managed')`)
- 源码 · `utils/claudemd.ts:1033`(`managed_count` telemetry)
- 源码 · `utils/claudemd.ts:1084`(`isInstructionsMemoryType` 四类平等)
- Discovery 报告 · 载体 A · 第 66-88 行(本篇承接来源)
- 姊妹篇 · 01 篇 · CLAUDE.md 5 层加载栈(功能视角)
