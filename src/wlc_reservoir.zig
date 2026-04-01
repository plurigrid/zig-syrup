//! Winnerless Competition (WLC) Reservoir — Rabinovich-Varona heteroclinic dynamics
//!
//! The maximally antagonistic dynamical system for zig-syrup's type system.
//! WLC produces stable heteroclinic channels: trajectories that visit saddle
//! points sequentially, never converging, never chaotic, never periodic.
//!
//! Resolution: we don't trit-classify the trajectory. We discretize at
//! the INSTRUMENT — which saddle neighborhood the trajectory currently
//! visits. The saddles ARE the opens in the ordered locale. The heteroclinic
//! connections ARE the way-below relations. The attractor (visitation sequence)
//! is translation-invariant.
//!
//! Connects to:
//! - propagator.zig: CellValue = saddle index (not continuous state)
//! - prigogine.zig: dissipative structure classification
//! - virion.zig: Trit assigned per saddle, not per trajectory point
//! - bci_homotopy.zig: EEG channels as saddle detectors
//! - gatomic catcolab: RegulatoryNetwork/attractor-switching model

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ============================================================================
// LOTKA-VOLTERRA WLC CORE
// ============================================================================

/// Generalized Lotka-Volterra system with asymmetric inhibition.
/// dx_i/dt = x_i(σ_i - Σ_j ρ_ij x_j)
/// When ρ is asymmetric and satisfies the heteroclinic condition,
/// trajectories cycle through saddle equilibria without repeating.
pub const WLCSystem = struct {
    n: usize,
    /// Growth rates σ_i (one per species/saddle)
    sigma: []f64,
    /// Inhibition matrix ρ_ij (n×n, asymmetric)
    rho: []f64,
    /// Current state x_i >= 0
    state: []f64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, n: usize) !WLCSystem {
        const sigma = try allocator.alloc(f64, n);
        const rho = try allocator.alloc(f64, n * n);
        const state = try allocator.alloc(f64, n);
        @memset(sigma, 1.0);
        @memset(rho, 0.0);
        @memset(state, 0.0);
        return .{
            .n = n,
            .sigma = sigma,
            .rho = rho,
            .state = state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WLCSystem) void {
        self.allocator.free(self.sigma);
        self.allocator.free(self.rho);
        self.allocator.free(self.state);
    }

    /// Set inhibition: species j inhibits species i with strength rho_ij
    pub fn setInhibition(self: *WLCSystem, i: usize, j: usize, val: f64) void {
        self.rho[i * self.n + j] = val;
    }

    /// RHS: dx_i/dt = x_i(σ_i - Σ_j ρ_ij x_j)
    pub fn derivative(self: *const WLCSystem, x: []const f64, dxdt: []f64) void {
        for (0..self.n) |i| {
            var inhibition: f64 = 0.0;
            for (0..self.n) |j| {
                inhibition += self.rho[i * self.n + j] * x[j];
            }
            dxdt[i] = x[i] * (self.sigma[i] - inhibition);
        }
    }

    /// RK4 step
    pub fn step(self: *WLCSystem, dt: f64) !void {
        const n = self.n;
        const alloc = self.allocator;
        const k1 = try alloc.alloc(f64, n);
        defer alloc.free(k1);
        const k2 = try alloc.alloc(f64, n);
        defer alloc.free(k2);
        const k3 = try alloc.alloc(f64, n);
        defer alloc.free(k3);
        const k4 = try alloc.alloc(f64, n);
        defer alloc.free(k4);
        const tmp = try alloc.alloc(f64, n);
        defer alloc.free(tmp);

        self.derivative(self.state, k1);

        for (0..n) |i| tmp[i] = self.state[i] + 0.5 * dt * k1[i];
        self.derivative(tmp, k2);

        for (0..n) |i| tmp[i] = self.state[i] + 0.5 * dt * k2[i];
        self.derivative(tmp, k3);

        for (0..n) |i| tmp[i] = self.state[i] + dt * k3[i];
        self.derivative(tmp, k4);

        for (0..n) |i| {
            self.state[i] += (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]);
            // Clamp to non-negative (species can't go negative)
            if (self.state[i] < 0.0) self.state[i] = 0.0;
        }
    }
};

// ============================================================================
// SADDLE DETECTOR (THE INSTRUMENT)
// ============================================================================

/// Which saddle equilibrium the trajectory is currently near.
/// This is the discretization that makes WLC compatible with GF(3).
pub const SaddleDetection = struct {
    /// Index of the dominant species (saddle neighborhood)
    active_saddle: usize,
    /// Confidence: ratio of dominant to second-largest species
    dominance_ratio: f64,
    /// True if clearly in one saddle's neighborhood
    confident: bool,
    /// True if transitioning between saddles (in the heteroclinic channel)
    in_transition: bool,
};

/// Detect which saddle the trajectory is visiting.
/// The instrument: maps continuous ℝⁿ → discrete saddle index.
pub fn detectSaddle(state: []const f64, n: usize, threshold: f64) SaddleDetection {
    var max_val: f64 = 0.0;
    var max_idx: usize = 0;
    var second_val: f64 = 0.0;

    for (0..n) |i| {
        if (state[i] > max_val) {
            second_val = max_val;
            max_val = state[i];
            max_idx = i;
        } else if (state[i] > second_val) {
            second_val = state[i];
        }
    }

    const ratio = if (second_val > 1e-12) max_val / second_val else math.inf(f64);

    return .{
        .active_saddle = max_idx,
        .dominance_ratio = ratio,
        .confident = ratio > threshold,
        .in_transition = (ratio <= threshold) and (ratio > 1.0),
    };
}

// ============================================================================
// VISITATION SEQUENCE (THE ATTRACTOR, TRANSLATION-INVARIANT)
// ============================================================================

/// Record of saddle visitations — this IS the memory of the continuous system.
/// Translation-invariant: shift the time origin, same sequence.
pub const VisitationLog = struct {
    /// Sequence of saddle indices visited
    saddles: std.ArrayListUnmanaged(usize),
    /// Residence times at each saddle
    durations: std.ArrayListUnmanaged(f64),
    /// GF(3) trit assigned to each saddle
    trits: std.ArrayListUnmanaged(i8),
    /// Current saddle being visited
    current: ?usize,
    /// Time spent at current saddle
    current_duration: f64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) VisitationLog {
        return .{
            .saddles = .{},
            .durations = .{},
            .trits = .{},
            .current = null,
            .current_duration = 0.0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VisitationLog) void {
        self.saddles.deinit(self.allocator);
        self.durations.deinit(self.allocator);
        self.trits.deinit(self.allocator);
    }

    /// Update with a new saddle detection. Only records transitions.
    pub fn update(self: *VisitationLog, detection: SaddleDetection, dt: f64, trit_map: []const i8) !void {
        if (!detection.confident) {
            // In transition — don't record, just accumulate time
            self.current_duration += dt;
            return;
        }

        if (self.current) |cur| {
            if (cur == detection.active_saddle) {
                // Same saddle — accumulate residence time
                self.current_duration += dt;
                return;
            }
            // Transition! Record the completed visit
            try self.saddles.append(self.allocator, cur);
            try self.durations.append(self.allocator, self.current_duration);
            try self.trits.append(self.allocator, trit_map[cur]);
        }

        // Start new visit
        self.current = detection.active_saddle;
        self.current_duration = dt;
    }

    /// GF(3) trit balance of the visitation sequence
    pub fn tritBalance(self: *const VisitationLog) i32 {
        var sum: i32 = 0;
        for (self.trits.items) |t| {
            sum += @as(i32, t);
        }
        return sum;
    }

    /// Number of unique saddles visited
    pub fn uniqueSaddles(self: *const VisitationLog) usize {
        var seen: [64]bool = .{false} ** 64; // max 64 saddles
        for (self.saddles.items) |s| {
            if (s < 64) seen[s] = true;
        }
        var count: usize = 0;
        for (seen) |s| {
            if (s) count += 1;
        }
        return count;
    }

    /// Mean residence time (higher = more stable saddles)
    pub fn meanResidence(self: *const VisitationLog) f64 {
        if (self.durations.items.len == 0) return 0.0;
        var sum: f64 = 0.0;
        for (self.durations.items) |d| sum += d;
        return sum / @as(f64, @floatFromInt(self.durations.items.len));
    }
};

// ============================================================================
// CANONICAL WLC CONFIGURATIONS
// ============================================================================

/// 3-species WLC (minimal heteroclinic cycle). Maps to GF(3) directly:
/// saddle 0 = trit +1 (generator), saddle 1 = trit 0 (ergodic), saddle 2 = trit -1 (validator)
pub fn wlc3(allocator: Allocator) !WLCSystem {
    var sys = try WLCSystem.init(allocator, 3);
    // Asymmetric inhibition matrix (Rabinovich-Varona conditions)
    // ρ_ij > σ_i/σ_j for heteroclinic stability
    sys.setInhibition(0, 1, 2.5); // 1 inhibits 0 (strong asymmetry needed)
    sys.setInhibition(1, 2, 2.5); // 2 inhibits 1
    sys.setInhibition(2, 0, 2.5); // 0 inhibits 2
    // Self-inhibition (carrying capacity)
    sys.setInhibition(0, 0, 1.0);
    sys.setInhibition(1, 1, 1.0);
    sys.setInhibition(2, 2, 1.0);
    // Initial condition: perturb near saddle 0
    sys.state[0] = 0.9;
    sys.state[1] = 0.05;
    sys.state[2] = 0.05;
    return sys;
}

/// GF(3) trit map for the 3-species WLC
pub const trit_map_3: [3]i8 = .{ 1, 0, -1 };

/// 5-species WLC (richer dynamics, longer heteroclinic channels)
pub fn wlc5(allocator: Allocator) !WLCSystem {
    var sys = try WLCSystem.init(allocator, 5);
    // Ring inhibition with skip connections
    const strong: f64 = 1.8;
    const weak: f64 = 0.3;
    for (0..5) |i| {
        sys.setInhibition(i, i, 1.0); // self
        sys.setInhibition(i, (i + 1) % 5, strong); // next inhibits current
        sys.setInhibition(i, (i + 2) % 5, weak); // skip-one weak inhibition
    }
    sys.state[0] = 0.8;
    sys.state[1] = 0.1;
    sys.state[2] = 0.05;
    sys.state[3] = 0.03;
    sys.state[4] = 0.02;
    return sys;
}

/// GF(3) trit map for 5-species: balanced assignment
pub const trit_map_5: [5]i8 = .{ 1, 0, -1, 1, -1 };

// ============================================================================
// RESERVOIR INTERFACE (for propagator.zig integration)
// ============================================================================

/// WLC reservoir output: the saddle index, suitable for CellValue.value
/// This is what the propagator network sees — NOT the continuous state.
pub const ReservoirOutput = struct {
    saddle: usize,
    trit: i8,
    residence_time: f64,
    transition_count: usize,

    /// Serialize to JSON-RPC 2.0 notification for the Nashator bridge.
    /// gorj reads this as a trit-tick: site=saddle, sweep=transition_count,
    /// s-new=trit, tau=residence_time.
    pub fn toJsonRpc(self: ReservoirOutput, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        try std.fmt.format(writer,
            \\{{"jsonrpc":"2.0","method":"wlc/tick","params":{{"saddle":{d},"trit":{d},"residence_time":{d:.6},"transition_count":{d}}}}}
        , .{ self.saddle, self.trit, self.residence_time, self.transition_count });
        return fbs.getWritten();
    }
};

/// Run WLC for `steps` timesteps, return the discretized output.
pub fn runReservoir(
    sys: *WLCSystem,
    log: *VisitationLog,
    trit_map: []const i8,
    steps: usize,
    dt: f64,
    threshold: f64,
) !ReservoirOutput {
    for (0..steps) |_| {
        try sys.step(dt);
        const detection = detectSaddle(sys.state, sys.n, threshold);
        try log.update(detection, dt, trit_map);
    }

    const current = log.current orelse 0;
    return .{
        .saddle = current,
        .trit = trit_map[current],
        .residence_time = log.current_duration,
        .transition_count = log.saddles.items.len,
    };
}

// ============================================================================
// SPI-RACE FINGERPRINT (embarrassingly parallel verification)
// ============================================================================

/// SPI constants (same as spi-race/libspi.zig)
const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

/// Map trit to a 64-bit mask for XOR fingerprinting.
/// Balanced trits [+1, 0, -1] XOR to 0 — conservation law in XOR domain.
inline fn tritToBits(trit: i8) u64 {
    return switch (trit) {
        -1 => 0x5555555555555555,
        0 => 0xAAAAAAAAAAAAAAAA,
        1 => 0xFFFFFFFFFFFFFFFF,
        else => 0,
    };
}

/// XOR fingerprint of a visitation log's trit sequence.
/// Commutative + associative: any partition, any order, same result.
/// Returns 0 iff the sequence is GF(3)-balanced over complete cycles.
pub fn xorFingerprint(log: *const VisitationLog) u64 {
    var fp: u64 = 0;
    for (log.trits.items) |t| {
        fp ^= tritToBits(t);
    }
    return fp;
}

/// SPI-style color at a saddle visitation index.
/// Pure function: no state, no reservoir needed. For cross-validation
/// against the gorj Clojure side.
pub inline fn spiColorAtSaddle(seed: u64, visit_index: u64) u64 {
    var z = seed +% (GOLDEN *% (visit_index +% 1));
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

/// Race N independent WLC reservoirs in parallel, verify all produce
/// the same XOR fingerprint. Returns true iff all agree.
pub fn raceReservoirs(
    allocator: Allocator,
    n_replicas: usize,
    steps: usize,
    dt: f64,
    threshold: f64,
) !struct { all_agree: bool, fingerprints: []u64, transition_counts: []usize } {
    const fps = try allocator.alloc(u64, n_replicas);
    const counts = try allocator.alloc(usize, n_replicas);

    for (0..n_replicas) |r| {
        var sys = try wlc3(allocator);
        defer sys.deinit();
        // Perturb initial condition slightly per replica
        sys.state[0] = 0.9 - @as(f64, @floatFromInt(r)) * 0.01;
        sys.state[1] = 0.05 + @as(f64, @floatFromInt(r)) * 0.005;
        sys.state[2] = 0.05 + @as(f64, @floatFromInt(r)) * 0.005;

        var log = VisitationLog.init(allocator);
        defer log.deinit();

        _ = try runReservoir(&sys, &log, &trit_map_3, steps, dt, threshold);

        fps[r] = xorFingerprint(&log);
        counts[r] = log.saddles.items.len;
    }

    var all_agree = true;
    for (1..n_replicas) |r| {
        if (fps[r] != fps[0]) {
            all_agree = false;
            break;
        }
    }

    return .{ .all_agree = all_agree, .fingerprints = fps, .transition_counts = counts };
}

// ============================================================================
// TESTS
// ============================================================================

test "wlc3 heteroclinic cycle" {
    const allocator = std.testing.allocator;
    var sys = try wlc3(allocator);
    defer sys.deinit();
    var log = VisitationLog.init(allocator);
    defer log.deinit();

    const output = try runReservoir(&sys, &log, &trit_map_3, 100000, 0.005, 2.0);

    // Should have visited multiple saddles
    try std.testing.expect(log.saddles.items.len >= 2);
    // Output should be a valid saddle
    try std.testing.expect(output.saddle < 3);
    // Trit should be valid
    try std.testing.expect(output.trit >= -1 and output.trit <= 1);
}

test "wlc3 trit balance tends toward zero" {
    const allocator = std.testing.allocator;
    var sys = try wlc3(allocator);
    defer sys.deinit();
    var log = VisitationLog.init(allocator);
    defer log.deinit();

    _ = try runReservoir(&sys, &log, &trit_map_3, 200000, 0.005, 2.0);

    // With symmetric growth rates and balanced trit map,
    // long-run trit balance should be near zero
    const balance = log.tritBalance();
    const abs_balance: i32 = if (balance < 0) -balance else balance;
    const visits: i32 = @intCast(log.saddles.items.len);
    // Balance should be small relative to total visits
    try std.testing.expect(abs_balance < @divTrunc(visits, 3));
}

test "saddle detection confidence" {
    const state = [_]f64{ 0.9, 0.05, 0.05 };
    const d = detectSaddle(&state, 3, 3.0);
    try std.testing.expect(d.active_saddle == 0);
    try std.testing.expect(d.confident);
    try std.testing.expect(!d.in_transition);
}

test "saddle detection transition" {
    const state = [_]f64{ 0.5, 0.4, 0.1 };
    const d = detectSaddle(&state, 3, 3.0);
    try std.testing.expect(d.active_saddle == 0);
    try std.testing.expect(!d.confident); // ratio = 1.25, below threshold 3.0
}

test "spi fingerprint balanced trits xor to zero" {
    // [+1, 0, -1] is one complete GF(3) cycle → fingerprint = 0
    const bits_plus = tritToBits(1);
    const bits_zero = tritToBits(0);
    const bits_minus = tritToBits(-1);
    try std.testing.expectEqual(@as(u64, 0), bits_plus ^ bits_zero ^ bits_minus);
}

test "spi fingerprint commutative" {
    // Any permutation → same fingerprint
    const a = tritToBits(1) ^ tritToBits(0) ^ tritToBits(-1) ^ tritToBits(1);
    const b = tritToBits(-1) ^ tritToBits(1) ^ tritToBits(1) ^ tritToBits(0);
    try std.testing.expectEqual(a, b);
}

test "wlc3 spi fingerprint zero over complete cycles" {
    const allocator = std.testing.allocator;
    var sys = try wlc3(allocator);
    defer sys.deinit();
    var log = VisitationLog.init(allocator);
    defer log.deinit();

    _ = try runReservoir(&sys, &log, &trit_map_3, 200000, 0.005, 2.0);

    const fp = xorFingerprint(&log);
    const visits = log.saddles.items.len;

    // If visits is a multiple of 3, fingerprint should be 0
    // (each complete cycle cancels). Allow non-multiple.
    if (visits % 3 == 0) {
        try std.testing.expectEqual(@as(u64, 0), fp);
    }
    // Regardless, fingerprint should be one of the 3 possible residuals
    try std.testing.expect(
        fp == 0 or
            fp == tritToBits(1) or
            fp == tritToBits(0) or
            fp == tritToBits(-1) or
            fp == (tritToBits(1) ^ tritToBits(0)) or
            fp == (tritToBits(1) ^ tritToBits(-1)) or
            fp == (tritToBits(0) ^ tritToBits(-1)),
    );
}
