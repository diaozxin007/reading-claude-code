# 03 · Anthropic API Memory Tool · 从日期版本到客户端记忆文件系统

> 本篇仍属于 **Memory 研究系列**，回答“跨 session 的信息怎样留下来”；但 `memory_20250818` 本身是一个 tool，所以正文采用 Tools 系列的拆解方法：**作用 → 具体例子 → 触发条件 → 技术实现 → Prompt / Schema → 小结**。
>
> 姊妹篇 [02 · auto memory · 从一次纠正到 MEMORY.md](02-auto-memory.md) 讲 Claude Code 产品内部的 Auto Memory。本篇讲 Anthropic Messages API 提供的通用 Memory Tool。两者解决相似问题，但不是同一套实现。

## TL;DR

| 维度 | 结论 |
|---|---|
| **它是什么** | Anthropic 提供 schema、客户端负责执行的 Tool |
| **请求配置** | `{"type":"memory_20250818","name":"memory"}` |
| **日期后缀** | `20250818` 是 Tool 协议版本，不是记忆创建日期 |
| **调用方式** | Claude 发出 `tool_use`；应用执行后返回 `tool_result` |
| **命令集** | `view` / `create` / `str_replace` / `insert` / `delete` / `rename` |
| **存储位置** | 客户端控制，可映射到磁盘、数据库或对象存储 |
| **路径空间** | 模型看到的路径统一从 `/memories` 开始 |
| **跨会话关键** | 不同 session 必须连接到同一个持久化 store |
| **Claude Code 是否使用** | 研究版本 v2.1.220 没有使用这套 API；它有独立的 Auto Memory |

---

## 1 · 作用 · 给 Agent 一套能跨会话使用的文件系统

Memory Tool 解决的不是“当前对话还能记住多少”，而是：

> 当前 session 结束后，哪些信息能够保存下来，并在下一次 session 中重新读取？

它提供四个核心能力：

1. **跨会话持久化** —— 任务进度、用户偏好和项目决定不必一直留在 messages 中。
2. **按需读取** —— Claude 先看目录，再读取相关文件；不需要起手把所有历史塞进 context。
3. **模型自主维护** —— Claude 可以自己判断何时创建、修改、移动或删除记忆文件。
4. **存储权留在应用侧** —— Anthropic 定义交互协议，但不替应用保存文件。

这是一种 Just-in-time retrieval：context 里只保留当前需要的信息，长期信息先放在 context 外，需要时再通过 Tool 取回。

---

## 2 · 一个具体例子 · 新 session 先读取客服规则

假设一个客服 Agent 在上一次 session 中保存了退款规则。新的 session 里，用户说：

> Help me respond to this customer service ticket.

Claude 不需要用户重新贴一遍规则，而是先调用 Memory Tool：

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

应用把 `/memories` 映射到自己的存储，并返回目录：

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01",
  "content": "1.5K\t/memories/customer_service_guidelines.xml\n2.0K\t/memories/refund_policies.xml"
}
```

Claude 找到相关文件，再发起一次读取：

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

应用返回文件内容，Claude据此回答当前 ticket。完整链路是：

```text
用户提出任务
    ↓
Claude 调用 memory.view
    ↓
应用读取自己的持久化存储
    ↓
应用返回 tool_result
    ↓
Claude 使用取回的记忆继续任务
```

这里最重要的不是“多了一个文件读取工具”，而是**新的 session 仍然连着旧的存储**。如果应用每次 session 都创建一个新的内存字典，这套工具看起来能运行，却没有真正实现 Memory。

---

## 3 · 触发条件 · 什么时候应该使用

### 适合使用

- Agent 会运行多个 session，需要保存任务进度或长期决定。
- 不希望把全部历史一直塞在 context 中，而是希望按需读取。
- 应用需要自己控制数据的存储位置、加密、租户隔离和删除策略。
- 希望直接复用 Claude 已经熟悉的记忆文件操作协议，而不是重新设计一套 Tool schema。

### 不一定需要

- 信息只在当前 session 有效 —— 留在 messages 中即可。
- 内容很少，而且每次调用都必须看到 —— 直接注入 system prompt 或固定上下文更简单。
- 应用已经有成熟的数据库检索 Tool，只需要精确查询，不需要让模型维护文件树。
- 使用的是 Claude Code 产品内置的 Auto Memory —— 它走自己的 `MEMORY.md` 与抽取流程，不依赖 `memory_20250818`。

### 和相邻机制的边界

| 机制 | 解决的问题 | 信息何时进入 context |
|---|---|---|
| **messages** | 当前 session 的对话历史 | 每次调用重发 |
| **Compaction** | 当前历史太长 | 用摘要替换长历史 |
| **Memory Tool** | 信息跨 session 存活 | Claude 主动 `view` 时进入 |
| **Claude Code Auto Memory** | Claude Code 自动沉淀长期信息 | session 起手加载 `MEMORY.md`，并按需读取 topic 文件 |
| **普通检索 Tool** | 从业务数据库查事实 | 查询命中后进入 |

---

## 4 · 技术实现 · 一个标准 Tool Loop

### 4.1 · 一行 Tool 定义

请求的 `tools` 数组只需加入：

```json
{"type": "memory_20250818", "name": "memory"}
```

这两个字段承担不同职责：

- **`name: "memory"`** 是工具名。Claude 发出的 `tool_use.name` 是 `memory`。
- **`type: "memory_20250818"`** 选择这套 Tool 的协议版本。

`20250818` 是按日期命名的版本标识。Anthropic-provided tools 的 schema、行为或模型支持范围发生变化时，可以发布新的日期版本，同时保留旧版本，避免已有集成被静默破坏。

可以把它理解成：

> `name` 决定 Claude 调用哪个工具；`type` 决定客户端与 API 按照哪一版接口通信。

### 4.2 · 它属于哪一种 Tool

Anthropic 的 Tool 可以分成三类：

| 类型 | Schema 谁定义 | 谁执行 |
|---|---|---|
| **用户自定义 Tool** | 应用 | 应用 |
| **Anthropic-schema client Tool** | Anthropic | 应用 |
| **Server Tool** | Anthropic | Anthropic 服务端 |

Memory Tool 属于第二类：

- Anthropic 定义名称、输入 schema 和模型使用习惯。
- 应用不需要再声明 `input_schema`。
- Claude 发出标准 `tool_use`。
- 应用执行文件操作并返回 `tool_result`。

所以它既不是普通的自定义 Tool，也不是 Anthropic 帮你托管存储的服务端 Tool。

### 4.3 · 六种命令

| 命令 | 作用 | 关键参数 | 关键约束 |
|---|---|---|---|
| `view` | 列目录或读文件 | `path`、可选 `view_range` | 长文本分页；文本带行号；可以读取图片 |
| `create` | 创建文件 | `path`、`file_text` | 已存在时如何处理由实现决定 |
| `str_replace` | 精确替换文本 | `path`、`old_str`、可选 `new_str` | `old_str` 必须逐字匹配且唯一 |
| `insert` | 按行插入 | `path`、`insert_line`、`insert_text` | `0` 表示文件开头 |
| `delete` | 删除文件或目录 | `path` | 不能删除 `/memories` 根目录 |
| `rename` | 移动或重命名 | `old_path`、`new_path` | 不能重命名根目录；目标不能冲突 |

这套接口不像 KV store 的 `get/set`，而更像一个缩小版文本编辑器。Claude 可以先 `view`，再用 `str_replace` 精确修改局部内容，而不必每次重写整个记忆文件。

### 4.4 · `view` 的格式为什么很严格

读取文本时，官方推荐给每行加固定宽度的行号：

```text
     1	Hello World
     2	This is line two
    10	Line ten
```

核心格式是：

- 行号从 1 开始。
- 宽度为 6，右对齐。
- 行号与正文之间使用 tab。
- 长文件通过 `view_range` 分页。

这不是为了排版好看，而是给后续编辑提供稳定坐标。Claude先看到精确文本，才能生成唯一的 `old_str` 完成替换。

### 4.5 · 存储完全由客户端决定

模型看到的 `/memories` 只是一个逻辑前缀。应用可以把它映射到：

- 本地文件系统
- 每个用户独立的数据库空间
- S3 / R2 等对象存储
- 带加密和审计的企业存储

真正实现跨会话需要满足三个条件：

1. 相同用户的不同 session 路由到同一个 store。
2. 进程或容器重启后数据仍然存在。
3. 多个并发 session 修改同一文件时有版本或锁机制。

部分 Anthropic SDK 提供 Memory Tool helper 和本地文件系统示例，但 Tool 本身已经 GA，并不意味着所有 SDK helper 都脱离了 beta namespace。

### 4.6 · 安全边界

Memory Tool 把模型生成的路径交给应用执行，因此客户端必须承担文件系统安全责任。

最危险的错误是只检查：

```python
path.startswith("/memories")
```

因为 `/memories/../../secrets.env` 仍然能通过。正确思路是：

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

生产实现至少还要处理：

- URL 编码或其他形式的 path traversal
- 敏感信息写入前的二次校验
- 单文件大小、文件数量和读取长度上限
- 删除与覆盖操作的审计或回收站
- 多用户数据隔离
- 并发写入冲突

模型通常会避免主动保存敏感数据，但这不是安全边界。真正的强保证必须由客户端完成。

---

## 5 · Prompt 与 Schema · Tool 的形状怎样教模型工作

### 5.1 · 为什么不能自定义名称和 schema

普通 Tool 由开发者填写 `name`、`description` 和 `input_schema`。Memory Tool 不需要，因为 Anthropic 已经定义并训练了这套接口。

这意味着：

- `name` 必须是 `memory`。
- `type` 必须选择一个受支持的 Memory Tool 版本。
- 参数名和命令结构由 Anthropic 提供。
- 应用的主要自由度在**执行与存储层**，不在 Tool 外形。

固定接口的收益是模型不必临时理解每个应用自创的“记忆协议”；代价是应用需要适配既有 schema。

### 5.2 · API 自动注入行为提示

启用 Memory Tool 后，API 会给模型补充 Memory Protocol。最核心的一句是：

> ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.

这段提示还要求模型假设 context 可能随时中断，并及时记录进度。它塑造了两个行为习惯：

1. **新 session 起手先读** —— 先恢复历史状态，再继续任务。
2. **任务过程中及时写** —— 不等全部完成才保存，避免中断时丢失中间进度。

协议本身没有在运行时强制“第一步必须 view”，但 Prompt 会让模型倾向于这样做。这正是 Tools 系列反复出现的设计：**先用 Prompt 塑造正确路径，再由客户端守住硬边界。**

### 5.3 · 返回字符串也是软协议

应用可以自由组织 `tool_result` 文本，但官方推荐的目录格式、错误模板和成功提示不是随意文案。Claude 熟悉这些模式，看到“路径不存在”“匹配不唯一”等返回后，更容易采取正确的恢复动作。

因此，定制 Tool Result 时更稳妥的做法是：

- 保留官方核心语义和结构。
- 自定义错误码、trace id 等信息放在末尾。
- 面向用户的本地化文案与给模型看的 Tool Result 分开。

Tool Result 在这里不仅是执行结果，也是模型下一步决策的输入。

### 5.4 · 三个容易误解的设计

#### `create` 不一定等于“只创建”

模型可能把 `create` 理解成“创建或覆盖”，而参考 handler 可以在文件存在时返回错误。客户端必须明确选择语义：允许覆盖、拒绝覆盖，或覆盖前自动备份。最糟糕的是语义不明确，让同一个请求在不同后端产生不同结果。

#### `view` 不只读取文本

Memory 目录可能包含 `.jpg`、`.jpeg`、`.png`。应用如果承诺支持官方完整行为，就要能返回图片 content block，而不是默认所有文件都能按 UTF-8 解码。

#### 错误文本可以自定义，但不应随意

Claude 能理解自然语言错误，但越接近熟悉的返回结构，错误恢复越稳定。协议允许自由，不代表所有表达都有相同效果。

---

## 6 · 回到 Memory 主题 · 它如何影响 Context 与产品设计

### 6.1 · Memory、Context Editing 与 Compaction

长时间运行的 Agent 通常同时需要三种机制：

- **Context Editing** 清理已经不需要的旧 Tool Result。
- **Compaction** 在历史接近 context window 上限时生成摘要。
- **Memory Tool** 保存必须跨摘要、跨 session 存活的信息。

它们处理的是不同时间尺度：

```text
当前几轮的临时结果 ── Context Editing
当前 session 的长历史 ── Compaction
多个 session 之间的长期信息 ── Memory Tool
```

Memory 文件不应该变成“把所有历史再复制一遍”的垃圾场。适合写入的是长期决定、任务进度、稳定偏好和下一次恢复任务所必需的信息。

### 6.2 · Claude Code 为什么不用它

在本文研究的 Claude Code v2.1.220 源码中，没有找到 `memory_20250818` Tool 定义。Claude Code 的 Auto Memory 是另一套产品实现：

| 维度 | API Memory Tool | Claude Code Auto Memory |
|---|---|---|
| **读取入口** | Claude 主动调用 `memory.view` | 起手注入 `MEMORY.md` 索引，细节按需读取 |
| **写入主体** | 当前模型通过 Tool 自主写 | 主 Agent 直写或 extraction fork 补漏 |
| **编辑接口** | 六种 Memory 命令 | Claude Code 的 Read / Edit / Write 与 `/memory` UI |
| **存储设计** | 应用自行决定 | Claude Code 规定目录和文件结构 |
| **产品能力** | 通用协议原语 | 私人、团队、Agent scope 等产品能力 |

验证线索包括：

- 源码中没有 `memory_20250818` 字面量。
- `src/tools/` 没有 MemoryTool。
- Session Memory 直接使用文件系统 API。
- Memory extraction 使用 Claude Code 自己的 Read / Edit / Write。

因此，**API Memory Tool 与 Claude Code Auto Memory 不能混为一谈**。前者给 Agent 开发者一套通用协议；后者是 Claude Code 围绕自身产品体验构建的记忆系统。

### 6.3 · 自研 Agent 的两条路线

如果自研一个基于 Anthropic API 的 Agent，有两种主要选择：

- **采用 Memory Tool** —— 复用现成 schema 和模型行为，实现客户端 handler、持久化与安全边界。
- **自建记忆系统** —— 自己决定何时抽取、如何索引、怎样注入 context、如何 GC，以及是否提供人工编辑界面。

前者更接近“先获得可用的跨会话记忆”；后者适合需要复杂 scope、团队协作、审批和产品化管理的系统。

---

## 7 · 小结 · Tool 是实现形态，Memory 是功能主题

Memory Tool 最值得带走的不是六个命令，而是它的分工方式：

- Anthropic 固定 Tool schema 和模型行为。
- Claude 决定何时读写。
- 客户端负责执行、持久化和安全。
- Memory 留在 context 外，需要时才通过 Tool 进入。

### 设计取舍

1. **客户端存储，而不是 Anthropic 托管** —— 数据控制权更强，但应用承担安全与运维责任。
2. **文件树，而不是简单 KV** —— 表达力更强，但接口和并发控制更复杂。
3. **Prompt 塑造行为，客户端执行硬约束** —— 模型负责判断，程序负责守底线。
4. **日期版本固定协议** —— 接口可以演进，又不破坏已有集成。

### 常见反模式

- 只用 `startswith("/memories")` 检查路径。
- 把记忆保存在 session 内存，进程重启后全部消失。
- 不做用户隔离和并发控制。
- 把所有历史都写入 Memory，重新制造一个无限增长的 context。
- 只依赖模型避免保存敏感信息。
- 自定义 schema 或错误文本，却忽略模型已经熟悉的协议形状。

### 演进信号

- Claude 频繁扫描无关目录 → 增加索引或重新设计文件结构。
- 同一信息反复写入 → 增加去重或独立 extraction pipeline。
- 文件数量持续增长 → 增加保留期限、容量限制和 GC。
- 需要团队共享、权限和审批 → 从通用 Memory Tool 演进到产品级记忆系统。

一句话总结：

> **`memory_20250818` 是一套日期版本化的 Tool 协议；它用 Tool 的方式，让客户端控制的存储变成 Claude 可以自主维护的跨会话记忆。**

下一篇 [04 · Subagent memory · 从 agent type 到三层持久目录](04-subagent-memory.md) 回到 Claude Code 产品内部，继续看 sub-agent 的记忆如何按 user / project / local 三种 scope 持久化。

---

## 参考

### Anthropic 官方

- [Memory Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- [Tool reference · Anthropic-provided tools 与日期版本](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference)
- [Tool use overview](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)
- [Context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing)
- [Compaction](https://platform.claude.com/docs/en/build-with-claude/compaction)
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

### SDK 示例

- [Python SDK Memory 示例](https://github.com/anthropics/anthropic-sdk-python/blob/main/examples/memory/basic.py)
- [TypeScript SDK Memory 示例](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/examples/tools-helpers-memory.ts)
- [C# SDK Memory 示例](https://github.com/anthropics/anthropic-sdk-csharp/tree/main/examples/MemoryToolExample)
- [Java SDK Memory 示例](https://github.com/anthropics/anthropic-sdk-java/blob/main/anthropic-java-example/src/main/java/com/anthropic/example/BetaMemoryToolExample.java)

### Claude Code v2.1.220 源码定位

- `src/services/SessionMemory/sessionMemory.ts` · Session Memory 直接使用文件系统 API
- `src/services/extractMemories/extractMemories.ts` · extraction fork 使用 Read / Edit / Write
- `src/commands/memory/memory.tsx` · `/memory` 人工编辑界面
- `src/tools/` · 没有 MemoryTool 定义

### 系列内关联

- [02 · auto memory · 从一次纠正到 MEMORY.md](02-auto-memory.md) · Claude Code Auto Memory
- [05 · Memory extraction pipeline · 从一轮结束到受限 fork](05-extraction-pipeline.md) · extraction fork 的完整流程
- [04 · Compaction 六兄弟 · 从手动到无处不在的压缩](../context-management/04-compaction.md) · Compaction 对 context 的影响
