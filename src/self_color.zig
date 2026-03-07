//! SelfColor — Bandwidth for self-color perception
//!
//! Connects bubbletea/VHS observation (tape_recorder), Lux color space,
//! Arrow IPC zero-copy transport (arrow_color_ipc), and Gay.jl reafference
//! verification into a single perceptual control loop.
//!
//! Architecture:
//!   1. Agent generates ColorValue at (seed, index) — the efference copy
//!   2. Color travels through Arrow IPC batch (zero-copy, referentially transparent)
//!   3. Observer receives color and computes CIEDE2000 against prediction
//!   4. Reafference match: Delta-E < JND means "I generated this" (self)
//!   5. Exafference: Delta-E > JND means "world changed" (other)
//!   6. VHS tape records the perception events for episodic replay
//!
//! CUE lattice semantics:
//!   Each perception claim is a CUE value: { seed: int, index: int, hex: string }
//!   Unification: claim & observation must be compatible (Delta-E < threshold)
//!   Bottom (_|_): contradiction when prediction fails reafference check
//!
//! The three checkpoints (from PerceptualColourMaps.jl / color_bandwidth.zig):
//!   FIRST observation, LAST observation, and RANDOM observation per batch
//!   must all pass reafference. If any fails, the batch is exafferent.
//!
//! GF(3): self_color is ERGODIC (0) — the observer that mediates between
//! generator (+1) and validator (-1).

const std = @import("std");
const color_bandwidth = @import("color_bandwidth.zig");
const color_value = @import("color_value.zig");
const lux_color = @import("lux_color.zig");

const ColorValue = color_value.ColorValue;
const Trit = color_value.Trit;
const RGB = color_value.RGB;
const TritWord = color_value.TritWord;

// =============================================================================
// SplitMix64 (shared with color_value.zig, color_bandwidth.zig, Gay.jl)
// =============================================================================

const GOLDEN: u64 = 0x9E3779B97F4A7C15;

fn splitmix64(x: u64) u64 {
    var z = x +% GOLDEN;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn colorAtRaw(seed: u64, index: u64) u64 {
    return splitmix64(seed +% (GOLDEN *% index));
}

// =============================================================================
// Efference Copy: the predicted color before observation
// =============================================================================

pub const EfferenceCopy = struct {
    seed: u64,
    index: u64,
    predicted_rgb: [3]u8,
    predicted_trit: Trit,
    timestamp_ms: i64,

    pub fn generate(seed: u64, index: u64, timestamp_ms: i64) EfferenceCopy {
        const raw = colorAtRaw(seed, index);
        const word = TritWord.fromIndex(@intCast(raw % 243));
        const rgb = color_value.at(seed, index);
        return .{
            .seed = seed,
            .index = index,
            .predicted_rgb = .{ rgb.r, rgb.g, rgb.b },
            .predicted_trit = Trit.fromU64(raw),
            .timestamp_ms = timestamp_ms,
        };
    }
};

// =============================================================================
// Observation: the received color after transport
// =============================================================================

pub const Observation = struct {
    observed_rgb: [3]u8,
    observed_trit: Trit,
    timestamp_ms: i64,
    source: Source,

    pub const Source = enum(u8) {
        arrow_ipc,
        vhs_tape,
        dom_backend,
        direct,
    };

    pub fn fromRgb(r: u8, g: u8, b: u8, trit: Trit, ts: i64, src: Source) Observation {
        return .{
            .observed_rgb = .{ r, g, b },
            .observed_trit = trit,
            .timestamp_ms = ts,
            .source = src,
        };
    }
};

// =============================================================================
// Reafference Verdict: self vs world
// =============================================================================

pub const Verdict = enum(u8) {
    reafferent, // Delta-E < JND: I generated this
    exafferent, // Delta-E > JND: world changed it
    contradiction, // trit mismatch: CUE _|_ bottom
};

pub const ReafferenceResult = struct {
    verdict: Verdict,
    delta_e: f32,
    trit_match: bool,
    latency_ms: i64,

    pub fn isself(self: ReafferenceResult) bool {
        return self.verdict == .reafferent;
    }
};

pub const JND_THRESHOLD: f32 = 2.3; // just-noticeable difference (CIEDE2000)

pub fn checkReafference(efference: EfferenceCopy, observation: Observation) ReafferenceResult {
    const delta_e = color_bandwidth.ciede2000(
        color_bandwidth.rgbToLab(efference.predicted_rgb[0], efference.predicted_rgb[1], efference.predicted_rgb[2]),
        color_bandwidth.rgbToLab(observation.observed_rgb[0], observation.observed_rgb[1], observation.observed_rgb[2]),
    );
    const trit_match = efference.predicted_trit == observation.observed_trit;
    const latency = observation.timestamp_ms - efference.timestamp_ms;

    const verdict: Verdict = if (!trit_match)
        .contradiction
    else if (delta_e < JND_THRESHOLD)
        .reafferent
    else
        .exafferent;

    return .{
        .verdict = verdict,
        .delta_e = delta_e,
        .trit_match = trit_match,
        .latency_ms = latency,
    };
}

// =============================================================================
// PerceptionBatch: Arrow IPC style batch with first/last/random checkpoints
// =============================================================================

pub const MAX_BATCH: usize = 4096;

pub const PerceptionBatch = struct {
    seed: u64,
    start_index: u64,
    count: u32,
    efferences: [MAX_BATCH]EfferenceCopy = undefined,
    observations: [MAX_BATCH]Observation = undefined,
    results: [MAX_BATCH]ReafferenceResult = undefined,
    has_observations: bool = false,
    batch_timestamp_ms: i64 = 0,

    pub fn init(seed: u64, start_index: u64, count: u32, timestamp_ms: i64) PerceptionBatch {
        var batch = PerceptionBatch{
            .seed = seed,
            .start_index = start_index,
            .count = @min(count, MAX_BATCH),
            .batch_timestamp_ms = timestamp_ms,
        };
        for (0..batch.count) |i| {
            batch.efferences[i] = EfferenceCopy.generate(seed, start_index + i, timestamp_ms);
        }
        return batch;
    }

    pub fn observe(self: *PerceptionBatch, index: usize, obs: Observation) void {
        if (index >= self.count) return;
        self.observations[index] = obs;
        self.results[index] = checkReafference(self.efferences[index], obs);
        self.has_observations = true;
    }

    /// Simulate perfect transport: observations match predictions exactly
    pub fn observePerfect(self: *PerceptionBatch, obs_timestamp_ms: i64) void {
        for (0..self.count) |i| {
            const ef = self.efferences[i];
            self.observe(i, Observation.fromRgb(
                ef.predicted_rgb[0],
                ef.predicted_rgb[1],
                ef.predicted_rgb[2],
                ef.predicted_trit,
                obs_timestamp_ms,
                .direct,
            ));
        }
    }

    /// Simulate noisy transport: add random perturbation to colors
    pub fn observeNoisy(self: *PerceptionBatch, noise_seed: u64, obs_timestamp_ms: i64) void {
        for (0..self.count) |i| {
            const ef = self.efferences[i];
            const noise = splitmix64(noise_seed +% GOLDEN *% i);
            const nr: i16 = @as(i16, @intCast(noise & 0xF)) - 8;
            const ng: i16 = @as(i16, @intCast((noise >> 4) & 0xF)) - 8;
            const nb: i16 = @as(i16, @intCast((noise >> 8) & 0xF)) - 8;
            self.observe(i, Observation.fromRgb(
                @intCast(std.math.clamp(@as(i16, ef.predicted_rgb[0]) + nr, 0, 255)),
                @intCast(std.math.clamp(@as(i16, ef.predicted_rgb[1]) + ng, 0, 255)),
                @intCast(std.math.clamp(@as(i16, ef.predicted_rgb[2]) + nb, 0, 255)),
                ef.predicted_trit,
                obs_timestamp_ms,
                .arrow_ipc,
            ));
        }
    }

    // =========================================================================
    // Three Checkpoints (PerceptualColourMaps.jl protocol)
    // =========================================================================

    pub fn firstCheckpoint(self: *const PerceptionBatch) ?ReafferenceResult {
        if (!self.has_observations or self.count == 0) return null;
        return self.results[0];
    }

    pub fn lastCheckpoint(self: *const PerceptionBatch) ?ReafferenceResult {
        if (!self.has_observations or self.count == 0) return null;
        return self.results[self.count - 1];
    }

    pub fn randomCheckpoint(self: *const PerceptionBatch) ?ReafferenceResult {
        if (!self.has_observations or self.count < 3) return null;
        const rand_idx = splitmix64(self.seed +% self.seed) % (self.count - 2) + 1;
        return self.results[@intCast(rand_idx)];
    }

    /// All three checkpoints pass reafference?
    pub fn allCheckpointsPass(self: *const PerceptionBatch) bool {
        const first = self.firstCheckpoint() orelse return false;
        const last = self.lastCheckpoint() orelse return false;
        const random = self.randomCheckpoint() orelse return false;
        return first.isself() and last.isself() and random.isself();
    }

    // =========================================================================
    // Batch statistics
    // =========================================================================

    pub fn reafferentCount(self: *const PerceptionBatch) u32 {
        if (!self.has_observations) return 0;
        var count: u32 = 0;
        for (0..self.count) |i| {
            if (self.results[i].verdict == .reafferent) count += 1;
        }
        return count;
    }

    pub fn exafferentCount(self: *const PerceptionBatch) u32 {
        if (!self.has_observations) return 0;
        var count: u32 = 0;
        for (0..self.count) |i| {
            if (self.results[i].verdict == .exafferent) count += 1;
        }
        return count;
    }

    pub fn contradictionCount(self: *const PerceptionBatch) u32 {
        if (!self.has_observations) return 0;
        var count: u32 = 0;
        for (0..self.count) |i| {
            if (self.results[i].verdict == .contradiction) count += 1;
        }
        return count;
    }

    pub fn meanDeltaE(self: *const PerceptionBatch) f32 {
        if (!self.has_observations or self.count == 0) return 0;
        var sum: f32 = 0;
        for (0..self.count) |i| {
            sum += self.results[i].delta_e;
        }
        return sum / @as(f32, @floatFromInt(self.count));
    }

    pub fn maxDeltaE(self: *const PerceptionBatch) f32 {
        if (!self.has_observations or self.count == 0) return 0;
        var max_de: f32 = 0;
        for (0..self.count) |i| {
            if (self.results[i].delta_e > max_de) max_de = self.results[i].delta_e;
        }
        return max_de;
    }

    /// GF(3) trit: batch self-perception quality
    pub fn perceptionTrit(self: *const PerceptionBatch) Trit {
        if (!self.has_observations) return .minus;
        const ratio = @as(f32, @floatFromInt(self.reafferentCount())) / @as(f32, @floatFromInt(self.count));
        if (ratio > 0.95) return .plus; // strong self-recognition
        if (ratio > 0.5) return .zero; // partial
        return .minus; // mostly exafferent
    }
};

// =============================================================================
// CUE Lattice Semantics for Color Claims
// =============================================================================

/// A CUE-style color claim: { seed, index, hex, trit }
/// Unification: two claims unify iff they agree on all fields
/// Bottom: any field mismatch = _|_ (contradiction)
pub const ColorClaim = struct {
    seed: ?u64 = null,
    index: ?u64 = null,
    hex: ?[7]u8 = null, // "#RRGGBB"
    trit: ?Trit = null,

    pub fn fromEfference(ef: EfferenceCopy) ColorClaim {
        return .{
            .seed = ef.seed,
            .index = ef.index,
            .hex = hexEncode(ef.predicted_rgb),
            .trit = ef.predicted_trit,
        };
    }

    pub fn fromObservation(obs: Observation) ColorClaim {
        return .{
            .seed = null,
            .index = null,
            .hex = hexEncode(obs.observed_rgb),
            .trit = obs.observed_trit,
        };
    }

    /// CUE unification: a & b
    pub fn unify(a: ColorClaim, b: ColorClaim) ?ColorClaim {
        var result: ColorClaim = .{};

        // seed
        if (a.seed != null and b.seed != null and a.seed.? != b.seed.?) return null;
        result.seed = a.seed orelse b.seed;

        // index
        if (a.index != null and b.index != null and a.index.? != b.index.?) return null;
        result.index = a.index orelse b.index;

        // hex (allow perceptual near-match via CIEDE2000)
        if (a.hex != null and b.hex != null) {
            const a_rgb = hexDecode(a.hex.?);
            const b_rgb = hexDecode(b.hex.?);
            const de = color_bandwidth.ciede2000(
                color_bandwidth.rgbToLab(a_rgb[0], a_rgb[1], a_rgb[2]),
                color_bandwidth.rgbToLab(b_rgb[0], b_rgb[1], b_rgb[2]),
            );
            if (de > JND_THRESHOLD) return null; // _|_ bottom
            result.hex = a.hex; // take the prediction side
        } else {
            result.hex = a.hex orelse b.hex;
        }

        // trit
        if (a.trit != null and b.trit != null and a.trit.? != b.trit.?) return null;
        result.trit = a.trit orelse b.trit;

        return result;
    }

    /// Is this a complete (non-partial) claim?
    pub fn isComplete(self: ColorClaim) bool {
        return self.seed != null and self.index != null and self.hex != null and self.trit != null;
    }
};

fn hexEncode(rgb: [3]u8) [7]u8 {
    const hex_chars = "0123456789abcdef";
    return .{
        '#',
        hex_chars[rgb[0] >> 4],
        hex_chars[rgb[0] & 0xf],
        hex_chars[rgb[1] >> 4],
        hex_chars[rgb[1] & 0xf],
        hex_chars[rgb[2] >> 4],
        hex_chars[rgb[2] & 0xf],
    };
}

fn hexDecode(hex: [7]u8) [3]u8 {
    return .{
        hexNibble(hex[1]) * 16 + hexNibble(hex[2]),
        hexNibble(hex[3]) * 16 + hexNibble(hex[4]),
        hexNibble(hex[5]) * 16 + hexNibble(hex[6]),
    };
}

fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

// =============================================================================
// Lux Integration: golden/plastic angle color streams
// =============================================================================

pub const LuxStream = struct {
    seed: u64,
    base_hue: f32,
    mode: Mode,
    step: u32 = 0,

    pub const Mode = enum { golden, plastic, silver };

    pub fn init(seed: u64, mode: Mode) LuxStream {
        const raw = splitmix64(seed);
        const base_hue = @as(f32, @floatFromInt(raw & 0xFFFF)) / 65535.0 * 360.0;
        return .{ .seed = seed, .base_hue = base_hue, .mode = mode };
    }

    pub fn next(self: *LuxStream) lux_color.RGB {
        const angle: f32 = switch (self.mode) {
            .golden => lux_color.GOLDEN_ANGLE,
            .plastic => lux_color.PLASTIC_ANGLE,
            .silver => lux_color.SILVER_ANGLE,
        };
        const hue = @mod(self.base_hue + angle * @as(f32, @floatFromInt(self.step)), 360.0);
        self.step += 1;
        const hcl = lux_color.HCL{ .h = hue, .c = 0.6, .l = 0.55 };
        return hcl.toRGB();
    }

    pub fn at(self: *const LuxStream, step: u32) lux_color.RGB {
        const angle: f32 = switch (self.mode) {
            .golden => lux_color.GOLDEN_ANGLE,
            .plastic => lux_color.PLASTIC_ANGLE,
            .silver => lux_color.SILVER_ANGLE,
        };
        const hue = @mod(self.base_hue + angle * @as(f32, @floatFromInt(step)), 360.0);
        const hcl = lux_color.HCL{ .h = hue, .c = 0.6, .l = 0.55 };
        return hcl.toRGB();
    }
};

// =============================================================================
// VHS Tape Event for Perception (integrates with tape_recorder.zig format)
// =============================================================================

pub const PerceptionEvent = struct {
    timestamp_ms: i64,
    kind: Kind,
    seed: u64,
    index: u64,
    predicted_hex: [7]u8,
    observed_hex: [7]u8,
    delta_e: f32,
    verdict: Verdict,

    pub const Kind = enum(u8) {
        checkpoint_first,
        checkpoint_last,
        checkpoint_random,
        batch_summary,
    };

    /// Format as VHS-compatible tape line
    pub fn toVhsLine(self: PerceptionEvent, buf: *[256]u8) []const u8 {
        const verdict_str: []const u8 = switch (self.verdict) {
            .reafferent => "SELF",
            .exafferent => "WORLD",
            .contradiction => "BOTTOM",
        };
        const kind_str: []const u8 = switch (self.kind) {
            .checkpoint_first => "FIRST",
            .checkpoint_last => "LAST",
            .checkpoint_random => "RANDOM",
            .batch_summary => "BATCH",
        };
        const result = std.fmt.bufPrint(buf, "# {s} seed={d} idx={d} pred={s} obs={s} dE={d:.2} verdict={s}\n", .{
            kind_str,
            self.seed,
            self.index,
            &self.predicted_hex,
            &self.observed_hex,
            self.delta_e,
            verdict_str,
        }) catch return buf[0..0];
        return result;
    }
};

/// Generate perception events for a batch's three checkpoints
pub fn batchToPerceptionEvents(batch: *const PerceptionBatch) [3]?PerceptionEvent {
    var events: [3]?PerceptionEvent = .{ null, null, null };

    if (batch.firstCheckpoint()) |first| {
        events[0] = .{
            .timestamp_ms = batch.batch_timestamp_ms,
            .kind = .checkpoint_first,
            .seed = batch.seed,
            .index = batch.start_index,
            .predicted_hex = hexEncode(batch.efferences[0].predicted_rgb),
            .observed_hex = hexEncode(batch.observations[0].observed_rgb),
            .delta_e = first.delta_e,
            .verdict = first.verdict,
        };
    }

    if (batch.lastCheckpoint()) |last| {
        const li = batch.count - 1;
        events[1] = .{
            .timestamp_ms = batch.batch_timestamp_ms,
            .kind = .checkpoint_last,
            .seed = batch.seed,
            .index = batch.start_index + li,
            .predicted_hex = hexEncode(batch.efferences[li].predicted_rgb),
            .observed_hex = hexEncode(batch.observations[li].observed_rgb),
            .delta_e = last.delta_e,
            .verdict = last.verdict,
        };
    }

    if (batch.randomCheckpoint()) |random| {
        const ri = splitmix64(batch.seed +% batch.seed) % (batch.count - 2) + 1;
        events[2] = .{
            .timestamp_ms = batch.batch_timestamp_ms,
            .kind = .checkpoint_random,
            .seed = batch.seed,
            .index = batch.start_index + ri,
            .predicted_hex = hexEncode(batch.efferences[@intCast(ri)].predicted_rgb),
            .observed_hex = hexEncode(batch.observations[@intCast(ri)].observed_rgb),
            .delta_e = random.delta_e,
            .verdict = random.verdict,
        };
    }

    return events;
}

// =============================================================================
// Arrow IPC Header Compatibility
// =============================================================================

pub const ArrowBatchHeader = extern struct {
    magic: [4]u8 = .{ 'S', 'C', 'P', 0x01 }, // Self-Color Perception v1
    batch_len: u32 = 0,
    seed: u64 = 0,
    schema_hash: [32]u8 = std.mem.zeroes([32]u8),
    reafferent_count: u32 = 0,
    exafferent_count: u32 = 0,
    mean_delta_e_x100: u16 = 0, // Delta-E * 100 as integer
    perception_trit: i8 = 0,
    _reserved: [5]u8 = std.mem.zeroes([5]u8),

    comptime {
        std.debug.assert(@sizeOf(ArrowBatchHeader) == 64);
    }

    pub fn fromBatch(batch: *const PerceptionBatch) ArrowBatchHeader {
        return .{
            .batch_len = batch.count,
            .seed = batch.seed,
            .reafferent_count = batch.reafferentCount(),
            .exafferent_count = batch.exafferentCount(),
            .mean_delta_e_x100 = @intFromFloat(@min(65535.0, batch.meanDeltaE() * 100.0)),
            .perception_trit = @intFromEnum(batch.perceptionTrit()),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "efference copy deterministic" {
    const ef1 = EfferenceCopy.generate(42, 0, 1000);
    const ef2 = EfferenceCopy.generate(42, 0, 2000);
    try std.testing.expectEqual(ef1.predicted_rgb, ef2.predicted_rgb);
    try std.testing.expectEqual(ef1.predicted_trit, ef2.predicted_trit);
}

test "efference copy different seeds differ" {
    const ef1 = EfferenceCopy.generate(42, 0, 1000);
    const ef2 = EfferenceCopy.generate(69, 0, 1000);
    try std.testing.expect(ef1.predicted_rgb[0] != ef2.predicted_rgb[0] or
        ef1.predicted_rgb[1] != ef2.predicted_rgb[1] or
        ef1.predicted_rgb[2] != ef2.predicted_rgb[2]);
}

test "reafference perfect transport" {
    const ef = EfferenceCopy.generate(42, 7, 1000);
    const obs = Observation.fromRgb(ef.predicted_rgb[0], ef.predicted_rgb[1], ef.predicted_rgb[2], ef.predicted_trit, 1001, .direct);
    const result = checkReafference(ef, obs);
    try std.testing.expectEqual(result.verdict, .reafferent);
    try std.testing.expect(result.delta_e < 0.001);
    try std.testing.expect(result.trit_match);
    try std.testing.expectEqual(result.latency_ms, 1);
}

test "reafference trit mismatch is contradiction" {
    const ef = EfferenceCopy.generate(42, 7, 1000);
    const wrong_trit = if (ef.predicted_trit == .plus) Trit.minus else Trit.plus;
    const obs = Observation.fromRgb(ef.predicted_rgb[0], ef.predicted_rgb[1], ef.predicted_rgb[2], wrong_trit, 1001, .direct);
    const result = checkReafference(ef, obs);
    try std.testing.expectEqual(result.verdict, .contradiction);
    try std.testing.expect(!result.trit_match);
}

test "reafference large delta-E is exafferent" {
    const ef = EfferenceCopy.generate(42, 7, 1000);
    // Completely different color
    const obs = Observation.fromRgb(
        255 - ef.predicted_rgb[0],
        255 - ef.predicted_rgb[1],
        255 - ef.predicted_rgb[2],
        ef.predicted_trit,
        1001,
        .arrow_ipc,
    );
    const result = checkReafference(ef, obs);
    try std.testing.expect(result.delta_e > JND_THRESHOLD);
    // Verdict depends on whether trit matches the inverted color
    try std.testing.expect(result.verdict == .exafferent or result.verdict == .contradiction);
}

test "perception batch perfect transport all reafferent" {
    var batch = PerceptionBatch.init(42, 0, 64, 1000);
    batch.observePerfect(1001);
    try std.testing.expectEqual(batch.reafferentCount(), 64);
    try std.testing.expectEqual(batch.exafferentCount(), 0);
    try std.testing.expectEqual(batch.contradictionCount(), 0);
    try std.testing.expect(batch.meanDeltaE() < 0.001);
    try std.testing.expect(batch.allCheckpointsPass());
    try std.testing.expectEqual(batch.perceptionTrit(), .plus);
}

test "perception batch noisy transport" {
    var batch = PerceptionBatch.init(42, 0, 64, 1000);
    batch.observeNoisy(999, 1001);
    // Noise is small (+/- 8 per channel), so most should still pass
    try std.testing.expect(batch.reafferentCount() > 0);
    try std.testing.expect(batch.meanDeltaE() < 10.0);
}

test "three checkpoints first/last/random" {
    var batch = PerceptionBatch.init(42, 0, 100, 1000);
    batch.observePerfect(1001);
    const first = batch.firstCheckpoint().?;
    const last = batch.lastCheckpoint().?;
    const random = batch.randomCheckpoint().?;
    try std.testing.expect(first.isself());
    try std.testing.expect(last.isself());
    try std.testing.expect(random.isself());
}

test "CUE claim unification success" {
    const ef = EfferenceCopy.generate(42, 7, 1000);
    const obs = Observation.fromRgb(ef.predicted_rgb[0], ef.predicted_rgb[1], ef.predicted_rgb[2], ef.predicted_trit, 1001, .direct);
    const claim_a = ColorClaim.fromEfference(ef);
    const claim_b = ColorClaim.fromObservation(obs);
    const unified = ColorClaim.unify(claim_a, claim_b);
    try std.testing.expect(unified != null);
    try std.testing.expect(unified.?.isComplete());
    try std.testing.expectEqual(unified.?.seed.?, 42);
}

test "CUE claim unification bottom on mismatch" {
    const claim_a = ColorClaim{ .hex = hexEncode(.{ 255, 0, 0 }), .trit = .plus };
    const claim_b = ColorClaim{ .hex = hexEncode(.{ 0, 0, 255 }), .trit = .plus };
    const unified = ColorClaim.unify(claim_a, claim_b);
    try std.testing.expect(unified == null); // _|_ bottom: red vs blue
}

test "Lux golden stream progression" {
    var stream = LuxStream.init(42, .golden);
    const c0 = stream.next();
    const c1 = stream.next();
    const c2 = stream.next();
    // All colors should be in gamut and distinct
    try std.testing.expect(c0.r != c1.r or c0.g != c1.g or c0.b != c1.b);
    try std.testing.expect(c1.r != c2.r or c1.g != c2.g or c1.b != c2.b);
}

test "Lux plastic stream for GF(3)" {
    var stream = LuxStream.init(42, .plastic);
    var prev = stream.next();
    var distinct_count: u32 = 0;
    for (1..10) |_| {
        const curr = stream.next();
        if (curr.r != prev.r or curr.g != prev.g or curr.b != prev.b) distinct_count += 1;
        prev = curr;
    }
    try std.testing.expect(distinct_count >= 7); // at least 7/9 steps produce distinct colors
}

test "Arrow batch header size" {
    try std.testing.expectEqual(@sizeOf(ArrowBatchHeader), 64);
    var batch = PerceptionBatch.init(42, 0, 32, 1000);
    batch.observePerfect(1001);
    const header = ArrowBatchHeader.fromBatch(&batch);
    try std.testing.expectEqual(header.batch_len, 32);
    try std.testing.expectEqual(header.seed, 42);
    try std.testing.expectEqual(header.reafferent_count, 32);
    try std.testing.expectEqual(header.perception_trit, 1); // .plus
}

test "perception events from batch" {
    var batch = PerceptionBatch.init(42, 0, 100, 1000);
    batch.observePerfect(1001);
    const events = batchToPerceptionEvents(&batch);
    try std.testing.expect(events[0] != null); // first
    try std.testing.expect(events[1] != null); // last
    try std.testing.expect(events[2] != null); // random
    try std.testing.expectEqual(events[0].?.verdict, .reafferent);
    try std.testing.expectEqual(events[1].?.verdict, .reafferent);
    try std.testing.expectEqual(events[2].?.verdict, .reafferent);
}

test "VHS tape line format" {
    const event = PerceptionEvent{
        .timestamp_ms = 1000,
        .kind = .checkpoint_first,
        .seed = 42,
        .index = 0,
        .predicted_hex = hexEncode(.{ 128, 64, 32 }),
        .observed_hex = hexEncode(.{ 128, 64, 32 }),
        .delta_e = 0.0,
        .verdict = .reafferent,
    };
    var buf: [256]u8 = undefined;
    const line = event.toVhsLine(&buf);
    try std.testing.expect(line.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, line, "FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "SELF") != null);
}

test "hex roundtrip" {
    const original = [3]u8{ 0xAB, 0xCD, 0xEF };
    const encoded = hexEncode(original);
    const decoded = hexDecode(encoded);
    try std.testing.expectEqual(original, decoded);
}
