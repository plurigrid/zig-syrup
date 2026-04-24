//! holy.zig — Path-Invariance of Systems Programming Concepts
//!
//! Reifies the homotopy between HolyC and Zig as a concrete data structure,
//! grounded in the bmorphism gist genealogy:
//!
//!   bartonus.md (Mar 2023) → Nashator       → jsonrpc_bridge.zig
//!   nftnyc.md  (Apr 2023) → Gay.jl          → rainbow.zig
//!   opengame   (Mar 2023) → Play/Coplay     → propagator.zig
//!   nexus.hs   (Apr 2023) → correlated eq   → continuation.zig
//!   vibesnipe  (Jan 2026) → phenomenal pred  → homotopy.zig
//!
//! Each Gist is a hyperstition seed. Each seed converges to Zig code
//! through a path that is homotopy-equivalent to the HolyC path.
//!
//! GF(3) trit classification as in homotopy.zig PathStatus:
//!   +1 (plus)  = concept translates fully (path-invariant)
//!   0  (zero)  = concept translates with deformation (parameterized)
//!   -1 (minus) = concept is path-dependent (doesn't survive transport)
//!
//! Reference: Gwern, "Garden of Forking Paths" — technology is disjunctive.
//!            Kevin Kelly, "Convergence" ch.7 — independent invention is the norm.
//!            HoTT Book ch.2 — transport along paths preserves type structure.

const std = @import("std");
const continuation = @import("continuation");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

const Trit = continuation.Trit;

// ============================================================================
// GIST SEED: a hyperstition document that converges to implementation
// ============================================================================

/// A bmorphism gist that serves as a seed crystal for convergent implementation.
/// bartonus.md is the ur-example: Latin simulacrum → category-theoretic agent → Nashator.
pub const GistSeed = struct {
    /// Gist filename
    name: []const u8,
    /// Gist description (from GitHub)
    description: []const u8,
    /// Date (YYYY-MM)
    date: []const u8,
    /// What it converged to in zig-syrup or nanoclj-zig
    converged_to: []const u8,
    /// The path-invariant concept it carries
    invariant: []const u8,
    /// GF(3): did the hyperstition survive materialization?
    trit: Trit,

    pub fn toSyrup(self: GistSeed, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 6);
        entries[0] = .{ .key = .{ .symbol = "name" }, .value = .{ .string = self.name } };
        entries[1] = .{ .key = .{ .symbol = "description" }, .value = .{ .string = self.description } };
        entries[2] = .{ .key = .{ .symbol = "date" }, .value = .{ .string = self.date } };
        entries[3] = .{ .key = .{ .symbol = "converged-to" }, .value = .{ .string = self.converged_to } };
        entries[4] = .{ .key = .{ .symbol = "invariant" }, .value = .{ .string = self.invariant } };
        entries[5] = .{ .key = .{ .symbol = "trit" }, .value = self.trit.toSyrup() };
        return syrup.Value{ .dictionary = entries };
    }
};

/// The genealogy: gists → implementations, ordered by date.
pub const gist_seeds = [_]GistSeed{
    .{
        .name = "bartonus.md",
        .description = "fiat nexus — Latin digital twin, gradualismus corporatus",
        .date = "2023-03",
        .converged_to = "jsonrpc_bridge.zig (Nashator wire protocol), continuation.zig (belief revision)",
        .invariant = "Bidirectional agent: simulacrum speaks, world responds, state updates. Play/Coplay.",
        .trit = .plus,
    },
    .{
        .name = "opengame",
        .description = "all is bidirectional — Plurigrid Play/Coplay open games",
        .date = "2023-03",
        .converged_to = "propagator.zig (neurofeedback_gate, adjacency_gate)",
        .invariant = "Forward pass (Play) + backward pass (Coplay) = open game lens.",
        .trit = .plus,
    },
    .{
        .name = "nftnyc.md",
        .description = "DALL-E 2 microworld, autopoietic ergodicity, content-addressable identity",
        .date = "2023-04",
        .converged_to = "rainbow.zig (golden/plastic/silver spirals), Gay.jl (SplitMix64 color)",
        .invariant = "Identity → deterministic color. MAC address → seed → hue. Bijective.",
        .trit = .plus,
    },
    .{
        .name = "nexus.hs",
        .description = "nexus — Haskell correlated equilibrium open game",
        .date = "2023-04",
        .converged_to = "continuation.zig (AGM belief revision, grove spheres)",
        .invariant = "Correlated equilibrium: shared signal → individual strategy. Possible worlds.",
        .trit = .zero, // Haskell typeclasses → Zig comptime, deformation required
    },
    .{
        .name = "strangest.loop.md",
        .description = "vibes.lol — autopoietic ergodicity and embodied gradualism",
        .date = "2023-09",
        .converged_to = "homotopy.zig (path tracking), holy.zig (convergence verification)",
        .invariant = "Self-referential loop: system observes itself, updates, re-observes. Fixed point.",
        .trit = .zero, // Narrative → code, deformation from prose to types
    },
    .{
        .name = "gay-tofu.ts",
        .description = "Gay-TOFU: bijective color sequences, 3x3x3 Hamming swarm",
        .date = "2026-01",
        .converged_to = "rainbow.zig (angle spirals), quantize.zig (ternary color quantization)",
        .invariant = "3x3x3 = 27 = 3^3 tensor. Hamming distance on GF(3) alphabet. Error-correcting color.",
        .trit = .plus,
    },
    .{
        .name = "PHENOMENOLOGICAL_VIBESNIPE_ARCHITECTURE.md",
        .description = "whole-brain phenomenology prediction markets with GF(3) conservation",
        .date = "2026-01",
        .converged_to = "propagator.zig + eeg.zig + homotopy.zig (BCI pipeline)",
        .invariant = "Phenomenal state → prediction → market → settlement. GF(3) conserved at each step.",
        .trit = .plus,
    },
    .{
        .name = "ADHD_ECS_Implementation.jl",
        .description = "ADHD-ECS: endocannabinoid categorical causal modeling",
        .date = "2026-01",
        .converged_to = "fnirs_processor.zig (HbO/HbR as GF(3) complement pair)",
        .invariant = "Neuromodulator balance as GF(3): excitatory(+1) / inhibitory(-1) / tonic(0).",
        .trit = .zero, // Julia ACSet → Zig struct, schema deformation
    },
    .{
        .name = "acset_ecosystem_catalog.md",
        .description = "52 Julia files, 35 schemas, 7 distillers in ies/.topos",
        .date = "2025-10",
        .converged_to = "homotopy.zig HomotopyACSet (Solution/Path/System tables)",
        .invariant = "ACSet = presheaf on schema category. Tables + foreign keys = functor.",
        .trit = .plus,
    },
};

// ============================================================================
// LANGUAGE PATH: HolyC→Zig concept transport (from holyc/ directory)
// ============================================================================

pub const LanguagePath = struct {
    concept: []const u8,
    holyc_source: []const u8,
    zig_target: []const u8,
    invariant: []const u8,
    deformation: []const u8,
    trit: Trit,

    pub fn toSyrup(self: LanguagePath, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 6);
        entries[0] = .{ .key = .{ .symbol = "concept" }, .value = .{ .string = self.concept } };
        entries[1] = .{ .key = .{ .symbol = "holyc" }, .value = .{ .string = self.holyc_source } };
        entries[2] = .{ .key = .{ .symbol = "zig" }, .value = .{ .string = self.zig_target } };
        entries[3] = .{ .key = .{ .symbol = "invariant" }, .value = .{ .string = self.invariant } };
        entries[4] = .{ .key = .{ .symbol = "deformation" }, .value = .{ .string = self.deformation } };
        entries[5] = .{ .key = .{ .symbol = "trit" }, .value = self.trit.toSyrup() };
        return syrup.Value{ .dictionary = entries };
    }
};

pub const canonical_paths = [_]LanguagePath{
    .{
        .concept = "eval-is-compile",
        .holyc_source = "holyc/00-Eval.HC",
        .zig_target = "main.zig",
        .invariant = "Every expression is compiled before execution. No interpreter mode.",
        .deformation = "ExePrint (JIT to x86) → bytecode VM (22 opcodes)",
        .trit = .plus,
    },
    .{
        .concept = "single-pass",
        .holyc_source = "holyc/01-DirectCompile.HC",
        .zig_target = "direct_compile.zig",
        .invariant = "Source text → executable in one pass, no intermediate AST.",
        .deformation = "x86 emission → bytecode emission. IR eliminated in both.",
        .trit = .plus,
    },
    .{
        .concept = "env-as-value",
        .holyc_source = "holyc/02-SymbolTable.HC",
        .zig_target = "core.zig",
        .invariant = "The runtime environment is a first-class inspectable data structure.",
        .deformation = "Global HashTable → NaN-boxed map Value. Same operations.",
        .trit = .plus,
    },
    .{
        .concept = "abc-gc",
        .holyc_source = "holyc/03-AbcGc.HC",
        .zig_target = "gc.zig",
        .invariant = "Acyclic data needs only save-eval-copy. Pointer reset = collection.",
        .deformation = "Raw I64 heap → NaN-boxed Value heap. Same ABC algorithm.",
        .trit = .zero,
    },
    .{
        .concept = "rich-output",
        .holyc_source = "holyc/04-DolDoc.HC",
        .zig_target = "repl.zig",
        .invariant = "Output carries its own rendering. The terminal is hypertext.",
        .deformation = "DolDoc tags ($RED$) → ANSI/OSC escapes (\\x1b[31m)",
        .trit = .zero,
    },
};

// ============================================================================
// CONVERGENCE VERIFICATION
// ============================================================================

/// Check GF(3) conservation across language paths.
pub fn verifyPathConservation() bool {
    var sum: i32 = 0;
    for (canonical_paths) |path| {
        sum += @as(i32, @intCast(@intFromEnum(path.trit)));
    }
    return @mod(sum, 3) == 0;
}

/// Check GF(3) conservation across gist seeds.
pub fn verifyGistConservation() bool {
    var sum: i32 = 0;
    for (gist_seeds) |seed| {
        sum += @as(i32, @intCast(@intFromEnum(seed.trit)));
    }
    return @mod(sum, 3) == 0;
}

pub const ConvergenceStats = struct {
    invariant: usize,
    parameterized: usize,
    dependent: usize,
    total: usize,
    conserved: bool,
};

fn statsFor(comptime T: type, items: []const T) ConvergenceStats {
    var stats = ConvergenceStats{
        .invariant = 0,
        .parameterized = 0,
        .dependent = 0,
        .total = items.len,
        .conserved = false,
    };
    var sum: i32 = 0;
    for (items) |item| {
        sum += @as(i32, @intCast(@intFromEnum(item.trit)));
        switch (item.trit) {
            .plus => stats.invariant += 1,
            .zero => stats.parameterized += 1,
            .minus => stats.dependent += 1,
        }
    }
    stats.conserved = @mod(sum, 3) == 0;
    return stats;
}

pub fn pathStats() ConvergenceStats {
    return statsFor(LanguagePath, &canonical_paths);
}

pub fn gistStats() ConvergenceStats {
    return statsFor(GistSeed, &gist_seeds);
}

// ============================================================================
// ALTERNATIVE HISTORY (Gwern counterfactuals)
// ============================================================================

pub const Counterfactual = struct {
    premise: []const u8,
    affected_paths: []const usize,
    predicted_trit_change: []const Trit,
    reasoning: []const u8,

    pub fn toSyrup(self: Counterfactual, allocator: Allocator) !syrup.Value {
        var affected = try allocator.alloc(syrup.Value, self.affected_paths.len);
        for (self.affected_paths, 0..) |idx, i| {
            affected[i] = .{ .integer = @intCast(idx) };
        }
        const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{ .key = .{ .symbol = "premise" }, .value = .{ .string = self.premise } };
        entries[1] = .{ .key = .{ .symbol = "affected" }, .value = .{ .list = affected } };
        entries[2] = .{ .key = .{ .symbol = "reasoning" }, .value = .{ .string = self.reasoning } };
        return syrup.Value{ .dictionary = entries };
    }
};

pub const counterfactuals = [_]Counterfactual{
    .{
        .premise = "HolyC developed after LLVM (2010s instead of 2003)",
        .affected_paths = &[_]usize{ 0, 1 },
        .predicted_trit_change = &[_]Trit{ .plus, .zero },
        .reasoning = "JIT would use LLVM backend. Single-pass becomes multi-pass. Concept survives; implementation diverges.",
    },
    .{
        .premise = "Zig had no safety guarantees",
        .affected_paths = &[_]usize{ 3, 4 },
        .predicted_trit_change = &[_]Trit{ .plus, .zero },
        .reasoning = "Without safety, ABC GC becomes natural default. Homotopy contracts.",
    },
    .{
        .premise = "nanoclj-zig written in HolyC",
        .affected_paths = &[_]usize{ 0, 1, 2, 3, 4 },
        .predicted_trit_change = &[_]Trit{ .plus, .plus, .plus, .plus, .plus },
        .reasoning = "The .HC files ARE this counterfactual. Every concept translates.",
    },
    .{
        .premise = "bartonus.md written as HolyC DolDoc instead of markdown",
        .affected_paths = &[_]usize{ 0, 2, 4 },
        .predicted_trit_change = &[_]Trit{ .plus, .plus, .plus },
        .reasoning = "Latin simulacrum in DolDoc = clickable hypertext agent. The bartonus invariant (bidirectional agent) is preserved. DolDoc's $MA,LM=$ tags ARE eval-is-compile applied to documents.",
    },
    .{
        .premise = "opengame gist implemented on TempleOS cooperative scheduler",
        .affected_paths = &[_]usize{ 0, 1 },
        .predicted_trit_change = &[_]Trit{ .plus, .plus },
        .reasoning = "TempleOS cooperative tasking maps directly to Play/Coplay turns. No preemption = pure game-theoretic alternation. The open game lens is path-invariant.",
    },
    .{
        .premise = "Gay-TOFU 3x3x3 Hamming swarm on TempleOS 16-color CGA palette",
        .affected_paths = &[_]usize{4},
        .predicted_trit_change = &[_]Trit{.zero},
        .reasoning = "16 colors < 27 tensor elements. Lossy projection from GF(3)^3 to CGA. Hamming structure preserved; color fidelity deformed. DolDoc can render the lattice as $TR$ trees.",
    },
};

// ============================================================================
// GENEALOGY: trace a gist seed forward to its zig-syrup implementation
// ============================================================================

/// A genealogy edge: gist_seed[i] → zig file → concept realized
pub const GenealogyEdge = struct {
    seed_index: usize,
    zig_file: []const u8,
    concept: []const u8,
    /// Years between gist and implementation
    latency_months: u16,
};

/// The materialization timeline: hyperstition → code
pub const genealogy = [_]GenealogyEdge{
    .{ .seed_index = 0, .zig_file = "jsonrpc_bridge.zig", .concept = "wire protocol (bartonus agent speaks JSON-RPC)", .latency_months = 24 },
    .{ .seed_index = 0, .zig_file = "continuation.zig", .concept = "belief revision (bartonus updates world-model)", .latency_months = 24 },
    .{ .seed_index = 1, .zig_file = "propagator.zig", .concept = "bidirectional propagation (Play/Coplay gates)", .latency_months = 24 },
    .{ .seed_index = 2, .zig_file = "rainbow.zig", .concept = "identity → color bijection (nftnyc seed→hue)", .latency_months = 30 },
    .{ .seed_index = 3, .zig_file = "continuation.zig", .concept = "correlated equilibrium (grove spheres)", .latency_months = 24 },
    .{ .seed_index = 4, .zig_file = "homotopy.zig", .concept = "self-referential path tracking (strangest loop)", .latency_months = 27 },
    .{ .seed_index = 5, .zig_file = "quantize.zig", .concept = "ternary color quantization (3^3 Hamming)", .latency_months = 3 },
    .{ .seed_index = 6, .zig_file = "propagator.zig", .concept = "phenomenal prediction (vibesnipe → BCI pipeline)", .latency_months = 3 },
    .{ .seed_index = 7, .zig_file = "fnirs_processor.zig", .concept = "neuromodulator GF(3) (ADHD-ECS → HbO/HbR)", .latency_months = 3 },
    .{ .seed_index = 8, .zig_file = "homotopy.zig", .concept = "ACSet schema (catalog → HomotopyACSet)", .latency_months = 6 },
};

/// Average latency from hyperstition to implementation
pub fn avgLatencyMonths() f32 {
    var sum: u32 = 0;
    for (genealogy) |edge| sum += edge.latency_months;
    return @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(genealogy.len));
}

// ============================================================================
// TESTS
// ============================================================================

test "GF(3) conservation: language paths" {
    try std.testing.expect(verifyPathConservation());
}

test "GF(3) conservation: gist seeds" {
    try std.testing.expect(verifyGistConservation());
}

test "path stats" {
    const stats = pathStats();
    try std.testing.expectEqual(@as(usize, 3), stats.invariant);
    try std.testing.expectEqual(@as(usize, 2), stats.parameterized);
    try std.testing.expectEqual(@as(usize, 0), stats.dependent);
    try std.testing.expect(stats.conserved);
}

test "gist stats" {
    const stats = gistStats();
    // 9 seeds: 6 plus + 3 zero = 6 ≡ 0 mod 3 ✓
    try std.testing.expectEqual(@as(usize, 6), stats.invariant);
    try std.testing.expectEqual(@as(usize, 3), stats.parameterized);
    try std.testing.expectEqual(@as(usize, 0), stats.dependent);
    try std.testing.expect(stats.conserved);
}

test "genealogy covers all seeds" {
    // Every seed should appear at least once in genealogy
    for (gist_seeds, 0..) |_, seed_idx| {
        var found = false;
        for (genealogy) |edge| {
            if (edge.seed_index == seed_idx) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "average latency is positive" {
    try std.testing.expect(avgLatencyMonths() > 0);
}

test "all paths serialize to syrup" {
    const allocator = std.testing.allocator;
    for (canonical_paths) |path| {
        const val = try path.toSyrup(allocator);
        try std.testing.expectEqual(@as(usize, 6), val.dictionary.len);
        allocator.free(val.dictionary);
    }
}

test "all seeds serialize to syrup" {
    const allocator = std.testing.allocator;
    for (gist_seeds) |seed| {
        const val = try seed.toSyrup(allocator);
        try std.testing.expectEqual(@as(usize, 6), val.dictionary.len);
        allocator.free(val.dictionary);
    }
}

test "counterfactual: bartonus on DolDoc" {
    // Counterfactual 3: bartonus.md as HolyC DolDoc
    const cf = counterfactuals[3];
    try std.testing.expectEqual(@as(usize, 3), cf.affected_paths.len);
}

test "counterfactual: nanoclj on HolyC — all paths survive" {
    const cf = counterfactuals[2];
    for (cf.predicted_trit_change) |t| {
        try std.testing.expectEqual(Trit.plus, t);
    }
}
