//! JSON-RPC ↔ Syrup Bridge for ACP
//!
//! Mediates between ACP agents that speak JSON-RPC 2.0 over NDJSON stdio
//! (e.g. `copilot --acp`) and the Syrup-native internal representation.
//!
//! The bridge translates bidirectionally:
//!   JSON-RPC request/response ←→ Syrup records
//!
//! This is the key piece that lets zig-syrup talk to closed-source
//! ACP agents without depending on their code.
//!
//! Wire format (copilot side): newline-delimited JSON-RPC 2.0
//!   {"jsonrpc":"2.0","method":"initialize","id":1,"params":{...}}\n
//!   {"jsonrpc":"2.0","result":{...},"id":1}\n
//!
//! Internal format (zig-syrup side): Syrup records
//!   <'initialize 1+ {terminal: t, fs: {readTextFile: t}}>

const std = @import("std");
const syrup = @import("syrup");
const acp = @import("acp");

const Allocator = std.mem.Allocator;
const json = std.json;

// ============================================================================
// JSON ↔ Syrup Value Conversion
// ============================================================================

/// Convert a std.json.Value to a syrup.Value
pub fn jsonToSyrup(allocator: Allocator, jval: json.Value) Allocator.Error!syrup.Value {
    return switch (jval) {
        .null => syrup.nullv(),
        .bool => |b| syrup.boolean(b),
        .integer => |i| syrup.integer(i),
        .float => |f| syrup.float(f),
        .string => |s| syrup.string(s),
        .number_string => |s| syrup.string(s),
        .array => |arr| blk: {
            const items = try allocator.alloc(syrup.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try jsonToSyrup(allocator, item);
            }
            break :blk syrup.list(items);
        },
        .object => |obj| blk: {
            const entries = try allocator.alloc(syrup.Value.DictEntry, obj.count());
            var idx: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                entries[idx] = .{
                    .key = syrup.symbol(entry.key_ptr.*),
                    .value = try jsonToSyrup(allocator, entry.value_ptr.*),
                };
                idx += 1;
            }
            // Sort for canonical Syrup encoding
            std.mem.sort(syrup.Value.DictEntry, entries, {}, syrup.dictEntryLessThan);
            break :blk syrup.dictionary(entries);
        },
    };
}

/// Convert a syrup.Value to std.json.Value
/// Note: Syrup symbols become JSON strings, records become objects with "__label" key
pub fn syrupToJson(allocator: Allocator, sval: syrup.Value) Allocator.Error!json.Value {
    return switch (sval) {
        .undefined, .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .float32 => |f| .{ .float = @floatCast(f) },
        .string, .symbol => |s| .{ .string = s },
        .bytes => |b| blk: {
            // Base64 encode bytes for JSON
            const encoder = std.base64.standard.Encoder;
            const encoded_len = encoder.calcSize(b.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            _ = encoder.encode(encoded, b);
            break :blk .{ .string = encoded };
        },
        .list, .set => |items| blk: {
            var arr = json.Array.init(allocator);
            try arr.ensureTotalCapacity(items.len);
            for (items) |item| {
                try arr.append(try syrupToJson(allocator, item));
            }
            break :blk .{ .array = arr };
        },
        .dictionary => |entries| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.ensureTotalCapacity(@intCast(entries.len));
            for (entries) |entry| {
                const key = switch (entry.key) {
                    .string, .symbol => |s| s,
                    else => "__unknown_key",
                };
                try obj.put(key, try syrupToJson(allocator, entry.value));
            }
            break :blk .{ .object = obj };
        },
        .record => |r| blk: {
            // Record → JSON object with method-style encoding
            var obj = json.ObjectMap.init(allocator);
            const label_str = switch (r.label.*) {
                .string, .symbol => |s| s,
                else => "__record",
            };
            try obj.put("__label", .{ .string = label_str });
            for (r.fields, 0..) |field, i| {
                var key_buf: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch "?";
                const key_owned = try allocator.dupe(u8, key);
                try obj.put(key_owned, try syrupToJson(allocator, field));
            }
            break :blk .{ .object = obj };
        },
        .tagged => |t| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("__tag", .{ .string = t.tag });
            try obj.put("value", try syrupToJson(allocator, t.payload.*));
            break :blk .{ .object = obj };
        },
        .@"error" => |e| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("message", .{ .string = e.message });
            try obj.put("identifier", .{ .string = e.identifier });
            try obj.put("data", try syrupToJson(allocator, e.data.*));
            break :blk .{ .object = obj };
        },
        .bigint => |b| blk: {
            // Encode as string for JSON
            if (b.toI128()) |v| {
                if (v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) {
                    break :blk .{ .integer = @intCast(v) };
                }
            }
            break :blk .{ .string = "__bigint" };
        },
    };
}

// ============================================================================
// JSON-RPC 2.0 Message Types
// ============================================================================

pub const JsonRpcMessage = union(enum) {
    request: JsonRpcRequest,
    notification: JsonRpcNotification,
    response: JsonRpcResponse,
    error_response: JsonRpcErrorResponse,
};

pub const JsonRpcRequest = struct {
    id: i64,
    method: []const u8,
    params: ?json.Value = null,
};

pub const JsonRpcNotification = struct {
    method: []const u8,
    params: ?json.Value = null,
};

pub const JsonRpcResponse = struct {
    id: i64,
    result: json.Value,
};

pub const JsonRpcErrorResponse = struct {
    id: i64,
    code: i64,
    message: []const u8,
    data: ?json.Value = null,
};

/// Parse a JSON-RPC message from a JSON object
pub fn parseJsonRpc(obj: json.ObjectMap) JsonRpcMessage {
    const has_method = obj.contains("method");
    const has_result = obj.contains("result");
    const has_error = obj.contains("error");
    const has_id = obj.contains("id");

    if (has_method and has_id) {
        // Request
        const id_val = obj.get("id").?;
        const id: i64 = switch (id_val) {
            .integer => |i| i,
            else => 0,
        };
        return .{
            .request = .{
                .id = id,
                .method = obj.get("method").?.string,
                .params = obj.get("params"),
            },
        };
    }

    if (has_method and !has_id) {
        // Notification
        return .{
            .notification = .{
                .method = obj.get("method").?.string,
                .params = obj.get("params"),
            },
        };
    }

    if (has_result and has_id) {
        const id_val = obj.get("id").?;
        const id: i64 = switch (id_val) {
            .integer => |i| i,
            else => 0,
        };
        return .{
            .response = .{
                .id = id,
                .result = obj.get("result").?,
            },
        };
    }

    if (has_error and has_id) {
        const id_val = obj.get("id").?;
        const id: i64 = switch (id_val) {
            .integer => |i| i,
            else => 0,
        };
        const err_obj = obj.get("error").?;
        const code: i64 = switch (err_obj) {
            .object => |o| switch (o.get("code") orelse .null) {
                .integer => |i| i,
                else => -1,
            },
            else => -1,
        };
        const message: []const u8 = switch (err_obj) {
            .object => |o| switch (o.get("message") orelse .null) {
                .string => |s| s,
                else => "unknown error",
            },
            else => "unknown error",
        };
        const data: ?json.Value = switch (err_obj) {
            .object => |o| o.get("data"),
            else => null,
        };
        return .{
            .error_response = .{
                .id = id,
                .code = code,
                .message = message,
                .data = data,
            },
        };
    }

    // Fallback: treat as notification with empty method
    return .{
        .notification = .{
            .method = "",
            .params = null,
        },
    };
}

// ============================================================================
// JSON-RPC ↔ Syrup Record Translation
// ============================================================================

/// Convert a JSON-RPC request to a Syrup record
/// <'method id params-as-syrup-dict>
pub fn jsonRpcRequestToSyrup(allocator: Allocator, req: JsonRpcRequest) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = syrup.symbol(req.method);

    var field_count: usize = 1; // id always present
    if (req.params != null) field_count += 1;

    const fields = try allocator.alloc(syrup.Value, field_count);
    fields[0] = syrup.integer(req.id);
    if (req.params) |params| {
        fields[1] = try jsonToSyrup(allocator, params);
    }

    return syrup.record(label, fields);
}

/// Convert a JSON-RPC notification to a Syrup record
/// <'method params-as-syrup-dict>
pub fn jsonRpcNotificationToSyrup(allocator: Allocator, notif: JsonRpcNotification) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = syrup.symbol(notif.method);

    if (notif.params) |params| {
        const fields = try allocator.alloc(syrup.Value, 1);
        fields[0] = try jsonToSyrup(allocator, params);
        return syrup.record(label, fields);
    }

    return syrup.record(label, &.{});
}

/// Convert a JSON-RPC response to a Syrup record
/// <'response id result-as-syrup>
pub fn jsonRpcResponseToSyrup(allocator: Allocator, resp: JsonRpcResponse) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = syrup.symbol("response");

    const fields = try allocator.alloc(syrup.Value, 2);
    fields[0] = syrup.integer(resp.id);
    fields[1] = try jsonToSyrup(allocator, resp.result);

    return syrup.record(label, fields);
}

/// Convert a JSON-RPC error response to a Syrup error value
pub fn jsonRpcErrorToSyrup(allocator: Allocator, err_resp: JsonRpcErrorResponse) !syrup.Value {
    const data_val = try allocator.create(syrup.Value);
    if (err_resp.data) |data| {
        data_val.* = try jsonToSyrup(allocator, data);
    } else {
        data_val.* = syrup.nullv();
    }

    // Encode id as part of identifier
    var id_buf: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{err_resp.id}) catch "?";

    return syrup.err(err_resp.message, try allocator.dupe(u8, id_str), data_val);
}

/// Convert a Syrup record back to a JSON-RPC request line (for sending to agent)
/// Assumes: <'method id params-dict>
pub fn syrupToJsonRpcRequest(allocator: Allocator, value: syrup.Value) ![]u8 {
    if (value != .record) return error.InvalidValue;
    const rec = value.record;

    const method = switch (rec.label.*) {
        .symbol, .string => |s| s,
        else => return error.InvalidValue,
    };

    if (rec.fields.len < 1) return error.InvalidValue;
    const id = switch (rec.fields[0]) {
        .integer => |i| i,
        else => return error.InvalidValue,
    };

    // Build JSON object
    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = method });
    try obj.put("id", .{ .integer = id });

    if (rec.fields.len > 1) {
        const params = try syrupToJson(allocator, rec.fields[1]);
        try obj.put("params", params);
    }

    // Serialize to JSON string
    const json_val = json.Value{ .object = obj };
    var out = std.ArrayList(u8).init(allocator);
    try json_val.jsonStringify(.{}, out.writer());
    try out.append('\n');
    return out.toOwnedSlice();
}

/// Convert a Syrup record to a JSON-RPC response line
/// Assumes: <'response id result>
pub fn syrupToJsonRpcResponse(allocator: Allocator, value: syrup.Value) ![]u8 {
    if (value != .record) return error.InvalidValue;
    const rec = value.record;

    if (rec.fields.len < 2) return error.InvalidValue;
    const id = switch (rec.fields[0]) {
        .integer => |i| i,
        else => return error.InvalidValue,
    };

    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", .{ .integer = id });
    try obj.put("result", try syrupToJson(allocator, rec.fields[1]));

    const json_val = json.Value{ .object = obj };
    var out = std.ArrayList(u8).init(allocator);
    try json_val.jsonStringify(.{}, out.writer());
    try out.append('\n');
    return out.toOwnedSlice();
}

// ============================================================================
// ACP Bridge: Subprocess Mediator
// ============================================================================

/// Callback for receiving translated Syrup messages from the agent
pub const BridgeCallback = *const fn (ctx: ?*anyopaque, message: syrup.Value) void;

/// ACP Bridge mediates between a JSON-RPC ACP subprocess and Syrup callers.
///
/// Usage:
///   1. Create bridge with command + callback
///   2. Bridge spawns subprocess
///   3. Call sendSyrup() to send Syrup records → translated to JSON-RPC → agent stdin
///   4. Agent stdout JSON-RPC → translated to Syrup records → callback
pub const AcpBridge = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    // Subprocess
    process: ?std.process.Child = null,

    // Callback for incoming messages
    on_message: ?BridgeCallback = null,
    on_message_ctx: ?*anyopaque = null,

    // Request ID counter
    next_id: i64 = 1,

    // Read buffer
    read_buf: [64 * 1024]u8 = undefined,
    line_buf: std.ArrayList(u8),

    pub fn init(allocator: Allocator) AcpBridge {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .line_buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *AcpBridge) void {
        self.line_buf.deinit();
        self.arena.deinit();
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }
    }

    /// Spawn the agent subprocess
    pub fn spawn(self: *AcpBridge, command: []const u8, cwd: ?[]const u8) !void {
        // Split command by spaces for argv (simple splitting)
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        var it = std.mem.splitScalar(u8, command, ' ');
        while (it.next()) |arg| {
            if (arg.len > 0) try argv.append(arg);
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .pipe;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;
        if (cwd) |dir| {
            child.cwd = dir;
        }

        try child.spawn();
        self.process = child;
    }

    /// Get the next request ID
    pub fn nextId(self: *AcpBridge) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Send a Syrup record to the agent (translated to JSON-RPC)
    pub fn sendRequest(self: *AcpBridge, method: []const u8, params: syrup.Value) !i64 {
        const proc = self.process orelse return error.NotSpawned;
        const stdin = proc.stdin orelse return error.NoStdin;

        const id = self.nextId();
        const arena_alloc = self.arena.allocator();

        // Build JSON-RPC request
        var obj = json.ObjectMap.init(arena_alloc);
        try obj.put("jsonrpc", .{ .string = "2.0" });
        try obj.put("method", .{ .string = method });
        try obj.put("id", .{ .integer = id });

        if (params != .null and params != .undefined) {
            try obj.put("params", try syrupToJson(arena_alloc, params));
        }

        const json_val = json.Value{ .object = obj };
        var out = std.ArrayList(u8).init(arena_alloc);
        try json_val.jsonStringify(.{}, out.writer());
        try out.append('\n');

        _ = try stdin.write(out.items);

        return id;
    }

    /// Send a Syrup-encoded JSON-RPC response back to the agent
    pub fn sendResponse(self: *AcpBridge, id: i64, result: syrup.Value) !void {
        const proc = self.process orelse return error.NotSpawned;
        const stdin = proc.stdin orelse return error.NoStdin;

        const arena_alloc = self.arena.allocator();

        var obj = json.ObjectMap.init(arena_alloc);
        try obj.put("jsonrpc", .{ .string = "2.0" });
        try obj.put("id", .{ .integer = id });
        try obj.put("result", try syrupToJson(arena_alloc, result));

        const json_val = json.Value{ .object = obj };
        var out = std.ArrayList(u8).init(arena_alloc);
        try json_val.jsonStringify(.{}, out.writer());
        try out.append('\n');

        _ = try stdin.write(out.items);
    }

    /// Send a notification (no id, no response expected)
    pub fn sendNotification(self: *AcpBridge, method: []const u8, params: syrup.Value) !void {
        const proc = self.process orelse return error.NotSpawned;
        const stdin = proc.stdin orelse return error.NoStdin;

        const arena_alloc = self.arena.allocator();

        var obj = json.ObjectMap.init(arena_alloc);
        try obj.put("jsonrpc", .{ .string = "2.0" });
        try obj.put("method", .{ .string = method });

        if (params != .null and params != .undefined) {
            try obj.put("params", try syrupToJson(arena_alloc, params));
        }

        const json_val = json.Value{ .object = obj };
        var out = std.ArrayList(u8).init(arena_alloc);
        try json_val.jsonStringify(.{}, out.writer());
        try out.append('\n');

        _ = try stdin.write(out.items);
    }

    /// Read one line from agent stdout, parse as JSON-RPC, convert to Syrup
    /// Returns null if no more data (process ended)
    pub fn readMessage(self: *AcpBridge) !?syrup.Value {
        const proc = self.process orelse return null;
        const stdout = proc.stdout orelse return null;

        // Read until newline
        self.line_buf.clearRetainingCapacity();
        const reader = stdout.reader();

        reader.streamUntilDelimiter(self.line_buf.writer(), '\n', 1024 * 1024) catch |e| {
            switch (e) {
                error.EndOfStream => return null,
                else => return e,
            }
        };

        const line = self.line_buf.items;
        if (line.len == 0) return null;

        // Parse JSON
        const arena_alloc = self.arena.allocator();
        const parsed = json.parseFromSlice(json.Value, arena_alloc, line, .{
            .allocate = .alloc_always,
        }) catch return null;

        const root = parsed.value;
        if (root != .object) return null;

        // Classify and convert
        const msg = parseJsonRpc(root.object);
        return switch (msg) {
            .request => |req| try jsonRpcRequestToSyrup(arena_alloc, req),
            .notification => |notif| try jsonRpcNotificationToSyrup(arena_alloc, notif),
            .response => |resp| try jsonRpcResponseToSyrup(arena_alloc, resp),
            .error_response => |err_resp| try jsonRpcErrorToSyrup(arena_alloc, err_resp),
        };
    }

    /// Kill the subprocess
    pub fn kill(self: *AcpBridge) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            self.process = null;
        }
    }

    /// Check if process is still running
    pub fn isRunning(self: *AcpBridge) bool {
        return self.process != null;
    }

    /// Reset the arena (call periodically to free accumulated allocations)
    pub fn resetArena(self: *AcpBridge) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

// ============================================================================
// High-Level ACP Session (Syrup-native interface)
// ============================================================================

/// A complete ACP session using Syrup internally, JSON-RPC externally.
/// This is the main interface for toad/zig consumers.
pub const AcpSession = struct {
    bridge: AcpBridge,
    allocator: Allocator,

    // State
    session_id: ?[]const u8 = null,
    agent_capabilities: ?acp.AgentCapabilities = null,
    protocol_version: i64 = 0,

    // Pending request tracking
    pending_ids: std.AutoHashMap(i64, []const u8), // id → method

    pub fn init(allocator: Allocator) AcpSession {
        return .{
            .bridge = AcpBridge.init(allocator),
            .allocator = allocator,
            .pending_ids = std.AutoHashMap(i64, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *AcpSession) void {
        self.pending_ids.deinit();
        self.bridge.deinit();
    }

    /// Start agent subprocess
    pub fn start(self: *AcpSession, command: []const u8, cwd: ?[]const u8) !void {
        try self.bridge.spawn(command, cwd);
    }

    /// Send initialize request, returns the request ID
    pub fn initialize(
        self: *AcpSession,
        client_info: acp.Implementation,
        capabilities: acp.ClientCapabilities,
    ) !i64 {
        const arena_alloc = self.bridge.arena.allocator();

        // Build params as Syrup dict, then bridge converts to JSON
        const entries = try arena_alloc.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{
            .key = syrup.symbol("protocolVersion"),
            .value = syrup.integer(acp.PROTOCOL_VERSION),
        };
        entries[1] = .{
            .key = syrup.symbol("clientCapabilities"),
            .value = try capabilities.toSyrup(arena_alloc),
        };
        entries[2] = .{
            .key = syrup.symbol("clientInfo"),
            .value = try client_info.toSyrup(arena_alloc),
        };

        const params = syrup.dictionary(entries);
        const id = try self.bridge.sendRequest("initialize", params);
        try self.pending_ids.put(id, "initialize");
        return id;
    }

    /// Send session/new request
    pub fn newSession(self: *AcpSession, cwd: []const u8) !i64 {
        const arena_alloc = self.bridge.arena.allocator();

        const entries = try arena_alloc.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.symbol("cwd"),
            .value = syrup.string(cwd),
        };
        entries[1] = .{
            .key = syrup.symbol("mcpServers"),
            .value = syrup.list(&.{}),
        };

        const params = syrup.dictionary(entries);
        const id = try self.bridge.sendRequest("session/new", params);
        try self.pending_ids.put(id, "session/new");
        return id;
    }

    /// Send session/prompt request
    pub fn prompt(self: *AcpSession, text: []const u8) !i64 {
        const session_id = self.session_id orelse return error.NoSession;
        const arena_alloc = self.bridge.arena.allocator();

        // Build content block
        const text_entries = try arena_alloc.alloc(syrup.Value.DictEntry, 2);
        text_entries[0] = .{
            .key = syrup.symbol("type"),
            .value = syrup.string("text"),
        };
        text_entries[1] = .{
            .key = syrup.symbol("text"),
            .value = syrup.string(text),
        };

        const content_block = syrup.dictionary(text_entries);
        const content_list = try arena_alloc.alloc(syrup.Value, 1);
        content_list[0] = content_block;

        const entries = try arena_alloc.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.symbol("prompt"),
            .value = syrup.list(content_list),
        };
        entries[1] = .{
            .key = syrup.symbol("sessionId"),
            .value = syrup.string(session_id),
        };

        const params = syrup.dictionary(entries);
        const id = try self.bridge.sendRequest("session/prompt", params);
        try self.pending_ids.put(id, "session/prompt");
        return id;
    }

    /// Send session/cancel notification
    pub fn cancel(self: *AcpSession) !void {
        const session_id = self.session_id orelse return error.NoSession;
        const arena_alloc = self.bridge.arena.allocator();

        const entries = try arena_alloc.alloc(syrup.Value.DictEntry, 1);
        entries[0] = .{
            .key = syrup.symbol("sessionId"),
            .value = syrup.string(session_id),
        };

        try self.bridge.sendNotification("session/cancel", syrup.dictionary(entries));
    }

    /// Send session/set_mode request
    pub fn setMode(self: *AcpSession, mode_id: []const u8) !i64 {
        const session_id = self.session_id orelse return error.NoSession;
        const arena_alloc = self.bridge.arena.allocator();

        const entries = try arena_alloc.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.symbol("sessionId"),
            .value = syrup.string(session_id),
        };
        entries[1] = .{
            .key = syrup.symbol("modeId"),
            .value = syrup.string(mode_id),
        };

        const params = syrup.dictionary(entries);
        const id = try self.bridge.sendRequest("session/set_mode", params);
        try self.pending_ids.put(id, "session/set_mode");
        return id;
    }

    /// Read and process one message from agent
    /// Returns the Syrup value, or null if agent has exited
    pub fn readMessage(self: *AcpSession) !?syrup.Value {
        const msg = try self.bridge.readMessage() orelse return null;

        // If it's a response, update state
        if (msg == .record) {
            const label_str = switch (msg.record.label.*) {
                .symbol, .string => |s| s,
                else => "",
            };

            if (std.mem.eql(u8, label_str, "response") and msg.record.fields.len >= 2) {
                const id = switch (msg.record.fields[0]) {
                    .integer => |i| i,
                    else => return msg,
                };

                if (self.pending_ids.get(id)) |method| {
                    if (std.mem.eql(u8, method, "session/new")) {
                        // Extract sessionId from result
                        const result = msg.record.fields[1];
                        if (result == .dictionary) {
                            for (result.dictionary) |entry| {
                                if (entry.key == .symbol and std.mem.eql(u8, entry.key.symbol, "sessionId")) {
                                    if (entry.value == .string) {
                                        self.session_id = entry.value.string;
                                    }
                                }
                            }
                        }
                    }
                    _ = self.pending_ids.remove(id);
                }
            }
        }

        return msg;
    }

    /// Stop the agent
    pub fn stop(self: *AcpSession) void {
        self.bridge.kill();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "json to syrup: primitives" {
    const allocator = std.testing.allocator;

    // null
    const null_val = try jsonToSyrup(allocator, .null);
    try std.testing.expect(null_val == .null);

    // bool
    const true_val = try jsonToSyrup(allocator, .{ .bool = true });
    try std.testing.expect(true_val == .bool);
    try std.testing.expect(true_val.bool == true);

    // integer
    const int_val = try jsonToSyrup(allocator, .{ .integer = 42 });
    try std.testing.expect(int_val == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);

    // float
    const float_val = try jsonToSyrup(allocator, .{ .float = 3.14 });
    try std.testing.expect(float_val == .float);

    // string
    const str_val = try jsonToSyrup(allocator, .{ .string = "hello" });
    try std.testing.expect(str_val == .string);
    try std.testing.expectEqualStrings("hello", str_val.string);
}

test "json to syrup: object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse a JSON object
    const input = "{\"method\":\"initialize\",\"protocolVersion\":1}";
    const parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
    const sval = try jsonToSyrup(allocator, parsed.value);

    try std.testing.expect(sval == .dictionary);
    // Should have 2 entries (method, protocolVersion) sorted canonically
    try std.testing.expectEqual(@as(usize, 2), sval.dictionary.len);
}

test "syrup to json: primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const jnull = try syrupToJson(allocator, syrup.nullv());
    try std.testing.expect(jnull == .null);

    const jbool = try syrupToJson(allocator, syrup.boolean(true));
    try std.testing.expect(jbool == .bool);
    try std.testing.expect(jbool.bool == true);

    const jint = try syrupToJson(allocator, syrup.integer(99));
    try std.testing.expect(jint == .integer);
    try std.testing.expectEqual(@as(i64, 99), jint.integer);

    const jstr = try syrupToJson(allocator, syrup.string("world"));
    try std.testing.expect(jstr == .string);
    try std.testing.expectEqualStrings("world", jstr.string);
}

test "parse json-rpc request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"params\":{\"protocolVersion\":1}}";
    const parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
    const msg = parseJsonRpc(parsed.value.object);

    switch (msg) {
        .request => |req| {
            try std.testing.expectEqual(@as(i64, 1), req.id);
            try std.testing.expectEqualStrings("initialize", req.method);
            try std.testing.expect(req.params != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse json-rpc notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"abc\"}}";
    const parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
    const msg = parseJsonRpc(parsed.value.object);

    switch (msg) {
        .notification => |notif| {
            try std.testing.expectEqualStrings("session/update", notif.method);
            try std.testing.expect(notif.params != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse json-rpc response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "{\"jsonrpc\":\"2.0\",\"result\":{\"sessionId\":\"s123\"},\"id\":2}";
    const parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
    const msg = parseJsonRpc(parsed.value.object);

    switch (msg) {
        .response => |resp| {
            try std.testing.expectEqual(@as(i64, 2), resp.id);
            try std.testing.expect(resp.result == .object);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "json-rpc request roundtrip to syrup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const req = JsonRpcRequest{
        .id = 1,
        .method = "initialize",
        .params = .{ .integer = 42 },
    };

    const sval = try jsonRpcRequestToSyrup(allocator, req);
    try std.testing.expect(sval == .record);
    try std.testing.expectEqualStrings("initialize", sval.record.label.symbol);
    try std.testing.expectEqual(@as(i64, 1), sval.record.fields[0].integer);
}

test "json-rpc response roundtrip to syrup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const resp = JsonRpcResponse{
        .id = 5,
        .result = .{ .string = "ok" },
    };

    const sval = try jsonRpcResponseToSyrup(allocator, resp);
    try std.testing.expect(sval == .record);
    try std.testing.expectEqualStrings("response", sval.record.label.symbol);
    try std.testing.expectEqual(@as(i64, 5), sval.record.fields[0].integer);
    try std.testing.expectEqualStrings("ok", sval.record.fields[1].string);
}

test "full translation: json string → syrup → json string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse JSON-RPC request
    const input = "{\"jsonrpc\":\"2.0\",\"method\":\"session/new\",\"id\":3,\"params\":{\"cwd\":\"/home/user\",\"mcpServers\":[]}}";
    const parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
    const msg = parseJsonRpc(parsed.value.object);

    // Convert to Syrup
    const sval = switch (msg) {
        .request => |req| try jsonRpcRequestToSyrup(allocator, req),
        else => return error.TestExpectedRequest,
    };

    // Verify Syrup structure
    try std.testing.expect(sval == .record);
    try std.testing.expectEqualStrings("session/new", sval.record.label.symbol);
    try std.testing.expectEqual(@as(i64, 3), sval.record.fields[0].integer);

    // The params should be a dict with cwd and mcpServers
    const params = sval.record.fields[1];
    try std.testing.expect(params == .dictionary);
}
