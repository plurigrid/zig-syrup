//! OpenBCI Bridge for neurofeedback integration
//!
//! Connects EEG data streams to world parameters, enabling
//! brain-controlled multiplayer simulations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syrup = @import("syrup");
const World = @import("world.zig").World;
const Player = @import("world.zig").Player;

/// Bridge error types
pub const BridgeError = error{
    ConnectionFailed,
    InvalidEEGData,
    ChannelNotFound,
    CalibrationError,
    PlayerNotFound,
    OutOfMemory,
};

/// EEG channel identifiers (OpenBCI Cyton/Daisy standard)
pub const EEGChannel = enum(u8) {
    // Standard 8 channels (Cyton)
    ch1 = 0,
    ch2,
    ch3,
    ch4,
    ch5,
    ch6,
    ch7,
    ch8,
    // Extended 8 channels (Daisy)
    ch9,
    ch10,
    ch11,
    ch12,
    ch13,
    ch14,
    ch15,
    ch16,
    
    pub const COUNT = 16;
    pub const CYTON_COUNT = 8;
};

/// Brain wave frequency bands
pub const FrequencyBand = enum {
    delta,    // 0.5-4 Hz - Deep sleep
    theta,    // 4-8 Hz - Meditation, drowsiness
    alpha,    // 8-13 Hz - Relaxed awareness
    beta,     // 13-30 Hz - Active thinking
    gamma,    // 30-100 Hz - High-level cognition
    
    /// Get frequency range
    pub fn range(self: FrequencyBand) struct { min: f32, max: f32 } {
        return switch (self) {
            .delta => .{ .min = 0.5, .max = 4.0 },
            .theta => .{ .min = 4.0, .max = 8.0 },
            .alpha => .{ .min = 8.0, .max = 13.0 },
            .beta => .{ .min = 13.0, .max = 30.0 },
            .gamma => .{ .min = 30.0, .max = 100.0 },
        };
    }
};

/// Raw EEG sample
pub const EEGSample = struct {
    timestamp: i64,
    /// Channel values in microvolts
    channels: [EEGChannel.COUNT]f32,
    /// Accelerometer data (if available)
    accel: ?[3]f32,
    /// Sample number (for synchronization)
    sample_num: u32,
};

/// Processed brain state
pub const BrainState = struct {
    /// Timestamp of analysis
    timestamp: i64,
    /// Focus level (0.0-1.0, based on beta/alpha ratio)
    focus_level: f32,
    /// Relaxation level (0.0-1.0, based on alpha power)
    relaxation_level: f32,
    /// Engagement level (0.0-1.0, overall signal quality)
    engagement_level: f32,
    /// Fatigue indicator (0.0-1.0, based on theta/delta)
    fatigue_level: f32,
    /// Band powers
    band_powers: [5]f32, // delta, theta, alpha, beta, gamma
    /// Signal quality per channel (0.0-1.0)
    signal_quality: [EEGChannel.COUNT]f32,
    
    /// Serialize to syrup
    pub fn toSyrup(self: BrainState, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("focus"),
            .value = syrup.Value.fromFloat(self.focus_level),
        });
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("relaxation"),
            .value = syrup.Value.fromFloat(self.relaxation_level),
        });
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("engagement"),
            .value = syrup.Value.fromFloat(self.engagement_level),
        });
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("fatigue"),
            .value = syrup.Value.fromFloat(self.fatigue_level),
        });
        
        // Band powers
        var band_list = std.ArrayListUnmanaged(syrup.Value){};
        defer band_list.deinit(allocator);
        
        for (self.band_powers) |power| {
            try band_list.append(allocator, syrup.Value.fromFloat(power));
        }
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("bands"),
            .value = syrup.Value.fromList(try band_list.toOwnedSlice(allocator)),
        });
        
        return syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
    }
};

/// Player brain mapping
pub const PlayerBrainMapping = struct {
    player_id: u32,
    /// Primary channels for this player
    channels: []const EEGChannel,
    /// Calibration baseline
    baseline: BrainState,
    /// Whether currently active
    active: bool,
    /// Last update timestamp
    last_update: i64,
};

/// Neurofeedback configuration
pub const Neurofeedback = struct {
    /// Target focus level
    target_focus: f32,
    /// Target relaxation level
    target_relaxation: f32,
    /// Tolerance for feedback
    tolerance: f32,
    /// Reward function (how to convert state to world parameters)
    reward_function: RewardFunction,
    
    pub const RewardFunction = enum {
        linear,
        sigmoid,
        threshold,
    };
    
    /// Calculate reward based on brain state
    pub fn calculateReward(self: Neurofeedback, state: BrainState) f32 {
        const focus_diff = @abs(state.focus_level - self.target_focus);
        const relax_diff = @abs(state.relaxation_level - self.target_relaxation);
        
        const avg_diff = (focus_diff + relax_diff) / 2.0;
        
        return switch (self.reward_function) {
            .linear => 1.0 - std.math.clamp(avg_diff, 0.0, 1.0),
            .sigmoid => sigmoid(1.0 - avg_diff),
            .threshold => if (avg_diff < self.tolerance) 1.0 else 0.0,
        };
    }
    
    fn sigmoid(x: f32) f32 {
        return 1.0 / (1.0 + @exp(-5.0 * (x - 0.5)));
    }
};

/// OpenBCI Bridge for EEG-world integration
pub const OpenBCIBridge = struct {
    const Self = @This();
    
    allocator: Allocator,
    connected_world: World,
    
    // Player mappings
    player_mappings: std.AutoHashMapUnmanaged(u32, PlayerBrainMapping),
    
    // EEG data buffers
    sample_buffer: std.ArrayListUnmanaged(EEGSample),
    max_buffer_size: usize,
    
    // Brain states
    brain_states: std.AutoHashMapUnmanaged(u32, BrainState),
    
    // Processing
    sample_rate: f32,
    fft_size: usize,
    window_function: []f32,
    
    // Neurofeedback
    neurofeedback: ?Neurofeedback,
    
    // Statistics
    total_samples: u64,
    dropped_samples: u64,
    
    pub fn init(allocator: Allocator, world: World) !Self {
        const fft_size = 256;
        var window = try allocator.alloc(f32, fft_size);
        
        // Hann window
        for (0..fft_size) |i| {
            const n = @as(f32, @floatFromInt(i));
            const N = @as(f32, @floatFromInt(fft_size));
            window[i] = 0.5 * (1.0 - @cos(2.0 * std.math.pi * n / (N - 1)));
        }
        
        return Self{
            .allocator = allocator,
            .connected_world = world,
            .player_mappings = .{},
            .sample_buffer = .{},
            .max_buffer_size = 1000,
            .brain_states = .{},
            .sample_rate = 250.0, // OpenBCI default
            .fft_size = fft_size,
            .window_function = window,
            .neurofeedback = null,
            .total_samples = 0,
            .dropped_samples = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.window_function);
        
        var it = self.player_mappings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.channels);
        }
        self.player_mappings.deinit(self.allocator);
        
        self.sample_buffer.deinit(self.allocator);
        self.brain_states.deinit(self.allocator);
    }
    
    /// Map a player to EEG channels
    pub fn mapPlayer(
        self: *Self,
        player_id: u32,
        channels: []const EEGChannel,
    ) !void {
        const channels_copy = try self.allocator.dupe(EEGChannel, channels);
        errdefer self.allocator.free(channels_copy);
        
        const mapping = PlayerBrainMapping{
            .player_id = player_id,
            .channels = channels_copy,
            .baseline = .{
                .timestamp = 0,
                .focus_level = 0.5,
                .relaxation_level = 0.5,
                .engagement_level = 0.5,
                .fatigue_level = 0.0,
                .band_powers = .{0} ** 5,
                .signal_quality = .{0} ** EEGChannel.COUNT,
            },
            .active = false,
            .last_update = 0,
        };
        
        try self.player_mappings.put(self.allocator, player_id, mapping);
    }
    
    /// Unmap a player
    pub fn unmapPlayer(self: *Self, player_id: u32) void {
        if (self.player_mappings.fetchRemove(player_id)) |entry| {
            self.allocator.free(entry.value.channels);
        }
    }
    
    /// Process incoming EEG sample
    pub fn processSample(self: *Self, sample: EEGSample) !void {
        self.total_samples += 1;
        
        // Add to buffer
        try self.sample_buffer.append(self.allocator, sample);
        
        // Trim buffer if needed
        if (self.sample_buffer.items.len > self.max_buffer_size) {
            _ = self.sample_buffer.orderedRemove(0);
            self.dropped_samples += 1;
        }
        
        // Process for each mapped player
        var it = self.player_mappings.iterator();
        while (it.next()) |entry| {
            const player_id = entry.key_ptr.*;
            const mapping = entry.value_ptr;
            
            if (!mapping.active) continue;
            
            const state = try self.analyzeBrainState(mapping.channels);
            try self.brain_states.put(self.allocator, player_id, state);
            
            // Update world parameter
            try self.updateWorldParameter(player_id, state);
        }
    }
    
    /// Analyze brain state from channels
    fn analyzeBrainState(self: Self, channels: []const EEGChannel) !BrainState {
        _ = self;
        
        // Simplified - would perform actual FFT and band power calculation
        var band_powers = [_]f32{0} ** 5;
        var signal_quality = [_]f32{0.5} ** EEGChannel.COUNT;
        
        // Placeholder calculations
        for (channels) |ch| {
            const idx = @intFromEnum(ch);
            if (idx < EEGChannel.COUNT) {
                signal_quality[idx] = 0.8;
            }
        }
        
        // Synthetic band powers
        band_powers[2] = 0.3; // alpha
        band_powers[3] = 0.4; // beta
        
        const focus = band_powers[3] / (band_powers[2] + 0.01);
        const relaxation = band_powers[2];
        
        return BrainState{
            .timestamp = std.time.milliTimestamp(),
            .focus_level = std.math.clamp(focus, 0.0, 1.0),
            .relaxation_level = std.math.clamp(relaxation, 0.0, 1.0),
            .engagement_level = 0.7,
            .fatigue_level = 0.2,
            .band_powers = band_powers,
            .signal_quality = signal_quality,
        };
    }
    
    /// Update world parameter based on brain state
    fn updateWorldParameter(self: *Self, player_id: u32, state: BrainState) !void {
        // Calculate parameter value from brain state
        const value = state.focus_level;
        
        // Update world
        const param_name = try std.fmt.allocPrint(
            self.allocator,
            "player_{d}_focus",
            .{player_id},
        );
        defer self.allocator.free(param_name);
        
        try self.connected_world.setParameter(param_name, value);
    }
    
    /// Get brain state for player
    pub fn getBrainState(self: Self, player_id: u32) ?BrainState {
        return self.brain_states.get(player_id);
    }
    
    /// Set baseline for player calibration
    pub fn calibratePlayer(self: *Self, player_id: u32, duration_ms: i64) !void {
        const mapping = self.player_mappings.getPtr(player_id) orelse {
            return BridgeError.PlayerNotFound;
        };
        
        // Collect samples over calibration period
        const start_time = std.time.milliTimestamp();
        var samples_collected: usize = 0;
        var accumulated_state = BrainState{
            .timestamp = 0,
            .focus_level = 0,
            .relaxation_level = 0,
            .engagement_level = 0,
            .fatigue_level = 0,
            .band_powers = .{0} ** 5,
            .signal_quality = .{0} ** EEGChannel.COUNT,
        };
        
        for (self.sample_buffer.items) |sample| {
            if (sample.timestamp >= start_time - duration_ms) {
                const state = try self.analyzeBrainState(mapping.channels);
                accumulated_state.focus_level += state.focus_level;
                accumulated_state.relaxation_level += state.relaxation_level;
                samples_collected += 1;
            }
        }
        
        if (samples_collected > 0) {
            accumulated_state.focus_level /= @floatFromInt(samples_collected);
            accumulated_state.relaxation_level /= @floatFromInt(samples_collected);
            mapping.baseline = accumulated_state;
            mapping.active = true;
        } else {
            return BridgeError.CalibrationError;
        }
    }
    
    /// Enable neurofeedback
    pub fn enableNeurofeedback(self: *Self, config: Neurofeedback) void {
        self.neurofeedback = config;
    }
    
    /// Get neurofeedback reward for player
    pub fn getReward(self: Self, player_id: u32) ?f32 {
        const nf = self.neurofeedback orelse return null;
        const state = self.brain_states.get(player_id) orelse return null;
        return nf.calculateReward(state);
    }
    
    /// Create simulated EEG data for testing
    pub fn createSimulatedSample(self: *Self, focus_level: f32) !EEGSample {
        _ = self;
        
        var channels = [_]f32{0} ** EEGChannel.COUNT;
        
        // Simulate channels based on focus level
        for (0..EEGChannel.CYTON_COUNT) |i| {
            const noise = std.crypto.random.float(f32) * 10.0;
            const signal = focus_level * 50.0;
            channels[i] = signal + noise - 25.0; // Center around 0
        }
        
        return EEGSample{
            .timestamp = std.time.milliTimestamp(),
            .channels = channels,
            .accel = .{ 0, 0, 1.0 },
            .sample_num = @intCast(std.crypto.random.int(u32)),
        };
    }
    
    /// Get statistics
    pub fn getStats(self: Self) BridgeStats {
        return .{
            .total_samples = self.total_samples,
            .dropped_samples = self.dropped_samples,
            .buffer_size = self.sample_buffer.items.len,
            .mapped_players = self.player_mappings.count(),
        };
    }
    
    pub const BridgeStats = struct {
        total_samples: u64,
        dropped_samples: u64,
        buffer_size: usize,
        mapped_players: usize,
    };
    
    /// Serialize bridge state to syrup
    pub fn toSyrup(self: Self, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("world"),
            .value = syrup.Value.fromString(self.connected_world.config.uri),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("mapped_players"),
            .value = syrup.Value.fromInteger(@intCast(self.player_mappings.count())),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("total_samples"),
            .value = syrup.Value.fromInteger(@intCast(self.total_samples)),
        });
        
        return syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
    }
};

/// EEG data parser for OpenBCI binary format
pub const OpenBCIParser = struct {
    const HEADER_BYTE: u8 = 0xA0;
    
    /// Parse a single sample from OpenBCI binary stream
    pub fn parseSample(data: []const u8, sample_num: u32) !EEGSample {
        if (data.len < 33) return BridgeError.InvalidEEGData;
        
        // Standard OpenBCI packet: 0xA0 + sample + 8 channels (3 bytes each) + 3 accel
        if (data[0] != HEADER_BYTE) return BridgeError.InvalidEEGData;
        
        var channels = [_]f32{0} ** EEGChannel.COUNT;
        
        // Parse 8 channels
        for (0..8) |i| {
            const offset = 2 + i * 3;
            const raw: i24 = @as(i24, data[offset]) << 16 |
                            @as(i24, data[offset + 1]) << 8 |
                            @as(i24, data[offset + 2]);
            // Convert to microvolts (OpenBCI scale factor)
            channels[i] = @as(f32, @floatFromInt(raw)) * 0.02235174;
        }
        
        // Parse accelerometer (optional, last 6 bytes before stop byte)
        const accel: ?[3]f32 = if (data.len >= 32) blk: {
            var a = [_]f32{0} ** 3;
            for (0..3) |i| {
                const offset = 26 + i * 2;
                const raw: i16 = @as(i16, data[offset]) << 8 | data[offset + 1];
                a[i] = @as(f32, @floatFromInt(raw)) * 0.002;
            }
            break :blk a;
        } else null;
        
        return EEGSample{
            .timestamp = std.time.milliTimestamp(),
            .channels = channels,
            .accel = accel,
            .sample_num = sample_num,
        };
    }
};

// Tests
const testing = std.testing;

test "brain state serialization" {
    const allocator = testing.allocator;
    
    const state = BrainState{
        .timestamp = 0,
        .focus_level = 0.75,
        .relaxation_level = 0.60,
        .engagement_level = 0.80,
        .fatigue_level = 0.20,
        .band_powers = .{ 0.1, 0.2, 0.3, 0.4, 0.0 },
        .signal_quality = .{0.9} ** EEGChannel.COUNT,
    };
    
    const syrup_val = try state.toSyrup(allocator);
    defer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
    }
    
    try testing.expect(syrup_val == .dictionary);
}

test "openbci bridge" {
    const allocator = testing.allocator;
    
    var world = try World.init(allocator, .{
        .uri = "test://world",
        .max_players = 3,
    });
    defer world.deinit();
    
    var bridge = try OpenBCIBridge.init(allocator, world);
    defer bridge.deinit();
    
    try testing.expectEqual(@as(usize, 0), bridge.player_mappings.count());
}

test "player mapping" {
    const allocator = testing.allocator;
    
    var world = try World.init(allocator, .{
        .uri = "test://world",
        .max_players = 3,
    });
    defer world.deinit();
    
    var bridge = try OpenBCIBridge.init(allocator, world);
    defer bridge.deinit();
    
    const channels = &[_]EEGChannel{ .ch1, .ch2, .ch3 };
    try bridge.mapPlayer(0, channels);
    
    try testing.expectEqual(@as(usize, 1), bridge.player_mappings.count());
    
    bridge.unmapPlayer(0);
    try testing.expectEqual(@as(usize, 0), bridge.player_mappings.count());
}

test "simulated sample" {
    const allocator = testing.allocator;
    
    var world = try World.init(allocator, .{
        .uri = "test://world",
        .max_players = 3,
    });
    defer world.deinit();
    
    var bridge = try OpenBCIBridge.init(allocator, world);
    defer bridge.deinit();
    
    const sample = try bridge.createSimulatedSample(0.75);
    
    try testing.expect(sample.timestamp > 0);
}

test "neurofeedback reward" {
    const nf = Neurofeedback{
        .target_focus = 0.8,
        .target_relaxation = 0.6,
        .tolerance = 0.1,
        .reward_function = .linear,
    };
    
    const state = BrainState{
        .timestamp = 0,
        .focus_level = 0.8,
        .relaxation_level = 0.6,
        .engagement_level = 0.8,
        .fatigue_level = 0.0,
        .band_powers = .{0} ** 5,
        .signal_quality = .{0} ** EEGChannel.COUNT,
    };
    
    const reward = nf.calculateReward(state);
    try testing.expect(reward > 0.9); // Should be close to 1.0 for exact match
}
