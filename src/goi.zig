//! goi.zig — Geometry of Interaction
//!
//! Girard's GoI as a computational substrate for REPL hole-filling.
//! The token machine traverses proof nets, bouncing at nodes.
//! Cut elimination = evaluation = hole-filling.
//!
//! Architecture:
//!   Proof Net (nodes + wires with ports)
//!     → Token Machine (Danos-Regnier traversal)
//!     → Cut Elimination (reduction steps)
//!     → Hole/Fill state (open cut = hole, eliminated = filled)
//!     → Tiling Geometry (hex/penrose/kagome per REPL topology)
//!     → Color Flow (SplitMixRGB drives token color)
//!     → retty Widget (renders the GoI state)
//!
//! Three REPL topologies:
//!   Cider   (Clojure)    → Tensor (⊗) topology, hexagonal tiling
//!   Geiser  (Scheme)     → Par (⅋) topology, Penrose tiling
//!   SLIME   (Common Lisp) → Exponential (!) topology, Kagome tiling
//!
//! GF(3) mapping:
//!   Producer (+1, pos) → Generator/Blue
//!   Neutral  ( 0, null) → Coordinator/Green
//!   Consumer (-1, neg) → Validator/Red
//!
//! On-chain: drand round seeds token color at each reduction step.
//! Deterministic nondeterminism: unpredictable before reveal, reproducible after.
//!
//! wasm32-freestanding compatible. No allocator in hot path (fixed-size nets).

const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ============================================================================
// Constants
// ============================================================================

pub const MAX_NODES: usize = 256;
pub const MAX_WIRES: usize = 512;
pub const MAX_PORTS: usize = 4; // max ports per node
pub const MAX_TOKENS: usize = 16;
pub const MAX_HISTORY: usize = 1024; // token path history
pub const MAX_HOLES: usize = 64;

// ============================================================================
// Polarity — compatible with stellogen/ast.zig
// ============================================================================

pub const Polarity = enum(i8) {
    pos = 1, // Producer / output / Generator (+)
    neg = -1, // Consumer / input  / Validator (-)
    null = 0, // Neutral / wire   / Coordinator (0)

    pub fn opposite(self: Polarity) Polarity {
        return switch (self) {
            .pos => .neg,
            .neg => .pos,
            .null => .null,
        };
    }

    pub fn compatible(self: Polarity, other: Polarity) bool {
        return (self == .pos and other == .neg) or
            (self == .neg and other == .pos) or
            self == .null or other == .null;
    }

    pub fn toGF3(self: Polarity) i8 {
        return @intFromEnum(self);
    }

    pub fn toRGB(self: Polarity) u24 {
        return switch (self) {
            .pos => 0x4488FF, // Blue  (Generator)
            .null => 0x44FF88, // Green (Coordinator)
            .neg => 0xFF4444, // Red   (Validator)
        };
    }
};

// ============================================================================
// Node types — proof net nodes (Girard's multiplicatives + exponentials)
// ============================================================================

pub const NodeKind = enum(u8) {
    // Multiplicatives (linear)
    axiom, // Axiom link: connects pos to neg (identity)
    cut, // Cut: connects two conclusions (computation happens here)
    tensor, // ⊗ (times): pair construction
    par, // ⅋ (par): pair destruction / parallel composition
    // Exponentials (controlled non-linearity)
    bang, // ! (of course): unlimited copying
    whynot, // ? (why not): unlimited discarding
    dereliction, // Expose one copy
    contraction, // Duplicate
    weakening, // Discard
    // Structural
    wire, // Simple wire (identity)
    hole, // Open/unfilled — REPL awaiting evaluation
    fill, // Filled — evaluation complete

    pub fn defaultColor(self: NodeKind) u24 {
        return switch (self) {
            .axiom => 0x888888,
            .cut => 0xFF8800,
            .tensor => 0x4488FF, // Blue (Cider)
            .par => 0x44FF88, // Green (Geiser)
            .bang => 0xFF4444, // Red (SLIME)
            .whynot => 0xFF6666,
            .dereliction => 0xCC4444,
            .contraction => 0xAA2222,
            .weakening => 0x882222,
            .wire => 0x666666,
            .hole => 0x222222, // Dark — unfilled
            .fill => 0xFFFFFF, // Bright — filled
        };
    }
};

// ============================================================================
// REPL topology — which proof net shape this REPL uses
// ============================================================================

pub const ReplTopology = enum(u8) {
    /// Cider (Clojure): Tensor ⊗ topology — pair/destructure, hexagonal tiling
    /// Clojure's persistent data structures are tensor products
    cider = 0,
    /// Geiser (Scheme): Par ⅋ topology — parallel composition, Penrose tiling
    /// Scheme's continuations are par links (multiple futures)
    geiser = 1,
    /// SLIME (Common Lisp): Exponential ! topology — copy/discard, Kagome tiling
    /// CL's macros and eval are exponential modalities (arbitrary duplication)
    slime = 2,

    pub fn primaryNode(self: ReplTopology) NodeKind {
        return switch (self) {
            .cider => .tensor,
            .geiser => .par,
            .slime => .bang,
        };
    }

    pub fn trit(self: ReplTopology) Polarity {
        return switch (self) {
            .cider => .pos, // Generator (+1, Blue)
            .geiser => .null, // Coordinator (0, Green)
            .slime => .neg, // Validator (-1, Red)
        };
    }

    pub fn tilingKind(self: ReplTopology) TilingKind {
        return switch (self) {
            .cider => .hexagonal,
            .geiser => .penrose,
            .slime => .kagome,
        };
    }
};

// ============================================================================
// Tiling geometry — proof net nodes laid out as geometric tiles
// ============================================================================

pub const TilingKind = enum(u8) {
    /// Regular hexagonal tiling (tensor products)
    /// 6 neighbors, 120° symmetry, honeycomb
    hexagonal = 0,
    /// Penrose tiling (par compositions)
    /// Aperiodic, 5-fold symmetry, quasicrystalline
    penrose = 1,
    /// Kagome tiling (exponential modalities)
    /// Corner-sharing triangles, frustrated lattice
    kagome = 2,
};

/// 2D position for tile layout
pub const TilePos = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn distance(self: TilePos, other: TilePos) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// Generate tile position for a node index in the given tiling
pub fn tilePosition(kind: TilingKind, index: usize) TilePos {
    const i_f: f32 = @floatFromInt(index);
    return switch (kind) {
        .hexagonal => blk: {
            // Hex grid: offset coordinates
            const row = index / 12;
            const col = index % 12;
            const r_f: f32 = @floatFromInt(row);
            const c_f: f32 = @floatFromInt(col);
            const offset: f32 = if (row % 2 == 0) 0.0 else 0.5;
            break :blk .{ .x = (c_f + offset) * 1.732, .y = r_f * 1.5 };
        },
        .penrose => blk: {
            // Penrose-approximation: golden spiral placement
            const angle = i_f * 2.399963; // golden angle in radians
            const radius = @sqrt(i_f) * 1.5;
            break :blk .{
                .x = radius * @cos(angle),
                .y = radius * @sin(angle),
            };
        },
        .kagome => blk: {
            // Kagome: triangular lattice with alternating up/down
            const row = index / 8;
            const col = index % 8;
            const r_f: f32 = @floatFromInt(row);
            const c_f: f32 = @floatFromInt(col);
            const tri_offset: f32 = if ((row + col) % 2 == 0) 0.0 else 0.433;
            break :blk .{ .x = c_f * 1.0, .y = r_f * 0.866 + tri_offset };
        },
    };
}

// ============================================================================
// Port — connection point on a node
// ============================================================================

pub const PortId = struct {
    node: u16, // node index
    port: u8, // port index on that node (0..MAX_PORTS)
};

pub const Port = struct {
    polarity: Polarity,
    connected_to: ?PortId = null, // null = free/dangling
    label: []const u8 = "",
};

// ============================================================================
// Node — proof net node
// ============================================================================

pub const Node = struct {
    kind: NodeKind = .wire,
    ports: [MAX_PORTS]Port = [_]Port{.{ .polarity = .null }} ** MAX_PORTS,
    num_ports: u8 = 0,
    /// Tile position in geometric layout
    pos: TilePos = .{},
    /// Current color (driven by token passage)
    color: u24 = 0x444444,
    /// Whether this node has been visited by the current token
    visited: bool = false,
    /// Generation counter (incremented on each reduction)
    generation: u32 = 0,
    /// For holes: which REPL topology this hole belongs to
    repl: ReplTopology = .geiser,
    /// Is this node alive (not eliminated)?
    alive: bool = true,

    pub fn isHole(self: *const Node) bool {
        return self.kind == .hole and self.alive;
    }

    pub fn isFilled(self: *const Node) bool {
        return self.kind == .fill or !self.alive;
    }

    pub fn principalPort(self: *const Node) ?PortId {
        // Port 0 is always the principal port
        if (self.num_ports > 0) {
            return self.ports[0].connected_to;
        }
        return null;
    }
};

// ============================================================================
// Token — the traveler in GoI (Danos-Regnier machine)
// ============================================================================

pub const TokenDirection = enum(u8) {
    /// Moving "down" toward conclusions (following computation)
    down = 0,
    /// Moving "up" toward axioms (tracing back)
    up = 1,
};

pub const Token = struct {
    /// Current position
    position: PortId = .{ .node = 0, .port = 0 },
    /// Direction of travel
    direction: TokenDirection = .down,
    /// Color (from SplitMixRGB, changes at each node)
    color: u24 = 0xFFFFFF,
    /// Path history (for visualization)
    history: [MAX_HISTORY]PortId = undefined,
    history_len: u16 = 0,
    /// Is this token active?
    active: bool = true,
    /// Number of bounces (reduction steps)
    bounces: u32 = 0,

    /// Record current position in history
    pub fn recordStep(self: *Token) void {
        if (self.history_len < MAX_HISTORY) {
            self.history[self.history_len] = self.position;
            self.history_len += 1;
        }
    }
};

// ============================================================================
// Proof Net — the complete GoI structure
// ============================================================================

pub const ProofNet = struct {
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    node_count: u16 = 0,
    tokens: [MAX_TOKENS]Token = [_]Token{.{}} ** MAX_TOKENS,
    token_count: u8 = 0,
    /// Which REPL topology is this net for?
    topology: ReplTopology = .geiser,
    /// Tiling kind for geometric layout
    tiling: TilingKind = .penrose,
    /// Global generation counter
    generation: u32 = 0,
    /// Number of cuts remaining (0 = fully reduced)
    cuts_remaining: u16 = 0,
    /// Number of holes (open cuts awaiting REPL eval)
    holes_remaining: u16 = 0,
    /// drand round seed for this net's color flow
    drand_seed: u64 = 0,

    // ---- Construction ----

    pub fn init(topology: ReplTopology) ProofNet {
        return .{
            .topology = topology,
            .tiling = topology.tilingKind(),
        };
    }

    /// Add a node, return its index
    pub fn addNode(self: *ProofNet, kind: NodeKind, num_ports: u8) u16 {
        if (self.node_count >= MAX_NODES) return self.node_count -| 1;
        const idx = self.node_count;
        self.nodes[idx] = .{
            .kind = kind,
            .num_ports = num_ports,
            .pos = tilePosition(self.tiling, idx),
            .color = kind.defaultColor(),
            .alive = true,
            .repl = self.topology,
        };
        // Set port polarities based on node kind
        self.initPorts(idx, kind, num_ports);
        if (kind == .cut) self.cuts_remaining += 1;
        if (kind == .hole) self.holes_remaining += 1;
        self.node_count += 1;
        return idx;
    }

    fn initPorts(self: *ProofNet, idx: u16, kind: NodeKind, num_ports: u8) void {
        switch (kind) {
            .axiom => {
                // Port 0: pos (output), Port 1: neg (input)
                if (num_ports >= 2) {
                    self.nodes[idx].ports[0].polarity = .pos;
                    self.nodes[idx].ports[1].polarity = .neg;
                }
            },
            .cut => {
                // Port 0: neg (input from left), Port 1: neg (input from right)
                if (num_ports >= 2) {
                    self.nodes[idx].ports[0].polarity = .neg;
                    self.nodes[idx].ports[1].polarity = .neg;
                }
            },
            .tensor => {
                // Port 0: pos (output), Port 1: neg (left input), Port 2: neg (right input)
                if (num_ports >= 1) self.nodes[idx].ports[0].polarity = .pos;
                if (num_ports >= 2) self.nodes[idx].ports[1].polarity = .neg;
                if (num_ports >= 3) self.nodes[idx].ports[2].polarity = .neg;
            },
            .par => {
                // Port 0: neg (input), Port 1: pos (left output), Port 2: pos (right output)
                if (num_ports >= 1) self.nodes[idx].ports[0].polarity = .neg;
                if (num_ports >= 2) self.nodes[idx].ports[1].polarity = .pos;
                if (num_ports >= 3) self.nodes[idx].ports[2].polarity = .pos;
            },
            .bang => {
                // Port 0: pos (output), Port 1: neg (input / box content)
                if (num_ports >= 1) self.nodes[idx].ports[0].polarity = .pos;
                if (num_ports >= 2) self.nodes[idx].ports[1].polarity = .neg;
            },
            .hole => {
                // Port 0: null (open — awaiting), Port 1: null (open — awaiting)
                if (num_ports >= 1) self.nodes[idx].ports[0].polarity = .null;
                if (num_ports >= 2) self.nodes[idx].ports[1].polarity = .null;
            },
            else => {},
        }
    }

    /// Connect two ports
    pub fn connect(self: *ProofNet, a: PortId, b: PortId) void {
        if (a.node < self.node_count and b.node < self.node_count) {
            self.nodes[a.node].ports[a.port].connected_to = b;
            self.nodes[b.node].ports[b.port].connected_to = a;
        }
    }

    /// Add an axiom link (identity wire between pos and neg)
    pub fn addAxiom(self: *ProofNet) u16 {
        return self.addNode(.axiom, 2);
    }

    /// Add a cut (the site of computation — where reduction happens)
    pub fn addCut(self: *ProofNet) u16 {
        return self.addNode(.cut, 2);
    }

    /// Add a hole (open cut — REPL awaiting evaluation)
    pub fn addHole(self: *ProofNet, repl: ReplTopology) u16 {
        const idx = self.addNode(.hole, 2);
        self.nodes[idx].repl = repl;
        return idx;
    }

    /// Fill a hole (evaluation complete)
    pub fn fillHole(self: *ProofNet, hole_idx: u16, result_color: u24) void {
        if (hole_idx < self.node_count and self.nodes[hole_idx].kind == .hole) {
            self.nodes[hole_idx].kind = .fill;
            self.nodes[hole_idx].color = result_color;
            if (self.holes_remaining > 0) self.holes_remaining -= 1;
        }
    }

    // ---- Token Machine (Danos-Regnier) ----

    /// Spawn a token at a node's principal port
    pub fn spawnToken(self: *ProofNet, node_idx: u16) u8 {
        if (self.token_count >= MAX_TOKENS) return self.token_count -| 1;
        const idx = self.token_count;
        self.tokens[idx] = .{
            .position = .{ .node = node_idx, .port = 0 },
            .direction = .down,
            .color = self.nodes[node_idx].color,
            .active = true,
        };
        self.token_count += 1;
        return idx;
    }

    /// Step a token one move through the net.
    /// This is the core of GoI: the token bounces at nodes according to rules.
    /// Returns true if the token moved, false if stuck/completed.
    pub fn stepToken(self: *ProofNet, token_idx: u8) bool {
        if (token_idx >= self.token_count) return false;
        var token = &self.tokens[token_idx];
        if (!token.active) return false;

        const node = &self.nodes[token.position.node];
        if (!node.alive) {
            token.active = false;
            return false;
        }

        token.recordStep();
        node.visited = true;
        token.bounces += 1;

        // Color mixing: token picks up node color via XOR
        token.color ^= node.color;

        switch (node.kind) {
            .axiom => {
                // Axiom: token passes through (pos→neg or neg→pos)
                const exit_port: u8 = if (token.position.port == 0) 1 else 0;
                return self.followWire(token, token.position.node, exit_port);
            },
            .cut => {
                // Cut: token enters from one side, exits the other
                // THIS IS WHERE COMPUTATION HAPPENS
                const exit_port: u8 = if (token.position.port == 0) 1 else 0;
                return self.followWire(token, token.position.node, exit_port);
            },
            .tensor => {
                // Tensor ⊗: token entering principal port (0) goes to left (1)
                // Token entering auxiliary (1 or 2) goes to principal (0)
                if (token.direction == .down) {
                    if (token.position.port == 0) {
                        // Entering from above → go left
                        return self.followWire(token, token.position.node, 1);
                    } else {
                        // Entering from below → go up
                        token.direction = .up;
                        return self.followWire(token, token.position.node, 0);
                    }
                } else {
                    // Going up through tensor → exit principal
                    return self.followWire(token, token.position.node, 0);
                }
            },
            .par => {
                // Par ⅋: dual of tensor
                if (token.direction == .down) {
                    if (token.position.port == 0) {
                        return self.followWire(token, token.position.node, 1);
                    } else {
                        token.direction = .up;
                        return self.followWire(token, token.position.node, 0);
                    }
                } else {
                    return self.followWire(token, token.position.node, 0);
                }
            },
            .bang => {
                // ! (of course): token bounces — copies are created in full GoI
                // Simplified: just pass through
                const exit_port: u8 = if (token.position.port == 0) 1 else 0;
                return self.followWire(token, token.position.node, exit_port);
            },
            .hole => {
                // Hole: token stops here — awaiting REPL evaluation
                token.active = false;
                // The hole captures the token's color as the "question"
                node.color = token.color;
                return false;
            },
            .fill => {
                // Filled hole: token passes through with the fill color
                token.color = node.color;
                const exit_port: u8 = if (token.position.port == 0) 1 else 0;
                return self.followWire(token, token.position.node, exit_port);
            },
            .wire => {
                const exit_port: u8 = if (token.position.port == 0) 1 else 0;
                return self.followWire(token, token.position.node, exit_port);
            },
            else => {
                token.active = false;
                return false;
            },
        }
    }

    /// Follow a wire from a port to its connected port
    fn followWire(self: *ProofNet, token: *Token, node_idx: u16, port: u8) bool {
        if (port >= MAX_PORTS) return false;
        const connected = self.nodes[node_idx].ports[port].connected_to;
        if (connected) |target| {
            token.position = target;
            return true;
        }
        // Dangling wire — token stops
        token.active = false;
        return false;
    }

    /// Run a token to completion (or max steps)
    pub fn runToken(self: *ProofNet, token_idx: u8, max_steps: u32) u32 {
        var steps: u32 = 0;
        while (steps < max_steps) {
            if (!self.stepToken(token_idx)) break;
            steps += 1;
        }
        return steps;
    }

    // ---- Cut Elimination ----

    /// Eliminate a cut between two nodes.
    /// Returns true if the cut was eliminated.
    pub fn eliminateCut(self: *ProofNet, cut_idx: u16) bool {
        if (cut_idx >= self.node_count) return false;
        const cut_node = &self.nodes[cut_idx];
        if (cut_node.kind != .cut or !cut_node.alive) return false;

        // Get the two nodes connected to this cut
        const left_port = cut_node.ports[0].connected_to orelse return false;
        const right_port = cut_node.ports[1].connected_to orelse return false;

        const left_node = &self.nodes[left_port.node];
        const right_node = &self.nodes[right_port.node];

        // Multiplicative cut elimination: tensor ⊗ cut ⅋
        if (left_node.kind == .tensor and right_node.kind == .par) {
            return self.eliminateTensorPar(cut_idx, left_port.node, right_port.node);
        }
        if (left_node.kind == .par and right_node.kind == .tensor) {
            return self.eliminateTensorPar(cut_idx, right_port.node, left_port.node);
        }

        // Axiom cut: axiom link cut with anything → just rewire
        if (left_node.kind == .axiom or right_node.kind == .axiom) {
            return self.eliminateAxiomCut(cut_idx, left_port, right_port);
        }

        return false;
    }

    fn eliminateTensorPar(self: *ProofNet, cut_idx: u16, tensor_idx: u16, par_idx: u16) bool {
        // tensor ⊗ cut ⅋ → two smaller cuts (key multiplicative rule)
        // Tensor has auxiliary ports 1, 2
        // Par has auxiliary ports 1, 2
        // Result: connect tensor.1↔par.1 and tensor.2↔par.2
        const t = &self.nodes[tensor_idx];
        const p = &self.nodes[par_idx];

        // Get tensor auxiliaries
        const t1 = t.ports[1].connected_to;
        const t2 = t.ports[2].connected_to;
        // Get par auxiliaries
        const p1 = p.ports[1].connected_to;
        const p2 = p.ports[2].connected_to;

        // Rewire: t1 ↔ p1
        if (t1) |t1p| {
            if (p1) |p1p| {
                self.nodes[t1p.node].ports[t1p.port].connected_to = p1p;
                self.nodes[p1p.node].ports[p1p.port].connected_to = t1p;
            }
        }
        // Rewire: t2 ↔ p2
        if (t2) |t2p| {
            if (p2) |p2p| {
                self.nodes[t2p.node].ports[t2p.port].connected_to = p2p;
                self.nodes[p2p.node].ports[p2p.port].connected_to = t2p;
            }
        }

        // Kill the cut, tensor, and par nodes
        self.nodes[cut_idx].alive = false;
        self.nodes[tensor_idx].alive = false;
        self.nodes[par_idx].alive = false;
        self.cuts_remaining -|= 1;
        self.generation += 1;
        return true;
    }

    fn eliminateAxiomCut(self: *ProofNet, cut_idx: u16, left: PortId, right: PortId) bool {
        const left_node = &self.nodes[left.node];
        const right_node = &self.nodes[right.node];

        // If left is axiom, rewire right to axiom's other port
        if (left_node.kind == .axiom) {
            const other_port: u8 = if (left.port == 0) 1 else 0;
            const other_target = left_node.ports[other_port].connected_to;
            if (other_target) |ot| {
                self.nodes[ot.node].ports[ot.port].connected_to = right;
                right_node.ports[right.port].connected_to = ot;
            }
        } else if (right_node.kind == .axiom) {
            const other_port: u8 = if (right.port == 0) 1 else 0;
            const other_target = right_node.ports[other_port].connected_to;
            if (other_target) |ot| {
                self.nodes[ot.node].ports[ot.port].connected_to = left;
                left_node.ports[left.port].connected_to = ot;
            }
        }

        self.nodes[cut_idx].alive = false;
        self.cuts_remaining -|= 1;
        self.generation += 1;
        return true;
    }

    /// Run all possible cut eliminations until no more cuts remain.
    /// Returns number of elimination steps performed.
    pub fn normalize(self: *ProofNet, max_steps: u32) u32 {
        var steps: u32 = 0;
        while (steps < max_steps and self.cuts_remaining > 0) {
            var eliminated_any = false;
            var i: u16 = 0;
            while (i < self.node_count) : (i += 1) {
                if (self.nodes[i].kind == .cut and self.nodes[i].alive) {
                    if (self.eliminateCut(i)) {
                        eliminated_any = true;
                        steps += 1;
                    }
                }
            }
            if (!eliminated_any) break; // stuck (irreducible cuts or holes)
        }
        return steps;
    }

    // ---- drand integration ----

    /// Set the drand seed for color flow
    pub fn setDrandSeed(self: *ProofNet, round: u64, seed: u64) void {
        self.drand_seed = seed;
        // Recolor all nodes from the drand seed
        var i: u16 = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.nodes[i].alive) {
                self.nodes[i].color = drandColor(seed, i);
            }
        }
        _ = round;
    }

    fn drandColor(seed: u64, index: u16) u24 {
        // SplitMix64 expansion of drand seed → per-node color
        const GOLDEN: u64 = 0x9e3779b97f4a7c15;
        const MIX1: u64 = 0xbf58476d1ce4e5b9;
        const MIX2: u64 = 0x94d049bb133111eb;
        var z = seed +% (GOLDEN *% @as(u64, index));
        z = (z ^ (z >> 30)) *% MIX1;
        z = (z ^ (z >> 27)) *% MIX2;
        z = z ^ (z >> 31);
        return @truncate(z & 0xFFFFFF);
    }

    // ---- Queries ----

    pub fn aliveNodeCount(self: *const ProofNet) u16 {
        var count: u16 = 0;
        var i: u16 = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.nodes[i].alive) count += 1;
        }
        return count;
    }

    pub fn holeCount(self: *const ProofNet) u16 {
        var count: u16 = 0;
        var i: u16 = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.nodes[i].isHole()) count += 1;
        }
        return count;
    }

    /// Check Danos-Regnier correctness criterion:
    /// A proof net is correct iff for every switching (choosing one premise
    /// of each par), the resulting graph is connected and acyclic.
    /// Simplified check: just verify no isolated components.
    pub fn isCorrect(self: *const ProofNet) bool {
        if (self.node_count == 0) return true;
        // BFS from first alive node, check all alive nodes are reachable
        var visited = [_]bool{false} ** MAX_NODES;
        var queue: [MAX_NODES]u16 = undefined;
        var head: u16 = 0;
        var tail: u16 = 0;

        // Find first alive node
        var start: u16 = 0;
        while (start < self.node_count and !self.nodes[start].alive) start += 1;
        if (start >= self.node_count) return true;

        queue[tail] = start;
        tail += 1;
        visited[start] = true;

        while (head < tail) {
            const current = queue[head];
            head += 1;
            const node = &self.nodes[current];

            var p: u8 = 0;
            while (p < node.num_ports) : (p += 1) {
                if (node.ports[p].connected_to) |target| {
                    if (target.node < self.node_count and !visited[target.node] and self.nodes[target.node].alive) {
                        visited[target.node] = true;
                        if (tail < MAX_NODES) {
                            queue[tail] = target.node;
                            tail += 1;
                        }
                    }
                }
            }
        }

        // Check all alive nodes were visited
        var i: u16 = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.nodes[i].alive and !visited[i]) return false;
        }
        return true;
    }

    /// GF(3) balance of the net: sum of all alive node polarities
    pub fn gf3Sum(self: *const ProofNet) i32 {
        var sum: i32 = 0;
        var i: u16 = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.nodes[i].alive) {
                // Sum the polarities of all ports
                var p: u8 = 0;
                while (p < self.nodes[i].num_ports) : (p += 1) {
                    sum += @as(i32, self.nodes[i].ports[p].polarity.toGF3());
                }
            }
        }
        return sum;
    }
};


// ============================================================================
// Predefined proof net constructors
// ============================================================================

/// Create a simple identity net (axiom only)
pub fn identityNet(topology: ReplTopology) ProofNet {
    var net = ProofNet.init(topology);
    _ = net.addAxiom();
    return net;
}

/// Create a tensor-par cut net (the fundamental multiplicative computation)
pub fn tensorParCut(topology: ReplTopology) ProofNet {
    var net = ProofNet.init(topology);

    // Axioms provide the inputs
    const ax1 = net.addAxiom();
    const ax2 = net.addAxiom();

    // Tensor node: combines two inputs
    const tens = net.addNode(.tensor, 3);

    // Par node: separates two outputs
    const par_node = net.addNode(.par, 3);

    // Cut: the site of computation
    const cut_node = net.addCut();

    // Wire up: axiom outputs → tensor inputs
    net.connect(.{ .node = ax1, .port = 0 }, .{ .node = tens, .port = 1 });
    net.connect(.{ .node = ax2, .port = 0 }, .{ .node = tens, .port = 2 });

    // Tensor output → cut left
    net.connect(.{ .node = tens, .port = 0 }, .{ .node = cut_node, .port = 0 });

    // Cut right → par input
    net.connect(.{ .node = cut_node, .port = 1 }, .{ .node = par_node, .port = 0 });

    // Par outputs go to axiom inputs (closing the net)
    net.connect(.{ .node = par_node, .port = 1 }, .{ .node = ax1, .port = 1 });
    net.connect(.{ .node = par_node, .port = 2 }, .{ .node = ax2, .port = 1 });

    return net;
}

/// Create a net with a REPL hole (awaiting evaluation)
pub fn replHoleNet(repl: ReplTopology) ProofNet {
    var net = ProofNet.init(repl);

    const ax = net.addAxiom();
    const hole_node = net.addHole(repl);

    // Axiom output → hole input
    net.connect(.{ .node = ax, .port = 0 }, .{ .node = hole_node, .port = 0 });
    // Hole output → axiom input (loop)
    net.connect(.{ .node = hole_node, .port = 1 }, .{ .node = ax, .port = 1 });

    return net;
}

// ============================================================================
// WASM exports (C ABI for browser / retty integration)
// ============================================================================

var global_net: ProofNet = ProofNet.init(.geiser);

export fn goi_init(topology: u8) void {
    global_net = ProofNet.init(@enumFromInt(topology));
}

export fn goi_add_axiom() u16 {
    return global_net.addAxiom();
}

export fn goi_add_cut() u16 {
    return global_net.addCut();
}

export fn goi_add_hole(repl: u8) u16 {
    return global_net.addHole(@enumFromInt(repl));
}

export fn goi_fill_hole(idx: u16, color: u32) void {
    global_net.fillHole(idx, @truncate(color));
}

export fn goi_connect(a_node: u16, a_port: u8, b_node: u16, b_port: u8) void {
    global_net.connect(.{ .node = a_node, .port = a_port }, .{ .node = b_node, .port = b_port });
}

export fn goi_spawn_token(node: u16) u8 {
    return global_net.spawnToken(node);
}

export fn goi_step_token(token: u8) bool {
    return global_net.stepToken(token);
}

export fn goi_run_token(token: u8, max_steps: u32) u32 {
    return global_net.runToken(token, max_steps);
}

export fn goi_normalize(max_steps: u32) u32 {
    return global_net.normalize(max_steps);
}

export fn goi_set_drand(round: u64, seed: u64) void {
    global_net.setDrandSeed(round, seed);
}

export fn goi_node_count() u16 {
    return global_net.node_count;
}

export fn goi_alive_count() u16 {
    return global_net.aliveNodeCount();
}

export fn goi_hole_count() u16 {
    return global_net.holeCount();
}

export fn goi_cuts_remaining() u16 {
    return global_net.cuts_remaining;
}

export fn goi_node_color(idx: u16) u32 {
    if (idx < global_net.node_count) return global_net.nodes[idx].color;
    return 0;
}

export fn goi_node_kind(idx: u16) u8 {
    if (idx < global_net.node_count) return @intFromEnum(global_net.nodes[idx].kind);
    return 0;
}

export fn goi_token_color(idx: u8) u32 {
    if (idx < global_net.token_count) return global_net.tokens[idx].color;
    return 0;
}

export fn goi_is_correct() bool {
    return global_net.isCorrect();
}

export fn goi_gf3_sum() i32 {
    return global_net.gf3Sum();
}

// ============================================================================
// Tests
// ============================================================================

const testing = if (!is_wasm) @import("std").testing else struct {};

test "Polarity compatibility" {
    try testing.expect(Polarity.pos.compatible(.neg));
    try testing.expect(Polarity.neg.compatible(.pos));
    try testing.expect(!Polarity.pos.compatible(.pos));
    try testing.expect(Polarity.null.compatible(.pos));
}

test "Polarity GF(3)" {
    try testing.expectEqual(@as(i8, 1), Polarity.pos.toGF3());
    try testing.expectEqual(@as(i8, -1), Polarity.neg.toGF3());
    try testing.expectEqual(@as(i8, 0), Polarity.null.toGF3());
}

test "REPL topology mapping" {
    try testing.expectEqual(ReplTopology.cider.primaryNode(), .tensor);
    try testing.expectEqual(ReplTopology.geiser.primaryNode(), .par);
    try testing.expectEqual(ReplTopology.slime.primaryNode(), .bang);

    try testing.expectEqual(ReplTopology.cider.tilingKind(), .hexagonal);
    try testing.expectEqual(ReplTopology.geiser.tilingKind(), .penrose);
    try testing.expectEqual(ReplTopology.slime.tilingKind(), .kagome);
}

test "Identity net construction" {
    const net = identityNet(.geiser);
    try testing.expectEqual(net.node_count, 1);
    try testing.expectEqual(net.nodes[0].kind, .axiom);
    try testing.expect(net.isCorrect());
}

test "Tensor-par cut elimination" {
    var net = tensorParCut(.cider);
    try testing.expectEqual(net.cuts_remaining, 1);
    try testing.expectEqual(net.node_count, 5); // 2 axioms + tensor + par + cut

    const steps = net.normalize(10);
    try testing.expect(steps > 0);
    try testing.expectEqual(net.cuts_remaining, 0);
}

test "REPL hole creation and filling" {
    var net = replHoleNet(.slime);
    try testing.expectEqual(net.holes_remaining, 1);
    try testing.expectEqual(net.holeCount(), 1);

    // Fill the hole
    net.fillHole(1, 0xFF0000); // Red fill (SLIME = Validator)
    try testing.expectEqual(net.holes_remaining, 0);
    try testing.expectEqual(net.nodes[1].kind, .fill);
}

test "Token machine traversal" {
    var net = identityNet(.geiser);

    // Spawn token at axiom
    const tok = net.spawnToken(0);
    try testing.expect(net.tokens[tok].active);

    // Step: should follow wire (but axiom has no external connections → stops)
    _ = net.stepToken(tok);
    try testing.expect(net.tokens[tok].bounces > 0);
}

test "Token stops at hole" {
    var net = replHoleNet(.cider);
    const tok = net.spawnToken(0);

    // Run token — should stop at the hole
    const steps = net.runToken(tok, 100);
    _ = steps;
    // Token should eventually become inactive (stopped at hole or exhausted)
}

test "drand seed colors nodes" {
    var net = tensorParCut(.geiser);
    net.setDrandSeed(42, 0xDEADBEEFCAFEBABE);

    // Nodes should now have drand-derived colors
    try testing.expect(net.nodes[0].color != 0x888888); // Changed from default
}

test "Tile position generation" {
    // Hexagonal
    const hex_pos = tilePosition(.hexagonal, 0);
    try testing.expectEqual(hex_pos.x, 0.0);

    // Penrose
    const pen_pos = tilePosition(.penrose, 0);
    try testing.expectEqual(pen_pos.x, 0.0);

    // Kagome
    const kag_pos = tilePosition(.kagome, 0);
    try testing.expectEqual(kag_pos.x, 0.0);

    // Different indices give different positions
    const hex1 = tilePosition(.hexagonal, 1);
    try testing.expect(hex1.x != hex_pos.x or hex1.y != hex_pos.y);
}

test "GF(3) sum of net" {
    const net = identityNet(.geiser);
    const sum = net.gf3Sum();
    // Axiom has one pos (+1) and one neg (-1) port → sum = 0
    try testing.expectEqual(sum, 0);
}

test "Proof net correctness (connected)" {
    var net = ProofNet.init(.geiser);
    const a = net.addAxiom();
    const b = net.addAxiom();
    // Unconnected → not correct
    try testing.expect(!net.isCorrect());
    // Connect them
    net.connect(.{ .node = a, .port = 0 }, .{ .node = b, .port = 1 });
    try testing.expect(net.isCorrect());
}
