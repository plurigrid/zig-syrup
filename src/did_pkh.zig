//! did:pkh — Public Key Hash DID method in Zig
//!
//! Maps blockchain addresses to DIDs via CAIP-10 account identifiers.
//! Primary use: Sign-In with Ethereum (SIWE / EIP-4361).
//!
//! Format: did:pkh:<caip10-account-id>
//!   e.g., did:pkh:eip155:1:0xab16a96D359eC26a11e2C2b3d8f8B8942d5Bfcdb
//!         did:pkh:solana:4sGjMW1sUnHzSxGspuhpqLDx6wiyjNtZ:GCIZ3...
//!         did:pkh:bip122:000000000019d6689c085ae165831e93:128Lk...
//!
//! CAIP-10: <namespace>:<chain_reference>:<account_address>
//! Namespaces: eip155 (Ethereum), solana, bip122, cosmos, polkadot, etc.
//!
//! Bridge to did:gay: account address → trit trajectory (address bytes mod 3).
//! Capability inference: chain namespace determines available operations.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// TYPES
// ============================================================================

/// Chain namespace (CAIP-2 namespace)
pub const ChainNamespace = enum {
    eip155, // Ethereum + L2s
    solana,
    bip122, // Bitcoin
    cosmos,
    polkadot,
    aptos,
    unknown,

    pub fn fromString(s: []const u8) ChainNamespace {
        if (std.mem.eql(u8, s, "eip155")) return .eip155;
        if (std.mem.eql(u8, s, "solana")) return .solana;
        if (std.mem.eql(u8, s, "bip122")) return .bip122;
        if (std.mem.eql(u8, s, "cosmos")) return .cosmos;
        if (std.mem.eql(u8, s, "polkadot")) return .polkadot;
        if (std.mem.eql(u8, s, "aptos")) return .aptos;
        return .unknown;
    }

    /// GF(3) trit for chain type:
    ///   EVM chains (+1): smart contract execution = generative
    ///   UTXO chains (-1): verification-oriented
    ///   Account chains (0): balanced
    pub fn trit(self: ChainNamespace) Trit {
        return switch (self) {
            .eip155, .aptos => .plus,
            .bip122 => .minus,
            .solana, .cosmos, .polkadot, .unknown => .zero,
        };
    }

    /// Capability set inferred from chain namespace
    pub fn capabilities(self: ChainNamespace) []const []const u8 {
        return switch (self) {
            .eip155 => &.{ "sign", "verify", "contract_call", "transfer", "delegate" },
            .solana => &.{ "sign", "verify", "program_invoke", "transfer" },
            .bip122 => &.{ "sign", "verify", "transfer" },
            .cosmos => &.{ "sign", "verify", "transfer", "ibc_transfer", "governance" },
            .aptos => &.{ "sign", "verify", "move_call", "transfer" },
            .polkadot => &.{ "sign", "verify", "transfer", "governance", "staking" },
            .unknown => &.{ "sign", "verify" },
        };
    }
};

/// Parsed did:pkh identifier
pub const DidPkh = struct {
    did: []const u8,
    namespace: ChainNamespace,
    chain_ref: []const u8,
    address: []const u8,
    trit: Trit,
    allocator: Allocator,

    pub fn deinit(self: *const DidPkh) void {
        self.allocator.free(self.did);
        self.allocator.free(self.chain_ref);
        self.allocator.free(self.address);
    }
};

/// GF(3) trit
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn fromByte(byte: u8) Trit {
        return switch (@mod(byte, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

// ============================================================================
// PARSING
// ============================================================================

const DID_PKH_PREFIX = "did:pkh:";

/// Parse a did:pkh string.
pub fn parse(allocator: Allocator, did: []const u8) !DidPkh {
    if (!std.mem.startsWith(u8, did, DID_PKH_PREFIX)) {
        return error.InvalidDidPkhPrefix;
    }

    const caip10 = did[DID_PKH_PREFIX.len..];

    // Split CAIP-10: namespace:chain_reference:account_address
    var colons: [2]usize = undefined;
    var found: usize = 0;
    for (caip10, 0..) |ch, i| {
        if (ch == ':' and found < 2) {
            colons[found] = i;
            found += 1;
        }
    }
    if (found < 2) return error.InvalidCaip10;

    const ns_str = caip10[0..colons[0]];
    const chain_ref = caip10[colons[0] + 1 .. colons[1]];
    const address = caip10[colons[1] + 1 ..];

    if (address.len == 0) return error.EmptyAddress;

    const namespace = ChainNamespace.fromString(ns_str);

    return .{
        .did = try allocator.dupe(u8, did),
        .namespace = namespace,
        .chain_ref = try allocator.dupe(u8, chain_ref),
        .address = try allocator.dupe(u8, address),
        .trit = namespace.trit(),
        .allocator = allocator,
    };
}

/// Construct a did:pkh from components.
pub fn fromComponents(
    allocator: Allocator,
    namespace: []const u8,
    chain_ref: []const u8,
    address: []const u8,
) !DidPkh {
    const did = try std.fmt.allocPrint(
        allocator,
        DID_PKH_PREFIX ++ "{s}:{s}:{s}",
        .{ namespace, chain_ref, address },
    );
    defer allocator.free(did);
    return parse(allocator, did);
}

// ============================================================================
// DID DOCUMENT GENERATION
// ============================================================================

/// Generate a minimal did:pkh DID Document.
/// did:pkh documents use blockchainAccountId in the verification method.
pub fn toDidDocument(allocator: Allocator, dp: DidPkh) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"@context":["https://www.w3.org/ns/did/v1","https://w3id.org/security/suites/jws-2020/v1"],"id":"{s}","verificationMethod":[{{"id":"{s}#blockchainAccountId","type":"EcdsaSecp256k1RecoveryMethod2020","controller":"{s}","blockchainAccountId":"{s}:{s}:{s}"}}],"authentication":["{s}#blockchainAccountId"]}}
    , .{ dp.did, dp.did, dp.did, @tagName(dp.namespace), dp.chain_ref, dp.address, dp.did });
}

// ============================================================================
// BRIDGE TO did:gay (via trit trajectory)
// ============================================================================

/// Convert a blockchain address to a trit trajectory for bisimulation.
/// Hex addresses: each hex nibble mod 3 → trit.
/// Non-hex addresses: each byte mod 3 → trit.
pub fn addressToTritTrajectory(allocator: Allocator, address: []const u8) ![]Trit {
    // Strip 0x prefix for Ethereum addresses
    const addr = if (std.mem.startsWith(u8, address, "0x")) address[2..] else address;

    var trajectory = try allocator.alloc(Trit, addr.len);
    for (addr, 0..) |ch, i| {
        trajectory[i] = Trit.fromByte(ch);
    }
    return trajectory;
}

/// Compute GF(3) balance of an address trajectory.
pub fn addressGf3Balance(address: []const u8) Trit {
    const addr = if (std.mem.startsWith(u8, address, "0x")) address[2..] else address;
    var sum: i8 = 0;
    for (addr) |ch| {
        sum = @mod(sum + @as(i8, @intFromEnum(Trit.fromByte(ch))) + 3, 3);
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

test "did:pkh parse Ethereum" {
    const allocator = std.testing.allocator;
    const dp = try parse(allocator, "did:pkh:eip155:1:0xab16a96D359eC26a11e2C2b3d8f8B8942d5Bfcdb");
    defer dp.deinit();

    try std.testing.expectEqual(ChainNamespace.eip155, dp.namespace);
    try std.testing.expectEqualStrings("1", dp.chain_ref);
    try std.testing.expectEqual(Trit.plus, dp.trit); // EVM = generative
}

test "did:pkh parse Cosmos" {
    const allocator = std.testing.allocator;
    const dp = try parse(allocator, "did:pkh:cosmos:cosmoshub-4:cosmos1xyz");
    defer dp.deinit();

    try std.testing.expectEqual(ChainNamespace.cosmos, dp.namespace);
    try std.testing.expectEqual(Trit.zero, dp.trit);
}

test "did:pkh parse Bitcoin" {
    const allocator = std.testing.allocator;
    const dp = try parse(allocator, "did:pkh:bip122:000000000019d6689c085ae165831e93:128LkPSMRb");
    defer dp.deinit();

    try std.testing.expectEqual(ChainNamespace.bip122, dp.namespace);
    try std.testing.expectEqual(Trit.minus, dp.trit); // UTXO = verification
}

test "did:pkh rejects invalid" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDidPkhPrefix, parse(allocator, "did:web:example.com"));
}

test "did:pkh address trit trajectory" {
    const allocator = std.testing.allocator;
    const traj = try addressToTritTrajectory(allocator, "0xab16a96D");
    defer allocator.free(traj);
    // "ab16a96D" = 8 chars → 8 trits
    try std.testing.expectEqual(@as(usize, 8), traj.len);
}

test "did:pkh DID document generation" {
    const allocator = std.testing.allocator;
    const dp = try parse(allocator, "did:pkh:eip155:1:0xdeadbeef");
    defer dp.deinit();

    const doc = try toDidDocument(allocator, dp);
    defer allocator.free(doc);

    try std.testing.expect(std.mem.indexOf(u8, doc, "did:pkh:eip155:1:0xdeadbeef") != null);
}

test "did:pkh chain capabilities" {
    try std.testing.expect(ChainNamespace.eip155.capabilities().len == 5);
    try std.testing.expect(ChainNamespace.bip122.capabilities().len == 3);
}

test "did:pkh GF(3) balance deterministic" {
    const b1 = addressGf3Balance("0xdeadbeef");
    const b2 = addressGf3Balance("0xdeadbeef");
    try std.testing.expectEqual(b1, b2);
}
