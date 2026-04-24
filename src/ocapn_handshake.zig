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
//!   acceptable-location-sig = <sig-envelope scheme sig-bytes> record
//!
//! The signature covers the canonical Syrup encoding of the location record,
//! domain-separated with the literal bytestring "captp-location-sig:".

const std = @import("std");
const syrup = @import("syrup");
const location_mod = @import("ocapn_location");
const Ed25519 = std.crypto.sign.Ed25519;
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const CAPTP_VERSION: []const u8 = "1.0";
pub const SIG_DOMAIN: []const u8 = "captp-location-sig:";

pub const Signature = struct {
    scheme: []const u8 = "ed25519", // symbol
    bytes: [Ed25519.Signature.encoded_length]u8,

    pub fn encodeAlloc(self: Signature, allocator: Allocator) ![]u8 {
        var out = ByteList.init(allocator);
        defer out.deinit();
        try out.appendSlice("<12'sig-envelope");
        try std.fmt.format(out.writer(), "{d}'", .{self.scheme.len});
        try out.appendSlice(self.scheme);
        try std.fmt.format(out.writer(), "{d}:", .{self.bytes.len});
        try out.appendSlice(&self.bytes);
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

    // session-pubkey as bytestring (32 bytes)
    try out.appendSlice("32:");
    try out.appendSlice(&session_pubkey);

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

test "encodeStartSession parses as a record" {
    const allocator = std.testing.allocator;
    const kp = try KeyPair.generate();
    const loc = location_mod.Location{
        .netlayer = .tcp,
        .designator = &[_]u8{ 1, 2, 3 },
    };
    const sig = try signLocation(kp, loc, allocator);

    var sess_pk: [32]u8 = undefined;
    for (&sess_pk, 0..) |*b, i| b.* = @intCast(i);

    const bytes = try encodeStartSession(allocator, sess_pk, loc, sig);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:start-session", v.record.label.symbol);
    try std.testing.expect(v.record.fields.len == 4);
}
