//! Persistent data structures (Immer/Ewig-style)
//! 
//! Provides immutable data structures with structural sharing for efficient
//! versioning and time-travel in world simulations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syrup = @import("syrup");

/// Persistent vector with structural sharing
/// Based on RRB-Trees (Relaxed Radix Balanced Trees)
pub fn PersistentVector(comptime T: type) type {
    return struct {
        const Self = @This();
        const BRANCHING_FACTOR = 32;
        const MASK = BRANCHING_FACTOR - 1;
        
        /// Node in the tree
        const Node = struct {
            refs: usize, // Reference count for sharing
            level: u8,
            items: union(enum) {
                leaf: []T,
                branch: []*Node,
            },
            
            fn initLeaf(allocator: Allocator, capacity: usize) !*Node {
                const node = try allocator.create(Node);
                node.refs = 1;
                node.level = 0;
                node.items = .{ .leaf = try allocator.alloc(T, capacity) };
                return node;
            }
            
            fn initBranch(allocator: Allocator, level: u8) !*Node {
                const node = try allocator.create(Node);
                node.refs = 1;
                node.level = level;
                node.items = .{ .branch = try allocator.alloc(*Node, BRANCHING_FACTOR) };
                @memset(node.items.branch, undefined);
                return node;
            }
            
            fn deinit(self: *Node, allocator: Allocator) void {
                self.refs -= 1;
                if (self.refs > 0) return;
                
                switch (self.items) {
                    .leaf => |leaf| allocator.free(leaf),
                    .branch => |branch| {
                        // In a real implementation, track which children are valid
                        // For now, we assume all allocated children are at the start
                        allocator.free(branch);
                    },
                }
                allocator.destroy(self);
            }
            
            fn retain(self: *Node) void {
                self.refs += 1;
            }
        };
        
        allocator: Allocator,
        root: ?*Node,
        len: usize,
        
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .len = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit(self.allocator);
            }
        }
        
        pub fn isEmpty(self: Self) bool {
            return self.len == 0;
        }
        
        /// Get element at index
        pub fn get(self: Self, index: usize) ?T {
            if (index >= self.len) return null;
            if (self.root == null) return null;
            
            return self.getRecursive(self.root.?, index);
        }
        
        fn getRecursive(self: Self, node: *Node, index: usize) T {
            if (node.level == 0) {
                return node.items.leaf[index];
            }
            
            const shift = @as(usize, node.level) * 5; // log2(32) = 5
            const child_idx = (index >> @intCast(shift)) & MASK;
            const child = node.items.branch[child_idx];
            
            return self.getRecursive(child, index);
        }
        
        /// Append element (returns new vector with sharing)
        pub fn append(self: Self, value: T) !Self {
            var new = self;
            
            if (self.root == null or self.needsNewRoot()) {
                // Need to increase tree height
                const new_root = try Node.initBranch(self.allocator, if (self.root) |r| r.level + 1 else 0);
                if (self.root) |r| {
                    new_root.items.branch[0] = r;
                    r.retain();
                }
                new.root = new_root;
            }
            
            try self.appendRecursive(new.root.?, self.len, value);
            new.len += 1;
            
            return new;
        }
        
        fn needsNewRoot(self: Self) bool {
            if (self.root == null) return false;
            const max_capacity = std.math.pow(usize, BRANCHING_FACTOR, @as(usize, self.root.?.level) + 1);
            return self.len >= max_capacity;
        }
        
        fn appendRecursive(self: Self, node: *Node, index: usize, value: T) !void {
            _ = self;
            _ = node;
            _ = index;
            _ = value;
            // Implementation would clone path and set value
        }
        
        /// Create a snapshot/clone (shares underlying data)
        pub fn clone(self: Self) Self {
            if (self.root) |root| {
                root.retain();
            }
            return self;
        }
        
        /// Serialize to syrup
        pub fn toSyrup(self: Self, allocator: Allocator) !syrup.Value {
            var items = std.ArrayListUnmanaged(syrup.Value){};
            defer items.deinit(allocator);
            
            for (0..self.len) |i| {
                if (self.get(i)) |val| {
                    // Serialize based on type
                    const val_syrup = switch (@typeInfo(T)) {
                        .Int => syrup.Value.fromInteger(val),
                        .Float => syrup.Value.fromFloat(val),
                        else => syrup.Value.fromString("<complex>"),
                    };
                    try items.append(allocator, val_syrup);
                }
            }
            
            return syrup.Value.fromList(try items.toOwnedSlice(allocator));
        }
    };
}

/// Persistent hash map with structural sharing
/// Based on Hash Array Mapped Tries (HAMT)
pub fn PersistentMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const BITS = 5;
        const SIZE = 32; // 2^5
        
        const Entry = struct {
            key: K,
            value: V,
        };
        
        const Node = struct {
            refs: usize,
            bitmap: u32,
            children: union(enum) {
                entries: []Entry,
                nodes: []*Node,
            },
            
            fn init(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.refs = 1;
                node.bitmap = 0;
                node.children = .{ .entries = &[_]Entry{} };
                return node;
            }
            
            fn deinit(self: *Node, allocator: Allocator) void {
                self.refs -= 1;
                if (self.refs > 0) return;
                
                switch (self.children) {
                    .entries => |entries| allocator.free(entries),
                    .nodes => |nodes| {
                        for (nodes) |n| n.deinit(allocator);
                        allocator.free(nodes);
                    },
                }
                allocator.destroy(self);
            }
            
            fn retain(self: *Node) void {
                self.refs += 1;
            }
        };
        
        allocator: Allocator,
        root: ?*Node,
        len: usize,
        
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .len = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit(self.allocator);
            }
        }
        
        pub fn isEmpty(self: Self) bool {
            return self.len == 0;
        }
        
        /// Get value for key
        pub fn get(self: Self, key: K) ?V {
            if (self.root == null) return null;
            return self.getRecursive(self.root.?, key, hash(key), 0);
        }
        
        fn getRecursive(self: Self, node: *Node, key: K, h: u32, shift: u6) ?V {
            const idx = (h >> shift) & (SIZE - 1);
            const mask = @as(u32, 1) << @intCast(idx);
            
            if (node.bitmap & mask == 0) return null;
            
            switch (node.children) {
                .entries => |entries| {
                    for (entries) |e| {
                        if (e.key == key) return e.value;
                    }
                    return null;
                },
                .nodes => |nodes| {
                    const pos = @popCount(node.bitmap & (mask - 1));
                    return self.getRecursive(nodes[pos], key, h, shift + BITS);
                },
            }
        }
        
        /// Insert key-value pair (returns new map)
        pub fn put(self: Self, key: K, value: V) !Self {
            // Implementation would clone path and insert
            _ = key;
            _ = value;
            return self;
        }
        
        fn hash(key: K) u32 {
            // Simple hash function
            return std.hash.Crc32.hash(std.mem.asBytes(&key));
        }
        
        /// Clone (shares underlying data)
        pub fn clone(self: Self) Self {
            if (self.root) |root| {
                root.retain();
            }
            return self;
        }
    };
}

/// Versioned state for time-travel
pub fn VersionedState(comptime T: type) type {
    return struct {
        const Self = @This();
        
        const Version = struct {
            timestamp: i64,
            data: T,
            parent: ?usize,
        };
        
        allocator: Allocator,
        versions: std.ArrayListUnmanaged(Version),
        current: usize,
        
        pub fn init(allocator: Allocator, initial: T) !Self {
            var self = Self{
                .allocator = allocator,
                .versions = .{},
                .current = 0,
            };
            
            try self.versions.append(allocator, .{
                .timestamp = std.time.milliTimestamp(),
                .data = initial,
                .parent = null,
            });
            
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            // Assume T handles its own cleanup
            self.versions.deinit(self.allocator);
        }
        
        /// Get current state
        pub fn getCurrent(self: Self) T {
            return self.versions.items[self.current].data;
        }
        
        /// Commit new state
        pub fn commit(self: *Self, data: T) !void {
            try self.versions.append(self.allocator, .{
                .timestamp = std.time.milliTimestamp(),
                .data = data,
                .parent = self.current,
            });
            self.current = self.versions.items.len - 1;
        }
        
        /// Go back to previous version
        pub fn undo(self: *Self) bool {
            if (self.versions.items[self.current].parent) |parent| {
                self.current = parent;
                return true;
            }
            return false;
        }
        
        /// Redo (if we undid)
        pub fn redo(self: *Self) bool {
            // Find child that points to current
            for (self.versions.items, 0..) |v, i| {
                if (v.parent == self.current) {
                    self.current = i;
                    return true;
                }
            }
            return false;
        }
        
        /// Jump to specific version
        pub fn checkout(self: *Self, version: usize) bool {
            if (version >= self.versions.items.len) return false;
            self.current = version;
            return true;
        }
        
        /// Get version count
        pub fn getVersionCount(self: Self) usize {
            return self.versions.items.len;
        }
        
        /// Get version history
        pub fn getHistory(self: Self) []const Version {
            return self.versions.items;
        }
        
        /// Create branch (alternative timeline)
        pub fn branch(self: *Self) !usize {
            const branch_point = self.current;
            try self.versions.append(self.allocator, .{
                .timestamp = std.time.milliTimestamp(),
                .data = self.versions.items[branch_point].data,
                .parent = branch_point,
            });
            return self.versions.items.len - 1;
        }
    };
}

// Tests
const testing = std.testing;

test "persistent vector basic" {
    const allocator = testing.allocator;
    
    var vec = PersistentVector(i64).init(allocator);
    defer vec.deinit();
    
    try testing.expect(vec.isEmpty());
    try testing.expectEqual(@as(?i64, null), vec.get(0));
}

test "persistent map basic" {
    const allocator = testing.allocator;
    
    var map = PersistentMap(u32, []const u8).init(allocator);
    defer map.deinit();
    
    try testing.expect(map.isEmpty());
}

test "versioned state" {
    const allocator = testing.allocator;
    
    var state = try VersionedState(i64).init(allocator, 0);
    defer state.deinit();
    
    try testing.expectEqual(@as(i64, 0), state.getCurrent());
    try testing.expectEqual(@as(usize, 1), state.getVersionCount());
    
    try state.commit(10);
    try state.commit(20);
    
    try testing.expectEqual(@as(i64, 20), state.getCurrent());
    try testing.expectEqual(@as(usize, 3), state.getVersionCount());
    
    try testing.expect(state.undo());
    try testing.expectEqual(@as(i64, 10), state.getCurrent());
    
    try testing.expect(state.undo());
    try testing.expectEqual(@as(i64, 0), state.getCurrent());
    
    try testing.expect(!state.undo());
}
