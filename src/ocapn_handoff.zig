//! OCapN 3-vat handoff protocol.
//!
//! A (gifter) introduces B (receiver) to C (exporter). Per Spritely Racket
//! reference impl (goblins/ocapn/captp.rkt:157–253, 888–1135):
//!
//!   <desc:handoff-give
//!      recipient-key       bytes    ; B's session handoff-pubkey
//!      exporter-location   <ocapn-node ...>
//!      session             bytes    ; A↔C session-name
//!      gifter-side         bytes    ; A's side in A↔C
//!      gift-id>            bytes|int
//!
//!   <desc:handoff-receive
//!      receiving-session   bytes    ; B↔C session-name
//!      receiving-side      bytes    ; B's side
//!      handoff-count       int      ; monotonic per (B,C) session
//!      signed-give>        <desc:sig-envelope <handoff-give ...> <sig>>
//!
//!   <desc:sig-envelope object signature>
//!
//! Signatures are Ed25519 over the Syrup-canonical encoding of the inner
//! record bytes — no domain-separator, no hash. The signing key is the
//! *per-session* handoff keypair announced in op:start-session, not the
//! long-term machine key.

const std = @import("std");
const syrup = @import("syrup");
const location_mod = @import("ocapn_location");
const handshake = @import("ocapn_handshake");
const Ed25519 = std.crypto.sign.Ed25519;
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

// 0.16 compat: Managed ArrayList lost its .writer() method.
fn fmtAppend(list: *ByteList, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [128]u8 = undefined;
    try list.appendSlice(try std.fmt.bufPrint(&tmp, fmt, args));
}

pub const GIFT_ID_LEN: usize = 32;

pub const HandoffGive = struct {
    recipient_key: [32]u8, // B's session pubkey
    exporter_location: location_mod.Location, // C
    session: []const u8, // A↔C session-name
    gifter_side: []const u8, // A's side in A↔C
    gift_id: [GIFT_ID_LEN]u8,

    pub fn encodeAlloc(self: HandoffGive, allocator: Allocator) ![]u8 {
        var out = ByteList.init(allocator);
        defer out.deinit();
        try out.appendSlice("<17'desc:handoff-give");

        // recipient-key as 32-byte bytestring
        try out.appendSlice("32:");
        try out.appendSlice(&self.recipient_key);

        // exporter-location
        const loc_bytes = try self.exporter_location.encodeAlloc(allocator);
        defer allocator.free(loc_bytes);
        try out.appendSlice(loc_bytes);

        // session
        try fmtAppend(&out, "{d}:", .{self.session.len});
        try out.appendSlice(self.session);

        // gifter-side
        try fmtAppend(&out, "{d}:", .{self.gifter_side.len});
        try out.appendSlice(self.gifter_side);

        // gift-id
        try fmtAppend(&out, "{d}:", .{self.gift_id.len});
        try out.appendSlice(&self.gift_id);

        try out.append('>');
        return out.toOwnedSlice();
    }
};

pub const HandoffReceive = struct {
    receiving_session: []const u8,
    receiving_side: []const u8,
    handoff_count: u64,
    signed_give: []const u8, // pre-encoded sig-envelope wrapping a handoff-give

    pub fn encodeAlloc(self: HandoffReceive, allocator: Allocator) ![]u8 {
        var out = ByteList.init(allocator);
        defer out.deinit();
        try out.appendSlice("<20'desc:handoff-receive");

        try fmtAppend(&out, "{d}:", .{self.receiving_session.len});
        try out.appendSlice(self.receiving_session);

        try fmtAppend(&out, "{d}:", .{self.receiving_side.len});
        try out.appendSlice(self.receiving_side);

        try fmtAppend(&out, "{d}+", .{self.handoff_count});

        try out.appendSlice(self.signed_give);

        try out.append('>');
        return out.toOwnedSlice();
    }
};

/// Wrap (object-bytes, signature-bytes) as a desc:sig-envelope record.
pub fn encodeSigEnvelope(
    allocator: Allocator,
    inner_record_bytes: []const u8,
    sig_bytes: [Ed25519.Signature.encoded_length]u8,
) ![]u8 {
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<17'desc:sig-envelope");
    try out.appendSlice(inner_record_bytes);

    // Signature as a record: <sig scheme bytes>
    try out.appendSlice("<3'sig");
    try out.appendSlice("7'ed25519");
    try fmtAppend(&out, "{d}:", .{sig_bytes.len});
    try out.appendSlice(&sig_bytes);
    try out.append('>');

    try out.append('>');
    return out.toOwnedSlice();
}

/// Sign a handoff-give with A's per-session handoff key, return a sig-envelope
/// containing the signed give record.
pub fn signGive(
    allocator: Allocator,
    gifter_session_keypair: handshake.KeyPair,
    give: HandoffGive,
) ![]u8 {
    const give_bytes = try give.encodeAlloc(allocator);
    defer allocator.free(give_bytes);

    const kp = Ed25519.KeyPair{
        .public_key = try Ed25519.PublicKey.fromBytes(gifter_session_keypair.pub_key),
        .secret_key = gifter_session_keypair.secret,
    };
    const sig = try kp.sign(give_bytes, null);
    return encodeSigEnvelope(allocator, give_bytes, sig.toBytes());
}

/// Sign a handoff-receive with B's per-session handoff key for B↔C.
pub fn signReceive(
    allocator: Allocator,
    receiver_session_keypair: handshake.KeyPair,
    recv: HandoffReceive,
) ![]u8 {
    const recv_bytes = try recv.encodeAlloc(allocator);
    defer allocator.free(recv_bytes);

    const kp = Ed25519.KeyPair{
        .public_key = try Ed25519.PublicKey.fromBytes(receiver_session_keypair.pub_key),
        .secret_key = receiver_session_keypair.secret,
    };
    const sig = try kp.sign(recv_bytes, null);
    return encodeSigEnvelope(allocator, recv_bytes, sig.toBytes());
}

/// C-side verification: given the signed-give sig-envelope and expected
/// recipient pubkey (B's session pubkey as seen in B↔C), verify.
pub fn verifyGive(
    envelope: syrup.Value,
    signer_pubkey: [32]u8,
    allocator: Allocator,
) !bool {
    if (envelope != .record) return error.InvalidFormat;
    const r = envelope.record;
    if (r.label.* != .symbol) return error.InvalidFormat;
    if (!std.mem.eql(u8, r.label.symbol, "desc:sig-envelope")) return error.InvalidFormat;
    if (r.fields.len < 2) return error.InvalidFormat;

    // Re-encode the inner give record to canonical bytes.
    const inner = r.fields[0];
    const inner_bytes = try inner.encodeAlloc(allocator);
    defer allocator.free(inner_bytes);

    if (r.fields[1] != .record) return error.InvalidFormat;
    const sig_r = r.fields[1].record;
    if (sig_r.fields.len < 2) return error.InvalidFormat;
    if (sig_r.fields[1] != .bytes) return error.InvalidFormat;
    if (sig_r.fields[1].bytes.len != Ed25519.Signature.encoded_length) return error.InvalidFormat;

    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_bytes, sig_r.fields[1].bytes);
    const signature = Ed25519.Signature.fromBytes(sig_bytes);
    const pk = try Ed25519.PublicKey.fromBytes(signer_pubkey);
    signature.verify(inner_bytes, pk) catch return false;
    return true;
}

/// Generate a fresh 32-byte gift-id.
pub fn freshGiftId() [GIFT_ID_LEN]u8 {
    var out: [GIFT_ID_LEN]u8 = undefined;
    std.crypto.random.bytes(&out);
    return out;
}

// ---- Tests ------------------------------------------------------------------

test "handoff-give encodes and parses as record" {
    const allocator = std.testing.allocator;
    var rk: [32]u8 = undefined;
    for (&rk, 0..) |*b, i| b.* = @intCast(i);
    var gift: [GIFT_ID_LEN]u8 = undefined;
    for (&gift, 0..) |*b, i| b.* = @intCast(0xFF - i);

    const give = HandoffGive{
        .recipient_key = rk,
        .exporter_location = .{ .netlayer = .tcp, .designator = &[_]u8{ 7, 7, 7 } },
        .session = "sess-ac",
        .gifter_side = "a-side",
        .gift_id = gift,
    };
    const bytes = try give.encodeAlloc(allocator);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("desc:handoff-give", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 5), v.record.fields.len);
}

test "sign + verify handoff-give end-to-end" {
    const allocator = std.testing.allocator;
    const kp = try handshake.KeyPair.generate();

    var rk: [32]u8 = undefined;
    for (&rk, 0..) |*b, i| b.* = @intCast(i * 2);
    const give = HandoffGive{
        .recipient_key = rk,
        .exporter_location = .{ .netlayer = .tcp, .designator = &[_]u8{ 1, 2, 3 } },
        .session = "sess-ac",
        .gifter_side = "a",
        .gift_id = freshGiftId(),
    };
    const envelope_bytes = try signGive(allocator, kp, give);
    defer allocator.free(envelope_bytes);

    var parser = syrup.Parser.init(envelope_bytes, allocator);
    var env_val = try parser.parse();
    defer env_val.deinitAll(allocator);

    const ok = try verifyGive(env_val, kp.pub_key, allocator);
    try std.testing.expect(ok);
}

// Square C — handoff sign/verify holds for every gift in the 70-color CGT
// corpus. Each gift-id is derived deterministically from the corpus index
// (SHA-256 of `"cgt-gift:" ++ u32-BE(i)`), giving 70 distinct, reproducible
// envelopes through the same A-side keypair. If any single sign/verify
// fails, the per-session ed25519 signing path is broken under load and
// cross-runtime handoff (Square C of the path-invariance diagram) cannot
// hold. Test is local: it does not need a remote peer.
test "Square C — corpus of 70 handoff-give envelopes all sign/verify" {
    const allocator = std.testing.allocator;
    const kp = try handshake.KeyPair.generate();

    // Recipient pubkey is fixed within the corpus (same B across all gifts);
    // only the gift-id varies. This isolates the gift-id channel.
    var rk: [32]u8 = undefined;
    std.crypto.random.bytes(&rk);

    // Use a printable string designator (Racket-aligned), not raw bytes,
    // since the encoder now emits Syrup string for designator.
    const exporter_designator = "cgt-exporter-onion-base32-stub-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    var i: u32 = 0;
    while (i < 70) : (i += 1) {
        var seed: [12]u8 = undefined;
        @memcpy(seed[0..8], "cgt-gift");
        std.mem.writeInt(u32, seed[8..12], i, .big);

        var gift: [GIFT_ID_LEN]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&seed, &gift, .{});

        const give = HandoffGive{
            .recipient_key = rk,
            .exporter_location = .{
                .netlayer = .onion,
                .designator = exporter_designator,
            },
            .session = "sess-ac",
            .gifter_side = "a",
            .gift_id = gift,
        };

        const envelope_bytes = try signGive(allocator, kp, give);
        defer allocator.free(envelope_bytes);

        var parser = syrup.Parser.init(envelope_bytes, allocator);
        var env_val = try parser.parse();
        defer env_val.deinitAll(allocator);

        const ok = try verifyGive(env_val, kp.pub_key, allocator);
        std.testing.expect(ok) catch |e| {
            std.debug.print("Square C fail at corpus idx={d}\n", .{i});
            return e;
        };
    }
}
