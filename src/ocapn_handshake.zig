//! OCapN op:start-session handshake — spec-conformant encoder + Ed25519 sigs.
//!
//! Wire format per OCapN CapTP §start-session:
//!   <op:start-session captp-version session-pubkey
//!                     acceptable-location acceptable-location-signature>
//!
//! Where:
//!   captp-version           = string, e.g. "1.0"
//!   session-pubkey          = bytestring (32-byte Ed25519 pubkey)
//!   acceptable-location     = <ocapn-node netlayer designator hints> record
//!   acceptable-location-sig = <desc:sig-envelope scheme sig-bytes> record
//!
//! The signature covers the canonical Syrup encoding of the location record,
//! domain-separated with the literal bytestring "captp-location-sig:".

const std = @import("std");
const syrup = @import("syrup");
const location_mod = @import("ocapn_location");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const CAPTP_VERSION: []const u8 = "1.0";
pub const SIG_DOMAIN: []const u8 = "captp-location-sig:";
pub const SESSION_ID_PROTO: []const u8 = "prot0";

// ---- gcrypt s-expression format for Ed25519 keys and signatures ----
//
// Spec format (Syrup-encoded gcrypt s-expressions):
//   pubkey:  [public-key [ecc [curve Ed25519] [flags eddsa] [q <32B>]]]
//   sig:     [sig-val [eddsa [r <32B>] [s <32B>]]]
//
// Public Identifier = SHA256(SHA256(canonical_syrup(pubkey_sexp)))
// Session ID = SHA256(SHA256("prot0" || sort(id_a, id_b)))

/// Encode a 32-byte Ed25519 public key as the gcrypt-style Syrup s-expression.
/// Returns caller-owned bytes.
pub fn encodeGcryptPubkey(allocator: Allocator, pub_key: [32]u8) ![]u8 {
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:");
    try out.appendSlice(&pub_key);
    try out.appendSlice("]]]");
    return out.toOwnedSlice();
}

/// Decode a gcrypt-style Syrup pubkey s-expression back to raw 32 bytes.
/// Expects a Syrup list value: [public-key [ecc ... [q <32B>]]]
pub fn decodeGcryptPubkey(v: syrup.Value) ![32]u8 {
    if (v != .list) return error.InvalidPubkey;
    const items = v.list;
    if (items.len < 2) return error.InvalidPubkey;
    if (items[0] != .symbol or !std.mem.eql(u8, items[0].symbol, "public-key"))
        return error.InvalidPubkey;
    if (items[1] != .list) return error.InvalidPubkey;
    const ecc = items[1].list;
    // Find the [q <bytes>] sub-list.
    for (ecc) |elem| {
        if (elem != .list) continue;
        const sub = elem.list;
        if (sub.len >= 2 and sub[0] == .symbol and std.mem.eql(u8, sub[0].symbol, "q")) {
            if (sub[1] != .bytes or sub[1].bytes.len != 32) return error.InvalidPubkey;
            var result: [32]u8 = undefined;
            @memcpy(&result, sub[1].bytes);
            return result;
        }
    }
    return error.InvalidPubkey;
}

/// Encode an Ed25519 signature (64 bytes) as the gcrypt-style Syrup s-expression.
/// First 32 bytes = R, second 32 bytes = S.
pub fn encodeGcryptSignature(allocator: Allocator, sig_bytes: [64]u8) ![]u8 {
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("[7'sig-val[5'eddsa[1'r32:");
    try out.appendSlice(sig_bytes[0..32]);
    try out.appendSlice("][1's32:");
    try out.appendSlice(sig_bytes[32..64]);
    try out.appendSlice("]]]");
    return out.toOwnedSlice();
}

/// Decode a gcrypt-style Syrup signature s-expression back to raw 64 bytes.
pub fn decodeGcryptSignature(v: syrup.Value) ![64]u8 {
    if (v != .list) return error.InvalidSignature;
    const items = v.list;
    if (items.len < 2) return error.InvalidSignature;
    if (items[0] != .symbol or !std.mem.eql(u8, items[0].symbol, "sig-val"))
        return error.InvalidSignature;
    if (items[1] != .list) return error.InvalidSignature;
    const eddsa = items[1].list;
    var result: [64]u8 = undefined;
    var found_r = false;
    var found_s = false;
    for (eddsa) |elem| {
        if (elem != .list) continue;
        const sub = elem.list;
        if (sub.len < 2 or sub[0] != .symbol) continue;
        if (std.mem.eql(u8, sub[0].symbol, "r") and sub[1] == .bytes and sub[1].bytes.len == 32) {
            @memcpy(result[0..32], sub[1].bytes);
            found_r = true;
        }
        if (std.mem.eql(u8, sub[0].symbol, "s") and sub[1] == .bytes and sub[1].bytes.len == 32) {
            @memcpy(result[32..64], sub[1].bytes);
            found_s = true;
        }
    }
    if (!found_r or !found_s) return error.InvalidSignature;
    return result;
}

/// Derive the Public Identifier from a 32-byte Ed25519 public key.
/// public_id = SHA256(SHA256(canonical_syrup(pubkey_sexp)))
pub fn derivePublicId(allocator: Allocator, pub_key: [32]u8) ![32]u8 {
    const sexp_bytes = try encodeGcryptPubkey(allocator, pub_key);
    defer allocator.free(sexp_bytes);
    var h1: [32]u8 = undefined;
    Sha256.hash(sexp_bytes, &h1, .{});
    var h2: [32]u8 = undefined;
    Sha256.hash(&h1, &h2, .{});
    return h2;
}

/// Derive the Session ID from two Public Identifiers.
/// session_id = SHA256(SHA256("prot0" || sort(id_a, id_b)))
pub fn deriveSessionId(id_a: [32]u8, id_b: [32]u8) [32]u8 {
    // Sort by lexicographic octet order.
    const order = std.mem.order(u8, &id_a, &id_b);
    const first = if (order == .lt or order == .eq) id_a else id_b;
    const second = if (order == .lt or order == .eq) id_b else id_a;

    var hasher = Sha256.init(.{});
    hasher.update(SESSION_ID_PROTO);
    hasher.update(&first);
    hasher.update(&second);
    const h1 = hasher.finalResult();
    var h2: [32]u8 = undefined;
    Sha256.hash(&h1, &h2, .{});
    return h2;
}

pub const Signature = struct {
    scheme: []const u8 = "ed25519",
    bytes: [Ed25519.Signature.encoded_length]u8,

    /// Encode as `<desc:sig-envelope object-bytes sig-val-sexp>` using the
    /// gcrypt s-expression format for the signature value.
    pub fn encodeAlloc(self: Signature, allocator: Allocator) ![]u8 {
        const sig_sexp = try encodeGcryptSignature(allocator, self.bytes);
        defer allocator.free(sig_sexp);
        var out = ByteList.init(allocator);
        defer out.deinit();
        try out.appendSlice("<17'desc:sig-envelope");
        try std.fmt.format(out.writer(), "{d}'", .{self.scheme.len});
        try out.appendSlice(self.scheme);
        try out.appendSlice(sig_sexp);
        try out.append('>');
        return out.toOwnedSlice();
    }
};

pub const KeyPair = struct {
    pub_key: [Ed25519.PublicKey.encoded_length]u8,
    secret: Ed25519.SecretKey,

    pub fn generate() !KeyPair {
        const kp = Ed25519.KeyPair.generate();
        return KeyPair{
            .pub_key = kp.public_key.toBytes(),
            .secret = kp.secret_key,
        };
    }

    pub fn fromSecretBytes(secret_bytes: [Ed25519.SecretKey.encoded_length]u8) !KeyPair {
        const sk = try Ed25519.SecretKey.fromBytes(secret_bytes);
        const pk = try sk.publicKey();
        return KeyPair{ .pub_key = pk.toBytes(), .secret = sk };
    }
};

/// Sign a location record under the captp-location-sig domain.
pub fn signLocation(
    kp: KeyPair,
    loc: location_mod.Location,
    allocator: Allocator,
) !Signature {
    const loc_bytes = try loc.encodeAlloc(allocator);
    defer allocator.free(loc_bytes);

    var msg = try allocator.alloc(u8, SIG_DOMAIN.len + loc_bytes.len);
    defer allocator.free(msg);
    @memcpy(msg[0..SIG_DOMAIN.len], SIG_DOMAIN);
    @memcpy(msg[SIG_DOMAIN.len..], loc_bytes);

    const kp_real = Ed25519.KeyPair{
        .public_key = try Ed25519.PublicKey.fromBytes(kp.pub_key),
        .secret_key = kp.secret,
    };
    const sig = try kp_real.sign(msg, null);
    return Signature{ .bytes = sig.toBytes() };
}

pub fn verifyLocation(
    pub_key: [Ed25519.PublicKey.encoded_length]u8,
    loc: location_mod.Location,
    sig: Signature,
    allocator: Allocator,
) !bool {
    const loc_bytes = try loc.encodeAlloc(allocator);
    defer allocator.free(loc_bytes);

    var msg = try allocator.alloc(u8, SIG_DOMAIN.len + loc_bytes.len);
    defer allocator.free(msg);
    @memcpy(msg[0..SIG_DOMAIN.len], SIG_DOMAIN);
    @memcpy(msg[SIG_DOMAIN.len..], loc_bytes);

    const pk = try Ed25519.PublicKey.fromBytes(pub_key);
    const signature = Ed25519.Signature.fromBytes(sig.bytes);
    signature.verify(msg, pk) catch return false;
    return true;
}

/// Encode a spec-conformant op:start-session message as raw Syrup bytes.
/// Caller owns the returned slice.
pub fn encodeStartSession(
    allocator: Allocator,
    session_pubkey: [32]u8,
    location: location_mod.Location,
    signature: Signature,
) ![]u8 {
    var out = ByteList.init(allocator);
    defer out.deinit();

    try out.appendSlice("<16'op:start-session");

    // captp-version as string
    try std.fmt.format(out.writer(), "{d}\"", .{CAPTP_VERSION.len});
    try out.appendSlice(CAPTP_VERSION);

    // session-pubkey as gcrypt s-expression
    const pubkey_sexp = try encodeGcryptPubkey(allocator, session_pubkey);
    defer allocator.free(pubkey_sexp);
    try out.appendSlice(pubkey_sexp);

    // acceptable-location (full record)
    const loc_bytes = try location.encodeAlloc(allocator);
    defer allocator.free(loc_bytes);
    try out.appendSlice(loc_bytes);

    // acceptable-location-signature (sig-envelope record)
    const sig_bytes = try signature.encodeAlloc(allocator);
    defer allocator.free(sig_bytes);
    try out.appendSlice(sig_bytes);

    try out.append('>');
    return out.toOwnedSlice();
}

// ---- Tests ------------------------------------------------------------------

test "sign + verify location round-trip" {
    const allocator = std.testing.allocator;
    const kp = try KeyPair.generate();
    const loc = location_mod.Location{
        .netlayer = .tcp,
        .designator = &[_]u8{ 9, 9, 9, 9 },
    };
    const sig = try signLocation(kp, loc, allocator);
    const ok = try verifyLocation(kp.pub_key, loc, sig, allocator);
    try std.testing.expect(ok);

    // Tampered location fails.
    const tampered = location_mod.Location{
        .netlayer = .onion,
        .designator = &[_]u8{ 9, 9, 9, 9 },
    };
    const bad = try verifyLocation(kp.pub_key, tampered, sig, allocator);
    try std.testing.expect(!bad);
}

test "encodeStartSession parses as record with gcrypt pubkey" {
    const allocator = std.testing.allocator;
    const kp = try KeyPair.generate();
    const loc = location_mod.Location{
        .netlayer = .tcp,
        .designator = &[_]u8{ 1, 2, 3 },
    };
    const sig = try signLocation(kp, loc, allocator);

    const bytes = try encodeStartSession(allocator, kp.pub_key, loc, sig);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:start-session", v.record.label.symbol);
    try std.testing.expect(v.record.fields.len == 4);
    // Field 1 should be a list (gcrypt pubkey s-expression), not bytes.
    try std.testing.expect(v.record.fields[1] == .list);
}

test "gcrypt pubkey encode/decode round-trip" {
    const allocator = std.testing.allocator;
    var pk: [32]u8 = undefined;
    for (&pk, 0..) |*b, i| b.* = @intCast(i);

    const sexp_bytes = try encodeGcryptPubkey(allocator, pk);
    defer allocator.free(sexp_bytes);

    var parser = syrup.Parser.init(sexp_bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const decoded = try decodeGcryptPubkey(v);
    try std.testing.expectEqualSlices(u8, &pk, &decoded);
}

test "gcrypt signature encode/decode round-trip" {
    const allocator = std.testing.allocator;
    var sig: [64]u8 = undefined;
    for (&sig, 0..) |*b, i| b.* = @intCast(i);

    const sexp_bytes = try encodeGcryptSignature(allocator, sig);
    defer allocator.free(sexp_bytes);

    var parser = syrup.Parser.init(sexp_bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const decoded = try decodeGcryptSignature(v);
    try std.testing.expectEqualSlices(u8, &sig, &decoded);
}

test "derivePublicId is deterministic" {
    const allocator = std.testing.allocator;
    var pk: [32]u8 = undefined;
    for (&pk, 0..) |*b, i| b.* = @intCast(i);

    const id1 = try derivePublicId(allocator, pk);
    const id2 = try derivePublicId(allocator, pk);
    try std.testing.expectEqualSlices(u8, &id1, &id2);
    // Should not be all zeros (SHA256^2 of non-trivial input).
    var zero_count: usize = 0;
    for (id1) |b| if (b == 0) {
        zero_count += 1;
    };
    try std.testing.expect(zero_count < 32);
}

test "deriveSessionId is symmetric (order-independent)" {
    const id_a = [_]u8{0xAA} ** 32;
    const id_b = [_]u8{0xBB} ** 32;
    const sid_ab = deriveSessionId(id_a, id_b);
    const sid_ba = deriveSessionId(id_b, id_a);
    try std.testing.expectEqualSlices(u8, &sid_ab, &sid_ba);
}

test "deriveSessionId differs for different peers" {
    const id_a = [_]u8{0xAA} ** 32;
    const id_b = [_]u8{0xBB} ** 32;
    const id_c = [_]u8{0xCC} ** 32;
    const sid_ab = deriveSessionId(id_a, id_b);
    const sid_ac = deriveSessionId(id_a, id_c);
    try std.testing.expect(!std.mem.eql(u8, &sid_ab, &sid_ac));
}
