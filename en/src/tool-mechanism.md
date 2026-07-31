Each subsequent article in this series will dissect a specific tool. But first, let's establish the foundation: what a tool is and how Claude uses it. Everything that follows builds on this understanding.

## Why Tools Exist

An LLM on its own can only **generate text**. This creates two fundamental limitations:

1. **It cannot act on the external world** -- generating the sentence "I deleted the file" is useless; the file is still there
2. **Its output is unreliable** -- the model might return text with wrong structure, missing fields, or hallucinated content that downstream programs can't reliably consume

Tools fill exactly these two gaps:

- **Action** -- declare an executable function; once the model invokes it, the harness actually executes it (reading files, making requests, switching modes)
- **Structure** -- use JSON Schema to declare input parameters; the model must output according to the schema; non-conforming output is rejected outright

From this perspective, tools don't "make the LLM more powerful" -- they **create a trusted channel between the LLM and the external world**.

## What a Tool Definition Looks Like

An Anthropic API tool definition is a JSON object. Here's a simplified version of AskUserQuestion:

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

Three top-level fields:

- **`name`** -- the tool's unique identifier, which also serves as a **naming signal** for the model
- **`description`** -- natural language explaining what this tool is, when to use it, and when not to
- **`input_schema`** -- JSON Schema declaring the input structure, per-field descriptions, and validation rules

This is **everything** in a tool definition -- no hidden configuration, no other metadata. All design intent must be encoded into these three fields.

## What Each of the Three Fields Does

Each subsequent article will dissect tools across 4 layers. These 4 layers are simply an expansion of the three fields:

| Layer | Location | Purpose |
|---|---|---|
| 1 - Naming | `name` + field names in the schema | Convey semantics at a glance |
| 2 - Tool-level description | `description` | Determine "is this the tool I should use?" |
| 3 - Field-level description | `description` within each field of `input_schema` | Determine "what do I fill in here?" |
| 4 - Schema validation | `type` / `minItems` / `maxLength` / `enum` etc. in `input_schema` | Hard-reject invalid input |

**Signal density decreases while coverage increases**:

- Naming -- a single word conveys meaning (reinforced every time the model reads a field name)
- Tool description -- read every time the model considers using this tool (macro-level boundaries)
- Field description -- read only when filling in a field (precise hints)
- Schema validation -- perceived only when the model gets it wrong (hard rejection)

The complete prompt surface of a tool definition = these 4 layers stacked together.

## How Claude "Sees" All This

**All tool definitions are concatenated into the system prompt and sent with every request to the model.** This is key -- they're not "loaded on demand when called," they're **always present** in the conversation context.

The specific flow:

1. The harness collects all available tool definitions at startup
2. Each time a request is sent to Claude, the tool list is attached via the `tools` parameter
3. The prompt structure Claude receives looks roughly like: `system prompt` + `tools definitions` (injected as full JSON) + `messages` conversation history

This mechanism has two direct consequences:

- **Every word in a description costs tokens** -- a 20 KB tool definition is sent with every request, token cost multiplied by conversation turns
- **Descriptions can reference other tools** -- since all tools live in the same system prompt, AskUserQuestion's description can say "don't use this to ask 'is the plan OK?' -- that's ExitPlanMode's job"

This is why good tool descriptions must be **both concise and precise**: concise to save tokens, precise because every sentence carries the weight of constraining responsibility, boundaries, and collaboration contracts.

## How Claude Invokes a Tool

A single invocation is one **message round-trip**:

**Step 1 - Model outputs a tool_use block**

When Claude decides to use a tool, it doesn't execute directly. Instead, it outputs a special block in its response:

```json
{
  "type": "tool_use",
  "id": "toolu_01A09q90qw90lq917835lq9",
  "name": "AskUserQuestion",
  "input": {
    "questions": [
      {
        "question": "Which authentication method should we use?",
        "header": "Auth method",
        "options": [
          { "label": "JWT (recommended)", "description": "Stateless, easy to scale horizontally" },
          { "label": "Session cookie", "description": "Server-side session store" },
          { "label": "OAuth", "description": "Integrate with third-party identity providers" }
        ]
      }
    ]
  }
}
```

**Step 2 - Harness intercepts and executes**

The model's output is intercepted by the harness. The harness looks up the corresponding tool by `name`, passes `input` to the implementation (which could be a local function, an external service, or a UI interaction), and gets back the result.

**Step 3 - Harness sends the result back via tool_result**

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
  "content": "User selected: JWT (recommended)"
}
```

This block is sent back to Claude as a new user message. Claude continues the conversation -- it can call another tool based on the return value, or directly output a text response to the user.

Throughout this process, the model plays the role of **decision-maker** -- when to call, which tool to call, what parameters to pass, how to use the result -- all determined by the model itself. The harness is only responsible for execution and relaying results.

## Two Modes of Return Values

**Success** -- `tool_result` with content:

```json
{
  "type": "tool_result",
  "tool_use_id": "...",
  "content": "..."
}
```

`content` can be plain text or structured blocks (multiple text segments + images, etc.).

**Failure** -- with `is_error: true`:

```json
{
  "type": "tool_result",
  "tool_use_id": "...",
  "content": "Error: file not found",
  "is_error": true
}
```

**Loud fail**: errors are never silent -- the model perceives the failure and decides the next step (retry, try a different approach, ask the user). This is also why good tools use strict schema validation -- rejected errors return explicit failures at the harness layer, rather than letting the model receive a semantically ambiguous empty result and continue onward.

**Return content occupies the main loop context**: every time the model receives a tool_result, it's read into the context. This means:

- Return size **must be controlled** -- a grep returning 100,000 lines would instantly exhaust the context
- Good tools **pre-summarize / truncate / paginate** (e.g., Read defaults to only 2000 lines, Grep has a head_limit)
- This also explains why Claude Code has so many seemingly "read" tools that always return compact results -- it's not a lack of capability, it's intentional context budget management

## Tools Are Structured Prompt Engineering

Compare the two approaches:

**Free-form prompt version**:

> You can call a function called AskUserQuestion to ask the user questions. After the user responds, you'll receive their answer.

**Tool version**:

- `name` = "AskUserQuestion"
- `description` = several hundred words of behavioral constraints
- `input_schema` = field-level types + validation + few-shot examples

The difference isn't "whether it can be done," but **whether it can be done reliably**:

| Dimension | Free-form prompt | Tool |
|---|---|---|
| Structure | Model improvises | JSON Schema hard constraints |
| Failure | Structural errors may silently return wrong values | Schema validation catches them, explicit failure |
| Boundaries | Model decides based on intuition | Description explicitly states when to use / not use |
| Composition | Model must memorize relationships between functions | Each tool description can directly reference other tools |
| Main loop awareness | Results mixed into conversation text | Structured tool_use + tool_result, harness can intercept |

Tools are essentially **structured prompt engineering**: encoding the soft requirement of "make the model reliably do X" into a specification that is verifiable, composable, and maintainable.

## Series Preview

Now that we understand the tool mechanism, each subsequent article will use the same skeleton to dissect a specific tool:

1. Purpose
2. A concrete example (with counter-examples for contrast)
3. Trigger conditions
4. Technical implementation -- expanded across 4 layers
   - 1 - Naming
   - 2 - Tool-level description
   - 3 - Field-level description
   - 4 - Schema validation rules
5. Division of labor with neighboring tools
6. Summary

This introductory article covers **mechanism** -- what a tool is and how Claude uses it. Subsequent articles cover **design** -- how specific tools leverage all 4 layers to transform a capability from "can do" to "reliable, predictable, and collaborative."

The next article starts with [AskUserQuestion](interaction/ask-user-question.md).
