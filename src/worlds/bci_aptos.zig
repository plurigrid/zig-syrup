//! BCI -> Aptos Bridge
//!
//! Connects OpenBCI brain states to Aptos GF(3) Society consensus.
//! Transforms neural signals into on-chain staking actions and consensus votes.
//!
//! Flow:
//! 1. OpenBCI EEG -> BrainState (Focus/Relax/Stress)
//! 2. BrainState -> CognitiveModel (GF(3) Trit: +1/0/-1)
//! 3. Trit -> ConsensusVote (Generator/Coordinator/Validator)
//! 4. ConsensusVote -> Syrup Payload (for Aptos Agent)

const std = @import("std");
const syrup = @import("syrup");
// Removed dependency on broken openbci_bridge.zig
// const openbci = @import("openbci_bridge.zig");
// Changed relative imports to use modules provided by build.zig
const bci_homotopy = @import("bci_homotopy"); 
const continuation = @import("continuation");
const Allocator = std.mem.Allocator;

/// EEG channel identifiers (OpenBCI Cyton/Daisy standard)
pub const EEGChannel = enum(u8) {
    ch1 = 0, ch2, ch3, ch4, ch5, ch6, ch7, ch8,
    ch9, ch10, ch11, ch12, ch13, ch14, ch15, ch16,
    pub const COUNT = 16;
};

/// Processed brain state (Mirror of OpenBCI Bridge state)
pub const OpenBciState = struct {
    timestamp: i64,
    focus_level: f32,
    relaxation_level: f32,
    engagement_level: f32,
    fatigue_level: f32,
    band_powers: [5]f32,
    signal_quality: [EEGChannel.COUNT]f32,
};

/// Neurofeedback configuration
pub const Neurofeedback = struct {
    target_focus: f32,
    target_relaxation: f32,
    tolerance: f32,
    reward_function: RewardFunction,
    
    pub const RewardFunction = enum {
        linear,
        sigmoid,
        threshold,
    };
    
    pub fn calculateReward(self: Neurofeedback, state: OpenBciState) f32 {
        const focus_diff = @abs(state.focus_level - self.target_focus);
        const relax_diff = @abs(state.relaxation_level - self.target_relaxation);
        const avg_diff = (focus_diff + relax_diff) / 2.0;
        
        return switch (self.reward_function) {
            .linear => 1.0 - std.math.clamp(avg_diff, 0.0, 1.0),
            .sigmoid => 1.0 / (1.0 + @exp(-5.0 * ((1.0 - avg_diff) - 0.5))),
            .threshold => if (avg_diff < self.tolerance) 1.0 else 0.0,
        };
    }
};

/// Aptos Consensus Role (GF(3) Trit)
pub const ConsensusRole = enum(u8) {
    coordinator = 0, // 0: Relaxed/Meditative
    validator = 1,   // -1: Drowsy/Stressed (Critical)
    generator = 2,   // +1: Focused/Excited (Creative)

    pub fn fromTrit(trit: continuation.Trit) ConsensusRole {
        return switch (trit) {
            .zero => .coordinator,
            .minus => .validator,
            .plus => .generator,
        };
    }
};

/// On-Chain Action derived from Brain State
pub const BrainAction = struct {
    role: ConsensusRole,
    confidence: f32, // 0.0-1.0
    reward: f32,     // Neurofeedback reward (0.0-1.0)
    timestamp: i64,
    
    pub fn toSyrup(self: BrainAction, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);

        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("role"),
            .value = syrup.Value.fromInteger(@intFromEnum(self.role)),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("confidence"),
            .value = syrup.Value.fromFloat(self.confidence),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("reward"),
            .value = syrup.Value.fromFloat(self.reward),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("timestamp"),
            .value = syrup.Value.fromInteger(self.timestamp),
        });

        // Add Aptos payload details
        const payload = try self.toAptosPayload(allocator);
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("aptos_payload"),
            .value = syrup.Value.fromByteString(payload),
        });

        return syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
    }

    /// Generate Aptos Move payload for pyusd_staking::stake
    /// Returns a JSON string representing the Move call arguments
    pub fn toAptosPayload(self: BrainAction, allocator: Allocator) ![]const u8 {
        // Map role to staking type:
        // Generator (+1) -> 2
        // Coordinator (0) -> 0
        // Validator (-1) -> 1
        const stake_type = @intFromEnum(self.role);
        
        // Amount scales with confidence (e.g. 100 * confidence)
        const amount = @as(u64, @intFromFloat(self.confidence * 100.0));
        
        return std.fmt.allocPrint(allocator, 
            "{{" ++
            "\"function\":\"0x1::pyusd_staking::stake\"," ++
            "\"type_arguments\":[]," ++
            "\"arguments\":[{d},{d}]" ++
            "}}",
            .{stake_type, amount}
        );
    }
};

/// Bridge connecting BCI to Aptos
pub const BciAptosBridge = struct {
    allocator: Allocator,
    cognitive_model: bci_homotopy.CognitiveModel,
    neurofeedback: ?Neurofeedback,
    
    pub fn init(allocator: Allocator) BciAptosBridge {
        return .{
            .allocator = allocator,
            .cognitive_model = bci_homotopy.CognitiveModel.init(allocator),
            .neurofeedback = null,
        };
    }
    
    pub fn deinit(self: *BciAptosBridge) void {
        self.cognitive_model.deinit(self.allocator);
    }

    /// Configure Neurofeedback targets (e.g. "Proof of Focus" staking)
    pub fn setNeurofeedback(self: *BciAptosBridge, config: Neurofeedback) void {
        self.neurofeedback = config;
    }

    /// Process a BrainState and produce an optional Action
    pub fn processState(self: *BciAptosBridge, state: OpenBciState) !?BrainAction {
        // 1. Map OpenBCI state to Homotopy BrainState
        const homotopy_state = mapToHomotopyState(state);
        
        // 2. Update Cognitive Model (Belief Revision)
        try self.cognitive_model.update(homotopy_state, self.allocator);
        
        // 3. Determine Trit from Model
        const current_trit = self.cognitive_model.current_trit;
        
        // 4. Calculate Confidence (magnitude of state)
        const confidence = switch (homotopy_state) {
            .focused => state.focus_level,
            .relaxed => state.relaxation_level,
            .meditative => state.relaxation_level, // approximate
            .excited => state.focus_level,
            .drowsy => state.fatigue_level,
            .stressed => state.fatigue_level, // approximate
        };

        // 5. Calculate Neurofeedback Reward (if configured)
        var reward: f32 = 0.0;
        if (self.neurofeedback) |nf| {
            reward = nf.calculateReward(state);
        }

        // 6. Generate Action if confidence is high enough
        // If Neurofeedback is active, we also require a minimum reward to act
        if (confidence > 0.6 and (self.neurofeedback == null or reward > 0.5)) {
            return BrainAction{
                .role = ConsensusRole.fromTrit(current_trit),
                .confidence = confidence,
                .reward = reward,
                .timestamp = state.timestamp,
            };
        }
        
        return null;
    }

    /// Map OpenBCI metrics to Homotopy BrainState enum
    fn mapToHomotopyState(state: OpenBciState) bci_homotopy.BrainState {
        // Simple heuristic mapping
        if (state.fatigue_level > 0.7) return .drowsy;
        if (state.focus_level > 0.7) return .focused;
        if (state.relaxation_level > 0.7) return .relaxed;
        
        // Secondary checks
        if (state.focus_level > state.relaxation_level) return .excited;
        return .meditative; // Default to balanced/meditative
    }
};

test "process state generates action" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var bridge = BciAptosBridge.init(allocator);
    defer bridge.deinit();

    // High focus state -> Generator (+1)
    const focus_state = OpenBciState{
        .timestamp = 1000,
        .focus_level = 0.9,
        .relaxation_level = 0.1,
        .engagement_level = 0.8,
        .fatigue_level = 0.0,
        .band_powers = .{0} ** 5,
        .signal_quality = .{0} ** 16,
    };
    
    const action = try bridge.processState(focus_state);
    try testing.expect(action != null);
    try testing.expectEqual(ConsensusRole.generator, action.?.role);
    try testing.expect(action.?.confidence > 0.8);

    // High fatigue state -> Validator (-1)
    const tired_state = OpenBciState{
        .timestamp = 2000,
        .focus_level = 0.1,
        .relaxation_level = 0.2,
        .engagement_level = 0.1,
        .fatigue_level = 0.95,
        .band_powers = .{0} ** 5,
        .signal_quality = .{0} ** 16,
    };

    const action2 = try bridge.processState(tired_state);
    try testing.expect(action2 != null);
    try testing.expectEqual(ConsensusRole.validator, action2.?.role);
    
    // Verify payload generation
    const payload = try action2.?.toAptosPayload(allocator);
    defer allocator.free(payload);
    
    // Expect Validator (1) and scaled amount
    try testing.expect(std.mem.indexOf(u8, payload, "\"arguments\":[1,") != null);
}

test "neurofeedback gates action" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var bridge = BciAptosBridge.init(allocator);
    defer bridge.deinit();

    // Set "Proof of Focus" requirement
    bridge.setNeurofeedback(.{
        .target_focus = 0.9,
        .target_relaxation = 0.0,
        .tolerance = 0.1,
        .reward_function = .threshold,
    });

    // High focus state (Matches target) -> Action allowed
    const focus_state = OpenBciState{
        .timestamp = 3000,
        .focus_level = 0.95,
        .relaxation_level = 0.05,
        .engagement_level = 0.9,
        .fatigue_level = 0.0,
        .band_powers = .{0} ** 5,
        .signal_quality = .{0} ** 16,
    };
    
    const action = try bridge.processState(focus_state);
    try testing.expect(action != null);
    try testing.expect(action.?.reward > 0.9); // High reward

    // Low focus state (Misses target) -> Action blocked
    const distracted_state = OpenBciState{
        .timestamp = 4000,
        .focus_level = 0.4,
        .relaxation_level = 0.3,
        .engagement_level = 0.4,
        .fatigue_level = 0.1,
        .band_powers = .{0} ** 5,
        .signal_quality = .{0} ** 16,
    };

    const action2 = try bridge.processState(distracted_state);
    try testing.expect(action2 == null); // Blocked by low reward
}
