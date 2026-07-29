# CLAUDE.md · reading-claude-code

这份文档给未来协作维护这本书的 Claude 看 —— 让新 session 快速进入状态,不用每次问相同问题。

## 项目定位

**《一同读 Claude Code》** —— 一本关于 Claude Code 工具原语设计的深度拆解。每一个 tool 都在防止什么。

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
├── zh/                     (中文站 mdBook 项目)
│   ├── book.toml           (mdBook 主配置)
│   └── src/
│       ├── SUMMARY.md      (中文目录 · mdBook 靠这个组装书本结构)
│       ├── preface.md      (前言)
│       ├── philosophy.md   (设计哲学 · 起步章)
│       ├── tool-mechanism.md   (Tool 机制 · 起步章)
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

原始起草稿放在 `ORIGINAL_VAULT_PATH_REDACTED/Claude code tools 研究系列/` · 里面有:

- 16 篇 vault 原始版本(还带 obsidian wikilink)
- 1 篇 AI 协作方法论复盘(这本书是怎么被 AI 协作写出来的元证据)

如果需要**回查原始起草稿** · 去那个目录。

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

- 英文站目前只有骨架,内容多数还未翻译
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

## 联系

原作者 [@diaozxin007](https://github.com/diaozxin007) · Issue / PR 都欢迎。
