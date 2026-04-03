//! did:gay — Behavioral Identity DID method in Zig
//!
//! The bridge module. Ties passport.zig (brain entropy) ↔ bisimulation.zig
//! (cross-protocol oracle) ↔ all other DID methods.
//!
//! Format: did:gay:<24-char-base32-identifier>
//!   Derived from: BLAKE3(Ed25519_pubkey || color_hex)[0:15] → base32-lower
//!
//! Identity proof: behavioral trit trajectory (EEG, conversation, device signals).
//! NOT a key. NOT a biometric. A behavioral trajectory — you are what you do.
//!
//! Bridge priority:
//!   did:gay ↔ did:key   (direct: both use Ed25519 pubkeys)
//!   did:gay ↔ did:web   (domain → trit trajectory via charToTrit)
//!   did:gay ↔ did:pkh   (address → trit trajectory via byte mod 3)
//!   did:gay ↔ did:tdw   (version log → trit trajectory, most natural)
//!   did:gay ↔ A2A       (agent card → LTS, already in bisimulation.zig)
//!   did:gay ↔ MCP       (descriptor → LTS, already in bisimulation.zig)
//!
//! Bisimulation oracle verifies: are two identities behaviorally equivalent?
//! GF(3) conservation catches translation errors (broken bridge → sum ≠ 0 mod 3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;

// ============================================================================
// CONSTANTS
// ============================================================================

const DID_GAY_PREFIX = "did:gay:";
const BASE32_LOWER = "abcdefghijklmnopqrstuvwxyz234567";
const IDENTIFIER_LEN = 24; // 15 bytes → 24 base32 chars

// ============================================================================
// TYPES
// ============================================================================

/// GF(3) trit
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "explore",
            .zero => "coordinate",
            .plus => "build",
        };
    }
};

/// A did:gay identifier
pub const DidGay = struct {
    /// Full DID string (e.g., "did:gay:a3xk7vm2np4qf8hw9d6yjc5r")
    did: []const u8,
    /// 24-char base32 identifier
    identifier: [IDENTIFIER_LEN]u8,
    /// The color hex (from SplitMix64 or seed)
    color_hex: [6]u8,
    /// GF(3) trit derived from identifier
    trit: Trit,
    allocator: Allocator,

    pub fn deinit(self: *const DidGay) void {
        self.allocator.free(self.did);
    }
};

/// Bridge result from a cross-DID comparison
pub const BridgeResult = struct {
    source_did: []const u8,
    target_did: []const u8,
    /// Trit trajectories are GF(3) balanced?
    gf3_conserved: bool,
    /// Trajectory lengths
    source_len: usize,
    target_len: usize,
};

// ============================================================================
// GENERATION
// ============================================================================

/// Generate a did:gay from an Ed25519 public key and a color hex string.
pub fn fromKeyAndColor(allocator: Allocator, public_key: [32]u8, color_hex: [6]u8) !DidGay {
    // BLAKE3(pubkey || color_hex)[0:15] → base32-lower → 24 chars
    var hasher = Blake3.init(.{});
    hasher.update(&public_key);
    hasher.update(&color_hex);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const identifier = bytesToBase32(hash[0..15]);
    const trit = deriveTrit(identifier);

    const did = try std.fmt.allocPrint(allocator, DID_GAY_PREFIX ++ "{s}", .{identifier});

    return .{
        .did = did,
        .identifier = identifier,
        .color_hex = color_hex,
        .trit = trit,
        .allocator = allocator,
    };
}

/// Generate a did:gay from a seed (SplitMix64 → color, Ed25519 keypair).
pub fn fromSeed(allocator: Allocator, seed: u64) !DidGay {
    // SplitMix64 → deterministic color
    const color_val = splitMix64(seed);
    var color_hex: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&color_hex, "{x:0>6}", .{@as(u24, @truncate(color_val))}) catch unreachable;

    // Seed → Ed25519 keypair
    var key_seed: [32]u8 = undefined;
    var sm_state = seed;
    for (&key_seed) |*b| {
        sm_state = splitMix64Step(sm_state);
        b.* = @truncate(sm_state);
    }
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(key_seed);

    return fromKeyAndColor(allocator, kp.public_key.toBytes(), color_hex);
}

/// Generate a did:gay from a trit trajectory (e.g., conversation history).
pub fn fromTrajectory(allocator: Allocator, trajectory: []const Trit) !DidGay {
    // BLAKE3(trajectory bytes) → seed
    var hasher = Blake3.init(.{});
    for (trajectory) |t| {
        hasher.update(&[_]u8{@bitCast(@intFromEnum(t))});
    }
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const seed = std.mem.readInt(u64, hash[0..8], .little);
    return fromSeed(allocator, seed);
}

// ============================================================================
// RESOLUTION
// ============================================================================

/// Parse a did:gay string.
pub fn parse(allocator: Allocator, did: []const u8) !DidGay {
    if (!std.mem.startsWith(u8, did, DID_GAY_PREFIX)) {
        return error.InvalidDidGayPrefix;
    }

    const id_part = did[DID_GAY_PREFIX.len..];
    if (id_part.len != IDENTIFIER_LEN) return error.InvalidIdentifierLength;

    var identifier: [IDENTIFIER_LEN]u8 = undefined;
    @memcpy(&identifier, id_part);

    return .{
        .did = try allocator.dupe(u8, did),
        .identifier = identifier,
        .color_hex = "000000".*, // unknown until resolved
        .trit = deriveTrit(identifier),
        .allocator = allocator,
    };
}

// ============================================================================
// BRIDGE FUNCTIONS: did:gay ↔ other DID methods
// ============================================================================

/// Bridge did:gay ↔ did:key: both share Ed25519 key material.
/// Given a did:key's 32-byte pubkey, derive the corresponding did:gay.
pub fn bridgeFromDidKey(allocator: Allocator, public_key: [32]u8, seed: u64) !DidGay {
    const color_val = splitMix64(seed);
    var color_hex: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&color_hex, "{x:0>6}", .{@as(u24, @truncate(color_val))}) catch unreachable;
    return fromKeyAndColor(allocator, public_key, color_hex);
}

/// Bridge did:gay ↔ did:web: domain → trit trajectory.
pub fn bridgeFromDomain(allocator: Allocator, domain: []const u8) !DidGay {
    var trajectory = try allocator.alloc(Trit, domain.len);
    defer allocator.free(trajectory);
    for (domain, 0..) |ch, i| {
        trajectory[i] = charToTrit(ch);
    }
    return fromTrajectory(allocator, trajectory);
}

/// Bridge did:gay ↔ did:pkh: blockchain address → trit trajectory.
pub fn bridgeFromAddress(allocator: Allocator, address: []const u8) !DidGay {
    const addr = if (std.mem.startsWith(u8, address, "0x")) address[2..] else address;
    var trajectory = try allocator.alloc(Trit, addr.len);
    defer allocator.free(trajectory);
    for (addr, 0..) |ch, i| {
        trajectory[i] = switch (@mod(ch, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
    return fromTrajectory(allocator, trajectory);
}

/// Bridge did:gay ↔ did:tdw: version log → trit trajectory.
pub fn bridgeFromVersionLog(allocator: Allocator, version_trits: []const Trit) !DidGay {
    return fromTrajectory(allocator, version_trits);
}

/// Check GF(3) conservation across a bridge.
pub fn checkBridgeConservation(traj_a: []const Trit, traj_b: []const Trit) BridgeResult {
    var sum_a: Trit = .zero;
    for (traj_a) |t| sum_a = Trit.add(sum_a, t);

    var sum_b: Trit = .zero;
    for (traj_b) |t| sum_b = Trit.add(sum_b, t);

    return .{
        .source_did = "did:gay",
        .target_did = "did:*",
        .gf3_conserved = (sum_a == sum_b),
        .source_len = traj_a.len,
        .target_len = traj_b.len,
    };
}

// ============================================================================
// HELPERS
// ============================================================================

fn bytesToBase32(bytes: *const [15]u8) [IDENTIFIER_LEN]u8 {
    var result: [IDENTIFIER_LEN]u8 = undefined;
    var bit_buf: u32 = 0;
    var bits: u5 = 0;
    var out_idx: usize = 0;

    for (bytes) |byte| {
        bit_buf = (bit_buf << 8) | byte;
        bits += 8;
        while (bits >= 5 and out_idx < IDENTIFIER_LEN) {
            bits -= 5;
            result[out_idx] = BASE32_LOWER[@as(u5, @intCast((bit_buf >> bits) & 0x1F))];
            out_idx += 1;
        }
    }
    while (out_idx < IDENTIFIER_LEN) {
        result[out_idx] = BASE32_LOWER[@as(u5, @intCast((bit_buf << @as(u5, @intCast(5 - @as(u8, bits)))) & 0x1F))];
        out_idx += 1;
        bits = 0;
    }
    return result;
}

fn deriveTrit(identifier: [IDENTIFIER_LEN]u8) Trit {
    var sum: u64 = 0;
    for (identifier) |ch| sum += ch;
    return switch (@as(u2, @intCast(sum % 3))) {
        0 => .zero,
        1 => .plus,
        2 => .minus,
        else => unreachable,
    };
}

fn charToTrit(ch: u8) Trit {
    return switch (ch) {
        'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U' => .zero,
        'b', 'c', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 'n', 'p', 'q', 'r', 's', 't', 'v', 'w', 'x', 'y', 'z',
        'B', 'C', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'V', 'W', 'X', 'Y', 'Z',
        => .plus,
        else => .minus,
    };
}

fn splitMix64(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn splitMix64Step(state: u64) u64 {
    return state +% 0x9e3779b97f4a7c15;
}

// ============================================================================
// TESTS
// ============================================================================

test "did:gay from seed deterministic" {
    const allocator = std.testing.allocator;
    const dg1 = try fromSeed(allocator, 1069);
    defer dg1.deinit();
    const dg2 = try fromSeed(allocator, 1069);
    defer dg2.deinit();

    try std.testing.expectEqualStrings(dg1.did, dg2.did);
}

test "did:gay prefix" {
    const allocator = std.testing.allocator;
    const dg = try fromSeed(allocator, 42);
    defer dg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, dg.did, DID_GAY_PREFIX));
    try std.testing.expectEqual(@as(usize, DID_GAY_PREFIX.len + IDENTIFIER_LEN), dg.did.len);
}

test "did:gay from trajectory" {
    const allocator = std.testing.allocator;
    const traj = [_]Trit{ .plus, .minus, .zero, .plus, .zero };
    const dg = try fromTrajectory(allocator, &traj);
    defer dg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, dg.did, DID_GAY_PREFIX));
}

test "did:gay parse roundtrip" {
    const allocator = std.testing.allocator;
    const dg = try fromSeed(allocator, 69);
    defer dg.deinit();

    const parsed = try parse(allocator, dg.did);
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, &dg.identifier, &parsed.identifier);
}

test "did:gay bridge from domain" {
    const allocator = std.testing.allocator;
    const dg = try bridgeFromDomain(allocator, "machines.gay");
    defer dg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, dg.did, DID_GAY_PREFIX));
}

test "did:gay bridge from address" {
    const allocator = std.testing.allocator;
    const dg = try bridgeFromAddress(allocator, "0xdeadbeef");
    defer dg.deinit();

    try std.testing.expect(std.mem.startsWith(u8, dg.did, DID_GAY_PREFIX));
}

test "did:gay bridge conservation check" {
    const traj_a = [_]Trit{ .plus, .minus, .zero };
    const traj_b = [_]Trit{ .plus, .minus, .zero };
    const result = checkBridgeConservation(&traj_a, &traj_b);
    try std.testing.expect(result.gf3_conserved);
}

test "did:gay bridge conservation violation" {
    const traj_a = [_]Trit{ .plus, .plus, .zero };
    const traj_b = [_]Trit{ .minus, .minus, .zero };
    const result = checkBridgeConservation(&traj_a, &traj_b);
    try std.testing.expect(!result.gf3_conserved);
}

test "did:gay trit is valid" {
    const allocator = std.testing.allocator;
    const dg = try fromSeed(allocator, 1069);
    defer dg.deinit();
    const v = @intFromEnum(dg.trit);
    try std.testing.expect(v >= -1 and v <= 1);
}

test "did:gay seed 1069 (canonical)" {
    const allocator = std.testing.allocator;
    const dg = try fromSeed(allocator, 1069);
    defer dg.deinit();

    // Must produce a valid 24-char identifier
    try std.testing.expectEqual(@as(usize, 24), dg.identifier.len);
    // Color must be 6 hex chars
    try std.testing.expectEqual(@as(usize, 6), dg.color_hex.len);
}
