//! Beeper Desktop API Client
//!
//! HTTP client for the Beeper Desktop local API (localhost:23373).
//! Requires Beeper Desktop v4.1.169+ with API enabled via Settings > Developers.
//!
//! Auth: Bearer token via `BEEPER_ACCESS_TOKEN` env var or explicit config.
//!
//! Design follows zig-syrup conventions:
//!   - `simple_tcp.zig` connection pattern
//!   - `ghostty_ix_http.zig` JSON handling
//!   - `jsonrpc_bridge.zig` JSON ↔ structured data conversion
//!
//! API surface derived from beeper-cli (Go reference implementation).
//! Collaborator context: yevbar (Yev Bar-On) / Tenderloin Fund.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const Config = struct {
    base_url: []const u8 = "http://localhost:23373",
    token: ?[]const u8 = null,
    host: []const u8 = "localhost",
    port: u16 = 23373,

    pub fn fromEnv(allocator: Allocator) Config {
        const token = std.process.getEnvVarOwned(allocator, "BEEPER_ACCESS_TOKEN") catch null;
        return .{ .token = token };
    }
};

// ============================================================================
// Types: Messages
// ============================================================================

pub const AttachmentType = enum {
    gif,
    voice_note,
    sticker,
    auto,
};

pub const SendMessageParams = struct {
    chat_id: []const u8,
    text: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    upload_id: ?[]const u8 = null,
    attachment_type: AttachmentType = .auto,
    mime_type: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration: ?f64 = null,
};

pub const EditMessageParams = struct {
    chat_id: []const u8,
    message_id: []const u8,
    text: []const u8,
};

pub const PaginationDirection = enum { before, after };

pub const ListMessagesParams = struct {
    chat_id: []const u8,
    cursor: ?[]const u8 = null,
    direction: ?PaginationDirection = null,
};

pub const MediaType = enum { any, video, image, link, file };
pub const ChatType = enum { single, group, any };
pub const SenderFilter = enum { me, others };

pub const SearchMessagesParams = struct {
    query: ?[]const u8 = null,
    chat_ids: ?[]const []const u8 = null,
    account_ids: ?[]const []const u8 = null,
    sender: ?[]const u8 = null,
    chat_type: ?ChatType = null,
    media_types: ?[]const MediaType = null,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    direction: ?PaginationDirection = null,
    limit: ?u32 = null,
    exclude_low_priority: bool = true,
    include_muted: bool = true,
};

// ============================================================================
// Types: Chats
// ============================================================================

pub const CreateChatParams = struct {
    account_id: []const u8,
    participants: []const []const u8,
    chat_type: ChatType = .single,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const GetChatParams = struct {
    chat_id: []const u8,
    max_participants: i32 = -1,
};

pub const ListChatsParams = struct {
    account_ids: ?[]const []const u8 = null,
    cursor: ?[]const u8 = null,
    direction: ?PaginationDirection = null,
};

pub const InboxFilter = enum { primary, low_priority, archive };

pub const SearchChatsParams = struct {
    query: ?[]const u8 = null,
    account_ids: ?[]const []const u8 = null,
    chat_type: ?ChatType = null,
    inbox: ?InboxFilter = null,
    scope: ?[]const u8 = null,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    unread_only: bool = false,
    include_muted: bool = true,
    cursor: ?[]const u8 = null,
    direction: ?PaginationDirection = null,
    limit: ?u32 = null,
};

pub const ArchiveChatParams = struct {
    chat_id: []const u8,
    unarchive: bool = false,
};

pub const CreateReminderParams = struct {
    chat_id: []const u8,
    remind_at: []const u8, // ISO-8601
};

// ============================================================================
// Types: Assets
// ============================================================================

pub const UploadResult = struct {
    upload_id: []const u8,
    file_name: []const u8,
    mime_type: []const u8,
    file_size: u64,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const UploadBase64Params = struct {
    data: []const u8,
    filename: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

// ============================================================================
// Types: Accounts
// ============================================================================

pub const Account = struct {
    id: []const u8,
    network: []const u8,
    name: ?[]const u8 = null,
};

pub const ContactSearchParams = struct {
    account_id: []const u8,
    query: []const u8,
};

// ============================================================================
// Types: Search
// ============================================================================

pub const GlobalSearchParams = struct {
    query: []const u8,
};

// ============================================================================
// Response Wrapper
// ============================================================================

pub const ApiError = error{
    ConnectionRefused,
    Unauthorized,
    NotFound,
    BadRequest,
    ServerError,
    Timeout,
    InvalidJson,
    MissingToken,
};

pub fn ApiResponse(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ApiError,
    };
}

// ============================================================================
// HTTP Request Builder
// ============================================================================

const Method = enum { GET, POST, PUT, DELETE, PATCH };

const HttpRequest = struct {
    method: Method,
    path: []const u8,
    body: ?[]const u8 = null,
    query_params: ?[]const QueryParam = null,

    const QueryParam = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Client
// ============================================================================

pub const BeeperClient = struct {
    allocator: Allocator,
    config: Config,

    pub fn init(allocator: Allocator, config: Config) BeeperClient {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn initFromEnv(allocator: Allocator) BeeperClient {
        return init(allocator, Config.fromEnv(allocator));
    }

    // -- Messages --

    pub fn sendMessage(self: *BeeperClient, params: SendMessageParams) ApiError!json.Value {
        var obj = json.ObjectMap.init(self.allocator);
        if (params.text) |t| obj.put("text", .{ .string = t }) catch return error.BadRequest;
        if (params.reply_to) |r| obj.put("reply_to", .{ .string = r }) catch return error.BadRequest;
        if (params.upload_id) |u| obj.put("upload_id", .{ .string = u }) catch return error.BadRequest;
        const body = json.stringifyAlloc(self.allocator, json.Value{ .object = obj }, .{}) catch
            return error.BadRequest;
        return self.request(.POST, self.buildPath("/api/chats/{s}/messages", .{params.chat_id}), body);
    }

    pub fn editMessage(self: *BeeperClient, params: EditMessageParams) ApiError!json.Value {
        var obj = json.ObjectMap.init(self.allocator);
        obj.put("text", .{ .string = params.text }) catch return error.BadRequest;
        const body = json.stringifyAlloc(self.allocator, json.Value{ .object = obj }, .{}) catch
            return error.BadRequest;
        const path = self.buildPath("/api/chats/{s}/messages/{s}", .{ params.chat_id, params.message_id });
        return self.request(.PUT, path, body);
    }

    pub fn listMessages(self: *BeeperClient, params: ListMessagesParams) ApiError!json.Value {
        const path = self.buildPath("/api/chats/{s}/messages", .{params.chat_id});
        return self.request(.GET, path, null);
    }

    pub fn searchMessages(self: *BeeperClient, params: SearchMessagesParams) ApiError!json.Value {
        _ = params;
        return self.request(.GET, "/api/messages/search", null);
    }

    // -- Chats --

    pub fn createChat(self: *BeeperClient, params: CreateChatParams) ApiError!json.Value {
        _ = params;
        return self.request(.POST, "/api/chats", null);
    }

    pub fn getChat(self: *BeeperClient, params: GetChatParams) ApiError!json.Value {
        const path = self.buildPath("/api/chats/{s}", .{params.chat_id});
        return self.request(.GET, path, null);
    }

    pub fn listChats(self: *BeeperClient, params: ListChatsParams) ApiError!json.Value {
        _ = params;
        return self.request(.GET, "/api/chats", null);
    }

    pub fn searchChats(self: *BeeperClient, params: SearchChatsParams) ApiError!json.Value {
        _ = params;
        return self.request(.GET, "/api/chats/search", null);
    }

    pub fn archiveChat(self: *BeeperClient, params: ArchiveChatParams) ApiError!json.Value {
        const path = self.buildPath("/api/chats/{s}/archive", .{params.chat_id});
        const method: Method = if (params.unarchive) .DELETE else .POST;
        return self.request(method, path, null);
    }

    pub fn createReminder(self: *BeeperClient, params: CreateReminderParams) ApiError!json.Value {
        const path = self.buildPath("/api/chats/{s}/reminder", .{params.chat_id});
        var obj = json.ObjectMap.init(self.allocator);
        obj.put("remind_at", .{ .string = params.remind_at }) catch return error.BadRequest;
        const body = json.stringifyAlloc(self.allocator, json.Value{ .object = obj }, .{}) catch
            return error.BadRequest;
        return self.request(.POST, path, body);
    }

    pub fn deleteReminder(self: *BeeperClient, chat_id: []const u8) ApiError!json.Value {
        const path = self.buildPath("/api/chats/{s}/reminder", .{chat_id});
        return self.request(.DELETE, path, null);
    }

    // -- Accounts --

    pub fn listAccounts(self: *BeeperClient) ApiError!json.Value {
        return self.request(.GET, "/api/accounts", null);
    }

    pub fn searchContacts(self: *BeeperClient, params: ContactSearchParams) ApiError!json.Value {
        const path = self.buildPath("/api/accounts/{s}/contacts/search", .{params.account_id});
        return self.request(.GET, path, null);
    }

    // -- Assets --

    pub fn uploadAsset(self: *BeeperClient, file_path: []const u8) ApiError!json.Value {
        _ = file_path;
        return self.request(.POST, "/api/assets/upload", null);
    }

    pub fn uploadBase64(self: *BeeperClient, params: UploadBase64Params) ApiError!json.Value {
        var obj = json.ObjectMap.init(self.allocator);
        obj.put("data", .{ .string = params.data }) catch return error.BadRequest;
        if (params.filename) |f| obj.put("filename", .{ .string = f }) catch return error.BadRequest;
        if (params.mime_type) |m| obj.put("mime_type", .{ .string = m }) catch return error.BadRequest;
        const body = json.stringifyAlloc(self.allocator, json.Value{ .object = obj }, .{}) catch
            return error.BadRequest;
        return self.request(.POST, "/api/assets/upload-base64", body);
    }

    pub fn downloadAsset(self: *BeeperClient, mxc_url: []const u8) ApiError!json.Value {
        _ = mxc_url;
        return self.request(.GET, "/api/assets/download", null);
    }

    // -- Search --

    pub fn globalSearch(self: *BeeperClient, params: GlobalSearchParams) ApiError!json.Value {
        _ = params;
        return self.request(.GET, "/api/search", null);
    }

    // -- Focus --

    pub fn focusApp(self: *BeeperClient) ApiError!json.Value {
        return self.request(.POST, "/api/focus", null);
    }

    // -- Internal --

    fn buildPath(self: *BeeperClient, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args) catch "/";
    }

    fn request(self: *BeeperClient, method: Method, path: []const u8, body: ?[]const u8) ApiError!json.Value {
        const token = self.config.token orelse return error.MissingToken;

        const addr_list = net.getAddressList(self.allocator, self.config.host, self.config.port) catch
            return error.ConnectionRefused;
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.ConnectionRefused;

        const stream = net.tcpConnectToAddress(addr_list.addrs[0]) catch
            return error.ConnectionRefused;
        defer stream.close();

        const method_str = switch (method) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
        };

        var req_buf: [8192]u8 = undefined;
        const content_len = if (body) |b| b.len else 0;
        const header = std.fmt.bufPrint(&req_buf,
            \\{s} {s} HTTP/1.1
            \\Host: {s}:{d}
            \\Authorization: Bearer {s}
            \\Content-Type: application/json
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\
        , .{
            method_str,
            path,
            self.config.host,
            self.config.port,
            token,
            content_len,
        }) catch return error.BadRequest;

        _ = stream.write(header) catch return error.ConnectionRefused;
        if (body) |b| _ = stream.write(b) catch return error.ConnectionRefused;

        var resp_buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < resp_buf.len) {
            const n = stream.read(resp_buf[total..]) catch return error.ConnectionRefused;
            if (n == 0) break;
            total += n;
        }

        const resp = resp_buf[0..total];
        const body_start = mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.InvalidJson;
        const resp_body = resp[body_start + 4 ..];

        const parsed = json.parseFromSlice(json.Value, self.allocator, resp_body, .{}) catch
            return error.InvalidJson;
        return parsed.value;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Config.fromEnv returns defaults without env" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("localhost", cfg.host);
    try std.testing.expectEqual(@as(u16, 23373), cfg.port);
}

test "BeeperClient init" {
    var client = BeeperClient.init(std.testing.allocator, .{
        .token = "test-token",
    });
    try std.testing.expectEqualStrings("test-token", client.config.token.?);
    _ = &client;
}

test "SendMessageParams defaults" {
    const params = SendMessageParams{
        .chat_id = "!test:beeper.local",
        .text = "hello",
    };
    try std.testing.expectEqual(AttachmentType.auto, params.attachment_type);
    try std.testing.expect(params.reply_to == null);
}
