# CLAUDE.md · reading-claude-code

这份文档给未来协作维护这本书的 Claude 看 —— 让新 session 快速进入状态,不用每次问相同问题。

## 项目定位

**《一同读 Claude Code》** —— 从 Tools、Agent Loop、Context 到 Memory，系统拆解 Claude Code 的内部机制与工程取舍。

- **仓库**:https://github.com/diaozxin007/reading-claude-code
- **中文在线阅读**:https://diaozxin007.github.io/reading-claude-code/zh/
- **英文在线阅读**:https://diaozxin007.github.io/reading-claude-code/en/
- **技术栈**:mdBook + GitHub Pages + GitHub Actions

## 目录结构

```
reading-claude-code/
├── LICENSE                 (MIT)
├── README.md               (仓库首页 · 双站入口)
├── CLAUDE.md               (你正在读的这份)
├── .github/workflows/      (GitHub Actions 构建 & 部署配置)
├── scripts/
│   ├── index.html          (顶层语言选择页 · 部署时挂在 _site/index.html)
│   ├── sitemap.xml         (SEO · 部署时挂在 _site/sitemap.xml)
│   ├── submit-indexnow.sh  (部署后从 sitemap 提取 URL 并通知 IndexNow)
│   └── robots.txt          (SEO · 部署时挂在 _site/robots.txt)
├── zh/                     (中文站 mdBook 项目)
│   ├── book.toml           (mdBook 主配置)
│   ├── theme/
│   │   └── head.hbs        (SEO meta 注入 · OG / hreflang / keywords)
│   └── src/
│       ├── SUMMARY.md      (中文目录 · mdBook 靠这个组装书本结构)
│       ├── preface.md      (前言)
│       ├── tool-mechanism.md   (Tool 机制 · 起步章)
│       ├── about.md        (关于 · 作者 + 书面信息)
│       ├── interaction/    (交互原语 3 篇)
│       │   ├── ask-user-question.md
│       │   ├── enter-plan-mode.md
│       │   ├── exit-plan-mode.md
│       │   └── images/     (AskUserQuestion 篇的截图)
│       ├── execution/      (执行原语 4 篇)
│       │   ├── grep-glob.md
│       │   ├── read.md
│       │   ├── edit.md
│       │   └── write.md
│       ├── power/          (通用能力 2 篇)
│       │   ├── bash.md
│       │   └── agent.md
│       ├── state/          (状态与调度 4 篇)
│       │   ├── task-family.md
│       │   ├── background.md
│       │   ├── cron-family.md
│       │   └── monitor.md
│       ├── info/           (信息访问 1 篇)
│       │   └── web.md
│       ├── agent-loop/     (Agent Loop 执行流 · 11 篇)
│       ├── context-management/ (Context 信息流 · 9 篇)
│       ├── memory/         (跨 session 记忆 · 9 篇)
│       └── appendix-index.md   (附录 · 工具索引)
├── en/                     (英文站 · 结构同 zh/ · 但内容多数还未翻译)
└── .gitignore              (忽略 zh/book/ 和 en/book/ mdBook 构建产物)
```

## 常用命令

### 本地开发

```bash
# 中文站本地预览(浏览器自动打开)
cd zh && mdbook serve --open

# 英文站
cd en && mdbook serve --open

# 只 build 不启服务器
cd zh && mdbook build
```

### 部署

推 GitHub 后 · Actions 自动 build + 部署到 gh-pages 分支 · GitHub Pages 展示。不用手动做任何事。

## 系列写作方法论(重要 · 请遵守)

这套书是一个人 + Claude 协作沉淀出来的 · 有明确的**写作纪律**。任何新增章节都应该按这套方法论。

### 六段式结构(每篇工具章节都用这个骨架)

1. **作用** —— 4 条核心价值 · 每条一句话
2. **一个具体例子** —— 用真实场景说清"没有它 vs 用了它"(可选反例)
3. **触发条件** —— 该用 / 不该用 · 划边界
4. **技术实现** —— 参数 / runtime 行为 / harness 协作,拆若干个非平凡设计决策
5. **prompt 详解** —— 逐条拆官方 tool description 里的约束 · **必须贴英文原文**
6. **小结** —— 精妙之处清单 + 与其它工具的对照表

### 事实核对纪律(死磕的)

- **官方 prompt 引用** —— 必须贴英文原文,不能凭训练记忆写。
- **每一条 prompt 约束都得有原文** —— 如果没有原文来源、只是我推断的,要明确标注「我的理解是...」
- **引用块外层** 不要套双引号(markdown 引用块本身已表达"这是引用")
- **内嵌引号** 保留原文的双引号 `"...",` 不要改成单引号

### 人称统一

这本书是**给读者看的**。整篇用**「作者」的第三方叙事** —— 不要出现「我」「用户」这种切换视角的表达。任何涉及"作者写作过程"的注解 · 都用"作者"或叙事化陈述 · 不要让读者出戏想"作者是谁"。

例外:直接对读者说话时可以用「你」(比如「你可以试试」)· 因为「你」明确指向读者、不会混淆。

### wikilink 转换规则

vault 里用 obsidian wikilink `[[篇名|显示文本]]` · 迁到 mdBook 后必须转成标准 md 链接 `[显示文本](../相对路径.md)`。

vault 篇名跟 mdBook 路径的映射见 `/tmp/fix_wikilinks_v2.py`(如果还在的话)。

### 每篇结尾的对照表

新增章节时,更新 **9 工具对照表 / 三种时态 / 三种信息来源** 这类跨工具对照 · 保持"每一篇都能承接前面全部积累"的呼应网络。

## 上游 vault 归档位置

原始起草稿放在原作者的 Obsidian vault 里 · 不公开路径。里面有:

- 16 篇 vault 原始版本(还带 obsidian wikilink)
- 1 篇 AI 协作方法论复盘(这本书是怎么被 AI 协作写出来的元证据)

如需**回查原始起草稿** · 请联系原作者。

## 常见任务模板

### 新增一个工具章节

1. 在 vault 里先起草 · 走六段式结构
2. 复制到 `zh/src/{分类}/{tool-name}.md`
3. wikilink 转 md 链接
4. 在 `zh/src/SUMMARY.md` 里加一行索引
5. 在 `zh/src/appendix-index.md` 里加一行索引
6. `cd zh && mdbook build` 本地验一遍
7. git commit + push · Actions 自动部署

### 修一个已发布章节

1. 直接改 `zh/src/{path}/{file}.md`
2. `cd zh && mdbook serve --open` 本地预览
3. git commit + push

**不要**改 `zh/book/` 里的内容 —— 那是 build 产物 · 已被 `.gitignore` 忽略。

### 从 vault 同步更新(高频)

上游作者的 Obsidian vault 里会不断迭代原稿 · 需要定期同步回来。**流程**:

1. **复制 vault 版本覆盖仓库版本** —— 按篇名到路径的映射 · `cp` 到 `zh/src/{分类}/{tool-name}.md`
2. **跑 wikilink 转换脚本** —— `python3 /tmp/fix_wikilinks_v2.py`(如果不在,重新写一份 · 见下)
3. **手工修 3 类残留**:
   - **AskUserQuestion 篇的两张实际截图** —— vault 用 `![[attachments/xxx.jpg]]` wikilink · 转换脚本会变成 `<!-- TODO: image ... -->` 注释 · 需手工换成 `![认证方式选择](images/ask-user-question-auth.jpg)` 和 `![凭证存储选择](images/ask-user-question-storage.jpg)`
   - **Read 篇 prompt 详解里的 `![[image.png]]` 字面量** —— 是代码示例 · 转换脚本会污染 · 需手工恢复为原样
   - **cron-family.md 里 `<time>` 标签** —— vault 版本用裸 `<time>` · mdBook 会警告 unclosed HTML · 需用反引号包成 `` `<time>` ``
4. **本地 build 验证** —— `cd zh && mdbook build` · 只允许 INFO 级别输出 · 不允许 WARN / ERROR
5. **commit + push** · Actions 自动 build + 部署

**wikilink 映射表**(fix_wikilinks_v2.py 里的 MAP 字段):

vault 篇名(全角括号)→ mdBook 相对路径,例:

- `Claude code tools 研究系列-开篇（AskUserQuestion）` → `interaction/ask-user-question.md`
- `Claude code tools 研究系列（六）Edit` → `execution/edit.md`
- `Claude code tools 研究系列（十四）Background 机制` → `state/background.md`

完整映射见脚本源码。

### 翻译一篇到英文

1. 复制 `zh/src/{path}/{file}.md` 到 `en/src/{path}/{file}.md`
2. 翻译内容,**保留 prompt 引用块的英文原文不改**
3. 更新 `en/src/SUMMARY.md`
4. 参考已有的 [dev.to 版 AskUserQuestion](https://github.com/diaozxin007/reading-claude-code/blob/main/en/src/interaction/ask-user-question.md) 的语气

## 提交规范

- **提交格式**:`type(scope): 简短标题` · 参考 vault CLAUDE.md 里的 commit 规范
- **敏感文件**:不提 `.env` / API key
- **Actions 部署**:每次 push 到 main 触发 build · 直接推 main 就 OK

## 已知限制

- 英文站目前只发布第一部分；Agent Loop、Context、Memory 尚未翻译
- 图片附件目前只有 AskUserQuestion 篇有 2 张 · 其他章节都是纯文字
- 部分工具章节里画的 ASCII 图可以未来换成 mermaid

## 踩过的坑

### 首次 GitHub Actions 部署会失败(第一次装仓库时)

**症状**:第一次 push 后 Actions 跑到 `deploy` 阶段报 `HttpError: Not Found · Ensure GitHub Pages has been enabled`。

**原因**:GitHub Pages 需要在仓库 Settings 里开启才能被 `actions/deploy-pages` 用。gh CLI 上开 Pages 的命令是:

```bash
gh api --method POST /repos/OWNER/REPO/pages -f build_type=workflow
```

**修法**:第一次 push 后 · 手动开启 Pages(用上面命令 · 或去 GitHub Web UI Settings → Pages → Build source: GitHub Actions)· 然后 `gh workflow run deploy.yml` 手动触发一次。后续 push 就都正常了。

## SEO / 搜索引擎覆盖

### 索引状态

| 引擎 | 验证方式 | 状态 |
|---|---|---|
| **Google Search Console** | HTML meta 标签 · verification code 在 head.hbs / scripts/index.html | ✅ 已验证 + sitemap 已提交 |
| **Bing Webmaster Tools** | 从 GSC 一键导入 · sitemap 自动共享 | ✅ 已验证 |
| **IndexNow** | key 文件 `{key}.txt` 挂在站点根 · workflow 每次 push 自动 POST URL 列表 | ✅ 集成到 CI |
| **百度** | 不做 | ⏸ |

### IndexNow

**IndexNow 是 Bing / Yandex / Seznam 支持的主动通知机制** —— 每次 URL 更新时 POST 一下 URL 列表 · 搜索引擎立刻来抓 · 不用等 sitemap 定期爬。

**当前配置**:
- **key**:`7fc1636ecc8f7ed11fb3c8547168cd8859a13e66c3cf23643f76e3d3dbfb40ed`
- **key location**:`https://diaozxin007.github.io/reading-claude-code/{key}.txt`
- **触发时机**:workflow 里 `deploy` job 完成后 · `indexnow` job 自动跑 · 从 sitemap.xml 提取所有 URL · POST 到 `https://api.indexnow.org/indexnow`

**要新增 URL 到 IndexNow 通知**:改 `scripts/sitemap.xml` 加一条 `<url>` · workflow 自动提取并提交。

**脚本**:`scripts/submit-indexnow.sh` · workflow 在部署成功后调用。脚本从 sitemap 提取 URL，并从 `scripts/<key>.txt` 读取 key，避免在 workflow 里重复配置。

**本地验证**:`scripts/submit-indexnow.sh --dry-run` · 只生成并显示 payload，不发起网络请求。

**手工触发**:如果需要立刻通知(比如某篇内容有大改) · GitHub Web UI → Actions → 「Deploy mdBook to GitHub Pages」→ Run workflow 就会重新走一遍 build + deploy + indexnow。

## 联系

原作者 [@diaozxin007](https://github.com/diaozxin007) · Issue / PR 都欢迎。
