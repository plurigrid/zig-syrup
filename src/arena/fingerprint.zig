//! TestFingerprint: 9-bit context summary of an OCapN message used to
//! index the bandit table. The fingerprint must be cheap, total, and
//! stable across protocol versions modulo a spec-version reset.
//!
//! Cheap: single recursive walk of the syrup.Value tree.
//! Total: every Value variant produces a fingerprint, no panics.
//! Stable: feature names map to symbol-string matches, not byte offsets,
//!   so canonical-form re-encoding of the same record yields the same
//!   fingerprint.

const std = @import("std");
const syrup = @import("../syrup.zig");

pub const Transport = enum(u2) {
    unknown = 0,
    websocket = 1,
    tor = 2,
    tcp = 3,
};

/// 11 bits of context. Layout chosen so the underlying u11 packs into a
/// single bandit-table row index (2048 cells). Two extra flags
/// (tw_outlier, fv_outlier) come from the boxxy tapes-conformance loop:
/// when a tape diff's StructuredDecompositions bound exceeds k_w or k_f,
/// the corresponding outlier flag flips and the bandit biases substrate
/// selection toward the silver (-1) reference impl. Wired by the host
/// at session time; default both false when no SD.jl bridge is active.
pub const TestFingerprint = packed struct(u11) {
    has_handoff: bool,
    has_signed_envelope: bool,
    has_pipelining: bool,
    has_gc_exports: bool,
    has_promise_listen: bool,
    has_abort: bool,
    has_break: bool,
    transport: Transport,
    /// True when treewidth(diff_graph) > k_w from Conformance.juvix.
    tw_outlier: bool,
    /// True when fv-num-of-shape(diff_graph) > k_f from Conformance.juvix.
    fv_outlier: bool,

    pub fn toIndex(self: TestFingerprint) u11 {
        return @bitCast(self);
    }

    pub fn fromIndex(i: u11) TestFingerprint {
        return @bitCast(i);
    }

    pub fn empty() TestFingerprint {
        return .{
            .has_handoff = false,
            .has_signed_envelope = false,
            .has_pipelining = false,
            .has_gc_exports = false,
            .has_promise_listen = false,
            .has_abort = false,
            .has_break = false,
            .transport = .unknown,
            .tw_outlier = false,
            .fv_outlier = false,
        };
    }
};

/// Walk a Syrup record tree and accumulate the fingerprint flags. The
/// transport channel must be supplied separately — it's not encoded in
/// the message itself.
pub fn extract(v: syrup.Value, transport: Transport) TestFingerprint {
    return extractWithOutliers(v, transport, false, false);
}

/// Same, but with treewidth/fv-num outlier flags supplied externally
/// (typically by a SD.jl bridge that classified the current tape diff).
pub fn extractWithOutliers(
    v: syrup.Value,
    transport: Transport,
    tw_outlier: bool,
    fv_outlier: bool,
) TestFingerprint {
    var fp = TestFingerprint.empty();
    fp.transport = transport;
    fp.tw_outlier = tw_outlier;
    fp.fv_outlier = fv_outlier;
    walk(v, &fp);
    return fp;
}

fn walk(v: syrup.Value, fp: *TestFingerprint) void {
    switch (v) {
        .record => |r| {
            // The label drives most flags. Nested records walk into
            // fields too — gc-exports payloads contain desc:export
            // descriptors which we do *not* want to flag as pipelining.
            if (r.label.* == .symbol) {
                const lbl = r.label.symbol;
                if (eqAny(lbl, &.{ "desc:handoff-give", "desc:handoff-receive" })) fp.has_handoff = true;
                if (eqAny(lbl, &.{"desc:sig-envelope"})) fp.has_signed_envelope = true;
                if (eqAny(lbl, &.{"desc:answer"})) fp.has_pipelining = true;
                if (std.mem.eql(u8, lbl, "op:gc-exports")) fp.has_gc_exports = true;
                if (std.mem.eql(u8, lbl, "op:listen")) fp.has_promise_listen = true;
                if (std.mem.eql(u8, lbl, "op:abort")) fp.has_abort = true;
                if (std.mem.eql(u8, lbl, "op:break")) fp.has_break = true;
            }
            for (r.fields) |f| walk(f, fp);
        },
        .list => |items| for (items) |it| walk(it, fp),
        .set => |items| for (items) |it| walk(it, fp),
        .dictionary => |entries| for (entries) |e| {
            walk(e.key, fp);
            walk(e.value, fp);
        },
        .tagged => |t| walk(t.payload.*, fp),
        .@"error" => |e| walk(e.data.*, fp),
        else => {},
    }
}

fn eqAny(s: []const u8, choices: []const []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}

test "extract on op:deliver with desc:answer flags pipelining" {
    const ans_label = syrup.Value{ .symbol = "desc:answer" };
    const ans_fields = [_]syrup.Value{.{ .integer = 12 }};
    const ans = syrup.Value{ .record = .{ .label = &ans_label, .fields = &ans_fields } };

    const op_label = syrup.Value{ .symbol = "op:deliver" };
    const op_fields = [_]syrup.Value{ ans, .{ .list = &.{} }, .{ .integer = 13 }, ans };
    const op = syrup.Value{ .record = .{ .label = &op_label, .fields = &op_fields } };

    const fp = extract(op, .websocket);
    try std.testing.expect(fp.has_pipelining);
    try std.testing.expect(!fp.has_handoff);
    try std.testing.expectEqual(Transport.websocket, fp.transport);
}

test "fingerprint round trip via index" {
    const fp = TestFingerprint{
        .has_handoff = true,
        .has_signed_envelope = false,
        .has_pipelining = true,
        .has_gc_exports = false,
        .has_promise_listen = true,
        .has_abort = false,
        .has_break = false,
        .transport = .tor,
        .tw_outlier = true,
        .fv_outlier = false,
    };
    const idx = fp.toIndex();
    const fp2 = TestFingerprint.fromIndex(idx);
    try std.testing.expectEqual(fp, fp2);
}

test "tw_outlier flag distinguishes bandit cells" {
    const ans_label = syrup.Value{ .symbol = "desc:answer" };
    const ans_fields = [_]syrup.Value{.{ .integer = 12 }};
    const ans = syrup.Value{ .record = .{ .label = &ans_label, .fields = &ans_fields } };
    const op_label = syrup.Value{ .symbol = "op:deliver" };
    const op_fields = [_]syrup.Value{ ans, .{ .list = &.{} } };
    const op = syrup.Value{ .record = .{ .label = &op_label, .fields = &op_fields } };

    const fp_normal = extractWithOutliers(op, .websocket, false, false);
    const fp_outlier = extractWithOutliers(op, .websocket, true, false);
    try std.testing.expect(fp_normal.toIndex() != fp_outlier.toIndex());
    try std.testing.expect(fp_outlier.tw_outlier);
    try std.testing.expect(!fp_outlier.fv_outlier);
}
