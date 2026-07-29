这个系列后续每篇会拆一个具体 tool。在此之前，先把 "tool 是什么、Claude 怎么用" 讲清楚 —— 后面所有拆解都建立在这个底子上。

## 为什么要有 tool

LLM 本身只会**生成文本**。这带来两个硬伤：

1. **不能操作外部世界** —— 光生成 "我把文件删了" 这句话没用，文件还在
2. **输出不可靠** —— 模型可能返回结构不对、字段缺失、幻觉内容的文本，下游程序没法稳定消费

Tool 补上的正是这两块：

- **动作** —— 声明一个可执行函数，模型调用后由 harness 真的执行（读文件、发请求、切模式）
- **结构** —— 用 JSON schema 声明入参 · 模型必须按 schema 输出 · 不符合直接被拦住

从这个视角看，tool 不是 "让 LLM 更强"，而是**让 LLM 和外部世界之间有一个可信通道**。

## 一个 tool 定义长什么样

Anthropic API 的 tool 定义是一个 JSON 对象。看 AskUserQuestion 简化版：

```json
{
  "name": "AskUserQuestion",
  "description": "Use this tool only when you are blocked on a decision that is genuinely the user's to make: one you cannot resolve from the request, the code, or sensible defaults. ...",
  "input_schema": {
    "type": "object",
    "properties": {
      "questions": {
        "type": "array",
        "description": "Questions to ask the user (1-4 questions)",
        "minItems": 1,
        "maxItems": 4,
        "items": {
          "type": "object",
          "properties": {
            "question": {
              "type": "string",
              "description": "The complete question to ask the user. Should be clear, specific, and end with a question mark. Example: \"Which library should we use for date formatting?\""
            },
            "header": {
              "type": "string",
              "maxLength": 12,
              "description": "Very short label displayed as a chip/tag (max 12 chars). Examples: \"Auth method\", \"Library\", \"Approach\"."
            },
            "multiSelect": {
              "type": "boolean",
              "default": false,
              "description": "Set to true to allow the user to select multiple options ..."
            },
            "options": {
              "type": "array",
              "minItems": 2,
              "maxItems": 4,
              "items": { "...": "..." }
            }
          },
          "required": ["question", "header", "options"]
        }
      }
    },
    "required": ["questions"]
  }
}
```

三个顶级字段：

- **`name`** —— 工具唯一标识，同时也是给模型看的**命名信号**
- **`description`** —— 一段自然语言，讲这个工具是什么、什么时候用、什么时候不用
- **`input_schema`** —— JSON schema，声明入参结构 + 每个字段的 description + 校验规则

这就是 tool 定义的**全部** —— 没有隐藏配置，没有其他元数据。所有设计意图都必须编码进这三个字段。

## 三大字段各自在做什么

后续每篇文章会按 4 层拆解 tool，这 4 层其实就是三大字段的展开：

| 层 | 位置 | 作用 |
|---|---|---|
| 1 · 命名 | `name` + schema 里的字段名 | 望文生义传语义 |
| 2 · 工具级描述 | `description` | 决定 "是不是我要用的工具" |
| 3 · 字段级描述 | `input_schema` 里每个字段的 description | 决定 "这个字段填什么" |
| 4 · schema 校验 | `input_schema` 里的 type / minItems / maxLength / enum 等 | 硬拦截错误输入 |

**信号密度递减，覆盖面递增**：

- 命名 —— 一个词就能感知（每次读到字段名都在训练）
- 工具描述 —— 每次考虑用这个工具时都会读到（宏观边界）
- 字段描述 —— 填字段时才读到（精确 hint）
- schema 校验 —— 只在写错时才被感知（硬拦截）

一个 tool 定义的完整 prompt 表面 = 这 4 层叠加。

## Claude 是怎么"读到"这些的

**所有 tool 定义会拼进 system prompt，随每次请求发给模型**。这是关键 —— 不是 "调用的时候才加载"，而是**常驻**在对话上下文里。

具体流程：

1. Harness 启动时收集所有可用 tool 定义
2. 每次向 Claude 发送请求时，把 tool 列表附在请求的 `tools` 参数里
3. Claude 收到的 prompt 结构大致是：`system prompt` + `tools 定义`（JSON 形式全文注入）+ `messages` 对话历史

这个机制带来两个直接后果：

- **描述里每个字都花 token** —— 一个 20 KB 的 tool 定义每次请求都要发一遍，token 成本乘以对话轮次
- **描述可以引用其他 tool** —— 因为所有 tool 都在同一份 system prompt 里，写 AskUserQuestion 时可以直接说 "不要用来问『方案 OK 吗』，那是 ExitPlanMode 的职责"

这也是为什么好的 tool 描述要**又短又精**：短是省 token，精是每一句都在承担限制职责/边界/协作契约的功能。

## Claude 怎么调用一个 tool

一次调用是一次 **消息往返**：

**Step 1 · 模型输出 tool_use block**

Claude 决定要用某个 tool 时，不是直接执行，而是在回复里输出一个特殊 block：

```json
{
  "type": "tool_use",
  "id": "toolu_01A09q90qw90lq917835lq9",
  "name": "AskUserQuestion",
  "input": {
    "questions": [
      {
        "question": "选哪种认证方式？",
        "header": "认证方式",
        "options": [
          { "label": "JWT（推荐）", "description": "无状态、易横向扩展" },
          { "label": "会话 cookie", "description": "server-side session store" },
          { "label": "OAuth", "description": "接第三方身份提供商" }
        ]
      }
    ]
  }
}
```

**Step 2 · Harness 拦截并执行**

模型的输出被 harness 截住，harness 检查 `name` 找到对应工具，把 `input` 传给实现（可以是本地函数、可以是外部服务、可以是 UI 交互）。执行完拿到结果。

**Step 3 · Harness 用 tool_result 把结果送回模型**

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
  "content": "用户选择：JWT（推荐）"
}
```

这个 block 作为新一条 user 消息发回给 Claude。Claude 继续对话 —— 可以基于返回值再调用下一个 tool，也可以直接给用户输出文本回复。

整个过程模型都在扮演**决策者**的角色 —— 什么时候调、调哪个、传什么参数、拿到结果怎么用 —— 全靠模型自己判断。Harness 只负责执行和传递结果。

## 返回值的两种模式

**成功** —— `tool_result` 带内容：

```json
{
  "type": "tool_result",
  "tool_use_id": "...",
  "content": "..."
}
```

`content` 可以是纯文本，也可以是结构化 block（多段文本 + 图片等）。

**失败** —— 加 `is_error: true`：

```json
{
  "type": "tool_result",
  "tool_use_id": "...",
  "content": "Error: file not found",
  "is_error": true
}
```

**Loud fail**：错误不静默，模型能感知失败并决定下一步（重试、换方案、问用户）。这也是为什么好的 tool 会用严格 schema 校验 —— 拦住的错误在 harness 层就返回明确失败，而不是让模型拿到一个语义模糊的空结果继续走。

**返回内容占用主循环 context**：模型每次收到 tool_result 都会读进上下文。这意味着：

- 返回体积**必须节制** —— 一个 grep 返回 10 万行会把上下文瞬间打满
- 好的工具会**提前摘要 / 截断 / 分页**（比如 Read 默认只读 2000 行、Grep 有 head_limit）
- 这也解释了为什么 Claude Code 有大量看似 "读取" 类工具却总是返回精简结果 —— 不是能力弱，是有意的 context 预算管理

## Tool 是结构化 prompt engineering

对比一下：

**自由 prompt 版本**：

> 你可以调用一个叫 AskUserQuestion 的函数，向用户问问题，用户选完后你会收到答案。

**Tool 版本**：

- `name` = "AskUserQuestion"
- `description` = 一段几百字的行为约束
- `input_schema` = 精确到字段的类型 + 校验 + few-shot

差别不在 "能不能实现"，而在**能不能稳定**：

| 维度 | 自由 prompt | Tool |
|---|---|---|
| 结构 | 模型自由发挥 | JSON schema 硬约束 |
| 失败 | 结构错了可能静默返回错误值 | schema 校验拦住，明确失败 |
| 边界 | 模型靠感觉决定用不用 | description 明说该用 / 不该用 |
| 组合 | 需要模型记住多个函数的关系 | 每个 tool 描述里可以直接引用其他 tool |
| 主循环感知 | 结果混在对话文本里 | 结构化 tool_use + tool_result，harness 可拦截 |

Tool 本质上是 **结构化的 prompt engineering**：把 "让模型稳定做某件事" 这个软性需求，编码成可校验、可组合、可维护的规格。

## 系列后续预告

搞清楚 tool 机制后，后续每篇会用同一个骨架拆一个具体 tool：

1. 作用
2. 一个具体例子（含反例对照）
3. 触发条件
4. 技术实现 —— 按 4 层展开
   - 1 · 命名
   - 2 · 工具级描述
   - 3 · 字段级描述
   - 4 · schema 校验规则
5. 与邻居工具的分工
6. 小结

前置篇讲**机制** —— tool 是什么、Claude 怎么用。后续讲**设计** —— 具体 tool 是怎么把这 4 层用满，让一个能力从"能做"变成"稳定、可预测、可协作"。

下一篇从 [AskUserQuestion](interaction/ask-user-question.md) 开始。
