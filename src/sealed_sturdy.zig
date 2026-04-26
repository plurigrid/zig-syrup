//! sealed_sturdy.zig — sealer-wrapped swiss numbers as time-limited bootstrap tokens.
//!
//! Swiss numbers in OCapN bootstrap are 32-byte handles that any holder can
//! present to fetch an export position. They have no built-in lifetime,
//! audience binding, or replay protection — bare swiss numbers are forever
//! sturdy. A `SealedSturdy` wraps a swiss in a `Sealer` envelope along with
//! `(issued_at_ms, expires_at_ms, nonce)`, giving:
//!
//!   - **Time limit**: unsealing past `expires_at_ms` returns `error.Expired`.
//!   - **Audience binding**: only the holder of the matching `Unsealer` can
//!     read the swiss; an attacker who intercepts the envelope cannot use it.
//!   - **Replay distinguishing**: each envelope embeds a fresh `nonce`, so a
//!     receiver can dedupe replays by remembering recently-seen nonces.
//!   - **Tamper detection**: the underlying NaCl SecretBox MAC catches any
//!     bit-flip or splice attempt.
//!
//! Wire layout (after sealing):
//!     `nonce(24) ‖ tag(16) ‖ ct(56)` — 96 bytes total
//! Plaintext payload is fixed-size (56 bytes) so envelopes are uniform on
//! the wire; no length-prefixing or framing needed beyond what the transport
//! provides.
//!
//! Composition with `ocapn_bootstrap.zig`: the unsealed `swiss` field is
//! exactly what `SwissRegistry.fetch` expects. A vat can hand out sealed
//! sturdies to clients and accept either form on the bootstrap path.

const std = @import("std");
const sealer = @import("sealer.zig");

/// Must match `ocapn_SWISS_LEN`. Defined locally to keep this module
/// independent of the wire-side bootstrap path (which pulls in the `syrup`
/// module dependency). The two values are linked by contract, not by code.
pub const SWISS_LEN: usize = 32;

pub const PAYLOAD_SIZE: usize = SWISS_LEN + 8 + 8 + 8; // 32 + 8 + 8 + 8 = 56
pub const SEALED_SIZE: usize = sealer.SEAL_OVERHEAD + PAYLOAD_SIZE; // 96

pub const Error = error{
    InvalidPayload,
    Expired,
} || sealer.SealError || sealer.UnsealError;

/// Plaintext contents of a sealed sturdy. Big-endian wire encoding ensures
/// the same envelope is interpretable across architectures.
pub const SwissPayload = struct {
    swiss: [SWISS_LEN]u8,
    issued_at_ms: i64,
    expires_at_ms: i64,
    nonce: u64,

    pub fn serialize(self: SwissPayload, out: *[PAYLOAD_SIZE]u8) void {
        @memcpy(out[0..SWISS_LEN], &self.swiss);
        std.mem.writeInt(i64, out[32..40], self.issued_at_ms, .big);
        std.mem.writeInt(i64, out[40..48], self.expires_at_ms, .big);
        std.mem.writeInt(u64, out[48..56], self.nonce, .big);
    }

    pub fn deserialize(in: *const [PAYLOAD_SIZE]u8) SwissPayload {
        var p: SwissPayload = undefined;
        @memcpy(&p.swiss, in[0..SWISS_LEN]);
        p.issued_at_ms = std.mem.readInt(i64, in[32..40], .big);
        p.expires_at_ms = std.mem.readInt(i64, in[40..48], .big);
        p.nonce = std.mem.readInt(u64, in[48..56], .big);
        return p;
    }
};

/// Seal a `SwissPayload` into `out`. `out.len` must be at least `SEALED_SIZE`.
pub fn seal(
    s: sealer.Sealer,
    out: []u8,
    payload: SwissPayload,
    rng: std.Random,
) Error![]u8 {
    var pt: [PAYLOAD_SIZE]u8 = undefined;
    payload.serialize(&pt);
    return try s.seal(out, &pt, rng);
}

/// Unseal an envelope and verify it has not expired against `now_ms`.
/// Returns the recovered `SwissPayload` on success.
pub fn unseal(
    u: sealer.Unsealer,
    envelope: []const u8,
    now_ms: i64,
) Error!SwissPayload {
    var pt: [PAYLOAD_SIZE]u8 = undefined;
    const recovered = try u.unseal(&pt, envelope);
    if (recovered.len != PAYLOAD_SIZE) return error.InvalidPayload;
    const p = SwissPayload.deserialize(&pt);
    if (now_ms >= p.expires_at_ms) return error.Expired;
    return p;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "round-trip: seal then unseal recovers swiss + metadata" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();
    const pair = sealer.Pair.generate(rng);

    const swiss: [SWISS_LEN]u8 = .{0x42} ** SWISS_LEN;
    const payload = SwissPayload{
        .swiss = swiss,
        .issued_at_ms = 1_000_000,
        .expires_at_ms = 2_000_000,
        .nonce = 0xCAFEF00DBA5EBA11,
    };

    var env_buf: [SEALED_SIZE]u8 = undefined;
    const env = try seal(pair.sealer(), &env_buf, payload, rng);
    try testing.expectEqual(SEALED_SIZE, env.len);

    const got = try unseal(pair.unsealer(), env, 1_500_000);
    try testing.expectEqualSlices(u8, &swiss, &got.swiss);
    try testing.expectEqual(payload.issued_at_ms, got.issued_at_ms);
    try testing.expectEqual(payload.expires_at_ms, got.expires_at_ms);
    try testing.expectEqual(payload.nonce, got.nonce);
}

test "expired envelope returns error.Expired" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    const pair = sealer.Pair.generate(rng);
    const payload = SwissPayload{
        .swiss = .{0} ** SWISS_LEN,
        .issued_at_ms = 1000,
        .expires_at_ms = 2000,
        .nonce = 1,
    };
    var env_buf: [SEALED_SIZE]u8 = undefined;
    const env = try seal(pair.sealer(), &env_buf, payload, rng);
    try testing.expectError(error.Expired, unseal(pair.unsealer(), env, 2000));
    try testing.expectError(error.Expired, unseal(pair.unsealer(), env, 9999));
}

test "tampered envelope rejected by MAC" {
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    const pair = sealer.Pair.generate(rng);
    const payload = SwissPayload{
        .swiss = .{0xAA} ** SWISS_LEN,
        .issued_at_ms = 1000,
        .expires_at_ms = 9999,
        .nonce = 42,
    };
    var env_buf: [SEALED_SIZE]u8 = undefined;
    const env = try seal(pair.sealer(), &env_buf, payload, rng);
    env[sealer.NONCE_LEN + sealer.TAG_LEN] ^= 0x01; // flip a bit in ciphertext
    try testing.expectError(error.AuthenticationFailed, unseal(pair.unsealer(), env, 1500));
}

test "wrong unsealer rejected" {
    var prng = std.Random.DefaultPrng.init(13);
    const rng = prng.random();
    const a = sealer.Pair.generate(rng);
    const b = sealer.Pair.generate(rng);
    const payload = SwissPayload{
        .swiss = .{0xFF} ** SWISS_LEN,
        .issued_at_ms = 0,
        .expires_at_ms = std.math.maxInt(i64),
        .nonce = 0,
    };
    var env_buf: [SEALED_SIZE]u8 = undefined;
    const env = try seal(a.sealer(), &env_buf, payload, rng);
    try testing.expectError(error.AuthenticationFailed, unseal(b.unsealer(), env, 0));
}

test "PAYLOAD_SIZE exactly matches serialized field bytes" {
    try testing.expectEqual(@as(usize, 56), PAYLOAD_SIZE);
    try testing.expectEqual(@as(usize, 96), SEALED_SIZE);
}
