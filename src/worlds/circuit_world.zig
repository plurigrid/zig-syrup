//! Circuit-based world for zero-knowledge proofs
//!
//! Represents world state as arithmetic circuits for deterministic
//! evaluation and optional ZK proofs of world transitions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syrup = @import("syrup");
const bristol = @import("bristol");
const World = @import("world.zig").World;
const WorldState = @import("world.zig").WorldState;
const Player = @import("world.zig").Player;

/// Circuit error types
pub const CircuitError = error{
    InvalidWorldState,
    CircuitCompilationError,
    EvaluationError,
    ProofGenerationError,
    ProofVerificationError,
    InvalidInput,
    OutOfMemory,
};

/// Input to circuit evaluation
pub const CircuitInput = struct {
    /// Player inputs (actions/choices)
    player_inputs: []const PlayerInput,
    /// World parameters
    parameters: []const Parameter,
    /// Randomness for deterministic simulation
    seed: u64,
    
    pub const PlayerInput = struct {
        player_id: u32,
        action: Action,
        data: u64, // Encoded action data
    };
    
    pub const Action = enum(u8) {
        none = 0,
        move,
        interact,
        attack,
        defend,
        use_item,
        communicate,
    };
    
    pub const Parameter = struct {
        name: []const u8,
        value: i64,
    };
    
    /// Serialize to syrup
    pub fn toSyrup(self: CircuitInput, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);
        
        // Player inputs
        var inputs_list = std.ArrayListUnmanaged(syrup.Value){};
        defer inputs_list.deinit(allocator);
        
        for (self.player_inputs) |input| {
            var input_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
            defer input_entries.deinit(allocator);
            
            try input_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("player"),
                .value = syrup.Value.fromInteger(input.player_id),
            });
            try input_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("action"),
                .value = syrup.Value.fromInteger(@intFromEnum(input.action)),
            });
            try input_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("data"),
                .value = syrup.Value.fromInteger(@intCast(input.data)),
            });
            
            try inputs_list.append(allocator, syrup.Value.fromDictionary(
                try input_entries.toOwnedSlice(allocator),
            ));
        }
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("inputs"),
            .value = syrup.Value.fromList(try inputs_list.toOwnedSlice(allocator)),
        });
        
        // Parameters
        var params_list = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer params_list.deinit(allocator);
        
        for (self.parameters) |param| {
            try params_list.append(allocator, .{
                .key = syrup.Value.fromString(param.name),
                .value = syrup.Value.fromInteger(param.value),
            });
        }
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("params"),
            .value = syrup.Value.fromDictionary(try params_list.toOwnedSlice(allocator)),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("seed"),
            .value = syrup.Value.fromInteger(@intCast(self.seed)),
        });
        
        return syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
    }
};

/// Output from circuit evaluation
pub const CircuitOutput = struct {
    /// New world state hash
    new_state_hash: [32]u8,
    /// Player results (scores/rewards)
    player_results: []const PlayerResult,
    /// Events that occurred
    events: []const Event,
    /// Final tick
    final_tick: u64,
    
    pub const PlayerResult = struct {
        player_id: u32,
        score: i64,
        reward: i64,
        eliminated: bool,
    };
    
    pub const Event = struct {
        tick: u64,
        event_type: EventType,
        data: u64,
    };
    
    pub const EventType = enum(u8) {
        none = 0,
        player_joined,
        player_left,
        collision,
        goal_reached,
        item_collected,
        combat_resolved,
    };
    
    /// Serialize to syrup
    pub fn toSyrup(self: CircuitOutput, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);
        
        // State hash
        var hash_list = std.ArrayListUnmanaged(syrup.Value){};
        defer hash_list.deinit(allocator);
        
        for (self.new_state_hash) |b| {
            try hash_list.append(allocator, syrup.Value.fromInteger(b));
        }
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("state_hash"),
            .value = syrup.Value.fromList(try hash_list.toOwnedSlice(allocator)),
        });
        
        // Results
        var results_list = std.ArrayListUnmanaged(syrup.Value){};
        defer results_list.deinit(allocator);
        
        for (self.player_results) |result| {
            var result_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
            defer result_entries.deinit(allocator);
            
            try result_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("player"),
                .value = syrup.Value.fromInteger(result.player_id),
            });
            try result_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("score"),
                .value = syrup.Value.fromInteger(result.score),
            });
            try result_entries.append(allocator, .{
                .key = syrup.Value.fromSymbol("reward"),
                .value = syrup.Value.fromInteger(result.reward),
            });
            
            try results_list.append(allocator, syrup.Value.fromDictionary(
                try result_entries.toOwnedSlice(allocator),
            ));
        }
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("results"),
            .value = syrup.Value.fromList(try results_list.toOwnedSlice(allocator)),
        });
        
        try entries.append(allocator, .{
            .key = syrup.Value.fromSymbol("tick"),
            .value = syrup.Value.fromInteger(@intCast(self.final_tick)),
        });
        
        return syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
    }
};

/// Zero-knowledge proof of world transition
pub const ZKWorldProof = struct {
    /// Proof data (circuit-specific)
    proof_data: []const u8,
    /// Public inputs (state hashes, etc.)
    public_inputs: []const u64,
    /// Verification key reference
    vk_hash: [32]u8,
    
    pub fn deinit(self: *ZKWorldProof, allocator: Allocator) void {
        allocator.free(self.proof_data);
        allocator.free(self.public_inputs);
    }
};

/// Arithmetic gate for world circuits
pub const ArithGate = struct {
    op: Op,
    inputs: [2]u32, // Wire indices
    output: u32,
    
    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        eq,
        lt,
        gt,
        and_gate,
        or_gate,
        not_gate,
    };
};

/// Circuit-based world for deterministic evaluation
pub const CircuitWorld = struct {
    const Self = @This();
    
    allocator: Allocator,
    base_world: World,
    
    // Circuit state
    gates: std.ArrayListUnmanaged(ArithGate),
    num_wires: u32,
    num_public_inputs: u32,
    num_private_inputs: u32,
    
    // Evaluation state
    wire_values: std.ArrayListUnmanaged(u64),
    
    // ZK state
    zk_enabled: bool,
    proving_key: ?[]const u8,
    verification_key: ?[]const u8,
    
    pub fn init(allocator: Allocator, world: World) !Self {
        return Self{
            .allocator = allocator,
            .base_world = world,
            .gates = .{},
            .num_wires = 0,
            .num_public_inputs = 0,
            .num_private_inputs = 0,
            .wire_values = .{},
            .zk_enabled = false,
            .proving_key = null,
            .verification_key = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.gates.deinit(self.allocator);
        self.wire_values.deinit(self.allocator);
        if (self.proving_key) |pk| self.allocator.free(pk);
        if (self.verification_key) |vk| self.allocator.free(vk);
    }
    
    /// Compile world state to circuit
    pub fn compile(self: *Self) !void {
        // Reset circuit
        self.gates.clearRetainingCapacity();
        self.num_wires = 0;
        
        // Allocate wires for public inputs
        self.num_public_inputs = @intCast(2 + self.base_world.getPlayerCount() * 3); // seed + tick + player_data
        self.num_wires = self.num_public_inputs;
        
        // Allocate wires for private inputs (randomness)
        self.num_private_inputs = 8;
        self.num_wires += self.num_private_inputs;
        
        // Compile world logic to gates
        try self.compileWorldLogic();
        
        // Compile player interactions
        try self.compilePlayerLogic();
        
        // Compile output constraints
        try self.compileOutputLogic();
    }
    
    fn compileWorldLogic(self: *Self) !void {
        // Add gates for world state transitions
        _ = self;
        // Simplified - would generate actual arithmetic constraints
    }
    
    fn compilePlayerLogic(self: *Self) !void {
        // Add gates for player action processing
        _ = self;
        // Simplified - would generate constraints for each player
    }
    
    fn compileOutputLogic(self: *Self) !void {
        // Add gates for computing output state hash
        _ = self;
        // Simplified - would hash final state
    }
    
    /// Add a gate to the circuit
    pub fn addGate(self: *Self, gate: ArithGate) !void {
        try self.gates.append(self.allocator, gate);
        self.num_wires = @max(self.num_wires, gate.output + 1);
    }
    
    /// Evaluate circuit with given inputs
    pub fn evaluate(self: *Self, inputs: CircuitInput) !CircuitOutput {
        // Set public inputs
        try self.wire_values.resize(self.allocator, self.num_wires);
        @memset(self.wire_values.items, 0);
        
        // Wire 0: seed
        self.wire_values.items[0] = inputs.seed;
        // Wire 1: current tick
        self.wire_values.items[1] = self.base_world.getTick();
        
        // Set player inputs
        for (inputs.player_inputs, 0..) |pi, i| {
            const base = 2 + i * 3;
            if (base + 2 < self.num_public_inputs) {
                self.wire_values.items[base] = pi.player_id;
                self.wire_values.items[base + 1] = @intFromEnum(pi.action);
                self.wire_values.items[base + 2] = pi.data;
            }
        }
        
        // Evaluate gates
        for (self.gates.items) |gate| {
            const a = self.wire_values.items[gate.inputs[0]];
            const b = self.wire_values.items[gate.inputs[1]];
            
            self.wire_values.items[gate.output] = switch (gate.op) {
                .add => a +% b,
                .sub => a -% b,
                .mul => a *% b,
                .div => if (b != 0) a / b else 0,
                .eq => if (a == b) 1 else 0,
                .lt => if (a < b) 1 else 0,
                .gt => if (a > b) 1 else 0,
                .and_gate => if (a != 0 and b != 0) 1 else 0,
                .or_gate => if (a != 0 or b != 0) 1 else 0,
                .not_gate => if (a != 0) 0 else 1,
            };
        }
        
        // Generate output
        var state_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(
            std.mem.asBytes(self.wire_values.items),
            &state_hash,
            .{},
        );
        
        var results = std.ArrayListUnmanaged(CircuitOutput.PlayerResult){};
        defer results.deinit(self.allocator);
        
        // Generate results from wire values
        for (inputs.player_inputs) |pi| {
            try results.append(self.allocator, .{
                .player_id = pi.player_id,
                .score = @intCast(self.wire_values.items[pi.player_id % self.wire_values.items.len]),
                .reward = 0,
                .eliminated = false,
            });
        }
        
        return CircuitOutput{
            .new_state_hash = state_hash,
            .player_results = try results.toOwnedSlice(self.allocator),
            .events = &[_]CircuitOutput.Event{},
            .final_tick = self.base_world.getTick() + 1,
        };
    }
    
    /// Convert to Bristol format circuit
    pub fn toBristol(self: Self, allocator: Allocator) !bristol.Circuit {
        var gates = try allocator.alloc(bristol.Gate, self.gates.items.len);
        
        for (self.gates.items, 0..) |g, i| {
            // Map arithmetic ops to Bristol gates
            const op: bristol.GateType = switch (g.op) {
                .add, .sub, .mul => .EQ, // Simplified
                .and_gate => .AND,
                .or_gate => .XOR,
                .not_gate => .INV,
                else => .EQ,
            };
            
            const in_wires = try allocator.alloc(u32, 2);
            in_wires[0] = g.inputs[0];
            in_wires[1] = g.inputs[1];
            
            const out_wires = try allocator.alloc(u32, 1);
            out_wires[0] = g.output;
            
            gates[i] = .{
                .num_in = 2,
                .num_out = 1,
                .input_wires = in_wires,
                .output_wires = out_wires,
                .op = op,
            };
        }
        
        return bristol.Circuit{
            .num_gates = @intCast(gates.len),
            .num_wires = self.num_wires,
            .inputs = &[_]u32{},
            .outputs = &[_]u32{},
            .gates = gates,
        };
    }
    
    /// Generate ZK proof of evaluation (stub)
    pub fn generateProof(self: Self, output: CircuitOutput) !ZKWorldProof {
        _ = output;
        
        if (!self.zk_enabled) {
            return CircuitError.ProofGenerationError;
        }
        
        // Simplified - would use actual ZK proving system
        return ZKWorldProof{
            .proof_data = try self.allocator.dupe(u8, "mock_proof"),
            .public_inputs = try self.allocator.dupe(u64, &[_]u64{1, 2, 3}),
            .vk_hash = [_]u8{0} ** 32,
        };
    }
    
    /// Verify ZK proof (stub)
    pub fn verifyProof(self: Self, proof: ZKWorldProof) !bool {
        _ = self;
        _ = proof;
        // Simplified - would use actual ZK verification
        return true;
    }
    
    /// Enable ZK proving
    pub fn enableZK(self: *Self) !void {
        self.zk_enabled = true;
        // Would generate keys here
    }
    
    /// Get circuit statistics
    pub fn getStats(self: Self) CircuitStats {
        return .{
            .num_gates = self.gates.items.len,
            .num_wires = self.num_wires,
            .num_public_inputs = self.num_public_inputs,
            .num_private_inputs = self.num_private_inputs,
        };
    }
    
    pub const CircuitStats = struct {
        num_gates: usize,
        num_wires: u32,
        num_public_inputs: u32,
        num_private_inputs: u32,
    };
};

/// Circuit builder for constructing world circuits programmatically
pub const CircuitBuilder = struct {
    const Self = @This();
    
    allocator: Allocator,
    gates: std.ArrayListUnmanaged(ArithGate),
    next_wire: u32,
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .gates = .{},
            .next_wire = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.gates.deinit(self.allocator);
    }
    
    /// Allocate new wire
    pub fn allocWire(self: *Self) u32 {
        const w = self.next_wire;
        self.next_wire += 1;
        return w;
    }
    
    /// Allocate multiple wires
    pub fn allocWires(self: *Self, count: u32) []u32 {
        const start = self.next_wire;
        self.next_wire += count;
        
        var wires = self.allocator.alloc(u32, count) catch return &[_]u32{};
        for (0..count) |i| {
            wires[i] = start + @as(u32, @intCast(i));
        }
        return wires;
    }
    
    /// Add constant value
    pub fn constant(self: *Self, value: u64) !u32 {
        const out = self.allocWire();
        try self.gates.append(self.allocator, .{
            .op = .add,
            .inputs = .{ @intCast(value), 0 },
            .output = out,
        });
        return out;
    }
    
    /// Add two values
    pub fn add(self: *Self, a: u32, b: u32) !u32 {
        const out = self.allocWire();
        try self.gates.append(self.allocator, .{
            .op = .add,
            .inputs = .{ a, b },
            .output = out,
        });
        return out;
    }
    
    /// Multiply two values
    pub fn mul(self: *Self, a: u32, b: u32) !u32 {
        const out = self.allocWire();
        try self.gates.append(self.allocator, .{
            .op = .mul,
            .inputs = .{ a, b },
            .output = out,
        });
        return out;
    }
    
    /// Equality check
    pub fn equal(self: *Self, a: u32, b: u32) !u32 {
        const out = self.allocWire();
        try self.gates.append(self.allocator, .{
            .op = .eq,
            .inputs = .{ a, b },
            .output = out,
        });
        return out;
    }
    
    /// Build circuit world from current gates
    pub fn buildWorld(self: *Self, base_world: World) !CircuitWorld {
        var world = try CircuitWorld.init(self.allocator, base_world);
        
        world.gates = self.gates;
        self.gates = .{};
        world.num_wires = self.next_wire;
        
        return world;
    }
};

// Tests
const testing = std.testing;

test "circuit input serialization" {
    const allocator = testing.allocator;
    
    const input = CircuitInput{
        .player_inputs = &[_]CircuitInput.PlayerInput{
            .{
                .player_id = 0,
                .action = .move,
                .data = 100,
            },
        },
        .parameters = &[_]CircuitInput.Parameter{
            .{ .name = "difficulty", .value = 5 },
        },
        .seed = 12345,
    };
    
    const syrup_val = try input.toSyrup(allocator);
    defer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
    }
    
    try testing.expect(syrup_val == .dictionary);
}

test "circuit builder" {
    const allocator = testing.allocator;
    
    var builder = CircuitBuilder.init(allocator);
    defer builder.deinit();
    
    const a = try builder.constant(5);
    const b = try builder.constant(3);
    const sum = try builder.add(a, b);
    const product = try builder.mul(sum, b);
    _ = product;
    
    try testing.expect(builder.gates.items.len > 0);
}

test "circuit evaluation" {
    const allocator = testing.allocator;
    
    var world = try World.init(allocator, .{
        .uri = "circuit://test",
        .max_players = 2,
    });
    defer world.deinit();
    
    _ = try world.addPlayer("Player1");
    world.start();
    
    var circuit = try CircuitWorld.init(allocator, world);
    defer circuit.deinit();
    
    try circuit.compile();
    
    const input = CircuitInput{
        .player_inputs = &[_]CircuitInput.PlayerInput{
            .{ .player_id = 0, .action = .move, .data = 10 },
        },
        .parameters = &[_]CircuitInput.Parameter{},
        .seed = 42,
    };
    
    const output = try circuit.evaluate(input);
    defer allocator.free(output.player_results);
    defer allocator.free(output.events);
    
    try testing.expect(output.player_results.len > 0);
}
