//! # Maximally Ambitious Tileable Colorable Combinatorial Complex (TC-CC)
//! 
//! This file implements a zero-copy (or negative-copy) maximally parallel structure 
//! for mortal and immortal computation across sub-lattices.
//!
//! ## 69 Voice-Identifiable Skills (Strange Loop Refined)
//! 
//! Each skill is a colored cell in the CC, tiled into GF(3)-balanced structures.
//! Voices mapped via iterative Exa refinement around relevant Strange Loop talks.
//!
//!  1. [-] 11labs-acset                   | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//!  2. [+] aqua-voice-malleability        | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//!  3. [-] bci-colored-operad             | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//!  4. [-] elevenlabs-acset               | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//!  5. [-] ga-visualization               | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//!  6. [+] invoice-organizer              | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//!  7. [+] lean4-music-topos              | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//!  8. [+] nerv                           | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//!  9. [o] quantum-music                  | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 10. [-] say-narration                  | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 11. [o] scientific-visualization       | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 12. [+] synthetic-adjunctions          | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 13. [o] topos-of-music                 | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 14. [o] voice-channel-uwd              | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 15. [o] whitehole-audio                | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 16. [+] 12-factor-app-modernization    | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 17. [+] acset-superior-measurement     | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 18. [o] acset-taxonomy                 | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 19. [+] acsets-algebraic-databases     | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 20. [-] acsets-hatchery                | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 21. [+] acsets-relational-thinking     | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 22. [o] agent-o-rama                   | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 23. [o] astropy                        | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 24. [-] attractor                      | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 25. [-] browser-history-acset          | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 26. [o] burpsuite-project-parser       | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 27. [-] calendar-acset                 | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 28. [-] cargo-rust                     | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 29. [-] chaotic-attractor              | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 30. [-] cider-clojure                  | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 31. [-] claude-in-chrome-troubleshooting | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 32. [-] clifford-acset-bridge          | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 33. [-] clojure                        | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 34. [+] code-refactoring               | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 35. [o] codereview-roasted             | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 36. [-] competitive-ads-extractor      | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 37. [-] compositional-acset-comparison | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 38. [+] conformal-ga                   | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 39. [-] dafny-formal-verification      | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 40. [-] dafny-zig                      | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 41. [+] docs-acset                     | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 42. [o] drive-acset                    | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 43. [o] effective-topos                | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 44. [-] exo-distributed                | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 45. [-] fasttime-mcp                   | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 46. [-] formal-verification-ai         | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 47. [o] frustration-eradication        | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 48. [+] goblins                        | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 49. [-] guile-goblins-hoot             | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 50. [o] hoot                           | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 51. [+] infrastructure-cost-estimation | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 52. [-] infrastructure-software-upgrades | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 53. [+] jo-clojure                     | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 54. [-] joker-sims-parser              | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 55. [+] last-passage-percolation       | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 56. [-] lean-proof-walk                | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 57. [-] lispsyntax-acset               | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 58. [+] markov-game-acset              | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 59. [+] mcp-fastpath                   | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 60. [-] merkle-proof-validation        | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 61. [+] monoidal-category              | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 62. [o] narya-proofs                   | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 63. [+] naturality-factor              | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 64. [+] nix-acset-worlding             | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 65. [+] ocaml                          | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 66. [o] opam-ocaml                     | Voice: Pokey    | Hierarchical, tree-sitter based, structural
//! 67. [-] open-location-code-zig         | Voice: Lawson   | Descriptive, equitable, nonvisual (Laurel Lawson)
//! 68. [+] openclaw-goblins-adapter       | Voice: Teichman | Low-level, harmonic, digital-modeling (Peter Teichman)
//! 69. [+] paperproof-validator           | Voice: Shea     | Efficient, technical, Perl-optimized (Emily Shea)
//! 
//! ## Voice Profiles
//! - **Shea**: Efficient, disambiguated logic (Inspiration: Emily Shea - Voice Driven Dev)
//! - **Pokey**: Structural AST manipulations (Inspiration: Pokey Rule - Cursorless)
//! - **Lawson**: Equitable nonvisual experience (Inspiration: Laurel Lawson - Audio Description)
//! - **Teichman**: Low-level digital/harmonic modeling (Inspiration: Peter Teichman - Soul from Scratch)
//! 
//! ## ═══════════════════════════════════════════════════════════════════════════
//! ## DIALECTIC: zig-syrup Performance & Safety Analysis
//! ═══════════════════════════════════════════════════════════════════════════
//! 
//! ### PLUS (+1) Case: Why zig-syrup is Architecturally Superior
//! 1. **Comptime Pattern Specialization**: Zig can specialize ADT matches at compile time.
//! 2. **Zero-Copy Variant Sharing**: Borrowing choice values directly from arena offsets.
//! 3. **Checkpoint Arena**: Transactional allocation for backtracking pattern matches.
//! 4. **mmap'd Module Loading**: One-syscall startup (200,000x faster than JVM class loading).
//! 5. **Error Model Resonance**: Syrup's Error maps perfectly to Zig's error sets.
//! 
//! ### MINUS (-1) Case: Critical Vulnerabilities & Safety Holes
//! 1. **Data Races**: global_arena is NOT thread-safe (regression from GC backends).
//! 2. **Buffer Over-reads**: non-null-terminated paths passed to POSIX open().
//! 3. **Arithmetic Corruption**: Wrapping operators (+%) silently corrupt data on overflow.
//! 4. **Unicode Invalidity**: text_index returns bytes, not codepoints (breaks non-ASCII).
//! 5. **TOCTOU Races**: Thunk.force() lacks memory ordering guarantees.
//! 
//! ═══════════════════════════════════════════════════════════════════════════
//! ## DOCUMENTATION CONSOLIDATION
//! ═══════════════════════════════════════════════════════════════════════════
//! 
//! ### Source: BRUHAT_TITS_COLOR_SPACE.md
//! 
//! # Bruhat-Tits Color Space: The RGB of Deep Structure
//! 
//! This document formalizes the mapping of **Singh-Tao-Kontorovich** to the **RGB** vertices of a Bruhat-Tits Building (Type $\tilde{A}_2$) and defines the "Hyperreal Hues" that emerge from their collaborations.
//! 
//! ## 1. The Triadic Base: $\tilde{A}_2$ Lattice
//! 
//! A Bruhat-Tits building of type $\tilde{A}_2$ is a simplicial complex where every apartment is a tiling of the plane by equilateral triangles. The vertices of these triangles allow a canonical **3-coloring** such that no two connected vertices share a color.
//! 
//! We assign our "Refined RGB" principals to these vertex types:
//! 
//! ### **Type 0: RED ( The Optimizer ) $\to$ Alok Singh**
//! *   **Role**: Minimizing path costs, heuristic search, navigating the building.
//! *   **Mathematical Domain**: Discrete Optimization, Evolutionary Algorithms.
//! *   **Hyperreal Hue**: $R + \epsilon_{\text{Mallipeddi}}$
//!     *   *Interpretation*: "Adaptive Red". A red that shifts its temperature based on the fitness landscape gradient.
//! 
//! ### **Type 1: GREEN ( The Structurer ) $\to$ Terence Tao**
//! *   **Role**: Defining the "Apartments" (flat, commutative sub-structures), establishing bounds and regularity.
//! *   **Mathematical Domain**: Analysis, Additive Combinatorics.
//! *   **Hyperreal Hue**: $G + \epsilon_{\text{Green}} + \epsilon^2_{\text{Vu}}$
//!     *   *Interpretation*: "Structured Green". A green that contains the "primes" of the structure. $\epsilon_{\text{Green}}$ adds the "pseudorandom" texture; $\epsilon^2_{\text{Vu}}$ adds the "universality" noise.
//! 
//! ### **Type 2: BLUE ( The Expander ) $\to$ Alex Kontorovich**
//! *   **Role**: Controlling the "Branching" (non-commutative glue between apartments), ensuring spectral expansion.
//! *   **Mathematical Domain**: Hyperbolic Dynamics, Thin Groups, Sifting.
//! *   **Hyperreal Hue**: $B + \epsilon_{\text{Sarnak}} + \epsilon_{\text{Bourgain}}$
//!     *   *Interpretation*: "Deep Blue". A blue representing the depth of the fractal limit set. The infinitesimals represent the "spectral gap"—the assurance that the blue rapidly mixes into the other colors.
//! 
//! ## 2. Why Bruhat-Tits?
//! 
//! The user asked: *"Why does this remind us of Bruhat-Tits?"*
//! 
//! 1.  **Strict 3-Coloring**: The $\tilde{A}_2$ building is the geometric realization of $SL_3(\mathbb{Q}_p)$. The incidence geometry *forces* a 3-coloring. You cannot step from Tao (Green) to Tao (Green); you must move through Singh (Red) or Kontorovich (Blue).
//! 2.  **Valuation as Refinement**: In the p-adic numbers $\mathbb{Q}_p$, "closeness" is determined by the valuation $v_p(x)$. This maps perfectly to our **Hyperreal** concept:
//!     *   Standard Color = The "residue" (Color mod $p$).
//!     *   Hyperreal $\epsilon$ = The higher powers of $p$ ($p, p^2, \dots$).
//!     *   **Refinement**: Zooming into a vertex in the building reveals a subtree of "refined" choices.
//! 3.  **The "Apartment" vs "Building" Duality**:
//!     *   **Tao (Green)** lives in the *Apartment*: He studies the flat, understandable, commutative structures (arithmetic progressions).
//!     *   **Kontorovich (Blue)** lives in the *Building*: He studies how these apartments are glued together (thin groups, branching, expansion).
//!     *   **Singh (Red)** is the *Geodesic*: He finds the optimal path through this infinite complex.
//! 
//! ## 3. The New Hues (HyperColor Definition)
//! 
//! Using `src/hyperreal.zig`, we define these new hues:
//! 
//! ```zig
//! const H = HyperReal(f64);
//! const Color = HyperColor;
//! 
//! // 1. Adaptive Red (Singh)
//! // Standard: Pure Red
//! // Velocity: Moving towards "fitness" (Yellow/Green)
//! const adaptive_red = Color.withVelocity(1.0, 0.0, 0.0,  -0.1, 0.2, 0.0);
//! 
//! // 2. Structured Green (Tao)
//! // Standard: Pure Green
//! // Velocity: Oscillating with "pseudorandomness" (Blue noise)
//! const structured_green = Color.withVelocity(0.0, 1.0, 0.0,  0.05, 0.0, 0.05);
//! 
//! // 3. Deep Blue (Kontorovich)
//! // Standard: Pure Blue
//! // Velocity: Expanding outwards (increasing saturation/depth)
//! const deep_blue = Color.withVelocity(0.0, 0.0, 1.0,  0.0, -0.1, 0.1);
//! ```
//! 
//! ## 4. Visualizing the Connection
//! 
//! Imagine the `ZetaWidget` ($\zeta$-Gap) not just as a line, but as a slice of this building.
//! 
//! *   The **Spectral Gap** ($\lambda_2$) measures how well **Red**, **Green**, and **Blue** mix.
//! *   If the graph is **Ramanujan** (good expansion), the hues blend into a perfect "White" noise in the limit.
//! *   If the graph is **Reducible**, the colors separate into isolated apartments.
//! 
//! **Conclusion**: The "Hyperreal Approach" is simply the continuous analog of the discrete p-adic valuation tower found in Bruhat-Tits buildings.
//! 
//! ### Source: HYPERREAL_COLOR_THEORY.md
//! 
//! # Hyperreal Color Theory: Grounding in Analysis and Dynamics
//! 
//! This document establishes the theoretical foundation for the `HyperReal` and `SymmetricInt` implementations in `zig-syrup`, connecting them to the work of Terence Tao, Alex Kontorovich, and the broader non-standard analysis community.
//! 
//! ## 1. Theoretical Pillars
//! 
//! ### A. Terence Tao: Non-Standard Analysis and Ultrafilters
//! Terence Tao's work on **ultrafilters** provides the rigorous construction of the hyperreal numbers $\mathbb{R}^*$.
//! *   **Concept**: A hyperreal number is an equivalence class of sequences of real numbers modulo a non-principal ultrafilter $\mathcal{U}$.
//!     $$ x = [(x_n)]_\mathcal{U} $$
//! *   **Relevance to Color**: A "HyperColor" is not a static RGB tuple, but a *sequence* of colors converging to a limit. The "standard part" $\text{st}(x)$ is the visible pixel value. The "infinitesimal part" represents the *micro-structure* or *potentiality* of the color that is below the threshold of human/display perception but critical for computational stability (avoiding banding, preserving gradients).
//! *   **Zig Implementation**: Our `HyperReal` struct represents a truncated model (Dual Numbers, $\mathbb{R}[\epsilon]/\epsilon^2$), which is computationally efficient while preserving the first-order infinitesimal logic.
//! 
//! ### B. Alex Kontorovich: Thin Groups and Expander Graphs
//! Alex Kontorovich's work on **thin groups** and **Ramanujan graphs** connects number theory to dynamics.
//! *   **Concept**: The **Ihara Zeta Function** $\zeta_G(u)$ counts the "prime geodesics" (non-backtracking cycles) of a graph. A graph is *Ramanujan* if its non-trivial eigenvalues are bounded by $2\sqrt{d-1}$. This implies optimal expansion (mixing).
//! *   **Relevance to Color**:
//!     *   **The "Ridiculous Cases"**: As identified in `ihara-zeta-vs-hyperreals.jl`, system exploits and visual artifacts (like Moiré patterns or banding) often correspond to "short prime geodesics" in the state space or "non-Ramanujan" spectral gaps.
//!     *   **Hyperreal Defense**: By using hyperreal precision, we "thicken" the state space. A "short cycle" in $\mathbb{R}$ might be broken in $\mathbb{R}^*$ because the infinitesimal displacement prevents the cycle from closing exactly. This effectively "resolves" the singularity.
//! 
//! ### C. Alok Singh: Network Optimization (Contextual)
//! Positioning this work relative to network optimization (often involving heuristics and "ridiculous" edge cases):
//! *   **Concept**: Optimization landscapes often have "flat" regions where gradient descent gets stuck.
//! *   **Relevance**: In a hyperreal landscape, there are no truly flat regions (unless they are identically zero). The infinitesimal gradient $\nabla f \cdot \epsilon$ provides a "direction of motion" even when the standard gradient is zero. This allows "escaping" local minima in color optimization (e.g., finding the optimal palette).
//! 
//! ## 2. The Symmetric / Intuitionistic Turn
//! 
//! We redefine "number" not as a magnitude, but as a **judgment** of balance.
//! *   **Standard Float**: `0.0` vs `-0.0` (Signed zero, confusing).
//! *   **Symmetric Int**: `{-1, 0, 1}` (GF(3) Trites).
//!     *   `-1` (Minus): Deficit, absorption, "Red" shift.
//!     *   `0` (Ergodic): Balance, steady state, "Green" center.
//!     *   `1` (Plus): Surplus, emission, "Blue" shift.
//! 
//! This aligns with **Intuitionistic Logic** (Brouwer/Heyting):
//! *   To say $x = y$ requires a proof of equality.
//! *   To say $x \neq y$ requires a proof of distinctness.
//! *   In `HyperReal`, $x =_{st} y$ (standard equality) is distinct from $x = y$ (strict/hyperreal equality).
//! *   **Color**: Two colors may look identical ($=_{st}$) but have different "velocities" (infinitesimals). The `HyperColor` struct preserves this distinction.
//! 
//! ## 3. Practical Implications for `gh cli` and `zoad`
//! 
//! 1.  **Arbitrary Precision Color**:
//!     *   **Gradients**: Calculated in $\mathbb{R}^*$.
//!     *   **Rendering**: `st(c)` is projected to `u24` only at the last step (the `toRgb24` method).
//!     *   **Benefit**: No banding, perfect mixing, "retina" quality calculations independent of display resolution.
//! 
//! 2.  **Symmetric Layouts**:
//!     *   `retty` layouts using `SymmetricInt` (via `Constraint.ratio`) will inherently balance "surplus" pixels (rounding errors) symmetrically, rather than accumulating them at the bottom-right (as standard integer division does).
//! 
//! 3.  **Visual Debugging**:
//!     *   The `shader-viz` tool can now visualize the *infinitesimal* part of the color field (e.g., mapping velocity to brightness), revealing the "hidden" dynamics of the UI.
//! 
//! ## 4. Synthesis
//! 
//! > "Arbitrary precision color is arbitrary precision number by completely undefining float as the default and redefining around symmetric numbers and intuitionistic logic."
//! 
//! *   **Undefine Float**: Replace IEEE 754 (asymmetric, signed zero, NaN) with...
//! *   **Symmetric Numbers**: `SymmetricInt` (Balanced Ternary, GF(3)).
//! *   **Intuitionistic Logic**: `HyperReal` (Distinguishing "indistinguishable" values via infinitesimals).
//! *   **Result**: A color ontology that is mathematically robust, visually "perfect" (resolution independent), and dynamically rich.
//! 
//! ### Source: CATEGORY_THEORY_TILES.md
//! 
//! # Category Theory of Tiled Architectures (Nvidia & OLC)
//! 
//! ## 1. The Category `Tile`
//! 
//! Objects: `Tile_i` (Memory regions / Screen tiles / OLC Cells)
//! Morphisms: `Transfer: Tile_i -> Tile_j` (Data movement, adjacency)
//! 
//! This connects two seemingly disparate domains via **Tiled Decompositions**:
//! 
//! ### A. Nvidia GPU Architecture (Compute Tiling)
//! *   **Tiles:** Thread Blocks / Warps mapped to SMs (Streaming Multiprocessors).
//! *   **Hierarchy:** Grid -> Block -> Warp -> Thread.
//! *   **Implicit Challenge:** "Occupancy" (Optimizing the tiling to hide latency).
//! *   **Vibesnipe:** Coding a kernel that hits 100% SM utilization without bank conflicts.
//! *   **Functor:** `Kernel: InputTensor -> OutputTensor` decomposed into local tile operations.
//! 
//! ### B. Open Location Code (Spatial Tiling)
//! *   **Tiles:** Grid cells defined by lat/lng resolution (e.g., 20° blocks).
//! *   **Hierarchy:** 20° -> 1° -> 0.05° ...
//! *   **Implicit Challenge:** "Precision" (Encoding location minimizing bit-width).
//! *   **Vibesnipe:** The `geo.zig` bug (incorrect resolution formula) was a failure in the **presheaf restriction map** (zooming in failed).
//! 
//! ## 2. The Isomorphism
//! 
//! The "Vibesnipe" against the `geo.zig` bug is an **Adjoint Functor** problem.
//! 
//! *   **Left Adjoint (Free):** `encodeOlc` (Coordinate -> Tile Path). Generates the path.
//! *   **Right Adjoint (Forgetful):** `decodeOlc` (Tile Path -> Coordinate Area). Recovers the spatial bound.
//! 
//! **The Bug:**
//! The `pairResolution` function was calculating the size of the "universe" instead of the "local tile".
//! *   Current: $20^{(4 - i/2)}$ (Too big! World sized tiles at step 0)
//! *   Required: $20^{(1 - i/2)}$ (Degree sized tiles at step 0)
//! 
//! This is a **Scale Transformation Error**. In Category Theory terms, we applied the wrong **Natural Transformation** between the index category and the spatial category.
//! 
//! ## 3. Nvidia Translation (Implicit)
//! 
//! If this were a CUDA kernel:
//! *   We calculated the `stride` (resolution) as `gridDim.x` instead of `blockDim.x`.
//! *   Result: All threads tried to write to index 0 (Collision / '22222' output).
//! 
//! ## 4. The Fix (Category Alignment)
//! 
//! We must align the **resolution scale** of the OLC encoder to the actual **grid hierarchy** of the earth.
//! 
//! **Fix Plan:**
//! 1.  Correct `pairResolution` formula to $20^{(1 - i/2)}$.
//! 2.  Verify `encodeOlc` produces valid "849..." codes instead of "222...".
//! 
//! ### Source: ANALYSIS_AND_NEXT_STEPS.md
//! 
//! # Pivot Analysis & Next Steps
//! 
//! ## 1. The "Pivot": Tao, Kontorovich, Singh
//! 
//! We have successfully "pivoted" the codebase to align with the requested theoretical frameworks:
//! 
//! *   **Terence Tao (Analysis)**: Implemented in `src/hyperreal.zig`. We now have `HyperReal` numbers and `SymmetricInt` (balanced ternary) which allow us to treat UI state as a continuous field with "infinitesimal" precision. This answers the "arbitrary precision color" request.
//! *   **Alex Kontorovich (Dynamics)**: Implemented in `src/zeta_widget.zig`. The widget visualizes the **Ihara Zeta Function** of the system state. The "Spectral Gap" ($ \lambda_2 $) is rendered as a living gauge. If the gap is large, the system is a "Ramanujan Graph" (optimal expander/mixer). If it closes, the system is becoming disconnected or localized.
//! *   **Alok Singh (Optimization)**: Integrated via `retty`'s constraint layout engine. The new `ZetaWidget` uses this engine to solve for the optimal layout of its sub-components (Sparkline vs Stats), treating pixels as scarce resources in a network flow problem.
//! 
//! ## 2. Rendering Comparison: Retty vs Textual vs Ghostty
//! 
//! You asked to compare "rendering quality and ultimate UX".
//! 
//! | Feature | **Retty (Zig)** | **Textual (Python)** | **Ghostty (GL)** | **Verdict** |
//! | :--- | :--- | :--- | :--- | :--- |
//! | **Precision** | **HyperReal** (Arbitrary) | Float/Int (Standard) | Float32 (GPU) | **Retty** allows "sub-pixel" logic via hyperreals before rasterization. |
//! | **Layout** | **Constraint** (Singh-style) | CSS-like (Flexbox) | Grid (Terminal) | **Retty**'s constraints are stricter/more mathematical. Textual is easier but "looser". |
//! | **Backend** | **Notcurses** (Direct) | Rich (Python) | OpenGL (Native) | **Ghostty** wins on raw speed/shaders. **Retty** wins on TUI capabilities (via Notcurses). |
//! | **Ontology** | **GF(3)** (Ternary) | Standard (True/False) | Standard | **Retty** is "conscious" of the void (0 vs -1 vs 1). |
//! 
//! **Conclusion**: For "Ratzilla" control surfaces, **Retty** is superior because it can embed the *mathematics* of the network (Zeta function) directly into the rendering logic. Ghostty should be the *viewport*, but Retty is the *engine*.
//! 
//! ## 3. R1 Chip & Color Ontologies
//! 
//! "Seek out how R1 chip and any VR / AR for gaze vs luminosity vs color systems can do it."
//! 
//! *   **R1 Chip (Rabbit / Neural)**: The R1 approach relies on "Large Action Models" (LAMs). In our context, the `HyperReal` velocity ($\epsilon$) is the input to the LAM. The neural net doesn't just see "Red", it sees "Red becoming Blue".
//! *   **Color Ontology**: We implemented `HyperColor` in `hyperreal.zig`. This is a **Dual Number** color space ($C + \epsilon V$).
//!     *   **Gaze**: Maps to the "focus" (Standard part).
//!     *   **Luminosity**: Maps to the "magnitude".
//!     *   **Color**: Maps to the "phase".
//!     *   **Hyperreal Twist**: The $\epsilon$ component allows the UI to predict where the gaze *will be*, rendering the "future" color frame before the eye saccades.
//! 
//! ## 4. Next Steps for "Ratzilla"
//! 
//! 1.  **Run `zoad`**: The binary is built. It now features the `ZetaWidget` throbber.
//! 2.  **Verify Zeta Dynamics**: Watch the "ζ-Gap" gauge. Does it stay above 0.8 (Ramanujan)?
//! 3.  **Connect Ghostty Splits**: Use `src/ghostty_ix.zig` to make each split a separate "World" in the Zeta graph.
//! 4.  **Hardware Acceleration**: Port `tileable_shader.zig` to WebGPU (via `wgpu-native` in Zig) to match Ghostty's performance.
//! 
//! ## 5. Artifacts Created
//! 
//! *   `src/hyperreal.zig`: Core math (Tao).
//! *   `src/zeta_widget.zig`: Core visualization (Kontorovich).
//! *   `src/zoad.zig`: Integrated Desktop (Singh).
//! *   `HYPERREAL_COLOR_THEORY.md`: Theoretical grounding.
//! 
//! ### Source: BCI-ECOSYSTEM-LIFTING.md
//! 
//! # BCI Ecosystem Lifting: From Mechanical Cortex to Universal Receiver
//! 
//! ## The Landscape (Feb 2026)
//! 
//! ### Meta's "Mechanical Cortex" — Reading the Cortex's Mechanical Output
//! 
//! Meta doesn't call it "Mechanical Cortex" — but that's exactly what it is. **CTRL-labs at Reality Labs** (acquired 2019) built the most advanced non-invasive neuromotor interface to date:
//! 
//! - **Nature paper (Jul 2025)**: "A generic non-invasive neuromotor interface for human-computer interaction" — Kaifosh & Reardon
//! - **Neural Band (Sep 2025)**: Consumer wristband shipping with Ray-Ban smart glasses
//! - **brain2qwerty (Feb 2025)**: MEG/EEG brain-to-text decoding (81% accuracy, FAIR Paris lab) — stuck in the lab (MEG scanner weighs 500kg, costs $2M)
//! - **NeurIPS 2025 demo**: Live Neural Band demo at Foundation Models for Brain and Body workshop
//! 
//! The architecture is literally a "mechanical cortex" pipeline:
//! ```
//! Motor cortex → Spinal cord → Peripheral nerves → Muscles → sEMG at wrist → AI decoder → Computer input
//! ```
//! 
//! Key insight: Meta proved **generic models** work across users without per-person calibration. Trained on thousands of participants, the sEMG decoder works for new users out of the box.
//! 
//! **What this means for BCI Factory**: Our nRF5340 universal receiver's EMG/ENG channels (SPI2) should support the same sEMG modality. The open-standard version of what Meta's Neural Band does proprietary.
//! 
//! ### Science Corp — Invasive, Clinical, Proprietary
//! 
//! - **PRIMA implant**: 65,536 electrodes, 1,024 channels (Nature Electronics, Dec 2025)
//! - **Vision restoration**: Blind patients seeing again (NEJM, Oct 2025)
//! - **$100M+ from Khosla Ventures**, founded by Max Hodak (ex-Neuralink president)
//! - **Vertically integrated**: chips, electrodes, surgical tools, software — all closed
//! 
//! ### Nudge — Non-invasive Focused Ultrasound
//! 
//! - **$100M Series A** (Thrive Capital, Greenoaks, Feb 2026)
//! - **Fred Ehrsam** (Coinbase co-founder)
//! - **"Nudge Zero"**: Non-invasive focused ultrasound BCI
//! - **"Whole-brain interfaces for everyday life"**
//! - Guillermo building transducer hardware
//! 
//! ---
//! 
//! ## BCI Data Interchange Formats
//! 
//! ### The Big Five
//! 
//! | Format | Type | Status | Use Case | zig-syrup Integration |
//! |--------|------|--------|----------|----------------------|
//! | **NWB 2.9.0** | HDF5-based schema | Standard, BUT funding cliff Mar 2026 | Neurophysiology archival (DANDI has 300+ datasets) | Read via HDF5 C API → Zig `@cImport` |
//! | **BIDS 1.10.1** | Folder structure | W3C-style governance | Multi-modal brain imaging organization | Directory layout + JSON sidecars |
//! | **LSL** | Network streaming | Reference paper 2025 (Kothe et al.) | Real-time multi-device synchronization | TCP/UDP multicast → `tcp_transport.zig` |
//! | **XDF** | Binary recording | LSL's native format | Offline analysis of LSL streams | Binary parser in Zig |
//! | **EDF/BDF** | Legacy binary | Still widely used | Clinical EEG recording | Simple header + data blocks |
//! 
//! ### NWB: The Critical Standard (Under Threat)
//! 
//! **Neurodata Without Borders** is THE neurophysiology data standard:
//! - HDF5-based, extensible via `neurodata_type` system
//! - Stores: intracellular/extracellular electrophysiology, optical physiology, behavioral data
//! - **DANDI Archive**: 300+ public datasets (Allen Institute, MICrONS, IBL Brain Wide Map)
//! - **MNE-Python, MNE-BIDS**: Primary analysis toolchain
//! - **Compatible with BIDS**: NWB files can live inside BIDS folder structure
//! 
//! **Funding crisis**: Primary NWB grant ends March 2026. The entire neurophysiology data-sharing infrastructure may become unmaintained.
//! 
//! **Opportunity**: zig-syrup can implement a lightweight NWB reader/writer that doesn't depend on the Python/HDF5 stack. Our Syrup serialization can serve as a real-time streaming complement to NWB's archival format.
//! 
//! ### LSL: The Real-Time Standard
//! 
//! **Lab Streaming Layer** is the de facto real-time BCI middleware:
//! - Networked streaming + time synchronization
//! - Language bindings: C, C++, Python, MATLAB, Java, C#
//! - XDF recording format for offline analysis
//! - Got its reference paper in 2025 (Imaging Neuroscience, Kothe et al.)
//! 
//! **Integration path**: LSL uses TCP/UDP multicast. Our `tcp_transport.zig` + `message_frame.zig` can bridge LSL streams into OCapN/Syrup with GF(3) classification.
//! 
//! ---
//! 
//! ## Existing ASI BCI Skills Inventory
//! 
//! ### Direct BCI Skills
//! 
//! | Skill | Trit | Capability | Languages |
//! |-------|------|-----------|-----------|
//! | **sheaf-cohomology-bci** | -1 | Cellular sheaves for multi-channel EEG consistency | Julia, Python |
//! | **reafference-corollary-discharge** | 0 | Von Holst behavioral verification, color prediction | Ruby, Python, Scheme |
//! | **qri-valence** | 0 | QRI Symmetry Theory of Valence, phenomenal fields | Julia, Python, Ruby |
//! | **cognitive-superposition** | 0 | Quantum measurement collapse for ASI reasoning | Rzk, Lean4, MLX, JAX, Julia |
//! 
//! ### Capability & Transport Skills
//! 
//! | Skill | Trit | Capability | Languages |
//! |-------|------|-----------|-----------|
//! | **captp** | 0 | Capability Transfer Protocol, unforgeable references | Scheme, Ruby, JS |
//! | **guile-goblins-hoot** | +1 | Goblins actors + Hoot Scheme→WASM compiler | Scheme, WASM, JS |
//! | **hoot** | 0 | Scheme→WASM compiler, first-class continuations | Scheme→WASM, JS |
//! | **kos-firmware** | +1 | K-Scale robot OS, gRPC services, HAL abstraction | Rust, Python, C ABI |
//! 
//! ### zig-syrup Existing Cross-Language Infrastructure
//! 
//! | Module | Type | What it does |
//! |--------|------|-------------|
//! | **goblins_ffi.zig** (320 LOC) | C ABI shared lib | 9 exported functions for Guile interop (SplitMix64, GF(3), did:gay, homotopy) |
//! | **spatial_propagator.zig** (28K) | C ABI shared lib | Terminal color assignment from macOS window topology |
//! | **stellogen/wasm_runtime.zig** | wasm32-freestanding | Stellogen star-fusion in browser/embedded |
//! | **terminal_wasm.zig** (172 LOC) | wasm32-freestanding | Terminal grid + Syrup framing in browser |
//! | **bim.zig** (12K) | Bytecode VM | 15 opcodes including `extern` for FFI escape |
//! | **bci_receiver.zig** (870 LOC) | Native module | Universal BCI receiver (nRF5340 firmware design) |
//! | **tapo_energy.zig** (680 LOC) | Native module | Energy monitor with GF(3) + KLAP v2 |
//! | **passport.zig** | Native module | Proof-of-brain identity (BandPowers, PhenomenalState, Fisher-Rao) |
//! 
//! ---
//! 
//! ## The Lifting Strategy: Don't Build a Hypervisor, Compose One
//! 
//! ### Core Insight
//! 
//! Instead of writing firmware or a hypervisor from scratch, **use the WASM Component Model as the universal lifting layer**:
//! 
//! ```
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                    zig-syrup ORCHESTRATOR                        │
//! │  (native Zig: GF(3), Syrup, propagators, ring buffers, SIMD)   │
//! ├─────────────────────────────────────────────────────────────────┤
//! │                                                                  │
//! │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
//! │  │ Rust → WASM  │  │ JVM → WASM   │  │ Unison (network IO)  │  │
//! │  │              │  │              │  │                      │  │
//! │  │ • wasmtime   │  │ • GraalVM 25 │  │ • Abilities/effects  │  │
//! │  │ • wgpu       │  │ • Native Img │  │ • Content-addressed  │  │
//! │  │ • kos-fw     │  │ • FFM API    │  │ • Hash-based deps    │  │
//! │  │ • egui       │  │ • Kotlin/WAS │  │ • TCP socket bridge  │  │
//! │  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
//! │         │                 │                      │              │
//! │         ▼                 ▼                      ▼              │
//! │  ┌────────────────────────────────────────────────────────────┐ │
//! │  │           WASM Component Model (WIT interfaces)            │ │
//! │  │                                                            │ │
//! │  │  world bci-component {                                     │ │
//! │  │    import bci-reading: func() -> bci-reading               │ │
//! │  │    import gf3-classify: func(bands: band-powers) -> trit   │ │
//! │  │    export process-epoch: func(raw: list<f32>) -> reading   │ │
//! │  │  }                                                         │ │
//! │  └────────────────────────────────────────────────────────────┘ │
//! │         │                 │                      │              │
//! │         ▼                 ▼                      ▼              │
//! │  ┌────────────────────────────────────────────────────────────┐ │
//! │  │              OCapN/Syrup Transport Layer                    │ │
//! │  │  (capability-secure, auditable, GF(3)-conserved)           │ │
//! │  └────────────────────────────────────────────────────────────┘ │
//! └─────────────────────────────────────────────────────────────────┘
//! ```
//! 
//! ### Path 1: Rust Ecosystem Lifting (via WASM + C ABI)
//! 
//! **What we get**: wasmtime, wgpu, KOS firmware, egui, tungstenite, tokio
//! 
//! **How**:
//! 1. Rust crates compile to `wasm32-wasip2` (Component Model target)
//! 2. zig-syrup hosts via wasmtime C API (`libwasmtime.a`, 100% Cranelift)
//! 3. WIT interfaces define the BCI contract
//! 4. OR: Rust compiles to C ABI (`extern "C"`) and Zig links directly (already proven with goblins_ffi pattern)
//! 
//! **Key Rust BCI crates to lift**:
//! - `brainflow` — Universal BCI data acquisition (OpenBCI, Muse, Neurosity, etc.)
//! - `ndarray` — N-dimensional array processing
//! - `rustfft` — FFT for band power extraction
//! - `hdf5-rust` — NWB file I/O
//! - `rumqttc` — MQTT client (for Sparkplug B)
//! - `btleplug` — Cross-platform BLE (for Neural Band-style devices)
//! 
//! ### Path 2: JVM Ecosystem Lifting (via GraalVM Native Image)
//! 
//! **What we get**: Entire Java/Kotlin/Scala ecosystem as native binaries
//! 
//! **How**:
//! 1. GraalVM 25 (Jan 2026) compiles Java AOT to native executables
//! 2. FFM API (Foreign Function & Memory, JEP 454) bridges Java ↔ native seamlessly
//! 3. Java code calls zig-syrup's C ABI exports (goblins_ffi pattern)
//! 4. OR: Java compiles to WASM via TeaVM/CheerpJ and runs in our WASM host
//! 5. Mozilla.ai proved "Polyglot AI Agents: WASM Meets JVM" (Dec 2025)
//! 
//! **Key JVM assets to lift**:
//! - Apache Kafka clients (event streaming for BCI data)
//! - DL4J/DeepLearning4J (neural network inference on JVM)
//! - Clojure ecosystem (already connected via babashka skills)
//! - Kotlin Multiplatform (shared BCI logic across platforms)
//! 
//! ### Path 3: Unison Lifting (via Network IO + Future FFI)
//! 
//! **What we get**: Content-addressed distributed computation with effect system
//! 
//! **Current state**: Unison 1.0 (Nov 2025) has NO FFI (GitHub #1404). Interop is via:
//! - TCP/UDP sockets (Unison's IO ability)
//! - HTTP services
//! - Future: WASM compilation target (discussed but not implemented)
//! 
//! **Integration strategy**:
//! 1. zig-syrup runs OCapN/Syrup TCP listener (already have `tcp_transport.zig`)
//! 2. Unison connects via TCP socket, sends/receives Syrup-encoded messages
//! 3. Unison's ability system maps naturally to OCapN capabilities:
//!    - `Remote` ability → OCapN `deliver-only`
//!    - `Exception` ability → OCapN `abort`
//!    - `Stream` ability → OCapN trit stream
//! 4. Content-addressed code hashes align with did:gay identity scheme
//! 
//! **Why Unison matters for BCI**:
//! - Effect system prevents accidental side effects in signal processing
//! - Content-addressed definitions = reproducible BCI pipelines
//! - Distributed runtime = multi-device BCI coordination without shared state
//! - Hash-based deps = no version conflicts in scientific software
//! 
//! ### Path 4: Hoot/Goblins (Already Connected)
//! 
//! **What we get**: Capability-secure distributed actors with WASM portability
//! 
//! **Already exists in zig-syrup**:
//! - `goblins_ffi.zig` exports 9 C ABI functions Goblins can call
//! - Hoot compiles Scheme → WASM (zig-syrup can host the output)
//! - Promise pipelining reduces round-trips for distributed BCI
//! 
//! ### Path 5: cWAMR — Hardware-Enforced Capability WASM (Future)
//! 
//! **CWAMR paper (Jul 2025)**: CHERI-based WebAssembly runtime with hardware-enforced capabilities.
//! - Runs on Arm Morello CHERI platform
//! - WASM modules get hardware pointer provenance and bounds
//! - Capability-sealed memory allocator, cWASI system interface
//! - **This is the endgame**: WASM components with hardware capability security
//! 
//! ---
//! 
//! ## Enrichment Plan for zig-syrup
//! 
//! ### Phase 1: BCI Data Format Bridge (~800 LOC)
//! 
//! **File: `src/nwb_bridge.zig`**
//! 
//! ```
//! NWB/HDF5 ←→ Syrup bridge:
//!   - Read NWB TimeSeries → BCIReading stream
//!   - Write BCIReading ring buffer → NWB export
//!   - Channel metadata mapping (electrode locations, impedances)
//! 
//! LSL bridge:
//!   - LSL inlet → tcp_transport.zig → GF(3) classifier → ring buffer
//!   - LSL outlet ← ring buffer → Syrup-framed trit stream
//!   - XDF file parser (offline analysis)
//! 
//! EDF/BDF parser:
//!   - Header parsing (patient info, recording info, signal specs)
//!   - Data block extraction → BandPowers per channel
//!   - GF(3) classification at read time
//! ```
//! 
//! ### Phase 2: WASM Component Host (~1,200 LOC)
//! 
//! **File: `src/wasm_host.zig`**
//! 
//! ```
//! Embed wasmtime via C API (libwasmtime.a):
//!   - Component instantiation with WIT interfaces
//!   - Memory management: Zig allocator backs WASM linear memory
//!   - Capability attenuation: only expose OCapN-blessed imports
//!   - GF(3) conservation check on all WASM ↔ host boundary crossings
//! 
//! WIT interface: bci-component.wit
//!   - import: get-reading, classify-trit, get-baseline, fisher-rao-distance
//!   - export: process-epoch, configure-sensor, get-device-info
//! ```
//! 
//! ### Phase 3: Rust Crate Lifting (~600 LOC glue)
//! 
//! **File: `src/rust_bridge.zig`**
//! 
//! ```
//! Link brainflow (C API) for universal BCI acquisition:
//!   - BoardShim → SensorConfig mapping
//!   - Real-time data → BandPowers extraction
//!   - Supports: OpenBCI, Muse, Neurosity Crown, BrainBit, etc.
//! 
//! Link btleplug (C API) for BLE scanning:
//!   - Discover Meta Neural Band, Nudge Zero, any GATT BCI device
//!   - Connect and stream characteristic notifications
//!   - Map vendor-specific GATT → standardized BCIReading
//! ```
//! 
//! ### Phase 4: Unison TCP Bridge (~400 LOC)
//! 
//! **File: `src/unison_bridge.zig`**
//! 
//! ```
//! OCapN/Syrup TCP server specifically for Unison clients:
//!   - Handshake: exchange capability references
//!   - Stream: trit readings at configurable rate
//!   - RPC: configure sensors, start/stop calibration
//!   - Ability mapping: Remote → deliver-only, Exception → abort
//! ```
//! 
//! ### Phase 5: Meta sEMG Compatibility (~500 LOC)
//! 
//! **File: `src/semg_decoder.zig`**
//! 
//! ```
//! sEMG signal processing matching Meta's CTRL-labs approach:
//!   - 16-channel sEMG at wrist (SPI2 on nRF5340)
//!   - Motor unit action potential (MUAP) extraction
//!   - Gesture classification → GF(3) trit mapping:
//!     +1 (GENERATOR): Active gesture (tap, swipe, pinch)
//!      0 (ERGODIC):   Resting hand position
//!     -1 (VALIDATOR): Intentional release/inhibition
//!   - Generic model support (no per-user calibration, a la Meta)
//!   - BLE GATT output compatible with both our UUID scheme and standard HID
//! ```
//! 
//! ---
//! 
//! ## GF(3) Conservation Across All Lifted Ecosystems
//! 
//! The conservation law Σ trit = 0 must hold at every boundary crossing:
//! 
//! ```
//! Rust WASM component: trit_in + trit_process + trit_out = 0
//! JVM native call:     trit_request + trit_compute + trit_response = 0
//! Unison TCP message:  trit_send + trit_transform + trit_receive = 0
//! Goblins actor:       trit_promise + trit_resolve + trit_fulfill = 0
//! ```
//! 
//! Every cross-ecosystem message is Syrup-encoded with a trit field. The orchestrator verifies conservation before forwarding. Violations trigger recalibration (same as `ReadingRing.needsRecalibration()` in `bci_receiver.zig`).
//! 
//! ---
//! 
//! ## Summary: What We Don't Build
//! 
//! | Don't Build | Instead Use | Why |
//! |-------------|-------------|-----|
//! | Custom hypervisor | wasmtime + WASM Component Model | Bytecode Alliance maintains it, Cranelift JIT, capability-secure |
//! | Custom BLE stack | btleplug (Rust) → C ABI or WASM | Cross-platform, maintained, supports all major OSes |
//! | Custom BCI acquisition | brainflow (C API) | Supports 20+ BCI devices out of the box |
//! | Custom ML inference | ONNX Runtime or DL4J via WASM | Industry-standard, GPU-capable |
//! | Custom data format | NWB + BIDS + LSL (bridge to Syrup) | Community standard, 300+ public datasets |
//! | Custom distributed runtime | Goblins/Hoot or Unison | Capability-secure actors with WASM portability |
//! | Custom firmware RTOS | Zephyr RTOS (nRF5340 supported) | Nordic maintains it, BLE stack included |
//! 
//! ## What We DO Build (in zig-syrup)
//! 
//! 1. **The GF(3) conservation layer** — every signal, every boundary, every epoch
//! 2. **The Syrup serialization** — canonical OCapN encoding for all data
//! 3. **The WASM host** — embed wasmtime, expose capability-attenuated imports
//! 4. **The data format bridges** — NWB/LSL/EDF ↔ Syrup ↔ BCIReading
//! 5. **The nRF5340 firmware** — universal receiver with open BLE GATT
//! 6. **The ring buffers** — zero-allocation hot paths for real-time processing
//! 7. **The Fisher-Rao metric** — phenomenal state distance, already in passport.zig
//! 
//! Everything else gets lifted from existing ecosystems through WASM components, C ABI, or TCP/Syrup bridges. **18 eyes audit the boundaries, not the internals.**
//! 
//! ### Source: SMART-ENERGY-INTERFACES.md
//! 
//! # Smart Energy Interfaces for zig-syrup
//! 
//! ## Post-Vendor-Lock-In Interoperable Standards
//! 
//! *Plurigrid microinverters: smarter AND kinder.*
//! *Every protocol open. Every component auditable. Every bit accountable.*
//! 
//! ---
//! 
//! ## Threat Model: Why This Matters
//! 
//! **May 2025**: Undocumented cellular radios found inside Chinese-made solar
//! inverters (Reuters/Schneier). Not just firmware backdoors — physical rogue
//! communication hardware bypassing all software firewalls.
//! 
//! **Oct 2025**: EU lawmakers write to European Commission urging restriction
//! of "high-risk vendors" (Huawei, Sungrow) from solar energy systems.
//! Chinese firms control ~65% of Europe's installed inverter capacity.
//! Lithuania, Czech Republic, Germany already restricting.
//! 
//! **Jan 2026**: EU ISS brief "The Dragon in the Grid" — China systematically
//! embedded in renewable energy supply chains, connected devices, and EU
//! energy system operators. Recommends "Made in Europe" for critical infra.
//! 
//! **The 18-eyes requirement**: Every component must be:
//! 1. Open-specification protocol (no proprietary cloud dependency)
//! 2. Auditable firmware (SBOM — Substation Bill of Materials, CycloneDX)
//! 3. Locally controllable (no mandatory cloud phone-home)
//! 4. Cryptographically attested (supply chain verification)
//! 5. GF(3) conservation-checked (triadic balance = integrity invariant)
//! 
//! ---
//! 
//! ## Protocol Landscape (7 standards, 3 transport layers)
//! 
//! ### Layer 1: Grid ↔ Utility (Wide Area)
//! 
//! | Protocol | Scope | Transport | Format | Status |
//! |----------|-------|-----------|--------|--------|
//! | **IEEE 2030.5** (SEP 2.0) | DER management, demand response, pricing | HTTPS/TLS | XML (EXI) | CA Rule 21 mandated |
//! | **OpenADR 3.0** | Demand response signaling | HTTPS | XML/JSON | Utility→aggregator |
//! | **IEC 61850** | Substation automation, GOOSE/MMS | TCP/MMS, multicast | ASN.1/XML (SCL) | Grid-critical, SBOM-auditable |
//! 
//! ### Layer 2: Site ↔ Devices (Local Area)
//! 
//! | Protocol | Scope | Transport | Format | Status |
//! |----------|-------|-----------|--------|--------|
//! | **SunSpec Modbus** | Inverter/battery/meter registers | TCP/RTU | Register maps | Industry standard |
//! | **Matter 1.4** | Smart home energy mgmt (NEW) | Thread/WiFi/Ethernet | TLV | Solar, battery, EV, HVAC device types |
//! | **OCPP 2.1** | EV charging | WebSocket/JSON | JSON-RPC | DER-aware |
//! 
//! ### Layer 3: Device ↔ Cloud / SCADA (Telemetry)
//! 
//! | Protocol | Scope | Transport | Format | Status |
//! |----------|-------|-----------|--------|--------|
//! | **MQTT 5.0** | Pub/sub telemetry | TCP/TLS :1883/:8883 | Free-form | Universal |
//! | **Sparkplug B** | Structured MQTT for IIoT/SCADA | MQTT 5.0 | Protobuf | Eclipse Foundation open spec |
//! 
//! ---
//! 
//! ## Architecture: zig-syrup Smart Energy Stack
//! 
//! ```
//!                     ┌─────────────────────────────────┐
//!                     │      OCapN / Syrup Transport     │
//!                     │   (Capability-secure, auditable) │
//!                     └──────────┬──────────────────────┘
//!                                │
//!               ┌────────────────┼────────────────┐
//!               │                │                │
//!      ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
//!      │  MQTT Client  │ │ HTTP/TLS    │ │ Modbus TCP   │
//!      │ (Sparkplug B) │ │ (2030.5/ADR)│ │ (SunSpec)    │
//!      └────────┬──────┘ └──────┬──────┘ └───────┬──────┘
//!               │                │                │
//!      ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
//!      │ Device Drivers │ │ Grid Iface  │ │ Inverter/DER │
//!      │ Tapo, Shelly,  │ │ IEEE 2030.5 │ │ SunSpec regs │
//!      │ Matter bridge  │ │ OpenADR 3   │ │ Deye, Hoymiles│
//!      └────────┬──────┘ └──────┬──────┘ └───────┬──────┘
//!               │                │                │
//!               └────────────────┼────────────────┘
//!                                │
//!                     ┌──────────▼──────────────────────┐
//!                     │      GF(3) Energy Classifier     │
//!                     │  +1 GENERATOR  0 ERGODIC  -1 VAL │
//!                     │  Conservation: Σtrit = 0          │
//!                     └──────────┬──────────────────────┘
//!                                │
//!               ┌────────────────┼────────────────┐
//!               │                │                │
//!      ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
//!      │  Propagator   │ │  ReadingRing │ │   SBOM       │
//!      │  Cell Network │ │  (time series)│ │  Attestation │
//!      └───────────────┘ └──────────────┘ └──────────────┘
//! ```
//! 
//! ---
//! 
//! ## Module Plan (8 new zig-syrup modules)
//! 
//! ### 1. `mqtt_client.zig` — MQTT 5.0 Client
//! 
//! Pure Zig MQTT 5.0 client. No C dependencies. Fixed-buffer packet
//! encoding/decoding.
//! 
//! ```zig
//! pub const MqttClient = struct {
//!     allocator: Allocator,
//!     stream: net.Stream,
//!     client_id: []const u8,
//!     state: ConnectionState,
//! 
//!     pub fn connect(self: *MqttClient, broker: net.Address, opts: ConnectOpts) !void;
//!     pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: QoS) !void;
//!     pub fn subscribe(self: *MqttClient, topic_filter: []const u8, qos: QoS) !void;
//!     pub fn poll(self: *MqttClient) !?Message;
//!     pub fn disconnect(self: *MqttClient) void;
//! };
//! 
//! pub const QoS = enum(u2) { at_most_once = 0, at_least_once = 1, exactly_once = 2 };
//! 
//! pub const ConnectOpts = struct {
//!     clean_start: bool = true,
//!     keep_alive_sec: u16 = 60,
//!     username: ?[]const u8 = null,
//!     password: ?[]const u8 = null,
//!     will_topic: ?[]const u8 = null,
//!     will_payload: ?[]const u8 = null,
//!     tls: bool = false,
//! };
//! ```
//! 
//! **Key properties**:
//! - Zero allocation in hot path (publish/subscribe)
//! - Fixed 64KB accumulator for packet reassembly
//! - MQTT 5.0 properties support (topic alias, user properties)
//! - Will message for device death certificates (Sparkplug B)
//! 
//! ### 2. `sparkplug.zig` — Sparkplug B Codec
//! 
//! Sparkplug B topic namespace + Protobuf payload encoding.
//! State management (NBIRTH/NDEATH/DBIRTH/DDEATH/DDATA).
//! 
//! ```zig
//! pub const SparkplugTopic = struct {
//!     namespace: []const u8 = "spBv1.0",
//!     group_id: []const u8,       // e.g. "plurigrid"
//!     message_type: MessageType,   // NBIRTH, NDEATH, DBIRTH, DDEATH, DDATA, DCMD
//!     edge_node_id: []const u8,   // e.g. "microinverter-001"
//!     device_id: ?[]const u8,     // e.g. "panel-A3"
//! 
//!     pub fn format(self: SparkplugTopic, buf: []u8) []const u8;
//!     // → "spBv1.0/plurigrid/DDATA/microinverter-001/panel-A3"
//! };
//! 
//! pub const MessageType = enum {
//!     NBIRTH, NDEATH, DBIRTH, DDEATH, DDATA, DCMD, NCMD, STATE,
//! };
//! 
//! pub const Metric = struct {
//!     name: []const u8,
//!     timestamp: u64,          // epoch ms
//!     datatype: DataType,
//!     value: MetricValue,
//!     // GF(3) extension: trit classification
//!     trit: ?Trit = null,
//! };
//! 
//! /// Protobuf-lite encoding (Sparkplug B payload)
//! pub fn encodePayload(metrics: []const Metric, buf: []u8) !usize;
//! pub fn decodePayload(buf: []const u8, metrics: []Metric) !usize;
//! ```
//! 
//! **Topic hierarchy for Plurigrid**:
//! ```
//! spBv1.0/plurigrid/NBIRTH/site-001          # Edge node birth
//! spBv1.0/plurigrid/DBIRTH/site-001/inv-A    # Microinverter birth
//! spBv1.0/plurigrid/DDATA/site-001/inv-A     # Telemetry data
//! spBv1.0/plurigrid/DCMD/site-001/inv-A      # Command to inverter
//! spBv1.0/plurigrid/NDEATH/site-001          # Edge node death
//! ```
//! 
//! ### 3. `sunspec_modbus.zig` — SunSpec Modbus Register Maps
//! 
//! SunSpec-compliant Modbus TCP client for inverter/battery/meter
//! communication. Register map definitions per SunSpec Information Models.
//! 
//! ```zig
//! pub const SunSpecModel = enum(u16) {
//!     common = 1,            // Manufacturer, model, serial
//!     inverter_single = 101, // Single phase inverter
//!     inverter_split = 102,  // Split phase
//!     inverter_three = 103,  // Three phase
//!     nameplate = 120,       // DER nameplate ratings
//!     settings = 121,        // DER settings (Vref, Wmax)
//!     status = 122,          // DER status
//!     controls = 123,        // DER controls (connect/disconnect)
//!     storage = 124,         // Storage model (battery)
//!     pricing = 125,         // Pricing signals
//!     mppt = 160,            // MPPT extension (per-string)
//! };
//! 
//! pub const ModbusClient = struct {
//!     stream: net.Stream,
//!     unit_id: u8,
//! 
//!     pub fn readHolding(self: *ModbusClient, addr: u16, count: u16, buf: []u16) !void;
//!     pub fn writeSingle(self: *ModbusClient, addr: u16, value: u16) !void;
//!     pub fn writeMultiple(self: *ModbusClient, addr: u16, values: []const u16) !void;
//! };
//! 
//! /// Read a complete SunSpec model from an inverter
//! pub fn readModel(client: *ModbusClient, model: SunSpecModel, buf: []u8) !ModelData;
//! 
//! /// Common model (1): manufacturer, model, serial, firmware version
//! pub const CommonModel = struct {
//!     manufacturer: [32]u8,
//!     model: [32]u8,
//!     serial: [32]u8,
//!     fw_version: [16]u8,
//!     // ... SBOM fields for supply chain attestation
//! };
//! 
//! /// Inverter model (101-103): real-time AC power, energy, voltage, current
//! pub const InverterModel = struct {
//!     ac_power_w: i16,
//!     ac_energy_wh: u32,
//!     ac_voltage_v: u16,    // scale factor applied
//!     ac_current_a: u16,
//!     dc_power_w: i16,
//!     dc_voltage_v: u16,
//!     dc_current_a: u16,
//!     cabinet_temp_c: i16,
//!     operating_state: OperatingState,
//!     // GF(3) classification derived from power flow
//!     trit: Trit,
//! };
//! ```
//! 
//! ### 4. `ieee2030_5.zig` — IEEE 2030.5 / CSIP Client
//! 
//! Smart Energy Profile 2.0 client for DER-to-utility communication.
//! RESTful HTTP/TLS with EXI (Efficient XML Interchange) encoding.
//! 
//! ```zig
//! pub const Sep2Client = struct {
//!     allocator: Allocator,
//!     base_url: [256]u8,
//!     tls_cert: ?[]const u8,     // mTLS client certificate
//!     tls_key: ?[]const u8,
//! 
//!     /// Discover available function sets
//!     pub fn getDeviceCapability(self: *Sep2Client) !DeviceCapability;
//! 
//!     /// Read DER program list
//!     pub fn getDerProgramList(self: *Sep2Client) ![]DerProgram;
//! 
//!     /// Submit DER status
//!     pub fn postDerStatus(self: *Sep2Client, status: DerStatus) !void;
//! 
//!     /// Read pricing signals
//!     pub fn getPricing(self: *Sep2Client) ![]PricingSignal;
//! };
//! 
//! pub const DerProgram = struct {
//!     description: []const u8,
//!     default_control: DerControl,
//!     primacy: u8,            // priority (lower = higher priority)
//! };
//! 
//! pub const DerControl = struct {
//!     mode: ControlMode,
//!     op_mod_connect: bool,
//!     op_mod_energize: bool,
//!     op_mod_max_w: ?f32,     // max watts setpoint
//!     op_mod_pf: ?f32,        // power factor
//!     op_mod_var: ?f32,       // reactive power
//!     // GF(3): generation(+), curtailment(-), passthrough(0)
//!     trit: Trit,
//! };
//! ```
//! 
//! ### 5. `energy_classifier.zig` — Unified GF(3) Energy Classifier
//! 
//! Cross-protocol energy classification. Every device, every protocol,
//! every reading maps to the same GF(3) trit taxonomy.
//! 
//! ```zig
//! /// Energy flow classification across all device types
//! pub const EnergyFlow = enum {
//!     /// +1 GENERATOR: producing/exporting energy
//!     generating,
//!     /// 0 ERGODIC: passthrough, balanced, idle
//!     ergodic,
//!     /// -1 VALIDATOR: consuming, curtailing, validating
//!     validating,
//! 
//!     pub fn toTrit(self: EnergyFlow) Trit { ... }
//! };
//! 
//! /// Classify any power reading
//! pub fn classify(watts: f32, context: DeviceContext) EnergyFlow {
//!     return switch (context.device_type) {
//!         .solar_inverter => if (watts > 10) .generating
//!                           else if (watts < -10) .validating
//!                           else .ergodic,
//!         .battery => if (watts > 0) .generating      // discharging
//!                     else if (watts < 0) .validating  // charging
//!                     else .ergodic,
//!         .ev_charger => if (watts > 0) .validating    // drawing power
//!                        else .ergodic,
//!         .smart_plug => if (watts > context.threshold_high) .generating
//!                        else if (watts < context.threshold_low) .validating
//!                        else .ergodic,
//!         .microinverter => if (watts > 5) .generating
//!                           else .ergodic,
//!     };
//! }
//! 
//! /// Device types in the smart energy taxonomy
//! pub const DeviceType = enum {
//!     solar_inverter,
//!     microinverter,
//!     battery,
//!     ev_charger,
//!     smart_plug,
//!     smart_meter,
//!     heat_pump,
//!     hvac,
//!     warehouse_ups,
//!     grid_tie,
//! };
//! 
//! /// Site-level GF(3) balance
//! pub const SiteBalance = struct {
//!     generators: u32,       // count of +1 devices
//!     ergodic: u32,          // count of 0 devices
//!     validators: u32,       // count of -1 devices
//!     net_trit: i32,         // running sum
//!     total_watts: f32,
//!     net_export_watts: f32, // positive = exporting to grid
//! 
//!     pub fn isBalanced(self: SiteBalance) bool {
//!         return self.net_trit == 0;
//!     }
//! 
//!     pub fn toSyrup(self: SiteBalance, allocator: Allocator) !syrup.Value;
//! };
//! ```
//! 
//! ### 6. `sbom_attestation.zig` — Supply Chain Verification
//! 
//! Hardware/firmware Bill of Materials verification. Every device must
//! prove its provenance. Inspired by IEC 61850 Subs-BOM (CycloneDX).
//! 
//! ```zig
//! /// Device attestation record
//! pub const DeviceAttestation = struct {
//!     /// Manufacturer identity (from SunSpec Common Model or device cert)
//!     manufacturer: [64]u8,
//!     model: [64]u8,
//!     serial: [64]u8,
//!     firmware_version: [32]u8,
//! 
//!     /// SHA-256 of firmware binary (if readable)
//!     firmware_hash: [32]u8,
//! 
//!     /// Country of manufacture (ISO 3166-1)
//!     country_of_origin: [3]u8,
//! 
//!     /// TLS certificate fingerprint
//!     tls_cert_fingerprint: [32]u8,
//! 
//!     /// Known-good firmware hash list (from vendor or auditor)
//!     expected_fw_hash: ?[32]u8,
//! 
//!     /// Rogue hardware detection: unexpected network interfaces
//!     unexpected_interfaces: u8,
//! 
//!     /// Attestation result
//!     pub fn verify(self: *const DeviceAttestation) AttestationResult {
//!         // Check firmware hash matches expected
//!         if (self.expected_fw_hash) |expected| {
//!             if (!std.mem.eql(u8, &self.firmware_hash, &expected))
//!                 return .firmware_mismatch;
//!         }
//!         // Check for rogue communication hardware
//!         if (self.unexpected_interfaces > 0)
//!             return .rogue_hardware_detected;
//!         return .verified;
//!     }
//! };
//! 
//! pub const AttestationResult = enum {
//!     verified,
//!     firmware_mismatch,
//!     rogue_hardware_detected,
//!     certificate_invalid,
//!     country_restricted,
//!     unverifiable,
//! 
//!     pub fn toTrit(self: AttestationResult) Trit {
//!         return switch (self) {
//!             .verified => .plus,          // +1 trusted
//!             .unverifiable => .zero,      // 0 unknown
//!             else => .minus,              // -1 failed
//!         };
//!     }
//! };
//! ```
//! 
//! ### 7. `matter_bridge.zig` — Matter 1.4 Energy Device Bridge
//! 
//! Bridge between Matter energy device types and zig-syrup.
//! Matter 1.4 adds: Solar Power, Battery Storage, EV Supply Equipment,
//! Device Energy Management, Water Heater Management.
//! 
//! ```zig
//! /// Matter 1.4 energy device clusters
//! pub const MatterCluster = enum(u32) {
//!     electrical_measurement = 0x0B04,
//!     electrical_energy_measurement = 0x0091,
//!     device_energy_management = 0x0098,
//!     device_energy_management_mode = 0x009F,
//!     energy_evse = 0x0099,
//!     energy_evse_mode = 0x009D,
//!     power_topology = 0x009C,
//! };
//! 
//! /// Read Matter device via local commissioning (BLE/Thread/WiFi)
//! pub const MatterBridge = struct {
//!     // Matter operates over Thread (802.15.4) or WiFi
//!     // We bridge via the Matter controller's local API
//!     controller_addr: net.Address,
//! 
//!     pub fn readElectricalMeasurement(self: *MatterBridge, node_id: u64) !ElectricalMeasurement;
//!     pub fn readEnergyManagement(self: *MatterBridge, node_id: u64) !EnergyManagement;
//!     pub fn setEvseCurrent(self: *MatterBridge, node_id: u64, max_amps: u16) !void;
//! };
//! ```
//! 
//! ### 8. `openadr.zig` — OpenADR 3.0 Client
//! 
//! Demand response event subscription and dispatch.
//! 
//! ```zig
//! pub const AdrClient = struct {
//!     base_url: [256]u8,
//!     ven_id: []const u8,     // Virtual End Node ID
//! 
//!     /// Register as VEN (Virtual End Node)
//!     pub fn register(self: *AdrClient) !void;
//! 
//!     /// Poll for DR events
//!     pub fn getEvents(self: *AdrClient) ![]DemandResponseEvent;
//! 
//!     /// Report opt-in/opt-out status
//!     pub fn reportStatus(self: *AdrClient, event_id: []const u8, status: OptStatus) !void;
//! };
//! 
//! pub const DemandResponseEvent = struct {
//!     event_id: []const u8,
//!     signal_type: SignalType,     // LEVEL, PRICE, LOAD_CONTROL
//!     signal_value: f32,
//!     start_time: u64,
//!     duration_sec: u32,
//!     // GF(3): curtail(-1), normal(0), generate(+1)
//!     trit: Trit,
//! };
//! ```
//! 
//! ---
//! 
//! ## MQTT Topic Namespace for Plurigrid
//! 
//! ```
//! # Sparkplug B structure
//! spBv1.0/plurigrid/NBIRTH/{site_id}                    # Site comes online
//! spBv1.0/plurigrid/DBIRTH/{site_id}/{device_id}        # Device birth
//! spBv1.0/plurigrid/DDATA/{site_id}/{device_id}         # Telemetry
//! spBv1.0/plurigrid/DCMD/{site_id}/{device_id}          # Commands
//! spBv1.0/plurigrid/NDEATH/{site_id}                    # Site death
//! 
//! # Plurigrid extensions (under spBv1.0 namespace)
//! spBv1.0/plurigrid/DDATA/{site_id}/{device_id}/gf3     # GF(3) trit stream
//! spBv1.0/plurigrid/DDATA/{site_id}/{device_id}/sbom    # Attestation
//! spBv1.0/plurigrid/DDATA/{site_id}/balance              # Site GF(3) balance
//! 
//! # Device examples
//! spBv1.0/plurigrid/DDATA/warehouse-sf/inv-001           # Microinverter
//! spBv1.0/plurigrid/DDATA/warehouse-sf/batt-001          # Battery
//! spBv1.0/plurigrid/DDATA/warehouse-sf/evse-001          # EV charger
//! spBv1.0/plurigrid/DDATA/warehouse-sf/plug-tapo-001     # Smart outlet
//! spBv1.0/plurigrid/DDATA/warehouse-sf/meter-001         # Smart meter
//! 
//! # Site-level aggregation
//! spBv1.0/plurigrid/DDATA/warehouse-sf/site-balance      # GF(3) conservation
//! # Payload: {generators: N, ergodic: M, validators: K, net_trit: 0, watts: ...}
//! ```
//! 
//! ---
//! 
//! ## GF(3) Conservation Across the Smart Energy Stack
//! 
//! ```
//! L14: Physical Energy Layer (this module)
//!   + generation (solar/wind/battery discharge)
//!   ○ passthrough (grid-tied, balanced)
//!   − consumption (load/charging/curtailment)
//! 
//! Conservation law at every scale:
//!   Device:    Σ(trit per reading over time) → 0 (charge/discharge balance)
//!   Site:      Σ(trit per device) → 0 (generation matches consumption)
//!   Grid:      Σ(trit per site) → 0 (supply equals demand)
//! 
//! The GF(3) invariant is the energy balance equation in algebraic form.
//! Generation - Consumption = ΔStorage
//!     (+1)    -    (-1)     =    (0)
//! ```
//! 
//! ---
//! 
//! ## Supply Chain Security Model
//! 
//! ### The "18 Eyes" Audit Trail
//! 
//! 1. **Hardware attestation** (sbom_attestation.zig)
//!    - Firmware hash verification against known-good list
//!    - Network interface enumeration (detect rogue radios)
//!    - Certificate chain validation (no self-signed in production)
//!    - Country-of-origin check (configurable restricted list)
//! 
//! 2. **Protocol verification** (every module)
//!    - All traffic Syrup-serializable for audit replay
//!    - No proprietary binary blobs in wire protocol
//!    - Every command/response logged with CID (content-addressed)
//! 
//! 3. **Runtime monitoring** (propagator network)
//!    - Anomaly detection via propagator contradiction cells
//!    - Unexpected traffic patterns → contradiction → alert
//!    - GF(3) imbalance beyond threshold → investigate
//! 
//! ### What Even Huawei Cannot Sneak Past:
//! 
//! ```
//! Device connects → SBOM check
//!   ├─ Firmware hash ≠ expected → BLOCK
//!   ├─ Rogue interfaces detected → BLOCK
//!   ├─ Certificate from restricted CA → BLOCK
//!   └─ All clear → ADMIT with continuous monitoring
//!        ├─ Traffic patterns logged (Syrup CID)
//!        ├─ GF(3) conservation checked per cycle
//!        ├─ Propagator contradiction → isolate device
//!        └─ All readings auditable, replayable, verifiable
//! ```
//! 
//! ---
//! 
//! ## Implementation Priority
//! 
//! | Phase | Module | LOC est. | Deps |
//! |-------|--------|----------|------|
//! | **1** | `mqtt_client.zig` | 800 | tcp_transport |
//! | **1** | `sparkplug.zig` | 400 | mqtt_client, syrup |
//! | **2** | `sunspec_modbus.zig` | 600 | tcp_transport |
//! | **2** | `energy_classifier.zig` | 300 | continuation (Trit) |
//! | **3** | `sbom_attestation.zig` | 400 | crypto, syrup |
//! | **3** | `matter_bridge.zig` | 500 | tcp_transport, syrup |
//! | **4** | `ieee2030_5.zig` | 700 | http/tls, syrup |
//! | **4** | `openadr.zig` | 400 | http/tls, syrup |
//! 
//! Total: ~4,100 LOC across 8 modules
//! 
//! ### What Already Exists:
//! - `tapo_energy.zig` (680 LOC) — Tapo P15 smart plug driver ✅
//! - `tcp_transport.zig` — Framed TCP connections ✅
//! - `message_frame.zig` — Length-prefix framing ✅
//! - `propagator.zig` — Constraint propagation ✅
//! - `syrup.zig` — Serialization ✅
//! - `continuation.zig` — GF(3) Trit type ✅
//! 
//! ---
//! 
//! ## References
//! 
//! - [IEEE 2030.5 / SunSpec CSIP](https://sunspec.org/ieee-2030-5-csip-certification/)
//! - [OpenADR 3 ↔ Matter interworking spec](https://geotogether.com/wp-content/uploads/2025/04/Matter_OpenADR3.x_Interworking_Spec_v1.0.pdf)
//! - [Matter 1.4 energy management](https://csa-iot.org/newsroom/matter-1-4-enables-more-capable-smart-homes/)
//! - [Sparkplug B spec v2.2](https://sparkplug.eclipse.org/specification/version/2.2/documents/sparkplug-specification-2.2.pdf)
//! - [IEC 61850 Subs-BOM for supply chain](https://www.arxiv.org/pdf/2503.19638)
//! - [EU ISS: Dragon in the Grid](https://www.iss.europa.eu/publications/briefs/dragon-grid-limiting-chinas-influence-europes-energy-system)
//! - [Schneier: Backdoors in Chinese inverters](https://www.schneier.com/blog/archives/2025/05/communications-backdoor-in-chinese-power-inverters.html)
//! - [OpenDTU MQTT topics](https://www.opendtu.solar/firmware/mqtt_topics/)
//! - [Deye inverter MQTT bridge](https://github.com/kbialek/deye-inverter-mqtt)
//! - [SolarEdge2MQTT](https://github.com/DerOetzi/solaredge2mqtt)
//! 

const std = @import("std");
const syrup = @import("syrup.zig");
const lux_color = @import("lux_color.zig");
const Allocator = std.mem.Allocator;
const Trit = lux_color.Trit;

pub const CellId = u32;
pub const INVALID_CELL: CellId = 0xFFFFFFFF;

pub const CellTag = enum(u2) {
    mortal = 0,
    immortal = 1,
    phantom = 2,
    frozen = 3,
};

pub const SLAB_SIZE: usize = 1 << 16;

pub const CellSlab = struct {
    ranks: [SLAB_SIZE]u8,
    trits: [SLAB_SIZE]i8,
    tags: [SLAB_SIZE]u2,
    energy_k: [SLAB_SIZE]f32,
    energy_p: [SLAB_SIZE]f32,
    members_inline: [SLAB_SIZE][8]CellId,
    members_count: [SLAB_SIZE]u8,
    members_overflow: [SLAB_SIZE]?[*]CellId,
    payload_offset: [SLAB_SIZE]u32,
    states: [SLAB_SIZE]std.atomic.Value(u8),
    live_count: std.atomic.Value(u32),

    pub fn init() CellSlab {
        var slab: CellSlab = undefined;
        @memset(&slab.ranks, 0);
        @memset(&slab.trits, 0);
        @memset(&slab.tags, 0);
        @memset(&slab.energy_k, 0);
        @memset(&slab.energy_p, 0);
        @memset(&slab.members_count, 0);
        for (&slab.members_overflow) |*p| p.* = null;
        @memset(&slab.payload_offset, 0);
        for (&slab.states) |*s| s.* = std.atomic.Value(u8).init(0);
        slab.live_count = std.atomic.Value(u32).init(0);
        return slab;
    }
};

pub const CombinatorialComplex = struct {
    const Self = @This();

    slabs: std.ArrayListUnmanaged(*CellSlab) = .{},
    next_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_rank: u8 = 0,
    trit_sum: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    allocator: Allocator,
    rank_index: [256]std.ArrayListUnmanaged(CellId) = [_]std.ArrayListUnmanaged(CellId){.{}} ** 256,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.slabs.items) |slab| {
            self.allocator.destroy(slab);
        }
        self.slabs.deinit(self.allocator);
        for (&self.rank_index) |*list| list.deinit(self.allocator);
    }

    fn ensureSlab(self: *Self, slab_idx: usize) !void {
        while (self.slabs.items.len <= slab_idx) {
            const slab = try self.allocator.create(CellSlab);
            slab.* = CellSlab.init();
            try self.slabs.append(self.allocator, slab);
        }
    }

    inline fn slabOf(id: CellId) usize { return id / SLAB_SIZE; }
    inline fn offsetOf(id: CellId) usize { return id % SLAB_SIZE; }

    pub fn addVertex(self: *Self, trit: Trit) !CellId {
        const id = self.next_id.fetchAdd(1, .monotonic);
        try self.ensureSlab(slabOf(id));
        const slab = self.slabs.items[slabOf(id)];
        const off = offsetOf(id);
        slab.ranks[off] = 0;
        slab.trits[off] = @intFromEnum(trit);
        slab.tags[off] = @intFromEnum(CellTag.mortal);
        slab.members_count[off] = 0;
        _ = slab.live_count.fetchAdd(1, .monotonic);
        _ = self.trit_sum.fetchAdd(@intFromEnum(trit), .monotonic);
        try self.rank_index[0].append(self.allocator, id);
        return id;
    }

    pub fn addCell(self: *Self, rank: u8, trit: Trit, members: []const CellId) !CellId {
        const id = self.next_id.fetchAdd(1, .monotonic);
        try self.ensureSlab(slabOf(id));
        const slab = self.slabs.items[slabOf(id)];
        const off = offsetOf(id);
        slab.ranks[off] = rank;
        slab.trits[off] = @intFromEnum(trit);
        slab.tags[off] = @intFromEnum(CellTag.mortal);
        const n: u8 = @intCast(@min(members.len, 255));
        slab.members_count[off] = n;
        for (0..@min(n, 8)) |i| {
            slab.members_inline[off][i] = members[i];
        }
        if (n > 8) {
            const overflow = try self.allocator.alloc(CellId, n - 8);
            @memcpy(overflow, members[8..n]);
            slab.members_overflow[off] = overflow.ptr;
        }
        _ = slab.live_count.fetchAdd(1, .monotonic);
        _ = self.trit_sum.fetchAdd(@intFromEnum(trit), .monotonic);
        if (rank > self.max_rank) self.max_rank = rank;
        try self.rank_index[rank].append(self.allocator, id);
        return id;
    }

    pub fn getRank(self: *const Self, id: CellId) u8 { return self.slabs.items[slabOf(id)].ranks[offsetOf(id)]; }
    pub fn getTrit(self: *const Self, id: CellId) Trit { return @enumFromInt(self.slabs.items[slabOf(id)].trits[offsetOf(id)]); }
    pub fn getTag(self: *const Self, id: CellId) CellTag { return @enumFromInt(self.slabs.items[slabOf(id)].tags[offsetOf(id)]); }
    pub fn cellCount(self: *const Self) u32 { return self.next_id.load(.monotonic); }
    pub fn isConserved(self: *const Self) bool { return @mod(self.trit_sum.load(.monotonic), 3) == 0; }

    pub fn eulerCharacteristic(self: *const Self) i64 {
        var chi: i64 = 0;
        for (0..self.max_rank + 1) |k| {
            const count: i64 = @intCast(self.rank_index[k].items.len);
            if (k % 2 == 0) chi += count else chi -= count;
        }
        return chi;
    }
};

pub const BitVec = struct {
    words: []u64,
    len: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, len: usize) !BitVec {
        const nwords = (len + 63) / 64;
        const words = try allocator.alloc(u64, nwords);
        @memset(words, 0);
        return .{ .words = words, .len = len, .allocator = allocator };
    }
    pub fn deinit(self: *BitVec) void { self.allocator.free(self.words); }
    pub fn set(self: *BitVec, idx: usize) void { self.words[idx / 64] |= @as(u64, 1) << @intCast(idx % 64); }
    pub fn xorWith(self: *BitVec, other: *const BitVec) void { for (self.words, other.words) |*a, b| a.* ^= b; }
};

pub const SkillTile = struct {
    cell_id: CellId,
    name: []const u8,
    trit: Trit,
    rank: u8,
    mortal: bool,
};

test "tiling construction" {
    const allocator = std.testing.allocator;
    var cc = CombinatorialComplex.init(allocator);
    defer cc.deinit();
    const v0 = try cc.addVertex(.minus);
    const v1 = try cc.addVertex(.ergodic);
    const v2 = try cc.addVertex(.plus);
    try std.testing.expect(cc.isConserved());
    _ = v0; _ = v1; _ = v2;
}
