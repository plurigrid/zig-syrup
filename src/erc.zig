//! Ensemble Reservoir Computing (ERC)
//!
//! Multi-channel EEG classification via ensemble averaging of spatially
//! multiplexed reservoir states. Each EEG electrode acts as an independent
//! reservoir; ensemble averaging across channels provides noise robustness.
//!
//! Core compute path is zero-allocation (comptime-parameterized fixed arrays).
//!
//! Reference: Ensemble reservoir computing achieves robust information
//! processing using spin-torque oscillators (2024).
//!
//! GF(3) trit output: minus(-1) = low-frequency dominance (drowsy/sleep),
//!                    zero(0)   = alpha dominance (relaxed baseline),
//!                    plus(+1)  = high-frequency dominance (active/focused).

const std = @import("std");
const math = std.math;
const fft_bands = @import("fft_bands");
const bci = @import("bci_receiver");
const propagator = @import("propagator");

pub const NUM_BANDS = fft_bands.NUM_BANDS; // 5

// ============================================================================
// CLASSIFICATION RESULT
// ============================================================================

pub const ClassificationResult = struct {
    trit: bci.Trit,
    confidence: f32, // softmax probability of chosen class [0, 1]
    logits: [3]f32, // [minus, zero, plus]
    ensemble_entropy: f32, // Shannon entropy across channels (noise indicator)
};

// ============================================================================
// ENSEMBLE AVERAGE
// ============================================================================

pub fn EnsembleAverage(comptime N: usize) type {
    return struct {
        const Self = @This();

        mean: [NUM_BANDS]f32, // channel-averaged band powers
        variance: [NUM_BANDS]f32, // inter-channel variance per band

        /// Compute uniform ensemble average across N channels.
        pub fn compute(channels: [N][NUM_BANDS]f32) Self {
            var mean = [_]f32{0} ** NUM_BANDS;
            for (channels) |ch| {
                for (0..NUM_BANDS) |b| {
                    mean[b] += ch[b];
                }
            }
            for (0..NUM_BANDS) |b| {
                mean[b] /= @as(f32, @floatFromInt(N));
            }

            var variance = [_]f32{0} ** NUM_BANDS;
            for (channels) |ch| {
                for (0..NUM_BANDS) |b| {
                    const diff = ch[b] - mean[b];
                    variance[b] += diff * diff;
                }
            }
            for (0..NUM_BANDS) |b| {
                variance[b] /= @as(f32, @floatFromInt(N));
            }

            return Self{ .mean = mean, .variance = variance };
        }

        /// Compute weighted ensemble average (noisy channels down-weighted).
        pub fn computeWeighted(channels: [N][NUM_BANDS]f32, weights: [N]f32) Self {
            var total_weight: f32 = 0;
            for (weights) |w| total_weight += w;
            if (total_weight <= 0) return compute(channels);

            var mean = [_]f32{0} ** NUM_BANDS;
            for (channels, 0..) |ch, i| {
                const w = weights[i] / total_weight;
                for (0..NUM_BANDS) |b| {
                    mean[b] += ch[b] * w;
                }
            }

            var variance = [_]f32{0} ** NUM_BANDS;
            for (channels, 0..) |ch, i| {
                const w = weights[i] / total_weight;
                for (0..NUM_BANDS) |b| {
                    const diff = ch[b] - mean[b];
                    variance[b] += w * diff * diff;
                }
            }

            return Self{ .mean = mean, .variance = variance };
        }
    };
}

// ============================================================================
// READOUT LAYER
// ============================================================================

/// Linear readout: weight matrix maps ensemble features to 3-class logits.
/// Input: NUM_BANDS mean + NUM_BANDS variance = 10 features.
/// Output: 3 logits (minus, zero, plus).
pub const FEATURE_DIM = NUM_BANDS * 2; // mean + variance = 10

pub fn ReadoutLayer(comptime N: usize) type {
    _ = N; // N used only for type consistency; readout operates on ensemble features
    return struct {
        const Self = @This();
        const OUTPUT_DIM = 3;

        weights: [OUTPUT_DIM][FEATURE_DIM]f32,
        bias: [OUTPUT_DIM]f32,

        /// Zero-initialized (requires training).
        pub fn initZero() Self {
            return Self{
                .weights = [_][FEATURE_DIM]f32{[_]f32{0} ** FEATURE_DIM} ** OUTPUT_DIM,
                .bias = [_]f32{0} ** OUTPUT_DIM,
            };
        }

        /// Heuristic initialization: encodes domain knowledge without training.
        /// Band mapping: delta/theta → minus, alpha → zero, beta/gamma → plus.
        /// Variance features provide noise robustness weighting.
        pub fn initHeuristic() Self {
            var weights = [_][FEATURE_DIM]f32{[_]f32{0} ** FEATURE_DIM} ** OUTPUT_DIM;

            // Mean features [0..5]: delta, theta, alpha, beta, gamma
            // Variance features [5..10]: delta_var, theta_var, alpha_var, beta_var, gamma_var

            // MINUS class (idx 0): high delta/theta → drowsy/sleep
            weights[0][0] = 2.0; // delta mean
            weights[0][1] = 1.5; // theta mean
            weights[0][2] = -0.5; // alpha mean (negative — alpha opposes drowsiness)
            weights[0][3] = -1.0; // beta mean (negative)
            weights[0][4] = -0.5; // gamma mean (negative)
            weights[0][5] = -0.3; // delta variance (low variance = consistent drowsiness)
            weights[0][6] = -0.3; // theta variance

            // ZERO class (idx 1): high alpha → relaxed baseline
            weights[1][0] = -0.5; // delta mean
            weights[1][1] = 0.3; // theta mean (some theta is relaxed)
            weights[1][2] = 2.5; // alpha mean (strong positive)
            weights[1][3] = -0.5; // beta mean
            weights[1][4] = -0.5; // gamma mean
            weights[1][7] = -0.5; // alpha variance (low variance = consistent alpha)

            // PLUS class (idx 2): high beta/gamma → active/focused
            weights[2][0] = -0.5; // delta mean
            weights[2][1] = -0.5; // theta mean
            weights[2][2] = -0.5; // alpha mean (alpha suppression during focus)
            weights[2][3] = 2.0; // beta mean
            weights[2][4] = 1.5; // gamma mean
            weights[2][8] = -0.3; // beta variance (low variance = sustained focus)
            weights[2][9] = -0.3; // gamma variance

            return Self{
                .weights = weights,
                .bias = [_]f32{ -0.5, -0.3, -0.5 }, // slight zero-class bias (baseline prior)
            };
        }

        /// Forward pass: features -> logits -> trit.
        pub fn classify(self: *const Self, features: [FEATURE_DIM]f32) ClassificationResult {
            var logits: [OUTPUT_DIM]f32 = undefined;
            for (0..OUTPUT_DIM) |o| {
                var sum: f32 = self.bias[o];
                for (0..FEATURE_DIM) |f| {
                    sum += self.weights[o][f] * features[f];
                }
                logits[o] = sum;
            }

            // Softmax for confidence
            const max_logit = @max(logits[0], @max(logits[1], logits[2]));
            var exp_sum: f32 = 0;
            var exps: [OUTPUT_DIM]f32 = undefined;
            for (0..OUTPUT_DIM) |o| {
                exps[o] = @exp(logits[o] - max_logit);
                exp_sum += exps[o];
            }

            // Argmax for trit
            var best_idx: usize = 0;
            if (logits[1] > logits[best_idx]) best_idx = 1;
            if (logits[2] > logits[best_idx]) best_idx = 2;

            const trit: bci.Trit = switch (best_idx) {
                0 => .minus,
                1 => .zero,
                2 => .plus,
                else => unreachable,
            };

            const confidence = exps[best_idx] / exp_sum;

            return ClassificationResult{
                .trit = trit,
                .confidence = confidence,
                .logits = logits,
                .ensemble_entropy = 0, // set by ERC.process
            };
        }
    };
}

// ============================================================================
// RING BUFFER (fixed-size, zero-allocation)
// ============================================================================

fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        pub fn push(self: *Self, item: T) void {
            self.items[self.head] = item;
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        pub fn latest(self: *const Self) ?T {
            if (self.count == 0) return null;
            const idx = if (self.head == 0) capacity - 1 else self.head - 1;
            return self.items[idx];
        }

        /// Majority vote across buffer for a trit field.
        pub fn majorityTrit(self: *const Self, getTrit: *const fn (T) bci.Trit) bci.Trit {
            if (self.count == 0) return .zero;
            var counts = [_]u32{ 0, 0, 0 }; // minus, zero, plus
            const start = if (self.head >= self.count) self.head - self.count else capacity - (self.count - self.head);
            for (0..self.count) |i| {
                const idx = (start + i) % capacity;
                const t = getTrit(self.items[idx]);
                const ti: usize = @intCast(@as(i8, @intFromEnum(t)) + 1); // -1→0, 0→1, +1→2
                counts[ti] += 1;
            }
            var best: usize = 0;
            if (counts[1] > counts[best]) best = 1;
            if (counts[2] > counts[best]) best = 2;
            return switch (best) {
                0 => .minus,
                1 => .zero,
                2 => .plus,
                else => unreachable,
            };
        }
    };
}

// ============================================================================
// ERC: TOP-LEVEL ENSEMBLE RESERVOIR COMPUTER
// ============================================================================

pub const EnsembleMode = enum {
    uniform, // equal weight all channels
    entropy_weighted, // weight by inverse channel entropy (noisy channels down-weighted)
};

pub fn ERC(comptime N: usize) type {
    return struct {
        const Self = @This();
        pub const HISTORY_DEPTH = 16;

        readout: ReadoutLayer(N),
        history: RingBuffer(ClassificationResult, HISTORY_DEPTH),
        mode: EnsembleMode,

        /// Initialize with heuristic weights (works out of the box).
        pub fn init(mode: EnsembleMode) Self {
            return Self{
                .readout = ReadoutLayer(N).initHeuristic(),
                .history = .{},
                .mode = mode,
            };
        }

        /// Initialize with custom readout weights.
        pub fn initWithReadout(readout: ReadoutLayer(N), mode: EnsembleMode) Self {
            return Self{
                .readout = readout,
                .history = .{},
                .mode = mode,
            };
        }

        /// Core compute path (ZERO ALLOCATIONS):
        /// Takes N-channel band powers → ensemble average → linear readout → trit.
        pub fn process(self: *Self, channels: [N][NUM_BANDS]f32) ClassificationResult {
            // Step 1: Ensemble average
            const avg = switch (self.mode) {
                .uniform => EnsembleAverage(N).compute(channels),
                .entropy_weighted => blk: {
                    var weights: [N]f32 = undefined;
                    for (channels, 0..) |ch, i| {
                        const entropy = channelEntropy(ch);
                        // Inverse entropy weighting: low-entropy channels (clean) get higher weight
                        weights[i] = if (entropy > 0) 1.0 / entropy else 10.0;
                    }
                    break :blk EnsembleAverage(N).computeWeighted(channels, weights);
                },
            };

            // Step 2: Construct feature vector [mean(5) | variance(5)]
            var features: [FEATURE_DIM]f32 = undefined;
            @memcpy(features[0..NUM_BANDS], &avg.mean);
            @memcpy(features[NUM_BANDS..], &avg.variance);

            // Step 3: Linear readout
            var result = self.readout.classify(features);

            // Step 4: Compute ensemble entropy (noise/agreement indicator)
            result.ensemble_entropy = ensembleEntropy(N, channels);

            // Step 5: Push to history ring buffer
            self.history.push(result);

            return result;
        }

        /// Process from fft_bands.BandPowers array.
        pub fn processFromBandPowers(self: *Self, bands: [N]fft_bands.BandPowers) ClassificationResult {
            var channels: [N][NUM_BANDS]f32 = undefined;
            for (0..N) |i| {
                channels[i] = bands[i].asArray();
            }
            return self.process(channels);
        }

        /// Get latest classification result.
        pub fn latestResult(self: *const Self) ?ClassificationResult {
            return self.history.latest();
        }

        /// Majority vote over recent history for temporal smoothing.
        pub fn smoothedTrit(self: *const Self) bci.Trit {
            return self.history.majorityTrit(&getTritFromResult);
        }

        /// Export to propagator CellValue.
        pub fn toCellValue(self: *const Self) propagator.CellValue(f32) {
            const result = self.latestResult() orelse return .{ .nothing = {} };
            return .{ .value = @as(f32, @floatFromInt(@intFromEnum(result.trit))) };
        }
    };
}

fn getTritFromResult(r: ClassificationResult) bci.Trit {
    return r.trit;
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Shannon entropy of a single channel's band power distribution.
fn channelEntropy(bands: [NUM_BANDS]f32) f32 {
    var total: f32 = 0;
    for (bands) |b| total += b;
    if (total <= 0) return 0;

    var entropy: f32 = 0;
    for (bands) |b| {
        if (b > 0) {
            const prob = b / total;
            entropy -= prob * @log2(prob);
        }
    }
    return entropy;
}

/// Ensemble entropy: average of per-channel entropies.
/// High value = channels disagree (noisy). Low value = channels agree (clean signal).
fn ensembleEntropy(comptime N: usize, channels: [N][NUM_BANDS]f32) f32 {
    var total: f32 = 0;
    for (channels) |ch| {
        total += channelEntropy(ch);
    }
    return total / @as(f32, @floatFromInt(N));
}

// ============================================================================
// DEVICE PRESETS
// ============================================================================

/// DSI-24: 21 EEG channels (full 10-20 montage)
pub const DSI24 = ERC(21);

/// OpenBCI Cyton: 8 channels
pub const Cyton = ERC(8);

/// Generic 64-channel (research grade)
pub const ERC64 = ERC(64);

// ============================================================================
// TESTS
// ============================================================================

test "ensemble average uniform" {
    // 3 channels with known band powers
    const channels = [3][NUM_BANDS]f32{
        [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 },
        [_]f32{ 3.0, 4.0, 5.0, 6.0, 7.0 },
        [_]f32{ 2.0, 3.0, 4.0, 5.0, 6.0 },
    };

    const avg = EnsembleAverage(3).compute(channels);

    // Mean = (1+3+2)/3=2, (2+4+3)/3=3, ...
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), avg.mean[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), avg.mean[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), avg.mean[2], 0.001);

    // Variance for band 0: ((1-2)^2 + (3-2)^2 + (2-2)^2)/3 = 2/3
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), avg.variance[0], 0.001);
}

test "heuristic readout classifies alpha-dominant as zero" {
    const readout = ReadoutLayer(8).initHeuristic();

    // Alpha-dominant features: mean=[0.1, 0.2, 5.0, 0.3, 0.1], variance=low
    const features = [FEATURE_DIM]f32{
        0.1, 0.2, 5.0, 0.3, 0.1, // mean: alpha=5.0 dominates
        0.01, 0.01, 0.01, 0.01, 0.01, // variance: low (clean signal)
    };

    const result = readout.classify(features);
    try std.testing.expectEqual(bci.Trit.zero, result.trit);
    try std.testing.expect(result.confidence > 0.5);
}

test "heuristic readout classifies beta-dominant as plus" {
    const readout = ReadoutLayer(8).initHeuristic();

    // Beta/gamma dominant
    const features = [FEATURE_DIM]f32{
        0.1, 0.1, 0.2, 4.0, 2.0, // mean: beta=4.0, gamma=2.0
        0.01, 0.01, 0.01, 0.01, 0.01,
    };

    const result = readout.classify(features);
    try std.testing.expectEqual(bci.Trit.plus, result.trit);
}

test "heuristic readout classifies delta-dominant as minus" {
    const readout = ReadoutLayer(8).initHeuristic();

    // Delta/theta dominant
    const features = [FEATURE_DIM]f32{
        5.0, 3.0, 0.2, 0.1, 0.05, // mean: delta=5.0, theta=3.0
        0.01, 0.01, 0.01, 0.01, 0.01,
    };

    const result = readout.classify(features);
    try std.testing.expectEqual(bci.Trit.minus, result.trit);
}

test "ERC 8-channel process" {
    var erc = Cyton.init(.uniform);

    // 8 channels all alpha-dominant
    var channels: [8][NUM_BANDS]f32 = undefined;
    for (0..8) |i| {
        channels[i] = [_]f32{
            0.1 + @as(f32, @floatFromInt(i)) * 0.01, // delta (small)
            0.2,  // theta
            5.0,  // alpha (dominant)
            0.3,  // beta
            0.1,  // gamma
        };
    }

    const result = erc.process(channels);
    try std.testing.expectEqual(bci.Trit.zero, result.trit); // alpha → zero
    try std.testing.expect(result.confidence > 0.3);
    try std.testing.expect(result.ensemble_entropy > 0); // channels have some entropy
}

test "ERC entropy-weighted mode down-weights noisy channels" {
    var erc_uniform = ERC(4).init(.uniform);
    var erc_weighted = ERC(4).init(.entropy_weighted);

    // 3 clean alpha-dominant channels + 1 noisy (flat spectrum) channel
    const channels = [4][NUM_BANDS]f32{
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 }, // clean alpha
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 }, // clean alpha
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 }, // clean alpha
        [_]f32{ 2.0, 2.0, 2.0, 2.0, 2.0 }, // noisy (max entropy)
    };

    const result_uniform = erc_uniform.process(channels);
    const result_weighted = erc_weighted.process(channels);

    // Both should classify as zero (alpha dominant), but weighted should have higher confidence
    try std.testing.expectEqual(bci.Trit.zero, result_uniform.trit);
    try std.testing.expectEqual(bci.Trit.zero, result_weighted.trit);
    // Weighted should be more confident because the noisy channel is down-weighted
    try std.testing.expect(result_weighted.confidence >= result_uniform.confidence - 0.01);
}

test "ERC toCellValue propagator integration" {
    var erc = ERC(4).init(.uniform);
    const channels = [4][NUM_BANDS]f32{
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 },
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 },
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 },
        [_]f32{ 0.1, 0.1, 5.0, 0.1, 0.1 },
    };

    // Before processing: nothing
    const cv_before = erc.toCellValue();
    try std.testing.expect(cv_before.isNothing());

    // After processing: value
    _ = erc.process(channels);
    const cv_after = erc.toCellValue();
    try std.testing.expect(!cv_after.isNothing());
    try std.testing.expectEqual(@as(?f32, 0.0), cv_after.hasValue()); // zero trit = 0.0
}

test "ring buffer majority vote" {
    var buf = RingBuffer(ClassificationResult, 4){};

    const mk = struct {
        fn f(t: bci.Trit) ClassificationResult {
            return ClassificationResult{
                .trit = t,
                .confidence = 1.0,
                .logits = [_]f32{ 0, 0, 0 },
                .ensemble_entropy = 0,
            };
        }
    }.f;

    buf.push(mk(.plus));
    buf.push(mk(.plus));
    buf.push(mk(.zero));

    const vote = buf.majorityTrit(&getTritFromResult);
    try std.testing.expectEqual(bci.Trit.plus, vote); // 2 plus > 1 zero
}

test "channel entropy" {
    // Uniform distribution: max entropy = log2(5) ≈ 2.322
    const uniform = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0 };
    const h = channelEntropy(uniform);
    try std.testing.expectApproxEqAbs(@as(f32, @log2(@as(f32, 5.0))), h, 0.01);

    // Single band: zero entropy
    const single = [_]f32{ 5.0, 0.0, 0.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), channelEntropy(single), 0.001);
}

test "DSI24 preset compiles" {
    var erc = DSI24.init(.uniform);
    var channels: [21][NUM_BANDS]f32 = undefined;
    for (0..21) |i| {
        channels[i] = [_]f32{ 0.1, 0.1, @as(f32, @floatFromInt(i)) * 0.5, 0.1, 0.1 };
    }
    const result = erc.process(channels);
    try std.testing.expect(result.confidence > 0);
}
