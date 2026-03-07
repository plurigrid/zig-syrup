# 01 — Model Context Protocol (MCP) Deep Dive

## Executive Summary

The Model Context Protocol (MCP) is an open protocol created by Anthropic that standardizes how AI applications connect to external tools, data sources, and context. Released as open source in late 2024 and rapidly adopted through 2025-2026, MCP has become the de facto standard for the **agent-to-tool** layer of the agentic protocol stack. It is often described as "USB-C for AI" — a universal connector that turns the N×M integration problem into an M+N solution.

MCP is now governed by the **Agentic AI Foundation (AAIF)** under the Linux Foundation, with platinum members including Anthropic, OpenAI, Google, Microsoft, AWS, Bloomberg, and Cloudflare. The protocol takes inspiration from the Language Server Protocol (LSP), which standardized programming language support across development tools — MCP aims to do the same for AI application integrations.

As of February 2026, the MCP servers repository has 79,000+ GitHub stars, the Python SDK has 21,700+ stars, and the protocol reports over 97 million monthly SDK downloads with 10,000+ active servers.

---

## 1. Problem Statement

Before MCP, every AI application required bespoke integrations with every tool or data source. An organization with M AI applications and N data sources needed M×N custom connectors. Each integration was a one-off project with its own authentication, error handling, and data translation logic. This created:

- **Integration sprawl**: Exponential growth in maintenance burden
- **Fragile connections**: Updates to one side broke the other
- **Vendor lock-in**: Switching AI providers meant rewriting all integrations
- **Security inconsistency**: Each integration implemented auth/authz differently
- **Context starvation**: LLMs couldn't access the right data at the right time

MCP reduces this to M+N: M clients implement the MCP client protocol once, and N servers implement the MCP server protocol once.

---

## 2. Architecture

### 2.1 Core Components

MCP defines three roles:

| Role | Description | Examples |
|------|-------------|----------|
| **Host** | The AI application that orchestrates connections | Claude Desktop, VS Code, Cursor, Factory Droid |
| **Client** | A protocol client within the host that maintains a 1:1 connection to a server | MCP client library (TypeScript, Python, etc.) |
| **Server** | A lightweight program that exposes capabilities via the MCP protocol | Database connector, API wrapper, file system server |

The Host contains one or more Clients, each connected to exactly one Server. The Host mediates between the LLM and the Clients, routing tool calls and managing context.

```
┌──────────────────────────────────────────────────┐
│  HOST (e.g., Claude Desktop, VS Code, Factory)   │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Client A │  │ Client B │  │ Client C │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
│       │              │              │            │
│  ┌────▼─────┐  ┌────▼─────┐  ┌────▼─────┐      │
│  │ Server A │  │ Server B │  │ Server C │      │
│  │(Database)│  │ (GitHub) │  │  (Slack) │      │
│  └──────────┘  └──────────┘  └──────────┘      │
│                                                  │
│                   ┌─────┐                        │
│                   │ LLM │                        │
│                   └─────┘                        │
└──────────────────────────────────────────────────┘
```

### 2.2 Server Features (Server → Client)

MCP servers expose three fundamental primitives:

#### Tools (Model-Controlled)

Functions that the LLM can invoke to take actions. Tools are the primary mechanism for the LLM to interact with external systems.

```json
{
  "name": "query_database",
  "description": "Execute a read-only SQL query against the analytics database",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": { "type": "string", "description": "SQL query to execute" }
    },
    "required": ["query"]
  },
  "annotations": {
    "title": "Database Query",
    "readOnlyHint": true,
    "openWorldHint": false
  }
}
```

Tool annotations (introduced in the 2025-03-26 spec) provide metadata hints about tool behavior:
- `title`: Human-readable display name
- `readOnlyHint`: Whether the tool only reads data (no side effects)
- `destructiveHint`: Whether the tool may perform destructive operations
- `idempotentHint`: Whether repeated calls with same arguments have the same effect
- `openWorldHint`: Whether the tool interacts with the open world (network, external services)

**Important**: Tool annotations (including descriptions) are considered **untrusted** unless obtained from a trusted server. This is a deliberate security design decision.

#### Resources (Application-Controlled)

Data that the host can read to provide context, without requiring LLM-initiated actions. Resources are identified by URIs.

```json
{
  "uri": "file:///project/src/main.py",
  "name": "Main application file",
  "description": "The primary entry point for the application",
  "mimeType": "text/x-python"
}
```

Resources support:
- **Static resources**: Fixed URI, content changes over time (e.g., a config file)
- **Resource templates**: URI templates with parameters (e.g., `db://{table}/schema`)
- **Subscriptions**: Clients can subscribe to resource change notifications

#### Prompts (User-Controlled)

Templated messages and workflows that provide structured ways to interact with servers.

```json
{
  "name": "review_code",
  "description": "Review code for bugs and style issues",
  "arguments": [
    {
      "name": "language",
      "description": "Programming language",
      "required": true
    }
  ]
}
```

Prompts are user-initiated (unlike tools which are LLM-initiated), giving users explicit control over structured interactions.

### 2.3 Client Features (Client → Server)

The 2025-11-25 spec defines three client features that servers can request:

#### Sampling (Server-Initiated LLM Interaction)

Servers can request the client's LLM to perform completions/generations. This enables **agentic behaviors** — servers can request LLM reasoning without needing their own API keys.

```json
{
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": { "type": "text", "text": "Analyze this data..." }
      }
    ],
    "maxTokens": 1000,
    "modelPreferences": {
      "hints": [{ "name": "claude-4-sonnet" }]
    },
    "tools": [...],
    "toolChoice": { "type": "auto" }
  }
}
```

Key sampling features:
- Supports text, audio, and image-based interactions
- Optional `tools` and `toolChoice` parameters (added in 2025-11-25) for tool-augmented sampling
- **Human-in-the-loop required**: Users MUST explicitly approve sampling requests
- The protocol intentionally limits server visibility into prompts
- Clients control model selection, actual prompt content, and result visibility

#### Roots (Server-Initiated Boundary Inquiry)

Servers can ask clients about their operational boundaries — URI or filesystem boundaries they should operate within.

```json
{
  "method": "roots/list",
  "params": {}
}
// Response:
{
  "roots": [
    { "uri": "file:///home/user/project", "name": "Project Root" },
    { "uri": "https://api.example.com/v1", "name": "API Endpoint" }
  ]
}
```

Roots help servers understand their scope of operation without hardcoding paths.

#### Elicitation (Server-Initiated User Input)

Servers can request additional information from users through the client during interactions. Supports two modes:

1. **URL mode**: Directs users to external URLs for sensitive interactions (e.g., authentication pages). Servers MUST use URL mode for sensitive information like credentials.
2. **Form mode**: Requests structured data from users with optional JSON Schema validation. Servers MUST NOT use form mode for sensitive information.

```json
{
  "method": "elicitation/create",
  "params": {
    "message": "Please provide your project preferences",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "language": { "type": "string", "enum": ["python", "typescript", "rust"] },
        "framework": { "type": "string" }
      }
    }
  }
}
```

### 2.4 Additional Utilities

| Utility | Description |
|---------|-------------|
| **Configuration** | Server configuration management |
| **Progress Tracking** | Report progress on long-running operations |
| **Cancellation** | Cancel in-progress requests |
| **Error Reporting** | Structured error codes and messages |
| **Logging** | Server-to-client log message streaming |
| **Tasks** | **(Experimental, 2025-11-25)** Track durable requests with polling and deferred result retrieval |

---

## 3. Transport Layer

### 3.1 stdio Transport

The simplest transport — the client launches the server as a subprocess:

- Server reads JSON-RPC from `stdin`, writes to `stdout`
- Messages delimited by newlines (MUST NOT contain embedded newlines)
- Server MAY write to `stderr` for logging
- Server MUST NOT write non-MCP content to `stdout`

```
Client ──stdin──> Server Process
Client <──stdout── Server Process
         (stderr for logs)
```

**Best for**: Local tools, IDE integrations, trusted environments. Clients SHOULD support stdio whenever possible.

### 3.2 Streamable HTTP Transport (2025-11-25)

Replaces the deprecated HTTP+SSE transport from 2024-11-05. The server operates as an independent process handling multiple client connections.

**Single MCP endpoint** supports both POST and GET:

```
POST /mcp  →  Send JSON-RPC message to server
GET  /mcp  →  Open SSE stream for server-initiated messages
```

#### Sending Messages (Client → Server)

- Every JSON-RPC message is a new HTTP POST to the MCP endpoint
- Client MUST include `Accept: application/json, text/event-stream`
- Server responds with either `application/json` (single response) or `text/event-stream` (SSE stream)
- For notifications/responses: server returns 202 Accepted (no body)
- For requests: server may stream multiple messages before the final response

#### Listening (Server → Client)

- Client MAY issue HTTP GET to open an SSE stream
- Server uses this for unsolicited notifications and requests
- Server may close connection at any time; client reconnects via polling

#### Session Management

- Server MAY assign a session ID via `MCP-Session-Id` header during initialization
- Client MUST include session ID on all subsequent requests
- Session ID MUST be globally unique and cryptographically secure
- Client SHOULD send HTTP DELETE to terminate sessions explicitly
- Protocol version communicated via `MCP-Protocol-Version` header

#### Resumability and Redelivery

- Servers MAY attach SSE event IDs (globally unique per session)
- Clients reconnect with `Last-Event-ID` header to resume from last received event
- Enables reliable delivery despite network interruptions
- Event IDs assigned per-stream, acting as a cursor

#### Security Requirements

- Servers MUST validate `Origin` header (prevent DNS rebinding attacks)
- Invalid Origin → HTTP 403 Forbidden
- Local servers SHOULD bind to `127.0.0.1` only (not `0.0.0.0`)
- Servers SHOULD implement proper authentication

#### Backwards Compatibility

Clients wanting to support older (2024-11-05) servers:
1. Try POST `InitializeRequest` to server URL
2. If succeeds → Streamable HTTP transport
3. If fails (400/404/405) → Try GET, expect SSE stream with `endpoint` event → old HTTP+SSE transport

### 3.3 Custom Transports

The protocol is transport-agnostic. Implementers MAY create custom transports but MUST preserve JSON-RPC format and lifecycle requirements.

---

## 4. Authorization Framework (2025-11-25)

The authorization specification underwent significant evolution, moving from Dynamic Client Registration to a more practical approach.

### 4.1 OAuth 2.1 Foundation

MCP authorization is built on:
- **OAuth 2.1** (draft-ietf-oauth-v2-1-13)
- **OAuth 2.0 Authorization Server Metadata** (RFC 8414)
- **OAuth 2.0 Protected Resource Metadata** (RFC 9728)
- **OAuth Client ID Metadata Documents** (draft-ietf-oauth-client-id-metadata-document-00)
- **OAuth 2.0 Dynamic Client Registration** (RFC 7591) — for backwards compatibility

### 4.2 Roles

| Role | OAuth Mapping |
|------|--------------|
| MCP Server | OAuth 2.1 Resource Server |
| MCP Client | OAuth 2.1 Client |
| Authorization Server | Issues access tokens (may be co-located with MCP server or separate) |

### 4.3 Client Registration Approaches (Priority Order)

1. **Pre-registration**: Use existing client credentials if available
2. **Client ID Metadata Documents (CIMD)**: **(New, recommended)** Client hosts metadata at an HTTPS URL; authorization server fetches and validates it. Eliminates the need for Dynamic Client Registration.
3. **Dynamic Client Registration**: Fallback for backwards compatibility
4. **User-provided**: Prompt user to enter client information

#### Client ID Metadata Document Example

```json
{
  "client_id": "https://app.example.com/oauth/client-metadata.json",
  "client_name": "Example MCP Client",
  "client_uri": "https://app.example.com",
  "logo_uri": "https://app.example.com/logo.png",
  "redirect_uris": [
    "http://127.0.0.1:3000/callback",
    "http://localhost:3000/callback"
  ],
  "grant_types": ["authorization_code"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

This approach eliminates the headache of Dynamic Client Registration (DCR), which most authorization servers don't support and which led to security vulnerabilities in early MCP implementations.

### 4.4 Authorization Server Discovery

MCP servers MUST implement RFC 9728 (Protected Resource Metadata) to indicate their authorization server. Two discovery mechanisms:

1. **WWW-Authenticate Header**: Include `resource_metadata` URL in 401 Unauthorized responses
2. **Well-Known URI**: Serve metadata at `/.well-known/oauth-protected-resource`

### 4.5 Resource Parameter (RFC 8707)

MCP clients MUST include the `resource` parameter in authorization and token requests to bind tokens to specific MCP servers. This prevents token reuse across services.

### 4.6 Scope Selection Strategy

Clients SHOULD follow least-privilege:
1. Use `scope` from the initial 401 `WWW-Authenticate` header
2. If unavailable, use `scopes_supported` from Protected Resource Metadata
3. Support step-up authorization for incremental scope consent

### 4.7 Security Considerations

- **Token Audience Binding**: Servers MUST validate tokens are intended for them
- **Token Passthrough**: Servers MUST NOT forward client tokens to upstream APIs
- **PKCE Required**: All authorization code flows must use PKCE
- **Confused Deputy**: MCP proxy servers using static client IDs MUST obtain user consent for each dynamically registered client
- **Localhost Redirect Risks**: Authorization servers SHOULD display warnings for localhost-only redirect URIs
- **SSRF Protection**: Authorization servers fetching CIMD documents SHOULD consider SSRF risks
- **Authorization Extensions**: Modular, optional, additive extensions stored in the `ext-auth` repository

### 4.8 What Authorization Does NOT Cover

- stdio transport (use environment credentials instead)
- Agent-to-agent identity (this is A2A's domain)
- Agent identity verification (no DID/VC integration)
- Inter-organization trust establishment

---

## 5. Protocol Lifecycle

### 5.1 Connection Lifecycle

```
1. Initialization
   Client sends InitializeRequest with:
   - protocolVersion (e.g., "2025-11-25")
   - capabilities (what the client supports)
   - clientInfo (name, version)
   
   Server responds with InitializeResult:
   - protocolVersion (negotiated)
   - capabilities (what the server supports)
   - serverInfo (name, version)
   
2. Initialized Notification
   Client sends InitializedNotification to confirm ready state
   
3. Normal Operation
   Bidirectional JSON-RPC messages (requests, responses, notifications)
   
4. Shutdown
   Client closes connection (stdio: close stdin, terminate; HTTP: DELETE session)
```

### 5.2 Version Negotiation

- Client proposes its latest supported version
- Server responds with the version it will use (must be ≤ client's version)
- If no compatible version exists, server SHOULD return an error
- Protocol uses date-based versioning: `2024-11-05` → `2025-03-26` → `2025-06-18` → `2025-11-25`

### 5.3 Capability Negotiation

Both client and server declare capabilities during initialization. Only negotiated capabilities may be used during the session.

**Server capabilities** (what the server offers):
- `tools` — tool invocation support
- `resources` — resource access support (with optional `subscribe`)
- `prompts` — prompt template support
- `logging` — server-side logging
- `completions` — argument completion support

**Client capabilities** (what the client offers):
- `sampling` — LLM sampling support
- `roots` — root directory listing
- `elicitation` — user input collection

---

## 6. Message Format

All messages follow JSON-RPC 2.0:

### 6.1 Request

```json
{
  "jsonrpc": "2.0",
  "id": "req-123",
  "method": "tools/call",
  "params": {
    "name": "query_database",
    "arguments": { "query": "SELECT count(*) FROM users" }
  }
}
```

### 6.2 Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": "req-123",
  "result": {
    "content": [
      { "type": "text", "text": "Count: 42,531" }
    ],
    "isError": false
  }
}
```

### 6.3 Response (Error)

```json
{
  "jsonrpc": "2.0",
  "id": "req-123",
  "error": {
    "code": -32602,
    "message": "Invalid query: syntax error at position 15"
  }
}
```

### 6.4 Notification (No Response Expected)

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "op-456",
    "progress": 75,
    "total": 100,
    "message": "Processing records..."
  }
}
```

### 6.5 Content Types

MCP supports multiple content types in tool results and messages:

| Type | Description |
|------|-------------|
| `text` | Plain text content |
| `image` | Base64-encoded image with MIME type |
| `audio` | Base64-encoded audio with MIME type |
| `resource` | Embedded resource reference (URI + content) |

---

## 7. Specification Evolution (Changelog)

### 7.1 Version Timeline

| Version | Date | Key Changes |
|---------|------|-------------|
| `2024-11-05` | Nov 2024 | Initial release. HTTP+SSE transport, basic tools/resources/prompts |
| `2025-03-26` | Mar 2025 | Tool annotations, Streamable HTTP transport, elicitation |
| `2025-06-18` | Jun 2025 | Authorization framework (OAuth 2.1 + DCR), sampling enhancements |
| `2025-11-25` | Nov 2025 | CIMD auth, URL elicitation, sampling tools, tasks (experimental), icons, governance formalization |

### 7.2 Major Changes in 2025-11-25

1. **OAuth Client ID Metadata Documents**: Replaces DCR as recommended client registration
2. **OpenID Connect Discovery 1.0 support**: For authorization server discovery
3. **Icons for metadata**: Tools, resources, resource templates, and prompts can have icons
4. **Tool naming guidance**: Formalized conventions for tool names
5. **URL mode elicitation**: Servers can direct users to external URLs for sensitive interactions
6. **Sampling with tools**: `tools` and `toolChoice` parameters for tool-augmented sampling
7. **Tasks (experimental)**: Durable request tracking with polling and deferred results
8. **Incremental scope consent**: Step-up authorization via `WWW-Authenticate`
9. **Enhanced enum schemas**: Titled, untitled, single-select, and multi-select enums in elicitation
10. **JSON Schema 2020-12**: Established as default dialect

### 7.3 Governance Updates in 2025-11-25

- Formalized governance structure
- Established communication practices and guidelines
- Formalized Working Groups and Interest Groups
- SDK tiering system with feature support and maintenance requirements

---

## 8. Common Implementation Patterns

Based on analysis of the MCP server ecosystem:

| Pattern | Description | Example |
|---------|-------------|---------|
| **Prompt Library Server** | Exposes curated prompt templates | Company-specific prompt collections |
| **SaaS Platform Wrapper** | Wraps a SaaS API as MCP tools | GitHub, Jira, Slack servers |
| **Tool Catalog Server (Adapter Hub)** | Aggregates multiple tools behind one server | Enterprise tool gateway |
| **Retrieval Server (RAG)** | Provides semantic search over documents | Knowledge base, documentation server |
| **Code Repository Server** | Exposes code navigation and analysis | File system, git integration |
| **LLM-Powered Tools Server** | Uses LLM capabilities inside tools | Translation, summarization server |
| **Clarification Server** | Uses elicitation to gather info before acting | Interactive data entry |
| **Interactive Prompting Server** | Combines prompts + elicitation + tools | Multi-step workflow server |

---

## 9. Tool Description Quality

A February 2026 empirical study (arXiv:2602.14878) of 856 tools across 103 MCP servers found significant quality issues in tool descriptions:

- Tool descriptions are the critical interface between LLMs and tools
- Defective or "smelly" descriptions misguide LLM tool selection
- Common issues: vague descriptions, missing parameter documentation, inconsistent naming
- Impact: Incorrect tool selection, wrong argument passing, reduced agent effectiveness

This research validates the 2025-11-25 spec's addition of tool naming guidance and the ongoing focus on description quality in the MCP ecosystem.

---

## 10. Ecosystem & Adoption

### 10.1 Official SDKs

| Language | Repository | Stars (Feb 2026) | Tier |
|----------|-----------|-------------------|------|
| TypeScript | `modelcontextprotocol/typescript-sdk` | ~11,600 | Tier 1 |
| Python | `modelcontextprotocol/python-sdk` | ~21,700 | Tier 1 |

The 2025-11-25 spec established an SDK tiering system with clear requirements for feature support and maintenance commitments.

Additional community SDKs exist for Rust, Go, Java, C#, Ruby, and other languages.

### 10.2 Server Registry

- `modelcontextprotocol/registry`: Community-driven registry (6,400+ stars)
- `modelcontextprotocol/servers`: Reference implementations (79,000+ stars)
- Monthly SDK downloads: 97 million+
- Active servers: 10,000+

### 10.3 Major Adopters

| Category | Adopters |
|----------|---------|
| **AI Platforms** | Anthropic (Claude), OpenAI (ChatGPT, Agents SDK), Google (Gemini), Microsoft (Copilot) |
| **IDEs** | VS Code, Cursor, Windsurf, Zed, Android Studio |
| **Agent Frameworks** | Block (Goose), LangChain, Factory (Droid) |
| **Enterprise** | Salesforce, ServiceNow, Cloudflare, Bloomberg |

### 10.4 Server Ecosystem Categories

| Category | Examples |
|----------|---------|
| **Databases** | PostgreSQL, MySQL, SQLite, MongoDB, DuckDB, Elasticsearch |
| **Cloud Services** | AWS, GCP, Azure, Cloudflare |
| **Developer Tools** | GitHub, GitLab, Jira, Linear, Sentry |
| **Communication** | Slack, Email, Discord, Teams |
| **File/Knowledge** | File system, Google Drive, Notion, Confluence |
| **Search/Web** | Brave Search, Exa, Firecrawl, web browsers |
| **Observability** | Datadog, Grafana, PagerDuty |
| **Commerce** | Shopify, Stripe |

---

## 11. Security Model

### 11.1 Key Principles

1. **User Consent and Control**: Users must explicitly consent to and understand all data access and operations
2. **Data Privacy**: Hosts must obtain explicit user consent before exposing user data to servers
3. **Tool Safety**: Tools represent arbitrary code execution; hosts must obtain explicit user consent before invoking any tool
4. **LLM Sampling Controls**: Users must explicitly approve any LLM sampling requests

### 11.2 Trust Model

| Component | Trust Level |
|-----------|------------|
| Host | Trusted (user's application) |
| Client | Trusted (within the host) |
| Server | Semi-trusted (third-party code) |
| Tool descriptions/annotations | **Untrusted** (unless from trusted server) |
| LLM decisions | Untrusted (may be manipulated via prompt injection) |
| Network | Untrusted (require TLS for remote) |

### 11.3 Known Attack Vectors

| Attack | Mitigation |
|--------|-----------|
| **Tool description manipulation** | Treat annotations as untrusted; user approval before execution |
| **Prompt injection via tool results** | Sanitize tool output; don't auto-execute tool chains |
| **DNS rebinding** | Validate Origin header; bind to localhost |
| **Token theft** | Audience binding (RFC 8707); don't passthrough tokens |
| **Session hijacking** | Cryptographically secure session IDs; proper cookie handling |
| **Confused deputy** | Obtain user consent per dynamic client; scope minimization |
| **SSRF via CIMD** | Validate metadata document URLs; restrict fetch targets |

---

## 12. Relationship to Other Protocols

| Protocol | Relationship to MCP | Integration Pattern |
|----------|-------------------|--------------------|
| **A2A** | Complementary — A2A handles agent-to-agent; MCP handles agent-to-tool | Agent uses MCP for tools, A2A for delegation |
| **UCP** | Complementary — UCP uses MCP as one integration path for commerce | Merchant exposes catalog via MCP server |
| **ACP (Commerce)** | Complementary — Commerce ACP operates at a higher layer | ChatGPT uses MCP internally, Commerce ACP externally |
| **ANP** | Complementary — ANP focuses on network/discovery layer below MCP | ANP meta-protocol could negotiate MCP usage |
| **AP2** | Complementary — AP2 extends A2A/MCP with payment primitives | Payment tools exposed as MCP servers |
| **AGNTCY/SLIM** | Infrastructure — SLIM provides secure transport for MCP | MCP messages routed through SLIM data plane |
| **AGENTS.md** | Complementary — AGENTS.md provides repo-level agent guidance | MCP servers read AGENTS.md for context |

MCP occupies **Layer 3 (Agent-to-Tool)** in the five-layer agentic protocol stack.

---

## 13. Governance

### 13.1 AAIF Governance

MCP was contributed to the **Agentic AI Foundation (AAIF)** under the Linux Foundation in December 2025. Governance includes:

- **Technical Steering Committee (TSC)**: Specification decisions
- **Working Groups**: Focused on specific areas (auth, transport, etc.)
- **Interest Groups**: Broader community discussion
- **SEP Process**: Specification Enhancement Proposals (SEP-XXX) for changes
- **SDK Tiering**: Clear requirements for feature support and maintenance

### 13.2 Specification Process

Changes follow the SEP (Specification Enhancement Proposal) process:
1. SEP filed as GitHub issue
2. Community discussion
3. Working Group review
4. TSC approval
5. Implementation in SDKs
6. Inclusion in next spec revision

---

## 14. Strengths & Weaknesses

### Strengths
- Massive ecosystem and adoption (79K+ stars, 97M+ monthly downloads)
- Simple, well-specified protocol (JSON-RPC 2.0 is universally understood)
- Backed by all major AI companies
- Solves a real, immediate pain point (tool integration)
- Clean separation of concerns (tools vs. resources vs. prompts)
- Rich client features (sampling, elicitation, roots) enable agentic behaviors
- Mature authorization framework (OAuth 2.1 + CIMD)
- Formal governance under Linux Foundation
- Transport-agnostic design with strong default transports

### Weaknesses
- No agent identity model (OAuth covers tool auth, not agent identity)
- Limited to client-server (1:1) topology — no native pub/sub or multi-party
- Stateless sessions by default — complex workflows require external state management
- Tool description quality is empirically poor across the ecosystem
- No built-in rate limiting or quota management
- Tasks feature is experimental — durable workflows not yet standardized
- Authorization complexity may deter simpler use cases

---

## 15. Future Directions

### 15.1 Confirmed/In-Progress
- **Tasks maturation**: Moving from experimental to stable for durable request tracking
- **Auth extensions**: Modular authorization extensions (ext-auth repository)
- **Registry federation**: Moving toward a federated registry model
- **SDK tier expansion**: More languages reaching Tier 1 status

### 15.2 Expected
- **A2A integration patterns**: Clean handoff between MCP (tools) and A2A (agents)
- **Identity bridging**: Connecting MCP OAuth identity with A2A Agent Cards
- **IETF engagement**: Potential RFC standardization of wire format
- **Multimodal tools**: Richer support for audio, video, and mixed-media tool interactions

### 15.3 Speculative
- **Agent-to-agent via MCP**: Some push to extend MCP for lightweight agent collaboration
- **Decentralized discovery**: DID-based server discovery as alternative to DNS
- **Commerce primitives**: Native payment/checkout capabilities in MCP tools

---

## 16. References

### Specifications
- MCP Specification (2025-11-25): https://modelcontextprotocol.io/specification/2025-11-25
- MCP Changelog: https://modelcontextprotocol.io/specification/2025-11-25/changelog
- MCP Transports: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP Authorization: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP Sampling: https://modelcontextprotocol.io/specification/2025-11-25/client/sampling
- MCP Elicitation: https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation

### Code & Registry
- MCP GitHub Organization: https://github.com/modelcontextprotocol
- MCP Servers Repository: https://github.com/modelcontextprotocol/servers
- MCP Registry: https://github.com/modelcontextprotocol/registry
- Auth Extensions: https://github.com/modelcontextprotocol/ext-auth
- TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- Python SDK: https://github.com/modelcontextprotocol/python-sdk
- MCP Inspector: https://github.com/modelcontextprotocol/inspector

### Governance
- AAIF Announcement: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation
- AAIF Guide (IntuitionLabs): https://intuitionlabs.ai/pdfs/agentic-ai-foundation-guide-to-open-standards-for-ai-agents.pdf

### Analysis & Research
- MCP Tool Description Quality: arXiv:2602.14878 (Feb 2026)
- MCP Authorization Spec Analysis: https://den.dev/blog/mcp-november-authorization-spec/
- MCP Technical Overview (CodiLime): https://codilime.com/blog/model-context-protocol-explained/
- Current State of MCP (Elastic): https://www.elastic.co/search-labs/blog/mcp-current-state
- MCP Practical Guide: https://artificialintelligenceschool.com/model-context-protocol-mcp-guide/
