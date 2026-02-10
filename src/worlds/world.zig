//! World A/B Testing - Core World Data Structure
//! 
//! Immutable world state with copy-on-write semantics
//! URI-based world identification: a://, b://, c://
//! Hash-based identity for efficient comparison

const std = @import("std");
const crypto = std.crypto;
const hash_map = std.hash_map;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

// const ewig = @import("ewig/ewig.zig");

/// World URI scheme variants
pub const WorldVariant = enum {
    A, // Baseline
    B, // Variant 1
    C, // Variant 2 / Experimental
    
    pub fn prefix(self: WorldVariant) []const u8 {
        return switch (self) {
            .A => "a://",
            .B => "b://",
            .C => "c://",
        };
    }
    
    pub fn fromString(str: []const u8) ?WorldVariant {
        if (std.mem.startsWith(u8, str, "a://")) return .A;
        if (std.mem.startsWith(u8, str, "b://")) return .B;
        if (std.mem.startsWith(u8, str, "c://")) return .C;
        return null;
    }
};

/// Parsed world URI
pub const WorldUri = struct {
    variant: WorldVariant,
    name: []const u8,
    version: ?[]const u8,
    params: StringHashMap([]const u8),
    
    pub fn parse(allocator: std.mem.Allocator, uri: []const u8) !WorldUri {
        var result = WorldUri{
            .variant = WorldVariant.fromString(uri) orelse return error.InvalidScheme,
            .name = undefined,
            .version = null,
            .params = StringHashMap([]const u8).init(allocator),
        };
        
        // Find name end (either #version or ?params or end)
        const prefix_len = result.variant.prefix().len;
        var name_end = uri.len;
        var query_start: ?usize = null;
        var hash_start: ?usize = null;
        
        if (std.mem.indexOf(u8, uri[prefix_len..], "#")) |idx| {
            hash_start = prefix_len + idx;
            name_end = hash_start.?;
        }
        
        if (std.mem.indexOf(u8, uri[prefix_len..name_end], "?")) |idx| {
            query_start = prefix_len + idx;
            if (hash_start == null) name_end = query_start.?;
        }
        
        result.name = uri[prefix_len..name_end];
        
        // Parse version
        if (hash_start) |h| {
            result.version = uri[h + 1 ..];
        }
        
        // Parse query params
        if (query_start) |q| {
            const query_end = hash_start orelse uri.len;
            const query = uri[q + 1 .. query_end];
            
            var it = std.mem.splitAny(u8, query, "&");
            while (it.next()) |pair| {
                if (std.mem.indexOf(u8, pair, "=")) |eq| {
                    const key = pair[0..eq];
                    const val = pair[eq + 1 ..];
                    try result.params.put(key, val);
                }
            }
        }
        
        return result;
    }
    
    pub fn deinit(self: *WorldUri) void {
        self.params.deinit();
    }
    
    pub fn format(
        self: WorldUri,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}{s}", .{ self.variant.prefix(), self.name });
        if (self.version) |v| try writer.print("#{s}", .{v});
    }
};

/// Immutable world state with structural sharing
pub const WorldState = struct {
    allocator: std.mem.Allocator,
    data: StringHashMap(Value),
    hash: [32]u8,
    parent: ?*WorldState,
    ref_count: usize,
    
    const Value = union(enum) {
        Null,
        Bool: bool,
        Int: i64,
        Float: f64,
        String: []const u8,
        Array: []Value,
        Map: StringHashMap(Value),
    };
    
    pub fn init(allocator: std.mem.Allocator) !*WorldState {
        const self = try allocator.create(WorldState);
        self.* = .{
            .allocator = allocator,
            .data = StringHashMap(Value).init(allocator),
            .hash = undefined,
            .parent = null,
            .ref_count = 1,
        };
        self.recomputeHash();
        return self;
    }
    
    pub fn deinit(self: *WorldState) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            if (self.parent) |p| p.deinit();
            var it = self.data.valueIterator();
            while (it.next()) |v| self.freeValue(v.*);
            self.data.deinit();
            self.allocator.destroy(self);
        }
    }
    
    fn freeValue(self: *WorldState, v: Value) void {
        switch (v) {
            .String => |s| self.allocator.free(s),
            .Array => |a| {
                for (a) |item| self.freeValue(item);
                self.allocator.free(a);
            },
            .Map => |m| {
                var it = m.valueIterator();
                while (it.next()) |val| self.freeValue(val.*);
                // TODO: Fix hash_map deinit for Zig 0.15 - const correctness issue
                // @ptrCast(*std.StringHashMap(Value), &m).deinit();
            },
            else => {},
        }
    }
    
    /// Copy-on-write: returns new state with modified value
    pub fn set(self: *WorldState, key: []const u8, value: Value) !*WorldState {
        const new_state = try self.allocator.create(WorldState);
        new_state.* = .{
            .allocator = self.allocator,
            .data = try self.data.clone(),
            .hash = undefined,
            .parent = self,
            .ref_count = 1,
        };
        
        // Update or insert
        if (new_state.data.getPtr(key)) |existing| {
            self.freeValue(existing.*);
        }
        try new_state.data.put(key, value);
        
        new_state.recomputeHash();
        self.ref_count += 1;
        return new_state;
    }
    
    pub fn get(self: *const WorldState, key: []const u8) ?Value {
        if (self.data.get(key)) |v| return v;
        if (self.parent) |p| return p.get(key);
        return null;
    }
    
    fn recomputeHash(self: *WorldState) void {
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        
        var it = self.data.iterator();
        while (it.next()) |entry| {
            hasher.update(entry.key_ptr.*);
            self.hashValue(&hasher, entry.value_ptr.*);
        }
        
        hasher.final(&self.hash);
    }
    
    fn hashValue(self: *const WorldState, hasher: anytype, v: Value) void {
        switch (v) {
            .Null => hasher.update(&[_]u8{0}),
            .Bool => |b| hasher.update(&[_]u8{if (b) 1 else 0}),
            .Int => |i| hasher.update(std.mem.asBytes(&i)),
            .Float => |f| hasher.update(std.mem.asBytes(&f)),
            .String => |s| hasher.update(s),
            .Array => |a| {
                for (a) |item| self.hashValue(hasher, item);
            },
            .Map => |m| {
                var it = m.iterator();
                while (it.next()) |e| {
                    hasher.update(e.key_ptr.*);
                    self.hashValue(hasher, e.value_ptr.*);
                }
            },
        }
    }
    
    pub fn eql(self: *const WorldState, other: *const WorldState) bool {
        return std.mem.eql(u8, &self.hash, &other.hash);
    }
};

/// Main World struct
pub const World = struct {
    allocator: std.mem.Allocator,
    uri: WorldUri,
    state: *WorldState,
    // ewig_log: ?*ewig.Log,
    created_at: i64,
    
    pub fn create(
        allocator: std.mem.Allocator,
        uri_str: []const u8,
        ewig_log: ?*anyopaque,
    ) !*World {
        const self = try allocator.create(World);
        errdefer allocator.destroy(self);
        
        self.uri = try WorldUri.parse(allocator, uri_str);
        errdefer self.uri.deinit();
        
        self.state = try WorldState.init(allocator);
        // self.ewig_log = ewig_log;
        self.created_at = std.time.milliTimestamp();
        self.allocator = allocator;
        
        // Log world creation
        if (ewig_log != null) {
            // _ = try log.append(.{
            //     .world_uri = uri_str,
            //     .type = .WorldCreated,
            //     .payload = uri_str,
            // });
        }
        
        return self;
    }
    
    pub fn destroy(self: *World) void {
        self.state.deinit();
        self.uri.deinit();
        self.allocator.destroy(self);
    }
    
    /// Set parameter with copy-on-write and logging
    pub fn setParam(self: *World, key: []const u8, value: WorldState.Value) !void {
        const new_state = try self.state.set(key, value);
        self.state.deinit();
        self.state = new_state;
        
        if (self.ewig_log) |log| {
            var buf: [256]u8 = undefined;
            const payload = try std.fmt.bufPrint(&buf, "{s}={any}", .{ key, value });
            _ = try log.append(.{
                .world_uri = self.uri,
                .type = .StateChanged,
                .payload = payload,
            });
        }
    }
    
    pub fn getParam(self: *World, key: []const u8) ?WorldState.Value {
        return self.state.get(key);
    }
    
    /// Create snapshot of current state
    pub fn snapshot(self: *World) ![32]u8 {
        return self.state.hash;
    }
    
    // /// Restore to snapshot (via ewig log replay)
    // pub fn restore(self: *World, target_hash: [32]u8) !void {
    //     if (self.ewig_log) |log| {
    //         // Reconstruct state from log
    //         const new_state = try reconstructState(self.allocator, log, target_hash);
    //         self.state.deinit();
    //         self.state = new_state;
    //     }
    // }
};

// fn reconstructState(allocator: std.mem.Allocator, log: *ewig.Log, target_hash: [32]u8) !*WorldState {
//     return error.NotImplemented;
// }
//                 // Parse key=value from payload
//                 if (std.mem.indexOf(u8, event.payload, "=")) |eq| {
//                     const key = event.payload[0..eq];
//                     const val = event.payload[eq + 1 ..];
//                     
//                     // Try to parse as number, else string
//                     if (std.fmt.parseInt(i64, val, 10)) |int_val| {
//                         const new_state = try state.set(key, .{ .Int = int_val });
//                         state.deinit();
//                         state = new_state;
//                     } else |_| {
//                         if (std.fmt.parseFloat(f64, val)) |float_val| {
//                             const new_state = try state.set(key, .{ .Float = float_val });
//                             state.deinit();
//                             state = new_state;
//                         } else |_| {
//                             const s = try allocator.dupe(u8, val);
//                             const new_state = try state.set(key, .{ .String = s });
//                             state.deinit();
//                             state = new_state;
//                         }
//                     }
//                 }
//             },
//             else => {},
//         }
//         
//         // Check if we've reached target
//         if (std.mem.eql(u8, &state.hash, &target_hash)) break;
//     }
//     
//     return state;
// }

// ============================================================================
// Tests
// ============================================================================

test "WorldUri parsing" {
    const allocator = std.testing.allocator;
    
    var uri = try WorldUri.parse(allocator, "a://baseline#v1.0");
    defer uri.deinit();
    
    try std.testing.expectEqual(WorldVariant.A, uri.variant);
    try std.testing.expectEqualStrings("baseline", uri.name);
    try std.testing.expectEqualStrings("v1.0", uri.version.?);
}

test "WorldUri with params" {
    const allocator = std.testing.allocator;
    
    var uri = try WorldUri.parse(allocator, "b://variant?players=3&difficulty=hard");
    defer uri.deinit();
    
    try std.testing.expectEqual(WorldVariant.B, uri.variant);
    try std.testing.expectEqualStrings("variant", uri.name);
    try std.testing.expectEqualStrings("3", uri.params.get("players").?);
    try std.testing.expectEqualStrings("hard", uri.params.get("difficulty").?);
}

test "WorldState immutability" {
    const allocator = std.testing.allocator;
    
    var s1 = try WorldState.init(allocator);
    defer s1.deinit();
    
    var s2 = try s1.set("x", .{ .Int = 42 });
    defer s2.deinit();
    
    // s1 should still have original values
    try std.testing.expect(s1.get("x") == null);
    try std.testing.expectEqual(@as(i64, 42), s2.get("x").?.Int);
    
    // s3 from s2
    var s3 = try s2.set("y", .{ .Int = 100 });
    defer s3.deinit();
    
    try std.testing.expect(s2.get("y") == null);
    try std.testing.expectEqual(@as(i64, 100), s3.get("y").?.Int);
}

test "WorldState hash equality" {
    const allocator = std.testing.allocator;
    
    var s1 = try WorldState.init(allocator);
    defer s1.deinit();
    
    var s2 = try s1.set("x", .{ .Int = 42 });
    defer s2.deinit();
    
    var s3 = try s1.set("x", .{ .Int = 42 });
    defer s3.deinit();
    
    // s2 and s3 should have same hash
    try std.testing.expect(s2.eql(s3));
}
