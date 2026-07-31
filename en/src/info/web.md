This is the eleventh installment of the Claude Code Tools research series. The previous ten covered Claude Code's main **inward-facing toolset** — from aligning with the user, to operating on the local filesystem, to executing commands, to spawning subagents, to managing task lists. Every tool revolves around the **local environment**: modifying local code, running local tests, spawning local Claude instances.

But in real engineering work, Claude frequently needs to **reach beyond the local** — read an Anthropic API doc, check a third-party library's GitHub README, look up the latest npm tutorial, verify an official spec. This information isn't local, and it's not in the training data (or the training data is outdated).

This calls for **internet access tools**. Claude Code's answer is a duo: **WebFetch precisely retrieves the content of a known URL; WebSearch finds things across the entire internet by keywords**.

> This series assumes you've read the [prerequisite article](../tool-mechanism.md) — explaining what tools are and how Claude uses them. This article follows the 4-layer framework introduced there.

## WebFetch + WebSearch

We cover both in one article. The reasoning is the same as in the fourth article on Grep + Glob: the two tools are semantically tightly coupled — one "fetches by URL," the other "searches by query" — and they're often used in combination (Search to find a URL, then Fetch to get the content). Splitting them would mean repeating a lot.

### Family Overview

Here's a table for an at-a-glance view of each tool's responsibility:

| Tool | Input | Output | Typical Scenario |
|---|---|---|---|
| **WebFetch** | A known URL | Page content (HTML -> Markdown) | "Read this doc and extract X" |
| **WebSearch** | Keywords | A set of search results (title + URL) | "Find the latest approach for xxx" |

**Core division of labor**:

- **Know the URL** — use WebFetch directly, skip searching
- **Don't know the URL** — use WebSearch to find it, then WebFetch to dig deeper

This division perfectly mirrors local Grep+Glob — Grep+Glob does "search + locate" within the local filesystem; WebSearch+WebFetch does the same thing on the internet. **Same mental model, different domain**.

### Purpose

The core problem WebFetch + WebSearch jointly solve is "how Claude **breaks through the temporal and scope boundaries of training data** to get the latest and most specific external information":

1. **Breaking the temporal boundary** — Training data has a cutoff, but WebSearch/Fetch can get today's information
2. **Breaking the scope boundary** — Training data may not include the niche library your project uses, but WebFetch can read its official docs
3. **Official information verification** — The previous [opening article](../interaction/ask-user-question.md) discussed fact-checking discipline: claims with "citation/official" language must actually retrieve the source — that's WebFetch's responsibility
4. **Content compression** — WebFetch uses AI to process content, returning only the part relevant to your prompt, rather than stuffing the entire HTML page into Claude

The key difference from all previous tools: **this is the only tool family that "crosses the local boundary."** The previous ten tools' inputs and outputs all stay on the local machine. WebFetch+WebSearch are Claude's interface with the **external world (the public internet)**.

### A Concrete Example

**Scenario**: The user says **"Anthropic seems to have released a new Claude 4.5 Sonnet model recently. Help me look up its API usage, especially what's different from version 4, and also check the pricing."**

This is a typical task where **the information is on the internet, not local, and may be beyond the training cutoff**. Claude absolutely cannot rely on training memory to answer:

- The model was newly released; training data didn't catch it
- API parameters may have changed; guessing would be hallucination
- Pricing numbers especially can't be made up — reporting wrong ones has consequences

#### Step 1: Use WebSearch to Find Entry Points

Claude doesn't know the exact URL but knows to look on anthropic.com. First step — WebSearch:

```
WebSearch(
  query: "Claude 4.5 Sonnet API pricing announcement 2026",
  allowed_domains: ["anthropic.com", "docs.anthropic.com"]
)
```

**Note**: Uses `allowed_domains` to constrain the domain — only search official sites, excluding marketing blogs / second-hand retellings.

WebSearch returns a set of results:

```
1. Claude 4.5 Sonnet — Anthropic
   https://www.anthropic.com/news/claude-4-5-sonnet
2. Models Overview — Anthropic Docs
   https://docs.anthropic.com/en/docs/about-claude/models
3. Pricing — Anthropic
   https://www.anthropic.com/pricing
```

**Each result is title + URL** — not the full text. Claude now has three precise entry points.

#### Step 2: Use WebFetch to Dig Into Specific Content

Claude WebFetches the three URLs in sequence, each time with a **specific prompt** telling WebFetch what to extract:

```
WebFetch(
  url: "https://www.anthropic.com/news/claude-4-5-sonnet",
  prompt: "Extract: model release date · main improvements over Claude 4 · benchmark numbers · API model ID"
)
```

**Key point**: WebFetch's second parameter isn't "return the full text" — it's **"process the content using this prompt."** Behind the scenes, the runtime:

- Fetches the URL
- Converts HTML to Markdown
- **Uses a small, fast model** to extract relevant parts from the content according to Claude's prompt
- Returns only the extraction result to Claude

This means a 5,000-word blog post results in Claude receiving only 200 words of key information. **Just like an Agent dispatching a subagent, it's a context compression mechanism**.

After three WebFetch calls, Claude has three structured summaries and can give the user a complete answer covering API usage + differences + pricing.

#### Key Insight: WebFetch Is "curl with AI"

Traditional `curl` is "input URL, return raw HTML." WebFetch is "input URL + intent, return **processed results**."

This difference is profound:

- **curl** makes Claude bear the burden of HTML parsing, CSS interference, ad filtering, etc.
- **WebFetch** offloads all that to an AI in the runtime — Claude receives answers that have already been **"extracted according to your question"**

This design makes WebFetch a **"primitive for on-demand information extraction from the internet"** — not a "web page downloader."

### Trigger Conditions

**When to use WebSearch**:

- **Need latest information** — things after the training data cutoff (new releases, latest pricing, current-year events)
- **Don't know the exact URL** — use keywords to find entry points
- **Compare multiple sources** — pick several authoritative sources from search results
- **Search within specific domains** — use `allowed_domains` to constrain
- **Exclude specific domains** — use `blocked_domains` to block junk sites

**When to use WebFetch**:

- **Known URL** — user gave it directly, or obtained from WebSearch
- **Read official docs / specs / API references** — extract according to a specific prompt
- **Verify citations** — fact-checking discipline requires citations come from actually retrieved sources
- **Grab GitHub READMEs / docs** — though `gh` CLI works better (see below)

**When to combine both**:

- **Typical pipeline**: WebSearch to find URLs -> pick the most reliable -> WebFetch to dig in -> synthesize a response
- **Comparative research**: WebSearch to get 3~5 sources -> WebFetch each -> cross-validate

**When NOT to use them**:

- **Information is in training data** — don't go online for no reason; if training data can answer it, answer directly (e.g., basic JavaScript syntax)
- **GitHub-related content** — use `gh` CLI (via Bash); WebFetch on GitHub URLs often hits permission issues
- **Authenticated URLs** — WebFetch grabs public URLs; Google Docs / Confluence / Jira / private GitHub can't be fetched (will get 401/403)
- **Can be found locally** — knowledge already in the local project should use Grep, not WebSearch

A **core principle**: **avoid going online whenever possible**. Going online is slow, expensive, and has failure modes (network issues, blocks, page redesigns). **Only go to the public internet when both local and training data are insufficient.**

### Technical Implementation

WebFetch and WebSearch are **sibling tools** — with clear division of labor but shared design philosophy (both cross the local boundary to fetch public internet information). We'll break them down through the 4 layers separately, then revisit their duality.

---

## WebFetch

#### 1 - Naming

`WebFetch`

The name directly states what it does — **fetch a web resource**. "Fetch" is an industry-standard verb (fetch API, `git fetch`), implying "pull toward you" rather than "actively search." The field `url` is also a name anyone who's done web work instantly understands.

If it were called `ReadURL`, that would be misleading — it's not part of the Read family (Read is lossless full-content), but rather **on-demand extraction with AI processing**. Calling it `HTTPGet` would be too low-level, losing the core promise of "AI processes it according to your prompt." **"Fetch" sits precisely between "pull raw content" and "AI processing."**

#### 2 - Tool-Level Description

WebFetch's description is heavier than most tools — it opens with an all-caps IMPORTANT, followed by a series of Usage notes, centered on four things: **authentication failure warning, MCP deference, GitHub specialization, redirect protocol**.

**Opening IMPORTANT: Authenticated Service Blocklist**

> IMPORTANT: WebFetch WILL FAIL for authenticated or private URLs. Before using this tool, check if the URL points to an authenticated service (e.g. Google Docs, Confluence, Jira, GitHub). If so, look for a specialized MCP tool that provides authenticated access.

**The heaviest sentence in the entire WebFetch description.** Using IMPORTANT + all-caps WILL FAIL as double emphasis: **don't waste a call hitting a 401**. It also **provides an alternative path** — find a specialized MCP tool. This prompt trains Claude to build the instinct of "check the toolset before acting": **every "no" comes with a "yes"** — it doesn't just say it won't work, but "it won't work, but you can go this way."

**MCP Priority Deference**

> IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one, as it may have fewer restrictions.

**Explicitly yields to MCP** — acknowledging its own limited capabilities. If the session has a dedicated web fetch MCP, let it take priority. This is a rare "humility" posture in the tool ecosystem. It echoes the first point: **for authenticated content, find MCP; for more capable general fetching, also find MCP**.

**GitHub Specialization Guidance**

> For GitHub URLs, prefer using the gh CLI via Bash instead (e.g., gh pr view, gh issue view, gh api).

**GitHub is called out specifically** because it's so common. Using `gh` CLI through Bash leverages the user's locally authenticated credentials and can get more information than WebFetch scraping a public page (e.g., private repos, review comments). This is a classic case of **specific scenarios overriding general tools** — the tool description explicitly says "don't use me for this scenario."

**Explicit Cross-Domain Redirect Protocol**

> When a URL redirects to a different host, the tool will inform you and provide the redirect URL in a special format. You should then make a new WebFetch request with the redirect URL to fetch the content.

**Does not automatically follow cross-domain redirects** — handing the decision to Claude. This prevents a class of attacks: luring WebFetch through a redirect to a domain you didn't realize. Making Claude explicitly confirm before fetching is a **security boundary**. **Follow same-domain redirects, report cross-domain ones** — a default that's both convenient and not out of control.

**15-Minute Cache Transparency**

> Includes a self-cleaning 15-minute cache for faster responses when repeatedly accessing the same URL

Tells Claude there's a cache — re-fetching the same URL within a short time will be faster, **encouraging confident repeated calls within the same session** (in some designs, Claude might avoid re-calling due to "fear of waste"; making the cache explicit eliminates this concern).

**HTTP Auto-Upgrade to HTTPS**

> HTTP URLs will be automatically upgraded to HTTPS

Transparently surfacing hidden behavior — Claude writing `http://` will be auto-upgraded, no manual change needed. **Reduces error probability without silent magic**.

#### 3 - Field-Level Description

WebFetch has very few fields — but each is required, giving high signal density:

- `url` — required, full URL
- `prompt` — required, tells WebFetch what you want to extract from the content

**Why is prompt required?**

Because WebFetch **doesn't return the full text** — it returns "results processed according to the prompt." Without a prompt, the small fast model in the runtime wouldn't know what to extract or what length to summarize to.

Compare the curl mental model:

- curl: `curl https://example.com` -> returns raw HTML (potentially tens of thousands of words)
- WebFetch: `WebFetch(url, prompt="Extract the 3 core insights from this article")` -> returns a 100-word summary

**Writing the prompt is like giving instructions to a new colleague** — the more specific, the better the extraction quality. "Read this page" is a shallow prompt; "find the rate limit numbers, list them if present, say so if not" is a precise prompt.

**Promoting prompt from optional to required** is WebFetch's most elegant design decision — it forces Claude to **think clearly about what it wants before fetching**, rather than fetching first and digesting later. This constraint itself is a context budget protection mechanism.

#### 4 - Schema Validation Rules

WebFetch's schema layer has almost **no hard constraints**:

| Field | Type | Constraint |
|---|---|---|
| `url` | string | format: uri (URL format validation) |
| `prompt` | string | required, no length constraint |

**The only hard constraint is `url` using `format: uri`** — anything that's not a complete URL (like `foo`) gets blocked by the schema, and the tool call can't even be sent. This is "physical interception" level fallback: **Claude can't even pass a bare domain string; it must be a complete URL**.

All other constraints are pushed down to the tool description layer using natural language guidance. This differs from AskUserQuestion's "three-tier progression" — WebFetch's complexity isn't in parameter validation but in **the judgment of "when not to use it"** (authentication, GitHub, MCP deference), which belongs to the description layer's responsibility.

---

## WebSearch

#### 1 - Naming

`WebSearch`

**Search** rather than `WebQuery` / `GoogleSearch` — maintaining generality and avoiding search engine branding. The tool's behavior is "give keywords, return a set of results," which is exactly the semantics of search.

Together with WebFetch they form a duality: **Fetch retrieves a known URL; Search finds URLs from keywords** — both words borrow industry conventions and need no explanation.

#### 2 - Tool-Level Description

The most interesting aspect of WebSearch's description is that it **includes two hard constraints that no other tool has** — citation obligation and time awareness. It centers on four things: **basic capability introduction, mandatory Sources listing, domain filtering, year hardcoding**.

**Basic Capability Introduction**

> Allows Claude to search the web and use the results to inform responses. Provides up-to-date information for current events and recent data.

Two short opening sentences clearly convey "purpose = breaking through training cutoff + getting latest information." The term "up-to-date" pinpoints WebSearch's core reason for existence — compensating for the timeliness deficiency of training data.

**Mandatory Citation: CRITICAL Level**

> CRITICAL REQUIREMENT - You MUST follow this:
> - After answering the user's question, you MUST include a "Sources:" section at the end of your response
> - In the Sources section, list all relevant URLs from the search results as markdown hyperlinks: [Title](URL)
> - This is MANDATORY - never skip including sources in your response

**The heaviest paragraph in the entire WebSearch description.** CRITICAL / MUST (x3) / MANDATORY — the intensity of language is a rare maximum across all tools. This isn't "advice"; it's "iron law."

**Why mandate listing Sources?**

Because the information WebSearch retrieves comes from uncontrolled sources — biased, outdated, SEO spam. **Listing Sources is a traceability guarantee** — users can verify whether the sources Claude cited are reliable. This hardcodes "citation transparency" into the tool.

This constraint also responds to the **fact-checking discipline** introduced in the series [opening article](../interaction/ask-user-question.md) — claims with "citation/official" language must actually retrieve the source. WebSearch's mandatory Sources is the tool-layer guarantee: **gives Claude no room to "lazily omit sources."**

**Domain Filtering Capability Reminder**

> Domain filtering is supported to include or block specific websites

Explicitly reminds Claude: **when the user trusts specific domains, use allowed_domains as a whitelist; when wanting to avoid certain sites, use blocked_domains as a blacklist.** This capability is often overlooked, so the prompt explicitly mentions it. It echoes the fact-checking discipline — to verify official source text, use `allowed_domains: ["anthropic.com"]` to definitively block non-official sources.

**Year Hardcoding: Compensating for Missing Time Awareness**

> IMPORTANT - Use the correct year in search queries:
> - The current month is July 2026. You MUST use this year when searching for recent information, documentation, or current events.
> - Example: If the user asks for "latest React docs", search for "React documentation" with the current year, NOT last year

**Hardcoding the current time in the tool description** — this constraint is very rare, but the reason is profound: Claude itself **doesn't know what month it is** (it has no sense of time after the training cutoff), yet dates are critical in search queries. If "latest React docs" is searched with a year from 2 years ago, the returned docs will be outdated.

Embedding time in the prompt lets Claude add the correct year to search keywords, retrieving genuinely "latest" content rather than "what it thought was latest during training." **Providing an example** — the React docs scenario directly demonstrates "correct vs. incorrect" comparison, which is more effective than explaining principles abstractly.

**US-Only Availability**

> Domain filtering is supported to include or block specific websites. Web search is only available in the US

An inconspicuous but important boundary declaration. Claude instances outside the US will fail when calling WebSearch — **stating this upfront prevents misuse**.

#### 3 - Field-Level Description

- `query` — required, search keywords
- `allowed_domains` — optional, whitelist (array)
- `blocked_domains` — optional, blacklist (array)

**Two parallel filtering dimensions**:

- `allowed_domains` — only search within these domains. For "I only trust anthropic.com / docs.python.org official sites" scenarios
- `blocked_domains` — exclude these domains. For "don't include outdated sites like w3schools" scenarios

**You can't use the same domain in both** (logical conflict). But they can be used separately: **whitelist to narrow to authoritative sources, blacklist to exclude junk sources** — the two dimensions combine for a precise information retrieval posture.

**query has a minimum length of 2** — the only field-level schema hard constraint (detailed below). It prevents single-character invalid searches like `q: "a"`.

#### 4 - Schema Validation Rules

WebSearch's schema layer has several **hard constraints**:

| Field | Type | Constraint |
|---|---|---|
| `query` | string | minLength: 2 (at least 2 characters) |
| `allowed_domains` | array of string | optional |
| `blocked_domains` | array of string | optional |

**query minLength: 2** — a single-character search is meaningless (unless it's a Chinese single character, but minLength counts characters not bytes), and the schema layer blocks it directly. **Harder than persuading in the description**.

Other constraints still sink to the description layer. allowed / blocked domains are **capability openness, not hard constraints** — the schema allows both arrays to be non-empty simultaneously, while the tool description reminds users not to logically put the same domain in both. **Capability is opened up; judgment is left to Claude**.

---

### Why Build Dedicated WebFetch/WebSearch Instead of Having Claude Use Bash + curl / Search APIs?

Bash is a catch-all; theoretically `curl` + search APIs could do the job. But calling them directly has a pile of problems:

- **HTML parsing burden** — curl returns raw HTML; Claude has to strip CSS / ads / navigation noise itself
- **Authentication credential leakage risk** — the user's local curl might carry `~/.netrc` / cookies, inadvertently sending them
- **Search API key management** — Google Custom Search / Bing API both require API keys; who manages them and how
- **No citation obligation** — Claude can freely cite from curl results without listing sources, losing traceability
- **No content compression** — a 50,000-word page stuffed entirely into context blows the budget

Dedicated tools solve all these pain points: HTML -> Markdown auto-conversion, anonymous fetching without credentials, search API management handled by the runtime, **WebSearch mandates listing Sources**, WebFetch uses AI to extract per prompt. This is yet another manifestation of "Bash is the catch-all; dedicated tools are precision-crafted."

---

### Division of Labor with Neighboring Tools

WebFetch + WebSearch contrast with the previous ten tools:

| Dimension | Three Interaction Primitives | Locate + Perceive + Execute | Bash | Agent | Task Family | WebFetch / WebSearch |
|---|---|---|---|---|---|---|
| Role | Collaboration alignment | Modify code | Command execution | Spawn Claude | Externalize working memory | **Reach the public internet** |
| Input source | User | Disk | Commands | Prompt | User / AI | **URL / query keywords** |
| Output normalization | Structured | Text / diff | Raw text | Subagent results | Status | **HTML->Markdown / summary** |
| Authentication state | None | User logged in | User credentials | Fork main session | User session | **Anonymous, no credentials** |
| Primary benefit | User alignment | Precise code edits | Engineering workflow | Context space | Combat forgetting | **Controlled information interface** |

**The dual-tool pattern of WebFetch + WebSearch mirrors Grep + Glob**:

- Grep + Glob: one searches by content, one by path — **finding information within a project**
- WebFetch + WebSearch: one pulls by URL, one searches by keywords — **finding information on the public internet**

Both tool pairs follow the "one precise target, one fuzzy exploration" dual-tool pattern, but WebFetch + WebSearch face the **untrusted external world**, so they have additional safety guardrails: "MCP deference, no automatic cross-domain redirect following, mandatory Sources listing."

**Boundary with Bash**: Bash is the catch-all; theoretically `curl` + search APIs could do these things too, but with issues like HTML parsing burden, credential leakage, API key management, and no citation obligation. WebFetch + WebSearch package these pain points into dedicated tools, once again embodying the division philosophy of "Bash as fallback, dedicated tools for precision work."

---

### Summary

The elegance of WebFetch + WebSearch lies in decomposing the broad need of "letting AI access the internet" into two dedicated tools, fully leveraging the 4-layer design approach.

**Signal distribution**:

- **Naming**: Both Fetch and Search borrow industry conventions; Claude instantly understands the division of labor at a glance. "Fetch" implies pulling a known target; "Search" implies keyword exploration.
- **Tool-level description**: WebFetch's heaviest elements are the IMPORTANT authentication warning + MCP deference + GitHub specialization — together building the instinct of "check the toolset before acting"; WebSearch's heaviest elements are the CRITICAL mandatory Sources + current month hardcoding — one provides a fallback for "citation traceability," the other for "missing time awareness."
- **Field-level description**: WebFetch has only 2 fields, but prompt is **required** — forcing Claude to think clearly about what it wants before each call, serving as context budget protection; WebSearch's allowed / blocked domains are capability openness, independently exposing the "who to trust" and "who not to trust" dimensions to Claude.
- **Schema validation**: WebFetch uses `url: format: uri` to block non-URL strings; WebSearch uses `query: minLength: 2` to block single-character invalid searches — the schema layer performs physical interception, catching the most basic errors at the type-checking level.

**Several cross-tool unique design signals**:

- **Prompt required** — WebFetch's prompt parameter makes "on-demand extraction" a first-class citizen, upgrading the tool from "web page downloader" to "a primitive for extraction by prompt"
- **Mandatory Sources listing** — WebSearch is the **only** tool in the entire toolset that uses CRITICAL / MANDATORY in its description to mandate response format; "citation transparency" is written into the tool layer rather than relying on self-discipline
- **Current month hardcoded** — Extremely rarely, dynamic time information is embedded in a static prompt to compensate for Claude's capability gap of "not knowing what month it is"
- **Humble deference to MCP** — A rare "won't cover authenticated content; please find MCP" posture in the tool ecosystem; every "no" comes with a "yes"
- **No automatic cross-domain redirect following** — Hands security decisions to Claude, preventing redirect attacks; an explicit protocol rather than silent magic

These signals are each in their proper place across the 4 layers, collectively converging the capability of "letting Claude reach the public internet" into a controlled, traceable, deferential external information interface.

The next article continues by dissecting the [Cron Family](../state/cron-family.md) — switching from the "spatial dimension" (project / public internet) to the "temporal dimension" (scheduled / future triggers). How the CronCreate / CronDelete / CronList trio turns "letting AI do things on a schedule" into a composable temporal primitive.
