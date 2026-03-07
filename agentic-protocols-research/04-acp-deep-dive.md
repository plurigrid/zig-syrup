# 04 — ACP Deep Dive: Two Protocols, One Abbreviation

## Executive Summary

"ACP" names two entirely different protocols that share nothing but an abbreviation. Understanding this disambiguation is essential for navigating the agentic protocol landscape.

1. **Agent Communication Protocol (ACP)** — IBM Research / BeeAI. An agent-to-agent messaging protocol launched March 2025. Merged into Google's A2A under the Linux Foundation in August 2025. Now deprecated.

2. **Agentic Commerce Protocol (ACP)** — OpenAI / Stripe. A commerce checkout protocol launched February 2026 as the backend for ChatGPT's "Instant Checkout." Live and transacting. The official website is agenticcommerce.dev.

This document provides a complete technical deep-dive on both protocols, tracing IBM ACP's evolution from launch through merger, and covering Commerce ACP's architecture, checkout lifecycle, payment mechanics, and competitive positioning.

---

# Part 1: IBM Agent Communication Protocol (ACP)

## 1. Origins and Motivation

### 1.1 The BeeAI Project

IBM Research created ACP as the communication backbone of its **BeeAI** platform — an open-source system focused on agent interpretability (understanding *why* agents make decisions, not just *what* they do). BeeAI was designed to run agents **locally** on developer machines or clusters, not exclusively in the cloud.

Key BeeAI properties:
- **Open-source** under Apache 2.0
- **Local-first execution** — agents run on laptops, clusters, or edge devices
- **Multi-framework** — supports LangChain, CrewAI, AutoGen, custom agents
- **Interpretability** — tools for understanding agent behavior and decisions
- **Ollama integration** — local LLM hosting with quantized GGUF models

### 1.2 Problem Statement

IBM identified severe fragmentation in the agent ecosystem:
- Every framework invented its own JSON shape, auth story, and streaming mechanism
- Agents built on LangChain couldn't talk to CrewAI agents without brittle custom glue
- No standard existed for agent discovery, messaging, or lifecycle management
- Organizations duplicated work and maintained one-off integrations that didn't scale

ACP was positioned as **"the HTTP of AI agents"** — a minimal vocabulary so agents could discover, authenticate, and cooperate without bespoke connectors.

---

## 2. Technical Architecture

### 2.1 Design Principles

| Principle | Description |
|-----------|-------------|
| **Lightweight** | Minimal protocol surface — easy to implement in any language |
| **HTTP-native** | Standard REST conventions; JSON-RPC over HTTP/WebSockets |
| **Framework-agnostic** | Works with any agent implementation |
| **Local-first** | Optimized for low-latency local orchestration, not just cloud-to-cloud |
| **MCP-compatible** | Intentionally reuses MCP's message types to layer above it |

### 2.2 Core Concepts

| Concept | Description |
|---------|-------------|
| **Agent** | Any AI system that can send and receive messages via ACP |
| **Agent Directory** | Registry where agents publish their capabilities |
| **Message** | Content exchange unit supporting text, files, and structured data |
| **Conversation** | Ordered sequence of messages between agents |
| **Capability** | Declared skill or function an agent can perform |
| **Capability Token** | Unforgeable, signed object encoding resource type, ops, and expiry |

### 2.3 REST API Surface

ACP exposed a minimal REST API:

```
POST /agents                         # Register an agent
GET  /agents                         # List available agents
GET  /agents/{id}                    # Get agent details and capabilities
POST /agents/{id}/conversations      # Start a new conversation
POST /conversations/{id}/messages    # Send a message
GET  /conversations/{id}/messages    # Get conversation history
DELETE /conversations/{id}           # End a conversation
```

### 2.4 Agent Registration

Agents self-registered with the directory, declaring:

```json
{
  "id": "agent-financial-analysis",
  "name": "Financial Analysis Agent",
  "description": "Analyzes financial data and generates reports",
  "capabilities": [
    {
      "name": "analyze_portfolio",
      "description": "Analyze investment portfolio performance",
      "input_types": ["application/json"],
      "output_types": ["application/json", "text/markdown"]
    }
  ],
  "auth": {
    "type": "capability_token"
  },
  "metadata": {
    "framework": "langchain",
    "version": "0.3.1"
  }
}
```

### 2.5 Message Format

ACP supported multimodal content via structured messages:

```json
{
  "role": "agent",
  "content": [
    {
      "type": "text",
      "text": "Analysis complete. See the attached report."
    },
    {
      "type": "file",
      "mime_type": "application/pdf",
      "data": "<base64-encoded-content>"
    }
  ],
  "metadata": {
    "model": "gpt-4",
    "tokens_used": 1523
  }
}
```

### 2.6 Security Model

| Mechanism | Description |
|-----------|-------------|
| **Capability Tokens** | Signed, unforgeable tokens encoding resource type, operations, and expiry |
| **Kubernetes RBAC Bridge** | Maps capability claims onto existing cluster roles (no new policy silo) |
| **Optional JWS** | Per-message JSON Web Signature for integrity verification |
| **TLS** | Transport-layer encryption for HTTP/WebSocket connections |

A security analysis (arXiv:2511.03841, November 2025) found that ACP's architectural flexibility — notably its **optional** JWS enforcement — translated into high-impact integrity and confidentiality flaws when JWS wasn't enabled. The study recommended mandatory per-message integrity guarantees.

### 2.7 Streaming and Real-Time Communication

ACP supported two communication patterns:

1. **Request-Response**: Standard HTTP POST/GET for synchronous exchanges
2. **WebSocket Streaming**: For real-time, bidirectional message exchange during long-running tasks

WebSocket streaming enabled:
- Progressive result delivery
- Heartbeat/keepalive
- Server-initiated messages (status updates, clarification requests)
- Connection resumption after disconnection

### 2.8 Relationship to MCP

ACP was explicitly designed to layer **above** MCP:

```
┌─────────────────────────────────────────┐
│  ACP: Agent-to-Agent Communication       │
│  (discovery, messaging, task lifecycle)  │
├─────────────────────────────────────────┤
│  MCP: Agent-to-Tool Communication        │
│  (tool invocation, resource access)      │
└─────────────────────────────────────────┘
```

- MCP standardizes model-to-tool wiring (the "USB-C port" for data sources and APIs)
- ACP moved one layer up: agent-to-agent messaging, task handoff, and lifecycle
- ACP intentionally reused MCP's message types for compatibility

---

## 3. Evolution Timeline

| Date | Event |
|------|-------|
| **March 2025** | IBM Research launches ACP as part of BeeAI platform |
| **March 2025** | BeeAI project (including ACP) donated to Linux Foundation AI & Data |
| **April 2025** | Google launches A2A with 50+ enterprise partners |
| **April-August 2025** | IBM and Google teams recognize alignment, begin exploring convergence |
| **August 29, 2025** | Official announcement: ACP merges with A2A under Linux Foundation |
| **September 2025** | ACP team begins winding down active development |
| **September 2025** | Migration documentation and guides published |
| **December 2025** | AAIF formed; A2A continues under LF AI & Data alongside MCP under AAIF |
| **February 2026** | IBM ACP page directs all users to A2A with migration guide |

### 3.1 Why the Merger Happened

From the official LF AI & Data announcement by Kate Blair (IBM) and Todd Segal (Google):

> "When the Agent2Agent Protocol (A2A) came on the scene a month later, we immediately saw alignment in how our teams approached the challenge of enabling agents to communicate and began exploring how to bring the efforts together."

Key factors:
1. **Same layer, same problem**: Both addressed agent-to-agent communication (Layer 4)
2. **Fragmentation risk**: Two competing standards at the same layer would split the ecosystem
3. **A2A's broader coalition**: 50+ partners including Salesforce, SAP, ServiceNow, LangChain
4. **Complementary strengths**: ACP's lightweight local-first design + A2A's richer feature set
5. **Linux Foundation governance**: Both were already under LF, making organizational merger straightforward

### 3.2 What ACP Contributed to A2A

| ACP Contribution | A2A Integration |
|-----------------|-----------------|
| Lightweight REST API philosophy | Influenced A2A's clean HTTP API design |
| Framework-agnostic agent model | Core A2A design principle (agent opacity) |
| Local-first orchestration | A2A supports both local and remote agents |
| Capability token security model | Informed A2A's authentication considerations |
| BeeAI open-source ecosystem | Available as A2A reference implementation |
| Linux Foundation governance pathway | A2A adopted the same LF AI & Data governance |

### 3.3 Migration Path (ACP → A2A)

| ACP Concept | A2A Equivalent |
|-------------|---------------|
| Agent registration | Agent Card (JSON at `/.well-known/agent.json`) |
| Agent directory | Agent Card discovery + optional registries |
| Conversation | Task (with lifecycle: submitted → working → completed) |
| Message | Message with Parts (text, file, structured data) |
| Capability | Skill (declared in Agent Card) |
| Capability token | OAuth 2.0 / API key authentication |

---

## 4. Benchmark Evidence

The ProtocolBench study (arXiv:2510.17149, October 2025) from UIUC systematically compared agent protocols including ACP, A2A, and ANP across four axes:

| Axis | Finding |
|------|---------|
| **Task success** | Protocol choice significantly influenced completion rates |
| **Latency** | Up to 3.48s mean latency difference between protocols |
| **Overhead** | Completion time varied by up to 36.5% across protocols |
| **Robustness** | Resilience under failure differed consistently across protocols |

The study proposed **ProtocolRouter**, a learnable router that selects protocols per-scenario, reducing fail-storm recovery time by up to 18.1% versus the best single-protocol baseline. This suggests that the "one protocol wins all" framing is misleading — different protocols excel at different tasks.

---

# Part 2: Agentic Commerce Protocol (Commerce ACP)

## 5. Overview

The **Agentic Commerce Protocol** is an open standard developed by **Stripe and OpenAI** under the Apache 2.0 license. It defines programmatic commerce flows between buyers, AI agents, and businesses. The official specification is at [agenticcommerce.dev](https://www.agenticcommerce.dev/).

Commerce ACP powers **"Instant Checkout in ChatGPT"** — launched February 16, 2026 — enabling U.S. ChatGPT Plus, Pro, and Free users to purchase products directly inside the chat interface.

### 5.1 Key Properties

| Property | Detail |
|----------|--------|
| **License** | Apache 2.0 (open source) |
| **Developers** | Stripe + OpenAI |
| **Website** | agenticcommerce.dev |
| **API Version** | 2025-09-29 |
| **Transport** | REST API or MCP server |
| **Authentication** | Bearer token + request signing |
| **First Agent Platform** | ChatGPT (Instant Checkout) |
| **First PSP** | Stripe (Shared Payment Tokens) |

### 5.2 Design Philosophy

Commerce ACP follows three principles:
1. **Merchant remains merchant of record**: All orders, payments, taxes, and compliance stay on the merchant's existing stack
2. **Payments on merchant rails**: Authorization and settlement via the merchant's existing PSP
3. **Agent renders UI**: The AI agent is responsible for presenting checkout interface and collecting payment credentials

---

## 6. Technical Architecture

### 6.1 Protocol Phases

#### Initialization
- Merchant documents accepted payment methods (e.g., `card`) and fulfillment types (`shipping`, `digital`)
- Server publishes acceptable signature algorithms out-of-band
- Client MUST send `API-Version: 2025-09-29`; server MUST validate

#### Session Lifecycle

```
1. Create Session    POST /checkout_sessions
2. Update Session    POST /checkout_sessions/{id}
3. Complete Session  POST /checkout_sessions/{id}/complete
4. Cancel Session    POST /checkout_sessions/{id}/cancel  (optional)
5. Get Session       GET  /checkout_sessions/{id}          (optional)
```

### 6.2 API Endpoints

#### Create Checkout Session

```
POST /checkout_sessions
API-Version: 2025-09-29
Authorization: Bearer <token>
Idempotency-Key: <unique-key>
```

Request body:
```json
{
  "items": [
    { "id": "prod_12345", "quantity": 2 }
  ],
  "buyer": {
    "first_name": "Jane",
    "last_name": "Doe",
    "email": "jane@example.com",
    "phone_number": "+1-555-123-4567"
  },
  "fulfillment_address": {
    "name": "Jane Doe",
    "line_one": "1234 Chat Road",
    "city": "San Francisco",
    "state": "CA",
    "country": "US",
    "postal_code": "94102"
  }
}
```

Response includes:
- Session ID and status (`ready_for_payment`, `completed`, `canceled`)
- Payment provider info (Stripe, supported methods)
- Line items with base amount, discount, subtotal, tax, total (in cents)
- Fulfillment options and selected option
- Available fulfillment options with estimated delivery dates

#### Update Checkout Session

```
POST /checkout_sessions/{id}
```

Called when user changes items, shipping, or discounts. Each response returns the **full cart state** for display and validation. ChatGPT renders an authoritative cart on every response.

#### Complete Checkout Session

```
POST /checkout_sessions/{id}/complete
```

ChatGPT finalizes the checkout. Request includes the **Shared Payment Token (SPT)** from Stripe. Merchant confirms order creation and returns final cart and order identifiers.

#### Order Webhooks

Merchant publishes order lifecycle events to ChatGPT's webhook:
- `order.created` — Order confirmed
- `order.updated` — Status change (shipped, delivered, etc.)
- `order.cancelled` — Order cancelled

### 6.3 Payment Flow: Stripe Shared Payment Tokens (SPT)

The key innovation in Commerce ACP is **delegated payment** via Stripe's Shared Payment Token:

```
1. Customer expresses intent to pay in ChatGPT
2. ChatGPT provisions an SPT (set to amount + seller) via Stripe
3. SPT shared with merchant in CompleteCheckoutRequest
4. Merchant creates a Stripe PaymentIntent using the SPT
5. Merchant confirms payment via their existing Stripe integration
6. Settlement flows through normal Stripe rails
```

SPTs ensure:
- **PCI compliance**: Payment credentials never pass through the AI agent's application logic
- **Secure tokenization**: Only the authorized merchant can charge the token
- **Amount binding**: Token is bound to a specific amount and seller
- **No credential exposure**: Underlying card numbers never visible to the agent

### 6.4 Integration Modes

Commerce ACP supports two integration patterns:

| Mode | Description | Best For |
|------|-------------|----------|
| **REST API** | Standard HTTP endpoints at `/checkout_sessions` | Direct integration, custom backends |
| **MCP Server** | Expose checkout as MCP tools | LLM-native integration, tool-use patterns |

MCP server mode publishes checkout configuration as MCP tools, enabling any MCP-compatible agent to discover and initiate checkout flows.

### 6.5 Request Security

- **Bearer Token**: All requests require `Authorization: Bearer <token>`
- **Request Signing**: Client SHOULD sign requests (`Signature` header) over canonical JSON with accompanying `Timestamp` (RFC 3339)
- **Idempotency Keys**: Safe retries via `Idempotency-Key` header
- **API Versioning**: Explicit `API-Version` header prevents silent breaking changes

### 6.6 Error Handling

Structured error responses:

```json
{
  "type": "invalid_request",
  "code": "missing_field",
  "message": "Missing required field: items",
  "param": "$.items"
}
```

Error types: `invalid_request`, `rate_limited`, `internal_error`, `not_found`

---

## 7. Ecosystem and Adoption

### 7.1 Scale (February 2026)

| Metric | Value |
|--------|-------|
| ChatGPT weekly active users | 800-900 million |
| Shopping-related queries/day | ~50 million (estimated) |
| Fee model | 4% OpenAI fee + standard Stripe processing |

### 7.2 Live and Announced Merchants

| Merchant | Status | Platform |
|----------|--------|----------|
| **Etsy** | Live at launch (Feb 16, 2026) | Direct integration |
| **Shopify** | Coming soon (1M+ merchants) | Platform integration |
| **PayPal** | Announced (ACP server) | Payment provider integration |
| **Instacart** | Announced | Direct integration |
| **DoorDash** | Announced | Direct integration |
| **Target** | Announced | Direct integration |
| **Glossier, SKIMS, Spanx, Vuori** | Coming soon (via Shopify) | Platform integration |

### 7.3 Onboarding Paths

1. **Stripe merchants**: Enable ACP via Stripe dashboard → immediate access
2. **Shopify merchants**: Platform integration → coming soon, 1M+ stores
3. **PayPal merchants**: PayPal ACP server → tens of millions of small businesses
4. **Custom integration**: Implement ACP REST endpoints directly

### 7.4 Discovery

Commerce ACP currently lacks a standardized discovery mechanism:
> "We're working to create discovery mechanisms for AI platforms to identify businesses that have implemented ACP."

AI platforms interested in adopting ACP contact `acp@stripe.com`. This is a significant gap compared to A2A's Agent Card discovery or UCP's registry integration.

---

## 8. Commerce ACP vs. UCP: Detailed Comparison

| Dimension | Commerce ACP (OpenAI/Stripe) | UCP (Google/Shopify) |
|-----------|------------------------------|---------------------|
| **Primary Agent Surface** | ChatGPT (800M+ WAU) | Google Search, Gemini, AI Mode |
| **Primary Integration** | Stripe dashboard, Shopify (coming) | Shopify native, Google Merchant Center |
| **Architecture** | 5-endpoint REST API (minimal) | Layered capabilities + extensions (complex) |
| **Payment Rail** | Stripe Shared Payment Tokens | AP2 (multi-provider, DID-based) |
| **Fee Model** | 4% OpenAI + Stripe fees | Open standard (no protocol fee) |
| **Discovery Model** | Chat-to-buy (conversational) | Search-to-buy (SEO-like) |
| **Checkout Scope** | Focused on checkout session lifecycle | Full lifecycle (discovery → post-purchase) |
| **Commerce Types** | Physical, digital, subscriptions, async | Full lifecycle + custom extensions |
| **Identity** | Stripe merchant ID + Bearer tokens | AP2 DIDs + Verifiable Credentials |
| **MCP Integration** | ACP tools as MCP server | MCP as one integration path |
| **License** | Apache 2.0 | Open standard |
| **Governance** | Stripe/OpenAI-controlled | Google/Shopify-controlled |
| **Status** | Live (Feb 16, 2026) | Published (Jan 2026) |
| **Backers** | OpenAI, Stripe, Visa, Etsy, PayPal | Google, Shopify, Etsy, Target, Walmart, Salesforce |

### 8.1 Strategic Recommendation

Merchants should implement **both** protocols:
- **Commerce ACP** captures chat-to-buy traffic via ChatGPT (800M+ users)
- **UCP** captures search-to-buy traffic via Google Search/Gemini
- Dual implementation reportedly captures **~40% more** agentic commerce traffic than either alone
- Amazon's crawler block creates a structural advantage for non-Amazon brands in both protocols

---

## 9. The Name Collision Problem

The "ACP" abbreviation collision creates real confusion in the industry. A guide for disambiguation:

| Context | Which ACP? |
|---------|-----------|
| "ACP merged with A2A" | IBM's Agent Communication Protocol |
| "ACP-SDK" or "BeeAI ACP" | IBM's Agent Communication Protocol |
| "ACP checkout" or "Instant Checkout" | Commerce ACP (OpenAI/Stripe) |
| "ACP endpoints" or "/checkout_sessions" | Commerce ACP (OpenAI/Stripe) |
| "ACP vs UCP" | Commerce ACP (OpenAI/Stripe) |
| Academic papers before Aug 2025 | Usually IBM's ACP |
| Academic papers after Feb 2026 | Could be either — check context |
| "ACP security analysis" (arXiv) | IBM's ACP (the Nov 2025 paper) |
| agenticcommerce.dev | Commerce ACP (OpenAI/Stripe) |
| research.ibm.com/projects/agent-communication-protocol | IBM's ACP (redirects to A2A) |

---

## 10. Combined Strengths & Weaknesses

### IBM ACP (now merged into A2A)

| Strengths | Weaknesses |
|-----------|------------|
| Lightweight, minimal API surface | Smaller ecosystem than A2A at time of merger |
| Local-first (laptops, clusters, edge) | Optional JWS created security gaps |
| Framework-agnostic from day one | Now deprecated — no independent development |
| BeeAI interpretability focus | Short lifespan (6 months before merger) |
| LF governance from the start | Limited streaming compared to A2A SSE |
| MCP-compatible message types | Discovery less mature than A2A Agent Cards |

### Commerce ACP (OpenAI/Stripe)

| Strengths | Weaknesses |
|-----------|------------|
| Massive agent surface (ChatGPT 800M+ WAU) | 4% platform fee (vs. UCP open standard) |
| Simple API (5 endpoints) | Stripe-dependent (single PSP at launch) |
| Live and transacting (Feb 2026) | ChatGPT-centric (other agents TBD) |
| PCI-compliant payment tokenization | No standardized discovery mechanism |
| Apache 2.0 open source | Name collision with IBM ACP causes confusion |
| MCP server integration mode | Checkout-focused (no discovery/post-purchase) |
| Idempotency and request signing built-in | Limited to approved merchants initially |
| Webhook-based order lifecycle | No neutral governance body |

---

## 11. Future Directions

### IBM ACP Legacy
- ACP's technical contributions continue through A2A
- BeeAI platform remains available for agent interpretability research
- ACP security analysis findings (mandatory integrity guarantees) inform A2A's security evolution
- ProtocolBench/ProtocolRouter research suggests multi-protocol routing may emerge

### Commerce ACP
- **Additional AI platforms**: Beyond ChatGPT — any agent platform can implement ACP
- **Additional PSPs**: Beyond Stripe — PayPal ACP server announced, others expected
- **Discovery mechanisms**: Standardized merchant discovery for AI agents
- **International expansion**: Beyond U.S. (Feb 2026 launch is U.S.-only)
- **Post-purchase flows**: Returns, exchanges, support (currently out of scope)
- **Convergence with UCP**: Possible harmonization at the commerce layer, but competitive dynamics make this uncertain
- **WooCommerce, BigCommerce**: Platform integrations expanding beyond Shopify/Etsy

---

## 12. References

### IBM Agent Communication Protocol
- IBM Research: https://research.ibm.com/projects/agent-communication-protocol
- IBM Explainer: https://www.ibm.com/think/topics/agent-communication-protocol
- BeeAI Platform: https://github.com/i-am-bee/beeai
- ACP-A2A Merger Announcement: https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/
- ACP-A2A Unite Analysis: https://dotsquarelab.com/resources/acp-and-a2a-united
- WorkOS Technical Overview: https://workos.com/blog/ibm-agent-communication-protocol-acp
- ACP Security Analysis: arXiv:2511.03841 (November 2025)
- ProtocolBench: arXiv:2510.17149 (October 2025)

### Agentic Commerce Protocol (Commerce ACP)
- Official Website: https://www.agenticcommerce.dev/
- ACP Specification: https://www.agenticcommerce.dev/docs
- Stripe ACP Integration: https://docs.stripe.com/agentic-commerce/protocol
- ChatGPT Instant Checkout: https://openai.com/index/introducing-shopping-in-chatgpt/
- ChatGPT Merchant Application: https://chatgpt.com/merchants
- Retailer Guide: https://www.ekamoira.com/blog/chatgpt-instant-checkout-agentic-commerce-protocol-2026
- UCP vs ACP Comparison: https://wearepresta.com/ucp-vs-acp-the-complete-guide-to-agentic-commerce-protocols-in-2026
- Strategic Analysis: https://www.advancedwebranking.com/blog/ucp-acp-protocols-analysis
- AgentReady ACP Guide: https://agentreadyhq.com/blog/acp-agentic-commerce-protocol-openai-stripe
