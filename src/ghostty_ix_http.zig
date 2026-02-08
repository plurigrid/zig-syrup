/// Ghostty IX HTTP Server — Feedback & Monitoring
///
/// Provides JSON HTTP endpoints for monitoring IX execution state.
/// Runs on port :7071 (configurable), serves:
///   GET /status  → execution state, trit histogram, mode
///   GET /colors  → current spatial colors (node_id → hex_color)
///   GET /focus   → current focus node, level, adjacent IDs
///   POST /command → execute IX command, return result
///
/// Design references:
/// - metauni_bridge.py (SSE :7070 → HTTP :7071 pattern)
/// - ghostty_web_server.zig (TCP accept loop pattern)
/// - Zig std.net for HTTP/1.1 minimal server

const std = @import("std");
const ghostty_ix = @import("ghostty_ix");

const CommandDispatcher = ghostty_ix.CommandDispatcher;
const CommandType = ghostty_ix.CommandType;
const Command = ghostty_ix.Command;
const ExecutionResult = ghostty_ix.ExecutionResult;

/// HTTP response with status, headers, body
pub const HttpResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *HttpResponse) void {
        if (self.allocator) |alloc| {
            alloc.free(self.body);
        }
    }

    /// Format as HTTP/1.1 response bytes
    pub fn toBytes(self: HttpResponse, allocator: std.mem.Allocator) ![]u8 {
        const status_text = switch (self.status) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        return std.fmt.allocPrint(allocator,
            "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
            .{ self.status, status_text, self.content_type, self.body.len, self.body },
        );
    }
};

/// IX HTTP Server for monitoring and feedback
pub const IxHttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16 = 7071,
    dispatcher: *CommandDispatcher,
    running: bool = false,

    // Cached state for GET endpoints (updated by dispatcher)
    focus_node_id: u32 = 0,
    focus_level: f32 = 1.0,
    adjacent_ids: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    adjacent_count: u8 = 0,
    mode: []const u8 = "idle",

    // Spatial colors cache (up to 64 nodes)
    color_ids: [64]u32 = [_]u32{0} ** 64,
    color_hexes: [64][7]u8 = [_][7]u8{[_]u8{0} ** 7} ** 64,
    color_count: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, dispatcher: *CommandDispatcher) IxHttpServer {
        return IxHttpServer{
            .allocator = allocator,
            .dispatcher = dispatcher,
        };
    }

    /// Route HTTP request to appropriate handler
    pub fn route(self: *IxHttpServer, method: []const u8, path: []const u8, body: []const u8) !HttpResponse {
        if (std.mem.eql(u8, path, "/status")) {
            if (std.mem.eql(u8, method, "GET")) {
                return self.statusHandler();
            }
            return HttpResponse{ .status = 405, .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
        } else if (std.mem.eql(u8, path, "/colors")) {
            if (std.mem.eql(u8, method, "GET")) {
                return self.colorHandler();
            }
            return HttpResponse{ .status = 405, .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
        } else if (std.mem.eql(u8, path, "/focus")) {
            if (std.mem.eql(u8, method, "GET")) {
                return self.focusHandler();
            }
            return HttpResponse{ .status = 405, .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
        } else if (std.mem.eql(u8, path, "/command")) {
            if (std.mem.eql(u8, method, "POST")) {
                return self.commandHandler(body);
            }
            return HttpResponse{ .status = 405, .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
        }

        return HttpResponse{ .status = 404, .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    }

    /// GET /status → execution state, trit histogram, mode
    fn statusHandler(self: *IxHttpServer) HttpResponse {
        const hist = self.dispatcher.trit_histogram;
        const total = hist[0] + hist[1] + hist[2];
        const balance_sum = @as(i64, hist[2]) - @as(i64, hist[0]);
        const balanced = @mod(balance_sum, 3) == 0;

        const body = std.fmt.allocPrint(self.allocator,
            "{{\"mode\":\"{s}\",\"trit_histogram\":{{\"minus\":{d},\"ergodic\":{d},\"plus\":{d}}},\"total_commands\":{d},\"gf3_balanced\":{},\"last_trit\":{d}}}",
            .{ self.mode, hist[0], hist[1], hist[2], total, balanced, self.dispatcher.last_command_trit },
        ) catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"allocation failed\"}" };

        return HttpResponse{
            .status = 200,
            .content_type = "application/json",
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// GET /colors → current spatial colors as node_id:hex pairs
    fn colorHandler(self: *IxHttpServer) HttpResponse {
        // Build JSON object with color mappings
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();

        writer.writeAll("{\"colors\":{") catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"buffer overflow\"}" };

        for (0..self.color_count) |idx| {
            if (idx > 0) {
                writer.writeAll(",") catch break;
            }
            // "node_id":"#RRGGBB"
            std.fmt.format(writer, "\"{d}\":\"#{s}\"", .{ self.color_ids[idx], self.color_hexes[idx] }) catch break;
        }

        writer.writeAll("}}") catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"buffer overflow\"}" };

        const written = stream.getWritten();
        const body = self.allocator.dupe(u8, written) catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"allocation failed\"}" };

        return HttpResponse{
            .status = 200,
            .content_type = "application/json",
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// GET /focus → current focus node info
    fn focusHandler(self: *IxHttpServer) HttpResponse {
        // Build adjacent array
        var adj_buf: [256]u8 = undefined;
        var adj_stream = std.io.fixedBufferStream(&adj_buf);
        var adj_writer = adj_stream.writer();

        adj_writer.writeAll("[") catch {};
        for (0..self.adjacent_count) |idx| {
            if (idx > 0) {
                adj_writer.writeAll(",") catch break;
            }
            std.fmt.format(adj_writer, "{d}", .{self.adjacent_ids[idx]}) catch break;
        }
        adj_writer.writeAll("]") catch {};

        const adj_str = adj_stream.getWritten();

        const body = std.fmt.allocPrint(self.allocator,
            "{{\"node_id\":{d},\"focus_level\":{d:.3},\"adjacent_ids\":{s}}}",
            .{ self.focus_node_id, self.focus_level, adj_str },
        ) catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"allocation failed\"}" };

        return HttpResponse{
            .status = 200,
            .content_type = "application/json",
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// POST /command → execute command via dispatcher
    fn commandHandler(self: *IxHttpServer, body: []const u8) HttpResponse {
        // Simple JSON parse: extract "action" field
        // Format: {"action": "shell ls -la"} or {"action": "pause"} etc.
        const action = extractJsonString(body, "action") orelse {
            return HttpResponse{ .status = 400, .content_type = "application/json", .body = "{\"error\":\"missing action field\"}" };
        };

        // Parse action into command type + args
        var parts = std.mem.splitSequence(u8, action, " ");
        const cmd_name = parts.next() orelse {
            return HttpResponse{ .status = 400, .content_type = "application/json", .body = "{\"error\":\"empty action\"}" };
        };

        const rest = if (parts.rest().len > 0) parts.rest() else "";

        const command_type: CommandType = if (std.mem.eql(u8, cmd_name, "shell"))
            .shell
        else if (std.mem.eql(u8, cmd_name, "query"))
            .query
        else if (std.mem.eql(u8, cmd_name, "focus"))
            .focus_update
        else if (std.mem.eql(u8, cmd_name, "bim"))
            .bim
        else if (std.mem.eql(u8, cmd_name, "pause") or std.mem.eql(u8, cmd_name, "resume") or std.mem.eql(u8, cmd_name, "homotopy"))
            .continuation
        else if (std.mem.eql(u8, cmd_name, "stellogen"))
            .stellogen
        else if (std.mem.eql(u8, cmd_name, "propagate"))
            .propagator_cmd
        else
            .noop;

        // For continuation commands, prepend the subcommand back into args
        const args = if (command_type == .continuation)
            action
        else
            rest;

        const cmd = Command{
            .command_type = command_type,
            .args = args,
            .modifiers = 0,
        };

        const result = self.dispatcher.execute(cmd) catch |err| {
            const err_body = std.fmt.allocPrint(self.allocator,
                "{{\"success\":false,\"error\":\"{s}\"}}",
                .{@errorName(err)},
            ) catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"execution failed\"}" };

            return HttpResponse{
                .status = 500,
                .content_type = "application/json",
                .body = err_body,
                .allocator = self.allocator,
            };
        };

        const resp_body = std.fmt.allocPrint(self.allocator,
            "{{\"success\":{},\"output\":\"{s}\",\"colors_updated\":{},\"spatial_changed\":{}}}",
            .{ result.success, result.output, result.colors_updated, result.spatial_changed },
        ) catch return HttpResponse{ .status = 500, .content_type = "application/json", .body = "{\"error\":\"allocation failed\"}" };

        return HttpResponse{
            .status = 200,
            .content_type = "application/json",
            .body = resp_body,
            .allocator = self.allocator,
        };
    }

    /// Update focus state (called from spatial executor)
    pub fn updateFocus(self: *IxHttpServer, node_id: u32, level: f32, adjacent: []const u32) void {
        self.focus_node_id = node_id;
        self.focus_level = level;
        self.adjacent_count = @intCast(@min(adjacent.len, 8));
        for (0..self.adjacent_count) |idx| {
            self.adjacent_ids[idx] = adjacent[idx];
        }
    }

    /// Update color cache (called from spatial propagator)
    pub fn updateColor(self: *IxHttpServer, node_id: u32, hex: [7]u8) void {
        // Check if node already exists
        for (0..self.color_count) |idx| {
            if (self.color_ids[idx] == node_id) {
                self.color_hexes[idx] = hex;
                return;
            }
        }
        // Add new color entry
        if (self.color_count < 64) {
            self.color_ids[self.color_count] = node_id;
            self.color_hexes[self.color_count] = hex;
            self.color_count += 1;
        }
    }

    /// Parse HTTP request line and return (method, path, body)
    pub fn parseRequest(request: []const u8) struct { method: []const u8, path: []const u8, body: []const u8 } {
        // Find request line end
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
        const request_line = request[0..line_end];

        // Parse "METHOD /path HTTP/1.1"
        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse "GET";
        const path = parts.next() orelse "/";

        // Find body after \r\n\r\n
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n");
        const body = if (body_start) |s| request[s + 4 ..] else "";

        return .{ .method = method, .path = path, .body = body };
    }
};

/// Extract a string value from simple JSON (no nesting, no escapes)
/// Finds "key":"value" pattern
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key":"
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after_key = json[key_pos + pattern.len ..];

    // Skip whitespace
    var start: usize = 0;
    while (start < after_key.len and (after_key[start] == ' ' or after_key[start] == '\t')) : (start += 1) {}

    if (start >= after_key.len) return null;

    // Check for quoted string
    if (after_key[start] == '"') {
        const str_start = start + 1;
        const str_end = std.mem.indexOfScalar(u8, after_key[str_start..], '"') orelse return null;
        return after_key[str_start..][0..str_end];
    }

    return null;
}

// ===== Tests =====

test "route status endpoint" {
    const allocator = std.testing.allocator;
    var dispatcher = CommandDispatcher.init(allocator);
    defer dispatcher.deinit();

    var server = IxHttpServer.init(allocator, &dispatcher);
    var response = try server.route("GET", "/status", "");
    defer response.deinit();

    try std.testing.expect(response.status == 200);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "mode"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "trit_histogram"));
}

test "route focus endpoint" {
    const allocator = std.testing.allocator;
    var dispatcher = CommandDispatcher.init(allocator);
    defer dispatcher.deinit();

    var server = IxHttpServer.init(allocator, &dispatcher);
    server.updateFocus(42, 0.75, &.{ 1, 2, 3 });

    var response = try server.route("GET", "/focus", "");
    defer response.deinit();

    try std.testing.expect(response.status == 200);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "0.750"));
}

test "route 404 for unknown path" {
    const allocator = std.testing.allocator;
    var dispatcher = CommandDispatcher.init(allocator);
    defer dispatcher.deinit();

    var server = IxHttpServer.init(allocator, &dispatcher);
    const response = try server.route("GET", "/unknown", "");

    try std.testing.expect(response.status == 404);
}

test "parse HTTP request" {
    const request = "GET /status HTTP/1.1\r\nHost: localhost:7071\r\n\r\n";
    const parsed = IxHttpServer.parseRequest(request);
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/status", parsed.path);
}

test "extract JSON string" {
    const json = "{\"action\": \"shell ls -la\", \"mode\": \"test\"}";
    const action = extractJsonString(json, "action") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("shell ls -la", action);

    const mode = extractJsonString(json, "mode") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("test", mode);
}

test "route method not allowed" {
    const allocator = std.testing.allocator;
    var dispatcher = CommandDispatcher.init(allocator);
    defer dispatcher.deinit();

    var server = IxHttpServer.init(allocator, &dispatcher);
    const response = try server.route("POST", "/status", "");
    try std.testing.expect(response.status == 405);
}
