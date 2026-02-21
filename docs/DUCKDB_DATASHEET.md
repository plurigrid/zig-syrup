# DuckDB Dataset Scope — Datasheet for Datasets

**Date**: 2026-02-20
**Universe**: 90 databases, 492 tables, ~1.73 GB
**Root**: `/Users/bob/i/`
**Catalog**: `zig-syrup/tools/openbci_host/nuworlds/duckdb_catalog.duckdb`

---

## 1. Agent Session Logs

Conversation histories, tool calls, and session metadata from AI coding agents.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `claude-all-sessions` | 706 MB | 1 | raw_messages (165K) | Full Claude Code session export. Deeply nested STRUCTs: message content, tool_use, todos, context_management. Single denormalized table. |
| `copilot_history` | 25 MB | 8 | session_events (4.7K) | Claude + Codex history, color_usage, dafny_files, command_history. Cross-agent session tracking. |
| `goose_reafference` | 25 MB | 10 | messages (6.2K) | Goose sessions with reafference metadata. Searchable_sessions view (2.8K). Sessions_by_date aggregation. |
| `kimi_sessions` | 9.5 MB | 15 | wire_events (1.3K) | Kimi CLI sessions: messages, tool_calls, token_usage, checkpoints, irreducibility_scores. |
| `history` | 1.8 MB | 3 | history_all | Merged claude_history + codex_history. |
| `claude_sessions` | 524 KB | 1 | sessions | Session metadata index. |
| `claude-sessions` | 524 KB | 1 | sessions | Artifact copy of session metadata. |
| `repl_history` | 780 KB | 1 | history | REPL command history. |

**Schema patterns**: Temporal (timestamp, session_id), nested STRUCT for tool results, GF(3) trit annotations on some tables.

---

## 2. Social Graph & Messaging

Messages, contacts, and communication patterns across platforms.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `social_graph` | 26 MB | 4 | messages (125K) | Largest message corpus. chat_summary, temporal_arc, own_participation_timeline. |
| `ies_messages` | 18 MB | 1 | messages | IES (Interaction Entropy System) message archive. |
| `beeper_messages` | 780 KB | 1 | messages | Beeper unified messaging export. |
| `greenteatree01_messages` | 1.8 MB | 1 | messages | Single-account message archive. |
| `did-agi-beeper` | 6.7 MB | 3 | messages, did_agi_registry, chat_metadata | DID-linked messaging with identity registry. |
| `meta_org_learning_ct` | 3.1 MB | 4 | beeper_messages, beeper_chats, beeper_events | Category theory learning org messages. |
| `meta_org_learning_ct_cli` | 4.1 MB | 4 | beeper_cli_messages + view | CLI-exported version with attachments table. |
| `gay_signal_ducklake` | 3.9 MB | 9 | beeper_messages, claude_history | Signal + Beeper + Claude merged. anon_identities with Argon2 hashing. ducklake_timeline. |
| `gay` | 1.5 MB | 2 | messages, rec2020_gamut | Messages + Rec.2020 wide-gamut color reference. |

**Schema patterns**: (chat_id, sender, text, timestamp), SCD2 temporal versioning in some.

---

## 3. GitHub & Code Intelligence

Repository metadata, commits, PRs, issues, contributor graphs.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `interaction_hypergraph` | 13 MB | 20 | interaction_nodes (2.8K) | Multi-agent hypergraph: amp/claude/codex/goose/opencode histories, gh_commits/issues/PRs, node_connectivity. |
| `macos_use` | 4.1 MB | 6 | gh_repos, gh_commits, gh_prs, gh_issues, gh_discussions, gh_contents | GitHub API snapshots of repos. |
| `ghostty_activity` | 2.8 MB | 5 | gh_issues, gh_prs, gh_runs | Ghostty terminal project activity tracking. |
| `jank_gh` | 1.3 MB | 6 | issues_flat, prs_flat, issue_activity, pr_activity | Jank language project tracking. |
| `jank_interop` | 1 MB | 3 | commits, pull_requests, repo_meta | Jank C++ interop layer tracking. |
| `gh_interactions` | 1.3 MB | 2 | gh_interactions, gh_collab_edges | Collaboration network edges. |
| `gh_joshbooks_ducklake` | 1.3 MB | 5 | commits, issues, pull_requests, repos, snapshots | Single-user GitHub ducklake. |
| `rzk_interactions` | 780 KB | 2 | issues, prs | Rzk proof assistant project. |
| `gh_social` (nuworlds) | 524 KB | 1 | interactions (3) | GraphQL-ingested GitHub social data. |
| `deepwiki` | 524 KB | 1 | indexed_repos | DeepWiki repo index. |
| `repo_interactome` | 2.8 MB | 3 | repos, repo_chat_mentions, repo_contact_links | Repo-to-chat cross-reference. |

---

## 4. Blockchain & Commitment Infrastructure

Aptos, Basin, WEV (World Extractable Value), on-chain commitments.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `aptos_time_travel` | 16 MB | 15 | events (5.1K) | Temporal event sourcing: claude_events/raw, codex_events/raw, snapshots, aptos/wev/beeper_mcp mentions + goal hypotheses. |
| `basin-replay` | 21 MB | 39 | blake3_cid (16.8K) | Session replay with Blake3 content addressing. Merkle trees, file_sizes, Catalan-Doppler analysis, vivarium/warehouse topology, GF(3) conservation proofs. |
| `basin_commitment` | 1 MB | 3 | basin_messages, commitment_gradient, own_commitment_arc | Commitment trajectory tracking. |
| `aptos_regret` (duck/) | 4.6 MB | 2 | aptos_docs, regret_plan | Aptos documentation + regret analysis. |
| `gay_mcp` | 3.6 MB | 3 | rounds, gay_beacons, gay_session_overlay | Gay MCP drand beacon rounds + session overlays. |
| `ecosystem_opengames` | 2.3 MB | 4 | games, companies, compositions, triads | Open games: Nash equilibria, company compositions, GF(3) triads. |

---

## 5. Identity & Belief Systems

Belief revision, epistemic entrenchment, AGM postulates, identity proofs.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `belief_revision` | 154 MB | 41 | raw_commits (400) | ACSet-schema AGM belief revision: 8 postulates (K*1-K*8), Grove spheres, Harper/Levi identities, selection functions, entrenchment relations. Commit-as-revision bridge. Gay_colors, ies_batches, regime_transitions. |
| `joker_patterns` | 524 KB | 1 | patterns | Joker Lisp pattern database (boxxy). |

**Schema patterns**: ACSet-style (entity_id, attributes, morphisms), GF(3) trit + gay_color annotations.

---

## 6. Music, Knowledge & Research

Compositions, knowledge graphs, academic resources, curriculum.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `music_knowledge` | 9 MB | 20 | rust_crates, resources, concepts | Music topos knowledge base: Roughgarden resources, SMR learning path, mechanism design curriculum, speaker collaborations, theory-to-implementation mapping. |
| `compositions` | 3.9 MB | 9 | compositions_current, composition_history | Music compositions with denotators, morphisms, triads, broadcasts. Argumentation rounds. |
| `music_topos_artifacts` | 2.8 MB | 4 | artifacts, badiou_triangles, color_retromap, temporal_index | Music topos output artifacts. |
| `neurips2025` | 1.8 MB | 3 | papers, paper_mathpix, armstrong_aligned | NeurIPS 2025 paper corpus with Mathpix LaTeX extraction. |
| `2600` | 2.6 MB | 7 | issues, topic_index, notable_articles, access_methods | 2600 Magazine hacker archive: issues by decade, topic coverage. |
| `clockssugars` | 1.3 MB | 3 | blog_posts, latex_expressions, latex_validation | Blog content with LaTeX extraction. |
| `playlist_transcripts` | 205 MB | 1 | transcripts (343) | Video transcripts with FLOAT[] embeddings and cluster_id. Ready for vector search. |

---

## 7. Interaction Entropy & Reafference

Self-modeling, prediction-observation loops, information-theoretic tracking.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `interaction_entropy` | 6.4 MB | 18 | reafference_predictions (100) | ACSet interaction model: color_parts, morphisms, objects, DisCoPy diagram structure, GF(3) epoch conservation, terminal_entropy, world_entropy. |
| `claude_interaction_reafference` | 2 MB | 4 | interactions, efference_predictions, entropy_traces, reafference_matches | Efference copy / reafference matching loop. |
| `claude_corollary_discharge` | 2.8 MB | 7 | amplified_signals, efferent_commands, error_signals, sensory_reafference, suppressed_signals, threat_alerts | Von Holst corollary discharge model: suppression statistics. |
| `claude_seed_recovery` | 1.8 MB | 3 | color_observations, seed_candidates, seed_validation | Abductive seed recovery from observed colors. |
| `moebius_coinflip` | 1.3 MB | 2 | moebius_coinflip_events, spectral_filtration_summary | Mobius inversion applied to random events. |
| `claude_corollary_discharge_test` | 780 KB | 1 | test_table | Test harness. |

---

## 8. Twitter & Social Media

Personal Twitter/X archive with temporal versioning.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `twitter` | 97 MB | 9 | likes (65K) | Full Twitter archive: tweets (13.8K), likes (65K), hashtags (1.4K), mentions (16.7K), URLs (4.8K). **SCD2 pattern**: version_id, valid_from, valid_to for bitemporal tracking. |
| `x69ers` | 780 KB | 2 | x69ers, x69ers_stats | Niche Twitter subset + stats. |

---

## 9. Session Artifacts & Analysis

Derived analytics, regret analysis, cross-references.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `i` | 236 MB | 46 | prompt_vocabulary (3.8K) | **Meta-database**: 46 tables spanning agent_ontologies, game theory (nash_negotiation, agent_payoff_matrix), session analytics (session_flow, session_homology, session_leaderboard), SAW (self_avoiding_walks, skill_walk_history), photonics_west_2026, possible_worlds, KScale repos/contributors, Barton analysis, trifurcation_points. |
| `ducklake_timetravel` | 5.6 MB | 6 | claude_raw, codex_raw, contexts, relations, beta_reductions, context_graph | Time-travel queries with context graph. |
| `regret-analysis` | 524 KB | 1 | session_regret | Per-session regret scores. |
| `database-inventory` | 524 KB | 1 | databases | Meta-inventory of databases. |
| `ducklake-cross-reference` | 524 KB | 1 | db_repo_links | Database-to-repo mapping. |
| `alea_everywhere` | 1.3 MB | 3 | alea_identity, alea_messages, alea_publications | Randomness-as-identity system. |
| `claude_history_gay` | 1 MB | 2 | claude_history, gf3_quads | Claude history with GF(3) quad assignments. |

---

## 10. Infrastructure & DevOps

Containers, Nix packages, device reconnaissance.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `apple_containers` | 1.8 MB | 9 | core_repos, core_virt, hardening | Apple virtualization landscape: guest_os_support, vzefi_reference, full_interactome. |
| `nix_gc_packages` | 524 KB | 1 | gc_packages | Nix garbage collection package inventory. |
| `recon` | 3.1 MB | 3 | scans, devices, alerts | Waymo device reconnaissance data. |

---

## 11. BCI & Cognitive Science

Brain-computer interfaces, EEG, phenomenal states.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `bci_ecosystem` | 2.6 MB | 7 | bci_condensed_mathematics, bci_infinity_categories, etc. | BCI mathematical foundations: condensed math, derived categories, operadic composition, model categories, infinity topoi. |
| `apt_observations` | 4.4 MB | 12 | observations, flickers, anomalies, ghost_files | APT (Ambient Phenomenal Tracking): observation_triplets, GF(3) violations, method_stats. |

---

## 12. Worldslop & Games

Anti-slop analysis, open games, vibes.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `worldslop` | 30 MB | 1 | frames (115) | Worldslop analysis frames. |
| `goblin-patterns` | 268 KB | 3 | challenges, telemetry_spans, vows | Vibesnipe goblin game patterns. |

---

## 13. Specialized Knowledge Graphs

Domain-specific structured data.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `epstein` | 4.4 MB | 29 | persons (28), locations (10) | Epstein document knowledge graph: persons, organizations, events, claims, RDF triples, provenance chains. Mostly schema scaffolding (0 rows). |
| `shadows_forgotten_ancestors` | 2.3 MB | 5 | transcript, film_metadata, polyglot, ukrainian_subtitle_stats | Parajanov film analysis: multilingual corpus. |
| `amp_threads_closure` | 2.8 MB | 10 | threads, thread_stats, thread_summaries, conceptual_spaces, color_mentions | Amp thread analysis: thread_graph, thread_references, color_sources. |
| `unified_thread_lake` | 6.4 MB | 6 | threads, concepts, concept_timeline, concept_relations, colored_sexprs | Unified thread lake: concept extraction with temporal tracking. |

---

## 14. Skill & Agent Evolution

Agent capabilities, skill graphs, dispersal tracking.

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `asi` | 268 KB | 3 | extracted_skills, skill_intersections, asi_main_additions | ASI skill extraction and intersection analysis. |
| `query_agent_evolution` | 524 KB | 1 | agents | Agent evolution tracking. |
| `exa_research` | 1 MB | 2 | research_events, research_tasks | Exa AI research task tracking. |
| `bib` (x5 copies) | 1.3 MB ea | 1 | citations | Academic citation database (replicated across skill dirs). |
| `hatchery` (x5 copies) | 12 KB ea | 0 | — | Empty hatchery paper databases (schema only). |

---

## 15. Miscellaneous

| Database | Size | Tables | Top Table (rows) | Description |
|----------|------|--------|-------------------|-------------|
| `social-graph` (artifacts) | 1.3 MB | 1 | saw_repos | Self-avoiding walk repos. |
| `zen_history` | 2 MB | 5 | zen_visits, moz_places, browser_history | Zen browser history import. |
| `gitcoin_plurigrid` | 48 KB | 2 | gitcoin_repos, plurigrid_repos | Gitcoin grant repos. |
| `webos_legacy` | 268 KB | 1 | repos (0) | WebOS legacy repo tracking (empty). |

---

## Cross-Cutting Patterns

### GF(3) Trit Annotations
Tables with `gf3_trit INTEGER` or `trit INTEGER` columns:
- `belief_revision.AGMPostulate`, `Commit`, `BeliefRevisionWalk`
- `interaction_entropy.gf3_epoch_conservation`
- `basin-replay.gf3_conservation_proof`
- `bridge9_phase4_feedback` (Python/DuckDB integration)
- `claude_history_gay.gf3_quads`

### Gay Color Annotations
Tables with `gay_color VARCHAR` or `color_hex VARCHAR`:
- `belief_revision.gay_colors`, `Commit`, `AGMPostulate`
- `interaction_entropy.acset_color_parts`
- `music_topos_artifacts.color_retromap`
- `amp_threads_closure.color_mentions`, `color_sources`

### SCD2 / Temporal Versioning
- `twitter.duckdb`: `version_id`, `valid_from`, `valid_to` on tweets/likes
- `aptos_time_travel`: event snapshots
- `ducklake_timetravel`: AS-OF query support

### ACSet (Attributed C-Set) Schemas
- `belief_revision.duckdb`: Full ACSet with version tracking
- `interaction_entropy`: `acset_objects`, `acset_morphisms`, `acset_color_parts`
- `basin-replay`: Merkle tree + CID addressing

### Embedding Vectors
- `playlist_transcripts.transcripts`: `embedding FLOAT[]`, `cluster_id INTEGER`
- `i.agent_ontologies`: `features INTEGER[8]`

---

## Row Count Distribution

| Range | Count | Examples |
|-------|-------|---------|
| 100K+ | 3 | raw_messages (165K), messages (125K), likes (65K) |
| 10K-100K | 5 | blake3_cid (17K), tweets (14K), tweet_mentions (17K) |
| 1K-10K | ~25 | session_events, tool_calls, messages across various |
| 100-1K | ~60 | Most analytic/derived tables |
| 0-100 | ~300 | Schema scaffolding, small reference tables |
| 0 (empty) | ~100 | Hatchery, epstein KG, discopy, skill_dispersal |

---

## Access

```nu
# From nuworlds:
source duckdb_find.nu

duckdb universe                              # Dashboard
duckdb find                                  # List all 90 databases
duckdb tables "/Users/bob/i/i.duckdb"        # Tables in a db
duckdb schema "/Users/bob/i/i.duckdb" "claude_history"  # Column types
duckdb query "/Users/bob/i/i.duckdb" "SELECT * FROM claude_history LIMIT 5;"
duckdb search-tables "belief"                # Find tables by name across all dbs
duckdb grep "passport"                       # Full-text search across all dbs
duckdb catalog                               # Rebuild catalog index
duckdb catalog-query "SELECT ..."            # Query the meta-catalog
```
