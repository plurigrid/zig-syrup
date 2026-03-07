# Gemini Enterprise & CLI: Comprehensive Maximization Guide

## 1. Gemini Enterprise Tiers

### Gemini Enterprise Editions (Google Workspace AI)

| Feature | Business | Standard | Plus | Frontline |
|---------|----------|----------|------|-----------|
| Seats | 1-300 users | 1+ users | 1+ users | 150+ (with Standard/Plus) |
| Storage/indexing | Limited | Full | Full | Full |
| Purpose | SMB | Enterprise-wide | Power users | Frontline workers |

**What it is**: Gemini Enterprise is an **agentic platform** for organizations — chat interface, AI agents, no-code agent workbench, enterprise-grade security/compliance, data connector ecosystem.

### Gemini API Tiers (Developer/Vertex AI)

| Tier | RPM | TPM | RPD | Requirements |
|------|-----|-----|-----|-------------|
| **Free** | 5-15 | 250K | 100-1,000 | No credit card |
| **Tier 1 (Paid)** | 150-300 | 1M | 1,500 | Enable billing |
| **Tier 2** | 500-1,500 | 2M | 10,000 | $250 cumulative + 30 days |
| **Tier 3 (Enterprise)** | 1,000-4,000+ | Custom | Custom | $1,000 spend + contact sales |

### Two Pricing Surfaces

1. **Gemini Developer API** (via Google AI Studio at `ai.google.dev`)
   - Free tier included, pay-as-you-go
   - Batch API (50% cost reduction), context caching
   - Simpler setup, less enterprise features

2. **Vertex AI Gemini API** (via Google Cloud at `cloud.google.com/vertex-ai`)
   - Enterprise security, VPC-SC, CMEK, audit logging
   - Provisioned Throughput, Model Garden, fine-tuning
   - Volume-based discounts, dedicated support
   - MLOps integration (pipelines, monitoring, A/B testing)

### Token Pricing (Vertex AI, as of early 2026)

| Model | Input ≤200K | Input >200K | Cached Input ≤200K | Output |
|-------|-----------|-----------|-------------------|--------|
| Gemini 3.1 Pro Preview | $2/1M | $4/1M | $0.20/1M | $12/1M |
| Gemini 3 Pro Preview | $2/1M | $4/1M | $0.20/1M | $12/1M |
| Gemini 3 Flash Preview | Lower | Lower | Lower | Lower |
| Gemini 2.5 Pro | $1.25/1M | $2.50/1M | 75% discount | $10/1M |
| Gemini 2.5 Flash | Cheaper | Cheaper | 75% discount | Cheaper |

---

## 2. Context Window Sizes

| Model | Context Window | Notes |
|-------|---------------|-------|
| Gemini 2.5 Pro | **1,000,000 tokens** | Best reasoning model |
| Gemini 2.5 Flash | **1,000,000 tokens** | Balanced speed/intelligence |
| Gemini 3 Pro | **1,000,000 tokens** | Latest generation |
| Gemini 3 Flash | **1,000,000 tokens** | Fast, efficient |
| Gemini 3.1 Pro Preview | **1,000,000+ tokens** | Newest preview |

**Key**: All modern Gemini models support 1M+ token context windows. Some models support up to **2M tokens** depending on tier.

---

## 3. Gemini CLI

### Overview
- **Repository**: `google-gemini/gemini-cli` (95K+ stars, Apache 2.0)
- **Package**: `@google/gemini-cli` on npm (v0.29.5+)
- **Runtime**: Node.js 20.0.0+
- **Latest**: v0.30.0-preview.3 (Feb 2026)

### Installation

```bash
# npm (recommended)
npm install -g @google/gemini-cli

# Homebrew (macOS/Linux)
brew install gemini-cli

# MacPorts (macOS)
sudo port install gemini-cli

# Anaconda (restricted environments)
# Create and activate conda env first

# Run directly without installing
npx @google/gemini-cli
```

**Pre-installed on**: Google Cloud Shell, Cloud Workstations

### Run

```bash
gemini
```

### Authentication Methods

Three options on first run:

#### 1. Login with Google (Recommended for personal/Pro/Ultra subscribers)
```bash
gemini
# Select "1. Login with Google"
# Browser opens for OAuth flow
# Credentials cached locally
```

#### 2. Gemini API Key
```bash
export GEMINI_API_KEY="your-api-key"
gemini
# Or select "2. Use Gemini API key" at prompt
```

#### 3. Vertex AI (Enterprise/Google Cloud)
```bash
export GOOGLE_CLOUD_PROJECT="YOUR_PROJECT_ID"
# Must enable "Gemini for Cloud API"
# Configure IAM access permissions
gemini
# Select "3. Vertex AI"
```

For Google Workspace / Gemini Code Assist licensed users:
```bash
export GOOGLE_CLOUD_PROJECT="YOUR_PROJECT_ID"
echo 'export GOOGLE_CLOUD_PROJECT="YOUR_PROJECT_ID"' >> ~/.zshrc
```

### Free Tier Limits
- **60 requests/minute**
- **1,000 requests/day**
- **1M token context window**
- Personal Google account only

### Configuration

#### settings.json
Located at `~/.config/gemini-cli/settings.json` (Linux/macOS) or `%APPDATA%\gemini-cli\config.json` (Windows).

```json
{
  "theme": "dark",
  "model": "gemini-2.5-pro",
  "temperature": 0.7,
  "safetySettings": [
    {"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"}
  ]
}
```

#### GEMINI.md (Project-level context)
Place a `GEMINI.md` file in your project root to provide persistent context instructions (similar to `CLAUDE.md` for Claude Code).

#### .env File
```bash
GEMINI_API_KEY=your_api_key
GEMINI_MODEL=gemini-2.5-pro
GOOGLE_CLOUD_PROJECT=your-project-id
```

#### Priority Order
1. Command line arguments (highest)
2. Environment variables
3. Configuration file (lowest)

### Built-in Tools

Gemini CLI ships with these built-in tools:
- **Google Search grounding** — real-time web search
- **File operations** — read, write, edit files
- **Shell commands** — execute terminal commands
- **Web fetching** — fetch and parse web content
- **Code execution** — run code in sandboxed environment

### MCP Server Support

Gemini CLI is both an **MCP client** and can host **MCP servers**.

Configure MCP servers in your project:

```json
// .gemini/settings.json or project-level config
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "my-mcp-server"],
      "env": {
        "API_KEY": "your-key"
      }
    }
  }
}
```

### Key Commands / Slash Commands
- `/help` — show available commands
- `/model` — switch model
- `/tools` — list available tools
- `/clear` — clear context
- `/save` — save conversation
- `/quit` — exit

---

## 4. Maximizing Gemini Capabilities

### A. Safety Filter Adjustments

**Categories available for adjustment:**
| Category | Description |
|----------|-------------|
| `HARM_CATEGORY_HARASSMENT` | Targeting identity/protected attributes |
| `HARM_CATEGORY_HATE_SPEECH` | Rude, disrespectful, profane content |
| `HARM_CATEGORY_SEXUALLY_EXPLICIT` | Sexual references |
| `HARM_CATEGORY_DANGEROUS_CONTENT` | Promotes harmful acts |
| `HARM_CATEGORY_CIVIC_INTEGRITY` | Election-related (not adjustable) |

**Threshold levels (least to most restrictive):**
1. `OFF` — no filtering at all (use for Gemini 2.0 Flash+)
2. `BLOCK_NONE` — show all results regardless of probability
3. `BLOCK_ONLY_HIGH` — block only high-probability harmful content
4. `BLOCK_MEDIUM_AND_ABOVE` — block medium+ probability (default)
5. `BLOCK_LOW_AND_ABOVE` — most restrictive

**API Example (Python):**
```python
from google import genai
from google.genai import types

client = genai.Client()

safety_settings = [
    types.SafetySetting(
        category="HARM_CATEGORY_HARASSMENT",
        threshold="OFF"  # or "BLOCK_NONE"
    ),
    types.SafetySetting(
        category="HARM_CATEGORY_HATE_SPEECH",
        threshold="OFF"
    ),
    types.SafetySetting(
        category="HARM_CATEGORY_SEXUALLY_EXPLICIT",
        threshold="OFF"
    ),
    types.SafetySetting(
        category="HARM_CATEGORY_DANGEROUS_CONTENT",
        threshold="OFF"
    ),
]

response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="Your prompt here",
    config=types.GenerateContentConfig(
        safety_settings=safety_settings
    )
)
```

**Important notes:**
- For Gemini 2.0 Flash and newer: use `OFF` instead of `BLOCK_NONE`
- For older models: `BLOCK_NONE` still works
- `HARM_CATEGORY_CIVIC_INTEGRITY` is **not configurable**
- Non-configurable filters (CSAM, etc.) always remain active
- Applications using less restrictive settings may be subject to review

**Vertex AI (Google Cloud) safety config:**
```python
from google.cloud import aiplatform
from vertexai.generative_models import GenerativeModel, SafetySetting, HarmCategory, HarmBlockThreshold

safety_config = [
    SafetySetting(
        category=HarmCategory.HARM_CATEGORY_HARASSMENT,
        threshold=HarmBlockThreshold.OFF,
    ),
    SafetySetting(
        category=HarmCategory.HARM_CATEGORY_HATE_SPEECH,
        threshold=HarmBlockThreshold.OFF,
    ),
    SafetySetting(
        category=HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
        threshold=HarmBlockThreshold.OFF,
    ),
    SafetySetting(
        category=HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
        threshold=HarmBlockThreshold.OFF,
    ),
]

model = GenerativeModel("gemini-2.5-pro")
response = model.generate_content(
    "Your prompt",
    safety_settings=safety_config
)
```

### B. Quota Increases

**Via Google Cloud Console:**
1. Go to **IAM & Admin > Quotas & System Limits**
2. Filter by service: "Vertex AI API" or "Generative Language API"
3. Select the quota metric (e.g., `GenerateContent requests per minute per project per base_model`)
4. Click **Edit Quotas** → request increase
5. Provide justification

**Automatic tier upgrades (Developer API):**
- **Free → Tier 1**: Enable billing on project
- **Tier 1 → Tier 2**: $250 cumulative spend + 30 days on Tier 1
- **Tier 2 → Tier 3**: $1,000+ cumulative spend, contact sales

**Key quotas to increase on Vertex AI:**
- `Online prediction requests per minute per region per base_model`
- `Online prediction tokens per minute per region per base_model`
- `Online prediction requests per minute per region` (cross-model)

### C. Provisioned Throughput (PT)

Reserved capacity for guaranteed performance on Vertex AI:

- **Guaranteed capacity** — no 429 errors from contention
- **Predictable latency** — reserved compute resources
- **Cost efficiency** — volume discounts for consistent usage
- **Supported models**: Gemini 3, 2.5 Pro, 2.5 Flash, and more
- **Multimodal support**: text, images, video

**How to set up:**
1. Go to Vertex AI > Model Garden
2. Select your model
3. Choose "Provisioned Throughput" deployment option
4. Configure capacity (tokens per minute)
5. Commit to usage term for discounts

### D. Context Caching (Major Cost Saver)

Two types of caching available:

#### Implicit Caching (Automatic)
- Enabled by default for Gemini 2.5+ models
- Google automatically caches repeated inputs
- **75% discount** on cached input tokens (Gemini 2.5 Flash/Pro)
- No configuration needed — savings passed through automatically

#### Explicit Caching (Manual)
- You create named caches for specific content
- Guaranteed cache hits (not probabilistic)
- **75-90% discount** on cached tokens depending on model
- Minimum token counts: 1,024 (Flash), 2,048 (Pro)

```python
from google import genai
from google.genai import types

client = genai.Client()

# Create an explicit cache
cache = client.caches.create(
    model="gemini-2.5-pro",
    config=types.CreateCachedContentConfig(
        contents=[
            types.Content(
                parts=[types.Part(text="Your large document or system instructions here...")],
                role="user"
            )
        ],
        display_name="my-project-context",
        ttl="3600s"  # 1 hour
    )
)

# Use the cache in generation
response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="Question about the cached content",
    config=types.GenerateContentConfig(
        cached_content=cache.name
    )
)
```

### E. Grounding with Google Search

Connect Gemini to real-time web data:

```python
from google import genai
from google.genai import types

client = genai.Client()

response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="What happened in the news today?",
    config=types.GenerateContentConfig(
        tools=[types.Tool(google_search=types.GoogleSearch())]
    )
)

print(response.text)
# Response includes citations and grounding metadata
```

**Vertex AI grounding options:**
- **Grounding with Google Search** — public web data
- **Grounding with Google Maps** — geospatial data
- **Grounding with Vertex AI Search** — your own data (RAG)
- **Grounding with your Search API** — any external search endpoint
- Supports up to **10 grounding sources** per request
- Can combine multiple sources in single request

### F. Function Calling

```python
from google import genai
from google.genai import types

schedule_meeting = types.FunctionDeclaration(
    name="schedule_meeting",
    description="Schedules a meeting",
    parameters={
        "type": "object",
        "properties": {
            "attendees": {"type": "array", "items": {"type": "string"}},
            "date": {"type": "string"},
            "time": {"type": "string"},
            "topic": {"type": "string"},
        },
        "required": ["attendees", "date", "time", "topic"]
    }
)

tool = types.Tool(function_declarations=[schedule_meeting])

response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="Schedule a meeting with Alice tomorrow at 2pm about Q1 planning",
    config=types.GenerateContentConfig(tools=[tool])
)
```

### G. Fine-Tuning / Supervised Tuning

**Supported models for supervised fine-tuning:**
- Gemini 2.0 Flash, Flash-Lite
- Gemini 2.5 Flash, Flash-Lite
- Gemini 2.5 Pro

**Data types**: text, image, audio, video, documents

```python
from google.cloud import aiplatform

# Prepare JSONL training data
# Each line: {"messages": [{"role": "user", "parts": [{"text": "..."}]}, {"role": "model", "parts": [{"text": "..."}]}]}

# Start tuning job
tuning_job = aiplatform.CustomJob.submit(
    display_name="my-gemini-tuning",
    model_name="gemini-2.5-flash",
    training_data_uri="gs://bucket/train.jsonl",
    # Tuned model shares base model quota
)
```

**Tip**: For tuned models with thinking support, set thinking budget to off/lowest value during fine-tuning to reduce costs.

### H. Code Execution Sandbox

Gemini supports sandboxed code execution:

```python
from google import genai
from google.genai import types

client = genai.Client()

response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="Calculate the first 20 Fibonacci numbers",
    config=types.GenerateContentConfig(
        tools=[types.Tool(code_execution=types.ToolCodeExecution())]
    )
)
```

### I. Extensions (Vertex AI)

Vertex AI Extensions provide pre-built connections:
- **Code Interpreter** — execute Python code
- **Vertex AI Search** — RAG over your data
- **Google Maps** — geospatial queries

### J. Structured Output / JSON Mode

Force JSON output with schema validation:

```python
response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="List 5 programming languages with their year of creation",
    config=types.GenerateContentConfig(
        response_mime_type="application/json",
        response_schema={
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "year": {"type": "integer"}
                }
            }
        }
    )
)
```

### K. Thinking / Reasoning Mode

Gemini 2.5+ models support explicit thinking:

```python
response = client.models.generate_content(
    model="gemini-2.5-pro",
    contents="Solve this complex math problem...",
    config=types.GenerateContentConfig(
        thinking_config=types.ThinkingConfig(
            thinking_budget=10000  # tokens for reasoning
        )
    )
)
```

---

## 5. Quick Reference: Environment Variables

```bash
# Gemini Developer API
export GEMINI_API_KEY="your-api-key"

# Vertex AI
export GOOGLE_CLOUD_PROJECT="your-project-id"
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
export GOOGLE_CLOUD_REGION="us-central1"

# Gemini CLI specific
export GEMINI_MODEL="gemini-2.5-pro"
export GEMINI_TEMPERATURE="0.7"
```

## 6. Key Differences: AI Studio vs Vertex AI

| Feature | AI Studio (Developer API) | Vertex AI |
|---------|--------------------------|-----------|
| Target | Developers, prototyping | Enterprise, production |
| Auth | API key | Service account, OAuth, IAM |
| Safety filters | Adjustable | Adjustable + additional controls |
| Quotas | Fixed tiers | Custom, negotiable |
| Fine-tuning | Limited | Full supervised tuning |
| Grounding | Google Search only | Google Search + your data + custom API |
| Provisioned Throughput | No | Yes |
| VPC-SC, CMEK, DLP | No | Yes |
| Context caching | Yes (implicit + explicit) | Yes (implicit + explicit, 75% discount) |
| Batch API | Yes (50% discount) | Yes |
| SLA | None | Enterprise SLA |
| Pricing | Generally same per-token | Same per-token + PT options |

## 7. Cost Optimization Checklist

1. ✅ **Enable context caching** — 75% savings on repeated prompts
2. ✅ **Use Batch API** — 50% discount for non-time-sensitive workloads
3. ✅ **Choose right model** — Flash for speed, Pro for reasoning
4. ✅ **Set thinking budget** — control reasoning token spend
5. ✅ **Use Provisioned Throughput** — volume discounts for steady workloads
6. ✅ **Prompt optimization** — shorter, more efficient prompts
7. ✅ **Monitor usage** — Cloud Console quotas dashboard
8. ✅ **Use structured output** — reduce parsing overhead and retries
