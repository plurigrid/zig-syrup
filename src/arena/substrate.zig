//! Tier 0 substrate dispatcher.
//!
//! When zig-syrup's depth-unverified path executes (mostly the security
//! and 3PHO surfaces — `ocapn_handshake.zig`, `ocapn_handoff.zig`,
//! `sealed_sturdy.zig`), we don't trust the local result alone. We pick
//! a substrate at random (Tier 0), or by Thompson-sampled bandit
//! (Tier 1, see bandit.zig), or by an open-game equilibrium policy
//! (Tier 2), and consult Racket or Guile Goblins as the reference
//! oracle.
//!
//! This file is the substrate enum + the Selector trait + the CallSpec
//! describing one OCapN test invocation. The actual external substrate
//! calls go through MCP-host-mediated bridges (lorj.goblins_call,
//! lorj.guile_eval); they are wired by the caller at session time, not
//! here. We expose a function-pointer table the runtime fills in.

const std = @import("std");
const syrup = @import("../syrup.zig");

pub const Substrate = enum(u2) {
    zig_syrup = 0,
    racket_goblins = 1,
    guile_goblins = 2,

    pub fn label(self: Substrate) []const u8 {
        return switch (self) {
            .zig_syrup => "zig",
            .racket_goblins => "racket",
            .guile_goblins => "guile",
        };
    }
};

/// One OCapN test invocation. `request` is the full Syrup-encoded
/// message we want to put on the wire; `expected` (optional) is what a
/// spec-conformant peer should respond with — bytes-equal — so we can
/// score outcomes without round-tripping through every reference.
pub const CallSpec = struct {
    name: []const u8,
    request: []const u8,
    expected: ?[]const u8 = null,
    /// Soft deadline in milliseconds. Substrates that exceed it count
    /// as failures even if they would have produced correct bytes.
    deadline_ms: u32 = 5_000,
};

pub const Outcome = struct {
    substrate: Substrate,
    success: bool,
    response: []const u8,
    elapsed_ns: u64,
    err: ?[]const u8 = null,
};

/// Function-pointer dispatch table. The runtime fills these in. Tier 0
/// only requires `zig_runner` to be non-null; the racket and guile
/// runners can be left null and the dispatcher will skip them.
pub const Dispatch = struct {
    zig_runner: ?*const fn (Allocator, CallSpec) anyerror!Outcome = null,
    racket_runner: ?*const fn (Allocator, CallSpec) anyerror!Outcome = null,
    guile_runner: ?*const fn (Allocator, CallSpec) anyerror!Outcome = null,
};

const Allocator = std.mem.Allocator;

/// Tier 0 selector: fixed weights, RNG. Replace with bandit.zig's
/// Selector for Tier 1.
pub const RandomSelector = struct {
    rng: std.Random,
    /// Weights need not be normalized; Selector renormalizes. Default
    /// favors zig but never zeros out the references — we want regular
    /// cross-checks even when zig is 100% green.
    weights: [3]f32 = .{ 0.6, 0.2, 0.2 },

    pub fn pick(self: *RandomSelector) Substrate {
        const total = self.weights[0] + self.weights[1] + self.weights[2];
        const r = self.rng.float(f32) * total;
        var acc: f32 = 0;
        inline for (0..3) |i| {
            acc += self.weights[@as(u2, @intCast(i))];
            if (r < acc) return @enumFromInt(i);
        }
        return .zig_syrup;
    }
};

/// Run one CallSpec on the chosen substrate. If the substrate's runner
/// is null in the Dispatch table, fall through to zig_syrup (which is
/// required to be set).
pub fn dispatch(
    allocator: Allocator,
    table: Dispatch,
    s: Substrate,
    spec: CallSpec,
) !Outcome {
    const runner = switch (s) {
        .zig_syrup => table.zig_runner,
        .racket_goblins => table.racket_runner,
        .guile_goblins => table.guile_runner,
    } orelse table.zig_runner orelse return error.NoRunnerConfigured;

    const start = std.time.nanoTimestamp();
    const out = runner(allocator, spec) catch |e| return Outcome{
        .substrate = s,
        .success = false,
        .response = &.{},
        .elapsed_ns = @intCast(std.time.nanoTimestamp() - start),
        .err = @errorName(e),
    };
    return out;
}

/// Score an outcome against `expected` bytes. Thin scoring; counterfactual
/// scoring lives in counterfactual.zig.
pub fn scoreOutcome(out: Outcome, expected: ?[]const u8) f32 {
    if (!out.success) return 0.0;
    const bytes_ok = if (expected) |exp|
        std.mem.eql(u8, out.response, exp)
    else
        true;
    if (!bytes_ok) return 0.25; // ran but bytes diverged
    return 1.0;
}

test "RandomSelector respects weights in distribution" {
    var prng = std.Random.DefaultPrng.init(42);
    var sel = RandomSelector{ .rng = prng.random(), .weights = .{ 1.0, 0.0, 0.0 } };
    inline for (0..32) |_| {
        try std.testing.expectEqual(Substrate.zig_syrup, sel.pick());
    }
}

test "Substrate label round trip" {
    try std.testing.expectEqualStrings("zig", Substrate.zig_syrup.label());
    try std.testing.expectEqualStrings("racket", Substrate.racket_goblins.label());
    try std.testing.expectEqualStrings("guile", Substrate.guile_goblins.label());
}
