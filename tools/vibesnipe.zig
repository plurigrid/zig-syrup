const std = @import("std");
const syrup = @import("syrup");

// The Vibesnipe: Value Increments for Triadic Consensus
// Schema: <'increment {epoch: <int>, from: <sym>, to: <sym>, value: <dict>, vibe: <str>}>
//
// Triadic consensus flow:
//   Agent 0 (Alice/MINUS): Temporal validation
//   Agent 1 (Charlie/ERGODIC): Structural validation
//   Agent 2 (Bob/PLUS): Integrity validation
// 2/3 consensus required for finality

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    try stdout.print("\n╔════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║         VIBESNIPE TRIADIC CONSENSUS DEMONSTRATION        ║\n", .{});
    try stdout.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});

    // Phase 1: Boxxy's Security Commitment (MINUS validates temporal bounds)
    try stdout.print("Phase 1: MINUS Agent (Alice) - Temporal Validation\n", .{});
    try stdout.print("─────────────────────────────────────────────\n", .{});
    try emitIncrement(allocator, stdout, "alice", "charlie", "commitment", 1, "Timestamp verified: solution hash matches commitment within 1-hour window.");

    // Phase 2: Charlie's Structural Integrity (ERGODIC validates coherence)
    try stdout.print("\nPhase 2: ERGODIC Agent (Charlie) - Structural Validation\n", .{});
    try stdout.print("───────────────────────────────────────────────\n", .{});
    try emitIncrement(allocator, stdout, "charlie", "bob", "coherence", 1, "Proof structure verified: roots well-formed, counts in bounds, balance maintained (40%+ wikidata/gaymcp ratio).");

    // Phase 3: Bob's Merkle Integrity (PLUS validates completeness)
    try stdout.print("\nPhase 3: PLUS Agent (Bob) - Integrity Validation\n", .{});
    try stdout.print("──────────────────────────────────────────────\n", .{});
    try emitIncrement(allocator, stdout, "bob", "consensus", "finality", 1, "Merkle paths verified: GF(3) sum ≡ 0 (mod 3), all proofs lead to claimed roots.");

    // Consensus Result
    try stdout.print("\nConsensus Result: 3/3 UNANIMOUS ✓\n", .{});
    try stdout.print("─────────────────────────────────\n", .{});
    try emitIncrement(allocator, stdout, "consensus", "solver", "bounty_release", 10000, "Triadic consensus reached: CoplayBroadcast emitted, bounty transferred.");

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}

fn emitIncrement(
    allocator: std.mem.Allocator, 
    writer: anytype, 
    from: []const u8, 
    to: []const u8, 
    asset: []const u8, 
    amount: i64, 
    vibe: []const u8
) !void {
    // Construct the Record
    const label = syrup.Value.fromSymbol("increment");
    
    var dict_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
    defer dict_entries.deinit(allocator);
    
    // Keys must be sorted: amount, asset, epoch, from, to, vibe
    // 'a'mount, 'a'sset, 'e'poch, 'f'rom, 't'o, 'v'ibe
    
    // amount
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("amount"), .value = syrup.Value.fromInteger(amount) });
    // asset
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("asset"), .value = syrup.Value.fromSymbol(asset) });
    // epoch (fixed for demo)
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("epoch"), .value = syrup.Value.fromInteger(1) });
    // from
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("from"), .value = syrup.Value.fromSymbol(from) });
    // to
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("to"), .value = syrup.Value.fromSymbol(to) });
    // vibe
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("vibe"), .value = syrup.Value.fromString(vibe) });
    
    const dict_slice = try dict_entries.toOwnedSlice(allocator);
    defer allocator.free(dict_slice);

    const dict = syrup.Value.fromDictionary(dict_slice);
    
    // Fields list (just the dict)
    const fields_alloc = try allocator.alloc(syrup.Value, 1);
    defer allocator.free(fields_alloc);
    fields_alloc[0] = dict;
    
    const record = syrup.Value.fromRecord(&label, fields_alloc);
    
    // Encode
    var buf: [4096]u8 = undefined;
    const encoded = try record.encodeBuf(&buf);
    
    // Compute CID
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    const cid = std.fmt.bytesToHex(&hash, .lower);
    
    try writer.print("\n=== VIBESNIPE DETECTED ===\n", .{});
    try writer.print("From: {s} -> To: {s}\n", .{from, to});
    try writer.print("CID:  {s}\n", .{cid});
    try writer.print("Data: {s}\n", .{encoded});
}
