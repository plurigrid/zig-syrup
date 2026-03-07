//! AGM–Ewig Bridge: Immutable Epistemic History
//!
//! Connects AGM belief revision to Ewig's append-only event log.
//! Every expand/contract/revise gets recorded as a Merkle-hashed event,
//! enabling:
//!   - Time-travel replay of agent's epistemic evolution
//!   - Branching counterfactual reasoning ("what if we'd contracted X?")
//!   - GF(3) conservation auditing across full history
//!   - Isabelle2 postcondition verification from log replay
//!
//! The bridge wraps BeliefSet with Ewig logging, so the agent's internal
//! state remains zero-alloc (stack-only) while the history is safely
//! persisted via the allocator-backed Ewig system.
//!
//! Integration with PufferLib: during vec_step, each env can optionally
//! log to a shared Ewig instance for replay analysis.

const std = @import("std");
const agm = @import("agm.zig");
const ewig = @import("ewig/ewig.zig");

const BeliefSet = agm.BeliefSet;
const Belief = agm.Belief;
const OpKind = agm.OpKind;
const RevisionRecord = agm.RevisionRecord;
const Ewig = ewig.Ewig;
const EventType = ewig.EventType;

/// AGM operation payload for Ewig event logging
pub const AGMPayload = struct {
    op: OpKind,
    prop: u64,
    entrenchment: u8,
    trit: i2,
    generation: u32,
    n_beliefs_before: u8,
    n_beliefs_after: u8,
    trit_sum: i32,
    balanced: bool,

    /// Serialize to compact binary (24 bytes)
    pub fn toBytes(self: AGMPayload) [24]u8 {
        var buf: [24]u8 = undefined;
        buf[0] = @intFromEnum(self.op);
        buf[1] = self.entrenchment;
        buf[2] = @bitCast(@as(i8, @intCast(@as(i32, self.trit))));
        buf[3] = self.n_beliefs_before;
        // prop: bytes 4..11
        std.mem.writeInt(u64, buf[4..12], self.prop, .little);
        // generation: bytes 12..15
        std.mem.writeInt(u32, buf[12..16], self.generation, .little);
        // n_beliefs_after: byte 16
        buf[16] = self.n_beliefs_after;
        // trit_sum: bytes 17..20
        std.mem.writeInt(i32, buf[17..21], self.trit_sum, .little);
        // balanced: byte 21
        buf[21] = if (self.balanced) 1 else 0;
        // padding
        buf[22] = 0;
        buf[23] = 0;
        return buf;
    }

    /// Deserialize from bytes
    pub fn fromBytes(buf: *const [24]u8) AGMPayload {
        return .{
            .op = @enumFromInt(buf[0]),
            .entrenchment = buf[1],
            .trit = @intCast(@as(i8, @bitCast(buf[2]))),
            .n_beliefs_before = buf[3],
            .prop = std.mem.readInt(u64, buf[4..12], .little),
            .generation = std.mem.readInt(u32, buf[12..16], .little),
            .n_beliefs_after = buf[16],
            .trit_sum = std.mem.readInt(i32, buf[17..21], .little),
            .balanced = buf[21] != 0,
        };
    }
};

/// Logged BeliefSet — wraps AGM BeliefSet with Ewig event logging
pub const LoggedBeliefSet = struct {
    /// The underlying belief state (zero-alloc, stack-only)
    beliefs: BeliefSet,
    /// World URI for event tagging
    world_uri: []const u8,
    /// Ewig instance for persistence (nullable for test/embedded use)
    ewig_instance: ?*Ewig,
    /// Allocator for ewig operations
    allocator: std.mem.Allocator,
    /// Stats
    ops_logged: u64,
    ops_failed: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        world_uri: []const u8,
        ewig_instance: ?*Ewig,
    ) LoggedBeliefSet {
        return .{
            .beliefs = BeliefSet.init(),
            .world_uri = world_uri,
            .ewig_instance = ewig_instance,
            .allocator = allocator,
            .ops_logged = 0,
            .ops_failed = 0,
        };
    }

    /// Expand with logging
    pub fn expand(self: *LoggedBeliefSet, prop: u64, ent: u8) void {
        const before = self.beliefs.n_beliefs;
        self.beliefs.expand(prop, ent);
        self.logOp(.expansion, prop, ent, before);
    }

    /// Contract with logging
    pub fn contract(self: *LoggedBeliefSet, prop: u64) u8 {
        const before = self.beliefs.n_beliefs;
        const removed = self.beliefs.contract(prop);
        self.logOp(.contraction, prop, 0, before);
        return removed;
    }

    /// Revise with logging
    pub fn revise(self: *LoggedBeliefSet, prop: u64, ent: u8) void {
        const before = self.beliefs.n_beliefs;
        self.beliefs.revise(prop, ent);
        self.logOp(.revision, prop, ent, before);
    }

    /// Log an operation to Ewig
    fn logOp(self: *LoggedBeliefSet, op: OpKind, prop: u64, ent: u8, before: u8) void {
        const ew = self.ewig_instance orelse return;

        const payload = AGMPayload{
            .op = op,
            .prop = prop,
            .entrenchment = ent,
            .trit = switch (op) {
                .expansion => 1,
                .contraction => -1,
                .revision, .indet_revision => 0,
            },
            .generation = self.beliefs.generation,
            .n_beliefs_before = before,
            .n_beliefs_after = self.beliefs.n_beliefs,
            .trit_sum = self.beliefs.trit_sum,
            .balanced = self.beliefs.isBalanced(),
        };

        const bytes = payload.toBytes();
        _ = ew.append(.StateChanged, self.world_uri, &bytes) catch {
            self.ops_failed += 1;
            return;
        };
        self.ops_logged += 1;
    }

    // Delegate reads to underlying BeliefSet
    pub fn believes(self: *const LoggedBeliefSet, prop: u64) bool {
        return self.beliefs.believes(prop);
    }

    pub fn isBalanced(self: *const LoggedBeliefSet) bool {
        return self.beliefs.isBalanced();
    }

    pub fn gf3Trit(self: *const LoggedBeliefSet) i2 {
        return self.beliefs.gf3Trit();
    }

    pub fn packObs(self: *const LoggedBeliefSet, buf: []u8) usize {
        return self.beliefs.packObs(buf);
    }
};

/// Replay AGM history from Ewig log
pub const AGMReplayer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AGMReplayer {
        return .{ .allocator = allocator };
    }

    /// Replay all AGM events for a world, returning the reconstructed BeliefSet
    pub fn replay(self: *AGMReplayer, ew: *Ewig, world_uri: []const u8) !BeliefSet {
        _ = self;
        var bs = BeliefSet.init();

        // Get timeline for this world
        const tl = ew.timelines.getTimeline(world_uri) orelse return bs;

        // Replay each entry
        for (tl.entries.items) |entry| {
            if (entry.payload.len >= 24) {
                const payload = AGMPayload.fromBytes(entry.payload[0..24]);
                switch (payload.op) {
                    .expansion => bs.expand(payload.prop, payload.entrenchment),
                    .contraction => _ = bs.contract(payload.prop),
                    .revision => bs.revise(payload.prop, payload.entrenchment),
                    .indet_revision => bs.revise(payload.prop, payload.entrenchment),
                }
            }
        }

        return bs;
    }

    /// Verify GF(3) conservation across full history
    pub fn verifyConservation(self: *AGMReplayer, ew: *Ewig, world_uri: []const u8) !bool {
        const bs = try self.replay(ew, world_uri);
        return bs.isBalanced();
    }
};

/// Summary of AGM history for a world
pub const AGMHistorySummary = struct {
    total_ops: u32,
    expansions: u32,
    contractions: u32,
    revisions: u32,
    final_n_beliefs: u8,
    final_trit_sum: i32,
    balanced: bool,
    max_beliefs_seen: u8,
};

/// Extract summary from Ewig log
pub fn summarizeHistory(ew: *Ewig, world_uri: []const u8) AGMHistorySummary {
    var summary = AGMHistorySummary{
        .total_ops = 0,
        .expansions = 0,
        .contractions = 0,
        .revisions = 0,
        .final_n_beliefs = 0,
        .final_trit_sum = 0,
        .balanced = true,
        .max_beliefs_seen = 0,
    };

    const tl = ew.timelines.getTimeline(world_uri) orelse return summary;

    for (tl.entries.items) |entry| {
        if (entry.payload.len >= 24) {
            const payload = AGMPayload.fromBytes(entry.payload[0..24]);
            summary.total_ops += 1;
            switch (payload.op) {
                .expansion => summary.expansions += 1,
                .contraction => summary.contractions += 1,
                .revision, .indet_revision => summary.revisions += 1,
            }
            summary.final_n_beliefs = payload.n_beliefs_after;
            summary.final_trit_sum = payload.trit_sum;
            summary.balanced = payload.balanced;
            if (payload.n_beliefs_after > summary.max_beliefs_seen) {
                summary.max_beliefs_seen = payload.n_beliefs_after;
            }
        }
    }

    return summary;
}

// ============================================================================
// Tests
// ============================================================================

test "AGMPayload round-trip" {
    const payload = AGMPayload{
        .op = .expansion,
        .prop = 0xDEADBEEF,
        .entrenchment = 200,
        .trit = 1,
        .generation = 42,
        .n_beliefs_before = 3,
        .n_beliefs_after = 4,
        .trit_sum = 7,
        .balanced = false,
    };

    const bytes = payload.toBytes();
    const decoded = AGMPayload.fromBytes(&bytes);

    try std.testing.expectEqual(payload.op, decoded.op);
    try std.testing.expectEqual(payload.prop, decoded.prop);
    try std.testing.expectEqual(payload.entrenchment, decoded.entrenchment);
    try std.testing.expectEqual(payload.trit, decoded.trit);
    try std.testing.expectEqual(payload.generation, decoded.generation);
    try std.testing.expectEqual(payload.n_beliefs_before, decoded.n_beliefs_before);
    try std.testing.expectEqual(payload.n_beliefs_after, decoded.n_beliefs_after);
    try std.testing.expectEqual(payload.trit_sum, decoded.trit_sum);
    try std.testing.expectEqual(payload.balanced, decoded.balanced);
}

test "LoggedBeliefSet without Ewig" {
    // Test that logging degrades gracefully when Ewig is null
    var lbs = LoggedBeliefSet.init(std.testing.allocator, "a://test", null);

    lbs.expand(42, 128);
    try std.testing.expect(lbs.believes(42));
    try std.testing.expectEqual(@as(u64, 0), lbs.ops_logged); // no ewig = no logging
    try std.testing.expectEqual(@as(u64, 0), lbs.ops_failed);

    _ = lbs.contract(42);
    try std.testing.expect(!lbs.believes(42));
}

test "LoggedBeliefSet GF(3) conservation" {
    var lbs = LoggedBeliefSet.init(std.testing.allocator, "a://test", null);

    // 3 expansions + 3 contractions = balanced
    lbs.expand(1, 100);
    lbs.expand(2, 100);
    lbs.expand(3, 100);
    _ = lbs.contract(1);
    _ = lbs.contract(2);
    _ = lbs.contract(3);
    try std.testing.expect(lbs.isBalanced());
}
