# Research: Anoma, Tweag, and Glaive AI

## 1. Anoma Research (anoma.net)

### Overview
Anoma is a **distributed operating system for intent-centric applications**. Unlike traditional blockchains that process explicit transactions, Anoma lets users express **intents** (desired outcomes), and a decentralized solver network handles execution. First devnet launched **January 2025**. Mainnet anticipated with XAN token.

**Website:** https://anoma.net  
**GitHub:** https://github.com/anoma (verified org, 1.8k+ followers)

### Architecture (3 Layers)
1. **Desktop** — User interface for intent creation (wallets, dApps, GUIs)
2. **Intentnet** — P2P network that propagates and negotiates intents
3. **Motherboard** — Distributed infrastructure for solving, ordering, executing

### Key Components

| Component | Description | Repo |
|-----------|-------------|------|
| **Typhon** | Consensus protocol — stores, orders, executes transactions on Anoma blockchains. Chimera Chains for cross-chain atomic txs. | [anoma/typhon](https://github.com/anoma/typhon) |
| **Taiga** | Shielded execution framework — generalized shielded state transitions using recursive ZK proofs. Hides app type, data, parties. WIP/Rust. | [anoma/taiga](https://github.com/anoma/taiga) ★148 |
| **Juvix** | Functional language for intent-centric decentralized applications. Compiles to Anoma. Haskell-implemented. Latest v0.6.10. | [anoma/juvix](https://github.com/anoma/juvix) ★504 |
| **Resource Machine** | Core state model — resources (notes) are created/consumed via intents. Specs at specs.anoma.net. | [anoma specs](https://specs.anoma.net) |

### Key Innovations
- **Intent-centric model**: Users declare *what* they want, not *how*. Solvers compete to fulfill intents.
- **Solver markets**: Execution as competitive marketplace — solvers route liquidity, MEV-protect, bundle across domains.
- **Cross-chain coordination**: Native multi-chain outcomes without manual routing.
- **ZK-privacy at base layer**: Matching/execution can be private by default (Taiga).
- **Fractal scaling**: Localized environments dynamically expand based on user activity.

### Namada Relationship
- **Namada** is a live Anoma instance focused on privacy (MASP - Multi-Asset Shielded Pool).
- **NAM token** is live on Namada chain — staking, privacy rewards, governance.
- **XAN token** (ticker unconfirmed) will power the upcoming Anoma mainnet — staking, governance, solver incentives.
- Namada repo: [namada-net/namada](https://github.com/anoma/namada)

### Research & Publications
- Anoma has an active research arm at anoma.net/research
- Key papers on Chimera Chains, intent semantics, resource machine formalization
- Specs fully written in Juvix at specs.anoma.net

---

## 2. Tweag (by Modus Create)

### Overview
Tweag is a **software engineering consultancy** (now part of **Modus Create**) specializing in functional programming, build systems, and blockchain infrastructure. Strong focus on Haskell, Nix, and formal methods.

**Website:** https://tweag.io  
**GitHub:** https://github.com/tweag  
**Parent:** Modus Create (global consultancy, partners with Atlassian, AWS, GitHub)

### Technical Groups
- Functional Engineering
- Scalable Builds
- Data Engineering
- Frontend Architecture & Infrastructure
- Generative AI
- High Assurance Software
- Nix (group)
- Programming Languages and Compilers
- Quality Engineering Test Automation

### Key Open-Source Projects

#### Nix Ecosystem
| Repo | Stars | Description |
|------|-------|-------------|
| [tweag/nickel](https://github.com/tweag/nickel) | ★2.6k | **Nickel** — configuration language with gradual type system. Alternative to Nix language. Also at [nickel-lang/nickel](https://github.com/nickel-lang/nickel) ★2.8k |
| [tweag/rules_nixpkgs](https://github.com/tweag/rules_nixpkgs) | ★274 | Rules for importing Nixpkgs packages into Bazel |
| [tweag/buck2.nix](https://github.com/tweag/buck2.nix) | ★32 | Buck2 rules for Nix |

#### Haskell Ecosystem
| Repo | Stars | Description |
|------|-------|-------------|
| [tweag/monad-bayes](https://github.com/tweag/monad-bayes) | ★442 | **Probabilistic programming** library in Haskell. MCMC, SMC, PMMH. First-class library (not embedded DSL). |
| [tweag/linear-base](https://github.com/tweag/linear-base) | ★332 | **Standard library for linear types** in Haskell (GHC LinearTypes extension) |
| [tweag/HaskellR](https://github.com/tweag/HaskellR) | ★579 | Full power of R in Haskell (FFI bridge) |

#### Bazel Ecosystem
| Repo | Stars | Description |
|------|-------|-------------|
| tweag/rules_haskell | — | Haskell rules for Bazel build system |
| tweag/rules_nixpkgs | ★274 | Nix integration for Bazel |

### Cardano / IOG Relationship
- **Major Cardano infrastructure contractor** — leads work on consensus, ledger, protocol design, security audits.
- **Ouroboros Peras**: Extension to Ouroboros consensus for faster settlement under optimistic conditions.
- **2025 Intersect Proposals**: Submitted $7.3M (11M ADA) budget proposals for:
  - Peras implementation
  - Supporting multiple node implementations
  - Improving development experience
  - Scaling L1 engine
  - Maintaining network integrity
- **Formal verification**: Led mechanized Agda specification of Cardano blockchain ledger.
- Blog tag: https://www.tweag.io/blog/tags/cardano/

### Key Research Contributions
- **Linear types for Haskell** (GHC extension) — paper submitted to ICFP'17 with Simon Peyton Jones
- **Monad-bayes** probabilistic programming — ongoing fellowship-funded improvements
- **Nickel** — gradual typing for configuration languages
- **Nix ecosystem** — major contributor to Nix tooling and build system integration

---

## 3. Glaive AI

### Overview
Glaive is a **synthetic data generation platform** for fine-tuning language models. Their mission: democratize and commoditize AI by enabling anyone to build and own custom models.

**Website:** https://glaive.ai  
**Docs:** https://docs.glaive.ai  
**HuggingFace:** https://huggingface.co/glaiveai

### Core Products & Capabilities

#### Synthetic Dataset Platform
- **Dataset Designer**: Describe task + schema → Glaive generates training data
- **Schema-based generation**: Control structure of synthetic data (JSON format, length constraints, value sets)
- **Knowledge sources**: Inject domain knowledge into generation pipeline
- **Dataset Explorer**: View, search, filter generated data; auto-clustering by topic
- **Versioning**: Edit datasets → create new versions → train new model versions
- **Editing**: Add/remove samples based on conditions (e.g., "Add 100 samples where prompt has minimum 500 tokens")

#### Key Features
- Custom synthetic datasets for any use case
- Ownership model: datasets & model weights belong to customer forever
- No labeling or scraping required
- Iterative improvement workflow

### Notable Open-Source Datasets (HuggingFace)
| Dataset | Description |
|---------|-------------|
| glaiveai/glaive-function-calling-v2 | 113k function calling samples (Apache-2.0) |
| glaiveai/glaive-function-calling-v1 | Earlier function calling dataset |
| Code Assistant | Code generation training data |
| RAG (Retrieval Augmented Generation) | RAG training data |

### Featured Case Study
- **Groq** used Glaive datasets to train a model that reached **#1 on the Berkeley Function Calling Leaderboard (BFCL)**, outperforming all other open-source AND proprietary models at the time.

### Integration Points
- Platform API for programmatic dataset generation
- HuggingFace model/dataset hosting
- Works with any fine-tuning pipeline (model weights are portable)
- Specialized in function/tool calling, code, RAG, and structured output tasks

---

## Cross-Organization Integration Points

| Anoma ↔ Tweag | Both operate in formal methods / functional programming space. Juvix (Anoma) is Haskell-implemented. Tweag's Haskell + formal verification expertise is complementary. |
|---|---|
| Anoma ↔ Glaive | Glaive's synthetic data could train intent-parsing models for Anoma's solver network. |
| Tweag ↔ Glaive | Tweag's monad-bayes probabilistic programming could inform Glaive's sampling strategies. Tweag's GenAI group may use Glaive for fine-tuning. |
| All three | Functional programming (Juvix/Haskell) + synthetic training data (Glaive) + build/deploy infrastructure (Nix/Nickel from Tweag) = full stack for intent-centric AI applications. |
