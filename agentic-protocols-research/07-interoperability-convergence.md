# 07 — Interoperability and Convergence Analysis

## Executive Summary

The agentic protocol ecosystem is **layered and complementary, not competing**. This is the central insight that resolves the apparent confusion of overlapping protocols. When mapped to a five-layer stack — Infrastructure, Identity/Discovery, Agent-to-Tool, Agent-to-Agent, and Commerce — each major protocol occupies a distinct layer, with well-defined interfaces between them.

This document presents the layered stack model, maps all protocols to their layers, analyzes where true competition exists versus complementary specialization, and assesses convergence trajectories.

---

## 1. The Five-Layer Agentic Protocol Stack

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 5: COMMERCE                                          │
│  UCP (Google/Shopify) | Commerce ACP (OpenAI/Stripe) | AP2  │
│  Agentic shopping, checkout, payments, post-purchase        │
├─────────────────────────────────────────────────────────────┤
│  Layer 4: AGENT-TO-AGENT                                    │
│  A2A (Google → LF) | [ACP merged into A2A]                 │
│  Agent discovery, task delegation, multi-agent coordination │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: AGENT-TO-TOOL                                     │
│  MCP (Anthropic → AAIF)                                     │
│  Tool invocation, resource access, context provision        │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: IDENTITY / DISCOVERY                              │
│  DIDs (W3C) | OIDC (OpenID) | Agent Cards (A2A)            │
│  PAI (keypair) | Platform IDs | ANP identity layer          │
│  Authentication, authorization, agent discovery             │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: INFRASTRUCTURE                                    │
│  HTTP/TLS (IETF) | SLIM (AGNTCY) | DNS | WebSocket         │
│  Transport, encryption, routing, message delivery           │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Key Insight: Layers, Not Competitors

| Common Misconception | Reality |
|---------------------|---------|
| "MCP vs. A2A" | MCP (tools) and A2A (agents) are complementary layers |
| "ACP vs. A2A" | ACP merged into A2A — the competition is resolved |
| "UCP vs. Commerce ACP" | This IS genuine competition at the commerce layer |
| "ANP vs. everything" | ANP spans layers 1-2 (infrastructure + identity) below the others |
| "Protocols are fragmenting" | Protocols are specializing into a coherent stack |

---

## 2. Protocol-to-Layer Mapping

### 2.1 Layer 1: Infrastructure

| Protocol/Standard | Role | Status |
|------------------|------|--------|
| **HTTP/2, HTTP/3** | Transport for all agent protocols | Mature (IETF) |
| **TLS 1.3** | Transport encryption | Mature (IETF) |
| **SLIM** (AGNTCY) | Secure low-latency messaging for agent protocols | v1.1 (LF) |
| **DNS** | Service discovery (well-known URLs) | Mature (IETF) |
| **WebSocket** | Streaming/bidirectional communication | Mature (IETF) |
| **SSE** | Server-Sent Events for streaming | Mature |

**Analysis**: This layer is mature and non-controversial. All agent protocols build on established IETF standards. SLIM is the notable addition — a purpose-built data plane for agent traffic that provides MLS encryption and reliable delivery.

### 2.2 Layer 2: Identity and Discovery

| Protocol/Standard | Role | Status |
|------------------|------|--------|
| **W3C DIDs** | Decentralized agent identity | Recommendation (W3C) |
| **OpenID Connect** | Centralized authentication | Mature (OpenID Foundation) |
| **Agent Cards** | Self-declared agent metadata | v0.2.1 (A2A) |
| **ANP Identity Layer** | DID:WBA + end-to-end encryption | Research/Early |
| **PAI** | Keypair-based portable identity | Proposal |
| **Platform IDs** | Vendor-scoped agent identity | Proprietary |

**Analysis**: This is the **most fragmented and contested** layer. Six different approaches compete with no convergence mechanism. See the dedicated identity document (05) for detailed analysis.

### 2.3 Layer 3: Agent-to-Tool

| Protocol | Role | Status |
|----------|------|--------|
| **MCP** | Universal agent-to-tool connectivity | Production (AAIF) |

**Analysis**: MCP has **effectively won** this layer. With 79K+ stars on the servers repo, adoption by every major AI company, and AAIF governance, there is no meaningful competition. The remaining question is how MCP handles authentication and authorization at scale.

### 2.4 Layer 4: Agent-to-Agent

| Protocol | Role | Status |
|----------|------|--------|
| **A2A** | Agent discovery, task delegation, coordination | v0.2.1 (LF) |
| **ANP** (application layer) | Agent capability description and interaction | Research/Early |

**Analysis**: A2A has **consolidating momentum** at this layer following the ACP merger. ANP's application layer (Agent Description Protocol, Agent Discovery Protocol) overlaps but approaches from a different direction — semantic web / linked data vs. RESTful JSON. A2A is likely to dominate enterprise use cases; ANP may find a niche in decentralized/open-web scenarios.

### 2.5 Layer 5: Commerce

| Protocol | Role | Status |
|----------|------|--------|
| **UCP** | Full-lifecycle agentic commerce (Google/Shopify) | Published (Jan 2026) |
| **Commerce ACP** | Chat-to-buy via ChatGPT (OpenAI/Stripe) | Live (Feb 2026) |
| **AP2** | Agent payment transactions | Published (Sep 2025) |

**Analysis**: This is the layer with the **most active competition**. UCP and Commerce ACP serve similar functions but with different business models, agent surfaces, and payment rails. Both are backed by companies with enormous distribution. No convergence is expected in the near term.

---

## 3. Cross-Layer Integration Patterns

### 3.1 MCP + A2A (Tool Use + Agent Collaboration)

The most common integration pattern:

```
User → Agent A (via A2A) → Agent B (via A2A) → Tool (via MCP) → Database
```

- Agent A discovers Agent B via A2A Agent Card
- Agent A delegates a sub-task to Agent B via A2A Task
- Agent B uses MCP to invoke a tool (e.g., database query)
- Results flow back through the chain

### 3.2 UCP + A2A + MCP (Commerce)

Full-stack commerce flow:

```
User → Shopping Agent (A2A) → Merchant Agent (A2A) → Catalog API (MCP) → Checkout (UCP) → Payment (AP2)
```

- Shopping agent discovers merchant agent via A2A
- Merchant agent uses MCP to access inventory system
- Checkout session managed via UCP capabilities
- Payment processed via AP2 with DID-based identity

### 3.3 ANP + A2A (Decentralized Discovery + Collaboration)

Potential future integration:

```
Agent A (ANP identity) → Meta-protocol negotiation → A2A communication → Task completion
```

- ANP provides DID-based identity and encrypted communication
- Meta-protocol layer negotiates which application protocol to use
- A2A used as the application protocol for task management
- This pattern bridges decentralized identity with practical agent collaboration

---

## 4. Convergence Analysis

### 4.1 Where Convergence Has Happened

| Event | Protocols | Outcome |
|-------|-----------|---------|
| ACP-A2A merger (Sep 2025) | ACP + A2A | A2A is the standard for L4 |
| AAIF formation (Dec 2025) | MCP + AGENTS.md + Goose | MCP is the standard for L3 |

### 4.2 Where Convergence Is Likely

| Layer | Current State | Expected Convergence |
|-------|--------------|---------------------|
| **L4 (Agent-Agent)** | A2A dominant, ANP niche | A2A wins enterprise; ANP survives for decentralized |
| **L1 (Infrastructure)** | IETF standards + SLIM | SLIM becomes standard agent transport |

### 4.3 Where Convergence Is Unlikely (Near-Term)

| Layer | Current State | Why Convergence Is Hard |
|-------|--------------|------------------------|
| **L5 (Commerce)** | UCP vs Commerce ACP | Different business models (open vs. 4% fee); different surfaces (Google vs. ChatGPT) |
| **L2 (Identity)** | 6+ approaches | Different trust models; different governance bodies; regulatory fragmentation |

### 4.4 Convergence Timeline Estimates

| Milestone | Estimated Timeline |
|-----------|-------------------|
| MCP 1.0 specification | Mid-2026 |
| A2A 1.0 specification | Late 2026 |
| IETF agent protocol Working Group charter | 2026-2027 |
| Identity bridging standard (cross-layer) | 2027-2028 |
| Commerce protocol convergence | 2028+ (if ever) |
| Full-stack interoperability standard | 2028-2030 |

---

## 5. The ANP Wildcard

The Agent Network Protocol (ANP) deserves special attention as a potential disruptor:

### 5.1 What ANP Does Differently

- **Three-layer architecture**: Identity + Meta-Protocol + Application
- **DID-native**: Identity is a first-class protocol concern, not an afterthought
- **Meta-protocol negotiation**: Agents dynamically negotiate which application protocol to use
- **AI-native design**: Built for agent-to-agent communication, not adapted from human-facing web protocols
- **Semantic web heritage**: Agent capabilities described using structured, machine-readable formats

### 5.2 Why ANP Matters

If ANP's meta-protocol negotiation layer gains traction, it could become the **bridge** between competing application-layer protocols. An agent using ANP could negotiate whether to use A2A, UCP, or Commerce ACP based on context — resolving the L4/L5 competition at a lower layer.

### 5.3 Why ANP May Not Win

- Smaller community than MCP/A2A
- No major corporate backer (compared to Google, Anthropic, OpenAI)
- Semantic web approaches have historically struggled with adoption
- DID infrastructure is still immature

---

## 6. Interoperability Gaps

| Gap | Description | Impact |
|-----|-------------|--------|
| **L2-L3 bridge** | No standard way to propagate identity from discovery to tool use | MCP servers can't verify who's calling them |
| **L3-L4 bridge** | No standard handoff between MCP tool results and A2A task updates | Agents must implement custom glue code |
| **L4-L5 bridge** | No standard way to transition from agent collaboration to commerce | Commerce flow initiation is ad hoc |
| **Cross-L2 identity** | No way to verify the same agent across different identity systems | Agent identity is siloed per protocol |
| **Multi-protocol agents** | No standard for agents that speak multiple protocols | Each agent must implement each protocol independently |

---

## 7. Recommendations

1. **Adopt the layered model**: When evaluating protocols, map to the five-layer stack — don't treat them as competitors when they're at different layers
2. **Invest in L2 (Identity)**: This is the bottleneck; progress here unblocks everything else
3. **Build bridge adapters**: Focus on L3-L4 (MCP-A2A) integration patterns — this is where most immediate value lies
4. **Watch ANP**: Its meta-protocol layer could resolve application-layer fragmentation
5. **Implement both commerce protocols**: For merchants, UCP + Commerce ACP dual implementation is the pragmatic choice until convergence occurs

---

## 8. References

- A2A Specification: https://google-a2a.github.io/A2A/specification/
- MCP Specification: https://modelcontextprotocol.io/specification/2025-11-25
- UCP Engineering (Shopify): https://shopify.engineering/ucp
- ANP White Paper: https://agent-network-protocol.com/specs/white-paper
- AGNTCY/SLIM: https://github.com/agntcy/agp
- IETF Agent Framework: https://datatracker.ietf.org/doc/html/draft-rosenberg-aiproto-framework
- Agentic AI Protocols Comparison: https://k21academy.com/agentic-ai/agentic-ai-protocols-comparison/
- Pipe17 Protocol Guide: https://pipe17.com/blog/agentic-commerce-protocols/
