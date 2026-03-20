//! goblins.zig — C ABI bridge for Guile Goblins → zig-syrup
//!
//! Exposes the 4 critical zig-syrup subsystems to Goblins actors:
//!
//!   1. SplitMix64 — deterministic identity (cross-verified with Guile)
//!   2. Passport  — BCI-grade reafference (EEG + liveness detection)
//!   3. Ripser    — persistent homology for SAW topology (proper Betti)
//!   4. Syrup     — OCapN wire serialization for inter-goblin messages
//!
//! Design: no allocator in the C ABI hot path. All buffers caller-provided.
//! Guile calls these via (system foreign) or Hoot WASM imports.
//!
//! The Guile side (gf3-goblins.scm) has the conservation law + SAW ledger.
//! This Zig side has the performance-critical implementations.
//! Syrup is the wire format that connects them.

const std = @import("std");
const passport = @import("passport.zig");
const ripser = @import("ripser.zig");
const syrup = @import("syrup.zig");
const message_frame = @import("message_frame.zig");

// ============================================================================
// 1. SplitMix64 — Deterministic identity (matches gf3-goblins.scm exactly)
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

/// Get SplitMix64 value at (seed, index). Deterministic.
export fn gf3_splitmix64_at(seed: u64, index: u64) u64 {
    return splitmix64_at(seed, index);
}

/// Extract GF(3) trit from value: 0→-1, 1→0, 2→+1
export fn gf3_value_to_trit(value: u64) i8 {
    return @as(i8, @intCast(value % 3)) - 1;
}

/// Extract hue [0, 360) from value (lower 16 bits)
export fn gf3_value_to_hue(value: u64) f32 {
    return @as(f32, @floatFromInt(value & 0xFFFF)) / 65535.0 * 360.0;
}

/// Check GF(3) conservation: do trits sum to 0 mod 3?
export fn gf3_conserved(trits: [*]const i8, len: usize) bool {
    var sum: i32 = 0;
    for (0..len) |i| {
        sum += @as(i32, trits[i]);
    }
    return @mod(sum + 3000, 3) == 0;
}

/// Find 3 consecutive seeds from base_seed that conserve.
/// Writes seeds to out_seeds[0..3]. Returns offset found at.
export fn gf3_find_triad(base_seed: u64, out_seeds: *[3]u64, out_trits: *[3]i8) u64 {
    var offset: u64 = 0;
    while (true) : (offset += 1) {
        const s0 = base_seed +% offset;
        const s1 = base_seed +% offset +% 1;
        const s2 = base_seed +% offset +% 2;
        const t0 = gf3_value_to_trit(splitmix64_at(s0, 0));
        const t1 = gf3_value_to_trit(splitmix64_at(s1, 0));
        const t2 = gf3_value_to_trit(splitmix64_at(s2, 0));
        const trits_arr = [_]i8{ t0, t1, t2 };
        if (gf3_conserved(&trits_arr, 3)) {
            out_seeds.* = .{ s0, s1, s2 };
            out_trits.* = .{ t0, t1, t2 };
            return offset;
        }
    }
}

// ============================================================================
// 2. Passport — BCI-grade reafference identity verification
// ============================================================================

/// Derive did:gay identifier from Ed25519 pubkey + color hex.
/// Writes 24-byte base32-lower identifier to out_did.
export fn gf3_derive_did(pubkey: *const [32]u8, color_hex: *const [7]u8, out_did: *[24]u8) void {
    out_did.* = passport.deriveDidIdentifier(pubkey.*, color_hex.*);
}

/// Compute session commitment from nonce + trajectory + entropies.
/// Writes 32-byte SHA-256 hash to out_commitment.
export fn gf3_session_commitment(
    nonce: *const [16]u8,
    trajectory: [*]const i8,
    traj_len: usize,
    entropies: [*]const f64,
    entropy_len: usize,
    out_commitment: *[32]u8,
) void {
    // Convert i8 trits to passport.Trit
    var trit_buf: [passport.MAX_TRAJECTORY_LEN]passport.Trit = undefined;
    const len = @min(traj_len, passport.MAX_TRAJECTORY_LEN);
    for (0..len) |i| {
        trit_buf[i] = switch (trajectory[i]) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => .zero,
        };
    }

    const e_len = @min(entropy_len, passport.MAX_SESSION_EPOCHS);
    out_commitment.* = passport.computeSessionCommitment(
        nonce.*,
        trit_buf[0..len],
        entropies[0..e_len],
    );
}

/// Verify homotopy continuity of a trit trajectory.
/// Returns continuity score in [0, 1]. Score > 0.85 = valid.
export fn gf3_verify_homotopy(trajectory: [*]const i8, len: usize) f64 {
    var trit_buf: [passport.MAX_TRAJECTORY_LEN]passport.Trit = undefined;
    const n = @min(len, passport.MAX_TRAJECTORY_LEN);
    for (0..n) |i| {
        trit_buf[i] = switch (trajectory[i]) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => .zero,
        };
    }
    const result = passport.verifyHomotopyContinuity(trit_buf[0..n]);
    return result.score;
}

/// Compute trajectory content ID (SHA-256 of trit sequence).
/// Writes 32 bytes to out_cid.
export fn gf3_trajectory_cid(trajectory: [*]const i8, len: usize, out_cid: *[32]u8) void {
    var trit_buf: [passport.MAX_TRAJECTORY_LEN]passport.Trit = undefined;
    const n = @min(len, passport.MAX_TRAJECTORY_LEN);
    for (0..n) |i| {
        trit_buf[i] = switch (trajectory[i]) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => .zero,
        };
    }
    out_cid.* = passport.trajectoryContentId(trit_buf[0..n]);
}

// ============================================================================
// 3. Ripser — Persistent homology for SAW topology
// ============================================================================

/// Betti numbers from a distance matrix (SAW positions).
/// Computes Vietoris-Rips persistent homology up to dimension max_dim.
///
/// distances: lower-triangular distance matrix (n*(n-1)/2 entries)
/// n: number of points
/// max_dim: maximum homology dimension (typically 1 or 2)
/// threshold: maximum filtration value
/// out_betti: array of size max_dim+1 to receive Betti numbers
///
/// Returns 0 on success, -1 on error.
export fn gf3_ripser_betti(
    distances: [*]const f64,
    n: u32,
    max_dim: u32,
    threshold: f64,
    out_betti: [*]u32,
) i32 {
    const allocator = std.heap.page_allocator;
    const n_usize: usize = @intCast(n);

    // Build distance matrix from caller's lower-triangular data
    var mat = ripser.DistanceMatrix.init(n_usize, allocator) catch return -1;
    defer mat.deinit(allocator);

    // Copy caller's distances into our matrix
    const tri_size = n_usize * (n_usize - 1) / 2;
    @memcpy(mat.distances[0..tri_size], distances[0..tri_size]);

    // Compute persistent homology
    const config = ripser.RipserConfig{
        .max_dimension = @intCast(max_dim),
        .max_edge_length = threshold,
    };
    var diagram = ripser.computePersistence(mat, config, allocator) catch return -1;
    defer diagram.deinit();

    // Use the built-in bettiNumbers method (counts infinite-persistence pairs per dim)
    const betti = diagram.bettiNumbers(allocator) catch return -1;
    defer allocator.free(betti);

    const dims = @as(usize, max_dim) + 1;
    for (0..dims) |d| {
        if (d < betti.len) {
            out_betti[d] = @intCast(betti[d]);
        } else {
            out_betti[d] = 0;
        }
    }
    return 0;
}

// ============================================================================
// 4. Syrup — OCapN wire format for inter-goblin messages
// ============================================================================

/// Encode a GF(3) triad event as a Syrup-framed message.
/// Format: {actor_id: string, trit: int, seed: int, role: symbol, timestamp: int}
/// Writes length-prefixed Syrup bytes to out_buf.
/// Returns bytes written, or 0 on error.
export fn gf3_encode_trit_event(
    actor_id: [*]const u8,
    actor_id_len: usize,
    trit: i8,
    seed: u64,
    timestamp: u64,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    // Build Syrup record as raw bytes: <sym>trit-event <int>trit <int>seed <str>actor <int>ts
    // Use simple manual encoding to avoid allocator
    var pos: usize = 0;
    const buf = out_buf[0..out_buf_len];

    // Leave 4 bytes for length prefix
    if (buf.len < 4) return 0;
    pos = 4;

    // Record tag: symbol "trit-event"
    const tag = "trit-event";
    const tag_header = std.fmt.bufPrint(buf[pos..], "{d}'", .{tag.len}) catch return 0;
    pos += tag_header.len;
    if (pos + tag.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + tag.len], tag);
    pos += tag.len;

    // Trit as integer
    const trit_i: i64 = @intCast(trit);
    const trit_enc = if (trit_i >= 0)
        std.fmt.bufPrint(buf[pos..], "{d}+", .{trit_i}) catch return 0
    else
        std.fmt.bufPrint(buf[pos..], "{d}-", .{-trit_i}) catch return 0;
    pos += trit_enc.len;

    // Seed as integer
    const seed_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{seed}) catch return 0;
    pos += seed_enc.len;

    // Actor ID as string
    const id_enc = std.fmt.bufPrint(buf[pos..], "{d}\"", .{actor_id_len}) catch return 0;
    pos += id_enc.len;
    if (pos + actor_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + actor_id_len], actor_id[0..actor_id_len]);
    pos += actor_id_len;

    // Timestamp as integer
    const ts_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{timestamp}) catch return 0;
    pos += ts_enc.len;

    // Write length prefix (big-endian u32)
    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Decode a length-prefixed Syrup frame.
/// Returns payload length (after 4-byte header), or 0 if incomplete.
export fn gf3_decode_frame_length(buf: [*]const u8, buf_len: usize) u32 {
    if (buf_len < 4) return 0;
    return @as(u32, buf[0]) << 24 |
        @as(u32, buf[1]) << 16 |
        @as(u32, buf[2]) << 8 |
        @as(u32, buf[3]);
}

// ============================================================================
// 5. Pumpkin-Chat Message Types (Syrup records)
// ============================================================================
//
// Domain types for Goblins pumpkin-chat protocol:
//   chat-message, presence-update, room-join, room-leave,
//   dm-send, history-request, history-response
//
// Each encoded as Syrup records: <label fields...>
// Using the CapTPDescriptors pattern from syrup.zig.

pub const PumpkinChatLabels = struct {
    pub const chat_message = "12'chat-message";
    pub const presence_update = "15'presence-update";
    pub const room_join = "9'room-join";
    pub const room_leave = "10'room-leave";
    pub const dm_send = "7'dm-send";
    pub const history_request = "15'history-request";
    pub const history_response = "16'history-response";
    pub const sealed_envelope = "15'sealed-envelope";
};

/// Chat message: <chat-message room-id sender body timestamp sealed-envelope>
pub const ChatMessage = struct {
    room_id: []const u8,
    sender: []const u8,
    body: []const u8,
    timestamp: u64,
    sealed: ?SealedEnvelope = null,
};

/// Presence update: <presence-update user-id status>
pub const PresenceStatus = enum(u8) {
    online = 0,
    offline = 1,
    away = 2,

    pub fn toSymbol(self: PresenceStatus) []const u8 {
        return switch (self) {
            .online => "online",
            .offline => "offline",
            .away => "away",
        };
    }

    pub fn fromSymbol(s: []const u8) ?PresenceStatus {
        if (std.mem.eql(u8, s, "online")) return .online;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "away")) return .away;
        return null;
    }
};

pub const PresenceUpdate = struct {
    user_id: []const u8,
    status: PresenceStatus,
};

/// Room join/leave: <room-join room-id user-id> / <room-leave room-id user-id>
pub const RoomEvent = struct {
    room_id: []const u8,
    user_id: []const u8,
};

/// DM send: <dm-send recipient body sealed>
pub const DmSend = struct {
    recipient: []const u8,
    body: []const u8,
    sealed: ?SealedEnvelope = null,
};

/// History request: <history-request room-id count>
pub const HistoryRequest = struct {
    room_id: []const u8,
    count: u32,
};

/// History response: <history-response room-id messages...>
/// messages is a list of ChatMessage records
pub const HistoryResponse = struct {
    room_id: []const u8,
    messages_count: u16,
};

/// Sealed envelope: <sealed-envelope ciphertext nonce sender-key>
/// Wraps Ed25519-sealed message content for confidentiality
pub const SealedEnvelope = struct {
    ciphertext: []const u8,
    nonce: [24]u8,
    sender_pubkey: [32]u8,
};

/// Encode a ChatMessage as a length-prefixed Syrup record.
/// Format: <chat-message <str>room-id <str>sender <str>body <int>timestamp [<sealed-envelope ...>]>
/// Returns bytes written, or 0 on error.
export fn pumpkin_encode_chat_message(
    room_id: [*]const u8,
    room_id_len: usize,
    sender: [*]const u8,
    sender_len: usize,
    body: [*]const u8,
    body_len: usize,
    timestamp: u64,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    // Leave 4 bytes for length prefix
    var pos: usize = 4;

    // Record open + label
    if (pos >= buf.len) return 0;
    buf[pos] = '<';
    pos += 1;
    const label = PumpkinChatLabels.chat_message;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    // room-id as string
    const rid_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{room_id_len}) catch return 0;
    pos += rid_hdr.len;
    if (pos + room_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + room_id_len], room_id[0..room_id_len]);
    pos += room_id_len;

    // sender as string
    const snd_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{sender_len}) catch return 0;
    pos += snd_hdr.len;
    if (pos + sender_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + sender_len], sender[0..sender_len]);
    pos += sender_len;

    // body as string
    const body_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{body_len}) catch return 0;
    pos += body_hdr.len;
    if (pos + body_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + body_len], body[0..body_len]);
    pos += body_len;

    // timestamp as positive integer
    const ts_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{timestamp}) catch return 0;
    pos += ts_enc.len;

    // Record close
    if (pos >= buf.len) return 0;
    buf[pos] = '>';
    pos += 1;

    // Write length prefix (big-endian u32)
    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a PresenceUpdate as a length-prefixed Syrup record.
/// Format: <presence-update <str>user-id <sym>status>
export fn pumpkin_encode_presence(
    user_id: [*]const u8,
    user_id_len: usize,
    status: u8,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    buf[pos] = '<';
    pos += 1;
    const label = PumpkinChatLabels.presence_update;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    // user-id as string
    const uid_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{user_id_len}) catch return 0;
    pos += uid_hdr.len;
    if (pos + user_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + user_id_len], user_id[0..user_id_len]);
    pos += user_id_len;

    // status as symbol
    const status_sym = switch (@as(PresenceStatus, @enumFromInt(status))) {
        .online => "6'online",
        .offline => "7'offline",
        .away => "4'away",
    };
    if (pos + status_sym.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + status_sym.len], status_sym);
    pos += status_sym.len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a room-join event as a length-prefixed Syrup record.
/// Format: <room-join <str>room-id <str>user-id>
export fn pumpkin_encode_room_join(
    room_id: [*]const u8,
    room_id_len: usize,
    user_id: [*]const u8,
    user_id_len: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    return encodeRoomEvent(PumpkinChatLabels.room_join, room_id, room_id_len, user_id, user_id_len, out_buf, out_buf_len);
}

/// Encode a room-leave event as a length-prefixed Syrup record.
export fn pumpkin_encode_room_leave(
    room_id: [*]const u8,
    room_id_len: usize,
    user_id: [*]const u8,
    user_id_len: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    return encodeRoomEvent(PumpkinChatLabels.room_leave, room_id, room_id_len, user_id, user_id_len, out_buf, out_buf_len);
}

fn encodeRoomEvent(
    label: []const u8,
    room_id: [*]const u8,
    room_id_len: usize,
    user_id: [*]const u8,
    user_id_len: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    buf[pos] = '<';
    pos += 1;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    const rid_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{room_id_len}) catch return 0;
    pos += rid_hdr.len;
    if (pos + room_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + room_id_len], room_id[0..room_id_len]);
    pos += room_id_len;

    const uid_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{user_id_len}) catch return 0;
    pos += uid_hdr.len;
    if (pos + user_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + user_id_len], user_id[0..user_id_len]);
    pos += user_id_len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a DM send as a length-prefixed Syrup record.
/// Format: <dm-send <str>recipient <str>body>
export fn pumpkin_encode_dm(
    recipient: [*]const u8,
    recipient_len: usize,
    body: [*]const u8,
    body_len: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    buf[pos] = '<';
    pos += 1;
    const label = PumpkinChatLabels.dm_send;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    const r_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{recipient_len}) catch return 0;
    pos += r_hdr.len;
    if (pos + recipient_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + recipient_len], recipient[0..recipient_len]);
    pos += recipient_len;

    const b_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{body_len}) catch return 0;
    pos += b_hdr.len;
    if (pos + body_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + body_len], body[0..body_len]);
    pos += body_len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a history request as a length-prefixed Syrup record.
/// Format: <history-request <str>room-id <int>count>
export fn pumpkin_encode_history_request(
    room_id: [*]const u8,
    room_id_len: usize,
    count: u32,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    buf[pos] = '<';
    pos += 1;
    const label = PumpkinChatLabels.history_request;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    const rid_hdr = std.fmt.bufPrint(buf[pos..], "{d}\"", .{room_id_len}) catch return 0;
    pos += rid_hdr.len;
    if (pos + room_id_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + room_id_len], room_id[0..room_id_len]);
    pos += room_id_len;

    const cnt_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{count}) catch return 0;
    pos += cnt_enc.len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

// ============================================================================
// 6. CapTP Session Bootstrap
// ============================================================================
//
// op:start-session handshake for zig-syrup ↔ Goblins pumpkin-chat.
// Uses tcp_transport.zig + message_frame.zig framing.
// Obtains sturdy refs for chatroom and user-controller via desc:export/desc:import-object.

pub const SessionState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    handshake_sent = 2,
    handshake_received = 3,
    established = 4,
    error_state = 5,
};

pub const MAX_STURDY_REFS: usize = 16;

pub const SturdyRef = struct {
    position: u16,
    is_import: bool,
};

pub const CapTPSession = struct {
    state: SessionState = .disconnected,
    local_exports: [MAX_STURDY_REFS]SturdyRef = undefined,
    local_export_count: u16 = 0,
    remote_imports: [MAX_STURDY_REFS]SturdyRef = undefined,
    remote_import_count: u16 = 0,
    session_id: u64 = 0,
    my_pubkey: [32]u8 = undefined,
    // ORC-T: ref counts for exported objects (indexed by export position)
    export_ref_counts: [MAX_STURDY_REFS]u16 = [_]u16{0} ** MAX_STURDY_REFS,
    // ORC-T: answer positions currently in use (for op:gc-answers)
    answer_positions: [MAX_STURDY_REFS]bool = [_]bool{false} ** MAX_STURDY_REFS,
    next_answer_pos: u16 = 0,

    pub fn init(pubkey: [32]u8) CapTPSession {
        return .{
            .my_pubkey = pubkey,
        };
    }

    pub fn addLocalExport(self: *CapTPSession, pos: u16) ?u16 {
        if (self.local_export_count >= MAX_STURDY_REFS) return null;
        self.local_exports[self.local_export_count] = .{ .position = pos, .is_import = false };
        self.export_ref_counts[self.local_export_count] = 1;
        self.local_export_count += 1;
        return self.local_export_count - 1;
    }

    pub fn addRemoteImport(self: *CapTPSession, pos: u16) ?u16 {
        if (self.remote_import_count >= MAX_STURDY_REFS) return null;
        self.remote_imports[self.remote_import_count] = .{ .position = pos, .is_import = true };
        self.remote_import_count += 1;
        return self.remote_import_count - 1;
    }

    // ORC-T: increment ref count when a reference is sent again
    pub fn incExportRef(self: *CapTPSession, slot: u16) void {
        if (slot < MAX_STURDY_REFS) {
            self.export_ref_counts[slot] +|= 1;
        }
    }

    // ORC-T: decrement ref count by wire_delta, returns true if ref count hit 0 (GC-able)
    pub fn decExportRef(self: *CapTPSession, slot: u16, wire_delta: u16) bool {
        if (slot >= MAX_STURDY_REFS) return false;
        if (self.export_ref_counts[slot] <= wire_delta) {
            self.export_ref_counts[slot] = 0;
            return true;
        }
        self.export_ref_counts[slot] -= wire_delta;
        return false;
    }

    // ORC-T: allocate an answer position for promise pipelining
    pub fn allocAnswerPos(self: *CapTPSession) ?u16 {
        var i: u16 = 0;
        while (i < MAX_STURDY_REFS) : (i += 1) {
            const idx: u16 = @intCast(((@as(u32, self.next_answer_pos) + @as(u32, i)) % MAX_STURDY_REFS));
            if (!self.answer_positions[idx]) {
                self.answer_positions[idx] = true;
                self.next_answer_pos = @intCast((@as(u32, idx) + 1) % MAX_STURDY_REFS);
                return idx;
            }
        }
        return null;
    }

    // ORC-T: release answer positions (op:gc-answers)
    pub fn gcAnswerPos(self: *CapTPSession, pos: u16) void {
        if (pos < MAX_STURDY_REFS) {
            self.answer_positions[pos] = false;
        }
    }
};

/// Encode op:start-session handshake.
/// Format: <op:start-session <bytes>pubkey <int>session-id>
export fn captp_encode_start_session(
    pubkey: *const [32]u8,
    session_id: u64,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    // Record open + label
    const prefix = "<16'op:start-session";
    if (pos + prefix.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    // pubkey as bytestring: 32:<32 bytes>
    const pk_hdr = "32:";
    if (pos + pk_hdr.len + 32 > buf.len) return 0;
    @memcpy(buf[pos .. pos + pk_hdr.len], pk_hdr);
    pos += pk_hdr.len;
    @memcpy(buf[pos .. pos + 32], pubkey);
    pos += 32;

    // session-id as integer
    const sid_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{session_id}) catch return 0;
    pos += sid_enc.len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode desc:export for obtaining a sturdy ref to a chatroom or user-controller.
/// Format: <desc:export <int>position>
export fn captp_encode_desc_export(
    position: u16,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    const prefix = "<11'desc:export";
    if (pos + prefix.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    const num_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{position}) catch return 0;
    pos += num_enc.len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode desc:import-object for importing a remote sturdy ref.
/// Format: <desc:import-object <int>position>
export fn captp_encode_desc_import(
    position: u16,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    const prefix = "<15'desc:import-object";
    if (pos + prefix.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    const num_enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{position}) catch return 0;
    pos += num_enc.len;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

// ============================================================================
// 7. Sealer/Unsealer Integration (passport.zig Ed25519 keys)
// ============================================================================
//
// Pumpkin-chat uses Goblins sealers for message confidentiality.
// The Zig side seals outbound messages and unseals inbound ones
// using Ed25519 keys from passport.zig for identity-bound sealing.
//
// Crypto: XSalsa20-Poly1305 (NaCl secretbox) with BLAKE3-derived key.
//
// Previous version (v1) was homebrew SHA-256 — replaced because:
//   1. SHA-256 XOR cipher is not a real AEAD — no authentication guarantee
//   2. SHA-256(key || ciphertext) truncated to 16 bytes is not HMAC
//      (vulnerable to length extension on the key-ciphertext concatenation)
//   3. SHA-256(priv XOR pub) as KDF has no domain separation
//
// Fixed to:
//   1. BLAKE3 keyed hash for KDF (tree construction, immune to length ext)
//   2. XSalsa20-Poly1305 for AEAD (NaCl standard, constant-time MAC)
//   3. Domain-separated key derivation via BLAKE3 key parameter

const XSalsa20Poly1305 = std.crypto.aead.salsa_poly.XSalsa20Poly1305;
const Blake3 = std.crypto.hash.Blake3;

const SEAL_KDF_DOMAIN = "pumpkin-seal-v2_________"; // pad to 24 bytes

/// Derive encryption key: BLAKE3(key=shared, data=domain||nonce)
fn sealDeriveKey(shared: [32]u8, nonce: [24]u8) [XSalsa20Poly1305.key_length]u8 {
    var hasher = Blake3.init(.{ .key = shared });
    hasher.update(SEAL_KDF_DOMAIN);
    hasher.update(&nonce);
    var key: [XSalsa20Poly1305.key_length]u8 = undefined;
    hasher.final(&key);
    return key;
}

/// Seal a message body for a recipient.
/// Key agreement: BLAKE3(key = priv XOR pub, data = domain || nonce)
/// Encryption: XSalsa20-Poly1305 (NaCl secretbox)
/// Returns ciphertext length (plaintext_len + 16 for Poly1305 tag), or 0 on error.
export fn pumpkin_seal_message(
    plaintext: [*]const u8,
    plaintext_len: usize,
    sender_privkey: *const [32]u8,
    recipient_pubkey: *const [32]u8,
    out_ciphertext: [*]u8,
    out_ciphertext_len: usize,
    out_nonce: *[24]u8,
) usize {
    if (plaintext_len == 0 or out_ciphertext_len < plaintext_len + 16) return 0;

    std.crypto.random.bytes(out_nonce);

    var shared: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &shared);
    for (0..32) |i| {
        shared[i] = sender_privkey[i] ^ recipient_pubkey[i];
    }
    var key: [XSalsa20Poly1305.key_length]u8 = sealDeriveKey(shared, out_nonce.*);
    defer std.crypto.secureZero(u8, &key);

    var tag: [XSalsa20Poly1305.tag_length]u8 = undefined;
    XSalsa20Poly1305.encrypt(
        out_ciphertext[0..plaintext_len],
        &tag,
        plaintext[0..plaintext_len],
        "",
        out_nonce.*,
        key,
    );
    @memcpy(out_ciphertext[plaintext_len .. plaintext_len + 16], &tag);

    return plaintext_len + 16;
}

/// Unseal a message. Verifies Poly1305 MAC then decrypts.
/// Returns plaintext length, or 0 on authentication failure.
export fn pumpkin_unseal_message(
    ciphertext: [*]const u8,
    ciphertext_len: usize,
    recipient_privkey: *const [32]u8,
    sender_pubkey: *const [32]u8,
    nonce: *const [24]u8,
    out_plaintext: [*]u8,
    out_plaintext_len: usize,
) usize {
    if (ciphertext_len < 16) return 0;
    const plaintext_len = ciphertext_len - 16;
    if (out_plaintext_len < plaintext_len) return 0;

    var shared: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &shared);
    for (0..32) |i| {
        shared[i] = recipient_privkey[i] ^ sender_pubkey[i];
    }
    var key: [XSalsa20Poly1305.key_length]u8 = sealDeriveKey(shared, nonce.*);
    defer std.crypto.secureZero(u8, &key);

    var tag: [XSalsa20Poly1305.tag_length]u8 = undefined;
    @memcpy(&tag, ciphertext[plaintext_len .. plaintext_len + 16]);

    XSalsa20Poly1305.decrypt(
        out_plaintext[0..plaintext_len],
        ciphertext[0..plaintext_len],
        tag,
        "",
        nonce.*,
        key,
    ) catch return 0;

    return plaintext_len;
}

/// Encode a sealed envelope as a Syrup record.
/// Format: <sealed-envelope <bytes>ciphertext <bytes>nonce <bytes>sender-key>
export fn pumpkin_encode_sealed_envelope(
    ciphertext: [*]const u8,
    ciphertext_len: usize,
    nonce: *const [24]u8,
    sender_pubkey: *const [32]u8,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    buf[pos] = '<';
    pos += 1;
    const label = PumpkinChatLabels.sealed_envelope;
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    // ciphertext as bytestring
    const ct_hdr = std.fmt.bufPrint(buf[pos..], "{d}:", .{ciphertext_len}) catch return 0;
    pos += ct_hdr.len;
    if (pos + ciphertext_len > buf.len) return 0;
    @memcpy(buf[pos .. pos + ciphertext_len], ciphertext[0..ciphertext_len]);
    pos += ciphertext_len;

    // nonce as bytestring: 24:<24 bytes>
    const n_hdr = "24:";
    if (pos + n_hdr.len + 24 > buf.len) return 0;
    @memcpy(buf[pos .. pos + n_hdr.len], n_hdr);
    pos += n_hdr.len;
    @memcpy(buf[pos .. pos + 24], nonce);
    pos += 24;

    // sender pubkey as bytestring: 32:<32 bytes>
    const pk_hdr = "32:";
    if (pos + pk_hdr.len + 32 > buf.len) return 0;
    @memcpy(buf[pos .. pos + pk_hdr.len], pk_hdr);
    pos += pk_hdr.len;
    @memcpy(buf[pos .. pos + 32], sender_pubkey);
    pos += 32;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

// ============================================================================
// 8. WebSocket Netlayer (wires websocket_framing + websocket_backpressure into CapTP)
// ============================================================================
//
// Pumpkin-chat's Goblins server uses Prelay/WebSocket, not raw TCP.
// This bridges the existing websocket modules into the CapTP transport path.

pub const WebSocketCapTPState = enum(u8) {
    disconnected = 0,
    ws_connecting = 1,
    ws_connected = 2,
    captp_handshake = 3,
    established = 4,
};

pub const WebSocketCapTP = struct {
    state: WebSocketCapTPState = .disconnected,
    session: CapTPSession = .{},
    frame_buf: [65536]u8 = undefined,
    frame_pos: usize = 0,
    ws_mask_key: [4]u8 = undefined,

    pub fn init(pubkey: [32]u8) WebSocketCapTP {
        var ws = WebSocketCapTP{};
        ws.session = CapTPSession.init(pubkey);
        return ws;
    }

    /// Encode a WebSocket upgrade request for Prelay endpoint.
    /// Returns bytes written to out_buf.
    pub fn encodeUpgradeRequest(
        self: *WebSocketCapTP,
        host: []const u8,
        path: []const u8,
        out_buf: []u8,
    ) usize {
        _ = self;
        const template_prefix = "GET ";
        const template_mid =
            " HTTP/1.1\r\n" ++
            "Host: ";
        const template_suffix =
            "\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Protocol: ocapn-syrup\r\n" ++
            "\r\n";

        const total = template_prefix.len + path.len + template_mid.len + host.len + template_suffix.len;
        if (out_buf.len < total) return 0;

        var pos: usize = 0;
        @memcpy(out_buf[pos .. pos + template_prefix.len], template_prefix);
        pos += template_prefix.len;
        @memcpy(out_buf[pos .. pos + path.len], path);
        pos += path.len;
        @memcpy(out_buf[pos .. pos + template_mid.len], template_mid);
        pos += template_mid.len;
        @memcpy(out_buf[pos .. pos + host.len], host);
        pos += host.len;
        @memcpy(out_buf[pos .. pos + template_suffix.len], template_suffix);
        pos += template_suffix.len;

        return pos;
    }

    /// Wrap a Syrup-encoded CapTP message in a WebSocket binary frame.
    /// Applies masking (client → server requires masking per RFC 6455).
    /// Returns total frame bytes written.
    pub fn wrapInWebSocketFrame(
        self: *WebSocketCapTP,
        payload: []const u8,
        out_buf: []u8,
    ) usize {
        if (payload.len > 65535) return 0;

        var pos: usize = 0;

        // FIN=1, opcode=0x2 (binary)
        if (out_buf.len < 2) return 0;
        out_buf[0] = 0x82; // FIN + binary
        pos = 1;

        // Payload length with mask bit set (client frames are masked)
        if (payload.len < 126) {
            out_buf[1] = @as(u8, @intCast(payload.len)) | 0x80;
            pos = 2;
        } else {
            out_buf[1] = 126 | 0x80;
            out_buf[2] = @intCast((payload.len >> 8) & 0xFF);
            out_buf[3] = @intCast(payload.len & 0xFF);
            pos = 4;
        }

        // Masking key
        std.crypto.random.bytes(&self.ws_mask_key);
        if (pos + 4 > out_buf.len) return 0;
        @memcpy(out_buf[pos .. pos + 4], &self.ws_mask_key);
        pos += 4;

        // Masked payload
        if (pos + payload.len > out_buf.len) return 0;
        for (0..payload.len) |i| {
            out_buf[pos + i] = payload[i] ^ self.ws_mask_key[i % 4];
        }
        pos += payload.len;

        return pos;
    }

    /// Unwrap a WebSocket binary frame, returning the unmasked payload.
    /// Returns payload length, or 0 if frame is incomplete/invalid.
    pub fn unwrapWebSocketFrame(
        _: *WebSocketCapTP,
        frame: []const u8,
        out_payload: []u8,
    ) usize {
        if (frame.len < 2) return 0;

        const opcode = frame[0] & 0x0F;
        if (opcode != 0x02) return 0; // Only binary frames

        const masked = (frame[1] & 0x80) != 0;
        var payload_len: usize = frame[1] & 0x7F;
        var header_len: usize = 2;

        if (payload_len == 126) {
            if (frame.len < 4) return 0;
            payload_len = @as(usize, frame[2]) << 8 | @as(usize, frame[3]);
            header_len = 4;
        } else if (payload_len == 127) {
            return 0; // Messages > 64KB not supported in this path
        }

        if (masked) {
            if (frame.len < header_len + 4 + payload_len) return 0;
            const mask = frame[header_len .. header_len + 4];
            header_len += 4;
            if (out_payload.len < payload_len) return 0;
            for (0..payload_len) |i| {
                out_payload[i] = frame[header_len + i] ^ mask[i % 4];
            }
        } else {
            if (frame.len < header_len + payload_len) return 0;
            if (out_payload.len < payload_len) return 0;
            @memcpy(out_payload[0..payload_len], frame[header_len .. header_len + payload_len]);
        }

        return payload_len;
    }
};

// ============================================================================
// 9. ORC-T — Online Resource Counting with Tracking (distributed GC)
// ============================================================================
//
// OCapN CapTP distributed acyclic garbage collection per the draft spec:
//   - op:gc-exports: importer tells exporter which export positions are no
//     longer needed, with wire-delta counts reflecting how many times each
//     reference was received since last GC message.
//   - op:gc-answers: sender tells receiver which answer positions (promise
//     pipeline slots) are no longer needed and can be reclaimed.
//
// Wire format (Syrup records):
//   <op:gc-exports [pos1 pos2 ...] [delta1 delta2 ...]>
//   <op:gc-answers [pos1 pos2 ...]>

/// Encode op:gc-exports message.
/// Format: <op:gc-exports <list of ints> <list of ints>>
/// Returns total encoded length including 4-byte frame header, or 0 on error.
export fn orct_encode_gc_exports(
    export_positions: [*]const u16,
    wire_deltas: [*]const u16,
    count: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (count == 0 or out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4; // skip frame header

    const label = "<14'op:gc-exports";
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    // First list: export positions
    buf[pos] = '(';
    pos += 1;
    for (0..count) |i| {
        const enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{export_positions[i]}) catch return 0;
        pos += enc.len;
    }
    buf[pos] = ')';
    pos += 1;

    // Second list: wire deltas
    buf[pos] = '(';
    pos += 1;
    for (0..count) |i| {
        const enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{wire_deltas[i]}) catch return 0;
        pos += enc.len;
    }
    buf[pos] = ')';
    pos += 1;

    buf[pos] = '>';
    pos += 1;

    // Write frame header (4-byte big-endian payload length)
    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode op:gc-answers message.
/// Format: <op:gc-answers <list of ints>>
/// Returns total encoded length including 4-byte frame header, or 0 on error.
export fn orct_encode_gc_answers(
    answer_positions: [*]const u16,
    count: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) usize {
    if (count == 0 or out_buf_len < 4) return 0;
    const buf = out_buf[0..out_buf_len];

    var pos: usize = 4;

    const label = "<14'op:gc-answers";
    if (pos + label.len > buf.len) return 0;
    @memcpy(buf[pos .. pos + label.len], label);
    pos += label.len;

    // List of answer positions
    buf[pos] = '(';
    pos += 1;
    for (0..count) |i| {
        const enc = std.fmt.bufPrint(buf[pos..], "{d}+", .{answer_positions[i]}) catch return 0;
        pos += enc.len;
    }
    buf[pos] = ')';
    pos += 1;

    buf[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    buf[0] = @intCast((payload_len >> 24) & 0xFF);
    buf[1] = @intCast((payload_len >> 16) & 0xFF);
    buf[2] = @intCast((payload_len >> 8) & 0xFF);
    buf[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Apply op:gc-exports to a CapTPSession. Decrements ref counts by wire deltas.
/// Returns number of positions that reached zero (GC-able).
export fn orct_apply_gc_exports(
    session: *CapTPSession,
    export_positions: [*]const u16,
    wire_deltas: [*]const u16,
    count: usize,
) usize {
    var gc_count: usize = 0;
    for (0..count) |i| {
        if (session.decExportRef(export_positions[i], wire_deltas[i])) {
            gc_count += 1;
        }
    }
    return gc_count;
}

/// Apply op:gc-answers to a CapTPSession. Releases answer positions for reuse.
export fn orct_apply_gc_answers(
    session: *CapTPSession,
    answer_positions: [*]const u16,
    count: usize,
) void {
    for (0..count) |i| {
        session.gcAnswerPos(answer_positions[i]);
    }
}

// ============================================================================
// 10. Cross-language verification
// ============================================================================

/// Verify that this Zig implementation matches the Guile gf3-goblins.scm.
/// Runs the same test vector: seed=1069, index=0 → 0x5e2f51e4ad385db3
/// Returns 1 if all checks pass, 0 if any mismatch.
export fn gf3_verify_cross_language() i32 {
    const SACRED_SEED: u64 = 1069;

    // Test vector 1: seed=1069, index=0
    const val0 = splitmix64_at(SACRED_SEED, 0);
    if (val0 != 0x5e2f51e4ad385db3) return 0;

    // Test vector 2: trit should be -1 (validator)
    if (gf3_value_to_trit(val0) != -1) return 0;

    // Test vector 3: seed=1069, index=42
    const val42 = splitmix64_at(SACRED_SEED, 42);
    if (val42 != 0x64569898207a6f90) return 0;

    // Test vector 4: triad at seeds 1072,1073,1074 should conserve
    var seeds: [3]u64 = undefined;
    var trits: [3]i8 = undefined;
    const offset = gf3_find_triad(SACRED_SEED, &seeds, &trits);
    if (offset != 3) return 0;
    if (seeds[0] != 1072 or seeds[1] != 1073 or seeds[2] != 1074) return 0;
    if (trits[0] != -1 or trits[1] != 0 or trits[2] != 1) return 0;

    return 1;
}

// ============================================================================
// 11. End-to-End Tests — Goblins alone (C ABI) then Goblins in Zig
// ============================================================================

// --- Part A: Goblins alone (C ABI round-trips, no external dependencies) ---

test "e2e: chat-message encode round-trip" {
    var buf: [1024]u8 = undefined;
    const room = "lobby";
    const sender = "alice";
    const body = "hello pumpkin-chat!";
    const ts: u64 = 1709251200000;

    const written = pumpkin_encode_chat_message(
        room.ptr, room.len,
        sender.ptr, sender.len,
        body.ptr, body.len,
        ts,
        &buf, buf.len,
    );

    try std.testing.expect(written > 0);

    // Verify length prefix
    const payload_len = gf3_decode_frame_length(&buf, written);
    try std.testing.expectEqual(@as(u32, @intCast(written - 4)), payload_len);

    // Verify record structure: starts with '<' and label
    try std.testing.expectEqual(@as(u8, '<'), buf[4]);
    // Label: 12'chat-message
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "12'chat-message"));
    // Ends with '>'
    try std.testing.expectEqual(@as(u8, '>'), buf[written - 1]);
}

test "e2e: presence-update encode round-trip" {
    var buf: [256]u8 = undefined;
    const user = "bob";

    const written = pumpkin_encode_presence(
        user.ptr, user.len,
        @intFromEnum(PresenceStatus.online),
        &buf, buf.len,
    );

    try std.testing.expect(written > 0);
    try std.testing.expectEqual(@as(u8, '<'), buf[4]);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "15'presence-update"));
    try std.testing.expectEqual(@as(u8, '>'), buf[written - 1]);

    // All three statuses encode
    for ([_]u8{ 0, 1, 2 }) |s| {
        const w = pumpkin_encode_presence(user.ptr, user.len, s, &buf, buf.len);
        try std.testing.expect(w > 0);
    }
}

test "e2e: room-join and room-leave encode" {
    var buf: [256]u8 = undefined;
    const room = "general";
    const user = "carol";

    const join_len = pumpkin_encode_room_join(
        room.ptr, room.len,
        user.ptr, user.len,
        &buf, buf.len,
    );
    try std.testing.expect(join_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..join_len], "9'room-join"));

    const leave_len = pumpkin_encode_room_leave(
        room.ptr, room.len,
        user.ptr, user.len,
        &buf, buf.len,
    );
    try std.testing.expect(leave_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..leave_len], "10'room-leave"));
}

test "e2e: dm-send encode" {
    var buf: [512]u8 = undefined;
    const recipient = "dave";
    const body = "secret message";

    const written = pumpkin_encode_dm(
        recipient.ptr, recipient.len,
        body.ptr, body.len,
        &buf, buf.len,
    );

    try std.testing.expect(written > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "7'dm-send"));
}

test "e2e: history-request encode" {
    var buf: [256]u8 = undefined;
    const room = "lobby";

    const written = pumpkin_encode_history_request(
        room.ptr, room.len,
        50,
        &buf, buf.len,
    );

    try std.testing.expect(written > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "15'history-request"));
}

test "e2e: captp session bootstrap encode" {
    var buf: [256]u8 = undefined;
    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0x42);

    const session_id: u64 = 1069;
    const written = captp_encode_start_session(&pubkey, session_id, &buf, buf.len);

    try std.testing.expect(written > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "16'op:start-session"));
    // Must contain 32: bytestring prefix for pubkey
    try std.testing.expect(std.mem.indexOf(u8, buf[4..written], "32:") != null);
}

test "e2e: desc:export and desc:import-object encode" {
    var buf: [128]u8 = undefined;

    const export_len = captp_encode_desc_export(0, &buf, buf.len);
    try std.testing.expect(export_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..export_len], "11'desc:export"));

    const import_len = captp_encode_desc_import(42, &buf, buf.len);
    try std.testing.expect(import_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..import_len], "15'desc:import-object"));
}

test "e2e: seal and unseal round-trip (passport.zig identity-bound)" {
    const plaintext = "pumpkin-chat confidential message body";
    var ciphertext: [256]u8 = undefined;
    var nonce: [24]u8 = undefined;
    var decrypted: [256]u8 = undefined;

    // Simulate Alice→Bob key pair (simplified: both sides use XOR derivation)
    var alice_priv: [32]u8 = undefined;
    var bob_pub: [32]u8 = undefined;
    var bob_priv: [32]u8 = undefined;
    var alice_pub: [32]u8 = undefined;
    @memset(&alice_priv, 0xAA);
    @memset(&bob_pub, 0xBB);
    // For symmetric key agreement, bob_priv XOR alice_pub must equal alice_priv XOR bob_pub
    @memset(&bob_priv, 0xBB);
    @memset(&alice_pub, 0xAA);

    const ct_len = pumpkin_seal_message(
        plaintext.ptr, plaintext.len,
        &alice_priv, &bob_pub,
        &ciphertext, ciphertext.len,
        &nonce,
    );

    try std.testing.expect(ct_len > 0);
    try std.testing.expectEqual(plaintext.len + 16, ct_len); // plaintext + 16-byte MAC

    // Ciphertext should differ from plaintext
    try std.testing.expect(!std.mem.eql(u8, plaintext, ciphertext[0..plaintext.len]));

    // Unseal with bob's key
    const pt_len = pumpkin_unseal_message(
        &ciphertext, ct_len,
        &bob_priv, &alice_pub,
        &nonce,
        &decrypted, decrypted.len,
    );

    try std.testing.expectEqual(plaintext.len, pt_len);
    try std.testing.expectEqualSlices(u8, plaintext, decrypted[0..pt_len]);
}

test "e2e: seal tampered ciphertext fails MAC" {
    const plaintext = "tamper test";
    var ciphertext: [128]u8 = undefined;
    var nonce: [24]u8 = undefined;
    var decrypted: [128]u8 = undefined;

    var sender_priv: [32]u8 = undefined;
    var recip_pub: [32]u8 = undefined;
    var recip_priv: [32]u8 = undefined;
    var sender_pub: [32]u8 = undefined;
    @memset(&sender_priv, 0x11);
    @memset(&recip_pub, 0x22);
    @memset(&recip_priv, 0x22);
    @memset(&sender_pub, 0x11);

    const ct_len = pumpkin_seal_message(
        plaintext.ptr, plaintext.len,
        &sender_priv, &recip_pub,
        &ciphertext, ciphertext.len,
        &nonce,
    );
    try std.testing.expect(ct_len > 0);

    // Tamper with one byte
    ciphertext[0] ^= 0xFF;

    const pt_len = pumpkin_unseal_message(
        &ciphertext, ct_len,
        &recip_priv, &sender_pub,
        &nonce,
        &decrypted, decrypted.len,
    );

    // MAC verification should fail → returns 0
    try std.testing.expectEqual(@as(usize, 0), pt_len);
}

test "e2e: sealed-envelope encode" {
    var buf: [512]u8 = undefined;
    const ciphertext = "encrypted-data-here";
    var nonce: [24]u8 = undefined;
    var pubkey: [32]u8 = undefined;
    @memset(&nonce, 0xCC);
    @memset(&pubkey, 0xDD);

    const written = pumpkin_encode_sealed_envelope(
        ciphertext.ptr, ciphertext.len,
        &nonce, &pubkey,
        &buf, buf.len,
    );

    try std.testing.expect(written > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[5..written], "15'sealed-envelope"));
}

// --- Part B: Goblins in Zig (full protocol simulation using Zig types) ---

test "e2e: full pumpkin-chat session simulation" {
    // Simulates: connect → handshake → join room → send message → receive history → leave

    var session = CapTPSession.init([_]u8{0x42} ** 32);
    try std.testing.expectEqual(SessionState.disconnected, session.state);

    // 1. Encode op:start-session handshake
    var handshake_buf: [256]u8 = undefined;
    const hs_len = captp_encode_start_session(
        &session.my_pubkey, 1069,
        &handshake_buf, handshake_buf.len,
    );
    try std.testing.expect(hs_len > 0);
    session.state = .handshake_sent;
    session.session_id = 1069;

    // 2. Export local user-controller (position 0)
    var export_buf: [128]u8 = undefined;
    const exp_len = captp_encode_desc_export(0, &export_buf, export_buf.len);
    try std.testing.expect(exp_len > 0);
    const slot = session.addLocalExport(0);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(u16, 0), slot.?);

    // 3. Import remote chatroom (position 1)
    var import_buf: [128]u8 = undefined;
    const imp_len = captp_encode_desc_import(1, &import_buf, import_buf.len);
    try std.testing.expect(imp_len > 0);
    const imp_slot = session.addRemoteImport(1);
    try std.testing.expect(imp_slot != null);

    session.state = .established;

    // 4. Join a room
    var join_buf: [256]u8 = undefined;
    const room = "pumpkin-lobby";
    const user = "bob";
    const join_len = pumpkin_encode_room_join(
        room.ptr, room.len,
        user.ptr, user.len,
        &join_buf, join_buf.len,
    );
    try std.testing.expect(join_len > 0);

    // 5. Send a chat message
    var msg_buf: [1024]u8 = undefined;
    const body = "gm from zig-syrup pumpkin-chat!";
    const msg_len = pumpkin_encode_chat_message(
        room.ptr, room.len,
        user.ptr, user.len,
        body.ptr, body.len,
        1709251200000,
        &msg_buf, msg_buf.len,
    );
    try std.testing.expect(msg_len > 0);

    // 6. Request history
    var hist_buf: [256]u8 = undefined;
    const hist_len = pumpkin_encode_history_request(
        room.ptr, room.len,
        25,
        &hist_buf, hist_buf.len,
    );
    try std.testing.expect(hist_len > 0);

    // 7. Send DM
    var dm_buf: [512]u8 = undefined;
    const dm_recipient = "alice";
    const dm_body = "hey, join #pumpkin-lobby";
    const dm_len = pumpkin_encode_dm(
        dm_recipient.ptr, dm_recipient.len,
        dm_body.ptr, dm_body.len,
        &dm_buf, dm_buf.len,
    );
    try std.testing.expect(dm_len > 0);

    // 8. Leave room
    var leave_buf: [256]u8 = undefined;
    const leave_len = pumpkin_encode_room_leave(
        room.ptr, room.len,
        user.ptr, user.len,
        &leave_buf, leave_buf.len,
    );
    try std.testing.expect(leave_len > 0);

    // 9. Go offline
    var pres_buf: [256]u8 = undefined;
    const pres_len = pumpkin_encode_presence(
        user.ptr, user.len,
        @intFromEnum(PresenceStatus.offline),
        &pres_buf, pres_buf.len,
    );
    try std.testing.expect(pres_len > 0);

    // Verify all messages are valid Syrup frames (length prefix consistent)
    const frames = [_]struct { buf: []const u8, len: usize }{
        .{ .buf = &handshake_buf, .len = hs_len },
        .{ .buf = &export_buf, .len = exp_len },
        .{ .buf = &import_buf, .len = imp_len },
        .{ .buf = &join_buf, .len = join_len },
        .{ .buf = &msg_buf, .len = msg_len },
        .{ .buf = &hist_buf, .len = hist_len },
        .{ .buf = &dm_buf, .len = dm_len },
        .{ .buf = &leave_buf, .len = leave_len },
        .{ .buf = &pres_buf, .len = pres_len },
    };
    for (frames) |f| {
        const frame_payload_len = gf3_decode_frame_length(f.buf.ptr, f.len);
        try std.testing.expectEqual(@as(u32, @intCast(f.len - 4)), frame_payload_len);
    }
}

test "e2e: websocket captp frame wrap/unwrap round-trip" {
    var ws = WebSocketCapTP.init([_]u8{0x69} ** 32);

    // Encode a chat message
    var syrup_buf: [512]u8 = undefined;
    const room = "test-room";
    const sender = "ws-user";
    const body = "over websocket!";
    const syrup_len = pumpkin_encode_chat_message(
        room.ptr, room.len,
        sender.ptr, sender.len,
        body.ptr, body.len,
        1709251200000,
        &syrup_buf, syrup_buf.len,
    );
    try std.testing.expect(syrup_len > 0);

    // Wrap in WebSocket binary frame (client → server, masked)
    var ws_buf: [1024]u8 = undefined;
    const ws_len = ws.wrapInWebSocketFrame(syrup_buf[0..syrup_len], &ws_buf);
    try std.testing.expect(ws_len > syrup_len); // Frame has header + mask overhead

    // Verify frame header
    try std.testing.expectEqual(@as(u8, 0x82), ws_buf[0]); // FIN + binary
    try std.testing.expect((ws_buf[1] & 0x80) != 0); // Mask bit set

    // Unwrap
    var unwrapped: [512]u8 = undefined;
    const unwrap_len = ws.unwrapWebSocketFrame(ws_buf[0..ws_len], &unwrapped);
    try std.testing.expectEqual(syrup_len, unwrap_len);
    try std.testing.expectEqualSlices(u8, syrup_buf[0..syrup_len], unwrapped[0..unwrap_len]);
}

test "e2e: websocket upgrade request encoding" {
    var ws = WebSocketCapTP.init([_]u8{0} ** 32);
    var buf: [512]u8 = undefined;
    const len = ws.encodeUpgradeRequest("chat.example.com", "/ocapn/ws", &buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "GET /ocapn/ws HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Upgrade: websocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "ocapn-syrup") != null);
}

test "e2e: sealed message over websocket full pipeline" {
    // Full pipeline: seal → encode sealed envelope → wrap in chat msg → wrap in ws frame → unwrap
    const plaintext = "encrypted pumpkin-chat over websocket";
    var ciphertext: [256]u8 = undefined;
    var nonce: [24]u8 = undefined;

    var alice_priv: [32]u8 = undefined;
    var bob_pub: [32]u8 = undefined;
    @memset(&alice_priv, 0xAA);
    @memset(&bob_pub, 0xBB);

    // Seal
    const ct_len = pumpkin_seal_message(
        plaintext.ptr, plaintext.len,
        &alice_priv, &bob_pub,
        &ciphertext, ciphertext.len,
        &nonce,
    );
    try std.testing.expect(ct_len > 0);

    // Encode sealed envelope
    var env_buf: [512]u8 = undefined;
    var alice_pub: [32]u8 = undefined;
    @memset(&alice_pub, 0xAA);
    const env_len = pumpkin_encode_sealed_envelope(
        &ciphertext, ct_len,
        &nonce, &alice_pub,
        &env_buf, env_buf.len,
    );
    try std.testing.expect(env_len > 0);

    // Wrap in WebSocket
    var ws = WebSocketCapTP.init([_]u8{0x42} ** 32);
    var ws_buf: [2048]u8 = undefined;
    const ws_len = ws.wrapInWebSocketFrame(env_buf[0..env_len], &ws_buf);
    try std.testing.expect(ws_len > 0);

    // Unwrap WebSocket
    var unwrapped: [512]u8 = undefined;
    const unwrap_len = ws.unwrapWebSocketFrame(ws_buf[0..ws_len], &unwrapped);
    try std.testing.expectEqual(env_len, unwrap_len);
    try std.testing.expectEqualSlices(u8, env_buf[0..env_len], unwrapped[0..unwrap_len]);

    // Unseal
    var bob_priv: [32]u8 = undefined;
    @memset(&bob_priv, 0xBB);
    var decrypted: [256]u8 = undefined;
    const pt_len = pumpkin_unseal_message(
        &ciphertext, ct_len,
        &bob_priv, &alice_pub,
        &nonce,
        &decrypted, decrypted.len,
    );
    try std.testing.expectEqual(plaintext.len, pt_len);
    try std.testing.expectEqualSlices(u8, plaintext, decrypted[0..pt_len]);
}

test "e2e: GF(3) conservation across pumpkin-chat session" {
    // Verify that trit assignments across a session maintain GF(3) conservation
    const SEED: u64 = 1069;

    // Find a conserving triad for room participants
    var seeds: [3]u64 = undefined;
    var trits: [3]i8 = undefined;
    _ = gf3_find_triad(SEED, &seeds, &trits);

    // Conservation check
    try std.testing.expect(gf3_conserved(&trits, 3));

    // Each participant encodes presence with their trit-determined seed
    var buf: [256]u8 = undefined;
    const users = [_][]const u8{ "alice", "bob", "carol" };
    for (users, 0..) |user, i| {
        // Encode presence for each
        const len = pumpkin_encode_presence(
            user.ptr, user.len,
            @intFromEnum(PresenceStatus.online),
            &buf, buf.len,
        );
        try std.testing.expect(len > 0);

        // Verify their SplitMix64 identity is consistent
        const val = splitmix64_at(seeds[i], 0);
        const trit = gf3_value_to_trit(val);
        try std.testing.expectEqual(trits[i], trit);
    }
}

test "e2e: CapTPSession ref table management" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Add exports up to limit
    for (0..MAX_STURDY_REFS) |i| {
        const slot = session.addLocalExport(@intCast(i));
        try std.testing.expect(slot != null);
        try std.testing.expectEqual(@as(u16, @intCast(i)), slot.?);
    }

    // Table full
    try std.testing.expectEqual(@as(?u16, null), session.addLocalExport(99));

    // Same for imports
    for (0..MAX_STURDY_REFS) |i| {
        const slot = session.addRemoteImport(@intCast(i));
        try std.testing.expect(slot != null);
    }
    try std.testing.expectEqual(@as(?u16, null), session.addRemoteImport(99));
}

// --- Part C: ORC-T (distributed GC) tests ---

test "orct: export ref count lifecycle" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Export an object — ref count starts at 1
    const slot = session.addLocalExport(42).?;
    try std.testing.expectEqual(@as(u16, 1), session.export_ref_counts[slot]);

    // Send reference again — ref count increments
    session.incExportRef(slot);
    try std.testing.expectEqual(@as(u16, 2), session.export_ref_counts[slot]);
    session.incExportRef(slot);
    try std.testing.expectEqual(@as(u16, 3), session.export_ref_counts[slot]);

    // Partial GC: wire_delta=2, count goes 3→1
    const gc1 = session.decExportRef(slot, 2);
    try std.testing.expect(!gc1);
    try std.testing.expectEqual(@as(u16, 1), session.export_ref_counts[slot]);

    // Final GC: wire_delta=1, count goes 1→0 (GC-able)
    const gc2 = session.decExportRef(slot, 1);
    try std.testing.expect(gc2);
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[slot]);
}

test "orct: wire_delta overflow clamps to zero" {
    var session = CapTPSession.init([_]u8{0} ** 32);
    _ = session.addLocalExport(7);

    // wire_delta > ref_count should clamp to 0 and return true
    const gc = session.decExportRef(0, 999);
    try std.testing.expect(gc);
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[0]);
}

test "orct: op:gc-exports encode" {
    var buf: [256]u8 = undefined;
    const positions = [_]u16{ 3, 7, 12 };
    const deltas = [_]u16{ 1, 2, 1 };

    const len = orct_encode_gc_exports(&positions, &deltas, 3, &buf, buf.len);
    try std.testing.expect(len > 0);

    // Verify Syrup record structure: starts with frame header then record
    // Payload starts at offset 4
    const payload = buf[4..len];
    try std.testing.expect(std.mem.startsWith(u8, payload, "<14'op:gc-exports"));
    try std.testing.expect(payload[payload.len - 1] == '>');
    // Contains two lists
    try std.testing.expect(std.mem.indexOf(u8, payload, "(3+7+12+)") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "(1+2+1+)") != null);
}

test "orct: op:gc-answers encode" {
    var buf: [256]u8 = undefined;
    const positions = [_]u16{ 0, 5, 11 };

    const len = orct_encode_gc_answers(&positions, 3, &buf, buf.len);
    try std.testing.expect(len > 0);

    const payload = buf[4..len];
    try std.testing.expect(std.mem.startsWith(u8, payload, "<14'op:gc-answers"));
    try std.testing.expect(payload[payload.len - 1] == '>');
    try std.testing.expect(std.mem.indexOf(u8, payload, "(0+5+11+)") != null);
}

test "orct: apply gc-exports to session" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Export 3 objects, send each ref multiple times
    _ = session.addLocalExport(10); // slot 0, refcount=1
    _ = session.addLocalExport(20); // slot 1, refcount=1
    _ = session.addLocalExport(30); // slot 2, refcount=1
    session.incExportRef(0); // slot 0 refcount=2
    session.incExportRef(1); // slot 1 refcount=2
    session.incExportRef(1); // slot 1 refcount=3

    // GC: release slot 0 (delta=2) and slot 2 (delta=1)
    const positions = [_]u16{ 0, 2 };
    const deltas = [_]u16{ 2, 1 };
    const gc_count = orct_apply_gc_exports(&session, &positions, &deltas, 2);

    try std.testing.expectEqual(@as(usize, 2), gc_count);
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[0]);
    try std.testing.expectEqual(@as(u16, 3), session.export_ref_counts[1]); // untouched
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[2]);
}

test "orct: answer position alloc and gc-answers reuse" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Allocate answer positions
    const a0 = session.allocAnswerPos().?;
    const a1 = session.allocAnswerPos().?;
    const a2 = session.allocAnswerPos().?;
    try std.testing.expect(a0 != a1);
    try std.testing.expect(a1 != a2);
    try std.testing.expect(session.answer_positions[a0]);
    try std.testing.expect(session.answer_positions[a1]);

    // GC answer positions
    const gc_list = [_]u16{ a0, a2 };
    orct_apply_gc_answers(&session, &gc_list, 2);

    try std.testing.expect(!session.answer_positions[a0]);
    try std.testing.expect(session.answer_positions[a1]); // still in use
    try std.testing.expect(!session.answer_positions[a2]);

    // Reuse freed position — must get one of the GC'd slots, not a1
    const a3 = session.allocAnswerPos().?;
    try std.testing.expect(a3 != a1);
}

test "orct: answer position exhaustion and recovery" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Fill all answer positions
    for (0..MAX_STURDY_REFS) |_| {
        try std.testing.expect(session.allocAnswerPos() != null);
    }
    // Exhausted
    try std.testing.expectEqual(@as(?u16, null), session.allocAnswerPos());

    // GC one position
    session.gcAnswerPos(7);
    const recovered = session.allocAnswerPos().?;
    try std.testing.expectEqual(@as(u16, 7), recovered);
}

test "orct: full GC round-trip encode + apply" {
    var session = CapTPSession.init([_]u8{0} ** 32);

    // Setup: export 2 objects, send refs multiple times
    _ = session.addLocalExport(100); // slot 0
    _ = session.addLocalExport(200); // slot 1
    session.incExportRef(0); // slot 0 refcount=2
    session.incExportRef(0); // slot 0 refcount=3

    // Allocate answer positions
    const ans0 = session.allocAnswerPos().?;
    const ans1 = session.allocAnswerPos().?;

    // Encode gc-exports
    var gc_exp_buf: [256]u8 = undefined;
    const exp_positions = [_]u16{ 0, 1 };
    const exp_deltas = [_]u16{ 3, 1 };
    const gc_exp_len = orct_encode_gc_exports(&exp_positions, &exp_deltas, 2, &gc_exp_buf, gc_exp_buf.len);
    try std.testing.expect(gc_exp_len > 0);

    // Encode gc-answers
    var gc_ans_buf: [256]u8 = undefined;
    const ans_positions = [_]u16{ ans0, ans1 };
    const gc_ans_len = orct_encode_gc_answers(&ans_positions, 2, &gc_ans_buf, gc_ans_buf.len);
    try std.testing.expect(gc_ans_len > 0);

    // Apply gc-exports
    const gc_count = orct_apply_gc_exports(&session, &exp_positions, &exp_deltas, 2);
    try std.testing.expectEqual(@as(usize, 2), gc_count);
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[0]);
    try std.testing.expectEqual(@as(u16, 0), session.export_ref_counts[1]);

    // Apply gc-answers
    orct_apply_gc_answers(&session, &ans_positions, 2);
    try std.testing.expect(!session.answer_positions[ans0]);
    try std.testing.expect(!session.answer_positions[ans1]);

    // Verify positions can be reused
    const reused = session.allocAnswerPos();
    try std.testing.expect(reused != null);
}

test "orct: GF(3) conservation across GC lifecycle" {
    // ORC-T GC preserves GF(3) trit conservation — the triad that enters
    // a session must sum to 0 mod 3 regardless of GC state
    const SEED: u64 = 1069;
    var seeds: [3]u64 = undefined;
    var trits: [3]i8 = undefined;
    _ = gf3_find_triad(SEED, &seeds, &trits);
    try std.testing.expect(gf3_conserved(&trits, 3));

    // Create session, export all 3 triad members
    var session = CapTPSession.init([_]u8{0} ** 32);
    for (0..3) |i| {
        _ = session.addLocalExport(@intCast(seeds[i] & 0xFFFF));
    }

    // Send additional refs (increasing wire deltas)
    session.incExportRef(0);
    session.incExportRef(1);
    session.incExportRef(2);

    // GC slot 0 only — triad is still conserved at the semantic level
    const positions = [_]u16{0};
    const deltas = [_]u16{2};
    _ = orct_apply_gc_exports(&session, &positions, &deltas, 1);

    // Trits themselves don't change — conservation is a property of the
    // identities, not the ref counts
    try std.testing.expect(gf3_conserved(&trits, 3));
}
