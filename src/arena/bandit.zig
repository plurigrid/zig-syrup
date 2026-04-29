//! Thompson Beta-Bernoulli bandit over (TestFingerprint × Substrate).
//!
//! Tier 1 of the substrate-selection stack. Trivially compatible with
//! off-policy updates from counterfactual.zig.
//!
//! Memory layout: 2048 fingerprint cells × 3 substrates × (α, β as f32)
//! = 48 KiB. Persisted to disk as a fixed-size binary file with a
//! header carrying the OCapN spec hash; mismatch on load → reset.
//!
//! Bumped from 512 → 2048 cells to accommodate the tw_outlier and
//! fv_outlier flags from the boxxy tapes-conformance loop. Old
//! ZSARENA1 files will fail spec_hash check and reset cleanly via
//! Bandit.init; the new format uses magic ZSARENA2.

const std = @import("std");
const fingerprint = @import("fingerprint.zig");
const substrate = @import("substrate.zig");

pub const N_CELLS = 1 << 11; // 2048 — 11-bit fingerprint
pub const N_SUBSTRATES = 3;

pub const Cell = extern struct {
    alpha: f32 = 1.0,
    beta: f32 = 1.0,
};

pub const Header = extern struct {
    magic: [8]u8 = "ZSARENA2".*,
    spec_hash: [32]u8 = std.mem.zeroes([32]u8),
    n_cells: u32 = N_CELLS,
    n_substrates: u32 = N_SUBSTRATES,
};

pub const Bandit = struct {
    header: Header,
    cells: [N_CELLS][N_SUBSTRATES]Cell,
    rng: std.Random,

    pub fn init(rng: std.Random, spec_hash: [32]u8) Bandit {
        var b: Bandit = .{
            .header = .{ .spec_hash = spec_hash },
            .cells = undefined,
            .rng = rng,
        };
        for (0..N_CELLS) |i| {
            for (0..N_SUBSTRATES) |j| {
                b.cells[i][j] = .{};
            }
        }
        return b;
    }

    /// Thompson sampling: draw one Beta(α, β) per arm, pick the highest.
    pub fn pick(self: *Bandit, fp: fingerprint.TestFingerprint) substrate.Substrate {
        const idx = fp.toIndex();
        var best: substrate.Substrate = .zig_syrup;
        var best_sample: f32 = -1;
        inline for (0..N_SUBSTRATES) |i| {
            const c = self.cells[idx][i];
            const s = sampleBeta(self.rng, c.alpha, c.beta);
            if (s > best_sample) {
                best_sample = s;
                best = @enumFromInt(i);
            }
        }
        return best;
    }

    /// Update the chosen arm's posterior with one observation.
    pub fn update(
        self: *Bandit,
        fp: fingerprint.TestFingerprint,
        picked: substrate.Substrate,
        success: bool,
    ) void {
        const cell = &self.cells[fp.toIndex()][@intFromEnum(picked)];
        if (success) cell.alpha += 1 else cell.beta += 1;
    }

    /// Off-policy update from a counterfactual. `weight` ∈ [0, 1] scales
    /// the pseudo-observation since it didn't actually run on the wire.
    pub fn updateCounterfactual(
        self: *Bandit,
        fp: fingerprint.TestFingerprint,
        target: substrate.Substrate,
        success: bool,
        weight: f32,
    ) void {
        const cell = &self.cells[fp.toIndex()][@intFromEnum(target)];
        const w = std.math.clamp(weight, 0.0, 1.0);
        if (success) cell.alpha += w else cell.beta += w;
    }

    pub fn save(self: *const Bandit, writer: anytype) !void {
        try writer.writeAll(std.mem.asBytes(&self.header));
        try writer.writeAll(std.mem.sliceAsBytes(&self.cells));
    }

    pub fn load(reader: anytype, rng: std.Random, expected_spec: [32]u8) !Bandit {
        var b: Bandit = undefined;
        b.rng = rng;
        const hdr_bytes = try reader.readBytesNoEof(@sizeOf(Header));
        b.header = std.mem.bytesAsValue(Header, &hdr_bytes).*;
        if (!std.mem.eql(u8, &b.header.magic, "ZSARENA2")) return error.BadMagic;
        if (!std.mem.eql(u8, &b.header.spec_hash, &expected_spec)) return error.SpecMismatch;
        const cells_bytes = std.mem.sliceAsBytes(&b.cells);
        const n = try reader.readAll(cells_bytes);
        if (n != cells_bytes.len) return error.Truncated;
        return b;
    }
};

/// Sample from Beta(α, β) via the gamma-ratio trick — sufficient for our
/// needs given small α, β. Not numerically optimal at extreme priors.
fn sampleBeta(rng: std.Random, alpha: f32, beta: f32) f32 {
    const x = sampleGamma(rng, alpha);
    const y = sampleGamma(rng, beta);
    if (x + y == 0) return 0.5;
    return x / (x + y);
}

/// Marsaglia–Tsang Gamma sampler for shape ≥ 1; for shape < 1 use the
/// boost-and-scale trick.
fn sampleGamma(rng: std.Random, shape: f32) f32 {
    if (shape < 1.0) {
        // Stuart's theorem: G(α) = G(α+1) · U^(1/α)
        const g = sampleGamma(rng, shape + 1.0);
        const u = rng.float(f32);
        return g * std.math.pow(f32, u, 1.0 / shape);
    }
    const d = shape - 1.0 / 3.0;
    const c = 1.0 / std.math.sqrt(9.0 * d);
    while (true) {
        var x: f32 = undefined;
        var v: f32 = undefined;
        x = randNormal(rng);
        v = 1.0 + c * x;
        if (v <= 0) continue;
        v = v * v * v;
        const u = rng.float(f32);
        if (u < 1.0 - 0.0331 * x * x * x * x) return d * v;
        if (@log(u) < 0.5 * x * x + d * (1.0 - v + @log(v))) return d * v;
    }
}

fn randNormal(rng: std.Random) f32 {
    // Box-Muller, single-sample form. The unused second value is fine
    // for our sample volumes.
    const u1 = @max(rng.float(f32), 1e-7);
    const u2 = rng.float(f32);
    return std.math.sqrt(-2.0 * @log(u1)) * @cos(std.math.tau * u2);
}

test "Bandit converges on best arm under skewed reward" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();
    var b = Bandit.init(rng, std.mem.zeroes([32]u8));
    const fp = fingerprint.TestFingerprint.empty();

    // racket succeeds 80% of the time, others 10%. After 200 rounds the
    // bandit should pick racket on the majority of pulls.
    for (0..200) |i| {
        _ = i;
        const picked = b.pick(fp);
        const success = switch (picked) {
            .racket_goblins => prng.random().float(f32) < 0.8,
            else => prng.random().float(f32) < 0.1,
        };
        b.update(fp, picked, success);
    }

    var racket_picks: u32 = 0;
    for (0..100) |_| {
        if (b.pick(fp) == .racket_goblins) racket_picks += 1;
    }
    try std.testing.expect(racket_picks > 50);
}

test "Counterfactual update with weight 0 is a no-op" {
    var prng = std.Random.DefaultPrng.init(7);
    var b = Bandit.init(prng.random(), std.mem.zeroes([32]u8));
    const fp = fingerprint.TestFingerprint.empty();
    const before = b.cells[fp.toIndex()][@intFromEnum(substrate.Substrate.racket_goblins)];
    b.updateCounterfactual(fp, .racket_goblins, true, 0.0);
    const after = b.cells[fp.toIndex()][@intFromEnum(substrate.Substrate.racket_goblins)];
    try std.testing.expectEqual(before.alpha, after.alpha);
    try std.testing.expectEqual(before.beta, after.beta);
}
