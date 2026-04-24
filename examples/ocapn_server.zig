//! Runnable OCapN server — accepts one connection from a Guile or Racket
//! Goblins peer, performs the spec-conformant op:start-session handshake,
//! registers a demo sturdy, and prints every incoming op:deliver-only.
//!
//! Run:
//!   zig build ocapn-server -- 3927
//!
//! Then from Guile Goblins:
//!   (define peer (resolve-sturdy (string->sturdy-ref "ocapn://...")))
//!   ($ peer 'hello 42)

const std = @import("std");
const syrup = @import("syrup");
const transport = @import("ocapn_transport");
const handshake = @import("ocapn_handshake");
const location_mod = @import("ocapn_location");
const bootstrap = @import("ocapn_bootstrap");
const vat_mod = @import("ocapn_vat");
const compat = @import("compat");
const ByteList = std.array_list.Managed(u8);

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = 3927;

    const kp = try handshake.KeyPair.generate();

    // Location.designator holds the printable form (Racket convention):
    // base32(pubkey) for tcp/onion. Same value flows through both the
    // wire frame (Syrup string) and the URI authority — single source.
    var b32_buf = ByteList.init(allocator);
    defer b32_buf.deinit();
    try location_mod.base32LowerEncode(&b32_buf, &kp.pub_key);
    const designator_b32 = b32_buf.items;

    const my_loc = location_mod.Location{
        .netlayer = .tcp,
        .designator = designator_b32,
    };

    const demo_swiss = bootstrap.freshSwiss();
    const demo_ref = location_mod.SturdyRef{
        .location = my_loc,
        .swiss = demo_swiss,
    };
    const uri = try demo_ref.toUri(allocator);
    defer allocator.free(uri);

    const addr = try compat.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    var msg_buf: [512]u8 = undefined;
    const banner = try std.fmt.bufPrint(
        &msg_buf,
        "OCapN server listening on 127.0.0.1:{d}\nsturdy uri: {s}\n",
        .{ port, uri },
    );
    compat.stdoutWrite(banner);

    const accepted = try server.accept();
    var vat = vat_mod.Vat.init(
        allocator,
        transport.OcapnConnection.init(allocator, accepted.stream),
        kp,
        my_loc,
    );
    defer vat.deinit();

    _ = try vat.exportSturdy(demo_swiss);

    try vat.sendHandshake();
    try vat.receiveHandshake();
    compat.stdoutWrite("handshake established\n");

    while (true) {
        var v = vat.recvNext() catch |err| {
            const line = try std.fmt.bufPrint(&msg_buf, "recv error: {s}\n", .{@errorName(err)});
            compat.stdoutWrite(line);
            break;
        };
        defer v.deinitAll(allocator);

        if (v == .record) {
            const tag = if (v.record.label.* == .symbol) v.record.label.symbol else "<non-sym>";
            const line = try std.fmt.bufPrint(&msg_buf, "<- {s} ({d} fields)\n", .{ tag, v.record.fields.len });
            compat.stdoutWrite(line);
        } else {
            compat.stdoutWrite("<- non-record value\n");
        }
    }
}
