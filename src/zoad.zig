const std = @import("std");
const retty = @import("retty");
const terminal = @import("terminal"); 
const acp = @import("acp");
const nc_backend = @import("notcurses_backend");
const simple_tcp = @import("simple_tcp");
const syrup = @import("syrup");

const posix = std.posix;

// App State
const AppState = struct {
    should_quit: bool = false,
    messages: std.ArrayListUnmanaged([]const u8),
    input_buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    conn: ?simple_tcp.Connection = null,
    
    // Hardcoded Agent Address for MVP
    agent_host: []const u8 = "127.0.0.1",
    agent_port: u16 = 5555,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .messages = .{},
            .input_buffer = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.conn) |*c| c.close();
        for (self.messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
    }

    pub fn connectToAgent(self: *AppState) !void {
        self.conn = try simple_tcp.Connection.connect(self.allocator, self.agent_host, self.agent_port);
        try self.addMessage("Connected to agent at 127.0.0.1:5555");
        
        // Send Initialize
        const init_msg = acp.Message{
            .initialize = .{
                .protocol_version = 1,
                .client_capabilities = .{ .fs = null, .terminal = true },
                .client_info = .{ .name = "zoad", .version = "0.1.0" },
            },
        };
        const syrup_val = try init_msg.toSyrup(self.allocator);
        var buf: [1024]u8 = undefined;
        const encoded = try syrup_val.encodeBuf(&buf);
        try self.conn.?.stream.writeAll(encoded);
        try self.addMessage("Sent ACP Initialize");
    }

    pub fn addMessage(self: *AppState, msg: []const u8) !void {
        try self.messages.append(self.allocator, try self.allocator.dupe(u8, msg));
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Notcurses init handles raw mode
    var backend = try nc_backend.NotcursesBackend.init();
    defer backend.deinit();

    var app = AppState.init(allocator);
    defer app.deinit();

    try app.addMessage("Welcome to ZOAD (Zig Toad) - ACP Client");
    try app.addMessage("Type 'exit' or Ctrl+C to quit.");
    try app.addMessage("Type 'connect' to connect to local agent.");
    try app.addMessage("Running on Notcurses Backend!");

    while (!app.should_quit) {
        // ... layout code ...
        
        // Input Handling Logic (Simulated for now, would be nc_input event loop)
        // For MVP, if we typed 'connect', trigger connection
        if (app.input_buffer.items.len > 0 and std.mem.eql(u8, app.input_buffer.items, "connect")) {
             app.connectToAgent() catch |err| {
                 var buf: [64]u8 = undefined;
                 const err_msg = try std.fmt.bufPrint(&buf, "Connection failed: {}", .{err});
                 try app.addMessage(err_msg);
             };
             app.input_buffer.clearRetainingCapacity();
        }
        
        // ... render code ...

        // 1. Get terminal size from backend
        const width = backend.width;
        const height = backend.height;
        const area = retty.Rect{ .x = 0, .y = 0, .width = width, .height = height };

        // 2. Render
        var buf = retty.Buffer.init(area);

        // Layout: Chat (Top), Input (Bottom 3 lines)
        var chunks: [2]retty.Rect = undefined;
        const constraints = [_]retty.Constraint{
            .{ .min = 0 },
            .{ .length = 3 },
        };
        retty.Layout.vertical(&constraints).split(area, &chunks);
        
        const chat_area = chunks[0];
        const input_area = chunks[1];

        // Draw Chat
        var block = retty.Block.default()
            .withTitle(" Chat ")
            .withBorders(retty.Borders.ALL);
        block.render(chat_area, &buf);
        
        const inner_chat = block.innerArea(chat_area);
        
        var y = inner_chat.y;
        for (app.messages.items) |msg| {
            if (y >= inner_chat.y + inner_chat.height) break;
            buf.setString(inner_chat.x, y, msg, .{});
            y += 1;
        }

        // Draw Input
        var input_block = retty.Block.default()
            .withTitle(" Input ")
            .withBorders(retty.Borders.ALL);
        input_block.render(input_area, &buf);
        const inner_input = input_block.innerArea(input_area);

        // Format input string
        var input_fmt_buf: [256]u8 = undefined;
        const input_slice = try std.fmt.bufPrint(&input_fmt_buf, "> {s}_", .{app.input_buffer.items});
        buf.setString(inner_input.x, inner_input.y, input_slice, .{});

        // 3. Flush to Notcurses
        backend.draw(&buf);

        // 4. Input - Notcurses doesn't block nicely with this loop structure yet
        // For MVP, we'll just sleep a bit to simulate loop, 
        // effectively making it a non-interactive render test for now.
        // To make it interactive, we need notcurses_get_blocking via FFI.
        
        // TODO: Implement nc_input via NotcursesBackend
        std.Thread.sleep(100 * std.time.ns_per_ms);
        
        // Break after a few seconds for testing
        // app.should_quit = true; 
    }
}
