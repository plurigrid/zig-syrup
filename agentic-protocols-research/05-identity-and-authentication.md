# 05 — Identity and Authentication in Agentic Protocols

## Executive Summary

Identity is the **most contested and least solved** layer of the agentic protocol stack. While MCP, A2A, and UCP have achieved broad consensus at their respective layers, no single identity standard has emerged for AI agents. At least six distinct approaches are being pursued, each with different trust models, threat surfaces, and governance implications.

This document compares the identity and authentication mechanisms across all major agentic protocols, surveys the emerging standards landscape, and analyzes why convergence has proven so difficult.

---

## 1. Why Identity Is the Critical Unsolved Problem

### 1.1 The Human-Agent Assumption Gap

Traditional IAM (Identity and Access Management) systems — OAuth 2.0, OpenID Connect (OIDC), SAML — were designed for a world where:
- A **human** is clicking "authorize" on a trusted surface
- Sessions are **interactive** (human present to re-authenticate)
- Credentials are **long-lived** (tokens last hours or days)
- Delegation is **static** (scopes are fixed at authorization time)

AI agents break all of these assumptions:
- Agents act **autonomously** without a human clicking "authorize" each time
- Agent sessions may be **ephemeral** (spun up for a single task, then destroyed)
- Agents need **fine-grained, dynamic** permissions that change per-task
- Delegation chains can be **multi-hop** (user → agent → sub-agent → tool → API)
- Agents may **impersonate** or **fabricate** identity without cryptographic safeguards

### 1.2 Attack Surface

Without proper identity:
- **Sybil attacks**: One entity creates thousands of fake agents to manipulate markets (see Project OMEGA against OpenClaw/Moltbook)
- **Prompt injection**: Malicious content hijacks an agent's identity and authority
- **Replay attacks**: Agent credentials reused by unauthorized parties
- **Delegation abuse**: Agents exceeding their authorized scope
- **Reputation laundering**: Fake agents building artificial trust scores
- **Wash trading**: Agents transacting with themselves to inflate metrics

---

## 2. Six Identity Approaches

### 2.1 OAuth 2.0 / OIDC Extension (Industry Default)

**Approach**: Extend existing OAuth 2.0 and OpenID Connect flows with agent-specific claims and scopes.

**Proponents**: OpenID Foundation, Microsoft Entra, major cloud providers

**Mechanism**:
- Agents authenticate via OAuth 2.0 client credentials flow
- Agent-specific claims added to JWT tokens (agent type, capabilities, delegation chain)
- Existing OIDC discovery mechanisms used for agent discovery
- Human authorization via standard consent flows

**Strengths**:
- Builds on widely deployed infrastructure
- Well-understood security model
- Existing tooling and libraries

**Weaknesses**:
- Designed for human-interactive flows; awkward for autonomous agents
- Coarse-grained scopes don't capture dynamic agent permissions
- No native support for agent-to-agent delegation chains
- Centralized identity providers create single points of failure

**Key Reference**: OpenID Foundation whitepaper on "Identity Management for Agentic AI" (arXiv:2510.25819)

### 2.2 Decentralized Identifiers (DIDs)

**Approach**: Use W3C Decentralized Identifiers for self-sovereign agent identity with no central authority.

**Proponents**: ANP (Agent Network Protocol), AP2, W3C, various Web3 communities

**Mechanism**:
- Each agent creates a DID (e.g., `did:web:agent.example.com`, `did:wba:...`)
- DID Documents contain public keys, service endpoints, and capabilities
- Verifiable Credentials (VCs) attest to agent properties (who built it, what it can do)
- End-to-end encrypted communication using DID-derived keys

**Strengths**:
- No central authority required
- Self-sovereign — agents control their own identity
- Cryptographically verifiable
- Supports offline verification

**Weaknesses**:
- Many competing DID methods (did:web, did:wba, did:key, did:ion, etc.)
- Revocation is hard in decentralized systems
- No established trust anchors — who decides which DIDs to trust?
- Complexity barrier for mainstream adoption
- DID infrastructure still immature

**Key Reference**: ANP uses `did:wba` (Web-Based Agent) method; AP2 uses DIDs for agent identity

### 2.3 Agent Cards (Self-Declared Claims)

**Approach**: Agents publish JSON metadata documents declaring their identity and capabilities.

**Proponents**: A2A (Google)

**Mechanism**:
- Agent Card served at `/.well-known/agent.json`
- Contains name, description, provider, capabilities, skills, auth requirements
- Discovery via DNS (well-known URLs) or registries
- Authentication delegated to standard HTTP mechanisms (OAuth, API keys)

**Strengths**:
- Simple, web-native — just a JSON file
- Easy to implement and discover
- No complex cryptographic infrastructure
- Works with existing web standards

**Weaknesses**:
- **Self-declared, not verified**: Any agent can claim any identity
- No cryptographic proof of claims
- DNS-based discovery requires domain ownership
- Vulnerable to impersonation and spoofing
- Trust is binary (you trust the domain or you don't)

**Key Reference**: A2A Specification, Key Concepts

### 2.4 Portable Agent Identity (PAI) / Keypair-Based

**Approach**: Ed25519 keypair with HTTP Message Signatures (RFC 9421) for portable, cryptographic agent identity.

**Proponents**: OpenBotAuth, independent researchers, Web Bot Auth community

**Mechanism**:
- Agent generates an Ed25519 keypair
- Public key published via JWKS endpoint at well-known URL
- All HTTP requests signed using RFC 9421 (HTTP Message Signatures)
- Optional trust anchors (e.g., GitHub OAuth) bind keys to accountable controllers
- Nonce-based replay protection

**Strengths**:
- Portable across platforms (not tied to one OAuth provider)
- Offline provenance (signatures can be verified without contacting issuer)
- Compatible with software supply-chain signing
- RFC-based (builds on established IETF standards)

**Weaknesses**:
- No established directory or discovery mechanism
- Trust anchor binding is optional — keys alone don't establish trust
- Early stage — limited adoption
- Key rotation and revocation not fully specified

**Key Reference**: "Portable Agent Identity" implementer's profile (hammadtariq.com)

### 2.5 Platform-Scoped Identity

**Approach**: AI platforms assign and manage agent identities within their ecosystem.

**Proponents**: Microsoft (Entra Agent ID), Google (AI Mode), OpenAI (ChatGPT agents)

**Mechanism**:
- Platform assigns unique IDs to agents within its ecosystem
- Platform manages authentication, authorization, and audit
- Cross-platform identity via platform-to-platform federation (if supported)
- Human accountability via platform account linking

**Strengths**:
- Simple for developers within one ecosystem
- Strong accountability (platform controls agent creation)
- Good audit trail
- Existing enterprise IAM integrations

**Weaknesses**:
- **Vendor lock-in**: Identity doesn't port across platforms
- **Siloed**: No interoperability between platforms
- **Centralized control**: Platform is single point of failure and authority
- **Not self-sovereign**: Agents don't own their identity

### 2.6 Cryptographic Trust Models (Proof + Stake)

**Approach**: Multi-layered trust using cryptographic proofs, staked collateral, and reputation.

**Proponents**: Academic researchers, Web3/crypto communities, ERC-8004

**Mechanism**:
- **Proof**: Zero-knowledge proofs, TEE attestations for verifiable claims
- **Stake**: Bonded collateral with slashing for misbehavior
- **Reputation**: Graph-based trust signals from past interactions
- **Constraint**: Sandboxing and capability bounding

**Strengths**:
- Strongest trust guarantees (cryptographic + economic)
- Trustless by default — no need to trust any party
- Resistant to Sybil attacks (staking makes fake identities expensive)
- Composable — different mechanisms for different trust levels

**Weaknesses**:
- **Extremely complex** to implement and operate
- **High barrier** for mainstream adoption
- **Requires economic infrastructure** (staking, slashing)
- **Latency** from proof generation and verification
- **Unproven** at scale for AI agent use cases

**Key Reference**: "Inter-Agent Trust Models" (arXiv:2511.03434)

---

## 3. Protocol-by-Protocol Identity Comparison

| Protocol | Identity Mechanism | Verification | Delegation | Decentralized | Maturity |
|----------|-------------------|-------------|------------|---------------|----------|
| **MCP** | Delegated (transport-layer) | None (implementation-specific) | None | No | Production |
| **A2A** | Agent Cards (self-declared) | DNS ownership only | None | No | v0.2.1 |
| **UCP** | Via AP2 (DID-based) | DID verification | Via AP2 mandates | Partial | Early |
| **AP2** | DIDs + Verifiable Credentials | Cryptographic | Payment mandates | Yes | Early |
| **ANP** | DID:WBA + end-to-end encryption | Cryptographic | Via meta-protocol | Yes | Research |
| **Commerce ACP** | Stripe merchant identity | Platform-verified | Via Stripe | No | Live |
| **AGNTCY/SLIM** | MLS group encryption | Cryptographic | Group membership | Partial | v1.1 |

---

## 4. The Convergence Problem

### 4.1 Why No Standard Has Emerged

1. **Different threat models**: Commerce needs payment-grade identity; tool use needs lighter verification
2. **Different trust anchors**: Enterprises trust OAuth providers; decentralized systems trust cryptography; commerce trusts payment processors
3. **Chicken-and-egg**: Identity infrastructure needs adoption to be useful; adoption needs identity infrastructure to be secure
4. **Regulatory fragmentation**: EU, US, China have different identity and data sovereignty requirements
5. **Velocity vs. security**: Lightweight identity (Agent Cards) enables fast adoption; heavyweight identity (DIDs + staking) provides security but slows adoption
6. **Governance disagreement**: Who controls the identity layer controls the ecosystem

### 4.2 Most Likely Path Forward

The research suggests a **layered identity model** will emerge:

```
Layer 5 (Commerce):     AP2 DIDs + Stripe/Payment identity
Layer 4 (Agent-Agent):  Agent Cards + optional DID verification
Layer 3 (Agent-Tool):   OAuth 2.0 / API keys (existing infrastructure)
Layer 2 (Discovery):    DNS + DID:web for service endpoints
Layer 1 (Transport):    TLS + optional MLS for group encryption
```

Different layers will use different identity mechanisms appropriate to their trust requirements. The critical missing piece is a **bridging standard** that connects these layers — so an agent's identity at the tool layer can be verified at the commerce layer.

---

## 5. OpenClaw and the Identity-Free Cautionary Tale

The OpenClaw/Moltbook ecosystem (770,000+ active agents, 1.5M human observers as of January 2026) demonstrated the catastrophic failure mode of identity-free architectures:

- **Project OMEGA**: Deterministic Python scripts using `random.choice()` and proxy rotation achieved complete domain dominance over agent-based marketplaces
- **Attack vectors**: Sybil attacks, reputation laundering, wash trading, cognitive injection
- **Root cause**: API interaction was assumed to imply intelligent agency; no cryptographic identity verification
- **Lesson**: "Security by obscurity" (assuming API consumers are legitimate agents) fails completely

This is the strongest empirical evidence that **cryptographic identity is not optional** for agentic systems operating at scale.

---

## 6. Recommendations

1. **Short-term (2026)**: Use OAuth 2.0 / OIDC for tool-level identity; Agent Cards for agent discovery; AP2 DIDs for commerce
2. **Medium-term (2026-2027)**: Adopt Portable Agent Identity (PAI) / keypair-based identity as a cross-protocol standard
3. **Long-term (2027+)**: Converge on a DID method with established trust anchors and revocation infrastructure
4. **Avoid**: Identity-free architectures, bearer-token-only systems, platform-scoped identity as the sole mechanism

---

## 7. References

- OpenID Foundation Whitepaper: arXiv:2510.25819
- Inter-Agent Trust Models: arXiv:2511.03434v1
- ANP DID:WBA Specification: https://agent-network-protocol.com/specs/white-paper
- AP2 Core Specification: https://ap2lab.com/en/specification/core/
- Portable Agent Identity: http://hammadtariq.com/protocol-notes/portable-agent-identity-implementers-profile/
- Zero-Trust Agent IAM: arXiv:2505.19301
- Project OMEGA (OpenClaw vulnerability): https://medium.com/@maordayanofficial/the-trust-void-identity-nullification-in-the-openclaw-agent-ecosystem
- A2A Agent Cards: https://google.github.io/A2A/topics/key-concepts/
