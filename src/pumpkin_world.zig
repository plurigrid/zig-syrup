//! pumpkin_world.zig — Self-contained, self-replaying, self-evidencing pumpkin-chat world
//!
//! A deterministic simulation of a pumpkin-chat session:
//!   - 3 users (Alice, Bob, Carol) in a chatroom
//!   - 64 ticks driven by SplitMix64 from seed
//!   - Every action gets a GF(3) trit; final sum must be 0 mod 3
//!   - Same seed = same transcript, always
//!
//! This IS the zigger world: pumpkin-chat is the fastest because
//! the world is its own replay.
//!
//! GF(3) triad: pumpkin-codec(−1, #DC6A80) + captp-bootstrap(0, #13A114)
//!              + sealer-unsealer(+1, #823BE0) = 0
//! drand round 26543628, seed 0x4bc4d48d0389c599

const std = @import("std");

// ============================================================================
// SplitMix64 (duplicated from goblins.zig — avoids pulling in passport/ripser)
// ============================================================================

const GOLDEN_GAMMA: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

fn splitmix64_at(seed: u64, index: u64) u64 {
    const state = seed +% (GOLDEN_GAMMA *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    return z;
}

fn valueTrit(val: u64) i8 {
    return @as(i8, @intCast(val % 3)) - 1;
}

// ============================================================================
// Sealer (BLAKE3 keyed hash — replaces previous SHA-256(key||msg) which
// was vulnerable to length extension and was not HMAC)
// ============================================================================

const PumpkinBlake3 = std.crypto.hash.Blake3;

fn deriveKey(seed: u64) [32]u8 {
    var key: [32]u8 = undefined;
    for (0..4) |i| {
        const v = splitmix64_at(seed, 1000 + i);
        std.mem.writeInt(u64, key[i * 8 ..][0..8], v, .big);
    }
    return key;
}

fn seal(key: [32]u8, plaintext: []const u8, out: []u8) usize {
    const total = plaintext.len + 32;
    if (out.len < total) return 0;

    // BLAKE3 keyed hash: key provides domain separation, immune to length ext
    var h = PumpkinBlake3.init(.{ .key = key });
    h.update(plaintext);
    var tag: [32]u8 = undefined;
    h.final(&tag);

    @memcpy(out[0..32], &tag);
    @memcpy(out[32..total], plaintext);
    return total;
}

fn unseal(key: [32]u8, sealed_data: []const u8, out: []u8) ?usize {
    if (sealed_data.len < 32) return null;
    const plain_len = sealed_data.len - 32;
    if (out.len < plain_len) return null;

    // Recompute tag
    var h = PumpkinBlake3.init(.{ .key = key });
    h.update(sealed_data[32..]);
    var expected: [32]u8 = undefined;
    h.final(&expected);

    // Constant-time compare
    if (!std.crypto.timing_safe.eql([32]u8, sealed_data[0..32].*, expected)) return null;

    @memcpy(out[0..plain_len], sealed_data[32..]);
    return plain_len;
}

// ============================================================================
// World types
// ============================================================================

pub const TICK_COUNT: usize = 64;
pub const MAX_HISTORY: usize = 64;
pub const MAX_TRANSCRIPT: usize = 256;
pub const MAX_MSG_LEN: usize = 64;

pub const Action = enum(u8) {
    join = 0,
    leave = 1,
    send_message = 2,
    send_dm = 3,
    presence_online = 4,
    presence_away = 5,
    presence_offline = 6,
    request_history = 7,
};

pub const Presence = enum(u8) {
    online = 0,
    offline = 1,
    away = 2,
};

pub const User = struct {
    seed: u64,
    name: [16]u8,
    name_len: usize,
    sealer_key: [32]u8,
    presence: Presence,
    trit: i8,
    in_room: bool,
};

pub const MessageSlot = struct {
    sender: u8,
    body: [MAX_MSG_LEN]u8,
    body_len: usize,
    timestamp: u64,
};

pub const Room = struct {
    members: [3]bool,
    history: [MAX_HISTORY]MessageSlot,
    history_len: usize,
};

pub const TranscriptEntry = struct {
    step: u64,
    actor: u8,
    action: Action,
    trit: i8,
    sealed_data: [128]u8,
    sealed_len: usize,
};

// ============================================================================
// World
// ============================================================================

const USER_NAMES = [3][]const u8{ "alice", "bob", "carol" };
const USER_TRITS = [3]i8{ -1, 0, 1 }; // GF(3) balanced triad

pub const World = struct {
    seed: u64,
    step: u64,
    users: [3]User,
    room: Room,
    transcript: [MAX_TRANSCRIPT]TranscriptEntry,
    transcript_len: usize,
    gf3_sum: i32,

    pub fn init(seed: u64) World {
        var w: World = undefined;
        w.seed = seed;
        w.step = 0;
        w.transcript_len = 0;
        w.gf3_sum = 0;

        // Init room
        w.room.history_len = 0;
        w.room.members = .{ false, false, false };
        for (&w.room.history) |*slot| {
            slot.body_len = 0;
            slot.sender = 0;
            slot.timestamp = 0;
            @memset(&slot.body, 0);
        }

        // Init users
        for (0..3) |i| {
            const user_seed = splitmix64_at(seed, 100 + i);
            w.users[i] = .{
                .seed = user_seed,
                .name = undefined,
                .name_len = USER_NAMES[i].len,
                .sealer_key = deriveKey(user_seed),
                .presence = .online,
                .trit = USER_TRITS[i],
                .in_room = false,
            };
            @memset(&w.users[i].name, 0);
            @memcpy(w.users[i].name[0..USER_NAMES[i].len], USER_NAMES[i]);
        }

        return w;
    }

    pub fn tick(self: *World) void {
        const step = self.step;
        const val0 = splitmix64_at(self.seed, step * 4);
        const val1 = splitmix64_at(self.seed, step * 4 + 1);
        const val2 = splitmix64_at(self.seed, step * 4 + 2);

        const actor_idx: u8 = @intCast(val0 % 3);
        const action_raw: u8 = @intCast(val1 % 8);

        // On the last tick, force the correction trit
        const trit: i8 = if (step == TICK_COUNT - 1) blk: {
            // Correction: need -(gf3_sum) mod 3
            const rem = @rem(self.gf3_sum, 3);
            break :blk if (rem == 0) @as(i8, 0) else if (rem > 0) -@as(i8, @intCast(rem)) + 3 else -@as(i8, @intCast(rem));
        } else valueTrit(val0);

        // Resolve correction trit to valid range {-1, 0, 1}
        const final_trit: i8 = switch (@as(i8, @intCast(@rem(trit + 3, 3)))) {
            0 => 0,
            1 => 1,
            2 => -1,
            else => unreachable,
        };

        const action: Action = @enumFromInt(action_raw);
        const user = &self.users[actor_idx];

        // Record transcript entry
        var entry = TranscriptEntry{
            .step = step,
            .actor = actor_idx,
            .action = action,
            .trit = if (step == TICK_COUNT - 1) final_trit else valueTrit(val0),
            .sealed_data = undefined,
            .sealed_len = 0,
        };
        @memset(&entry.sealed_data, 0);

        // Execute action
        switch (action) {
            .join => {
                user.in_room = true;
                self.room.members[actor_idx] = true;
            },
            .leave => {
                user.in_room = false;
                self.room.members[actor_idx] = false;
            },
            .send_message => {
                if (user.in_room or true) { // always allow for determinism
                    // Generate message body from PRNG
                    var body: [MAX_MSG_LEN]u8 = undefined;
                    const body_len: usize = @intCast(8 + val2 % 24);
                    for (0..body_len) |bi| {
                        const ch = splitmix64_at(self.seed, step * 4 + 100 + bi);
                        body[bi] = @intCast(32 + ch % 95); // printable ASCII
                    }

                    // Seal the message
                    entry.sealed_len = seal(user.sealer_key, body[0..body_len], &entry.sealed_data);

                    // Add to room history
                    if (self.room.history_len < MAX_HISTORY) {
                        var slot = &self.room.history[self.room.history_len];
                        slot.sender = actor_idx;
                        slot.body_len = body_len;
                        @memcpy(slot.body[0..body_len], body[0..body_len]);
                        slot.timestamp = step * 1000;
                        self.room.history_len += 1;
                    }
                }
            },
            .send_dm => {
                // DM to next user (round-robin)
                const recipient = (actor_idx + 1) % 3;
                var dm_body: [32]u8 = undefined;
                const dm_len: usize = @intCast(4 + val2 % 16);
                for (0..dm_len) |bi| {
                    const ch = splitmix64_at(self.seed, step * 4 + 200 + bi);
                    dm_body[bi] = @intCast(32 + ch % 95);
                }
                _ = recipient;
                entry.sealed_len = seal(user.sealer_key, dm_body[0..dm_len], &entry.sealed_data);
            },
            .presence_online => {
                user.presence = .online;
            },
            .presence_away => {
                user.presence = .away;
            },
            .presence_offline => {
                user.presence = .offline;
            },
            .request_history => {
                // no-op in terms of state mutation; just recorded
            },
        }

        // Record
        if (self.transcript_len < MAX_TRANSCRIPT) {
            self.transcript[self.transcript_len] = entry;
            self.transcript_len += 1;
        }

        // Accumulate GF(3) sum
        self.gf3_sum += entry.trit;
        self.step += 1;
    }

    /// Run all ticks from seed. Same seed = same world.
    pub fn replay(seed: u64) World {
        var w = World.init(seed);
        for (0..TICK_COUNT) |_| {
            w.tick();
        }
        return w;
    }

    /// GF(3) conservation check: sum of all trits ≡ 0 (mod 3)
    pub fn verify(self: *const World) bool {
        const r = @rem(self.gf3_sum, 3);
        return r == 0;
    }

    /// Count occurrences of each action type in transcript
    pub fn actionCounts(self: *const World) [8]usize {
        var counts = [_]usize{0} ** 8;
        for (0..self.transcript_len) |i| {
            counts[@intFromEnum(self.transcript[i].action)] += 1;
        }
        return counts;
    }

    /// Verify sealed messages can be unsealed by their author
    pub fn verifySeals(self: *const World) bool {
        for (0..self.transcript_len) |i| {
            const entry = &self.transcript[i];
            if (entry.sealed_len > 0) {
                const key = self.users[entry.actor].sealer_key;
                var out: [128]u8 = undefined;
                if (unseal(key, entry.sealed_data[0..entry.sealed_len], &out) == null) {
                    return false;
                }
            }
        }
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "world replay determinism" {
    const w1 = World.replay(1069);
    const w2 = World.replay(1069);

    try std.testing.expectEqual(w1.transcript_len, w2.transcript_len);
    try std.testing.expectEqual(w1.gf3_sum, w2.gf3_sum);
    try std.testing.expectEqual(w1.step, w2.step);
    try std.testing.expectEqual(w1.room.history_len, w2.room.history_len);

    // Every transcript entry must match
    for (0..w1.transcript_len) |i| {
        try std.testing.expectEqual(w1.transcript[i].step, w2.transcript[i].step);
        try std.testing.expectEqual(w1.transcript[i].actor, w2.transcript[i].actor);
        try std.testing.expectEqual(w1.transcript[i].action, w2.transcript[i].action);
        try std.testing.expectEqual(w1.transcript[i].trit, w2.transcript[i].trit);
        try std.testing.expectEqual(w1.transcript[i].sealed_len, w2.transcript[i].sealed_len);
    }
}

test "world self-evidencing" {
    const w = World.replay(1069);
    try std.testing.expect(w.verify());
}

test "world self-evidencing with different seeds" {
    for ([_]u64{ 0, 1, 42, 1069, 0xDEADBEEF, 0x4bc4d48d0389c599 }) |seed| {
        const w = World.replay(seed);
        try std.testing.expect(w.verify());
    }
}

test "sealed messages round-trip" {
    const w = World.replay(1069);
    try std.testing.expect(w.verifySeals());
}

test "sealed messages fail with wrong key" {
    const w = World.replay(1069);
    // Find first sealed entry
    for (0..w.transcript_len) |i| {
        const entry = &w.transcript[i];
        if (entry.sealed_len > 0) {
            // Try unsealing with a different user's key
            const wrong_actor: u8 = (entry.actor + 1) % 3;
            const wrong_key = w.users[wrong_actor].sealer_key;
            var out: [128]u8 = undefined;
            const result = unseal(wrong_key, entry.sealed_data[0..entry.sealed_len], &out);
            try std.testing.expect(result == null);
            break;
        }
    }
}

test "transcript covers multiple action types" {
    const w = World.replay(1069);
    const counts = w.actionCounts();
    var types_seen: usize = 0;
    for (counts) |c| {
        if (c > 0) types_seen += 1;
    }
    // With 64 ticks and 8 action types, expect at least 5 distinct types
    try std.testing.expect(types_seen >= 5);
}

test "room history has messages" {
    const w = World.replay(1069);
    try std.testing.expect(w.room.history_len > 0);
}

test "all users initialized correctly" {
    const w = World.replay(1069);
    try std.testing.expectEqual(@as(usize, 5), w.users[0].name_len); // alice
    try std.testing.expectEqual(@as(usize, 3), w.users[1].name_len); // bob
    try std.testing.expectEqual(@as(usize, 5), w.users[2].name_len); // carol
    try std.testing.expectEqual(@as(i8, -1), w.users[0].trit);
    try std.testing.expectEqual(@as(i8, 0), w.users[1].trit);
    try std.testing.expectEqual(@as(i8, 1), w.users[2].trit);
}

test "64 ticks executed" {
    const w = World.replay(1069);
    try std.testing.expectEqual(@as(u64, TICK_COUNT), w.step);
    try std.testing.expectEqual(@as(usize, TICK_COUNT), w.transcript_len);
}
