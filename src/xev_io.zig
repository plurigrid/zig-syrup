//! libxev-based Async I/O for Syrup Serialization
//!
//! Faithful semantics from https://github.com/mitchellh/libxev.git
//! Provides completion-based async read/write of Syrup values
//!
//! Key libxev concepts:
//! - Completion: encapsulates operation + userdata + callback
//! - CallbackAction: .disarm (done) or .rearm (re-queue)
//! - Operations: read, write, accept, timer, etc.
//! - Zero allocations in the event loop itself

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

/// Mock xev types for when libxev is not available
/// In production, replace with: const xev = @import("xev");
pub const xev = struct {
    pub const Loop = struct {
        submissions: std.ArrayListUnmanaged(*Completion),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Loop {
            return .{
                .submissions = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Loop) void {
            self.submissions.deinit(self.allocator);
        }

        pub fn add(self: *Loop, completion: *Completion) void {
            self.submissions.append(self.allocator, completion) catch {};
        }

        /// Process one tick of the event loop
        pub fn tick(self: *Loop) !void {
            // In real libxev, this submits to io_uring/kqueue/epoll
            // Here we simulate immediate completion for testing
            while (self.submissions.items.len > 0) {
                const c = self.submissions.orderedRemove(0);
                const action = c.invoke(self);
                if (action == .rearm) {
                    self.submissions.append(self.allocator, c) catch {};
                }
            }
        }

        pub fn run(self: *Loop) !void {
            while (self.submissions.items.len > 0) {
                try self.tick();
            }
        }
    };

    pub const Completion = struct {
        op: Operation,
        userdata: ?*anyopaque = null,
        callback: ?Callback = null,

        pub fn invoke(self: *Completion, loop: *Loop) CallbackAction {
            if (self.callback) |cb| {
                const result = self.executeOp();
                return cb(self.userdata, loop, self, result);
            }
            return .disarm;
        }

        fn executeOp(self: *Completion) Result {
            return switch (self.op) {
                .read => |r| blk: {
                    // Simulate read from buffer
                    if (r.buffer.array.len > 0) {
                        break :blk .{ .read = .{ .bytes_read = r.buffer.array.len } };
                    }
                    break :blk .{ .read = .{ .err = error.EndOfStream } };
                },
                .write => |w| .{ .write = .{ .bytes_written = w.buffer.len } },
                .timer => .{ .timer = {} },
                .noop => .{ .noop = {} },
            };
        }
    };

    pub const Operation = union(enum) {
        read: ReadOp,
        write: WriteOp,
        timer: TimerOp,
        noop: void,

        pub const ReadOp = struct {
            fd: i32 = 0,
            buffer: Buffer,
        };

        pub const WriteOp = struct {
            fd: i32 = 0,
            buffer: []const u8,
        };

        pub const TimerOp = struct {
            duration_ns: u64 = 0,
        };

        pub const Buffer = union(enum) {
            array: []u8,
            slice: []const []u8,
        };
    };

    pub const Result = union(enum) {
        read: ReadResult,
        write: WriteResult,
        timer: void,
        noop: void,

        pub const ReadResult = union(enum) {
            bytes_read: usize,
            err: anyerror,
        };

        pub const WriteResult = union(enum) {
            bytes_written: usize,
            err: anyerror,
        };
    };

    pub const CallbackAction = enum {
        disarm,
        rearm,
    };

    pub const Callback = *const fn (
        userdata: ?*anyopaque,
        loop: *Loop,
        completion: *Completion,
        result: Result,
    ) CallbackAction;
};

// ============================================================================
// Syrup Async I/O Context
// ============================================================================

/// Context for async Syrup serialization/deserialization
pub const SyrupAsyncContext = struct {
    allocator: Allocator,
    loop: *xev.Loop,

    /// Buffer for encoding
    encode_buffer: []u8,
    /// Buffer for decoding
    decode_buffer: []u8,

    /// Completion for current operation
    completion: xev.Completion,

    /// Result storage
    result_value: ?syrup.Value = null,
    result_bytes: ?[]const u8 = null,
    err: ?anyerror = null,

    pub fn init(allocator: Allocator, loop: *xev.Loop, buffer_size: usize) !*SyrupAsyncContext {
        const ctx = try allocator.create(SyrupAsyncContext);
        ctx.* = .{
            .allocator = allocator,
            .loop = loop,
            .encode_buffer = try allocator.alloc(u8, buffer_size),
            .decode_buffer = try allocator.alloc(u8, buffer_size),
            .completion = .{ .op = .{ .noop = {} } },
        };
        return ctx;
    }

    pub fn deinit(self: *SyrupAsyncContext) void {
        self.allocator.free(self.encode_buffer);
        self.allocator.free(self.decode_buffer);
        self.allocator.destroy(self);
    }

    /// Async write a Syrup value to fd
    pub fn asyncWrite(
        self: *SyrupAsyncContext,
        fd: i32,
        value: syrup.Value,
        callback: xev.Callback,
    ) !void {
        // Encode value to buffer
        const encoded = try value.encodeBuf(self.encode_buffer);
        self.result_bytes = encoded;

        // Setup completion
        self.completion = .{
            .op = .{
                .write = .{
                    .fd = fd,
                    .buffer = encoded,
                },
            },
            .userdata = self,
            .callback = callback,
        };

        // Submit to loop
        self.loop.add(&self.completion);
    }

    /// Async read a Syrup value from fd
    pub fn asyncRead(
        self: *SyrupAsyncContext,
        fd: i32,
        callback: xev.Callback,
    ) void {
        // Setup completion for read
        self.completion = .{
            .op = .{
                .read = .{
                    .fd = fd,
                    .buffer = .{ .array = self.decode_buffer },
                },
            },
            .userdata = self,
            .callback = callback,
        };

        // Submit to loop
        self.loop.add(&self.completion);
    }
};

// ============================================================================
// Preserves-style Canonical Accessors
// ============================================================================

/// Canonical accessor for Syrup values following Preserves conventions
/// See: https://preserves.dev/
pub const CanonicalAccessor = struct {
    /// Get value at path (list of keys/indices)
    pub fn get(value: syrup.Value, path: []const PathElement) ?syrup.Value {
        var current = value;
        for (path) |elem| {
            current = switch (elem) {
                .index => |i| switch (current) {
                    .list => |items| if (i < items.len) items[i] else return null,
                    .record => |r| if (i < r.fields.len) r.fields[i] else return null,
                    else => return null,
                },
                .key => |k| switch (current) {
                    .dictionary => |entries| blk: {
                        for (entries) |entry| {
                            if (valuesEqual(entry.key, k)) {
                                break :blk entry.value;
                            }
                        }
                        return null;
                    },
                    else => return null,
                },
                .field => |name| switch (current) {
                    .record => |r| blk: {
                        // Record label must be a symbol matching field name
                        if (r.label.* == .symbol and std.mem.eql(u8, r.label.symbol, name)) {
                            // Convention: first field after label
                            if (r.fields.len > 0) break :blk r.fields[0];
                        }
                        return null;
                    },
                    else => return null,
                },
            };
        }
        return current;
    }

    pub const PathElement = union(enum) {
        index: usize,
        key: syrup.Value,
        field: []const u8,
    };

    /// Check if two values are equal (for canonical comparison)
    pub fn valuesEqual(a: syrup.Value, b: syrup.Value) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;

        return switch (a) {
            .undefined, .null => true,
            .bool => |va| va == b.bool,
            .integer => |va| va == b.integer,
            .float => |va| va == b.float,
            .float32 => |va| va == b.float32,
            .bytes => |va| std.mem.eql(u8, va, b.bytes),
            .string => |va| std.mem.eql(u8, va, b.string),
            .symbol => |va| std.mem.eql(u8, va, b.symbol),
            .list => |va| blk: {
                const vb = b.list;
                if (va.len != vb.len) break :blk false;
                for (va, vb) |ea, eb| {
                    if (!valuesEqual(ea, eb)) break :blk false;
                }
                break :blk true;
            },
            .dictionary => |va| blk: {
                const vb = b.dictionary;
                if (va.len != vb.len) break :blk false;
                // Dictionary entries must be in same order for canonical equality
                for (va, vb) |ea, eb| {
                    if (!valuesEqual(ea.key, eb.key)) break :blk false;
                    if (!valuesEqual(ea.value, eb.value)) break :blk false;
                }
                break :blk true;
            },
            .set => |va| blk: {
                const vb = b.set;
                if (va.len != vb.len) break :blk false;
                for (va, vb) |ea, eb| {
                    if (!valuesEqual(ea, eb)) break :blk false;
                }
                break :blk true;
            },
            .record => |va| blk: {
                const vb = b.record;
                if (!valuesEqual(va.label.*, vb.label.*)) break :blk false;
                if (va.fields.len != vb.fields.len) break :blk false;
                for (va.fields, vb.fields) |fa, fb| {
                    if (!valuesEqual(fa, fb)) break :blk false;
                }
                break :blk true;
            },
            .tagged => |va| blk: {
                const vb = b.tagged;
                if (!std.mem.eql(u8, va.tag, vb.tag)) break :blk false;
                break :blk valuesEqual(va.payload.*, vb.payload.*);
            },
            .@"error" => |va| blk: {
                const vb = b.@"error";
                if (!std.mem.eql(u8, va.message, vb.message)) break :blk false;
                if (!std.mem.eql(u8, va.identifier, vb.identifier)) break :blk false;
                break :blk valuesEqual(va.data.*, vb.data.*);
            },
            .bigint => |va| blk: {
                const vb = b.bigint;
                if (va.negative != vb.negative) break :blk false;
                break :blk std.mem.eql(u8, va.magnitude, vb.magnitude);
            },
        };
    }

    /// Canonical ordering for dictionary keys (Preserves spec)
    pub fn compareValues(a: syrup.Value, b: syrup.Value) std.math.Order {
        return a.compare(b);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "xev loop basic operation" {
    const allocator = std.testing.allocator;
    var loop = xev.Loop.init(allocator);
    defer loop.deinit();

    var completed = false;
    var c = xev.Completion{
        .op = .{ .noop = {} },
        .userdata = &completed,
        .callback = struct {
            fn cb(ud: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, _: xev.Result) xev.CallbackAction {
                const ptr: *bool = @ptrCast(@alignCast(ud));
                ptr.* = true;
                return .disarm;
            }
        }.cb,
    };

    loop.add(&c);
    try loop.run();

    try std.testing.expect(completed);
}

test "SyrupAsyncContext write" {
    const allocator = std.testing.allocator;
    var loop = xev.Loop.init(allocator);
    defer loop.deinit();

    var ctx = try SyrupAsyncContext.init(allocator, &loop, 1024);
    defer ctx.deinit();

    const write_completed = false;
    const value = syrup.string("hello");

    try ctx.asyncWrite(1, value, struct {
        fn cb(ud: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, result: xev.Result) xev.CallbackAction {
            const self: *SyrupAsyncContext = @ptrCast(@alignCast(ud));
            _ = self;
            switch (result) {
                .write => |w| switch (w) {
                    .bytes_written => |n| {
                        // "5\"hello" = 7 bytes
                        std.debug.assert(n == 7);
                    },
                    .err => {},
                },
                else => {},
            }
            // Use outer scope via closure capture
            const outer: *bool = @ptrFromInt(@intFromPtr(ud) - @sizeOf(SyrupAsyncContext) + @offsetOf(SyrupAsyncContext, "allocator"));
            _ = outer;
            return .disarm;
        }
    }.cb);

    try loop.run();
    _ = write_completed;
}

test "canonical accessor get" {
    // Build a nested structure
    const inner_items = [_]syrup.Value{ syrup.integer(1), syrup.integer(2) };
    const entries = [_]syrup.Value.DictEntry{
        .{ .key = syrup.string("a"), .value = syrup.list(&inner_items) },
        .{ .key = syrup.string("b"), .value = syrup.integer(42) },
    };
    const dict = syrup.dictionary(&entries);

    // Access dict["a"][1]
    const path = [_]CanonicalAccessor.PathElement{
        .{ .key = syrup.string("a") },
        .{ .index = 1 },
    };

    const result = CanonicalAccessor.get(dict, &path);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 2), result.?.integer);
}

test "canonical value comparison" {
    // Integers
    try std.testing.expectEqual(std.math.Order.lt, CanonicalAccessor.compareValues(syrup.integer(1), syrup.integer(2)));
    try std.testing.expectEqual(std.math.Order.eq, CanonicalAccessor.compareValues(syrup.integer(5), syrup.integer(5)));

    // Strings
    try std.testing.expectEqual(std.math.Order.lt, CanonicalAccessor.compareValues(syrup.string("a"), syrup.string("b")));

    // Type ordering: int < string
    try std.testing.expectEqual(std.math.Order.lt, CanonicalAccessor.compareValues(syrup.integer(999), syrup.string("a")));
}
