# Documentation Gaps: Zig-Syrup vs Reality

## Status Overview
- **DeepWiki**: Stale (~12 modules).
- **README.md**: Mostly accurate (~52 modules), but misses recent "Control Surface" and "Worlding" expansions.
- **Codebase**: ~75+ modules.

## Critical Omissions in README.md

### 1. Terminal Control Surfaces
The entire "Retty" (Ratatui-in-Zig) stack is undocumented, despite being the primary UI engine for new tools.
- `src/retty.zig`: Constraint-based layout engine (Ratatui port).
- `src/transient.zig`: Emacs-style popup menus with GF(3) trit coloring.
- `src/tileable_shader.zig`: New shader composition system.

### 2. Ihara-Hashimoto / Zeta World
The spectral graph theory visualization tools are completely absent.
- `src/zeta_cli.zig`: Standalone CLI for spectral analysis.
- `src/worlds/zeta/`: Ihara-Hashimoto zeta function logic and widgets.

### 3. Advanced Math & Physics
Several key theoretical modules are implemented but not listed.
- `src/goi.zig`: Geometry of Interaction (Linear Logic).
- `src/hyperreal.zig`: Non-standard analysis (Infinitesimals).
- `src/entangle.zig`: Quantum/Topological entanglement structures.
- `src/supermap.zig`: Higher-order process maps.

### 4. Worlds Subsystem Expansion
The `worlds/` directory has grown beyond the listed set.
- `src/worlds/ewig/`: "Eternal" persistent storage (likely Ewig/Immer port).
- `src/worlds/multiplayer.zig`: Multiplayer session state.
- `src/worlds/colored_parens.zig`: Syntax highlighting/structure demos.

### 5. Utilities
- `src/zoad.zig`: Toad/Zoad integration?
- `src/gf3_palette.zig`: New specialized color palette generator.

## ALife Integration Status (vs Skill)
The "ALife" skill concepts (Lenia, ALIEN, Concordia) are **not yet implemented** as concrete worlds, though the infrastructure (`retty`, `propagator`, `spectral_tensor`) supports them.
- **Lenia**: No explicit `lenia.zig`.
- **ALIEN**: No CUDA bindings found.
- **Concordia**: No GABM agent logic found.

## Autopoiesis Configuration
- **Status**: Enforced.
- **Rule**: Trifurcation-First (SplitMixTernary).
- **Location**: `.ruler/trifurcation-enforcer.cljs`

## SICMUtils / Emmy Integration
- **Status**: Scaffolded in `dscloj`.
- **Bridge**: `dscloj/src/sicmutils/srfi_bridge/` implements Cat# bicomodules (ListAlgebra, RNGBridge, LazyDiff, PhaseXduce).
- **Verification**: `verify_trit_balance.bb` confirms GF(3) conservation.
- **Execution**: `dscloj/examples/sicm_demo.clj` runs successfully (using mocks for heavy Emmy deps).
- **Role**: Provides "Physics" (+1) capability for thermodynamic simulations.
