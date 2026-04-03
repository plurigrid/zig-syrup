//! did:key — First DID method implementation in Zig
//!
//! Implements the W3C did:key Method Specification:
//!   did:key:z<multibase(multicodec(pubkey))>
//!
//! Ed25519 only (multicodec prefix 0xed). Uses Zig stdlib crypto
//! (no external dependencies). Bridges to did:gay via bisimulation.zig.
//!
//! Reference: https://w3c-ccg.github.io/did-method-key/
//! Landscape: Zero other Zig DID implementations exist (as of 2026-04).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const splitmix = @import("gay/splitmix.zig");
const Color = splitmix.Color;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Ed25519 multicodec prefix (varint 0xed = [0xed, 0x01])
const ED25519_MULTICODEC: [2]u8 = .{ 0xed, 0x01 };

/// Base58btc alphabet (Bitcoin variant)
const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// did:key prefix
const DID_KEY_PREFIX = "did:key:z";

/// Maximum encoded DID length: "did:key:z" + base58btc(34 bytes) ≤ 56 chars
const MAX_DID_LEN = 56;

// ============================================================================
// TYPES
// ============================================================================

/// A resolved did:key — contains the decoded public key and DID string
pub const DidKey = struct {
    /// Raw Ed25519 public key (32 bytes)
    public_key: [32]u8,
    /// The full DID string (e.g., "did:key:z6Mk...")
    did: []const u8,
    /// GF(3) trit derived from key material (for bisimulation bridge)
    trit: Trit,
    /// Deterministic Gay color from pubkey via SplitMix64 (seed 1069)
    color: Color,

    allocator: Allocator,

    pub fn deinit(self: *const DidKey) void {
        self.allocator.free(self.did);
    }
};

/// GF(3) trit — matches bisimulation.zig / continuation.zig
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn fromKeyByte(byte: u8) Trit {
        return switch (@mod(byte, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

// ============================================================================
// BASE58BTC ENCODING
// ============================================================================

/// Encode bytes as base58btc. Caller owns returned slice.
fn base58Encode(allocator: Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return allocator.alloc(u8, 0);

    // Count leading zeros
    var leading_zeros: usize = 0;
    for (input) |byte| {
        if (byte != 0) break;
        leading_zeros += 1;
    }

    // Allocate enough space (log(256)/log(58) ≈ 1.37, use 1.5 for safety)
    const max_len = leading_zeros + (input.len * 3 / 2) + 1;
    var digits = try allocator.alloc(u8, max_len);
    defer allocator.free(digits);
    @memset(digits, 0);
    var digits_len: usize = 0;

    for (input) |byte| {
        var carry: u32 = byte;
        var j: usize = 0;
        while (j < digits_len or carry != 0) {
            if (j < digits_len) {
                carry += @as(u32, digits[j]) * 256;
            }
            if (j >= digits.len) break;
            digits[j] = @intCast(carry % 58);
            carry /= 58;
            j += 1;
        }
        digits_len = j;
    }

    // Build result: leading '1's + reversed digits
    const result_len = leading_zeros + digits_len;
    var result = try allocator.alloc(u8, result_len);

    for (0..leading_zeros) |i| {
        result[i] = '1';
    }
    for (0..digits_len) |i| {
        result[leading_zeros + i] = BASE58_ALPHABET[digits[digits_len - 1 - i]];
    }

    return result;
}

/// Decode base58btc to bytes. Caller owns returned slice.
fn base58Decode(allocator: Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return allocator.alloc(u8, 0);

    // Count leading '1's (= leading zero bytes)
    var leading_ones: usize = 0;
    for (input) |ch| {
        if (ch != '1') break;
        leading_ones += 1;
    }

    // Decode
    const max_len = input.len;
    var bytes = try allocator.alloc(u8, max_len);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    var bytes_len: usize = 0;

    for (input) |ch| {
        const val = base58CharValue(ch) orelse return error.InvalidBase58;
        var carry: u32 = val;
        var j: usize = 0;
        while (j < bytes_len or carry != 0) {
            if (j < bytes_len) {
                carry += @as(u32, bytes[j]) * 58;
            }
            if (j >= bytes.len) break;
            bytes[j] = @intCast(carry % 256);
            carry /= 256;
            j += 1;
        }
        bytes_len = j;
    }

    // Build result: leading zeros + reversed bytes
    const result_len = leading_ones + bytes_len;
    var result = try allocator.alloc(u8, result_len);

    for (0..leading_ones) |i| {
        result[i] = 0;
    }
    for (0..bytes_len) |i| {
        result[leading_ones + i] = bytes[bytes_len - 1 - i];
    }

    return result;
}

fn base58CharValue(ch: u8) ?u8 {
    for (BASE58_ALPHABET, 0..) |c, i| {
        if (c == ch) return @intCast(i);
    }
    return null;
}

// ============================================================================
// DID:KEY GENERATION
// ============================================================================

/// Generate a did:key from an Ed25519 public key.
pub fn fromPublicKey(allocator: Allocator, public_key: [32]u8) !DidKey {
    // Multicodec-prefix the key: [0xed, 0x01] ++ pubkey
    var prefixed: [34]u8 = undefined;
    prefixed[0] = ED25519_MULTICODEC[0];
    prefixed[1] = ED25519_MULTICODEC[1];
    @memcpy(prefixed[2..], &public_key);

    // Base58btc encode
    const encoded = try base58Encode(allocator, &prefixed);
    defer allocator.free(encoded);

    // Build full DID string: "did:key:z" ++ encoded
    const did = try std.fmt.allocPrint(allocator, DID_KEY_PREFIX ++ "{s}", .{encoded});

    // Derive GF(3) trit from first key byte (deterministic)
    const trit = Trit.fromKeyByte(public_key[0]);

    // Derive deterministic Gay color: XOR pubkey into u64 seed, mix with GAY_SEED
    const color = pubkeyToColor(public_key);

    return .{
        .public_key = public_key,
        .did = did,
        .trit = trit,
        .color = color,
        .allocator = allocator,
    };
}

/// Generate a did:key from an Ed25519 keypair seed (32 bytes).
pub fn fromSeed(allocator: Allocator, seed: [32]u8) !DidKey {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    return fromPublicKey(allocator, kp.public_key.toBytes());
}

/// Generate a random did:key.
pub fn generate(allocator: Allocator) !DidKey {
    const kp = Ed25519.KeyPair.generate();
    return fromPublicKey(allocator, kp.public_key.toBytes());
}

// ============================================================================
// DID:KEY RESOLUTION
// ============================================================================

/// Resolve a did:key string back to its public key.
/// Returns error if the DID is malformed or uses unsupported codec.
pub fn resolve(allocator: Allocator, did: []const u8) !DidKey {
    // Check prefix
    if (!std.mem.startsWith(u8, did, DID_KEY_PREFIX)) {
        return error.InvalidDidKeyPrefix;
    }

    // Decode the multibase part (after "did:key:z")
    const multibase_part = did[DID_KEY_PREFIX.len..];
    const decoded = try base58Decode(allocator, multibase_part);
    defer allocator.free(decoded);

    // Check multicodec prefix
    if (decoded.len < 34) return error.InvalidDidKeyLength;
    if (decoded[0] != ED25519_MULTICODEC[0] or decoded[1] != ED25519_MULTICODEC[1]) {
        return error.UnsupportedMulticodec;
    }

    // Extract public key
    var public_key: [32]u8 = undefined;
    @memcpy(&public_key, decoded[2..34]);

    const did_copy = try allocator.dupe(u8, did);
    const trit = Trit.fromKeyByte(public_key[0]);
    const color = pubkeyToColor(public_key);

    return .{
        .public_key = public_key,
        .did = did_copy,
        .trit = trit,
        .color = color,
        .allocator = allocator,
    };
}

// ============================================================================
// DID DOCUMENT GENERATION
// ============================================================================

/// Generate a minimal DID Document (JSON) for a did:key.
/// Caller owns returned slice.
pub fn toDidDocument(allocator: Allocator, dk: DidKey) ![]u8 {
    // Multibase-encode the verification key for the document
    var prefixed: [34]u8 = undefined;
    prefixed[0] = ED25519_MULTICODEC[0];
    prefixed[1] = ED25519_MULTICODEC[1];
    @memcpy(prefixed[2..], &dk.public_key);
    const multibase_key = try base58Encode(allocator, &prefixed);
    defer allocator.free(multibase_key);

    return std.fmt.allocPrint(allocator,
        \\{{"@context":["https://www.w3.org/ns/did/v1","https://w3id.org/security/suites/ed25519-2020/v1"],"id":"{s}","verificationMethod":[{{"id":"{s}#keys-1","type":"Ed25519VerificationKey2020","controller":"{s}","publicKeyMultibase":"z{s}"}}],"authentication":["{s}#keys-1"],"assertionMethod":["{s}#keys-1"]}}
    , .{ dk.did, dk.did, dk.did, multibase_key, dk.did, dk.did });
}

// ============================================================================
// GAY COLOR DERIVATION (SplitMix64, seed 1069)
// ============================================================================

/// Derive a deterministic Gay color from an Ed25519 pubkey.
/// Folds 32 bytes into a u64 seed via XOR, mixes with GAY_SEED (1069),
/// then runs through SplitMix64 → Color. Matches Gay.jl pipeline.
pub fn pubkeyToColor(public_key: [32]u8) Color {
    // Fold 32 bytes → 4 u64s → XOR reduce
    var seed: u64 = splitmix.GAY_SEED;
    var i: usize = 0;
    while (i + 8 <= 32) : (i += 8) {
        seed ^= std.mem.readInt(u64, public_key[i..][0..8], .little);
    }
    // SplitMix64 → color via GayRng
    var rng = splitmix.GayRng.init(seed);
    return rng.nextColor();
}

// ============================================================================
// BRIDGE TO did:gay (via trit trajectory)
// ============================================================================

/// Convert a did:key to a trit trajectory for bisimulation oracle.
///
/// Maps key bytes to trits via GF(3): each byte mod 3 → trit.
/// Produces a 32-trit trajectory (one per key byte).
/// This trajectory can be fed into bisimulation.tritTrajectoryToLTS().
pub fn toTritTrajectory(public_key: [32]u8) [32]Trit {
    var trajectory: [32]Trit = undefined;
    for (&public_key, 0..) |byte, i| {
        trajectory[i] = Trit.fromKeyByte(byte);
    }
    return trajectory;
}

/// Compute GF(3) balance of a did:key's trit trajectory.
pub fn gf3Balance(public_key: [32]u8) Trit {
    const traj = toTritTrajectory(public_key);
    var sum: i8 = 0;
    for (traj) |t| {
        sum = @mod(sum + @as(i8, @intFromEnum(t)) + 3, 3);
    }
    return switch (sum) {
        0 => .zero,
        1 => .plus,
        2 => .minus,
        else => unreachable,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "did:key roundtrip" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0x42} ** 32;
    const dk = try fromSeed(allocator, seed);
    defer dk.deinit();

    // Must start with "did:key:z"
    try std.testing.expect(std.mem.startsWith(u8, dk.did, DID_KEY_PREFIX));

    // Resolve back
    const resolved = try resolve(allocator, dk.did);
    defer resolved.deinit();

    // Public keys must match
    try std.testing.expectEqualSlices(u8, &dk.public_key, &resolved.public_key);
}

test "did:key deterministic" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0xAB} ** 32;

    const dk1 = try fromSeed(allocator, seed);
    defer dk1.deinit();
    const dk2 = try fromSeed(allocator, seed);
    defer dk2.deinit();

    try std.testing.expectEqualStrings(dk1.did, dk2.did);
}

test "did:key trit trajectory GF(3)" {
    const seed = [_]u8{0x00} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const traj = toTritTrajectory(kp.public_key.toBytes());

    // All trits must be valid
    for (traj) |t| {
        const v = @intFromEnum(t);
        try std.testing.expect(v >= -1 and v <= 1);
    }
}

test "did:key DID document generation" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0xFF} ** 32;
    const dk = try fromSeed(allocator, seed);
    defer dk.deinit();

    const doc = try toDidDocument(allocator, dk);
    defer allocator.free(doc);

    // Must contain the DID
    try std.testing.expect(std.mem.indexOf(u8, doc, dk.did) != null);
    // Must be valid-ish JSON (starts with {)
    try std.testing.expectEqual(@as(u8, '{'), doc[0]);
}

test "base58 encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const input = "Hello, did:key!";
    const encoded = try base58Encode(allocator, input);
    defer allocator.free(encoded);
    const decoded = try base58Decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "base58 leading zeros" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0, 0, 0, 1, 2, 3 };
    const encoded = try base58Encode(allocator, &input);
    defer allocator.free(encoded);

    // Leading zeros → leading '1's
    try std.testing.expect(std.mem.startsWith(u8, encoded, "111"));

    const decoded = try base58Decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "resolve rejects invalid prefix" {
    const allocator = std.testing.allocator;
    const result = resolve(allocator, "did:web:example.com");
    try std.testing.expectError(error.InvalidDidKeyPrefix, result);
}

test "did:key color derivation SPI" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0x42} ** 32;
    const dk1 = try fromSeed(allocator, seed);
    defer dk1.deinit();
    const dk2 = try fromSeed(allocator, seed);
    defer dk2.deinit();

    // SPI: same seed → same color (Strong Parallelism Invariance)
    try std.testing.expect(Color.eql(dk1.color, dk2.color));

    // Color channels must be in [0, 1]
    try std.testing.expect(dk1.color.r >= 0.0 and dk1.color.r <= 1.0);
    try std.testing.expect(dk1.color.g >= 0.0 and dk1.color.g <= 1.0);
    try std.testing.expect(dk1.color.b >= 0.0 and dk1.color.b <= 1.0);

    // Different seed → different color
    const dk3 = try fromSeed(allocator, [_]u8{0xAB} ** 32);
    defer dk3.deinit();
    try std.testing.expect(!Color.eql(dk1.color, dk3.color));
}

test "gf3Balance is deterministic" {
    const seed = [_]u8{0x69} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const pk = kp.public_key.toBytes();
    const b1 = gf3Balance(pk);
    const b2 = gf3Balance(pk);
    try std.testing.expectEqual(b1, b2);
}
