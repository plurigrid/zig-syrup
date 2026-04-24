//! cgt_corpus.zig — the 70-color **Color of Greatest Trickery** corpus used
//! by all path-invariance tests (Square A/B/C/D and the cross-runtime
//! harness in `examples/interop/path_invariance.zig`).
//!
//! Layout:
//!   [0]      CGT — mid-grey (0.5, 0.5, 0.5), trit-0 ergodic equator
//!   [1..8]   8 cube vertices in {0,1}^3 (extremal corners under GF(3))
//!   [9..69]  60 deterministic splitmix samples (seed = 69420)
//!
//! All callers must consume the same generator so changing the recipe in
//! one place updates every test.

const std = @import("std");
const splitmix = @import("splitmix.zig");
const color_mod = @import("color.zig");
const RGB = color_mod.RGB;

pub const CORPUS_LEN: usize = 70;
pub const CORPUS_SEED: u64 = 69420;

pub fn fill(buf: *[CORPUS_LEN]RGB) void {
    buf[0] = RGB{ .r = 0.5, .g = 0.5, .b = 0.5 };

    var i: usize = 1;
    var bits: u3 = 0;
    while (i <= 8) : ({
        i += 1;
        bits +%= 1;
    }) {
        buf[i] = RGB{
            .r = if ((bits & 0b001) != 0) 1.0 else 0.0,
            .g = if ((bits & 0b010) != 0) 1.0 else 0.0,
            .b = if ((bits & 0b100) != 0) 1.0 else 0.0,
        };
    }

    var idx: usize = 9;
    var k: u64 = 0;
    while (idx < CORPUS_LEN) : ({
        idx += 1;
        k += 1;
    }) {
        const w = splitmix.colorAt(k, CORPUS_SEED);
        buf[idx] = RGB{ .r = w.r, .g = w.g, .b = w.b };
    }
}

test "cgt corpus has expected layout" {
    var buf: [CORPUS_LEN]RGB = undefined;
    fill(&buf);
    try std.testing.expectEqual(@as(f64, 0.5), buf[0].r);
    try std.testing.expectEqual(@as(f64, 0.5), buf[0].g);
    try std.testing.expectEqual(@as(f64, 0.5), buf[0].b);
    // Cube vertex 0b111 should be (1,1,1).
    try std.testing.expectEqual(@as(f64, 1.0), buf[8].r);
    try std.testing.expectEqual(@as(f64, 1.0), buf[8].g);
    try std.testing.expectEqual(@as(f64, 1.0), buf[8].b);
    // Splitmix samples land in [0,1]^3.
    for (buf[9..]) |c| {
        try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
        try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
        try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);
    }
}
