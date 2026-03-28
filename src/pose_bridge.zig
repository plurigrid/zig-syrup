//! pose_bridge.zig — Body Tracking Bridge for BCI Pipeline
//!
//! Receives joint angle data from Python pose_tracker.py and integrates
//! into the BCI trit classification pipeline.
//!
//! Joint angles (12 channels):
//!   l_shoulder, r_shoulder — shoulder flexion/extension
//!   l_elbow, r_elbow       — elbow flexion
//!   l_wrist, r_wrist       — wrist flexion
//!   l_hip, r_hip           — hip flexion
//!   l_knee, r_knee         — knee flexion
//!   l_ankle, r_ankle       — ankle dorsiflexion
//!
//! GF(3) trit classification:
//!   +1 (GENERATOR): high movement velocity (active motion)
//!    0 (ERGODIC):   baseline / static posture
//!   -1 (VALIDATOR): tremor / fatigue (high-freq, low-amplitude oscillation)
//!
//! Transport: NDJSON over stdin/pipe from pose_tracker.py, or LSL inlet.

const std = @import("std");
const bci = @import("bci_receiver.zig");
const Trit = bci.Trit;
const RGB = bci.RGB;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Number of joint angle channels
pub const NUM_JOINT_CHANNELS: usize = 12;

/// Default video frame rate (Hz)
pub const DEFAULT_FRAME_RATE: u16 = 30;

/// Movement velocity threshold for PLUS trit (active motion)
pub const VELOCITY_HIGH_THRESHOLD: f32 = 0.15;

/// Movement velocity threshold below which tremor detection activates
pub const VELOCITY_LOW_THRESHOLD: f32 = 0.02;

/// Frequency threshold for tremor classification (Hz)
pub const TREMOR_FREQ_THRESHOLD: f32 = 4.0;

// ============================================================================
// JOINT ANGLES — 12 named f32 fields
// ============================================================================

pub const JointAngles = struct {
    l_shoulder: f32 = 0, // left shoulder flexion/extension (degrees)
    r_shoulder: f32 = 0, // right shoulder flexion/extension
    l_elbow: f32 = 0, // left elbow flexion
    r_elbow: f32 = 0, // right elbow flexion
    l_wrist: f32 = 0, // left wrist flexion
    r_wrist: f32 = 0, // right wrist flexion
    l_hip: f32 = 0, // left hip flexion
    r_hip: f32 = 0, // right hip flexion
    l_knee: f32 = 0, // left knee flexion
    r_knee: f32 = 0, // right knee flexion
    l_ankle: f32 = 0, // left ankle dorsiflexion
    r_ankle: f32 = 0, // right ankle dorsiflexion

    /// Return all angles as a fixed-size array (channel order)
    pub fn asArray(self: JointAngles) [NUM_JOINT_CHANNELS]f32 {
        return .{
            self.l_shoulder, self.r_shoulder,
            self.l_elbow,    self.r_elbow,
            self.l_wrist,    self.r_wrist,
            self.l_hip,      self.r_hip,
            self.l_knee,     self.r_knee,
            self.l_ankle,    self.r_ankle,
        };
    }

    /// Mean of all joint angles
    pub fn mean(self: JointAngles) f32 {
        const arr = self.asArray();
        var sum: f32 = 0;
        for (arr) |v| sum += v;
        return sum / @as(f32, NUM_JOINT_CHANNELS);
    }

    /// Channel labels (10-20-style naming for joint angles)
    pub const LABELS = [NUM_JOINT_CHANNELS][]const u8{
        "L_Shoulder", "R_Shoulder",
        "L_Elbow",    "R_Elbow",
        "L_Wrist",    "R_Wrist",
        "L_Hip",      "R_Hip",
        "L_Knee",     "R_Knee",
        "L_Ankle",    "R_Ankle",
    };
};

// ============================================================================
// POSE SAMPLE — single frame of body tracking data
// ============================================================================

pub const PoseSample = struct {
    timestamp: f64, // seconds since epoch (or video time)
    joint_angles: JointAngles,
    movement_velocity: f32, // normalized velocity (0-1)
    movement_frequency: f32, // dominant frequency (Hz)
    trit: Trit, // GF(3) classification

    /// Classify movement state into GF(3) trit.
    ///
    /// - High velocity → PLUS (+1): active movement
    /// - Low velocity + high frequency → MINUS (-1): tremor/fatigue
    /// - Otherwise → ERGODIC (0): static/resting
    pub fn classify(self: *const PoseSample) Trit {
        return classifyMovement(self.movement_velocity, self.movement_frequency);
    }

    /// Get color for this sample's trit
    pub fn color(self: *const PoseSample) RGB {
        return self.trit.color();
    }
};

// ============================================================================
// MOVEMENT CLASSIFIER
// ============================================================================

/// Classify movement into GF(3) trit based on velocity and frequency.
///
/// Maps body movement patterns to the triadic classification:
///   PLUS (+1):  intentional, high-velocity movement (reaching, walking)
///   ERGODIC (0): static posture, baseline stillness
///   MINUS (-1): involuntary tremor or fatigue oscillation
pub fn classifyMovement(velocity: f32, frequency: f32) Trit {
    if (velocity > VELOCITY_HIGH_THRESHOLD) return .plus;
    if (velocity < VELOCITY_LOW_THRESHOLD and frequency > TREMOR_FREQ_THRESHOLD) return .minus;
    return .zero;
}

// ============================================================================
// POSE RING BUFFER — recent frames for velocity/frequency estimation
// ============================================================================

pub const POSE_RING_DEPTH: usize = 128; // ~4 seconds at 30fps

pub const PoseRing = struct {
    buf: [POSE_RING_DEPTH]PoseSample = undefined,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *PoseRing, sample: PoseSample) void {
        self.buf[self.head] = sample;
        self.head = (self.head + 1) % POSE_RING_DEPTH;
        if (self.count < POSE_RING_DEPTH) self.count += 1;
    }

    pub fn latest(self: *const PoseRing) ?*const PoseSample {
        if (self.count == 0) return null;
        const idx = if (self.head == 0) POSE_RING_DEPTH - 1 else self.head - 1;
        return &self.buf[idx];
    }

    /// Average velocity over buffered frames
    pub fn meanVelocity(self: *const PoseRing) f32 {
        if (self.count == 0) return 0;
        var sum: f32 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + POSE_RING_DEPTH - self.count + i) % POSE_RING_DEPTH;
            sum += self.buf[idx].movement_velocity;
        }
        return sum / @as(f32, @floatFromInt(self.count));
    }

    /// Trit distribution in buffer: (minus_count, zero_count, plus_count)
    pub fn tritDistribution(self: *const PoseRing) struct { minus: usize, zero: usize, plus: usize } {
        var minus: usize = 0;
        var zero: usize = 0;
        var plus: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + POSE_RING_DEPTH - self.count + i) % POSE_RING_DEPTH;
            switch (self.buf[idx].trit) {
                .minus => minus += 1,
                .zero => zero += 1,
                .plus => plus += 1,
            }
        }
        return .{ .minus = minus, .zero = zero, .plus = plus };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "JointAngles asArray and mean" {
    const angles = JointAngles{
        .l_shoulder = 90,
        .r_shoulder = 85,
        .l_elbow = 120,
        .r_elbow = 115,
        .l_wrist = 10,
        .r_wrist = 12,
        .l_hip = 90,
        .r_hip = 88,
        .l_knee = 170,
        .r_knee = 168,
        .l_ankle = 90,
        .r_ankle = 92,
    };
    const arr = angles.asArray();
    try std.testing.expectEqual(@as(usize, 12), arr.len);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), arr[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 92.0), arr[11], 0.001);

    const m = angles.mean();
    // Mean of all 12 values
    try std.testing.expect(m > 80.0);
    try std.testing.expect(m < 110.0);
}

test "classifyMovement thresholds" {
    // High velocity → PLUS
    try std.testing.expectEqual(Trit.plus, classifyMovement(0.3, 1.0));
    try std.testing.expectEqual(Trit.plus, classifyMovement(0.16, 0.0));

    // Static → ERGODIC
    try std.testing.expectEqual(Trit.zero, classifyMovement(0.05, 1.0));
    try std.testing.expectEqual(Trit.zero, classifyMovement(0.10, 2.0));

    // Tremor → MINUS (low velocity, high frequency)
    try std.testing.expectEqual(Trit.minus, classifyMovement(0.01, 5.0));
    try std.testing.expectEqual(Trit.minus, classifyMovement(0.005, 8.0));

    // Low velocity but low frequency → ERGODIC (not tremor)
    try std.testing.expectEqual(Trit.zero, classifyMovement(0.01, 2.0));
}

test "PoseSample classify and color" {
    const sample = PoseSample{
        .timestamp = 1.0,
        .joint_angles = .{},
        .movement_velocity = 0.3,
        .movement_frequency = 1.0,
        .trit = .plus,
    };
    try std.testing.expectEqual(Trit.plus, sample.classify());
    try std.testing.expectEqual(bci.COLOR_GENERATOR, sample.color());
}

test "PoseRing push and latest" {
    var ring = PoseRing{};
    try std.testing.expectEqual(@as(usize, 0), ring.count);
    try std.testing.expect(ring.latest() == null);

    const sample = PoseSample{
        .timestamp = 0.033,
        .joint_angles = .{ .l_shoulder = 90, .r_shoulder = 85 },
        .movement_velocity = 0.1,
        .movement_frequency = 1.0,
        .trit = .zero,
    };
    ring.push(sample);
    try std.testing.expectEqual(@as(usize, 1), ring.count);

    const latest = ring.latest().?;
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), latest.joint_angles.l_shoulder, 0.001);
}

test "PoseRing meanVelocity" {
    var ring = PoseRing{};

    // Push 3 samples with different velocities
    const velocities = [_]f32{ 0.1, 0.2, 0.3 };
    for (velocities, 0..) |v, i| {
        ring.push(.{
            .timestamp = @as(f64, @floatFromInt(i)) * 0.033,
            .joint_angles = .{},
            .movement_velocity = v,
            .movement_frequency = 1.0,
            .trit = .zero,
        });
    }
    // Mean should be 0.2
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), ring.meanVelocity(), 0.001);
}

test "PoseRing tritDistribution" {
    var ring = PoseRing{};
    const trits = [_]Trit{ .plus, .zero, .minus, .plus, .zero, .zero };
    for (trits, 0..) |t, i| {
        ring.push(.{
            .timestamp = @as(f64, @floatFromInt(i)) * 0.033,
            .joint_angles = .{},
            .movement_velocity = 0.1,
            .movement_frequency = 1.0,
            .trit = t,
        });
    }
    const dist = ring.tritDistribution();
    try std.testing.expectEqual(@as(usize, 1), dist.minus);
    try std.testing.expectEqual(@as(usize, 3), dist.zero);
    try std.testing.expectEqual(@as(usize, 2), dist.plus);
}
