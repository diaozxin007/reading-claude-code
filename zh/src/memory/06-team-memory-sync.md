# 06 · Team memory sync · 从本地双目录到服务端同步

> **TL;DR**:team memory 不是把 `.claude/team-memory/` 提交进 git。它在本机位于 auto-memory 目录的 `team/` 子目录,以 GitHub remote 的 `owner/repo` 作为服务端 scope,通过 Anthropic API 在 session 起手 pull、文件变化后 debounce push。private 与 team 各有一份 `MEMORY.md`;分类 prompt 决定写哪边,同步层负责传输而不重新判断语义。

上一篇 [05 · Memory extraction pipeline · 从一轮结束到受限 fork](05-extraction-pipeline.md) 停在“记忆文件写入磁盘”。如果这条信息不是个人偏好,而是所有项目成员都应该知道的测试约束,下一步不是 git commit,而是进入 team memory sync。

## 双目录 · 本地形态先分开

启用 team memory 后,同一项目有两个根:

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

team path 不是仓库内目录,而是 `join(getAutoMemPath(), 'team')`。它依附 auto memory,因此 auto memory 被关闭时,team memory 也必然关闭。见 `memdir/teamMemPaths.ts:66-94`。

这纠正了一个常见误读:“team”表示共享语义,不表示直接通过 git 工作树共享。GitHub remote 只负责给服务端提供 repo identity。

## scope 是内容分类问题,不是同步层猜测

combined prompt 把 scope 写进四种 memory type:

| 类型 | scope 倾向 |
|---|---|
| `user` | 永远 private |
| `feedback` | 默认 private;明确的项目级约定才 team |
| `project` | private 或 team,强烈偏 team |
| `reference` | private 或 team,取决于链接是否对整个项目有用 |

private feedback 若与 team feedback 冲突,应不保存,或明确记录 override。这个规则不是文件系统 enforce 的强约束,而是 prompt 对模型的语义约束。见 `memdir/memoryTypes.ts:37-106`。

选择 scope 后,保存仍是两步:topic 文件写入对应目录,再更新同目录的 `MEMORY.md`。两个索引都会进入会话 context,但 team 内容明确禁止敏感数据。见 `memdir/teamMemPrompts.ts:17-99`。

## 同步对象 · GitHub repo identity + Anthropic server

team sync service 的 API 以 GitHub `owner/repo` 查询:

```text
GET /api/claude_code/team_memory?repo=<owner/repo>
PUT /api/claude_code/team_memory?repo=<owner/repo>
```

只有 authenticated org member 共享同一 repo 的数据。没有 `github.com` remote 时 watcher 根本不启动;非 GitHub remote 不是降级为本地 git 同步,而是没有 server scope。见 `services/teamMemorySync/index.ts:1-24`、`services/teamMemorySync/watcher.ts:231-265`。

## session 起手 · server 先赢

启动流程是:

1. 检查 build feature、运行时 gate、OAuth 与 GitHub remote;
2. 创建独立 `SyncState`;
3. 先从 server pull;
4. pull 结束后再启动本地目录 watcher。

watcher 延后启动,避免 pull 落盘反过来触发一次无意义 push。即使 server 没内容,也要创建空目录并启动 watcher,否则第一个 team memory 写入可能落进 bootstrap dead zone。见 `services/teamMemorySync/watcher.ts:245-304`。

pull 的逐 key 冲突规则是 **server wins**:远端内容覆盖本地同名文件。这里没有三方 merge。团队记忆适合短而明确的规则与背景,不适合多人同时编辑的大文档。

## 本地变化 · watcher + 显式通知双保险

目录使用 `fs.watch({recursive:true})`,支持子目录。变化事件经过 debounce 后触发 push;FileWrite/Edit 的 PostToolUse 路径还会显式调用通知,防止 watcher 在启动同一 tick 漏事件,或平台合并快速写入。两条路径最终只会重置同一个 debounce timer。见 `services/teamMemorySync/watcher.ts:147-228,307-319`。

push 不是每次上传所有文件。`SyncState.serverChecksums` 保存服务端每个 key 的内容 hash,只上传本地 hash 与已知 server checksum 不同的 key。服务器是 upsert:本次 payload 未包含的 key 保留。见 `services/teamMemorySync/index.ts:14-24,100-109`。

## 删除为什么不会同步

服务端 API 的当前语义没有 delete propagation:

- 本地删文件不会删除服务端 key;
- 下一次 pull 会把它重新写回本地。

这是保守的数据保护选择,但也意味着“忘记一条团队记忆”不能靠本地 `rm` 完成。同步层宁愿复活一条被删内容,也不让一次误删扩散到全组织。见 `services/teamMemorySync/index.ts:14-20`。

## 大小、冲突与失败

同步实现还有几层工程边界:

- 单 entry 本地预检上限 250KB;
- PUT body 目标控制在约 200KB并拆成顺序 batch;
- 条目数量上限不硬编码,从服务端结构化 413 学习;
- ETag/checksum 冲突有有限次数重试;
- graceful shutdown 只有短预算,push 是 best-effort。

见 `services/teamMemorySync/index.ts:71-91`、`services/teamMemorySync/watcher.ts:321-340`。

团队记忆不是可靠消息队列。它提供跨成员的背景同步,但不承诺进程退出瞬间的最后一次写入一定成功。

## 路径安全 · server key 也不可信

服务端返回相对 key,客户端仍必须防 traversal。校验包含:

- null byte;
- URL 编码的 `../`;
- Unicode NFKC 归一后形成的 traversal;
- Windows 反斜杠;
- 绝对路径;
- `resolve()` 后的目录逃逸;
- symlink 与 dangling symlink 逃逸。

尤其是 symlink:字符串前缀校验无法阻止 `team/link → ~/.ssh`。源码会解析“最深已存在祖先”的 realpath,再确认真实路径仍在真实 team dir 内。见 `memdir/teamMemPaths.ts:17-63,96-171,222-283`。

## private 与 team 冲突时谁说了算

有两类“冲突”不要混在一起:

1. **语义冲突**:private feedback 与 team convention 相反。由 memory prompt 要求避免或显式 override。
2. **传输冲突**:本地 team 文件与 server 同 key 不同。pull 时 server wins;push 时 checksum/ETag 检测并重试。

前者需要模型理解内容,后者只处理字节版本。把语义合并塞进同步 service 会让基础设施必须理解 Markdown 规则,因此两层刻意分离。

## 决策 · 反模式 · 演进信号

### 决策

- 双目录让 private/team 在落盘时已经分区,避免同步层读取隐私内容再判断。
- repo identity 来自 GitHub remote,内容由 Anthropic server 同步。
- server-wins pull + 不传播删除,偏向防丢失而非自动合并。
- checksum delta 降低日常小改动的上传成本。

### 反模式

- 以为 team 目录应 `git add` · 它位于用户配置目录,不是仓库工作树。
- 把个人交流偏好放进 team · 会扩散给所有项目成员。
- 把密钥写进 team 再依赖同步层拦截 · prompt 与 secret scan 都不是保密边界的替代品。
- 本地删除后认为远端也忘记了 · 下次 pull 会复活。

### 演进信号

- 同名文件频繁 server-wins 覆盖 → topic 粒度太粗或多人同时编辑。
- push 经常拆大量 batch → 记忆内容已膨胀成文档库。
- private override 越来越多 → team convention 不够准确或 scope 选错。
- 非 GitHub 仓库需要共享 → 现有 repo identity 绑定成为产品限制。

## 小结

Team memory 的真正架构是:**模型按 scope 分流 → 本地 private/team 双目录 → GitHub repo 标识 → Anthropic server pull/push**。它没有让所有成员共同编辑一份 git 文件,而是把语义分类与字节同步拆成两层。这样隐私边界在写入前决定,同步层只需处理版本、批量、冲突与安全。

下一篇 [07 · Managed CLAUDE.md · 企业管控层](07-managed-claude-md.md) 回到组织权力的另一面:团队可以共享经验,管理员还需要一层不可被项目或用户排除的强制指令。

## 参考

- Claude Code 源码:`memdir/teamMemPaths.ts:17-94,96-291`
- Claude Code 源码:`memdir/teamMemPrompts.ts:17-99`
- Claude Code 源码:`memdir/memoryTypes.ts:37-106`
- Claude Code 源码:`services/teamMemorySync/index.ts:1-109`
- Claude Code 源码:`services/teamMemorySync/watcher.ts:147-340`
- Claude Code 源码:`services/teamMemorySync/secretScanner.ts`
- Claude Code 源码:`services/teamMemorySync/teamMemSecretGuard.ts`

