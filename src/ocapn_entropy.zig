//! OS-backed cryptographic entropy for OCapN secrets and unguessable names.
const std = @import("std");

/// Fill the entire slice or stop: callers must never publish secrets after an
/// entropy failure. Keep the existing infallible generators without a weak
/// PRNG fallback. A call-local backend avoids shared mutable RNG state.
pub fn fill(bytes: []u8) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    threaded.io().randomSecure(bytes) catch @panic("OCapN cryptographic entropy unavailable");
}

test "entropy fills only the requested slice, including empty and large slices" {
    var buffer: [1026]u8 = @splat(0xa5);
    for ([_]usize{ 0, 1, 32, 256, 1024 }) |len| {
        @memset(&buffer, 0xa5);
        fill(buffer[1..][0..len]);
        try std.testing.expectEqual(@as(u8, 0xa5), buffer[0]);
        for (buffer[1 + len ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        // A smoke check, not a statistical proof of cryptographic security.
        if (len >= 32) try std.testing.expect(!std.mem.allEqual(u8, buffer[1..][0..len], 0xa5));
    }
}
