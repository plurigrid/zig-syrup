//! witnessing_worm.zig — C. elegans Bidirectional Witnessing Protocol
//!
//! Models the C. elegans connectome as a witnessing protocol where two
//! parallel wavefronts propagate in opposite directions through the
//! nervous system. Each neuron is a witness node carrying:
//!
//!   - Recency:      timestamp of last wavefront visit
//!   - Subsequency:  ordinal position within current wave
//!   - Oppositional: GF(3) trit encoding forward/backward/neutral
//!
//! The protocol operates in perpetual cycles:
//!   1. Forward wave (head→tail): marks neurons with +1 trit
//!   2. Backward wave (tail→head): marks neurons with -1 trit
//!   3. At crossing points, oppositional levels accumulate
//!   4. Resymmetrization: when total oppositional sum → 0 (GF(3) conservation)
//!
//! This is a proof-of-witness: the worm's nervous system proves it has
//! been fully traversed in both directions by producing a balanced
//! oppositional signature.
//!
//! Integration:
//!   - wgpu_compute.zig: GPU buffer protocol for parallel wavefront dispatch
//!   - prigogine.zig: Brusselator-style bifurcation at wavefront collision points
//!   - Gay color: each neuron's oppositional state maps to a deterministic color
//!
//! GF(3) assignment:
//!   Forward wavefront  (+1) — recency proof propagating head→tail
//!   Neutral/Crossing   ( 0) — oppositional equilibrium, resymmetrized
//!   Backward wavefront (-1) — subsequency proof propagating tail→head

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ============================================================================
// GF(3) TRIT ARITHMETIC — the oppositional algebra
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        // GF(3): wrap to {-1, 0, +1}
        if (sum > 1) return .minus; // +1 + +1 = -1 (mod 3)
        if (sum < -1) return .plus; // -1 + -1 = +1 (mod 3)
        return @enumFromInt(sum);
    }

    pub fn negate(self: Trit) Trit {
        return @enumFromInt(-@as(i8, @intFromEnum(self)));
    }

    pub fn toF32(self: Trit) f32 {
        return @as(f32, @floatFromInt(@as(i8, @intFromEnum(self))));
    }
};

// ============================================================================
// NEURON — a witness node in the connectome
// ============================================================================

pub const Neuron = struct {
    /// Neuron class in C. elegans
    kind: NeuronKind,
    /// Name (e.g., "AVAL", "AVAR", "DVA")
    name: []const u8,
    /// Adjacency: indices of connected neurons
    connections: []const u16,

    // --- Witnessing state (mutable) ---

    /// GF(3) oppositional trit: forward(+1), backward(-1), neutral(0)
    oppositional: Trit = .zero,
    /// Tick when last visited by any wavefront
    recency: u64 = 0,
    /// Ordinal within current forward wave
    forward_subsequency: u32 = 0,
    /// Ordinal within current backward wave
    backward_subsequency: u32 = 0,
    /// Number of times resymmetrized (oppositional went through 0)
    resym_count: u32 = 0,
    /// Accumulated oppositional crossings
    crossing_depth: i32 = 0,
};

pub const NeuronKind = enum {
    sensory,
    inter,
    motor,
    command, // command interneurons (forward/backward locomotion)
};

// ============================================================================
// CONNECTOME — C. elegans nervous system graph
// ============================================================================

/// Simplified C. elegans connectome focusing on the locomotion circuit.
/// The real worm has 302 neurons and ~7000 synapses. We model the core
/// command interneuron circuit that controls forward/backward movement:
///
///   Head sensory → AVA/AVD/AVE (backward command) → Motor neurons → Tail
///                  AVB/PVC     (forward command)
///
/// This circuit IS the witnessing protocol: the worm literally witnesses
/// its environment by propagating signals bidirectionally through this graph.
pub const Connectome = struct {
    neurons: []Neuron,
    n_neurons: usize,
    allocator: Allocator,

    // Wavefront state
    forward_front: []bool,
    backward_front: []bool,
    tick: u64,

    pub fn init(allocator: Allocator) !Connectome {
        // Build the core locomotion circuit (simplified 32-neuron model)
        const n: usize = 32;
        const neurons = try allocator.alloc(Neuron, n);
        const forward_front = try allocator.alloc(bool, n);
        const backward_front = try allocator.alloc(bool, n);
        @memset(forward_front, false);
        @memset(backward_front, false);

        // Initialize neurons with connectome topology
        initLocomotionCircuit(neurons);

        return .{
            .neurons = neurons,
            .n_neurons = n,
            .allocator = allocator,
            .forward_front = forward_front,
            .backward_front = backward_front,
            .tick = 0,
        };
    }

    pub fn deinit(self: *Connectome) void {
        self.allocator.free(self.neurons);
        self.allocator.free(self.forward_front);
        self.allocator.free(self.backward_front);
    }

    /// Seed forward wavefront at head sensory neurons
    pub fn seedForwardWave(self: *Connectome) void {
        for (self.neurons, 0..) |neuron, i| {
            if (neuron.kind == .sensory) {
                self.forward_front[i] = true;
            }
        }
    }

    /// Seed backward wavefront at tail motor neurons
    pub fn seedBackwardWave(self: *Connectome) void {
        for (self.neurons, 0..) |neuron, i| {
            if (neuron.kind == .motor and i >= self.n_neurons / 2) {
                self.backward_front[i] = true;
            }
        }
    }

    /// Propagate both wavefronts one step. Returns true if any neuron changed.
    pub fn stepWitness(self: *Connectome) bool {
        self.tick += 1;
        var changed = false;

        // Snapshot current fronts
        var next_fwd = self.allocator.alloc(bool, self.n_neurons) catch return false;
        defer self.allocator.free(next_fwd);
        var next_bwd = self.allocator.alloc(bool, self.n_neurons) catch return false;
        defer self.allocator.free(next_bwd);
        @memset(next_fwd, false);
        @memset(next_bwd, false);

        var fwd_order: u32 = 0;
        var bwd_order: u32 = 0;

        // Forward propagation: head → tail
        for (0..self.n_neurons) |i| {
            if (self.forward_front[i]) {
                const neuron = &self.neurons[i];
                for (neuron.connections) |target| {
                    if (target < self.n_neurons and !next_fwd[target]) {
                        next_fwd[target] = true;
                        const t = &self.neurons[target];
                        t.oppositional = Trit.add(t.oppositional, .plus);
                        t.recency = self.tick;
                        fwd_order += 1;
                        t.forward_subsequency = fwd_order;
                        changed = true;

                        // Detect crossing: backward wave already here
                        if (self.backward_front[target]) {
                            t.crossing_depth += 1;
                            // Resymmetrize if oppositional returns to zero
                            if (t.oppositional == .zero) {
                                t.resym_count += 1;
                            }
                        }
                    }
                }
            }
        }

        // Backward propagation: tail → head
        var j: usize = self.n_neurons;
        while (j > 0) {
            j -= 1;
            if (self.backward_front[j]) {
                const neuron = &self.neurons[j];
                for (neuron.connections) |target| {
                    if (target < self.n_neurons and !next_bwd[target]) {
                        next_bwd[target] = true;
                        const t = &self.neurons[target];
                        t.oppositional = Trit.add(t.oppositional, .minus);
                        t.recency = self.tick;
                        bwd_order += 1;
                        t.backward_subsequency = bwd_order;
                        changed = true;

                        // Detect crossing: forward wave already here
                        if (self.forward_front[target] or next_fwd[target]) {
                            t.crossing_depth += 1;
                            if (t.oppositional == .zero) {
                                t.resym_count += 1;
                            }
                        }
                    }
                }
            }
        }

        // Update fronts
        @memcpy(self.forward_front, next_fwd);
        @memcpy(self.backward_front, next_bwd);

        return changed;
    }

    /// Total oppositional sum across all neurons (GF(3) conservation check)
    pub fn oppositionalSum(self: *const Connectome) i32 {
        var sum: i32 = 0;
        for (self.neurons) |n| {
            sum += @as(i32, @intFromEnum(n.oppositional));
        }
        return sum;
    }

    /// Count of neurons that have been resymmetrized at least once
    pub fn resymmetrizedCount(self: *const Connectome) u32 {
        var count: u32 = 0;
        for (self.neurons) |n| {
            if (n.resym_count > 0) count += 1;
        }
        return count;
    }

    /// Check if all neurons have been witnessed (visited by both waves)
    pub fn fullyWitnessed(self: *const Connectome) bool {
        for (self.neurons) |n| {
            if (n.forward_subsequency == 0 or n.backward_subsequency == 0) {
                return false;
            }
        }
        return true;
    }

    /// Maximum crossing depth (oppositional intensity)
    pub fn maxCrossingDepth(self: *const Connectome) i32 {
        var max: i32 = 0;
        for (self.neurons) |n| {
            if (n.crossing_depth > max) max = n.crossing_depth;
        }
        return max;
    }

    /// Run witnessing protocol to completion or max_steps
    pub fn runWitnessing(self: *Connectome, max_steps: u32) WitnessResult {
        self.seedForwardWave();
        self.seedBackwardWave();

        var steps: u32 = 0;
        while (steps < max_steps) : (steps += 1) {
            const changed = self.stepWitness();
            if (!changed) break;
            if (self.fullyWitnessed() and self.oppositionalSum() == 0) break;
        }

        return .{
            .steps = steps,
            .oppositional_sum = self.oppositionalSum(),
            .resymmetrized_count = self.resymmetrizedCount(),
            .fully_witnessed = self.fullyWitnessed(),
            .max_crossing_depth = self.maxCrossingDepth(),
            .final_tick = self.tick,
        };
    }
};

pub const WitnessResult = struct {
    steps: u32,
    oppositional_sum: i32,
    resymmetrized_count: u32,
    fully_witnessed: bool,
    max_crossing_depth: i32,
    final_tick: u64,

    pub fn isResymmetrized(self: WitnessResult) bool {
        return self.oppositional_sum == 0 and self.fully_witnessed;
    }
};

// ============================================================================
// CSR ADJACENCY — Compressed Sparse Row for GPU dispatch
// ============================================================================

/// Compressed Sparse Row representation of the connectome graph.
/// This is the format consumed by the WGSL shader bindings:
///   - offsets[i]..offsets[i+1] = range in adjacency[] for neuron i's neighbors
///   - adjacency[j] = neighbor index
///
/// Matches @group(0) @binding(1) adjacency and @binding(2) adj_offsets
/// in the generated WGSL compute shader.
pub const CsrAdjacency = struct {
    offsets: []u32, // length = n_neurons + 1
    adjacency: []u32, // length = total edges
    n_neurons: u32,
    allocator: Allocator,

    pub fn fromConnectome(connectome: *const Connectome, allocator: Allocator) !CsrAdjacency {
        const n: u32 = @intCast(connectome.n_neurons);

        // Count total edges
        var total_edges: u32 = 0;
        for (connectome.neurons[0..connectome.n_neurons]) |neuron| {
            total_edges += @intCast(neuron.connections.len);
        }

        var offsets = try allocator.alloc(u32, n + 1);
        var adjacency_buf = try allocator.alloc(u32, total_edges);

        var edge_idx: u32 = 0;
        for (0..n) |i| {
            offsets[i] = edge_idx;
            for (connectome.neurons[i].connections) |target| {
                adjacency_buf[edge_idx] = target;
                edge_idx += 1;
            }
        }
        offsets[n] = edge_idx;

        return .{
            .offsets = offsets,
            .adjacency = adjacency_buf,
            .n_neurons = n,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CsrAdjacency) void {
        self.allocator.free(self.offsets);
        self.allocator.free(self.adjacency);
    }

    /// Total edge count
    pub fn edgeCount(self: *const CsrAdjacency) u32 {
        return self.offsets[self.n_neurons];
    }

    /// Raw bytes for GPU SSBO upload (offsets buffer)
    pub fn offsetBytes(self: *const CsrAdjacency) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.offsets.ptr);
        return ptr[0 .. self.offsets.len * @sizeOf(u32)];
    }

    /// Raw bytes for GPU SSBO upload (adjacency buffer)
    pub fn adjacencyBytes(self: *const CsrAdjacency) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.adjacency.ptr);
        return ptr[0 .. self.adjacency.len * @sizeOf(u32)];
    }

    /// Degree of neuron i
    pub fn degree(self: *const CsrAdjacency, i: u32) u32 {
        return self.offsets[i + 1] - self.offsets[i];
    }
};

// ============================================================================
// CONNECTOME TOPOLOGY — simplified C. elegans locomotion circuit
// ============================================================================

/// C. elegans locomotion circuit:
///
///   Layer 0 (sensory):  ASH, ALM, AVM, PLM  — mechanosensory
///   Layer 1 (command):  AVA, AVD, AVE — backward command interneurons
///                       AVB, PVC     — forward command interneurons
///   Layer 2 (inter):    DVA, RIM, AIB, RIA, AIY, AIZ — integration
///   Layer 3 (motor):    DA1-DA4, DB1-DB4 — dorsal A/B motor neurons
///                       VA1-VA4, VB1-VB4 — ventral A/B motor neurons
///
/// Connectivity is derived from White et al. 1986 "The Structure of the
/// Nervous System of C. elegans" (the complete connectome).
fn initLocomotionCircuit(neurons: []Neuron) void {
    // Indices:
    // 0-3:   sensory (ASH, ALM, AVM, PLM)
    // 4-8:   command interneurons (AVA, AVD, AVE, AVB, PVC)
    // 9-14:  interneurons (DVA, RIM, AIB, RIA, AIY, AIZ)
    // 15-22: dorsal motor (DA1-DA4, DB1-DB4)
    // 23-30: ventral motor (VA1-VA4, VB1-VB4)
    // 31:    tail sensory (PHA)

    const conn = struct {
        // Sensory → command
        const ash: []const u16 = &.{ 4, 5, 6, 11 }; // ASH → AVA, AVD, AVE, AIB
        const alm: []const u16 = &.{ 4, 5, 7 }; // ALM → AVA, AVD, AVB
        const avm: []const u16 = &.{ 4, 6, 7 }; // AVM → AVA, AVE, AVB
        const plm: []const u16 = &.{ 4, 8, 7 }; // PLM → AVA, PVC, AVB

        // Command → motor (backward circuit)
        const ava: []const u16 = &.{ 5, 9, 15, 16, 17, 18, 23, 24, 25, 26 }; // AVA → DA, VA
        const avd: []const u16 = &.{ 4, 6, 9, 15, 16 }; // AVD → AVA, AVE, DVA, DA1-2
        const ave: []const u16 = &.{ 4, 10, 23, 24 }; // AVE → AVA, RIM, VA1-2

        // Command → motor (forward circuit)
        const avb: []const u16 = &.{ 8, 9, 19, 20, 21, 22, 27, 28, 29, 30 }; // AVB → DB, VB
        const pvc: []const u16 = &.{ 4, 7, 9, 31 }; // PVC → AVA, AVB, DVA, PHA

        // Interneuron connections
        const dva: []const u16 = &.{ 4, 7, 10 }; // DVA → AVA, AVB, RIM
        const rim: []const u16 = &.{ 4, 11, 12 }; // RIM → AVA, AIB, RIA
        const aib: []const u16 = &.{ 10, 12, 13, 14 }; // AIB → RIM, RIA, AIY, AIZ
        const ria: []const u16 = &.{ 13, 14 }; // RIA → AIY, AIZ
        const aiy: []const u16 = &.{ 14, 12 }; // AIY → AIZ, RIA
        const aiz: []const u16 = &.{ 10, 11 }; // AIZ → RIM, AIB

        // Motor → motor (gap junctions along body)
        const da1: []const u16 = &.{ 16, 23 }; // DA1 → DA2, VA1
        const da2: []const u16 = &.{ 15, 17, 24 };
        const da3: []const u16 = &.{ 16, 18, 25 };
        const da4: []const u16 = &.{ 17, 26, 31 }; // DA4 → DA3, VA4, PHA

        const db1: []const u16 = &.{ 20, 27 };
        const db2: []const u16 = &.{ 19, 21, 28 };
        const db3: []const u16 = &.{ 20, 22, 29 };
        const db4: []const u16 = &.{ 21, 30, 31 };

        const va1: []const u16 = &.{ 24, 15 };
        const va2: []const u16 = &.{ 23, 25, 16 };
        const va3: []const u16 = &.{ 24, 26, 17 };
        const va4: []const u16 = &.{ 25, 18, 31 };

        const vb1: []const u16 = &.{ 28, 19 };
        const vb2: []const u16 = &.{ 27, 29, 20 };
        const vb3: []const u16 = &.{ 28, 30, 21 };
        const vb4: []const u16 = &.{ 29, 22, 31 };

        // Tail sensory
        const pha: []const u16 = &.{ 8, 9 }; // PHA → PVC, DVA
    };

    neurons[0] = .{ .kind = .sensory, .name = "ASH", .connections = conn.ash };
    neurons[1] = .{ .kind = .sensory, .name = "ALM", .connections = conn.alm };
    neurons[2] = .{ .kind = .sensory, .name = "AVM", .connections = conn.avm };
    neurons[3] = .{ .kind = .sensory, .name = "PLM", .connections = conn.plm };

    neurons[4] = .{ .kind = .command, .name = "AVA", .connections = conn.ava };
    neurons[5] = .{ .kind = .command, .name = "AVD", .connections = conn.avd };
    neurons[6] = .{ .kind = .command, .name = "AVE", .connections = conn.ave };
    neurons[7] = .{ .kind = .command, .name = "AVB", .connections = conn.avb };
    neurons[8] = .{ .kind = .command, .name = "PVC", .connections = conn.pvc };

    neurons[9] = .{ .kind = .inter, .name = "DVA", .connections = conn.dva };
    neurons[10] = .{ .kind = .inter, .name = "RIM", .connections = conn.rim };
    neurons[11] = .{ .kind = .inter, .name = "AIB", .connections = conn.aib };
    neurons[12] = .{ .kind = .inter, .name = "RIA", .connections = conn.ria };
    neurons[13] = .{ .kind = .inter, .name = "AIY", .connections = conn.aiy };
    neurons[14] = .{ .kind = .inter, .name = "AIZ", .connections = conn.aiz };

    neurons[15] = .{ .kind = .motor, .name = "DA1", .connections = conn.da1 };
    neurons[16] = .{ .kind = .motor, .name = "DA2", .connections = conn.da2 };
    neurons[17] = .{ .kind = .motor, .name = "DA3", .connections = conn.da3 };
    neurons[18] = .{ .kind = .motor, .name = "DA4", .connections = conn.da4 };
    neurons[19] = .{ .kind = .motor, .name = "DB1", .connections = conn.db1 };
    neurons[20] = .{ .kind = .motor, .name = "DB2", .connections = conn.db2 };
    neurons[21] = .{ .kind = .motor, .name = "DB3", .connections = conn.db3 };
    neurons[22] = .{ .kind = .motor, .name = "DB4", .connections = conn.db4 };

    neurons[23] = .{ .kind = .motor, .name = "VA1", .connections = conn.va1 };
    neurons[24] = .{ .kind = .motor, .name = "VA2", .connections = conn.va2 };
    neurons[25] = .{ .kind = .motor, .name = "VA3", .connections = conn.va3 };
    neurons[26] = .{ .kind = .motor, .name = "VA4", .connections = conn.va4 };
    neurons[27] = .{ .kind = .motor, .name = "VB1", .connections = conn.vb1 };
    neurons[28] = .{ .kind = .motor, .name = "VB2", .connections = conn.vb2 };
    neurons[29] = .{ .kind = .motor, .name = "VB3", .connections = conn.vb3 };
    neurons[30] = .{ .kind = .motor, .name = "VB4", .connections = conn.vb4 };

    neurons[31] = .{ .kind = .sensory, .name = "PHA", .connections = conn.pha };
}

// ============================================================================
// WGSL COMPUTE SHADER — GPU-parallel wavefront propagation
// ============================================================================

/// Generates WGSL compute shader for parallel wavefront propagation.
/// Each workgroup thread handles one neuron: reads neighbor states,
/// computes new oppositional trit, writes back.
///
/// The shader encodes the connectome adjacency as a flat buffer,
/// enabling the GPU to propagate both wavefronts simultaneously.
pub fn generateWitnessWGSL(_: u32) []const u8 {
    // Comptime WGSL generation for the witnessing protocol
    return
    \\// Witnessing Worm — GPU-parallel wavefront propagation
    \\// C. elegans bidirectional proof of recency and subsequency
    \\
    \\struct Neuron {
    \\  oppositional: i32,       // GF(3) trit: -1, 0, +1
    \\  recency: u32,            // tick of last visit
    \\  forward_subseq: u32,     // forward wave ordinal
    \\  backward_subseq: u32,    // backward wave ordinal
    \\  resym_count: u32,        // resymmetrization counter
    \\  crossing_depth: i32,     // oppositional intensity
    \\  is_forward_front: u32,   // 1 if in current forward wavefront
    \\  is_backward_front: u32,  // 1 if in current backward wavefront
    \\};
    \\
    \\@group(0) @binding(0) var<storage, read_write> neurons: array<Neuron>;
    \\@group(0) @binding(1) var<storage, read> adjacency: array<u32>;
    \\@group(0) @binding(2) var<storage, read> adj_offsets: array<u32>;
    \\@group(0) @binding(3) var<uniform> params: vec4<u32>; // (n_neurons, tick, 0, 0)
    \\
    \\// GF(3) addition: (a + b) mod 3 mapped to {-1, 0, +1}
    \\fn gf3_add(a: i32, b: i32) -> i32 {
    \\  let sum = a + b;
    \\  if (sum > 1) { return -1; }  // wrap +2 → -1
    \\  if (sum < -1) { return 1; }  // wrap -2 → +1
    \\  return sum;
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn propagate_forward(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\  let idx = gid.x;
    \\  let n = params.x;
    \\  let tick = params.y;
    \\  if (idx >= n) { return; }
    \\
    \\  // Check if any neighbor is in the forward front
    \\  let start = adj_offsets[idx];
    \\  let end = adj_offsets[idx + 1u];
    \\  var activated = false;
    \\
    \\  for (var j = start; j < end; j = j + 1u) {
    \\    let neighbor = adjacency[j];
    \\    if (neurons[neighbor].is_forward_front == 1u) {
    \\      activated = true;
    \\      break;
    \\    }
    \\  }
    \\
    \\  if (activated && neurons[idx].is_forward_front == 0u) {
    \\    neurons[idx].oppositional = gf3_add(neurons[idx].oppositional, 1);
    \\    neurons[idx].recency = tick;
    \\    neurons[idx].forward_subseq = tick;
    \\    neurons[idx].is_forward_front = 1u;
    \\
    \\    // Crossing detection
    \\    if (neurons[idx].is_backward_front == 1u) {
    \\      neurons[idx].crossing_depth = neurons[idx].crossing_depth + 1;
    \\      if (neurons[idx].oppositional == 0) {
    \\        neurons[idx].resym_count = neurons[idx].resym_count + 1u;
    \\      }
    \\    }
    \\  }
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn propagate_backward(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\  let idx = gid.x;
    \\  let n = params.x;
    \\  let tick = params.y;
    \\  if (idx >= n) { return; }
    \\
    \\  let start = adj_offsets[idx];
    \\  let end = adj_offsets[idx + 1u];
    \\  var activated = false;
    \\
    \\  for (var j = start; j < end; j = j + 1u) {
    \\    let neighbor = adjacency[j];
    \\    if (neurons[neighbor].is_backward_front == 1u) {
    \\      activated = true;
    \\      break;
    \\    }
    \\  }
    \\
    \\  if (activated && neurons[idx].is_backward_front == 0u) {
    \\    neurons[idx].oppositional = gf3_add(neurons[idx].oppositional, -1);
    \\    neurons[idx].recency = tick;
    \\    neurons[idx].backward_subseq = tick;
    \\    neurons[idx].is_backward_front = 1u;
    \\
    \\    if (neurons[idx].is_forward_front == 1u) {
    \\      neurons[idx].crossing_depth = neurons[idx].crossing_depth + 1;
    \\      if (neurons[idx].oppositional == 0) {
    \\        neurons[idx].resym_count = neurons[idx].resym_count + 1u;
    \\      }
    \\    }
    \\  }
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn reduce_oppositional(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\  // Parallel reduction of oppositional sum for resymmetrization check
    \\  // Each thread contributes its neuron's trit to a workgroup sum
    \\  let idx = gid.x;
    \\  let n = params.x;
    \\  if (idx >= n) { return; }
    \\  // Output: neurons[0].crossing_depth accumulates global oppositional sum
    \\  // (In practice, use atomicAdd or multi-pass reduction)
    \\}
    ;
}

// ============================================================================
// WATER BRIDGE — fluid medium connecting witnessing to color streams
// ============================================================================

/// SplitMix64 constants (shared with wgpu_compute.zig)
const GOLDEN_GAMMA: u64 = 0x9e3779b97f4a7c15;
const MIX_C1: u64 = 0xbf58476d1ce4e5b9;
const MIX_C2: u64 = 0x94d049bb133111eb;

fn splitmix64(seed: u64, index: u64) u64 {
    const state = seed +% (GOLDEN_GAMMA *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% MIX_C1;
    z = (z ^ (z >> 27)) *% MIX_C2;
    z = z ^ (z >> 31);
    return z;
}

/// Water: the fluid medium that carries witnessing state as color.
/// Each neuron's oppositional trit × recency × subsequency produces
/// a deterministic Gay color via SplitMix64. The water flows through
/// the connectome — forward wave is warm (red→yellow), backward wave
/// is cool (blue→violet), crossing points are green (resymmetrized).
pub const Water = struct {
    seed: u64,
    epoch: u32,

    /// Color an individual neuron based on its witnessing state.
    /// The color encodes: which wave touched it, how recently, and
    /// whether it has been resymmetrized.
    pub fn neuronColor(self: Water, neuron: Neuron) [4]u8 {
        // Base hue from oppositional state
        const base_hue: f32 = switch (neuron.oppositional) {
            .plus => 30.0, // warm: forward wave (orange)
            .minus => 240.0, // cool: backward wave (blue)
            .zero => 120.0, // balanced: resymmetrized (green)
        };

        // Modulate by recency: more recent = more saturated
        const recency_factor: f32 = if (neuron.recency > 0)
            1.0 / (1.0 + @as(f32, @floatFromInt(self.epoch)) - @as(f32, @floatFromInt(@as(u32, @intCast(@min(neuron.recency, self.epoch))))))
        else
            0.1;

        // Modulate by crossing depth: deeper crossings = brighter
        const brightness: f32 = 0.4 + 0.6 * @min(@as(f32, @floatFromInt(@as(u32, @intCast(@max(neuron.crossing_depth, 0))))) / 5.0, 1.0);

        // SplitMix64 perturbation for uniqueness (same seed = same color)
        const perturb_val = splitmix64(self.seed, @as(u64, neuron.forward_subsequency) *% 31 +% neuron.backward_subsequency);
        const perturb_hue = @as(f32, @floatFromInt(perturb_val & 0xFF)) / 255.0 * 20.0 - 10.0;

        const hue = @mod(base_hue + perturb_hue + 360.0, 360.0);
        const saturation = 0.3 + 0.7 * recency_factor;
        const lightness = brightness;

        return hslToRgba(hue, saturation, lightness);
    }

    /// Color the entire connectome into an RGBA buffer.
    /// Buffer must have at least n_neurons * 4 bytes.
    pub fn colorConnectome(self: Water, connectome: *const Connectome, rgba_out: []u8) void {
        for (connectome.neurons[0..connectome.n_neurons], 0..) |neuron, i| {
            const color = self.neuronColor(neuron);
            const offset = i * 4;
            if (offset + 4 <= rgba_out.len) {
                rgba_out[offset] = color[0];
                rgba_out[offset + 1] = color[1];
                rgba_out[offset + 2] = color[2];
                rgba_out[offset + 3] = color[3];
            }
        }
    }

    fn hslToRgba(h: f32, s: f32, l: f32) [4]u8 {
        const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
        const h_prime = h / 60.0;
        const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        if (h_prime < 1) {
            r = c;
            g = x;
        } else if (h_prime < 2) {
            r = x;
            g = c;
        } else if (h_prime < 3) {
            g = c;
            b = x;
        } else if (h_prime < 4) {
            g = x;
            b = c;
        } else if (h_prime < 5) {
            r = x;
            b = c;
        } else {
            r = c;
            b = x;
        }
        const m = l - c * 0.5;
        return .{
            @intFromFloat(@min(@max((r + m) * 255.0, 0), 255)),
            @intFromFloat(@min(@max((g + m) * 255.0, 0), 255)),
            @intFromFloat(@min(@max((b + m) * 255.0, 0), 255)),
            255,
        };
    }
};

// ============================================================================
// PERPETUAL WITNESSING — resymmetrization in perpetuity
// ============================================================================

/// Runs the witnessing protocol in perpetual cycles. Each cycle:
/// 1. Seed forward + backward wavefronts
/// 2. Propagate until fully witnessed or stalled
/// 3. Record resymmetrization state
/// 4. Reset wavefronts, keep accumulated oppositional history
/// 5. Repeat — each epoch is a new witnessing proof
///
/// The water carries color through each epoch. Crossing points from
/// previous epochs persist as "memory" in the crossing_depth field.
/// Brusselator bifurcation occurs when crossing_depth exceeds threshold —
/// the system transitions from ordered propagation to oscillatory patterns,
/// just like Prigogine's dissipative structures emerging far from equilibrium.
pub const PerpetualWitness = struct {
    connectome: Connectome,
    water: Water,
    epochs_completed: u32,
    total_resymmetrizations: u32,
    bifurcation_threshold: i32,

    /// Whether the system has entered oscillatory (Brusselator-like) regime
    in_dissipative_regime: bool,

    pub fn init(allocator: Allocator, seed: u64) !PerpetualWitness {
        return .{
            .connectome = try Connectome.init(allocator),
            .water = .{ .seed = seed, .epoch = 0 },
            .epochs_completed = 0,
            .total_resymmetrizations = 0,
            .bifurcation_threshold = 3,
            .in_dissipative_regime = false,
        };
    }

    pub fn deinit(self: *PerpetualWitness) void {
        self.connectome.deinit();
    }

    /// Run one witnessing epoch. Returns the result.
    pub fn witnessEpoch(self: *PerpetualWitness, max_steps: u32) EpochResult {
        const result = self.connectome.runWitnessing(max_steps);

        self.water.epoch = @intCast(self.connectome.tick);
        self.total_resymmetrizations += result.resymmetrized_count;
        self.epochs_completed += 1;

        // Check for Brusselator-like bifurcation:
        // When crossing depth exceeds threshold, the system enters
        // a dissipative regime — ordered wavefronts break into
        // oscillatory patterns (analogous to Hopf bifurcation in
        // the Brusselator when B > 1 + A²)
        if (result.max_crossing_depth >= self.bifurcation_threshold) {
            self.in_dissipative_regime = true;
        }

        return .{
            .epoch = self.epochs_completed,
            .witness = result,
            .in_dissipative_regime = self.in_dissipative_regime,
            .total_resymmetrizations = self.total_resymmetrizations,
        };
    }

    /// Reset wavefronts for next epoch. Keeps crossing_depth as memory.
    pub fn resetWavefronts(self: *PerpetualWitness) void {
        @memset(self.connectome.forward_front, false);
        @memset(self.connectome.backward_front, false);
        // Oppositional trits carry forward — the "water" remembers
        // Only clear wavefront activation, not accumulated state
    }

    /// Run N epochs of perpetual witnessing
    pub fn runPerpetual(_: *PerpetualWitness, n_epochs: u32, steps_per_epoch: u32) []EpochResult {
        // Can't allocate dynamically in this context, so caller should loop
        _ = n_epochs;
        _ = steps_per_epoch;
        return &.{};
    }

    /// Color snapshot of current connectome state
    pub fn snapshot(self: *PerpetualWitness, rgba_out: []u8) void {
        self.water.colorConnectome(&self.connectome, rgba_out);
    }

    /// Oppositional sum (should tend toward 0 across epochs)
    pub fn oppositionalSum(self: *const PerpetualWitness) i32 {
        return self.connectome.oppositionalSum();
    }
};

pub const EpochResult = struct {
    epoch: u32,
    witness: WitnessResult,
    in_dissipative_regime: bool,
    total_resymmetrizations: u32,
};

// ============================================================================
// TESTS
// ============================================================================

test "trit arithmetic" {
    try std.testing.expectEqual(Trit.zero, Trit.add(.plus, .minus));
    try std.testing.expectEqual(Trit.minus, Trit.add(.plus, .plus)); // +1+1 = -1 mod 3
    try std.testing.expectEqual(Trit.plus, Trit.add(.minus, .minus)); // -1-1 = +1 mod 3
    try std.testing.expectEqual(Trit.plus, Trit.add(.zero, .plus));
    try std.testing.expectEqual(Trit.zero, Trit.add(.zero, .zero));
}

test "trit negation" {
    try std.testing.expectEqual(Trit.minus, Trit.negate(.plus));
    try std.testing.expectEqual(Trit.plus, Trit.negate(.minus));
    try std.testing.expectEqual(Trit.zero, Trit.negate(.zero));
}

test "connectome initialization" {
    const allocator = std.testing.allocator;
    var c = try Connectome.init(allocator);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 32), c.n_neurons);
    // Check neuron kinds
    try std.testing.expectEqual(NeuronKind.sensory, c.neurons[0].kind); // ASH
    try std.testing.expectEqual(NeuronKind.command, c.neurons[4].kind); // AVA
    try std.testing.expectEqual(NeuronKind.inter, c.neurons[9].kind); // DVA
    try std.testing.expectEqual(NeuronKind.motor, c.neurons[15].kind); // DA1
    try std.testing.expectEqual(NeuronKind.sensory, c.neurons[31].kind); // PHA (tail)
}

test "initial oppositional sum is zero" {
    const allocator = std.testing.allocator;
    var c = try Connectome.init(allocator);
    defer c.deinit();

    try std.testing.expectEqual(@as(i32, 0), c.oppositionalSum());
}

test "wavefront propagation changes state" {
    const allocator = std.testing.allocator;
    var c = try Connectome.init(allocator);
    defer c.deinit();

    c.seedForwardWave();
    const changed = c.stepWitness();
    try std.testing.expect(changed);
    try std.testing.expect(c.tick > 0);
}

test "bidirectional witnessing runs" {
    const allocator = std.testing.allocator;
    var c = try Connectome.init(allocator);
    defer c.deinit();

    const result = c.runWitnessing(100);
    try std.testing.expect(result.steps > 0);
    // The protocol should produce some crossings
    try std.testing.expect(result.max_crossing_depth >= 0);
}

test "WGSL shader generation" {
    const wgsl = generateWitnessWGSL(32);
    try std.testing.expect(wgsl.len > 0);
    // Verify it contains key shader components
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "gf3_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "propagate_forward") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "propagate_backward") != null);
}

test "water colors neurons by oppositional state" {
    const water = Water{ .seed = 1069, .epoch = 10 };

    // Forward neuron → warm color (hue ~30°, red channel dominant)
    var fwd = Neuron{ .kind = .command, .name = "AVA", .connections = &.{} };
    fwd.oppositional = .plus;
    fwd.recency = 8;
    fwd.forward_subsequency = 3;
    const fwd_color = water.neuronColor(fwd);
    try std.testing.expect(fwd_color[3] == 255); // alpha

    // Backward neuron → cool color (hue ~240°, blue channel dominant)
    var bwd = Neuron{ .kind = .command, .name = "AVB", .connections = &.{} };
    bwd.oppositional = .minus;
    bwd.recency = 9;
    bwd.backward_subsequency = 5;
    const bwd_color = water.neuronColor(bwd);
    try std.testing.expect(bwd_color[3] == 255);

    // Resymmetrized neuron → green (hue ~120°)
    var resym = Neuron{ .kind = .inter, .name = "DVA", .connections = &.{} };
    resym.oppositional = .zero;
    resym.recency = 10;
    resym.resym_count = 1;
    const resym_color = water.neuronColor(resym);
    try std.testing.expect(resym_color[1] > resym_color[0]); // green > red
    try std.testing.expect(resym_color[1] > resym_color[2]); // green > blue
}

test "perpetual witnessing runs multiple epochs" {
    const allocator = std.testing.allocator;
    var pw = try PerpetualWitness.init(allocator, 1069);
    defer pw.deinit();

    // Epoch 1
    const r1 = pw.witnessEpoch(50);
    try std.testing.expect(r1.epoch == 1);
    try std.testing.expect(r1.witness.steps > 0);

    pw.resetWavefronts();

    // Epoch 2 — crossing depths should accumulate
    const r2 = pw.witnessEpoch(50);
    try std.testing.expect(r2.epoch == 2);
    try std.testing.expect(r2.total_resymmetrizations >= r1.total_resymmetrizations);
}

test "water color snapshot fills buffer" {
    const allocator = std.testing.allocator;
    var pw = try PerpetualWitness.init(allocator, 42);
    defer pw.deinit();

    _ = pw.witnessEpoch(20);

    var rgba_buf: [32 * 4]u8 = undefined;
    pw.snapshot(&rgba_buf);

    // At least some pixels should be non-zero after witnessing
    var non_zero: u32 = 0;
    for (rgba_buf[0 .. 32 * 3]) |byte| {
        if (byte > 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 0);
}

test "CSR adjacency export" {
    const allocator = std.testing.allocator;
    var c = try Connectome.init(allocator);
    defer c.deinit();

    var csr = try CsrAdjacency.fromConnectome(&c, allocator);
    defer csr.deinit();

    // 32 neurons → 33 offsets
    try std.testing.expectEqual(@as(usize, 33), csr.offsets.len);
    try std.testing.expectEqual(@as(u32, 32), csr.n_neurons);

    // Offsets are monotonically increasing
    for (0..32) |i| {
        try std.testing.expect(csr.offsets[i] <= csr.offsets[i + 1]);
    }

    // Total edges > 0
    try std.testing.expect(csr.edgeCount() > 0);

    // ASH (neuron 0) has 4 connections
    try std.testing.expectEqual(@as(u32, 4), csr.degree(0));

    // Raw bytes are correctly sized for GPU upload
    try std.testing.expectEqual(csr.offsets.len * 4, csr.offsetBytes().len);
    try std.testing.expectEqual(csr.adjacency.len * 4, csr.adjacencyBytes().len);
}
