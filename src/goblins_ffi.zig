//! goblins_ffi.zig — C ABI bridge for Guile Goblins → zig-syrup
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
const compat = @import("compat");
const passport = @import("passport");
const ripser = @import("ripser");
const syrup = @import("syrup");
const message_frame = @import("message_frame");

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
// 5. TCP Transport — send/recv Syrup-framed messages to Nashator
// ============================================================================

const tcp_transport = @import("tcp_transport.zig");

/// Connection pool: up to 16 concurrent connections.
/// Handle = index into pool. -1 = invalid.
const MAX_CONNECTIONS = 16;
var connection_pool: [MAX_CONNECTIONS]?tcp_transport.Connection = @splat(null);

fn findFreeSlot() ?usize {
    for (0..MAX_CONNECTIONS) |i| {
        if (connection_pool[i] == null) return i;
    }
    return null;
}

/// Connect to host:port. Returns handle (0..15) or -1 on error.
/// host must be a null-terminated C string (IPv4 address or "127.0.0.1").
export fn gf3_tcp_connect(host: [*:0]const u8, port: u16) i32 {
    const slot = findFreeSlot() orelse return -1;

    // Parse address
    const host_slice = std.mem.sliceTo(host, 0);
    const addr = compat.Address.parseIp4(host_slice, port) catch return -1;

    // Connect
    const stream = compat.tcpConnectToAddress(addr) catch return -1;
    connection_pool[slot] = tcp_transport.Connection.init(std.heap.page_allocator, stream);

    return @intCast(slot);
}

/// Send a length-prefixed frame. Returns 0 on success, -1 on error.
export fn gf3_tcp_send_frame(handle: i32, payload: [*]const u8, payload_len: usize) i32 {
    if (handle < 0 or handle >= MAX_CONNECTIONS) return -1;
    const h: usize = @intCast(handle);
    var conn = &(connection_pool[h] orelse return -1);
    conn.send(payload[0..payload_len]) catch return -1;
    return 0;
}

/// Receive a length-prefixed frame. Blocks until complete.
/// Writes payload to out_buf, returns payload length, or -1 on error.
export fn gf3_tcp_recv_frame(handle: i32, out_buf: [*]u8, out_buf_len: usize) i32 {
    if (handle < 0 or handle >= MAX_CONNECTIONS) return -1;
    const h: usize = @intCast(handle);
    var conn = &(connection_pool[h] orelse return -1);
    const payload = conn.recv() catch return -1;
    if (payload.len > out_buf_len) return -1;
    @memcpy(out_buf[0..payload.len], payload);
    return @intCast(payload.len);
}

/// Close a connection and free the handle.
export fn gf3_tcp_close(handle: i32) void {
    if (handle < 0 or handle >= MAX_CONNECTIONS) return;
    const h: usize = @intCast(handle);
    if (connection_pool[h]) |*conn| {
        conn.close();
        connection_pool[h] = null;
    }
}

/// Check if a connection handle is still active.
export fn gf3_tcp_connected(handle: i32) bool {
    if (handle < 0 or handle >= MAX_CONNECTIONS) return false;
    const h: usize = @intCast(handle);
    const conn = connection_pool[h] orelse return false;
    return conn.isConnected();
}

/// Send a Syrup-encoded CapTP deliver message and receive the response.
/// Convenience function: encodes game-spec, sends frame, receives response.
///
/// tool_name: null-terminated C string (e.g., "nashator_solve")
/// game_json: null-terminated JSON string of game-spec
/// out_buf: buffer for response payload
/// out_buf_len: size of out_buf
///
/// Returns response payload length, or -1 on error.
export fn gf3_captp_rpc(
    handle: i32,
    tool_name: [*:0]const u8,
    game_json: [*]const u8,
    game_json_len: usize,
    out_buf: [*]u8,
    out_buf_len: usize,
) i32 {
    if (handle < 0 or handle >= MAX_CONNECTIONS) return -1;
    const h: usize = @intCast(handle);
    var conn = &(connection_pool[h] orelse return -1);

    // Build a minimal JSON-RPC request frame:
    // {"jsonrpc":"2.0","method":"<tool_name>","params":<game_json>,"id":1}
    var req_buf: [65536]u8 = undefined;
    const tool_slice = std.mem.sliceTo(tool_name, 0);
    const game_slice = game_json[0..game_json_len];

    const req = std.fmt.bufPrint(&req_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s},\"id\":1}}", .{ tool_slice, game_slice }) catch return -1;

    // Send as length-prefixed frame
    conn.send(req) catch return -1;

    // Receive response frame
    const response = conn.recv() catch return -1;
    if (response.len > out_buf_len) return -1;
    @memcpy(out_buf[0..response.len], response);

    return @intCast(response.len);
}

// ============================================================================
// 6. Vat runtime — Lokke (Clojure-on-Guile) → Guile Goblins reachability
// ============================================================================
//
// The same Vat handle is addressable from:
//   - Lokke, via (lokke ffi)        : (define vat (gf3_vat_create 1069))
//   - Guile Goblins, via FFI        : (gf3_vat_send vat target sel payload)
//   - Hoot WASM imports             : (import "env" "gf3_vat_send" ...)
//
// Behaviors crossing the FFI are C-callback shaped: the foreign caller
// supplies a `handle_cb` function pointer that the vat invokes per turn.

const vat_mod = @import("vat.zig");
const cap_mod = @import("cap.zig");

const MAX_VATS = 8;
var vat_pool: [MAX_VATS]?vat_mod.Vat = @splat(null);

fn findVatSlot() ?usize {
    for (0..MAX_VATS) |i| if (vat_pool[i] == null) return i;
    return null;
}

/// Create a vat with id `seed`. Returns handle (0..7) or -1.
export fn gf3_vat_create(seed: u32) i32 {
    const slot = findVatSlot() orelse return -1;
    vat_pool[slot] = vat_mod.Vat.init(std.heap.page_allocator, seed);
    return @intCast(slot);
}

/// Foreign behavior: call out to C handler on each turn.
const ForeignBehavior = struct {
    handle_cb: *const fn (state: ?*anyopaque, payload: [*]const u8, len: usize) callconv(.c) i32,
    state: ?*anyopaque,
    pub fn handle(self: *ForeignBehavior, _: *vat_mod.Vat, m: vat_mod.Message) !vat_mod.Become {
        const rc = self.handle_cb(self.state, m.payload.ptr, m.payload.len);
        return if (rc == 0) .same else .terminate;
    }
};

/// Spawn a foreign-callback actor. `handle_cb` is invoked per turn with the
/// payload bytes; return 0 to keep alive, non-zero to terminate.
/// Returns packed CapId (vat<<32 | actor) or 0 on error.
export fn gf3_vat_spawn_foreign(
    vat_handle: i32,
    handle_cb: *const fn (state: ?*anyopaque, payload: [*]const u8, len: usize) callconv(.c) i32,
    state: ?*anyopaque,
) u64 {
    if (vat_handle < 0 or vat_handle >= MAX_VATS) return 0;
    const h: usize = @intCast(vat_handle);
    var v = &(vat_pool[h] orelse return 0);
    const c = v.spawn(ForeignBehavior, .{ .handle_cb = handle_cb, .state = state }) catch return 0;
    return c.target;
}

/// Eventual send. `target` is the packed CapId from spawn; `facet_mask`
/// permits foreign callers to narrow on the wire. Returns 0/-1.
export fn gf3_vat_send(
    vat_handle: i32,
    target: u64,
    facet_mask: u64,
    selector: u8,
    payload: [*]const u8,
    payload_len: usize,
) i32 {
    if (vat_handle < 0 or vat_handle >= MAX_VATS or selector >= 64) return -1;
    const h: usize = @intCast(vat_handle);
    var v = &(vat_pool[h] orelse return -1);
    const sender = cap_mod.Capability{ .target = 0, .facet = cap_mod.FACET_FULL };
    const to = cap_mod.Capability{
        .target = target,
        .facet = facet_mask,
        .sender = 0,
    };
    v.send(sender, to, @intCast(selector), payload[0..payload_len]) catch return -1;
    return 0;
}

/// Rights amplification union — both must name the same target.
/// Returns combined facet mask, or 0 on error.
export fn gf3_vat_amplify(target_a: u64, mask_a: u64, target_b: u64, mask_b: u64) u64 {
    if (target_a != target_b) return 0;
    return mask_a | mask_b;
}

/// Facet narrow — intersect mask with `allowed`.
export fn gf3_vat_facet_narrow(facet_mask: u64, allowed: u64) u64 {
    return facet_mask & allowed;
}

/// Drain pending mailboxes up to `max_turns`. Returns turns run, or -1.
export fn gf3_vat_quiesce(vat_handle: i32, max_turns: u32) i32 {
    if (vat_handle < 0 or vat_handle >= MAX_VATS) return -1;
    const h: usize = @intCast(vat_handle);
    var v = &(vat_pool[h] orelse return -1);
    const n = v.quiesce(@intCast(max_turns)) catch return -1;
    return @intCast(n);
}

/// Close and free vat handle.
export fn gf3_vat_close(vat_handle: i32) void {
    if (vat_handle < 0 or vat_handle >= MAX_VATS) return;
    const h: usize = @intCast(vat_handle);
    if (vat_pool[h]) |*v| {
        v.deinit();
        vat_pool[h] = null;
    }
}

// ============================================================================
// 7. Cross-language verification
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
