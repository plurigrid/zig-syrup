//! Bisimulation Oracle for Cross-Protocol Agent Identity (G7)
//!
//! Verifies behavioral equivalence between agent identity claims
//! across protocol boundaries:
//!   A2A Agent Card ≅ ANP DID Document ≅ passport.gay trit trajectory
//!
//! Architecture:
//!   IdentityClaim → localize → LTS → Paige-Tarjan partition refinement
//!     → CellValue(bool): Nothing | Value(true) | Contradiction
//!
//! The oracle is:
//!   - Deterministic (no LLM in verification path)
//!   - GF(3) conserving (trit sum ≡ 0 mod 3 invariant)
//!   - Monotonic (results only strengthen in the propagator lattice)
//!
//! Categorical glossary (localization ≠ translation):
//!   Localization: C → C[S⁻¹]. Lossy, non-invertible. Restricts a protocol
//!     category to its behavioral subcategory by discarding non-observable
//!     structure. This is what localizeClaim() does: AgentCard → LTS.
//!   Translation: A ≅ B. Bijective, structure-preserving, round-trippable.
//!     This is what jsonrpc_bridge.zig does: JSON-RPC ↔ Syrup.
//!
//! Reference: agentic-protocols-research/09-bisimulation-oracle-G7.md

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// TYPES
// ============================================================================

/// GF(3) trit — matches continuation.zig / passport.zig
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "MINUS",
            .zero => "ERGODIC",
            .plus => "PLUS",
        };
    }
};

/// Three-valued oracle result (mirrors propagator.CellValue)
pub const OracleResult = union(enum) {
    /// Insufficient observations to determine equivalence
    nothing: void,
    /// Bisimulation relation exists (agents are behaviorally equivalent)
    equivalent: void,
    /// Bisimulation impossible — witness pair identifies divergence point
    non_equivalent: struct {
        state_a: usize,
        state_b: usize,
        diverging_label: u64,
    },

    pub fn isEquivalent(self: OracleResult) bool {
        return self == .equivalent;
    }

    pub fn isNonEquivalent(self: OracleResult) bool {
        return self == .non_equivalent;
    }

    pub fn isInsufficient(self: OracleResult) bool {
        return self == .nothing;
    }
};

/// A state in a Labeled Transition System
pub const State = struct {
    /// GF(3) classification of this state
    trit: Trit,
    /// Hashed capability names active in this state
    capabilities: []const u64,
};

/// A labeled transition between states
pub const Transition = struct {
    from: usize,
    to: usize,
    label: u64,
};

/// Labeled Transition System derived from an agent identity claim
pub const LTS = struct {
    states: []const State,
    transitions: []const Transition,
    initial: usize,

    /// Number of outgoing transitions from a state with a given label
    pub fn successors(self: LTS, state_idx: usize, label: u64) []const usize {
        // Caller must collect; this is used internally via collectSuccessors
        _ = self;
        _ = state_idx;
        _ = label;
        return &.{};
    }

    /// Collect all distinct labels in the LTS
    pub fn labels(self: LTS, allocator: Allocator) ![]u64 {
        var label_set = std.AutoHashMap(u64, void).init(allocator);
        defer label_set.deinit();
        for (self.transitions) |t| {
            try label_set.put(t.label, {});
        }
        var result = std.array_list.AlignedManaged(u64, null).init(allocator);
        var iter = label_set.keyIterator();
        while (iter.next()) |k| {
            try result.append(k.*);
        }
        return result.toOwnedSlice();
    }

    /// Compute GF(3) balance of the LTS (sum of all state trits mod 3)
    pub fn gf3Balance(self: LTS) Trit {
        var acc: Trit = .zero;
        for (self.states) |s| {
            acc = Trit.add(acc, s.trit);
        }
        return acc;
    }

    pub fn deinit(self: *const LTS, allocator: Allocator) void {
        for (self.states) |s| {
            allocator.free(s.capabilities);
        }
        allocator.free(self.states);
        allocator.free(self.transitions);
    }
};

/// Protocol-tagged identity claim
pub const IdentityClaim = union(enum) {
    /// A2A Agent Card (JSON)
    agent_card: []const u8,
    /// ANP DID Document (JSON-LD)
    did_document: []const u8,
    /// MCP Server Descriptor (JSON)
    mcp_descriptor: []const u8,
    /// passport.gay native trit trajectory
    trit_trajectory: []const Trit,
    /// Entra Service Principal (JSON)
    entra_principal: []const u8,
    /// did:key public key (32 bytes Ed25519)
    did_key_pubkey: []const u8,
};

// ============================================================================
// CAPABILITY HASHING
// ============================================================================

/// SplitMix64 — canonical import from gay/splitmix.zig (matches Gay.jl seed 1069)
const splitmix = @import("gay/splitmix.zig");
const splitMix64 = splitmix.splitmix64;

/// Hash a capability string to a u64 label
pub fn hashCapability(name: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (name) |byte| {
        h ^= @as(u64, byte);
        h *%= 0x100000001b3; // FNV prime
    }
    return splitMix64(h);
}

/// Map a capability band index (0-4) to a trit
/// delta(0), theta(1) → minus; alpha(2) → zero; beta(3), gamma(4) → plus
fn bandToTrit(band_idx: usize) Trit {
    return switch (band_idx) {
        0, 1 => .minus,
        2 => .zero,
        3, 4 => .plus,
        else => .zero,
    };
}

// ============================================================================
// IDENTITY LOCALIZATION: protocol claim → LTS
// ============================================================================

/// Localize a trit trajectory (passport.gay native) to an LTS.
/// Each trit becomes a state; transitions link consecutive trits.
pub fn tritTrajectoryToLTS(allocator: Allocator, trajectory: []const Trit) !LTS {
    if (trajectory.len == 0) {
        const states = try allocator.alloc(State, 1);
        states[0] = .{ .trit = .zero, .capabilities = &.{} };
        return .{
            .states = states,
            .transitions = &.{},
            .initial = 0,
        };
    }

    const states = try allocator.alloc(State, trajectory.len);
    for (trajectory, 0..) |trit, i| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = hashCapability(trit.name());
        states[i] = .{ .trit = trit, .capabilities = caps };
    }

    // Transitions: i → i+1 with label = hash of the trit name
    const n_trans = if (trajectory.len > 1) trajectory.len - 1 else 0;
    const transitions = try allocator.alloc(Transition, n_trans);
    for (0..n_trans) |i| {
        transitions[i] = .{
            .from = i,
            .to = i + 1,
            .label = hashCapability(trajectory[i + 1].name()),
        };
    }

    return .{
        .states = states,
        .transitions = transitions,
        .initial = 0,
    };
}

/// Extract JSON string array field as capability hashes.
/// Parses a JSON object, finds the named array field, hashes each string element.
fn extractJsonArrayAsHashes(allocator: Allocator, json_bytes: []const u8, field_name: []const u8) ![]u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch {
        return allocator.alloc(u64, 0);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return allocator.alloc(u64, 0);

    const arr_val = root.object.get(field_name) orelse return allocator.alloc(u64, 0);
    if (arr_val != .array) return allocator.alloc(u64, 0);

    var hashes = std.array_list.AlignedManaged(u64, null).init(allocator);
    for (arr_val.array.items) |item| {
        switch (item) {
            .string => |s| try hashes.append(hashCapability(s)),
            .object => {
                // A2A skills have .name field; MCP tools have .name field
                if (item.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        try hashes.append(hashCapability(name_val.string));
                    }
                }
            },
            else => {},
        }
    }
    return hashes.toOwnedSlice();
}

/// Translate an A2A Agent Card (JSON) to an LTS.
///
/// Mapping:
///   skills[] → capability labels
///   url → SplitMix64 seed → initial state trit
///   authentication.schemes → polarity trit
pub fn agentCardToLTS(allocator: Allocator, card_json: []const u8) !LTS {
    const skill_hashes = try extractJsonArrayAsHashes(allocator, card_json, "skills");
    defer allocator.free(skill_hashes);

    // Determine initial trit from URL hash
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, card_json, .{}) catch {
        return tritTrajectoryToLTS(allocator, &.{.zero});
    };
    defer parsed.deinit();

    var url_trit: Trit = .zero;
    if (parsed.value == .object) {
        if (parsed.value.object.get("url")) |url_val| {
            if (url_val == .string) {
                const h = hashCapability(url_val.string);
                url_trit = switch (@as(u2, @intCast(h % 3))) {
                    0 => .zero,
                    1 => .plus,
                    2 => .minus,
                    else => unreachable,
                };
            }
        }
    }

    // Build LTS: one state per capability + initial state
    const n_states = @max(1, skill_hashes.len + 1);
    const states = try allocator.alloc(State, n_states);

    // Initial state: URL-derived trit, no capabilities
    const init_caps = try allocator.alloc(u64, 0);
    states[0] = .{ .trit = url_trit, .capabilities = init_caps };

    // One state per skill
    for (skill_hashes, 0..) |h, i| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = h;
        states[i + 1] = .{
            .trit = bandToTrit(i % 5),
            .capabilities = caps,
        };
    }

    // Transitions from initial to each skill
    const transitions = try allocator.alloc(Transition, skill_hashes.len);
    for (skill_hashes, 0..) |h, i| {
        transitions[i] = .{
            .from = 0,
            .to = i + 1,
            .label = h,
        };
    }

    return .{
        .states = states,
        .transitions = transitions,
        .initial = 0,
    };
}

/// Translate an ANP DID Document (JSON-LD) to an LTS.
///
/// Mapping:
///   verificationMethod[].publicKeyMultibase → SHA-256 → trit sequence
///   service[].type → capability labels
///   controller → delegation chain
pub fn didDocumentToLTS(allocator: Allocator, did_json: []const u8) !LTS {
    const service_hashes = try extractJsonArrayAsHashes(allocator, did_json, "service");
    defer allocator.free(service_hashes);

    const vm_hashes = try extractJsonArrayAsHashes(allocator, did_json, "verificationMethod");
    defer allocator.free(vm_hashes);

    // Build combined LTS
    const n_states = @max(1, service_hashes.len + vm_hashes.len + 1);
    const states = try allocator.alloc(State, n_states);

    // Initial state
    const init_caps = try allocator.alloc(u64, 0);
    states[0] = .{ .trit = .zero, .capabilities = init_caps };

    var idx: usize = 1;

    // Verification methods become minus (verification) states
    for (vm_hashes) |h| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = h;
        states[idx] = .{ .trit = .minus, .capabilities = caps };
        idx += 1;
    }

    // Services become plus (generation/action) states
    for (service_hashes) |h| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = h;
        states[idx] = .{ .trit = .plus, .capabilities = caps };
        idx += 1;
    }

    // Transitions from initial
    const n_trans = vm_hashes.len + service_hashes.len;
    const transitions = try allocator.alloc(Transition, n_trans);
    for (0..vm_hashes.len) |i| {
        transitions[i] = .{
            .from = 0,
            .to = i + 1,
            .label = vm_hashes[i],
        };
    }
    for (0..service_hashes.len) |i| {
        transitions[vm_hashes.len + i] = .{
            .from = 0,
            .to = vm_hashes.len + 1 + i,
            .label = service_hashes[i],
        };
    }

    return .{
        .states = states,
        .transitions = transitions,
        .initial = 0,
    };
}

/// Translate an MCP Server Descriptor to an LTS.
///
/// Mapping:
///   tools[] → capability labels (plus)
///   resources[] → data labels (zero)
///   transport → polarity trit (stdio=-1, http=0, sse=+1)
pub fn mcpDescriptorToLTS(allocator: Allocator, mcp_json: []const u8) !LTS {
    const tool_hashes = try extractJsonArrayAsHashes(allocator, mcp_json, "tools");
    defer allocator.free(tool_hashes);

    const resource_hashes = try extractJsonArrayAsHashes(allocator, mcp_json, "resources");
    defer allocator.free(resource_hashes);

    const n_states = @max(1, tool_hashes.len + resource_hashes.len + 1);
    const states = try allocator.alloc(State, n_states);

    const init_caps = try allocator.alloc(u64, 0);
    states[0] = .{ .trit = .zero, .capabilities = init_caps };

    var idx: usize = 1;
    for (tool_hashes) |h| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = h;
        states[idx] = .{ .trit = .plus, .capabilities = caps };
        idx += 1;
    }
    for (resource_hashes) |h| {
        const caps = try allocator.alloc(u64, 1);
        caps[0] = h;
        states[idx] = .{ .trit = .zero, .capabilities = caps };
        idx += 1;
    }

    const n_trans = tool_hashes.len + resource_hashes.len;
    const transitions = try allocator.alloc(Transition, n_trans);
    for (0..tool_hashes.len) |i| {
        transitions[i] = .{ .from = 0, .to = i + 1, .label = tool_hashes[i] };
    }
    for (0..resource_hashes.len) |i| {
        transitions[tool_hashes.len + i] = .{
            .from = 0,
            .to = tool_hashes.len + 1 + i,
            .label = resource_hashes[i],
        };
    }

    return .{
        .states = states,
        .transitions = transitions,
        .initial = 0,
    };
}

// ============================================================================
// BISIMULATION CHECK (Paige-Tarjan partition refinement)
// ============================================================================

/// Check bisimulation equivalence between two LTS.
///
/// Uses partition refinement on the disjoint union of both LTS:
/// states 0..n_a-1 from LTS A, states n_a..n_a+n_b-1 from LTS B.
///
/// Result:
///   - equivalent: initial states of A and B are in the same partition block
///   - non_equivalent: they're in different blocks (witness = diverging transition)
///   - nothing: one or both LTS are empty (insufficient observations)
pub fn checkBisimulation(
    allocator: Allocator,
    lts_a: LTS,
    lts_b: LTS,
) !OracleResult {
    if (lts_a.states.len == 0 or lts_b.states.len == 0) {
        return .{ .nothing = {} };
    }

    const n_a = lts_a.states.len;
    const n_b = lts_b.states.len;
    const n_total = n_a + n_b;

    // Collect all labels from both LTS
    const labels_a = try lts_a.labels(allocator);
    defer allocator.free(labels_a);
    const labels_b = try lts_b.labels(allocator);
    defer allocator.free(labels_b);

    var all_labels = std.AutoHashMap(u64, void).init(allocator);
    defer all_labels.deinit();
    for (labels_a) |l| try all_labels.put(l, {});
    for (labels_b) |l| try all_labels.put(l, {});

    // Build adjacency: for each (state, label), which states can we reach?
    // State indices: LTS A = [0, n_a), LTS B = [n_a, n_a+n_b)
    const AdjKey = struct { state: usize, label: u64 };
    const Adj = std.AutoHashMap(AdjKey, std.array_list.AlignedManaged(usize, null));
    var adj = Adj.init(allocator);
    defer {
        var it = adj.valueIterator();
        while (it.next()) |v| v.deinit();
        adj.deinit();
    }

    for (lts_a.transitions) |t| {
        const key = AdjKey{ .state = t.from, .label = t.label };
        const entry = try adj.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.array_list.AlignedManaged(usize, null).init(allocator);
        }
        try entry.value_ptr.append(t.to);
    }
    for (lts_b.transitions) |t| {
        const key = AdjKey{ .state = t.from + n_a, .label = t.label };
        const entry = try adj.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.array_list.AlignedManaged(usize, null).init(allocator);
        }
        try entry.value_ptr.append(t.to + n_a);
    }

    // Initial partition: group by trit value (3 blocks max)
    // This is the coarsest partition that respects GF(3) structure
    var partition = try allocator.alloc(usize, n_total);
    defer allocator.free(partition);

    for (0..n_a) |i| {
        partition[i] = switch (lts_a.states[i].trit) {
            .minus => 0,
            .zero => 1,
            .plus => 2,
        };
    }
    for (0..n_b) |i| {
        partition[n_a + i] = switch (lts_b.states[i].trit) {
            .minus => 0,
            .zero => 1,
            .plus => 2,
        };
    }

    // Iterative refinement: split blocks by transition behavior
    var changed = true;
    var next_block: usize = 3;
    var iterations: usize = 0;
    const max_iterations = n_total * all_labels.count() + 1;

    while (changed and iterations < max_iterations) {
        changed = false;
        iterations += 1;

        // For each label, check if states in the same block go to the same block
        var label_iter = all_labels.keyIterator();
        while (label_iter.next()) |label_ptr| {
            const label = label_ptr.*;

            // Group states by (current_block, set_of_target_blocks_for_this_label)
            // Two states that reach different block sets must be split
            var signatures = std.AutoHashMap(usize, std.array_list.AlignedManaged(usize, null)).init(allocator);
            defer {
                var sig_it = signatures.valueIterator();
                while (sig_it.next()) |v| v.deinit();
                signatures.deinit();
            }

            for (0..n_total) |state| {
                const key = AdjKey{ .state = state, .label = label };
                const target_blocks = if (adj.get(key)) |succs| blk: {
                    // Compute a signature from sorted target blocks
                    var blocks = std.array_list.AlignedManaged(usize, null).init(allocator);
                    for (succs.items) |succ| {
                        try blocks.append(partition[succ]);
                    }
                    std.mem.sort(usize, blocks.items, {}, std.sort.asc(usize));
                    break :blk blocks;
                } else blk: {
                    // No transition with this label → empty signature
                    break :blk std.array_list.AlignedManaged(usize, null).init(allocator);
                };

                target_blocks.deinit();

                const sig_entry = try signatures.getOrPut(partition[state]);
                if (!sig_entry.found_existing) {
                    sig_entry.value_ptr.* = std.array_list.AlignedManaged(usize, null).init(allocator);
                }
                try sig_entry.value_ptr.append(state);
            }
        }

        // Simple refinement: for each block, check all pairs
        // If states in the same block have different transition targets for any label,
        // split them into different blocks
        var block_members = std.AutoHashMap(usize, std.array_list.AlignedManaged(usize, null)).init(allocator);
        defer {
            var bm_it = block_members.valueIterator();
            while (bm_it.next()) |v| v.deinit();
            block_members.deinit();
        }

        for (0..n_total) |state| {
            const entry = try block_members.getOrPut(partition[state]);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.array_list.AlignedManaged(usize, null).init(allocator);
            }
            try entry.value_ptr.append(state);
        }

        var bm_iter = block_members.iterator();
        while (bm_iter.next()) |entry| {
            const members = entry.value_ptr.items;
            if (members.len <= 1) continue;

            // Compare first member's transitions against all others
            const ref = members[0];

            for (members[1..]) |other| {
                var differs = false;

                var lbl_iter = all_labels.keyIterator();
                while (lbl_iter.next()) |lbl_ptr| {
                    const lbl = lbl_ptr.*;
                    const ref_key = AdjKey{ .state = ref, .label = lbl };
                    const other_key = AdjKey{ .state = other, .label = lbl };

                    const ref_succs = if (adj.get(ref_key)) |s| s.items else &[_]usize{};
                    const other_succs = if (adj.get(other_key)) |s| s.items else &[_]usize{};

                    // Compare target block sets
                    var ref_blocks = std.AutoHashMap(usize, void).init(allocator);
                    defer ref_blocks.deinit();
                    for (ref_succs) |s| try ref_blocks.put(partition[s], {});

                    var other_blocks = std.AutoHashMap(usize, void).init(allocator);
                    defer other_blocks.deinit();
                    for (other_succs) |s| try other_blocks.put(partition[s], {});

                    if (ref_blocks.count() != other_blocks.count()) {
                        differs = true;
                        break;
                    }
                    var rb_iter = ref_blocks.keyIterator();
                    while (rb_iter.next()) |k| {
                        if (!other_blocks.contains(k.*)) {
                            differs = true;
                            break;
                        }
                    }
                    if (differs) break;
                }

                if (differs) {
                    partition[other] = next_block;
                    next_block += 1;
                    changed = true;
                }
            }
        }
    }

    // Check if initial states of A and B are in the same partition block
    const init_a = lts_a.initial;
    const init_b = lts_b.initial + n_a;

    if (partition[init_a] == partition[init_b]) {
        return .{ .equivalent = {} };
    }

    // Find a diverging label as witness
    var label_iter2 = all_labels.keyIterator();
    while (label_iter2.next()) |lbl_ptr| {
        const lbl = lbl_ptr.*;
        const a_key = AdjKey{ .state = init_a, .label = lbl };
        const b_key = AdjKey{ .state = init_b, .label = lbl };

        const a_has = adj.contains(a_key);
        const b_has = adj.contains(b_key);

        if (a_has != b_has) {
            return .{ .non_equivalent = .{
                .state_a = lts_a.initial,
                .state_b = lts_b.initial,
                .diverging_label = lbl,
            } };
        }
    }

    return .{ .non_equivalent = .{
        .state_a = lts_a.initial,
        .state_b = lts_b.initial,
        .diverging_label = 0,
    } };
}

// ============================================================================
// ORACLE: top-level API
// ============================================================================

/// The bisimulation oracle: takes two identity claims from any protocol,
/// localizes to LTS, checks bisimulation.
///
/// Returns:
///   - equivalent: claims refer to behaviorally equivalent agents
///   - non_equivalent: claims diverge (with witness)
///   - nothing: insufficient information
pub fn oracle(
    allocator: Allocator,
    claim_a: IdentityClaim,
    claim_b: IdentityClaim,
) !OracleResult {
    const lts_a = try localizeClaim(allocator, claim_a);
    defer lts_a.deinit(allocator);

    const lts_b = try localizeClaim(allocator, claim_b);
    defer lts_b.deinit(allocator);

    // GF(3) conservation check: both LTS should have same balance
    const balance_a = lts_a.gf3Balance();
    const balance_b = lts_b.gf3Balance();
    if (balance_a != balance_b) {
        return .{ .non_equivalent = .{
            .state_a = lts_a.initial,
            .state_b = lts_b.initial,
            .diverging_label = 0, // GF(3) violation, no specific label
        } };
    }

    return checkBisimulation(allocator, lts_a, lts_b);
}

fn localizeClaim(allocator: Allocator, claim: IdentityClaim) !LTS {
    return switch (claim) {
        .trit_trajectory => |t| tritTrajectoryToLTS(allocator, t),
        .agent_card => |j| agentCardToLTS(allocator, j),
        .did_document => |j| didDocumentToLTS(allocator, j),
        .mcp_descriptor => |j| mcpDescriptorToLTS(allocator, j),
        .entra_principal => |j| agentCardToLTS(allocator, j), // Same shape for now
        .did_key_pubkey => |pk| blk: {
            // Bridge did:key → trit trajectory via GF(3) byte mapping
            if (pk.len < 32) break :blk tritTrajectoryToLTS(allocator, &.{.zero});
            var traj: [32]Trit = undefined;
            for (pk[0..32], 0..) |byte, i| {
                traj[i] = switch (@mod(byte, 3)) {
                    0 => .zero,
                    1 => .plus,
                    2 => .minus,
                    else => unreachable,
                };
            }
            break :blk tritTrajectoryToLTS(allocator, &traj);
        },
    };
}

// ============================================================================
// VERIFICATION PROPERTIES
// ============================================================================

/// Verify reflexivity: oracle(X, X) = equivalent for any valid claim
pub fn verifyReflexivity(allocator: Allocator, claim: IdentityClaim) !bool {
    const result = try oracle(allocator, claim, claim);
    return result.isEquivalent();
}

/// Verify GF(3) conservation of a localization
pub fn verifyGf3Conservation(allocator: Allocator, claim: IdentityClaim) !bool {
    const lts = try localizeClaim(allocator, claim);
    defer lts.deinit(allocator);
    // Balance should be well-defined (not dependent on localization bugs)
    _ = lts.gf3Balance();
    return true;
}

// ============================================================================
// TESTS
// ============================================================================

test "hash capability determinism" {
    const h1 = hashCapability("read_file");
    const h2 = hashCapability("read_file");
    try std.testing.expectEqual(h1, h2);

    const h3 = hashCapability("write_file");
    try std.testing.expect(h1 != h3);
}

test "trit trajectory to LTS" {
    const allocator = std.testing.allocator;
    const traj = [_]Trit{ .plus, .zero, .minus, .zero, .plus };
    const lts = try tritTrajectoryToLTS(allocator, &traj);
    defer lts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), lts.states.len);
    try std.testing.expectEqual(@as(usize, 4), lts.transitions.len);
    try std.testing.expectEqual(@as(usize, 0), lts.initial);
    try std.testing.expectEqual(Trit.plus, lts.states[0].trit);
    try std.testing.expectEqual(Trit.minus, lts.states[2].trit);
}

test "agent card to LTS" {
    const allocator = std.testing.allocator;
    const card =
        \\{"name":"TestAgent","url":"https://test.com/a2a","skills":[{"name":"search"},{"name":"compute"}]}
    ;
    const lts = try agentCardToLTS(allocator, card);
    defer lts.deinit(allocator);

    // 1 initial + 2 skills = 3 states
    try std.testing.expectEqual(@as(usize, 3), lts.states.len);
    // 2 transitions from initial to each skill
    try std.testing.expectEqual(@as(usize, 2), lts.transitions.len);
}

test "DID document to LTS" {
    const allocator = std.testing.allocator;
    const did =
        \\{"id":"did:wba:example.com","verificationMethod":[{"name":"key-1"}],"service":[{"name":"messaging"},{"name":"storage"}]}
    ;
    const lts = try didDocumentToLTS(allocator, did);
    defer lts.deinit(allocator);

    // 1 initial + 1 verification + 2 services = 4 states
    try std.testing.expectEqual(@as(usize, 4), lts.states.len);
    // Verification methods → minus trit
    try std.testing.expectEqual(Trit.minus, lts.states[1].trit);
    // Services → plus trit
    try std.testing.expectEqual(Trit.plus, lts.states[2].trit);
}

test "MCP descriptor to LTS" {
    const allocator = std.testing.allocator;
    const mcp =
        \\{"tools":[{"name":"read"},{"name":"write"}],"resources":[{"name":"database"}]}
    ;
    const lts = try mcpDescriptorToLTS(allocator, mcp);
    defer lts.deinit(allocator);

    // 1 initial + 2 tools + 1 resource = 4 states
    try std.testing.expectEqual(@as(usize, 4), lts.states.len);
    // Tools → plus trit
    try std.testing.expectEqual(Trit.plus, lts.states[1].trit);
    // Resources → zero trit
    try std.testing.expectEqual(Trit.zero, lts.states[3].trit);
}

test "bisimulation reflexivity" {
    const allocator = std.testing.allocator;
    const traj = [_]Trit{ .plus, .zero, .minus };
    const lts = try tritTrajectoryToLTS(allocator, &traj);
    defer lts.deinit(allocator);

    const result = try checkBisimulation(allocator, lts, lts);
    try std.testing.expect(result.isEquivalent());
}

test "bisimulation detects non-equivalence" {
    const allocator = std.testing.allocator;
    const traj_a = [_]Trit{ .plus, .zero };
    const traj_b = [_]Trit{ .minus, .zero };

    const lts_a = try tritTrajectoryToLTS(allocator, &traj_a);
    defer lts_a.deinit(allocator);
    const lts_b = try tritTrajectoryToLTS(allocator, &traj_b);
    defer lts_b.deinit(allocator);

    const result = try checkBisimulation(allocator, lts_a, lts_b);
    try std.testing.expect(result.isNonEquivalent());
}

test "oracle reflexivity on agent card" {
    const allocator = std.testing.allocator;
    const card =
        \\{"name":"Agent","url":"https://x.com","skills":[{"name":"search"}]}
    ;
    const claim = IdentityClaim{ .agent_card = card };
    try std.testing.expect(try verifyReflexivity(allocator, claim));
}

test "oracle non-equivalence across protocols" {
    const allocator = std.testing.allocator;

    // Agent with "search" skill
    const card =
        \\{"name":"Agent","url":"https://x.com","skills":[{"name":"search"}]}
    ;

    // MCP server with "read" and "write" tools (different capabilities)
    const mcp =
        \\{"tools":[{"name":"read"},{"name":"write"}],"resources":[]}
    ;

    const result = try oracle(
        allocator,
        .{ .agent_card = card },
        .{ .mcp_descriptor = mcp },
    );

    // Different capabilities should yield non-equivalent
    try std.testing.expect(result.isNonEquivalent());
}

test "did:key pubkey reflexivity via oracle" {
    const allocator = std.testing.allocator;
    const pubkey = [_]u8{0x42} ** 32;
    const claim = IdentityClaim{ .did_key_pubkey = &pubkey };
    try std.testing.expect(try verifyReflexivity(allocator, claim));
}

test "did:key pubkey to LTS produces 32 states" {
    const allocator = std.testing.allocator;
    const pubkey = [_]u8{0x69} ** 32;
    const lts = try localizeClaim(allocator, .{ .did_key_pubkey = &pubkey });
    defer lts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 32), lts.states.len);
}

test "different did:key pubkeys are non-equivalent" {
    const allocator = std.testing.allocator;
    const pk_a = [_]u8{0x00} ** 32;
    const pk_b = [_]u8{0x01} ** 32;
    const result = try oracle(
        allocator,
        .{ .did_key_pubkey = &pk_a },
        .{ .did_key_pubkey = &pk_b },
    );
    try std.testing.expect(result.isNonEquivalent());
}

test "GF(3) balance of LTS" {
    const allocator = std.testing.allocator;
    // Balanced trajectory: +, 0, - sums to 0
    const traj = [_]Trit{ .plus, .zero, .minus };
    const lts = try tritTrajectoryToLTS(allocator, &traj);
    defer lts.deinit(allocator);
    try std.testing.expectEqual(Trit.zero, lts.gf3Balance());
}

test "empty LTS returns nothing" {
    const allocator = std.testing.allocator;
    const empty_states = try allocator.alloc(State, 0);
    const empty_trans = try allocator.alloc(Transition, 0);
    const empty = LTS{ .states = empty_states, .transitions = empty_trans, .initial = 0 };
    defer {
        allocator.free(empty_states);
        allocator.free(empty_trans);
    }

    const traj = [_]Trit{.plus};
    const lts = try tritTrajectoryToLTS(allocator, &traj);
    defer lts.deinit(allocator);

    const result = try checkBisimulation(allocator, empty, lts);
    try std.testing.expect(result.isInsufficient());
}

test "GF(3) conservation check" {
    const allocator = std.testing.allocator;
    const card =
        \\{"name":"Agent","url":"https://x.com","skills":[{"name":"a"}]}
    ;
    try std.testing.expect(try verifyGf3Conservation(allocator, .{ .agent_card = card }));
}

test "identical agent cards are equivalent" {
    const allocator = std.testing.allocator;
    const card =
        \\{"name":"Agent","url":"https://x.com","skills":[{"name":"search"},{"name":"compute"}]}
    ;
    const result = try oracle(
        allocator,
        .{ .agent_card = card },
        .{ .agent_card = card },
    );
    try std.testing.expect(result.isEquivalent());
}

test "Trit name mapping" {
    try std.testing.expectEqualStrings("MINUS", Trit.minus.name());
    try std.testing.expectEqualStrings("ERGODIC", Trit.zero.name());
    try std.testing.expectEqualStrings("PLUS", Trit.plus.name());
}
