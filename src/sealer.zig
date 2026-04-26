//! sealer.zig — paired Sealer/Unsealer for opaque envelopes.
//!
//! `Pair.generate(rng)` produces a (Sealer, Unsealer) sharing one secret key:
//!   - `Sealer.seal(out, plaintext, rng)`  — produce an envelope nobody else can read
//!   - `Unsealer.unseal(out, envelope)`    — recover the plaintext
//!
//! Use cases:
//!   - Opaque cursors: server hands client a sealed token; only server's
//!     unsealer can read it back. Pair with Swiss numbers in ocapn_bootstrap.
//!   - Sealed-bid envelopes: bidder seals; auctioneer holds the unsealer.
//!   - Confined-vat secrets: parent seals; only parent's unsealer revives them.
//!
//! Construction: NaCl SecretBox (XSalsa20 + Poly1305) over a shared symmetric
//! key. Sealer and Unsealer are conceptually distinct rights (sealing vs
//! unsealing) but cryptographically the same secret. For asymmetric sealing
//! (anyone-can-seal, only-recipient-unseals), use `std.crypto.nacl.SealedBox`
//! directly — that pattern needs key-pair semantics this module does not
//! implement.
//!
//! Envelope layout: `nonce(24) || tag(16) || ciphertext(plaintext.len)`
//! Sealed length: `SEAL_OVERHEAD + plaintext.len`
//!
//! Threading: Sealer/Unsealer are plain values; they are reentrant as long as
//! the per-call RNG is not shared across threads.

const std = @import("std");

const SecretBox = std.crypto.nacl.SecretBox;

pub const KEY_LEN: usize = SecretBox.key_length; // 32
pub const NONCE_LEN: usize = SecretBox.nonce_length; // 24
pub const TAG_LEN: usize = SecretBox.tag_length; // 16
pub const SEAL_OVERHEAD: usize = NONCE_LEN + TAG_LEN; // 40

pub const SealError = error{BufferTooSmall};
pub const UnsealError = error{ BufferTooSmall, EnvelopeTruncated, AuthenticationFailed };

/// (Sealer, Unsealer) over a shared symmetric key.
pub const Pair = struct {
    key: [KEY_LEN]u8,

    /// Generate a fresh pair from `rng`. For production use, drive this from
    /// `std.crypto.random` (CSPRNG); a Xoshiro PRNG is fine for tests only.
    pub fn generate(rng: std.Random) Pair {
        var k: [KEY_LEN]u8 = undefined;
        rng.bytes(&k);
        return .{ .key = k };
    }

    pub fn sealer(self: Pair) Sealer {
        return .{ .key = self.key };
    }

    pub fn unsealer(self: Pair) Unsealer {
        return .{ .key = self.key };
    }
};

pub const Sealer = struct {
    key: [KEY_LEN]u8,

    /// Seal `plaintext` into `out`. `out.len` must be at least
    /// `SEAL_OVERHEAD + plaintext.len`. Returns the slice of `out` holding
    /// the envelope.
    pub fn seal(self: Sealer, out: []u8, plaintext: []const u8, rng: std.Random) SealError![]u8 {
        const env_len = SEAL_OVERHEAD + plaintext.len;
        if (out.len < env_len) return error.BufferTooSmall;
        var nonce: [NONCE_LEN]u8 = undefined;
        rng.bytes(&nonce);
        @memcpy(out[0..NONCE_LEN], &nonce);
        const ct_buf = out[NONCE_LEN..env_len];
        SecretBox.seal(ct_buf, plaintext, nonce, self.key);
        return out[0..env_len];
    }
};

pub const Unsealer = struct {
    key: [KEY_LEN]u8,

    /// Decrypt `envelope` (produced by the paired Sealer) into `out`.
    /// `out.len` must be at least `envelope.len - SEAL_OVERHEAD`. Returns
    /// the slice of `out` holding the plaintext.
    pub fn unseal(self: Unsealer, out: []u8, envelope: []const u8) UnsealError![]u8 {
        if (envelope.len < SEAL_OVERHEAD) return error.EnvelopeTruncated;
        const pt_len = envelope.len - SEAL_OVERHEAD;
        if (out.len < pt_len) return error.BufferTooSmall;
        var nonce: [NONCE_LEN]u8 = undefined;
        @memcpy(&nonce, envelope[0..NONCE_LEN]);
        SecretBox.open(out[0..pt_len], envelope[NONCE_LEN..], nonce, self.key) catch
            return error.AuthenticationFailed;
        return out[0..pt_len];
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "seal then unseal round-trips plaintext" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const pair = Pair.generate(rng);

    const plaintext = "swiss-number-deadbeef";
    var env_buf: [SEAL_OVERHEAD + plaintext.len]u8 = undefined;
    const env = try pair.sealer().seal(&env_buf, plaintext, rng);
    try testing.expectEqual(SEAL_OVERHEAD + plaintext.len, env.len);

    var out_buf: [plaintext.len]u8 = undefined;
    const recovered = try pair.unsealer().unseal(&out_buf, env);
    try testing.expectEqualStrings(plaintext, recovered);
}

test "tampered envelope fails authentication" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    const pair = Pair.generate(rng);

    const plaintext = "auction-bid-9999";
    var env_buf: [SEAL_OVERHEAD + plaintext.len]u8 = undefined;
    const env = try pair.sealer().seal(&env_buf, plaintext, rng);

    // Flip one bit inside the ciphertext region; Poly1305 should reject it.
    env[NONCE_LEN + TAG_LEN + 1] ^= 0x01;

    var out_buf: [plaintext.len]u8 = undefined;
    try testing.expectError(error.AuthenticationFailed, pair.unsealer().unseal(&out_buf, env));
}

test "different pairs cannot open each other's envelopes" {
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const rng = prng.random();
    const pair_a = Pair.generate(rng);
    const pair_b = Pair.generate(rng);

    const plaintext = "secret";
    var env_buf: [SEAL_OVERHEAD + plaintext.len]u8 = undefined;
    const env = try pair_a.sealer().seal(&env_buf, plaintext, rng);

    var out_buf: [plaintext.len]u8 = undefined;
    try testing.expectError(error.AuthenticationFailed, pair_b.unsealer().unseal(&out_buf, env));
}

test "truncated envelope returns EnvelopeTruncated" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    const pair = Pair.generate(rng);
    var out: [16]u8 = undefined;
    try testing.expectError(error.EnvelopeTruncated, pair.unsealer().unseal(&out, &.{ 1, 2, 3 }));
}

test "empty plaintext: envelope length equals SEAL_OVERHEAD" {
    var prng = std.Random.DefaultPrng.init(123);
    const rng = prng.random();
    const pair = Pair.generate(rng);

    var env_buf: [SEAL_OVERHEAD]u8 = undefined;
    const env = try pair.sealer().seal(&env_buf, "", rng);
    try testing.expectEqual(@as(usize, SEAL_OVERHEAD), env.len);

    var out: [0]u8 = undefined;
    const recovered = try pair.unsealer().unseal(&out, env);
    try testing.expectEqual(@as(usize, 0), recovered.len);
}

test "two seals of the same plaintext produce different envelopes (fresh nonce)" {
    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();
    const pair = Pair.generate(rng);

    const plaintext = "same input twice";
    var a_buf: [SEAL_OVERHEAD + plaintext.len]u8 = undefined;
    var b_buf: [SEAL_OVERHEAD + plaintext.len]u8 = undefined;
    const a = try pair.sealer().seal(&a_buf, plaintext, rng);
    const b = try pair.sealer().seal(&b_buf, plaintext, rng);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "out buffer too small returns BufferTooSmall" {
    var prng = std.Random.DefaultPrng.init(55);
    const rng = prng.random();
    const pair = Pair.generate(rng);
    var tiny: [10]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, pair.sealer().seal(&tiny, "abcd", rng));
}
