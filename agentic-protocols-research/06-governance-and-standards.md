# 06 — Governance and Standards Bodies Comparison

## Executive Summary

The governance of agentic AI protocols is distributed across multiple organizations, each with different mandates, membership models, and authority. This document maps the governance landscape, identifying who controls what, how decisions are made, and where conflicts and overlaps exist.

The key finding is that **no single body governs the full agentic protocol stack**. Instead, governance is layered — mirroring the protocol stack itself — with different organizations controlling different layers. This creates both resilience (no single point of failure) and fragmentation (no single authority to resolve cross-layer conflicts).

---

## 1. Governance Bodies Overview

### 1.1 Agentic AI Foundation (AAIF) — Linux Foundation

**Established**: December 2025
**Host**: Linux Foundation
**Mandate**: Open, interoperable infrastructure for agentic AI

**Founding Projects**:
- **MCP** (Anthropic) — Agent-to-tool protocol
- **Goose** (Block) — Open-source agent framework
- **AGENTS.md** (OpenAI) — Repository-level agent guidance standard

**Platinum Members**: Amazon Web Services, Anthropic, Block, Bloomberg, Cloudflare, Google, Microsoft, OpenAI

**Governance Model**:
- Technical Steering Committee (TSC) for specification decisions
- Platinum member companies have board seats
- Open community participation for specification development
- Apache-style or similar open-source licensing
- Patent and IP protections via Linux Foundation umbrella

**What AAIF Controls**:
- MCP specification evolution
- AGENTS.md standard
- Goose framework development
- Potentially: cross-protocol interoperability standards

**What AAIF Does NOT Control**:
- A2A (separate LF project, Google-led)
- UCP/AP2 (Google/Shopify-led, not under AAIF)
- Identity standards (OpenID Foundation, W3C)
- Network-level protocols (IETF)

### 1.2 Linux Foundation AI & Data (LF AI & Data)

**Established**: 2018 (AI focus expanded over time)
**Mandate**: Support open-source AI projects and infrastructure

**Relevant Projects**:
- **A2A** (Google → LF) — Agent-to-agent protocol
- **ACP/BeeAI** (IBM → LF, now merged into A2A) — Agent communication
- **AGNTCY** — Multi-agent infrastructure framework

**Governance Model**:
- Project-level Technical Advisory Councils (TACs)
- Graduated project model (sandbox → incubating → graduated)
- Member-driven funding and priorities
- Open-source licensing required

**Relationship to AAIF**:
Both are under the Linux Foundation umbrella, but AAIF is a separate foundation with its own governance, membership, and budget. AAIF focuses specifically on agentic AI standards; LF AI & Data has a broader AI/ML scope.

### 1.3 Internet Engineering Task Force (IETF)

**Established**: 1986
**Mandate**: Internet protocol standardization

**Relevant Work**:
- **draft-rosenberg-aiproto-framework** (October 2025): "Framework, Use Cases and Requirements for AI Agent Protocols" — an internet-draft proposing IETF as the venue for standardizing AI agent communication
- Surveys MCP, A2A, and AGNTCY within the IETF framework model
- Proposes that agent protocols are fundamentally internet protocols and should be standardized accordingly

**Governance Model**:
- Rough consensus and running code
- Open participation (no membership fees)
- Working Groups formed around specific topics
- RFC publication process (Proposed Standard → Internet Standard)
- IANA registry management

**What IETF Could Control**:
- Wire format standardization (if agent protocols become RFCs)
- Transport-layer standards (HTTP, TLS, WebSocket are already IETF)
- DNS-based discovery standards
- HTTP Message Signatures (RFC 9421) — relevant to agent identity

**Current Status**: The Rosenberg/Jennings internet-draft is informational; no IETF Working Group for agent protocols has been chartered yet. This is a space to watch.

### 1.4 World Wide Web Consortium (W3C)

**Established**: 1994
**Mandate**: Web standards development

**Relevant Standards**:
- **Decentralized Identifiers (DIDs)**: W3C Recommendation (July 2022) — foundational for ANP and AP2 agent identity
- **Verifiable Credentials**: W3C Recommendation — used for agent attestations
- **Linked Data / Semantic Web**: Relevant to agent capability description

**Governance Model**:
- Member-driven (corporate membership fees)
- Working Groups with formal charters
- Recommendation track (First Public Working Draft → Candidate → Proposed → Recommendation)
- Patent policy (royalty-free licensing)

**What W3C Controls**:
- DID specification and DID method registry
- Verifiable Credentials standard
- Web-related standards used by agent protocols (HTTP, WebSocket, JSON-LD)

### 1.5 OpenID Foundation

**Established**: 2007
**Mandate**: Digital identity standards

**Relevant Work**:
- **Whitepaper on Agentic AI Identity** (October 2025): Comprehensive analysis of IAM challenges for AI agents
- **OpenID Connect**: Used by MCP and A2A for authentication
- **Proposed Agent-Specific Extensions**: Agent claims, delegation chains, dynamic scopes

**Governance Model**:
- Working Groups for specific standards
- Implementer's draft → Final specification
- Certification programs for implementations
- Board of Directors from member organizations

**What OpenID Foundation Controls**:
- OpenID Connect specification and extensions
- Agent-specific OIDC profile (if developed)
- Certification of identity implementations

### 1.6 Industry Consortia and Proprietary Standards

#### Google-Led Standards
- **A2A**: Originally Google, now Linux Foundation
- **UCP**: Google + Shopify, announced at NRF 2026
- **AP2**: Google + 60+ payment/tech companies

#### OpenAI-Led Standards
- **AGENTS.md**: Now under AAIF
- **Agentic Commerce Protocol (Commerce ACP)**: OpenAI + Stripe
- **ChatGPT Plugin/Action protocols**: Proprietary

#### Microsoft-Led Standards
- **Entra Agent ID**: Platform-scoped agent identity
- **Agent Lightning**: Agent orchestration framework
- **Copilot ecosystem**: Proprietary agent platform

#### 3GPP (Telecommunications)
- Emerging work on agent communication over mobile networks
- Relevant for edge-deployed agents and IoT agent scenarios

---

## 2. Governance Mapping to Protocol Stack

| Layer | Protocol(s) | Primary Governance | Secondary Governance |
|-------|------------|-------------------|---------------------|
| **L5: Commerce** | UCP, Commerce ACP, AP2 | Google/Shopify (UCP), OpenAI/Stripe (ACP) | None (not yet under neutral governance) |
| **L4: Agent-to-Agent** | A2A | Linux Foundation (LF AI & Data) | IETF (potential future) |
| **L3: Agent-to-Tool** | MCP | AAIF (Linux Foundation) | IETF (potential future) |
| **L2: Identity/Discovery** | DIDs, OIDC, Agent Cards, PAI | W3C (DIDs), OpenID Foundation (OIDC) | IETF (RFC 9421), Independent (PAI) |
| **L1: Infrastructure** | HTTP, TLS, SLIM, DNS | IETF | AGNTCY (LF, for SLIM) |

**Critical observation**: Layer 5 (Commerce) and Layer 2 (Identity) have **no neutral governance body**. Commerce protocols are controlled by their originating companies. Identity has multiple competing standards bodies with no coordination mechanism.

---

## 3. Conflict Points

### 3.1 AAIF vs. LF AI & Data

Both are Linux Foundation projects, but with different mandates:
- AAIF: Specifically agentic AI (MCP, AGENTS.md, Goose)
- LF AI & Data: Broader AI/ML (A2A, AGNTCY)

**Conflict**: Who defines the interoperability standard between MCP (AAIF) and A2A (LF AI & Data)? Both organizations are under the LF umbrella, but have separate governance structures and member priorities.

### 3.2 Google Multi-Protocol Leadership

Google is involved in:
- A2A (creator and primary contributor)
- UCP (co-developer with Shopify)
- AP2 (creator with payment industry)
- AAIF (platinum member)

**Conflict**: Google effectively controls or co-controls three of the five protocol stack layers. This raises questions about vendor neutrality, even with Linux Foundation governance for some layers.

### 3.3 Identity Standards Fragmentation

At least four organizations are working on agent identity:
- W3C (DIDs)
- OpenID Foundation (OIDC extensions)
- IETF (HTTP Signatures)
- Independent (PAI, OpenBotAuth)

**Conflict**: No coordination mechanism exists between these efforts. An agent may need different identity mechanisms for different protocol layers, with no bridging standard.

### 3.4 Commerce Protocol Competition

UCP (Google/Shopify) and Commerce ACP (OpenAI/Stripe) are competing standards at the same layer, with different governance models:
- UCP: Open standard, no per-transaction fees, Google-controlled
- Commerce ACP: Platform standard, 4% fee, OpenAI-controlled

**Conflict**: Neither is under neutral governance. Merchants must implement both. No convergence path is visible.

### 3.5 IETF Potential Disruption

The Rosenberg/Jennings internet-draft explicitly argues that agent protocols are internet protocols and should be IETF-standardized. If IETF charters a Working Group:
- It could produce competing standards to MCP and A2A
- Or it could endorse existing protocols as RFCs
- IETF's "rough consensus and running code" model may conflict with AAIF/LF governance

---

## 4. Open Questions

1. **Will AAIF and LF AI & Data merge their agent protocol governance?** Having MCP and A2A under different LF sub-organizations creates unnecessary coordination overhead.

2. **Will IETF standardize agent protocols?** The internet-draft is informational, but IETF engagement could either legitimize or fragment the existing landscape.

3. **Will commerce protocols converge?** UCP and Commerce ACP serve similar functions with different business models. Market pressure may force convergence, but competitive dynamics may prevent it.

4. **Who will govern agent identity?** This is the most important open question. The organization that defines the identity layer effectively controls the trust infrastructure for the entire agentic ecosystem.

5. **What role will regulators play?** EU AI Act, US executive orders, and Chinese AI regulations may impose identity and accountability requirements that override technical standard decisions.

---

## 5. Governance Maturity Assessment

| Body | Neutrality | Inclusivity | Specification Quality | Adoption Power | Overall |
|------|-----------|------------|---------------------|---------------|---------|
| **AAIF** | High (LF umbrella) | High (open membership) | Medium (early) | Very High (MCP ecosystem) | Strong |
| **LF AI & Data** | High | High | Medium | High (A2A ecosystem) | Strong |
| **IETF** | Very High | Very High (free participation) | Very High (RFC process) | Medium (depends on adoption) | Very Strong (if engaged) |
| **W3C** | High | Medium (member fees) | Very High | Medium (DIDs adoption mixed) | Strong |
| **OpenID Foundation** | High | Medium | High | High (OIDC is universal) | Strong |
| **Google (UCP/AP2)** | Low (company-controlled) | Medium (open standard) | Medium | Very High (Google surfaces) | Mixed |
| **OpenAI (Commerce ACP)** | Low (company-controlled) | Low (Stripe-gated) | Medium | Very High (ChatGPT users) | Mixed |

---

## 6. Recommendations

1. **Unify LF agent governance**: Merge AAIF and LF AI & Data agent protocol projects under a single governance structure
2. **Engage IETF early**: Proactively bring MCP and A2A to IETF for review before they charter competing work
3. **Establish identity coordination**: Create a cross-body working group (W3C + OpenID + IETF + AAIF) for agent identity
4. **Demand commerce neutrality**: Push UCP and Commerce ACP toward neutral governance (LF or similar)
5. **Monitor regulatory impact**: EU and US regulatory requirements will likely force identity standardization faster than market dynamics

---

## 7. References

- AAIF Announcement: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation
- IETF Agent Protocol Framework: https://datatracker.ietf.org/doc/html/draft-rosenberg-aiproto-framework
- AAIF Guide (IntuitionLabs): https://intuitionlabs.ai/pdfs/agentic-ai-foundation-guide-to-open-standards-for-ai-agents.pdf
- Lawfare AI Governance Analysis: https://www.lawfaremedia.org/article/understanding-global-ai-governance-through-a-three-layer-framework
- W3C DID Specification: https://www.w3.org/TR/did-core/
- OpenID Foundation Agent Identity Whitepaper: arXiv:2510.25819
- AGNTCY/SLIM: https://github.com/agntcy/agp
