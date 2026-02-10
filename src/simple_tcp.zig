const std = @import("std");
const net = std.net;
const posix = std.posix;

pub const Connection = struct {
    stream: net.Stream,
    address: net.Address,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
        const list = try net.getAddressList(allocator, host, port);
        defer list.deinit();

        if (list.addrs.len == 0) return error.UnknownHost;

        const address = list.addrs[0];
        const stream = try net.tcpConnectToAddress(address);

        return Connection{
            .stream = stream,
            .address = address,
        };
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};
