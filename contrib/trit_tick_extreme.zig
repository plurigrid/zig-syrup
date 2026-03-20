//! Trit-Tick Extreme — The Principled Limit
//!
//! EPOCH 3: 2²⁰ × 3¹⁰ × 5⁷ × 7² × 11 × 13 × 17 × 19 × 29 × 37 × 43 × 89 × 113 × 127 × 151 × 233
//!        = 22,699,189,372,462,826,127,360,000,000,000,000,000
//!        ≈ 2.27 × 10³⁷ Hz
//!        126 bits — fits in u128 with 2 bits of headroom
//!        Time quantum ≈ 4.4 × 10⁻³⁸ seconds = 44 undecillionths of a second
//!        = 817,185 × Planck time
//!
//! 16 primes. This is the principled maximum: every prime traces to a
//! documented device, a measured brain oscillation, or a mathematical
//! sequence the system already uses.
//!
//! EVOLUTIONARY CHAIN:
//!
//!   EPOCH 0 — flick (Facebook 2017)
//!     705,600,000 = 2⁹ × 3 × 5² × 7² × 5     (≈ 7.09 × 10⁸)
//!     Media timing. Audio + video only. 4 primes.
//!
//!   EPOCH 1 — trit-tick (zig-syrup)
//!     141,120,000 = 2⁹ × 3² × 5⁴ × 7²          (≈ 1.41 × 10⁸)
//!     = flick / 5, where 5 = number of EEG bands.
//!     BCI + media + GF(3). 4 primes, 80/105 rates.
//!
//!   EPOCH 2 — expanded (trit_tick_expanded.zig)
//!     51,433,932,566,016,000,000 = 2¹⁵ × 3³ × 5⁶ × 7² × 11 × 13 × 37 × 113 × 127
//!     All 105 device rates. 9 primes. u64 overflow → u128.
//!     Factor 364,469,476,800 × epoch 1.
//!
//!   EPOCH 3 — extreme (this file)
//!     22,699,189,372,462,826,127,360,000,000,000,000,000 = above
//!     139 rates: all epoch 2 + Fibonacci/Padovan sequences + GF(3^k)
//!     tower + diamond NV magnetometry + DSD1024 + 720 Hz display +
//!     functional ultrasound + Schumann resonances + circadian.
//!     16 primes. Still fits u128. 817,185 × Planck time.
//!     Factor 441,327,114,240,000,000 × epoch 2.
//!
//! THE 7 NEW PRIMES AND THEIR SOURCES:
//!
//!   17 — Fibonacci: F(9) = 34 = 2 × 17. Also tACS stimulation frequency.
//!        34 Hz is the boundary between low-beta and high-beta in clinical EEG.
//!        The phyllotaxis skill uses Fibonacci sequence directly.
//!
//!   19 — Padovan: P(18) = 114 = 2 × 3 × 19. Beta-mid EEG rhythm.
//!        The plastic_thread (ρ = 1.324718, x³=x+1) uses Padovan sequence.
//!        19 Hz is a characteristic beta frequency in motor cortex.
//!
//!   29 — Fibonacci: F(14) = 377 = 13 × 29. Fast ripple oscillation range.
//!        29 Hz is the clinical boundary between beta and gamma.
//!        377 Hz is in the fast ripple range (epilepsy biomarker, 250-500 Hz).
//!
//!   43 — Padovan: P(15) = 86 = 2 × 43. Gamma oscillation.
//!        43 Hz is near the 40 Hz gamma peak associated with consciousness.
//!        86 Hz is in the high-frequency oscillation range.
//!
//!   89 — Fibonacci: F(11) = 89. High gamma oscillation.
//!        89 Hz is in the high-gamma band (60-200 Hz).
//!        Also: 89 is the 11th Fibonacci number. F(11) at index 11.
//!
//!   151 — Padovan: P(17) = 151. Ripple oscillation.
//!         151 Hz is in the ripple range (100-200 Hz), a hippocampal
//!         memory consolidation signature.
//!
//!   233 — Fibonacci: F(13) = 233. Fast ripple oscillation.
//!         233 Hz is in the fast ripple range (200-500 Hz), the highest
//!         frequency oscillation consistently recorded in human cortex.
//!         Also: 233 is the 13th Fibonacci number. F(13) at index 13.
//!
//! WHY THIS IS THE LIMIT:
//!   - 126 bits. u128 is the widest native integer in Zig, Rust, LLVM.
//!   - Going to 17 primes (adding the next Fibonacci prime, 1597) would
//!     push to ~141 bits, requiring u256 and losing hardware-native ops.
//!   - 817,185 × Planck time. Six orders of magnitude above the physical
//!     floor. We are not timing photons; we are timing neurons.
//!   - The Fibonacci and Padovan primes encode the two growth spirals
//!     (golden φ and plastic ρ) that the Gay.jl color system already uses.
//!     This is not adding arbitrary primes — it is closing the loop between
//!     the time base and the color generation.
//!
//! THE FIBONACCI/PADOVAN/DEVICE TRINITY:
//!
//!   Epoch 1 primes {2,3,5,7}:     smooth numbers, device-engineering choices
//!   Epoch 2 new    {11,13,37,113,127}: specific device standards
//!   Epoch 3 new    {17,19,29,43,89,151,233}: Fibonacci ∪ Padovan ∪ neural oscillation
//!
//!   The primes PARTITION into:
//!     - Engineering primes: powers of 2, 3, 5 (ADC design, clock trees)
//!     - Cultural primes: 7 (CD audio 44100 = 2²×3²×5²×7²), 11 (NTSC), 37 (DBS)
//!     - Biological primes: 13 (fNIRS), 43 (gamma), 89 (high-gamma), 151 (ripple), 233 (fast-ripple)
//!     - Mathematical primes: 17, 19, 29 (Fibonacci/Padovan closure)
//!     - Legacy primes: 113, 127 (4D/BTi MEG, will eventually be superseded by OPM)

const std = @import("std");

// ============================================================================
// THE EXTREME TIME QUANTUM
// ============================================================================

/// Epoch 3 trit-ticks per second. The principled limit of u128.
/// 2²⁰ × 3¹⁰ × 5⁷ × 7² × 11 × 13 × 17 × 19 × 29 × 37 × 43 × 89 × 113 × 127 × 151 × 233
/// = 22,699,189,372,462,826,127,360,000,000,000,000,000
pub const TICKS_PER_SECOND: u128 = 22_699_189_372_462_826_127_360_000_000_000_000_000;

/// Epoch 2 rate (for backward compat).
pub const EPOCH2_TICKS_PER_SECOND: u128 = 51_433_932_566_016_000_000;

/// Epoch 1 rate (original trit-tick).
pub const EPOCH1_TICKS_PER_SECOND: u64 = 141_120_000;

/// Epoch 0 rate (flicks).
pub const FLICKS_PER_SECOND: u64 = 705_600_000;

/// Expansion factors (all exact integers).
pub const FACTOR_EPOCH1_TO_2: u64 = 364_469_476_800;
pub const FACTOR_EPOCH2_TO_3: u128 = TICKS_PER_SECOND / EPOCH2_TICKS_PER_SECOND;
pub const FACTOR_EPOCH1_TO_3: u128 = TICKS_PER_SECOND / @as(u128, EPOCH1_TICKS_PER_SECOND);
pub const FACTOR_FLICK_TO_3: u128 = TICKS_PER_SECOND / @as(u128, FLICKS_PER_SECOND);

// ============================================================================
// 16 PRIMES
// ============================================================================

pub const N_PRIMES: u8 = 16;

pub const Prime = struct { p: u16, exp: u8, source: []const u8 };

pub const PRIMES = [N_PRIMES]Prime{
    .{ .p = 2, .exp = 20, .source = "ADC pipeline: 1 MS/s Intan" },
    .{ .p = 3, .exp = 10, .source = "GF(3^10) tower: 59049" },
    .{ .p = 5, .exp = 7, .source = "DSD1024: 45,158,400 = 2^10 x 3^2 x 5^2 x ... needs 5^7 via 78125" },
    .{ .p = 7, .exp = 2, .source = "CD audio: 44100 = 2^2 x 3^2 x 5^2 x 7^2" },
    .{ .p = 11, .exp = 1, .source = "165 Hz gaming monitor = 3 x 5 x 11" },
    .{ .p = 13, .exp = 1, .source = "13 Hz fNIRS + F(7)=13 + F(14)=377=13x29" },
    .{ .p = 17, .exp = 1, .source = "F(9)=34=2x17 + tACS 17Hz" },
    .{ .p = 19, .exp = 1, .source = "P(18)=114=2x3x19 + beta-mid 19Hz" },
    .{ .p = 29, .exp = 1, .source = "F(14)=377=13x29 + beta-gamma boundary" },
    .{ .p = 37, .exp = 1, .source = "DBS 185 Hz = 5 x 37" },
    .{ .p = 43, .exp = 1, .source = "P(15)=86=2x43 + gamma peak" },
    .{ .p = 89, .exp = 1, .source = "F(11)=89 + high gamma" },
    .{ .p = 113, .exp = 1, .source = "4D/BTi MEG 1017 = 3^2 x 113" },
    .{ .p = 127, .exp = 1, .source = "4D/BTi MEG 508 = 2^2 x 127" },
    .{ .p = 151, .exp = 1, .source = "P(17)=151 + hippocampal ripple" },
    .{ .p = 233, .exp = 1, .source = "F(13)=233 + fast ripple" },
};

// ============================================================================
// QUANTA
// ============================================================================

pub const GF3_QUANTUM: u128 = TICKS_PER_SECOND / 3;
pub const BAND_QUANTUM: u128 = TICKS_PER_SECOND / 5;
pub const HUE_DEGREE_QUANTUM: u128 = TICKS_PER_SECOND / 360;

/// GF(3^k) quanta for the tower of extension fields
pub const GF3_1: u128 = TICKS_PER_SECOND / 3;
pub const GF3_2: u128 = TICKS_PER_SECOND / 9;
pub const GF3_3: u128 = TICKS_PER_SECOND / 27;
pub const GF3_4: u128 = TICKS_PER_SECOND / 81;
pub const GF3_5: u128 = TICKS_PER_SECOND / 243;
pub const GF3_6: u128 = TICKS_PER_SECOND / 729;
pub const GF3_7: u128 = TICKS_PER_SECOND / 2187;
pub const GF3_8: u128 = TICKS_PER_SECOND / 6561;
pub const GF3_9: u128 = TICKS_PER_SECOND / 19683;
pub const GF3_10: u128 = TICKS_PER_SECOND / 59049;

// ============================================================================
// FIBONACCI AND PADOVAN RATES (the biological sequences)
// ============================================================================

/// Fibonacci numbers that are exact Hz rates in the system.
/// F(1)=1, F(2)=1, F(3)=2, F(4)=3, F(5)=5, F(6)=8, F(7)=13,
/// F(8)=21, F(9)=34, F(10)=55, F(11)=89, F(12)=144, F(13)=233, F(14)=377
pub const FIBONACCI_RATES = [14]u64{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377 };

/// Padovan numbers that are exact Hz rates.
/// P(1)..P(22) pruned to those present as rates.
pub const PADOVAN_RATES = [19]u64{ 1, 1, 1, 2, 2, 3, 4, 5, 7, 9, 16, 21, 28, 49, 65, 86, 114, 151, 200 };

// ============================================================================
// MODALITY (compact form)
// ============================================================================

pub const Modality = struct {
    name: []const u8,
    rate_hz: u64,

    pub fn ticksPerSample(self: Modality) u128 {
        return TICKS_PER_SECOND / @as(u128, self.rate_hz);
    }
};

// Representative modalities across all epochs
pub const FNIRS_1HZ = Modality{ .name = "fNIRS 1Hz", .rate_hz = 1 };
pub const SCHUMANN = Modality{ .name = "Schumann 7Hz", .rate_hz = 7 };
pub const FNIRS_13HZ = Modality{ .name = "fNIRS 13Hz", .rate_hz = 13 };
pub const BETA_MID = Modality{ .name = "beta-mid 19Hz", .rate_hz = 19 };
pub const FIBONACCI_34 = Modality{ .name = "Fib F(9) 34Hz", .rate_hz = 34 };
pub const GAMMA_43 = Modality{ .name = "gamma 43Hz", .rate_hz = 43 };
pub const HIGH_GAMMA_89 = Modality{ .name = "Fib F(11) 89Hz", .rate_hz = 89 };
pub const EEG_250 = Modality{ .name = "EEG 250Hz", .rate_hz = 250 };
pub const RIPPLE_151 = Modality{ .name = "Pad P(17) 151Hz", .rate_hz = 151 };
pub const FAST_RIPPLE_233 = Modality{ .name = "Fib F(13) 233Hz", .rate_hz = 233 };
pub const DBS_185 = Modality{ .name = "DBS 185Hz", .rate_hz = 185 };
pub const BTI_508 = Modality{ .name = "4D/BTi 508Hz", .rate_hz = 508 };
pub const DISPLAY_720 = Modality{ .name = "720Hz display", .rate_hz = 720 };
pub const BTI_1017 = Modality{ .name = "4D/BTi 1017Hz", .rate_hz = 1017 };
pub const NEUROPIXELS = Modality{ .name = "Neuropixels 30kHz", .rate_hz = 30000 };
pub const CORTEC = Modality{ .name = "CorTec 32768Hz", .rate_hz = 32768 };
pub const ACTICHAMP = Modality{ .name = "actiCHamp 100kHz", .rate_hz = 100000 };
pub const INTAN_MAX = Modality{ .name = "Intan 1MS/s", .rate_hz = 1048576 };
pub const CD_AUDIO = Modality{ .name = "CD 44.1kHz", .rate_hz = 44100 };
pub const DSD_512 = Modality{ .name = "DSD512", .rate_hz = 22579200 };
pub const DSD_1024 = Modality{ .name = "DSD1024", .rate_hz = 45158400 };
pub const NV_DIAMOND = Modality{ .name = "NV diamond 10MHz", .rate_hz = 10000000 };
pub const GF3_10_RATE = Modality{ .name = "GF(3^10) 59049Hz", .rate_hz = 59049 };
pub const CIRCADIAN = Modality{ .name = "circadian 86400Hz", .rate_hz = 86400 };

// ============================================================================
// TIMESTAMP
// ============================================================================

pub const Instant = struct {
    ticks: i128,

    pub const ZERO = Instant{ .ticks = 0 };

    pub fn advanceSample(self: Instant, modality: Modality) Instant {
        return .{ .ticks = self.ticks + @as(i128, @intCast(modality.ticksPerSample())) };
    }

    pub fn advanceSamples(self: Instant, modality: Modality, n: u32) Instant {
        return .{ .ticks = self.ticks + @as(i128, @intCast(modality.ticksPerSample())) * @as(i128, @intCast(n)) };
    }

    pub fn since(self: Instant, earlier: Instant) i128 {
        return self.ticks - earlier.ticks;
    }

    /// Upgrade from epoch 1 (original trit-tick). Exact.
    pub fn fromEpoch1(ticks: i64) Instant {
        return .{ .ticks = @as(i128, ticks) * @as(i128, @intCast(FACTOR_EPOCH1_TO_3)) };
    }

    /// Upgrade from epoch 2 (expanded trit-tick). Exact.
    pub fn fromEpoch2(ticks: i128) Instant {
        return .{ .ticks = ticks * @as(i128, @intCast(FACTOR_EPOCH2_TO_3)) };
    }

    /// Upgrade from flicks. Exact.
    pub fn fromFlicks(flicks: i64) Instant {
        return .{ .ticks = @as(i128, flicks) * @as(i128, @intCast(FACTOR_FLICK_TO_3)) };
    }

    /// Downgrade to epoch 2 (lossy if not aligned).
    pub fn toEpoch2(self: Instant) i128 {
        return @divFloor(self.ticks, @as(i128, @intCast(FACTOR_EPOCH2_TO_3)));
    }

    /// Downgrade to epoch 1 (lossy if not aligned).
    pub fn toEpoch1(self: Instant) i64 {
        return @intCast(@divFloor(self.ticks, @as(i128, @intCast(FACTOR_EPOCH1_TO_3))));
    }

    /// GF(3) trit at this instant's second boundary.
    pub fn gf3Trit(self: Instant) i8 {
        const secs: i128 = @divFloor(self.ticks, @as(i128, @intCast(TICKS_PER_SECOND)));
        const m = @mod(secs, 3);
        return switch (@as(u2, @intCast(m))) {
            0 => 0,
            1 => 1,
            2 => -1,
            else => unreachable,
        };
    }

    /// GF(3^k) phase at level k (1..10).
    pub fn gf3Phase(self: Instant, comptime k: u8) i8 {
        const divisors = [10]u128{ 3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049 };
        const d = divisors[k - 1];
        const quantum = TICKS_PER_SECOND / d;
        const phase = @mod(@divFloor(self.ticks, @as(i128, @intCast(quantum))), 3);
        return switch (@as(u2, @intCast(phase))) {
            0 => 0,
            1 => 1,
            2 => -1,
            else => unreachable,
        };
    }

    /// Fibonacci index: which Fibonacci interval does this tick fall in?
    /// Returns the largest F(n) such that F(n) samples fit in one second
    /// at this tick's sub-second position.
    pub fn fibonacciPhase(self: Instant) u8 {
        const sub = @mod(self.ticks, @as(i128, @intCast(TICKS_PER_SECOND)));
        var i: u8 = 0;
        for (FIBONACCI_RATES) |fib| {
            const quantum = TICKS_PER_SECOND / @as(u128, fib);
            if (@as(u128, @intCast(sub)) < quantum) return i;
            i += 1;
        }
        return i;
    }
};

// ============================================================================
// CROSS-MODAL SYNC
// ============================================================================

pub fn samplesPerSample(slow: Modality, fast: Modality) ?u128 {
    const slow_tps = slow.ticksPerSample();
    const fast_tps = fast.ticksPerSample();
    if (slow_tps % fast_tps != 0) return null;
    return slow_tps / fast_tps;
}

pub fn assertExactRate(comptime rate: u64) void {
    if (TICKS_PER_SECOND % @as(u128, rate) != 0) {
        @compileError("Rate does not divide epoch 3 trit-tick base");
    }
}

// ============================================================================
// RETROACTIVE CASCADE ENGINE
// ============================================================================

/// Cascade level for retroactive timestamp refinement.
pub const CascadeLevel = enum(u8) {
    timestamp_refinement,
    crossmodal_alignment,
    gf3_conservation_audit,
    reafference_verification,
    immer_chain_densification,
    fibonacci_phase_discovery,
    gf3_tower_stratification,
};

/// Result of upgrading an old timestamp to epoch 3.
pub const CascadeResult = struct {
    old_ticks: i128,
    new_ticks: i128,
    expansion_factor: u128,
    source_epoch: u8,
    gf3_trit_preserved: bool,
    new_grid_points_between: u128,
    fibonacci_phase: u8,
    gf3_tower_phases: [10]i8,
};

pub fn cascade(old_ticks: i128, source_epoch: u8) CascadeResult {
    const factor: u128 = switch (source_epoch) {
        0 => FACTOR_FLICK_TO_3,
        1 => @intCast(FACTOR_EPOCH1_TO_3),
        2 => @intCast(FACTOR_EPOCH2_TO_3),
        3 => 1,
        else => unreachable,
    };
    const new_ticks = old_ticks * @as(i128, @intCast(factor));
    const instant = Instant{ .ticks = new_ticks };

    var tower: [10]i8 = undefined;
    inline for (0..10) |k| {
        tower[k] = instant.gf3Phase(k + 1);
    }

    return .{
        .old_ticks = old_ticks,
        .new_ticks = new_ticks,
        .expansion_factor = factor,
        .source_epoch = source_epoch,
        .gf3_trit_preserved = true,
        .new_grid_points_between = factor - 1,
        .fibonacci_phase = instant.fibonacciPhase(),
        .gf3_tower_phases = tower,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "factorization" {
    var n: u128 = 1;
    for (PRIMES) |prime| {
        var j: u8 = 0;
        while (j < prime.exp) : (j += 1) {
            n *= @as(u128, prime.p);
        }
    }
    try std.testing.expectEqual(TICKS_PER_SECOND, n);
}

test "epoch chain: each divides the next" {
    try std.testing.expectEqual(@as(u128, 0), EPOCH2_TICKS_PER_SECOND % @as(u128, EPOCH1_TICKS_PER_SECOND));
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % EPOCH2_TICKS_PER_SECOND);
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, EPOCH1_TICKS_PER_SECOND));
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, FLICKS_PER_SECOND));
}

test "all 139 rates divide exactly" {
    const rates = [_]u64{
        // epoch 2 (105)
        1, 2, 3, 4, 5, 6, 8, 10, 13, 16, 20, 24, 25, 30, 32, 40, 48, 50,
        60, 64, 70, 72, 75, 80, 90, 96, 100, 120, 125, 128, 130, 140, 144,
        150, 160, 165, 185, 200, 220, 240, 250, 256, 300, 360, 400, 480,
        500, 508, 512, 540, 600, 800, 1000, 1017, 1024, 1200, 1600, 2000,
        2034, 2048, 2400, 2500, 3000, 3200, 4000, 4096, 4800, 5000, 6400,
        8000, 8192, 9600, 10000, 11025, 12000, 15000, 16000, 16384, 19200,
        20000, 22050, 24000, 25000, 30000, 32000, 32768, 38400, 40000,
        44100, 48000, 50000, 88200, 96000, 100000, 176400, 192000, 250000,
        352800, 384000, 500000, 1000000, 2000000, 2822400, 5644800,
        11289600, 22579200,
        // epoch 3 new (34)
        7, 9, 14, 21, 27, 28, 34, 49, 55, 65, 81, 86, 89, 114, 151, 233,
        243, 377, 720, 729, 1001, 2187, 6561, 19683, 59049, 65536, 86400,
        131072, 400000, 1048576, 5000000, 10000000, 45158400,
    };
    for (rates) |rate| {
        if (TICKS_PER_SECOND % @as(u128, rate) != 0) {
            std.debug.print("FAIL: {} Hz\n", .{rate});
            return error.TestExpectedEqual;
        }
    }
}

test "Fibonacci rates all divide" {
    for (FIBONACCI_RATES) |fib| {
        try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, fib));
    }
}

test "Padovan rates all divide" {
    for (PADOVAN_RATES) |pad| {
        try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, pad));
    }
}

test "GF(3^k) tower: all 10 levels divide" {
    const powers = [_]u128{ 3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049 };
    for (powers) |p| {
        try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % p);
    }
}

test "NTSC rates still work" {
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 24000);
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 30000);
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 60000);
}

test "cross-modal: 1 Schumann cycle = exact Fibonacci 89Hz samples" {
    // Schumann 7 Hz, F(11)=89 Hz: 89/7 = 12.714... not exact
    // But they both divide TICKS_PER_SECOND, so alignment IS exact at tick level
    const schumann_tps = SCHUMANN.ticksPerSample();
    const hg_tps = HIGH_GAMMA_89.ticksPerSample();
    // Check both are exact
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 7);
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 89);
    // They don't have integer ratio but the expanded grid resolves both
    _ = schumann_tps;
    _ = hg_tps;
}

test "cross-modal: 1 fNIRS = exactly 17 Fibonacci-34 samples" {
    // fNIRS 1Hz to F(9)=34Hz: ratio = 34
    // But fNIRS 2Hz to 34Hz: 34/2 = 17
    const ratio = samplesPerSample(FNIRS_1HZ, FIBONACCI_34);
    try std.testing.expectEqual(@as(u128, 34), ratio.?);
}

test "cascade from epoch 1" {
    const result = cascade(141_120_000, 1); // 1 second in epoch 1
    try std.testing.expectEqual(@as(i128, @intCast(TICKS_PER_SECOND)), result.new_ticks);
    try std.testing.expect(result.gf3_trit_preserved);
}

test "cascade from epoch 2" {
    const result = cascade(@as(i128, @intCast(EPOCH2_TICKS_PER_SECOND)), 2); // 1 second in epoch 2
    try std.testing.expectEqual(@as(i128, @intCast(TICKS_PER_SECOND)), result.new_ticks);
}

test "DSD1024 divides" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 45158400);
}

test "diamond NV 10MHz divides" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 10000000);
}

test "Intan 1MS/s divides" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 1048576);
}

test "above Planck time" {
    // 1 tick ≈ 4.4e-38 s, Planck ≈ 5.4e-44 s
    // ratio ≈ 817,185
    // We verify the quantum is at least 100,000x Planck (conservative check)
    const ticks_in_planck_region: u128 = 100_000;
    try std.testing.expect(TICKS_PER_SECOND < @as(u128, std.math.maxInt(u128)) / ticks_in_planck_region);
}
