//! cap_integration_test.zig — full-stack integration of the capability layer.
//!
//! Exercises every runtime + bridge module in a single scenario so that
//! their composition is locked in by tests, not just description:
//!
//!   - `cap.zig`            — Capability values, Revoker, expiry, narrow
//!   - `vat.zig`            — eventual-send, mailbox FIFO, virtual clock
//!   - `vat_replay.zig`     — turn_seq + now_ms recording for replay verify
//!   - `membrane.zig`       — in-vat confinement
//!   - `cross_vat_membrane.zig` — vat-spanning confinement
//!   - `sealer.zig`         — opaque envelope primitive
//!   - `sealed_sturdy.zig`  — time-limited swiss number tokens
//!   - `epoch_bridge.zig`   — wire-side EpochCapRef → runtime Revoker
//!
//! Scenario: "confined service offer with expiring bootstrap and partition demotion"
//!
//!   1. Service vat S spawns a Database actor.
//!   2. S mints a Sealer/Unsealer pair and issues a SealedSturdy token
//!      (envelope = swiss number ‖ expiry ‖ nonce). Hands envelope to client.
//!   3. Client vat C unseals the envelope (verifies expiry + MAC) to recover
//!      the swiss number. (In a real system this is what the bootstrap path
//!      would consume; here we just verify the round-trip.)
//!   4. S sets up a CrossVatMembrane (S → C) with policy_facet narrowed to
//!      read-only, wraps the Database cap, hands the outer cap to C.
//!   5. S also allocates an EpochCapRef at .cluster epoch and bridges it via
//!      EpochRevoker. The bridged Revoker is independent of the membrane's;
//!      a single shared-key cap could carry both, but here we test them in
//!      separate slots to prove orthogonality.
//!   6. C sends "read 1" through the membrane; relay reaches Database in S.
//!   7. Membrane is killed → further sends fail with `error.Revoked`.
//!
//! All assertions verify that authority gates compose — narrow + revoke +
//! expire + cross-vat relay all meet at a single send-site without
//! interfering.

const std = @import("std");
const testing = std.testing;

const cap = @import("cap.zig");
const vat = @import("vat.zig");
const vat_replay = @import("vat_replay.zig");
const membrane = @import("membrane.zig");
const cross_vat_membrane = @import("cross_vat_membrane.zig");
const sealer = @import("sealer.zig");
const sealed_sturdy = @import("sealed_sturdy.zig");
const epoch_bridge = @import("epoch_bridge.zig");
const epoch_capability = @import("epoch_capability.zig");

const Database = struct {
    rows: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pub const TRIT: i8 = 0; // ergodic
    /// Selector 0 = read, selector 1 = write. We only allow read across
    /// the membrane, so the cross-vat outer cap should narrow to {0}.
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{ 0, 1 });
    pub fn handle(self: *Database, _: *vat.Vat, m: vat.Message) !vat.Become {
        try self.rows.appendSlice(self.alloc, m.payload);
        return .same;
    }
};

test "integration: sealed sturdy + cross-vat membrane + epoch bridge compose" {
    const alloc = testing.allocator;

    // Two vats — service and client — with a shared virtual clock so expiry
    // and turn_seq are deterministic across the whole scenario.
    const Clock = struct {
        var now_ms: i64 = 1_000_000;
        fn read() i64 {
            return now_ms;
        }
    };
    Clock.now_ms = 1_000_000;

    var service = vat.Vat.init(alloc, 1);
    defer service.deinit();
    service.now_ms_fn = Clock.read;

    var client = vat.Vat.init(alloc, 2);
    defer client.deinit();
    client.now_ms_fn = Clock.read;

    // Replay log on the service side so we can verify turn_seq density.
    var log = vat_replay.Log.init(alloc);
    defer log.deinit();
    service.on_record = vat_replay.Log.callback;
    service.record_ctx = &log;

    // ========================================================================
    // 1. Service spawns Database actor.
    // ========================================================================
    var rows: std.ArrayList(u8) = .{};
    defer rows.deinit(alloc);
    const db_cap = try service.spawn(Database, .{ .rows = &rows, .alloc = alloc });
    try testing.expectEqual(cap.maskOf(&.{ 0, 1 }), db_cap.facet);

    // ========================================================================
    // 2. Service mints sealer pair + issues a sealed sturdy token.
    // ========================================================================
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE_DEADBEEF);
    const rng = prng.random();
    const seal_pair = sealer.Pair.generate(rng);

    const swiss: [sealed_sturdy.SWISS_LEN]u8 = .{0x42} ** sealed_sturdy.SWISS_LEN;
    const issued_at = Clock.read();
    const expires_at = issued_at + 60_000; // valid for 60 seconds
    var env_buf: [sealed_sturdy.SEALED_SIZE]u8 = undefined;
    const envelope = try sealed_sturdy.seal(seal_pair.sealer(), &env_buf, .{
        .swiss = swiss,
        .issued_at_ms = issued_at,
        .expires_at_ms = expires_at,
        .nonce = 0xABCD,
    }, rng);
    try testing.expectEqual(sealed_sturdy.SEALED_SIZE, envelope.len);

    // ========================================================================
    // 3. Client unseals envelope, verifies expiry + recovers swiss.
    // ========================================================================
    const recovered = try sealed_sturdy.unseal(seal_pair.unsealer(), envelope, Clock.read());
    try testing.expectEqualSlices(u8, &swiss, &recovered.swiss);
    try testing.expectEqual(@as(u64, 0xABCD), recovered.nonce);

    // Sanity: a far-future read fails with Expired.
    try testing.expectError(error.Expired, sealed_sturdy.unseal(seal_pair.unsealer(), envelope, expires_at));

    // ========================================================================
    // 4. Service wraps Database cap in a cross-vat read-only membrane.
    // ========================================================================
    var mem_rev = cap.Revoker{};
    var memb = cross_vat_membrane.CrossVatMembrane.init(&service, &client, &mem_rev);
    memb.policy_facet = cap.maskOf(&.{0}); // read-only
    const outer = try memb.wrap(db_cap);

    // Outer cap targets the client vat (where the forwarder lives).
    try testing.expectEqual(@as(cap.VatId, 2), cap.vatOf(outer.target));

    // ========================================================================
    // 5. Independently, service allocates an EpochCapRef at .cluster and
    //    bridges it via EpochRevoker. Demonstrates that the runtime cap
    //    layer can compose two distinct revokers (membrane + epoch).
    // ========================================================================
    var ecr = epoch_capability.EpochCapRef.init(0, false, .cluster, 0, 0);
    var epoch_rev = epoch_bridge.EpochRevoker.init(&ecr);
    epoch_rev.refresh(0);
    const epoch_gated_view = epoch_bridge.epochBackedCap(&epoch_rev, db_cap.target, db_cap.facet);
    try testing.expect(epoch_gated_view.isLive());

    // ========================================================================
    // 6. Client sends "row1" through the cross-vat membrane.
    // ========================================================================
    const client_sender = cap.Capability{ .target = cap.pack(2, 0) };
    try client.send(client_sender, outer, 0, "row1");
    _ = try client.quiesce(10); // forwarder runs, relays into service vat
    _ = try service.quiesce(10); // database receives the relay
    try testing.expectEqualStrings("row1", rows.items);

    // Write attempt is blocked at the membrane boundary by policy_facet.
    try testing.expectError(error.FacetDenies, client.send(client_sender, outer, 1, "WRITE"));

    // Verify replay log captured the database turn(s) with dense turn_seq.
    try testing.expect(log.turnCount() >= 1);
    try testing.expect(std.mem.indexOf(u8, log.bytes.items, "vat-turn") != null);

    // ========================================================================
    // 7. Kill the membrane → further sends fail with Revoked. The epoch-
    //    gated view is unaffected (orthogonal Revoker), demonstrating that
    //    each revocation scope is independent.
    // ========================================================================
    memb.kill();
    try testing.expectError(error.Revoked, client.send(client_sender, outer, 0, "denied"));
    try testing.expect(epoch_gated_view.isLive()); // epoch ref still valid

    // Also tear down the epoch side: revoke ecr → bridged cap dies.
    ecr.revoke();
    epoch_rev.refresh(0);
    try testing.expect(!epoch_gated_view.isLive());
}

test "integration: in-vat membrane + sealed sturdy + expiry compose" {
    // Smaller scenario verifying the *single-vat* membrane composes cleanly
    // with sealed sturdy expiry + cap-level expires_at_ms simultaneously.
    const alloc = testing.allocator;

    const Clock = struct {
        var now_ms: i64 = 100;
        fn read() i64 {
            return now_ms;
        }
    };
    Clock.now_ms = 100;

    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    v.now_ms_fn = Clock.read;

    var rows: std.ArrayList(u8) = .{};
    defer rows.deinit(alloc);
    const inner = try v.spawn(Database, .{ .rows = &rows, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = membrane.Membrane.init(&v, &rev);
    memb.policy_facet = cap.maskOf(&.{0});
    var outer = try memb.wrap(inner);
    outer.expires_at_ms = 200; // also has cap-level expiry

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer, 0, "early"); // before expiry, before revoke
    _ = try v.quiesce(10);
    try testing.expectEqualStrings("early", rows.items);

    // Wind clock past cap-level expiry — send fails with Expired even
    // though revoker is still alive.
    Clock.now_ms = 200;
    try testing.expectError(error.Expired, v.send(sender, outer, 0, "late"));
    try testing.expect(rev.isAlive());

    // Now revoke. The revoker check fires before the expiry check in
    // vat.send, so even rolling the clock back wouldn't revive the cap.
    Clock.now_ms = 100;
    memb.kill();
    try testing.expectError(error.Revoked, v.send(sender, outer, 0, "any"));
}
