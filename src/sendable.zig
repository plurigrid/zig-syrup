//! # Sendable Interface & BLE Transport
//! 
//! Syrup-encoded serialization and Swift-optimized BLE GATT characteristics.
//! Applicable in lux-flox-remote ecosystem for BCI data interchange.

const std = @import("std");
const syrup = @import("syrup.zig");
const tileable = @import("tileable.zig");
const CellId = tileable.CellId;

/// Swift BLE Service UUIDs (Candidate for lux-flox-remote)
pub const BCI_SERVICE_UUID = "FE84";
pub const BCI_TRIT_CHAR_UUID = "2D30C082-F39F-4CE6-923F-3484EA480596";
pub const BCI_DATA_CHAR_UUID = "2D30C083-F39F-4CE6-923F-3484EA480596";

pub const SendableCell = struct {
    id: CellId,
    trit: i8,
    payload: syrup.Value,

    pub fn encode(self: SendableCell, writer: anytype) !void {
        try writer.writeByte('<');
        try syrup.integer(self.id).encode(writer);
        try syrup.integer(self.trit).encode(writer);
        try self.payload.encode(writer);
        try writer.writeByte('>');
    }
};

/// Placeholder for Swift-compatible BLE notify/indicate logic
pub const BlePacket = struct {
    header: u8 = 0xA0,
    seq: u8,
    trit: i8,
    data: [16]u8,

    pub fn toBytes(self: BlePacket) [20]u8 {
        var buf: [20]u8 = undefined;
        buf[0] = self.header;
        buf[1] = self.seq;
        buf[2] = @as(u8, @bitCast(self.trit));
        @memcpy(buf[3..19], &self.data);
        buf[19] = 0xC0; // Stop byte
        return buf;
    }
};

test "sendable encoding" {
    const allocator = std.testing.allocator;
    const sc = SendableCell{
        .id = 42,
        .trit = 1,
        .payload = syrup.string("test"),
    };
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    try sc.encode(list.writer(allocator));
    try std.testing.expect(list.items.len > 0);
}

test "ble packet" {
    const pkt = BlePacket{
        .seq = 1,
        .trit = -1,
        .data = [_]u8{0} ** 16,
    };
    const bytes = pkt.toBytes();
    try std.testing.expect(bytes[0] == 0xA0);
    try std.testing.expect(bytes[2] == 0xFF); // -1 bitcast to u8
    try std.testing.expect(bytes[19] == 0xC0);
}
