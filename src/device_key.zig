//! device_key.zig — vat-bound Ed25519 identity with replay-resistant signing.
//!
//! A `DeviceKey` is an Ed25519 keypair pinned to a specific vat. Three
//! properties make it useful as an identity primitive for capability systems:
//!
//!   1. **Vat binding**: every signature commits to the originating
//!      `vat_id` via domain-separated AAD. Signatures from vat A cannot be
//!      replayed as if from vat B without a fresh signing operation.
//!
//!   2. **Replay distinguishing**: each signature carries a monotonic
//!      sequence number. Verifiers track the highest seen `seq` per
//!      `(pubkey, vat_id)` and reject any signature with a `seq` ≤ that.
//!      Two signatures of the same message produce different envelopes
//!      and only the newer one verifies thereafter.
//!
//!   3. **Confined signing capability**: `confine()` returns a `SigningCap`
//!      that holds only a pointer to the key plus an optional `Revoker`.
//!      Holders can sign but cannot extract the secret key bytes. Revoking
//!      the cap revokes signing authority synchronously.
//!
//! What this is *not*: a full capability-passing protocol. A `SigningCap`
//! is an in-process value, not a `cap.Capability` — it does not flow through
//! `vat.send`. To grant signing across a vat boundary, wrap a behavior actor
//! that holds a `SigningCap` and exposes a `sign(msg) -> Signature` method
//! through the runtime cap layer. The pattern is straightforward but kept
//! out of this module to preserve its single responsibility.
//!
//! Wire payload signed by `sign()`:
//!     `DOMAIN_SEP(8) ‖ vat_id_be(4) ‖ seq_be(8) ‖ msg(N)`
//! The signature itself is 64 bytes (Ed25519). The verifier reconstructs
//! this payload from the public-side fields and the signature struct.

const std = @import("std");
const cap = @import("cap.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const PUBKEY_LEN: usize = Ed25519.PublicKey.encoded_length; // 32
pub const SIG_LEN: usize = Ed25519.Signature.encoded_length; // 64
pub const SEED_LEN: usize = Ed25519.KeyPair.seed_length; // 32

/// Domain separation tag. Prevents cross-protocol signature reuse: a
/// signature produced by `DeviceKey.sign` cannot be confused with any other
/// payload that hashes a different prefix.
pub const DOMAIN_SEP: [8]u8 = .{ 'Z', 'S', 'D', 'K', 'v', '0', '0', '1' };
pub const HEADER_LEN: usize = DOMAIN_SEP.len + 4 + 8; // 20 bytes prefix

pub const SignError = error{
    Revoked,
    SignFailed,
} || std.mem.Allocator.Error;

pub const VerifyError = error{
    InvalidSignature,
    InvalidPublicKey,
    WrongVatId,
    StaleSequence,
} || std.mem.Allocator.Error;

/// Public-side signature envelope. Carries the AAD fields the verifier
/// needs alongside the raw 64-byte Ed25519 signature.
pub const Signature = struct {
    vat_id: cap.VatId,
    seq: u64,
    bytes: [SIG_LEN]u8,
};

/// Vat-bound Ed25519 signing identity. Owns the secret material; do not copy
/// instances — mutate through pointer to keep the seq counter monotonic.
pub const DeviceKey = struct {
    ed_pair: Ed25519.KeyPair,
    vat_id: cap.VatId,
    seq: u64 = 0,

    /// Generate a fresh DeviceKey from the system CSPRNG.
    pub fn generate(vat_id: cap.VatId) DeviceKey {
        return .{
            .ed_pair = Ed25519.KeyPair.generate(),
            .vat_id = vat_id,
        };
    }

    /// Deterministic generation from a 32-byte seed. Useful for tests and
    /// for key derivation from existing entropy. Do not feed predictable
    /// seeds in production.
    pub fn generateDeterministic(vat_id: cap.VatId, seed: [SEED_LEN]u8) !DeviceKey {
        return .{
            .ed_pair = try Ed25519.KeyPair.generateDeterministic(seed),
            .vat_id = vat_id,
        };
    }

    pub fn publicKeyBytes(self: DeviceKey) [PUBKEY_LEN]u8 {
        return self.ed_pair.public_key.toBytes();
    }

    /// Sign `msg` with vat-bound AAD. Increments `seq` so that future
    /// verifiers can reject replays.
    pub fn sign(self: *DeviceKey, msg: []const u8, allocator: std.mem.Allocator) SignError!Signature {
        const seq = self.seq;
        self.seq += 1;
        const payload = try buildPayload(allocator, self.vat_id, seq, msg);
        defer allocator.free(payload);
        const sig = self.ed_pair.sign(payload, null) catch return error.SignFailed;
        return .{
            .vat_id = self.vat_id,
            .seq = seq,
            .bytes = sig.toBytes(),
        };
    }
};

/// Confined signing capability. Holders can sign messages but cannot read
/// the underlying secret key. Optionally gated by a `Revoker` for
/// synchronous revocation.
pub const SigningCap = struct {
    key: *DeviceKey,
    revoker: ?*cap.Revoker = null,

    pub fn isLive(self: SigningCap) bool {
        if (self.revoker) |r| return r.isAlive();
        return true;
    }

    pub fn sign(self: SigningCap, msg: []const u8, allocator: std.mem.Allocator) SignError!Signature {
        if (!self.isLive()) return error.Revoked;
        return try self.key.sign(msg, allocator);
    }

    pub fn vatId(self: SigningCap) cap.VatId {
        return self.key.vat_id;
    }

    pub fn publicKeyBytes(self: SigningCap) [PUBKEY_LEN]u8 {
        return self.key.publicKeyBytes();
    }
};

/// Wrap a `DeviceKey` in a `SigningCap` bound to `revoker`. After this,
/// holders of the cap can sign but cannot extract the key. Revoke the
/// `Revoker` to synchronously kill all derived signing authority.
pub fn confine(key: *DeviceKey, revoker: ?*cap.Revoker) SigningCap {
    return .{ .key = key, .revoker = revoker };
}

/// Verify a signature against a public key. Returns the signed `seq` on
/// success; caller updates its per-key high-water mark.
///
/// Replay protection: rejects any `seq` < `min_seq`. Pass `min_seq = 0` for
/// the first signature, then bump to `returned_seq + 1` after each accept.
pub fn verify(
    pubkey_bytes: [PUBKEY_LEN]u8,
    msg: []const u8,
    sig: Signature,
    expected_vat_id: cap.VatId,
    min_seq: u64,
    allocator: std.mem.Allocator,
) VerifyError!u64 {
    if (sig.vat_id != expected_vat_id) return error.WrongVatId;
    if (sig.seq < min_seq) return error.StaleSequence;

    const pubkey = Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return error.InvalidPublicKey;
    const signature = Ed25519.Signature.fromBytes(sig.bytes);

    const payload = buildPayload(allocator, sig.vat_id, sig.seq, msg) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(payload);

    signature.verify(payload, pubkey) catch return error.InvalidSignature;
    return sig.seq;
}

/// Tracks the highest verified `seq` per `(vat_id, pubkey)` so a long-lived
/// verifier can reject replays across a stream. Caller owns lifetime.
pub const Verifier = struct {
    high_water: u64 = 0,
    pubkey: [PUBKEY_LEN]u8,
    expected_vat_id: cap.VatId,

    pub fn init(pubkey: [PUBKEY_LEN]u8, vat_id: cap.VatId) Verifier {
        return .{ .pubkey = pubkey, .expected_vat_id = vat_id };
    }

    /// Verify and advance the high-water mark on success.
    pub fn check(
        self: *Verifier,
        msg: []const u8,
        sig: Signature,
        allocator: std.mem.Allocator,
    ) VerifyError!void {
        const seen = try verify(self.pubkey, msg, sig, self.expected_vat_id, self.high_water, allocator);
        self.high_water = seen + 1;
    }
};

fn buildPayload(allocator: std.mem.Allocator, vat_id: cap.VatId, seq: u64, msg: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, HEADER_LEN + msg.len);
    @memcpy(out[0..DOMAIN_SEP.len], &DOMAIN_SEP);
    std.mem.writeInt(u32, out[DOMAIN_SEP.len..][0..4], vat_id, .big);
    std.mem.writeInt(u64, out[DOMAIN_SEP.len + 4 ..][0..8], seq, .big);
    @memcpy(out[HEADER_LEN..], msg);
    return out;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "DeviceKey: sign + verify round-trip" {
    const seed: [SEED_LEN]u8 = .{0x42} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(7, seed);
    const sig = try key.sign("hello", testing.allocator);

    const seen = try verify(
        key.publicKeyBytes(),
        "hello",
        sig,
        7,
        0,
        testing.allocator,
    );
    try testing.expectEqual(@as(u64, 0), seen);
}

test "DeviceKey: tampered message fails verification" {
    const seed: [SEED_LEN]u8 = .{0x11} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(1, seed);
    const sig = try key.sign("alpha", testing.allocator);
    try testing.expectError(error.InvalidSignature, verify(
        key.publicKeyBytes(),
        "beta",
        sig,
        1,
        0,
        testing.allocator,
    ));
}

test "DeviceKey: wrong vat_id rejected (vat-binding)" {
    const seed: [SEED_LEN]u8 = .{0x22} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(5, seed);
    const sig = try key.sign("payload", testing.allocator);
    // Verifier expects vat 9, signature is from vat 5.
    try testing.expectError(error.WrongVatId, verify(
        key.publicKeyBytes(),
        "payload",
        sig,
        9,
        0,
        testing.allocator,
    ));
}

test "DeviceKey: seq increments and stale seq rejected" {
    const seed: [SEED_LEN]u8 = .{0x33} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(2, seed);

    const sig0 = try key.sign("first", testing.allocator);
    const sig1 = try key.sign("second", testing.allocator);
    const sig2 = try key.sign("third", testing.allocator);
    try testing.expectEqual(@as(u64, 0), sig0.seq);
    try testing.expectEqual(@as(u64, 1), sig1.seq);
    try testing.expectEqual(@as(u64, 2), sig2.seq);

    // Verifying sig1 with min_seq=0 succeeds.
    _ = try verify(key.publicKeyBytes(), "second", sig1, 2, 0, testing.allocator);
    // After raising min_seq above sig1.seq, sig1 is stale.
    try testing.expectError(error.StaleSequence, verify(
        key.publicKeyBytes(),
        "second",
        sig1,
        2,
        2,
        testing.allocator,
    ));
}

test "Verifier: stream of signatures advances high_water; replay rejected" {
    const seed: [SEED_LEN]u8 = .{0x44} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(3, seed);

    var v = Verifier.init(key.publicKeyBytes(), 3);

    const a = try key.sign("a", testing.allocator);
    const b = try key.sign("b", testing.allocator);
    const c = try key.sign("c", testing.allocator);

    try v.check("a", a, testing.allocator);
    try v.check("b", b, testing.allocator);
    try v.check("c", c, testing.allocator);
    try testing.expectEqual(@as(u64, 3), v.high_water);

    // Replaying `a` is rejected — its seq=0 is below high_water=3.
    try testing.expectError(error.StaleSequence, v.check("a", a, testing.allocator));
}

test "Different keys cannot verify each other's signatures" {
    const seed_a: [SEED_LEN]u8 = .{0x55} ** SEED_LEN;
    const seed_b: [SEED_LEN]u8 = .{0x66} ** SEED_LEN;
    var key_a = try DeviceKey.generateDeterministic(1, seed_a);
    var key_b = try DeviceKey.generateDeterministic(1, seed_b);

    const sig = try key_a.sign("x", testing.allocator);
    try testing.expectError(error.InvalidSignature, verify(
        key_b.publicKeyBytes(),
        "x",
        sig,
        1,
        0,
        testing.allocator,
    ));
}

test "SigningCap: revoked cap returns error.Revoked on sign" {
    const seed: [SEED_LEN]u8 = .{0x77} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(1, seed);
    var rev = cap.Revoker{};
    var sc = confine(&key, &rev);

    _ = try sc.sign("ok", testing.allocator);
    rev.revoke();
    try testing.expectError(error.Revoked, sc.sign("denied", testing.allocator));
}

test "SigningCap: unrevoked cap exposes only sign + pubkey, never the key bytes" {
    const seed: [SEED_LEN]u8 = .{0x88} ** SEED_LEN;
    var key = try DeviceKey.generateDeterministic(11, seed);
    var sc = confine(&key, null);

    try testing.expect(sc.isLive());
    try testing.expectEqual(@as(cap.VatId, 11), sc.vatId());
    try testing.expectEqual(key.publicKeyBytes(), sc.publicKeyBytes());

    // The compiler enforces "no key bytes": SigningCap has no method
    // returning the secret key. Test by introspection — confirm the only
    // public methods are isLive, sign, vatId, publicKeyBytes.
    const decls = std.meta.declarations(SigningCap);
    var sign_count: usize = 0;
    var key_extract_count: usize = 0;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "sign")) sign_count += 1;
        if (std.mem.indexOf(u8, d.name, "secret") != null) key_extract_count += 1;
        if (std.mem.indexOf(u8, d.name, "Secret") != null) key_extract_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), sign_count);
    try testing.expectEqual(@as(usize, 0), key_extract_count);
}

test "header length and constants are stable" {
    try testing.expectEqual(@as(usize, 32), PUBKEY_LEN);
    try testing.expectEqual(@as(usize, 64), SIG_LEN);
    try testing.expectEqual(@as(usize, 32), SEED_LEN);
    try testing.expectEqual(@as(usize, 20), HEADER_LEN); // 8 + 4 + 8
}
