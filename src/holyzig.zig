//! HolyZig Convergence: Path-Invariance of Systems Programming Concepts
//!
//! Reifies the homotopy between HolyC and Zig as a concrete data structure.
//! Each LanguagePath tracks a concept from t=0 (HolyC) to t=1 (Zig),
//! classifying whether the computational content survives transport.
//!
//! Uses the same GF(3) trit classification as homotopy.zig PathStatus:
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
// LANGUAGE PATH: a single concept tracked across the HolyC→Zig homotopy
// ============================================================================

pub const LanguagePath = struct {
    /// Human-readable concept name
    concept: []const u8,
    /// HolyC source file demonstrating the concept at t=0
    holyc_source: []const u8,
    /// Zig target file where the concept lands at t=1
    zig_target: []const u8,
    /// What computational content is preserved (the type, in HoTT terms)
    invariant: []const u8,
    /// What changes between t=0 and t=1 (the fiber, in HoTT terms)
    deformation: []const u8,
    /// GF(3) classification of the transport
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

// ============================================================================
// THE FIVE CANONICAL PATHS
// ============================================================================

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
        .trit = .zero, // Deformation required: Zig's mark-sweep coexists
    },
    .{
        .concept = "rich-output",
        .holyc_source = "holyc/04-DolDoc.HC",
        .zig_target = "repl.zig",
        .invariant = "Output carries its own rendering. The terminal is hypertext.",
        .deformation = "DolDoc tags ($RED$) → ANSI/OSC escapes (\\x1b[31m)",
        .trit = .zero, // DolDoc has capabilities (clickable code) that ANSI lacks
    },
};

// ============================================================================
// CONVERGENCE VERIFICATION
// ============================================================================

/// Check GF(3) conservation across all paths.
/// Sum of trits should be 0 mod 3 for a balanced homotopy.
pub fn verifyConservation() bool {
    var sum: i32 = 0;
    for (canonical_paths) |path| {
        sum += @as(i32, @intCast(@intFromEnum(path.trit)));
    }
    // 5 paths: +1, +1, +1, 0, 0 = 3 ≡ 0 mod 3 ✓
    return @mod(sum, 3) == 0;
}

/// Count paths by trit classification
pub const ConvergenceStats = struct {
    invariant: usize, // trit +1: fully path-invariant
    parameterized: usize, // trit 0: survives with deformation
    dependent: usize, // trit -1: path-dependent, doesn't translate
    total: usize,
    conserved: bool,
};

pub fn convergenceStats() ConvergenceStats {
    var stats = ConvergenceStats{
        .invariant = 0,
        .parameterized = 0,
        .dependent = 0,
        .total = canonical_paths.len,
        .conserved = verifyConservation(),
    };
    for (canonical_paths) |path| {
        switch (path.trit) {
            .plus => stats.invariant += 1,
            .zero => stats.parameterized += 1,
            .minus => stats.dependent += 1,
        }
    }
    return stats;
}

/// Serialize all paths as a Syrup list (for wire transport or ACSet)
pub fn allPathsToSyrup(allocator: Allocator) !syrup.Value {
    var values = try allocator.alloc(syrup.Value, canonical_paths.len);
    for (canonical_paths, 0..) |path, i| {
        values[i] = try path.toSyrup(allocator);
    }
    return syrup.Value{ .list = values };
}

// ============================================================================
// ALTERNATIVE HISTORY GENERATOR
// ============================================================================

/// A counterfactual: "What if X had been different?"
/// Models Gwern's forking-paths framework as a concrete type.
pub const Counterfactual = struct {
    premise: []const u8, // "HolyC had LLVM"
    affected_paths: []const usize, // indices into canonical_paths
    predicted_trit_change: []const Trit, // how each path's trit would change
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

/// Three canonical counterfactuals from the PATH-INVARIANCE.md analysis
pub const counterfactuals = [_]Counterfactual{
    .{
        .premise = "HolyC developed after LLVM (2010s instead of 2003)",
        .affected_paths = &[_]usize{ 0, 1 }, // eval, single-pass
        .predicted_trit_change = &[_]Trit{ .plus, .zero },
        .reasoning = "JIT would use LLVM backend. Single-pass becomes multi-pass with optimization. Concept survives; implementation diverges more.",
    },
    .{
        .premise = "Zig had no safety guarantees (no bounds checks, no @panic)",
        .affected_paths = &[_]usize{ 3, 4 }, // abc-gc, rich-output
        .predicted_trit_change = &[_]Trit{ .plus, .zero },
        .reasoning = "Without safety, Zig's GC could be simpler (ABC becomes natural). Rich output unchanged. The homotopy contracts: fewer deformations needed.",
    },
    .{
        .premise = "nanoclj-zig written in HolyC instead of Zig",
        .affected_paths = &[_]usize{ 0, 1, 2, 3, 4 },
        .predicted_trit_change = &[_]Trit{ .plus, .plus, .plus, .plus, .plus },
        .reasoning = "All five concepts are path-invariant. The .HC files in this directory ARE this counterfactual realized. Every concept translates.",
    },
};

// ============================================================================
// TESTS
// ============================================================================

test "GF(3) conservation" {
    try std.testing.expect(verifyConservation());
}

test "convergence stats" {
    const stats = convergenceStats();
    try std.testing.expectEqual(@as(usize, 3), stats.invariant); // eval, single-pass, env
    try std.testing.expectEqual(@as(usize, 2), stats.parameterized); // abc-gc, rich-output
    try std.testing.expectEqual(@as(usize, 0), stats.dependent); // nothing is lost
    try std.testing.expectEqual(@as(usize, 5), stats.total);
    try std.testing.expect(stats.conserved);
}

test "all paths serialize to syrup" {
    const allocator = std.testing.allocator;
    const val = try allPathsToSyrup(allocator);
    // Just verify it's a list of 5 elements
    try std.testing.expectEqual(@as(usize, 5), val.list.len);
    // Clean up
    allocator.free(val.list);
}

test "counterfactual structure" {
    // The third counterfactual (nanoclj on HolyC) predicts all paths survive
    const cf = counterfactuals[2];
    try std.testing.expectEqual(@as(usize, 5), cf.affected_paths.len);
    for (cf.predicted_trit_change) |t| {
        try std.testing.expectEqual(Trit.plus, t);
    }
}
