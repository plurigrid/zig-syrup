// gaymc.zig: Colored Monte Carlo with Spectral Parallel Identity (SPI)
// Zig translation of Gay.jl's gaymc.jl
// Every MC operation (sweep, measure, checkpoint) splits the RNG and
// generates a deterministic color. Same seed + same operations = same colors.

const std = @import("std");
const splitmix = @import("splitmix.zig");
const color_mod = @import("color.zig");
const Color = color_mod.RGB;
const math = std.math;

// ============================================================================
// FNV-1a hash
// ============================================================================

pub fn fnv1a(data: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (data) |b| {
        h = (h ^ @as(u64, b)) *% 1099511628211;
    }
    return h;
}

// ============================================================================
// Color from RNG state
// ============================================================================

fn colorFromState(state: u64) Color {
    const val = splitmix.splitmix64(state);
    const mask21: u64 = (1 << 21) - 1;
    const r_raw = val & mask21;
    const g_raw = (val >> 21) & mask21;
    const b_raw = (val >> 42) & mask21;
    const scale = 1.0 / @as(f64, @floatFromInt(mask21));
    return .{
        .r = @as(f64, @floatFromInt(r_raw)) * scale,
        .g = @as(f64, @floatFromInt(g_raw)) * scale,
        .b = @as(f64, @floatFromInt(b_raw)) * scale,
    };
}

// ============================================================================
// Checkpoint
// ============================================================================

pub const Checkpoint = struct {
    seed: u64,
    worker_id: u64,
    sweep_count: u64,
    measure_count: u64,
    checkpoint_count: u64,
    color: Color,
};

// ============================================================================
// GayMCContext
// ============================================================================

pub const GayMCContext = struct {
    root_seed: u64,
    state: u64,
    sweep_count: u64,
    measure_count: u64,
    checkpoint_count: u64,
    worker_id: u64,
    seed: u64,
    color_history: std.ArrayList(Color),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64, worker_id: u64) GayMCContext {
        // Derive initial state by mixing seed and worker_id
        const initial_state = splitmix.splitmix64(seed ^ (worker_id *% 0x9e3779b97f4a7c15));
        return .{
            .root_seed = seed,
            .state = initial_state,
            .sweep_count = 0,
            .measure_count = 0,
            .checkpoint_count = 0,
            .worker_id = worker_id,
            .seed = seed,
            .color_history = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GayMCContext) void {
        self.color_history.deinit(self.allocator);
    }

    // Split the RNG: advance state deterministically
    fn split(self: *GayMCContext) u64 {
        self.state = splitmix.splitmix64(self.state);
        return self.state;
    }

    // Draw a uniform f64 in [0,1) from current state, advancing it
    fn uniform01(self: *GayMCContext) f64 {
        const val = self.split();
        // Use top 53 bits for double precision
        return @as(f64, @floatFromInt(val >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    // ========================================================================
    // Core MC operations
    // ========================================================================

    /// Sweep: advance the MC chain one step, producing a new state+color
    pub fn sweep(self: *GayMCContext) struct { state: u64, color: Color } {
        self.sweep_count += 1;
        const new_state = self.split();
        const color = colorFromState(new_state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .state = new_state, .color = color };
    }

    /// Measure: named measurement point, mixes name into state for determinism
    pub fn measure(self: *GayMCContext, name: []const u8) struct { state: u64, color: Color } {
        self.measure_count += 1;
        // Mix the measurement name into the state via FNV-1a
        const name_hash = fnv1a(name);
        self.state ^= name_hash;
        const new_state = self.split();
        const color = colorFromState(new_state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .state = new_state, .color = color };
    }

    /// Checkpoint: snapshot current state for later restore
    pub fn checkpoint(self: *GayMCContext) Checkpoint {
        self.checkpoint_count += 1;
        const color = colorFromState(self.state);
        return .{
            .seed = self.state,
            .worker_id = self.worker_id,
            .sweep_count = self.sweep_count,
            .measure_count = self.measure_count,
            .checkpoint_count = self.checkpoint_count,
            .color = color,
        };
    }

    /// Restore from a checkpoint
    pub fn restore(self: *GayMCContext, cp: Checkpoint) void {
        self.state = cp.seed;
        self.sweep_count = cp.sweep_count;
        self.measure_count = cp.measure_count;
        self.checkpoint_count = cp.checkpoint_count;
    }

    // ========================================================================
    // Color accessors
    // ========================================================================

    /// Color of the current sweep (from current state)
    pub fn colorSweep(self: *const GayMCContext) Color {
        return colorFromState(self.state);
    }

    /// Color at a specific history index
    pub fn colorSweepAt(self: *const GayMCContext, idx: usize) Color {
        if (idx < self.color_history.items.len) {
            return self.color_history.items[idx];
        }
        // Fallback: derive from seed + idx
        return colorFromState(self.seed +% @as(u64, idx));
    }

    /// Deterministic color for a named measurement
    pub fn colorMeasure(self: *const GayMCContext, name: []const u8) Color {
        const name_hash = fnv1a(name);
        return colorFromState(self.state ^ name_hash);
    }

    /// Color derived from recent state window (XOR of last `window` history entries)
    pub fn colorState(self: *const GayMCContext, window: usize) Color {
        const items = self.color_history.items;
        if (items.len == 0) return colorFromState(self.state);

        const start = if (items.len > window) items.len - window else 0;
        var acc: u64 = 0;
        for (items[start..]) |c| {
            acc ^= c.hash();
        }
        return colorFromState(acc);
    }

    // ========================================================================
    // Sampling distributions
    // ========================================================================

    /// Exponential distribution: -ln(u)/lambda
    pub fn sampleExponential(self: *GayMCContext, lambda: f64) struct { value: f64, color: Color } {
        const u = self.uniform01();
        // Avoid log(0)
        const safe_u = if (u == 0.0) 1e-300 else u;
        const value = -@log(safe_u) / lambda;
        const color = colorFromState(self.state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .value = value, .color = color };
    }

    /// Cauchy distribution: x0 + gamma * tan(pi * (u - 0.5))
    pub fn sampleCauchy(self: *GayMCContext, x0: f64, gamma: f64) struct { value: f64, color: Color } {
        const u = self.uniform01();
        const value = x0 + gamma * @tan(math.pi * (u - 0.5));
        const color = colorFromState(self.state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .value = value, .color = color };
    }

    /// Gaussian distribution via Box-Muller transform
    pub fn sampleGaussian(self: *GayMCContext, mu: f64, sigma: f64) struct { value: f64, color: Color } {
        const unif1 = self.uniform01();
        const unif2 = self.uniform01();
        const safe_u1 = if (unif1 == 0.0) 1e-300 else unif1;
        const z = @sqrt(-2.0 * @log(safe_u1)) * @cos(2.0 * math.pi * unif2);
        const value = mu + sigma * z;
        const color = colorFromState(self.state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .value = value, .color = color };
    }

    /// Metropolis-Hastings step with symmetric proposal
    pub fn metropolisStep(
        self: *GayMCContext,
        current: f64,
        proposal_width: f64,
        log_target: *const fn (f64) f64,
    ) struct { value: f64, accepted: bool, color: Color } {
        // Gaussian proposal
        const gauss = self.sampleGaussian(current, proposal_width);
        const proposal = gauss.value;
        // Remove the color appended by sampleGaussian from history
        // (we'll add our own at the end)
        if (self.color_history.items.len > 0) {
            _ = self.color_history.pop();
        }

        const log_alpha = log_target(proposal) - log_target(current);
        const u = self.uniform01();
        const accepted = @log(if (u == 0.0) 1e-300 else u) < log_alpha;
        const value = if (accepted) proposal else current;

        const color = colorFromState(self.state);
        self.color_history.append(self.allocator, color) catch {};
        return .{ .value = value, .accepted = accepted, .color = color };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "fnv1a deterministic" {
    const h1 = fnv1a("hello");
    const h2 = fnv1a("hello");
    try std.testing.expectEqual(h1, h2);
    // Different inputs -> different hashes
    const h3 = fnv1a("world");
    try std.testing.expect(h1 != h3);
}

test "fnv1a empty" {
    const h = fnv1a("");
    try std.testing.expectEqual(h, 14695981039346656037);
}

test "colorFromState deterministic" {
    const c1 = colorFromState(42);
    const c2 = colorFromState(42);
    try std.testing.expectApproxEqAbs(c1.r, c2.r, 1e-15);
    try std.testing.expectApproxEqAbs(c1.g, c2.g, 1e-15);
    try std.testing.expectApproxEqAbs(c1.b, c2.b, 1e-15);
}

test "colorFromState valid range" {
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const c = colorFromState(i *% 0x9e3779b97f4a7c15);
        try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
        try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
        try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);
    }
}

test "GayMCContext init and deinit" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    try std.testing.expectEqual(ctx.root_seed, 1069);
    try std.testing.expectEqual(ctx.worker_id, 0);
    try std.testing.expectEqual(ctx.sweep_count, 0);
}

test "SPI: same seed same operations same colors" {
    var ctx1 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx1.deinit();
    var ctx2 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx2.deinit();

    // Same sequence of operations
    const s1 = ctx1.sweep();
    const s2 = ctx2.sweep();
    try std.testing.expectApproxEqAbs(s1.color.r, s2.color.r, 1e-15);
    try std.testing.expectApproxEqAbs(s1.color.g, s2.color.g, 1e-15);
    try std.testing.expectApproxEqAbs(s1.color.b, s2.color.b, 1e-15);

    const m1 = ctx1.measure("energy");
    const m2 = ctx2.measure("energy");
    try std.testing.expectApproxEqAbs(m1.color.r, m2.color.r, 1e-15);
    try std.testing.expectApproxEqAbs(m1.color.g, m2.color.g, 1e-15);
    try std.testing.expectApproxEqAbs(m1.color.b, m2.color.b, 1e-15);
}

test "different workers produce different colors" {
    var ctx0 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx0.deinit();
    var ctx1 = GayMCContext.init(std.testing.allocator, 1069, 1);
    defer ctx1.deinit();

    const s0 = ctx0.sweep();
    const s1 = ctx1.sweep();
    // Very unlikely to be the same
    try std.testing.expect(s0.state != s1.state);
}

test "sweep advances state and count" {
    var ctx = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx.deinit();
    const state_before = ctx.state;
    _ = ctx.sweep();
    try std.testing.expect(ctx.state != state_before);
    try std.testing.expectEqual(ctx.sweep_count, 1);
    _ = ctx.sweep();
    try std.testing.expectEqual(ctx.sweep_count, 2);
}

test "measure mixes name" {
    var ctx = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx.deinit();
    const m1 = ctx.measure("energy");
    // Reset
    var ctx2 = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx2.deinit();
    const m2 = ctx2.measure("magnetization");
    // Different names -> different colors
    try std.testing.expect(m1.state != m2.state);
}

test "checkpoint and restore" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();

    _ = ctx.sweep();
    _ = ctx.sweep();
    const cp = ctx.checkpoint();

    // Do more work
    _ = ctx.sweep();
    _ = ctx.sweep();
    try std.testing.expectEqual(ctx.sweep_count, 4);

    // Restore
    ctx.restore(cp);
    try std.testing.expectEqual(ctx.sweep_count, 2);
    try std.testing.expectEqual(ctx.state, cp.seed);
}

test "colorSweep matches current state" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    _ = ctx.sweep();
    const c = ctx.colorSweep();
    const expected = colorFromState(ctx.state);
    try std.testing.expectApproxEqAbs(c.r, expected.r, 1e-15);
    try std.testing.expectApproxEqAbs(c.g, expected.g, 1e-15);
    try std.testing.expectApproxEqAbs(c.b, expected.b, 1e-15);
}

test "colorSweepAt returns history" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    const s0 = ctx.sweep();
    const s1 = ctx.sweep();
    const c0 = ctx.colorSweepAt(0);
    const c1 = ctx.colorSweepAt(1);
    try std.testing.expectApproxEqAbs(s0.color.r, c0.r, 1e-15);
    try std.testing.expectApproxEqAbs(s1.color.r, c1.r, 1e-15);
}

test "colorMeasure deterministic for same name" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    _ = ctx.sweep();
    const c1 = ctx.colorMeasure("obs");
    const c2 = ctx.colorMeasure("obs");
    try std.testing.expectApproxEqAbs(c1.r, c2.r, 1e-15);
}

test "colorState window" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    // Empty history -> fallback
    const c0 = ctx.colorState(5);
    try std.testing.expect(c0.r >= 0.0 and c0.r <= 1.0);

    // Add some sweeps
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = ctx.sweep();
    }
    const c1 = ctx.colorState(3);
    const c2 = ctx.colorState(5);
    // Different windows -> generally different colors
    try std.testing.expect(c1.r >= 0.0 and c1.r <= 1.0);
    try std.testing.expect(c2.r >= 0.0 and c2.r <= 1.0);
}

test "sampleExponential positive" {
    var ctx = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const result = ctx.sampleExponential(1.0);
        try std.testing.expect(result.value > 0.0);
        try std.testing.expect(result.color.r >= 0.0 and result.color.r <= 1.0);
    }
}

test "sampleExponential different lambda" {
    var ctx1 = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx1.deinit();
    var ctx2 = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx2.deinit();
    const r1 = ctx1.sampleExponential(1.0);
    const r2 = ctx2.sampleExponential(2.0);
    // Same uniform draw, different lambda -> value ratio should be ~2
    try std.testing.expectApproxEqAbs(r1.value / r2.value, 2.0, 0.01);
}

test "sampleCauchy finite" {
    var ctx = GayMCContext.init(std.testing.allocator, 99, 0);
    defer ctx.deinit();
    // Cauchy can produce large values but should be finite
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const result = ctx.sampleCauchy(0.0, 1.0);
        try std.testing.expect(math.isFinite(result.value));
    }
}

test "sampleGaussian mean and color" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    // Sample many and check mean is approximately mu
    var sum: f64 = 0;
    const n: usize = 1000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const result = ctx.sampleGaussian(5.0, 1.0);
        sum += result.value;
        try std.testing.expect(result.color.r >= 0.0 and result.color.r <= 1.0);
    }
    const mean = sum / @as(f64, @floatFromInt(n));
    try std.testing.expectApproxEqAbs(mean, 5.0, 0.2);
}

test "sampleGaussian deterministic" {
    var ctx1 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx1.deinit();
    var ctx2 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx2.deinit();
    const r1 = ctx1.sampleGaussian(0.0, 1.0);
    const r2 = ctx2.sampleGaussian(0.0, 1.0);
    try std.testing.expectApproxEqAbs(r1.value, r2.value, 1e-15);
}

fn negQuadratic(x: f64) f64 {
    return -0.5 * x * x;
}

test "metropolisStep accepts/rejects" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();

    var accept_count: usize = 0;
    var current: f64 = 0.0;
    const n: usize = 500;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const result = ctx.metropolisStep(current, 1.0, &negQuadratic);
        current = result.value;
        if (result.accepted) accept_count += 1;
        try std.testing.expect(result.color.r >= 0.0 and result.color.r <= 1.0);
    }
    // Acceptance rate should be reasonable (not 0% or 100%)
    try std.testing.expect(accept_count > 50);
    try std.testing.expect(accept_count < 450);
}

test "metropolisStep deterministic" {
    var ctx1 = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx1.deinit();
    var ctx2 = GayMCContext.init(std.testing.allocator, 42, 0);
    defer ctx2.deinit();
    const r1 = ctx1.metropolisStep(0.0, 1.0, &negQuadratic);
    const r2 = ctx2.metropolisStep(0.0, 1.0, &negQuadratic);
    try std.testing.expectEqual(r1.accepted, r2.accepted);
    try std.testing.expectApproxEqAbs(r1.value, r2.value, 1e-15);
}

test "color history grows with operations" {
    var ctx = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx.deinit();
    try std.testing.expectEqual(ctx.color_history.items.len, 0);
    _ = ctx.sweep();
    try std.testing.expectEqual(ctx.color_history.items.len, 1);
    _ = ctx.measure("x");
    try std.testing.expectEqual(ctx.color_history.items.len, 2);
    _ = ctx.sampleExponential(1.0);
    try std.testing.expectEqual(ctx.color_history.items.len, 3);
}

test "SPI fingerprint over color history" {
    var ctx1 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx1.deinit();
    var ctx2 = GayMCContext.init(std.testing.allocator, 1069, 0);
    defer ctx2.deinit();

    // Same operations
    _ = ctx1.sweep();
    _ = ctx1.sweep();
    _ = ctx1.measure("E");
    _ = ctx2.sweep();
    _ = ctx2.sweep();
    _ = ctx2.measure("E");

    // Fingerprints must match (SPI guarantee)
    const fp1 = color_mod.fingerprint(ctx1.color_history.items);
    const fp2 = color_mod.fingerprint(ctx2.color_history.items);
    try std.testing.expectEqual(fp1, fp2);
}
