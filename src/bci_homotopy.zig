//! BCI Homotopy Bridge
//!
//! Combines BCI state classification with Zig-Syrup's:
//! - GF(3) Trit conservation (Plus/Zero/Minus)
//! - Homotopy Path Tracking (Continuous state deformation)
//! - Continuation Pipelines (Resumable belief revision)
//!
//! Maps discrete brain states to topological trits:
//! - Plus (+)  : High Energy / External Attention (Focused, Excited)
//! - Zero (0)  : Balanced / Internal Attention (Relaxed, Meditative)
//! - Minus (-) : Low Energy / Damping (Drowsy, Stressed)

const std = @import("std");
const syrup = @import("syrup");
const continuation = @import("continuation");
const homotopy = @import("homotopy");
const Allocator = std.mem.Allocator;

// ============================================================================
// BCI STATE MAPPING
// ============================================================================

pub const BrainState = enum {
    focused,    // High beta/gamma
    excited,    // High beta/gamma
    relaxed,    // High alpha
    meditative, // High theta/alpha coherence
    drowsy,     // High theta
    stressed,   // High beta, low alpha

    /// Map brain state to GF(3) trit
    pub fn toTrit(self: BrainState) continuation.Trit {
        return switch (self) {
            .focused, .excited => .plus,     // Creation/Action
            .relaxed, .meditative => .zero,  // Ergodic/Flow
            .drowsy, .stressed => .minus,    // Damping/Restriction
        };
    }

    pub fn fromString(s: []const u8) ?BrainState {
        return std.meta.stringToEnum(BrainState, s);
    }
};

/// EEG Feature Vector (Phase 3 output)
pub const EEGFeatures = struct {
    alpha_power: f64,
    beta_power: f64,
    theta_power: f64,
    coherence: f64,

    pub fn fromSyrup(val: syrup.Value) !EEGFeatures {
        // Mock extraction for now - assumes dictionary
        if (val != .dictionary) return error.InvalidFormat;
        // In real impl, would parse fields
        return EEGFeatures{ .alpha_power = 0, .beta_power = 0, .theta_power = 0, .coherence = 0 };
    }
};

// ============================================================================
// CONTINUATION PIPELINE
// ============================================================================

/// Tracks the user's cognitive state as a persistent belief set
pub const CognitiveModel = struct {
    beliefs: continuation.BeliefSet,
    current_trit: continuation.Trit,
    history: std.ArrayListUnmanaged(continuation.Trit),
    
    pub fn init(allocator: Allocator) CognitiveModel {
        return .{
            .beliefs = continuation.BeliefSet.init(allocator),
            .current_trit = .zero,
            .history = .{},
        };
    }

    pub fn deinit(self: *CognitiveModel, allocator: Allocator) void {
        self.beliefs.deinit();
        self.history.deinit(allocator);
    }

    /// Update model based on new classified state
    pub fn update(self: *CognitiveModel, state: BrainState, allocator: Allocator) !void {
        const new_trit = state.toTrit();
        
        // 1. Update GF(3) History
        try self.history.append(allocator, new_trit);

        // 2. AGM Belief Revision
        // We maintain beliefs about the user's state
        const state_name = @tagName(state);
        
        // If state changed, revise beliefs
        if (new_trit != self.current_trit) {
            // Contract old beliefs incompatible with new state
            // (Simplified: just assert new state)
            try self.beliefs.revise(.{ .proposition = state_name, .entrenchment = 1 });
            
            // Derive implications (Example)
            if (state == .focused) {
                try self.beliefs.expand(.{ .proposition = "high-cognitive-load" });
            } else if (state == .relaxed) {
                self.beliefs.contract("high-cognitive-load");
            }
        }

        self.current_trit = new_trit;
    }
};

// ============================================================================
// HOMOTOPY PATH TRACKING
// ============================================================================

/// Represents a transition between brain states as a path in complex space
pub const StateTransition = struct {
    start: homotopy.Complex,
    target: homotopy.Complex,
    duration_sec: f64,
    
    /// Map a trit to a location on the unit circle (roots of unity)
    /// Plus  -> 1 + 0i  (0 degrees)
    /// Zero  -> -0.5 + 0.866i (120 degrees)
    /// Minus -> -0.5 - 0.866i (240 degrees)
    pub fn tritToComplex(trit: continuation.Trit) homotopy.Complex {
        return switch (trit) {
            .plus => homotopy.Complex.init(1.0, 0.0),
            .zero => homotopy.Complex.init(-0.5, 0.8660254),
            .minus => homotopy.Complex.init(-0.5, -0.8660254),
        };
    }

    /// Generate homotopy path for visualization
    pub fn generatePath(start_trit: continuation.Trit, end_trit: continuation.Trit, steps: usize, allocator: Allocator) ![]homotopy.Complex {
        const c_start = tritToComplex(start_trit);
        const c_end = tritToComplex(end_trit);
        
        const path = try allocator.alloc(homotopy.Complex, steps);
        for (0..steps) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps - 1));
            // Linear interpolation in complex plane (H(x,t) logic)
            // H(t) = (1-t)Start + tEnd
            const p1 = homotopy.Complex.scale(c_start, 1.0 - t);
            const p2 = homotopy.Complex.scale(c_end, t);
            path[i] = homotopy.Complex.add(p1, p2);
        }
        return path;
    }
};

test "BrainState to Trit mapping" {
    try std.testing.expectEqual(continuation.Trit.plus, BrainState.focused.toTrit());
    try std.testing.expectEqual(continuation.Trit.zero, BrainState.relaxed.toTrit());
    try std.testing.expectEqual(continuation.Trit.minus, BrainState.drowsy.toTrit());
}

test "CognitiveModel updates history and beliefs" {
    const allocator = std.testing.allocator;
    var model = CognitiveModel.init(allocator);
    defer model.deinit(allocator);

    // Initial state is Zero (Relaxed/Default)
    try std.testing.expectEqual(continuation.Trit.zero, model.current_trit);

    // Update to Focused (Plus)
    try model.update(.focused, allocator);
    try std.testing.expectEqual(continuation.Trit.plus, model.current_trit);
    try std.testing.expectEqual(@as(usize, 1), model.history.items.len);
    
    // Beliefs should contain "focused"
    try std.testing.expect(model.beliefs.entails("focused"));
    try std.testing.expect(model.beliefs.entails("high-cognitive-load"));
}

test "Homotopy path generation" {
    const allocator = std.testing.allocator;
    
    // Path from Zero to Plus
    const path = try StateTransition.generatePath(.zero, .plus, 5, allocator);
    defer allocator.free(path);
    
    try std.testing.expectEqual(@as(usize, 5), path.len);
    
    // Start should be Zero position (-0.5 + 0.866i)
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), path[0].re, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.866), path[0].im, 0.001);
    
    // End should be Plus position (1.0 + 0.0i)
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), path[4].re, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), path[4].im, 0.001);
}

