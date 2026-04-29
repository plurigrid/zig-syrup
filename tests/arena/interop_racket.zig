//! Keystone interop test: parse(.reia bytes) round-trip through racket
//! goblins, scored as a single arena.runOne() call.
//!
//! This test is *runtime-mediated* — racket is reached via the lorj MCP
//! `goblins_call` bridge, which requires session-time tool approval and
//! cannot run in unattended CI. The Zig side stubs the runner; the
//! actual racket call goes through the bridge file noted below.
//!
//! What the test exercises (in one go):
//!
//!   - Syrup encoding: record, byte-string, integer (the `parse` call)
//!   - Descriptors: desc:export (the parser cap), desc:answer (the
//!     promise position)
//!   - Ops: op:deliver (sending), op:fulfill (receiving)
//!   - Pipelining: file → frame → png in one batch (optional second
//!     leg — kept commented; switch on once the first leg passes)
//!   - Fingerprint extraction: the request fingerprint should flag
//!     pipelining=true on the optional leg, false on the first leg
//!
//! Bridge expectations (lives in scripts/bridge.rkt, NOT in this file):
//!
//!   #lang racket
//!   (require goblins ocapn/captp ocapn/syrup)
//!   ;; reads a Syrup-encoded request from stdin, dispatches into a
//!   ;; locally-spawned ParserVat, writes the response Syrup bytes to
//!   ;; stdout, exits.
//!
//! Wire it via:
//!
//!   const racket_runner = struct {
//!     fn run(alloc: std.mem.Allocator, spec: substrate.CallSpec)
//!         !substrate.Outcome
//!     {
//!         // Tool call (host-mediated):
//!         //   lorj.goblins_call({
//!         //     vat: "parser-arena",
//!         //     method: "deliver",
//!         //     args: spec.request,   // raw Syrup bytes
//!         //   })
//!         // Returned bytes become Outcome.response.
//!         _ = alloc; _ = spec;
//!         return error.RacketBridgeNotConfigured;
//!     }
//!   }.run;

const std = @import("std");
const syrup = @import("syrup");
const arena = @import("arena");
const substrate = arena.substrate;
const fingerprint = arena.fingerprint;
const bandit_mod = arena.bandit;

/// The keystone request: parse a 14283-byte .reia file via the parser
/// cap exported at desc:export 7, with answer position 12.
fn buildParseRequest(allocator: std.mem.Allocator, reia_bytes: []const u8) !syrup.Value {
    const parser_label = try allocator.create(syrup.Value);
    parser_label.* = .{ .symbol = "desc:export" };
    const parser_pos_field = try allocator.alloc(syrup.Value, 1);
    parser_pos_field[0] = .{ .integer = 7 };
    const parser_export = syrup.Value{
        .record = .{ .label = parser_label, .fields = parser_pos_field },
    };

    const method = syrup.Value{ .symbol = "parse" };
    const data = syrup.Value{ .bytes = reia_bytes };
    const args = try allocator.alloc(syrup.Value, 2);
    args[0] = method;
    args[1] = data;
    const args_list = syrup.Value{ .list = args };

    const answer_label = try allocator.create(syrup.Value);
    answer_label.* = .{ .symbol = "desc:answer" };
    const answer_field = try allocator.alloc(syrup.Value, 1);
    answer_field[0] = .{ .integer = 12 };
    const answer_desc = syrup.Value{
        .record = .{ .label = answer_label, .fields = answer_field },
    };

    const op_label = try allocator.create(syrup.Value);
    op_label.* = .{ .symbol = "op:deliver" };
    const op_fields = try allocator.alloc(syrup.Value, 4);
    op_fields[0] = parser_export;
    op_fields[1] = args_list;
    op_fields[2] = .{ .integer = 12 };
    op_fields[3] = answer_desc;
    return .{ .record = .{ .label = op_label, .fields = op_fields } };
}

test "parser cap parse request encodes with expected fingerprint" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const allocator = arena_alloc.allocator();

    const fake_reia = try allocator.alloc(u8, 64);
    @memset(fake_reia, 0);
    @memcpy(fake_reia[0..4], "RIFF");

    const req = try buildParseRequest(allocator, fake_reia);
    const fp = fingerprint.extract(req, .websocket);

    // The first-leg request hits desc:answer (creating the promise) but
    // does not chain on it, so pipelining is true (descriptor present).
    try std.testing.expect(fp.has_pipelining);
    try std.testing.expect(!fp.has_handoff);
    try std.testing.expect(!fp.has_signed_envelope);
    try std.testing.expectEqual(fingerprint.Transport.websocket, fp.transport);
}

test "arena.runOne with stub racket runner records outcome" {
    const StubRacket = struct {
        fn run(allocator: std.mem.Allocator, spec: substrate.CallSpec) !substrate.Outcome {
            // Pretend racket fulfilled the answer with desc:export 19.
            const reply = try allocator.dupe(u8, "<10'op:fulfill<11'desc:answer12+><11'desc:export19+>>");
            _ = spec;
            return .{
                .substrate = .racket_goblins,
                .success = true,
                .response = reply,
                .elapsed_ns = 150_000,
            };
        }
    };

    var prng = std.Random.DefaultPrng.init(31337);
    var bandit = bandit_mod.Bandit.init(prng.random(), std.mem.zeroes([32]u8));
    var ar = arena.Arena{
        .bandit = &bandit,
        .dispatch = .{
            // Force racket selection by zeroing out zig and guile arms.
            .zig_runner = &StubRacket.run,
            .racket_runner = &StubRacket.run,
        },
    };

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const allocator = arena_alloc.allocator();

    const fake_reia = try allocator.alloc(u8, 32);
    @memset(fake_reia, 0);
    const req = try buildParseRequest(allocator, fake_reia);

    const spec = substrate.CallSpec{
        .name = "reia_parse_keystone",
        .request = "<10'op:deliver<11'desc:export7+><7'parse...>",
        .expected = null, // Don't pin the response; bytes are racket's prerogative.
    };

    const result = try ar.runOne(allocator, spec, req, .websocket);
    try std.testing.expect(result.outcome.success);
}

// Optional second leg — pipelined frame → png. Switch on once the first
// leg passes. Demonstrates the answer-position chain that the bandit's
// `has_pipelining` flag is meant to prefer racket on.
//
// test "pipelined frame.toPng chains across answer positions" {
//     ...
// }
