# 02 — Agent-to-Agent Protocol (A2A) Deep Dive

## Executive Summary

The Agent2Agent (A2A) Protocol is an open standard for communication and interoperability between independent, opaque AI agent systems. Initiated by Google in April 2025 and now governed by the Linux Foundation, A2A defines how agents built on different frameworks, languages, and by different vendors discover each other, negotiate interaction modalities, manage collaborative tasks, and securely exchange information -- all without exposing their internal state.

As of February 2026, A2A has reached **Release Candidate v1.0** (latest released version: 0.3.0), with a three-layer specification architecture (Data Model, Operations, Protocol Bindings), official SDKs in five languages, and gRPC support alongside JSON-RPC and HTTP/REST. The August 2025 merger with IBM's Agent Communication Protocol (ACP) consolidated the agent-to-agent layer under a single standard.

A2A occupies **Layer 4 (Agent-to-Agent)** in the agentic protocol stack, complementing MCP (Layer 3: Agent-to-Tool) and UCP/Commerce ACP (Layer 5: Commerce).

---

## 1. Problem Statement

Modern enterprises deploy AI agents from multiple vendors and frameworks (LangChain, CrewAI, AutoGen, custom solutions). These agents are typically:

- **Opaque**: Their internal reasoning, memory, and tools are not exposed
- **Isolated**: They cannot discover or communicate with agents from other systems
- **Framework-locked**: Switching frameworks means rewriting all inter-agent integrations

Without a standard protocol, every agent-to-agent connection requires bespoke glue code. As one analysis puts it: the number of fragile point-to-point links explodes as new agents are added, creating "spaghetti integration." A2A standardizes the "agent communication contract" so organizations can safely combine specialist agents across teams and vendors.

---

## 2. Specification Architecture

### 2.1 Three-Layer Design

The RC v1.0 specification introduces a layered architecture that separates concerns:

```
┌──────────────────────────────────────────────────┐
│            Layer 3: Protocol Bindings             │
│  JSON-RPC Methods │ gRPC RPCs │ HTTP/REST │ Custom│
├──────────────────────────────────────────────────┤
│            Layer 2: Abstract Operations           │
│  Send Message │ Stream │ Get/List/Cancel Task     │
│  Subscribe │ Push Notifications │ Get Agent Card   │
├──────────────────────────────────────────────────┤
│            Layer 1: Canonical Data Model          │
│  Task │ Message │ AgentCard │ Part │ Artifact     │
│  Extension │ (Protocol Buffers definitions)       │
└──────────────────────────────────────────────────┘
```

**Layer 1: Canonical Data Model** -- Core data structures expressed as Protocol Buffer messages. The file `spec/a2a.proto` is the single authoritative normative definition. All SDK bindings and schemas MUST be generated from this proto file.

**Layer 2: Abstract Operations** -- Binding-independent descriptions of what A2A agents must support: Send Message, Send Streaming Message, Get Task, List Tasks, Cancel Task, Subscribe to Task, Push Notification management, Get Agent Card.

**Layer 3: Protocol Bindings** -- Concrete mappings to JSON-RPC 2.0 (primary), gRPC (added in v0.3+), HTTP+JSON/REST, and custom bindings.

### 2.2 Guiding Principles

1. **Simple**: Reuse existing standards (HTTP, JSON-RPC 2.0, SSE, gRPC)
2. **Enterprise Ready**: Authentication, authorization, security, privacy, tracing, monitoring
3. **Async First**: Designed for long-running tasks and human-in-the-loop interactions
4. **Modality Agnostic**: Text, files, structured data, audio/video references, embedded UI
5. **Opaque Execution**: Agents collaborate without sharing internal thoughts, plans, or tools

### 2.3 Normative Content and Versioning

The proto file is the source of truth. The specification follows a formal deprecation lifecycle:

| Phase | Description |
|-------|-------------|
| Introduction | New names added; legacy names remain available, marked deprecated |
| Documentation | Migration guidance provided for breaking changes |
| SDK Aliases | Deprecated alias types maintain backward compatibility |
| Removal | Deprecated names eligible for removal at next major version |

**Version History**: 0.1.0 -> 0.2.0 -> 0.2.4 -> 0.2.5 -> 0.2.6 -> 0.3.0 (latest released) -> RC v1.0 (draft)

---

## 3. Core Actors

| Actor | Description |
|-------|-------------|
| **User** | End-user (human or automated) who initiates a goal |
| **A2A Client (Client Agent)** | Application or agent that sends requests to A2A Servers on behalf of a user |
| **A2A Server (Remote Agent)** | Agent exposing an A2A-compliant endpoint, processing tasks |

Remote agents operate as opaque systems. Client agents can also act as servers to other agents, enabling **any topology** (tree, mesh, chain) as long as it fits the workflow.

---

## 4. Data Model

### 4.1 Agent Card

The Agent Card is the foundation of A2A discovery and interoperability. It is a JSON metadata document published by an A2A Server, typically at `/.well-known/agent.json`, describing:

```json
{
  "protocolVersions": ["0.3.0"],
  "name": "Travel Planner Agent",
  "description": "Plans trips including flights, hotels, and activities",
  "supportedInterfaces": [
    {"url": "https://travel-agent.example.com/a2a/v1", "protocolBinding": "JSONRPC"},
    {"url": "https://travel-agent.example.com/a2a/grpc", "protocolBinding": "GRPC"}
  ],
  "provider": {
    "organization": "Acme Travel Corp",
    "url": "https://acmetravel.example.com"
  },
  "version": "2.1.0",
  "defaultInputModes": ["text/plain", "application/json"],
  "defaultOutputModes": ["text/plain", "application/json"],
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "stateTransitionHistory": false,
    "extendedAgentCard": true
  },
  "skills": [
    {
      "id": "plan_trip",
      "name": "Plan a Trip",
      "description": "Creates a complete travel itinerary",
      "tags": ["travel", "planning"],
      "inputModes": ["text/plain", "application/json"],
      "outputModes": ["application/json"],
      "examples": ["Plan a 5-day trip to Paris in spring"]
    }
  ],
  "securitySchemes": {
    "OAuth2": {
      "type": "oauth2",
      "flows": {
        "clientCredentials": {
          "tokenUrl": "https://idp.example.com/oauth2/token",
          "scopes": {
            "travel.read": "Read-only operations",
            "travel.book": "Booking operations"
          }
        }
      }
    }
  },
  "security": [
    {"OAuth2": ["travel.read"]}
  ]
}
```

**Key Agent Card fields**:

| Field | Purpose |
|-------|---------|
| `protocolVersions` | Which A2A spec versions the agent supports |
| `supportedInterfaces` | Endpoints + protocol bindings (JSON-RPC, gRPC, REST) |
| `capabilities` | Protocol features: streaming, push notifications, history, extended card |
| `skills` | What the agent can do, with IDs, descriptions, tags, examples |
| `securitySchemes` | Supported auth methods (OAuth2, API keys, HTTP auth, OIDC, mTLS) |
| `security` | Required auth for the agent |
| `defaultInputModes` / `defaultOutputModes` | MIME types for content exchange |

**Extended Agent Card**: When `capabilities.extendedAgentCard` is true, the agent supports an authenticated endpoint that reveals additional private skills, capabilities, or configuration not exposed in the public card. This is crucial for enterprise environments where agents expose different capabilities depending on the caller's authorization level.

### 4.2 Task

The fundamental unit of work in A2A. Tasks are stateful and progress through a defined lifecycle:

```
submitted -> working -> completed
                   \-> failed
                   \-> canceled
                   \-> rejected
         -> input-required -> (client sends more data) -> working
```

**Task States (TaskState enum)**:

| State | Description |
|-------|-------------|
| `submitted` | Task accepted, queued for processing |
| `working` | Agent actively processing |
| `input-required` | Agent needs additional information from client |
| `completed` | Task finished successfully |
| `failed` | Task failed |
| `canceled` | Task canceled by client request |
| `rejected` | Task rejected by server (permissions, unsupported, etc.) |

**Task fields**: `id`, `contextId`, `status` (state + message + timestamp), `artifacts`, `history` (messages), `metadata`.

### 4.3 Message

A communication turn between client and agent:

| Field | Description |
|-------|-------------|
| `role` | `"user"` (from client) or `"agent"` (from server) |
| `messageId` | Unique identifier |
| `contextId` | Groups related messages and tasks |
| `taskId` | Optional association to a task |
| `parts` | Array of content parts |

### 4.4 Parts (Content Types)

Parts are the atomic content units. RC v1.0 removes the `kind` discriminator in favor of member-name-based typing:

**TextPart**:
```json
{"text": "Plan a 5-day trip to Tokyo"}
```

**DataPart** (structured JSON):
```json
{
  "data": {
    "incidentId": "INC-123",
    "severity": "high",
    "impactedServices": ["payments-api"]
  },
  "mediaType": "application/json"
}
```

**FilePart** (inline bytes or URL reference):
```json
{
  "raw": "iVBORw0KGgo...",
  "filename": "topology-diagram.png",
  "mediaType": "image/png"
}
```
or:
```json
{
  "url": "https://agent.example.com/artifacts/report.pdf",
  "filename": "report.pdf",
  "mediaType": "application/pdf"
}
```

### 4.5 Artifact

Output produced by an agent during task execution. Artifacts are composed of Parts and support chunked streaming via `append` and `lastChunk` fields:

```json
{
  "name": "triage-report",
  "description": "Incident triage summary with recommendations",
  "parts": [
    {"text": "Root cause: interface errors on edge-router-7 uplink Gi0/2"},
    {"data": {"rootCause": {"device": "edge-router-7", "confidence": 0.81}},
     "mediaType": "application/json"},
    {"url": "https://agent.example.com/artifacts/change-request.pdf",
     "filename": "change-request.pdf",
     "mediaType": "application/pdf"}
  ],
  "index": 0,
  "append": false,
  "lastChunk": true
}
```

### 4.6 Context

An optional server-generated identifier to logically group related tasks and messages into a conversation or session. Clients MAY provide a `contextId`; servers MUST provide one.

### 4.7 Extension

A mechanism for agents to provide additional functionality or data beyond the core specification. Extensions enable custom protocol behaviors without modifying the base spec.

---

## 5. Protocol Operations

### 5.1 Core Operations

| Operation | Description | Returns |
|-----------|-------------|---------|
| **Send Message** | Primary operation; sends a message to an agent | Task or Message |
| **Send Streaming Message** | Same, but with real-time SSE/gRPC streaming | Stream of Task + events |
| **Get Task** | Retrieve current task state (polling) | Task |
| **List Tasks** | List tasks with filtering and pagination | Task[] + pagination |
| **Cancel Task** | Request cancellation of in-progress task | Updated Task |
| **Subscribe to Task** | Stream updates for an existing task | Stream of events |
| **Create Push Notification Config** | Set up webhook for async updates | Config |
| **Get/List/Delete Push Notification Config** | Manage notification configs | Config(s) |
| **Get Agent Card** | Retrieve public agent card | AgentCard |
| **Get Extended Agent Card** | Retrieve authenticated agent card | AgentCard (extended) |

### 5.2 Method Mapping Across Bindings

| Operation | JSON-RPC Method | gRPC RPC | HTTP/REST |
|-----------|----------------|----------|-----------|
| Send Message | `message/send` | `SendMessage` | `POST /tasks` |
| Stream Message | `message/stream` | `StreamMessage` | `POST /tasks:streamSend` |
| Get Task | `tasks/get` | `GetTask` | `GET /tasks/{id}` |
| List Tasks | `tasks/list` | `ListTasks` | `GET /tasks` |
| Cancel Task | `tasks/cancel` | `CancelTask` | `POST /tasks/{id}:cancel` |
| Subscribe to Task | `tasks/subscribe` | `SubscribeToTask` | `GET /tasks/{id}:subscribe` |
| Get Agent Card | (well-known URL) | `GetAgentCard` | `GET /.well-known/agent.json` |

### 5.3 Streaming Architecture

A2A supports two streaming patterns:

**Message-only stream**: For simple interactions, the server returns exactly one `Message` object and closes the stream immediately.

**Task lifecycle stream**: For complex processing:
1. Stream begins with a `Task` object
2. Followed by zero or more `TaskStatusUpdateEvent` and `TaskArtifactUpdateEvent` objects
3. Stream closes when task reaches a terminal state

**Streaming event types**:

- **TaskStatusUpdateEvent**: Communicates current task state and step-level messages (e.g., "Pulling telemetry...", "Correlating devices...")
- **TaskArtifactUpdateEvent**: Delivers artifacts with chunking support (`append`, `lastChunk`)

**Transport mechanisms**:
- JSON-RPC: Server-Sent Events (SSE) over HTTP
- gRPC: Server-side streaming RPCs
- REST: SSE endpoint at `/tasks/{id}:subscribe`

### 5.4 Push Notifications

For long-running, disconnected scenarios:
- Client creates a `PushNotificationConfig` with a webhook URL
- Agent sends HTTP POST requests to the webhook with `StreamResponse` payloads
- Config persists until task completion or explicit deletion
- Webhook supports authentication tokens for secure delivery

### 5.5 Multi-Turn Interaction

When an agent needs more information:
1. Agent transitions task to `input-required` state
2. Returns a message explaining what's needed
3. Client sends additional data via `message/send` with the same `taskId`
4. Agent resumes processing from `working` state

```json
{
  "task": {
    "id": "task-uuid",
    "status": {
      "state": "input-required",
      "message": {
        "role": "agent",
        "parts": [{"text": "I need more details. Where would you like to fly from?"}]
      }
    }
  }
}
```

---

## 6. Protocol Bindings

### 6.1 JSON-RPC 2.0 Binding (Primary)

The original and most widely implemented binding. Uses JSON-RPC 2.0 over HTTP(S).

**Request example**:
```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "messageId": "msg-001",
      "contextId": "ctx-incident-123",
      "parts": [
        {"text": "Triage incident INC-123 and suggest next actions."},
        {"data": {"skillId": "triage-incident", "incidentId": "INC-123"},
         "mediaType": "application/json"}
      ]
    }
  }
}
```

**Response example**:
```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "result": {
    "task": {
      "id": "task-8c2f3b21",
      "contextId": "ctx-incident-123",
      "status": {
        "state": "submitted",
        "message": {
          "role": "agent",
          "parts": [{"text": "Task submitted. Starting incident triage for INC-123."}]
        }
      }
    }
  }
}
```

### 6.2 gRPC Binding (v0.3+)

Added in version 0.3.0 for higher-performance, strongly-typed environments. Uses Protocol Buffers for serialization and supports native server-side streaming. Ideal for:
- Low-latency internal microservice communication
- Environments with existing gRPC infrastructure
- Strongly-typed language ecosystems (Go, Java, Rust)

### 6.3 HTTP+JSON/REST Binding

RESTful endpoint mapping for standard HTTP clients:
- Resource-oriented URLs: `/tasks/{id}`, `/tasks`
- Standard HTTP methods: GET, POST, DELETE
- Action endpoints: `/tasks/{id}:cancel`, `/tasks/{id}:subscribe`
- Follows Google API Design Guidelines conventions

### 6.4 Custom Bindings

Custom bindings are permitted as long as they fulfill the binding requirements defined in the specification. Implementations must map all abstract operations to their chosen transport.

---

## 7. Security Model

### 7.1 Authentication Schemes

A2A defines security as a **discoverable contract** in the Agent Card. The `securitySchemes` field supports:

| Scheme Type | Description |
|-------------|-------------|
| `apiKey` | API key authentication (header, query, cookie) |
| `http` | HTTP auth (Basic, Bearer tokens) |
| `oauth2` | OAuth 2.0 with flows (clientCredentials, authorizationCode, etc.) |
| `openIdConnect` | OpenID Connect Discovery |
| `mutualTLS` | Mutual TLS (mTLS) for certificate-based auth |

A2A does **not** implement identity itself -- it advertises requirements while enterprise identity providers (OIDC/OAuth2) and gateways enforce authentication and authorization.

### 7.2 Agent Card Signing (v0.3+)

A2A supports but does **not enforce** Agent Card signing. Cards can include a `jwks` field with a JSON Web Key Set for verification:

```json
{
  "jwks": {
    "keys": [
      {
        "kty": "RSA",
        "use": "sig",
        "kid": "agent-signing-key-1",
        "n": "...",
        "e": "AQAB"
      }
    ]
  }
}
```

Without enforcement, Agent Card spoofing remains a realistic attack vector. There is no central registry for Agent Cards, making spoofing inexpensive.

### 7.3 Data Access and Authorization Scoping

The specification requires (Section 13.1):
- Implementations MUST scope data access to the authenticated client
- `ListTasks` MUST return only tasks visible to the authenticated caller
- Multi-tenant environments MUST use the `tenant` parameter for isolation
- Capability-based access control is RECOMMENDED

### 7.4 Known Security Concerns

Based on Semgrep's security analysis (Dec 2025) and academic work (arXiv:2505.12490):

**Protocol-level issues**:

| Issue | Description | Severity |
|-------|-------------|----------|
| **Unsigned Agent Cards** | Spoofing by bad actors; no central registry | High |
| **Token lifetime** | No enforcement of short-lived OAuth tokens; leaked tokens remain valid | High |
| **Coarse-grained scopes** | Tokens with broad capabilities not limited to single transactions | Medium |
| **Missing consent mechanisms** | No protocol-level requirement for user approval before data sharing | Medium |
| **Stream hijacking** | Multiple concurrent streams without mandating termination of others | Medium |
| **Data leakage** | Sensitive data may traverse intermediate agents or exist in shared context | Medium |
| **JSON serialization** | Unicode normalization, nested object depth, oversized payloads | Low-Med |

**Implementation-level concerns**:

- **Executor bugs**: Business logic errors in task processing and LLM invocation are the primary attack surface
- **SDK vulnerabilities**: Object handling, serialization edge cases, language-specific issues in early SDKs
- **Prompt injection**: All LLM applications face prompt injection; A2A inherits MCP attack surface through tool use
- **Blocking violations**: Operations MUST return immediately; improperly blocking requests is an implementation bug area

### 7.5 Security Audit Checklist

Semgrep published an [A2A audit checklist](https://docs.google.com/spreadsheets/d/1qiYF3SlwP8S-op5u5Gl8BTZqCwe8Q8vldnL0gcn-h4M/) covering:
- Agent Card validation and signing verification
- OAuth scope enforcement and token lifetime
- Input sanitization and prompt injection defenses
- Stream isolation and session management
- Data leakage prevention in multi-agent chains

---

## 8. ACP Merger

### 8.1 Background

IBM Research launched the Agent Communication Protocol (ACP) in March 2025 as part of its BeeAI platform. ACP was a lightweight, REST-native, HTTP-first protocol -- essentially "HTTP for AI agents." It was donated to the Linux Foundation shortly after launch.

### 8.2 Consolidation (August 2025)

ACP [merged into A2A](https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/) under Linux Foundation governance. The rationale:

- Both protocols addressed agent-to-agent communication at the same layer
- Having two competing standards would fragment the ecosystem
- A2A had broader industry backing (Google + 50+ partners)
- ACP's design principles were incorporated into A2A

### 8.3 What ACP Contributed

| Contribution | Impact on A2A |
|-------------|---------------|
| **Lightweight REST philosophy** | Influenced A2A's HTTP+JSON/REST binding |
| **Framework agnosticism** | Strong emphasis on working across LangChain, CrewAI, BeeAI |
| **Local-first orchestration** | Design for low-latency local agent coordination |
| **BeeAI ecosystem** | Open-source agent platform donated to Linux Foundation |
| **ProtocolBench** | IBM's benchmarking tool (arXiv:2504.06094) for protocol evaluation |

IBM now directs users to A2A and provides migration guides for ACP users.

---

## 9. Interaction Patterns

### 9.1 Simple Request-Response

Client sends `message/send`, receives a completed Task or direct Message:

```
Client                    Server
  |--- message/send -------->|
  |<--- Task (completed) ----|
```

### 9.2 Streaming with SSE

Client sends `message/stream`, receives a stream of events:

```
Client                    Server
  |--- message/stream ----->|
  |<--- Task (submitted) ---|
  |<--- StatusUpdate -------|  "Analyzing data..."
  |<--- StatusUpdate -------|  "Generating report..."
  |<--- ArtifactUpdate -----|  (chunk 1)
  |<--- ArtifactUpdate -----|  (chunk 2, lastChunk=true)
  |<--- StatusUpdate -------|  state: completed
  |<--- [stream closes] ----|
```

### 9.3 Multi-Turn with Input Required

```
Client                    Server
  |--- message/send -------->|
  |<--- Task (input-req) ----|  "What's your budget?"
  |--- message/send -------->|  "$5000"
  |<--- Task (working) ------|
  |<--- Task (completed) ----|
```

### 9.4 Async with Push Notifications

```
Client                        Server
  |--- message/send ------------>|
  |<--- Task (submitted) --------|
  |--- pushNotification/create ->|  (webhook URL)
  |<--- Config (created) --------|
  |                               |  [processing...]
  |<--- POST webhook ------------|  StatusUpdate: working
  |<--- POST webhook ------------|  ArtifactUpdate
  |<--- POST webhook ------------|  StatusUpdate: completed
```

### 9.5 Multi-Agent Delegation

Agents can act as both clients and servers, forming hierarchical or mesh topologies:

```
User -> Agent A (client) --A2A--> Agent B (server/client) --A2A--> Agent C (server)
                          --A2A--> Agent D (server)
```

Agent B receives a task from Agent A, then delegates subtasks to Agents C and D, aggregating results before responding to Agent A.

---

## 10. Known Limitations and Gaps

Based on practical deployment experience (CodiLime analysis, Feb 2026):

### 10.1 No Skill Parameterization

A2A Agent Cards list skills with descriptions, tags, and examples, but do **not** require machine-readable input/output schemas (like JSON Schema). This means:
- LLM planners can discover "what skills exist" but cannot reliably determine exact required parameters
- Fully automated orchestration is harder without type-safe skill contracts
- Workaround: Use `DataPart` with convention-based fields (e.g., `skillId`, typed parameters)

### 10.2 No Direct Skill Invocation

There is no standard `message/send` parameter to directly request a specific skill by ID. The agent routes based on natural language content. Workaround: Include skill hints in `DataPart`:

```json
{"data": {"skillId": "triage-incident", "incidentId": "INC-123"}}
```

### 10.3 Authorization Creep Risk

A2A's security model advertises auth requirements at the agent level (via `securitySchemes`), but does not currently define a machine-readable way to map scopes to individual skills. A token granting `netops.change` gives access to all change-capable skills, not just the intended one. This must be enforced by the agent or gateway.

### 10.4 No Built-in Identity Verification

Agent Cards are self-declared claims, not cryptographically verified proofs. Without enforced signing and a trust registry, agent identity relies on DNS ownership and TLS certificates.

---

## 11. Specification Evolution

### 11.1 Version Timeline

| Version | Date | Key Changes |
|---------|------|-------------|
| 0.1.0 | April 2025 | Initial release with Google announcement |
| 0.2.0 | May 2025 | Stabilized Agent Card schema, task lifecycle |
| 0.2.4-0.2.6 | Jun-Aug 2025 | ACP merger integration, refinements |
| 0.3.0 | Oct 2025 | gRPC binding, Agent Card signing (JWKS), `supportedInterfaces`, `protocolVersions` |
| RC v1.0 | Jan 2026 | Three-layer spec architecture, proto-as-normative, breaking changes (kind discriminator removed, extended card relocated), multi-tenant support, List Tasks, extended error handling |

### 11.2 Breaking Changes in RC v1.0

**Kind Discriminator Removed**: Part types and streaming events no longer use a `kind` field. Instead, the JSON member name acts as the discriminator:

```
Legacy:  {"kind": "text", "text": "Hello"}
Current: {"text": "Hello"}

Legacy:  {"kind": "status-update", "taskId": "...", "status": {...}}
Current: {"statusUpdate": {"taskId": "...", "status": {...}}}
```

**Extended Agent Card Relocated**: `supportsExtendedAgentCard` moved from top-level Agent Card to `capabilities.extendedAgentCard`.

**Multiple Message Renames**: `MessageSendParams` -> `SendMessageRequest`, `SendStreamingMessageSuccessResponse` -> `StreamResponse`, etc. Legacy names maintained with deprecation schedule.

---

## 12. Ecosystem & Adoption

### 12.1 Founding Partners (April 2025)

Over 50 organizations supported the A2A launch:

| Category | Partners |
|----------|---------|
| **Cloud/AI Platforms** | Google, Salesforce, SAP, ServiceNow, Workday |
| **Agent Frameworks** | LangChain, CrewAI, Cohere, Writer |
| **Enterprise** | Accenture, Deloitte, KPMG, McKinsey |
| **Infrastructure** | MongoDB, Neo4j, Elastic |

### 12.2 Official SDKs

A2A provides official SDKs in five languages:

| Language | Features |
|----------|----------|
| **Python** | FastAPI/Starlette server, typed models, OpenTelemetry tracing |
| **JavaScript/TypeScript** | Full client/server implementation |
| **Go** | gRPC-native support |
| **Java** | Spring Boot integration |
| **.NET** | C# client and server libraries |

### 12.3 Governance

A2A is governed under the Linux Foundation's LF AI & Data Foundation:
- Neutral governance with patent and IP protections
- Community-driven evolution via GitHub PRs to `a2aproject/A2A`
- Specification source at `a2a-protocol.org` (migrated from `google-a2a.github.io`)
- Coordinated with MCP (AAIF) and AGNTCY

### 12.4 Notable Implementations

- **GitLab Duo**: Announced A2A support for intelligent DevSecOps workflows
- **Google Cloud**: Reference implementations in multiple frameworks
- **Salesforce Agentforce**: Multi-agent orchestration via A2A
- Multiple startups building A2A-first agent marketplaces

---

## 13. Relationship to Other Protocols

| Protocol | Relationship to A2A | Layer |
|----------|-------------------|-------|
| **MCP** | Complementary -- MCP handles tool use; A2A handles agent collaboration | L3 (Tool) |
| **UCP** | Complementary -- UCP integrates via A2A for commerce agent coordination | L5 (Commerce) |
| **Commerce ACP** | Complementary -- Agentic Commerce Protocol for payment flows | L5 (Commerce) |
| **ANP** | Overlapping -- ANP also addresses agent networking with DID-based identity | L4 (Agent) |
| **AP2** | Extension -- Agent Payments Protocol designed as A2A extension | L5 (Commerce) |
| **AGNTCY/SLIM** | Infrastructure -- SLIM provides secure transport for A2A | L1-2 (Infra) |

**MCP + A2A complementarity**: An A2A Client agent requests an A2A Server agent to perform a complex task. The Server agent uses MCP to interact with tools, APIs, and data sources to fulfill the A2A task. MCP is "how agents use tools"; A2A is "how agents partner."

---

## 14. Strengths & Weaknesses

### Strengths

- **Opaque agent model**: No shared state, memory, or tool access required
- **Three-layer architecture**: Clean separation of data model, operations, and transport
- **Multiple bindings**: JSON-RPC, gRPC, REST -- covers all deployment scenarios
- **Rich task lifecycle**: Multi-turn, streaming, async, with `input-required` for HITL
- **Industry consolidation**: ACP merger eliminates fragmentation at agent-to-agent layer
- **Backed by Google** and 50+ enterprise partners under Linux Foundation governance
- **Official SDKs** in 5 languages with production-ready server/client libraries
- **Proto-as-normative**: Single source of truth prevents specification drift

### Weaknesses

- **No built-in identity standard**: Agent Cards are self-declared, not cryptographically verified
- **No skill parameterization**: No machine-readable I/O schemas for skills
- **Authorization mapping gap**: No standard way to map OAuth scopes to individual skills
- **Agent Card signing optional**: Spoofing remains easy without enforcement
- **Still pre-1.0**: Breaking changes between versions (kind discriminator, naming)
- **No decentralized discovery**: Well-known URLs require DNS ownership
- **No payment support**: Commerce/payment delegated to AP2/UCP extensions

---

## 15. Future Directions

- **Specification 1.0 GA**: Finalize RC v1.0 with stability guarantees
- **Skill schemas**: Machine-readable input/output definitions (community discussion active)
- **Agent registries**: Centralized and federated discovery beyond well-known URLs
- **Mandatory card signing**: Moving from optional to required JWKS verification
- **Cryptographic agent identity**: Verifiable credentials or DIDs for agent authentication
- **Multi-agent choreography**: Standard orchestration patterns beyond delegation
- **Commerce extensions**: Tighter integration with UCP and AP2 for payment flows
- **Observability standards**: OpenTelemetry integration for cross-agent tracing
- **Capability-based access**: Powers-style capability tokens limiting what deputies can do

---

## References

- A2A Specification (RC v1.0): https://a2a-protocol.org/latest/specification/
- A2A Specification (v0.3.0): https://a2a-protocol.org/v0.3.0/specification/
- A2A Key Concepts: https://a2a-protocol.org/latest/topics/key-concepts/
- A2A GitHub Repository: https://github.com/a2aproject/A2A
- A2A Announcement (April 2025): https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/
- ACP-A2A Merger: https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/
- Semgrep Security Guide: https://semgrep.dev/blog/2025/a-security-engineers-guide-to-the-a2a-protocol
- CodiLime Practical Guide: https://codilime.com/blog/a2a-protocol-explained/
- A2A Security Analysis (academic): https://arxiv.org/html/2505.12490
- ProtocolBench: https://arxiv.org/abs/2504.06094
