//! Arena runner: ties substrate dispatcher + fingerprint + bandit
//! together so each OCapN compliance test is one runOne() call.
//!
//! Wiring at session time:
//!
//!   var prng = std.Random.DefaultPrng.init(seed);
//!   var bandit = Bandit.init(prng.random(), spec_hash);
//!   const dispatch = Dispatch{
//!       .zig_runner    = &zigRunner,
//!       .racket_runner = &racketRunnerViaLorj,   // lorj.goblins_call bridge
//!       .guile_runner  = &guileRunnerViaLorj,    // lorj.guile_eval bridge
//!   };
//!   const arena = Arena{ .bandit = &bandit, .dispatch = dispatch };
//!   const out = try arena.runOne(allocator, spec);

const std = @import("std");
const syrup = @import("../syrup.zig");
const substrate = @import("substrate.zig");
const fingerprint = @import("fingerprint.zig");
const bandit_mod = @import("bandit.zig");

pub const Arena = struct {
    bandit: *bandit_mod.Bandit,
    dispatch: substrate.Dispatch,
    /// Cross-checking: when the picked substrate is zig_syrup, optionally
    /// also run the request on a reference and compare bytes. Set to
    /// null to disable. When non-null, it costs one extra reference call
    /// per zig pick — pricy but invaluable during compliance ramp-up.
    cross_check_substrate: ?substrate.Substrate = null,

    pub fn runOne(
        self: *Arena,
        allocator: std.mem.Allocator,
        spec: substrate.CallSpec,
        request_value: syrup.Value,
        transport: fingerprint.Transport,
    ) !RunResult {
        const fp = fingerprint.extract(request_value, transport);
        const picked = self.bandit.pick(fp);
        const out = try substrate.dispatch(allocator, self.dispatch, picked, spec);
        const score = substrate.scoreOutcome(out, spec.expected);
        const success = score >= 1.0;
        self.bandit.update(fp, picked, success);

        var cross: ?substrate.Outcome = null;
        if (picked == .zig_syrup and self.cross_check_substrate != null) {
            const ref = self.cross_check_substrate.?;
            cross = substrate.dispatch(allocator, self.dispatch, ref, spec) catch null;
            if (cross) |c| {
                const ref_success = c.success and
                    if (spec.expected) |exp| std.mem.eql(u8, c.response, exp) else true;
                self.bandit.update(fp, ref, ref_success);
                if (out.success and c.success and !std.mem.eql(u8, out.response, c.response)) {
                    // Bytes diverge between zig and reference — log loud.
                    std.log.warn(
                        "arena: byte divergence on test '{s}' between {s} and {s}",
                        .{ spec.name, picked.label(), ref.label() },
                    );
                }
            }
        }

        return .{
            .fingerprint = fp,
            .picked = picked,
            .outcome = out,
            .score = score,
            .cross_check = cross,
        };
    }
};

pub const RunResult = struct {
    fingerprint: fingerprint.TestFingerprint,
    picked: substrate.Substrate,
    outcome: substrate.Outcome,
    score: f32,
    cross_check: ?substrate.Outcome,
};

test "Arena runOne wires fingerprint → pick → dispatch → update" {
    const TestRunner = struct {
        fn run(allocator: std.mem.Allocator, spec: substrate.CallSpec) !substrate.Outcome {
            const echo = try allocator.dupe(u8, spec.request);
            return .{
                .substrate = .zig_syrup,
                .success = true,
                .response = echo,
                .elapsed_ns = 0,
            };
        }
    };

    var prng = std.Random.DefaultPrng.init(99);
    var bandit = bandit_mod.Bandit.init(prng.random(), std.mem.zeroes([32]u8));
    var arena = Arena{
        .bandit = &bandit,
        .dispatch = .{ .zig_runner = &TestRunner.run },
    };

    const label = syrup.Value{ .symbol = "op:abort" };
    const fields = [_]syrup.Value{.{ .string = "test reason" }};
    const req = syrup.Value{ .record = .{ .label = &label, .fields = &fields } };

    var allocator = std.testing.allocator;
    const spec = substrate.CallSpec{
        .name = "abort_smoke",
        .request = "<8'op:abort11\"test reason>",
        .expected = "<8'op:abort11\"test reason>",
    };
    const result = try arena.runOne(allocator, spec, req, .websocket);
    defer allocator.free(result.outcome.response);

    try std.testing.expect(result.fingerprint.has_abort);
    try std.testing.expect(result.score >= 1.0);
}
