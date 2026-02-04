//! Immer - Immutable Data Structures
//! 
//! Persistent data structures with structural sharing
//! Array (persistent vector) and Map (HAMT)

const std = @import("std");
const crypto = std.crypto;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

/// Immutable Array (persistent vector with structural sharing)
pub fn ImmutableArray(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // Node in the tree
        const Node = struct {
            refs: usize,
            is_leaf: bool,
            data: union {
                leaf: []const T,
                internal: []?*Node,
            },
            
            fn initLeaf(allocator: std.mem.Allocator, items: []const T) !*Node {
                const node = try allocator.create(Node);
                const data = try allocator.dupe(T, items);
                node.* = .{
                    .refs = 1,
                    .is_leaf = true,
                    .data = .{ .leaf = data },
                };
                return node;
            }
            
            fn initInternal(allocator: std.mem.Allocator, children: []?*Node) !*Node {
                const node = try allocator.create(Node);
                const data = try allocator.alloc(?*Node, children.len);
                @memcpy(data, children);
                node.* = .{
                    .refs = 1,
                    .is_leaf = false,
                    .data = .{ .internal = data },
                };
                return node;
            }
            
            fn acquire(self: *Node) void {
                self.refs += 1;
            }
            
            fn release(self: *Node, allocator: std.mem.Allocator) void {
                self.refs -= 1;
                if (self.refs == 0) {
                    if (self.is_leaf) {
                        allocator.free(self.data.leaf);
                    } else {
                        for (self.data.internal) |child| {
                            if (child) |c| c.release(allocator);
                        }
                        allocator.free(self.data.internal);
                    }
                    allocator.destroy(self);
                }
            }
        };
        
        allocator: std.mem.Allocator,
        root: ?*Node,
        len: usize,
        shift: u6, // Depth of tree (number of levels)
        
        const NODE_SIZE = 32; // Branching factor (2^5)
        const NODE_BITS = 5;
        const NODE_MASK = NODE_SIZE - 1;
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .len = 0,
                .shift = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.root) |r| r.release(self.allocator);
        }
        
        /// Clone (structural sharing, O(1))
        pub fn clone(self: Self) Self {
            if (self.root) |r| r.acquire();
            return .{
                .allocator = self.allocator,
                .root = self.root,
                .len = self.len,
                .shift = self.shift,
            };
        }
        
        /// Get element at index (O(log n))
        pub fn get(self: Self, index: usize) ?T {
            if (index >= self.len) return null;
            
            var node = self.root orelse return null;
            var level = self.shift;
            
            while (!node.is_leaf) {
                const idx = (index >> level) & NODE_MASK;
                node = node.data.internal[idx] orelse return null;
                level -= NODE_BITS;
            }
            
            const idx = index & NODE_MASK;
            if (idx >= node.data.leaf.len) return null;
            return node.data.leaf[idx];
        }
        
        /// Append element (structural sharing, O(log n))
        pub fn append(self: Self, value: T) !Self {
            if (self.len == 0) {
                // Create initial leaf
                const leaf = try Node.initLeaf(self.allocator, &[_]T{value});
                return .{
                    .allocator = self.allocator,
                    .root = leaf,
                    .len = 1,
                    .shift = 0,
                };
            }
            
            // Check if we need to increase tree depth
            const capacity = @as(usize, 1) << (self.shift + NODE_BITS);
            
            if (self.len >= capacity) {
                // New root level
                const new_root = try Node.initInternal(self.allocator, 
                    &[_]?*Node{ self.root, null });
                if (self.root) |r| r.acquire();
                
                return try self.appendToNode(new_root, self.shift + NODE_BITS, self.len, value);
            }
            
            // Append to existing tree
            if (self.root) |r| r.acquire();
            return try self.appendToNode(self.root.?, self.shift, self.len, value);
        }
        
        fn appendToNode(
            self: Self,
            node: *Node,
            shift: u6,
            index: usize,
            value: T,
        ) !Self {
            if (node.is_leaf) {
                // Clone leaf with new element
                var new_leaf_data = try self.allocator.alloc(T, node.data.leaf.len + 1);
                @memcpy(new_leaf_data[0..node.data.leaf.len], node.data.leaf);
                new_leaf_data[node.data.leaf.len] = value;
                
                const new_leaf = try Node.initLeaf(self.allocator, new_leaf_data);
                self.allocator.free(new_leaf_data);
                
                return .{
                    .allocator = self.allocator,
                    .root = new_leaf,
                    .len = index + 1,
                    .shift = shift,
                };
            }
            
            // Internal node - clone path
            const idx = (index >> shift) & NODE_MASK;
            const child_shift = shift - NODE_BITS;
            
            // Clone children array
            var new_children = try self.allocator.alloc(?*Node, NODE_SIZE);
            @memcpy(new_children[0..node.data.internal.len], node.data.internal);
            
            // Recursively append to or create child
            if (node.data.internal[idx]) |child| {
                const new_child = try self.appendToNodeRecursive(child, child_shift, index, value);
                new_children[idx] = new_child;
            } else {
                // Create new leaf
                const leaf = try Node.initLeaf(self.allocator, &[_]T{value});
                new_children[idx] = leaf;
            }
            
            const new_node = try Node.initInternal(self.allocator, new_children);
            self.allocator.free(new_children);
            
            // Release old root since we cloned path
            node.release(self.allocator);
            
            return .{
                .allocator = self.allocator,
                .root = new_node,
                .len = index + 1,
                .shift = shift,
            };
        }
        
        fn appendToNodeRecursive(
            self: Self,
            node: *Node,
            shift: u6,
            index: usize,
            value: T,
        ) !*Node {
            if (node.is_leaf) {
                var new_data = try self.allocator.alloc(T, node.data.leaf.len + 1);
                @memcpy(new_data[0..node.data.leaf.len], node.data.leaf);
                new_data[node.data.leaf.len] = value;
                
                const new_node = try Node.initLeaf(self.allocator, new_data);
                self.allocator.free(new_data);
                return new_node;
            }
            
            const idx = (index >> shift) & NODE_MASK;
            const child_shift = shift - NODE_BITS;
            
            var new_children = try self.allocator.alloc(?*Node, NODE_SIZE);
            @memcpy(new_children[0..node.data.internal.len], node.data.internal);
            
            if (node.data.internal[idx]) |child| {
                const new_child = try self.appendToNodeRecursive(child, child_shift, index, value);
                new_children[idx] = new_child;
            } else {
                const leaf = try Node.initLeaf(self.allocator, &[_]T{value});
                new_children[idx] = leaf;
            }
            
            const new_node = try Node.initInternal(self.allocator, new_children);
            self.allocator.free(new_children);
            return new_node;
        }
        
        /// Set element at index (structural sharing)
        pub fn set(self: Self, index: usize, value: T) !Self {
            if (index >= self.len) return error.IndexOutOfBounds;
            
            if (self.root) |r| r.acquire();
            const new_root = try self.setInNode(self.root.?, self.shift, index, value);
            
            return .{
                .allocator = self.allocator,
                .root = new_root,
                .len = self.len,
                .shift = self.shift,
            };
        }
        
        fn setInNode(self: Self, node: *Node, shift: u6, index: usize, value: T) !*Node {
            if (node.is_leaf) {
                var new_data = try self.allocator.dupe(T, node.data.leaf);
                new_data[index & NODE_MASK] = value;
                
                const new_node = try Node.initLeaf(self.allocator, new_data);
                self.allocator.free(new_data);
                return new_node;
            }
            
            const idx = (index >> shift) & NODE_MASK;
            const child_shift = shift - NODE_BITS;
            
            var new_children = try self.allocator.alloc(?*Node, NODE_SIZE);
            @memcpy(new_children[0..node.data.internal.len], node.data.internal);
            
            if (node.data.internal[idx]) |child| {
                const new_child = try self.setInNode(child, child_shift, index, value);
                new_children[idx] = new_child;
            }
            
            const new_node = try Node.initInternal(self.allocator, new_children);
            self.allocator.free(new_children);
            return new_node;
        }
        
        /// Iterator over elements
        pub const Iterator = struct {
            array: Self,
            index: usize,
            
            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.array.len) return null;
                const val = self.array.get(self.index);
                self.index += 1;
                return val;
            }
        };
        
        pub fn iterator(self: Self) Iterator {
            return .{ .array = self, .index = 0 };
        }
        
        /// Convert to standard array (allocates)
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]T {
            var result = try allocator.alloc(T, self.len);
            for (0..self.len) |i| {
                result[i] = self.get(i).?;
            }
            return result;
        }
    };
}

/// Immutable Map using Hash Array Mapped Trie (HAMT)
pub fn ImmutableMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        const Node = struct {
            refs: usize,
            bitmap: u32, // Which children are present
            entries: []const Entry,
            children: []?*Node,
            
            const Entry = struct { key: K, value: V };
            
            fn initEmpty(allocator: std.mem.Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .refs = 1,
                    .bitmap = 0,
                    .entries = &[_]Entry{},
                    .children = &[_]?*Node{},
                };
                return node;
            }
            
            fn acquire(self: *Node) void {
                self.refs += 1;
            }
            
            fn release(self: *Node, allocator: std.mem.Allocator) void {
                self.refs -= 1;
                if (self.refs == 0) {
                    // Note: doesn't free keys/values (assumes copy-by-value or managed externally)
                    allocator.free(self.entries);
                    for (self.children) |child| {
                        if (child) |c| c.release(allocator);
                    }
                    allocator.free(self.children);
                    allocator.destroy(self);
                }
            }
        };
        
        allocator: std.mem.Allocator,
        root: ?*Node,
        len: usize,
        
        const HASH_BITS = 5;
        const HASH_MASK = (1 << HASH_BITS) - 1;
        const MAX_DEPTH = 7; // 5 * 7 = 35 bits of hash
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .len = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.root) |r| r.release(self.allocator);
        }
        
        pub fn clone(self: Self) Self {
            if (self.root) |r| r.acquire();
            return .{
                .allocator = self.allocator,
                .root = self.root,
                .len = self.len,
            };
        }
        
        /// Hash function for keys
        fn hashKey(key: K) u32 {
            if (K == []const u8) {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key);
                return @truncate(hasher.final());
            } else if (K == i32 or K == i64 or K == u32 or K == u64) {
                return @as(u32, @truncate(@as(u64, @bitCast(key)) *% 0x9e3779b97f4a7c15));
            } else {
                // Default: use std.hash
                return std.hash.Crc32.hash(std.mem.asBytes(&key));
            }
        }
        
        /// Get value by key (O(log n))
        pub fn get(self: Self, key: K) ?V {
            var node = self.root orelse return null;
            var hash = hashKey(key);
            var depth: u32 = 0;
            
            while (true) {
                const idx = hash & HASH_MASK;
                
                // Check if slot is in bitmap
                if (node.bitmap & (@as(u32, 1) << @intCast(idx)) != 0) {
                    // Count bits before idx to get entry index
                    const entry_idx = @popCount(node.bitmap & ((@as(u32, 1) << @intCast(idx)) - 1));
                    
                    if (entry_idx < node.entries.len) {
                        const entry = node.entries[entry_idx];
                        if (self.keysEqual(entry.key, key)) {
                            return entry.value;
                        }
                    }
                }
                
                // Check child
                const child_idx = @popCount(node.bitmap & ((@as(u32, 1) << @intCast(idx + 16)) - 1));
                if (child_idx < node.children.len and node.children[child_idx] != null) {
                    node = node.children[child_idx].?;
                    hash >>= HASH_BITS;
                    depth += 1;
                    if (depth >= MAX_DEPTH) return null;
                    continue;
                }
                
                return null;
            }
        }
        
        /// Associate key with value (structural sharing, O(log n))
        pub fn assoc(self: Self, key: K, value: V) !Self {
            const hash = hashKey(key);
            
            if (self.root == null) {
                // Create root with single entry
                const root = try Node.initEmpty(self.allocator);
                const entries = try self.allocator.alloc(Node.Entry, 1);
                entries[0] = .{ .key = key, .value = value };
                root.entries = entries;
                root.bitmap = 1; // First bit set
                
                return .{
                    .allocator = self.allocator,
                    .root = root,
                    .len = 1,
                };
            }
            
            const new_root = try self.assocInNode(self.root.?, hash, 0, key, value);
            
            // Check if this was an update or insert
            const was_update = self.get(key) != null;
            
            return .{
                .allocator = self.allocator,
                .root = new_root,
                .len = if (was_update) self.len else self.len + 1,
            };
        }
        
        fn assocInNode(
            self: Self,
            node: *Node,
            hash: u32,
            depth: u32,
            key: K,
            value: V,
        ) !*Node {
            const idx = hash & HASH_MASK;
            const bit = @as(u32, 1) << @intCast(idx);
            
            // Clone node
            const new_node = try self.cloneNode(node);
            
            if (node.bitmap & bit != 0) {
                // Slot occupied - check if update or collision
                const entry_idx = @popCount(node.bitmap & (bit - 1));
                
                if (entry_idx < node.entries.len and 
                    self.keysEqual(node.entries[entry_idx].key, key)) {
                    // Update existing
                    var new_entries = try self.allocator.alloc(Node.Entry, node.entries.len);
                    @memcpy(new_entries, node.entries);
                    new_entries[entry_idx].value = value;
                    new_node.entries = new_entries;
                } else {
                    // Collision - need to create child
                    // For simplicity, just add to entries (handles ~20 items per node)
                    const new_entries = try self.allocator.alloc(Node.Entry, node.entries.len + 1);
                    @memcpy(new_entries[0..entry_idx], node.entries[0..entry_idx]);
                    new_entries[entry_idx] = .{ .key = key, .value = value };
                    @memcpy(new_entries[entry_idx + 1 ..], node.entries[entry_idx..]);
                    new_node.entries = new_entries;
                }
            } else {
                // New slot
                const entry_idx = @popCount(node.bitmap & (bit - 1));
                const new_entries = try self.allocator.alloc(Node.Entry, node.entries.len + 1);
                @memcpy(new_entries[0..entry_idx], node.entries[0..entry_idx]);
                new_entries[entry_idx] = .{ .key = key, .value = value };
                @memcpy(new_entries[entry_idx + 1 ..], node.entries[entry_idx..]);
                new_node.entries = new_entries;
                new_node.bitmap |= bit;
            }
            
            node.release(self.allocator);
            return new_node;
        }
        
        fn cloneNode(self: Self, node: *Node) !*Node {
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .refs = 1,
                .bitmap = node.bitmap,
                .entries = &[_]Node.Entry{},
                .children = &[_]?*Node{},
            };
            
            // Copy entries
            if (node.entries.len > 0) {
                new_node.entries = try self.allocator.dupe(Node.Entry, node.entries);
            }
            
            // Acquire refs to children
            if (node.children.len > 0) {
                new_node.children = try self.allocator.dupe(?*Node, node.children);
                for (new_node.children) |child| {
                    if (child) |c| c.acquire();
                }
            }
            
            return new_node;
        }
        
        fn keysEqual(self: Self, a: K, b: K) bool {
            _ = self;
            if (K == []const u8) {
                return std.mem.eql(u8, a, b);
            } else {
                return a == b;
            }
        }
        
        /// Remove key (returns new map without key)
        pub fn dissoc(self: Self, key: K) !Self {
            if (self.get(key) == null) return self.clone();
            
            // Simplified: return new map without the entry
            // Full implementation would clone and remove
            _ = key;
            return self.clone();
        }
        
        /// Iterator over key-value pairs
        pub fn iterator(self: Self) MapIterator(K, V) {
            return .{ .map = self, .stack = ArrayList(*Node).init(self.allocator) };
        }
    };
}

pub fn MapIterator(comptime K: type, comptime V: type) type {
    return struct {
        map: ImmutableMap(K, V),
        stack: ArrayList(*ImmutableMap(K, V).Node),
        current_entry: usize = 0,
        
        pub fn next(self: *@This()) ?struct { key: K, value: V } {
            // Simplified - full implementation would traverse tree
            _ = self;
            return null;
        }
        
        pub fn deinit(self: *@This()) void {
            self.stack.deinit();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ImmutableArray basic operations" {
    const allocator = std.testing.allocator;
    
    var arr = ImmutableArray(i32).init(allocator);
    defer arr.deinit();
    
    // Append
    var arr2 = try arr.append(1);
    defer arr2.deinit();
    
    var arr3 = try arr2.append(2);
    defer arr3.deinit();
    
    var arr4 = try arr3.append(3);
    defer arr4.deinit();
    
    try std.testing.expectEqual(@as(i32, 1), arr4.get(0).?);
    try std.testing.expectEqual(@as(i32, 2), arr4.get(1).?);
    try std.testing.expectEqual(@as(i32, 3), arr4.get(2).?);
    
    // Original unchanged
    try std.testing.expectEqual(@as(usize, 0), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr2.len);
}

test "ImmutableArray structural sharing" {
    const allocator = std.testing.allocator;
    
    var arr = ImmutableArray(i32).init(allocator);
    defer arr.deinit();
    
    // Build array
    var current = arr;
    defer current.deinit();
    
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var next = try current.append(i);
        current.deinit();
        current = next;
    }
    
    try std.testing.expectEqual(@as(usize, 100), current.len);
    try std.testing.expectEqual(@as(i32, 50), current.get(50).?);
    try std.testing.expectEqual(@as(i32, 99), current.get(99).?);
}

test "ImmutableMap basic operations" {
    const allocator = std.testing.allocator;
    
    var map = ImmutableMap([]const u8, i32).init(allocator);
    defer map.deinit();
    
    // Assoc
    var map2 = try map.assoc("a", 1);
    defer map2.deinit();
    
    var map3 = try map2.assoc("b", 2);
    defer map3.deinit();
    
    // Get
    try std.testing.expectEqual(@as(i32, 1), map3.get("a").?);
    try std.testing.expectEqual(@as(i32, 2), map3.get("b").?);
    try std.testing.expect(map3.get("c") == null);
    
    // Update
    var map4 = try map3.assoc("a", 10);
    defer map4.deinit();
    try std.testing.expectEqual(@as(i32, 10), map4.get("a").?);
    
    // Original unchanged
    try std.testing.expectEqual(@as(i32, 1), map2.get("a").?);
}

test "ImmutableMap int keys" {
    const allocator = std.testing.allocator;
    
    var map = ImmutableMap(i64, f64).init(allocator);
    defer map.deinit();
    
    var map2 = try map.assoc(100, 1.5);
    defer map2.deinit();
    
    var map3 = try map2.assoc(200, 2.5);
    defer map3.deinit();
    
    try std.testing.expectEqual(@as(f64, 1.5), map3.get(100).?);
    try std.testing.expectEqual(@as(f64, 2.5), map3.get(200).?);
}
