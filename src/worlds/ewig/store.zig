//! store.zig - Content-addressed storage for Ewig
//!
//! Merkle DAG for content addressing with:
//! - Deduplication (same content = same hash)
//! - Storage backends: memory, file, sqlite
//! - Garbage collection of unreferenced content
//! - CAS (Content Addressed Storage) interface

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");

const Hash = format.Hash;
const computeHash = format.computeHash;
const combineHashes = format.combineHashes;

// ============================================================================
// MERKLE DAG
// ============================================================================

/// Node in a Merkle DAG
pub const MerkleNode = struct {
    hash: Hash,
    data: []const u8,
    children: []const Hash,
    
    const Self = @This();
    
    /// Compute Merkle hash of this node and its children
    pub fn computeMerkleHash(data: []const u8, children: []const Hash) Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        // Hash data length and data
        hasher.update(std.mem.asBytes(&@as(u64, @intCast(data.len))));
        hasher.update(data);
        
        // Hash children count and child hashes
        hasher.update(std.mem.asBytes(&@as(u64, @intCast(children.len))));
        for (children) |child| {
            hasher.update(&child);
        }
        
        var hash: Hash = undefined;
        hasher.final(&hash);
        return hash;
    }
    
    /// Verify this node's hash is correct
    pub fn verify(self: Self) bool {
        const computed = computeMerkleHash(self.data, self.children);
        return std.mem.eql(u8, &self.hash, &computed);
    }
};

/// Merkle tree for efficient verification
pub const MerkleTree = struct {
    allocator: Allocator,
    leaves: std.ArrayList(Hash),
    levels: std.ArrayList(std.ArrayList(Hash)),
    root: Hash,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .leaves = std.ArrayList(Hash).init(allocator),
            .levels = std.ArrayList(std.ArrayList(Hash)).init(allocator),
            .root = [_]u8{0} ** 32,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.leaves.deinit();
        for (self.levels.items) |*level| {
            level.deinit();
        }
        self.levels.deinit();
    }
    
    /// Add a leaf hash
    pub fn addLeaf(self: *Self, hash: Hash) !void {
        try self.leaves.append(hash);
    }
    
    /// Build the tree and compute root
    pub fn build(self: *Self) !Hash {
        if (self.leaves.items.len == 0) {
            self.root = [_]u8{0} ** 32;
            return self.root;
        }
        
        // Clear previous levels
        for (self.levels.items) |*level| {
            level.deinit();
        }
        self.levels.clearRetainingCapacity();
        
        // Start with leaves
        var current_level = std.ArrayList(Hash).init(self.allocator);
        try current_level.appendSlice(self.leaves.items);
        
        // Build tree bottom-up
        while (current_level.items.len > 1) {
            try self.levels.append(current_level);
            
            const parent_size = (current_level.items.len + 1) / 2;
            var parent_level = std.ArrayList(Hash).init(self.allocator);
            
            var i: usize = 0;
            while (i < current_level.items.len) : (i += 2) {
                if (i + 1 < current_level.items.len) {
                    const combined = combineHashes(
                        current_level.items[i],
                        current_level.items[i + 1]
                    );
                    try parent_level.append(combined);
                } else {
                    // Odd node out - promote to next level
                    try parent_level.append(current_level.items[i]);
                }
            }
            
            current_level = parent_level;
        }
        
        try self.levels.append(current_level);
        
        self.root = current_level.items[0];
        return self.root;
    }
    
    /// Generate proof for a leaf at given index
    pub fn getProof(self: Self, leaf_index: usize) !MerkleProof {
        if (leaf_index >= self.leaves.items.len) return error.InvalidIndex;
        
        var proof = MerkleProof{
            .leaf_hash = self.leaves.items[leaf_index],
            .siblings = std.ArrayList(Hash).init(self.allocator),
            .indices = std.ArrayList(usize).init(self.allocator),
        };
        
        var idx = leaf_index;
        for (self.levels.items) |level| {
            const sibling_idx = if (idx % 2 == 0) idx + 1 else idx - 1;
            if (sibling_idx < level.items.len) {
                try proof.siblings.append(level.items[sibling_idx]);
                try proof.indices.append(idx % 2);
            }
            idx /= 2;
        }
        
        return proof;
    }
    
    /// Get root hash
    pub fn getRoot(self: Self) Hash {
        return self.root;
    }
};

/// Merkle proof for verification
pub const MerkleProof = struct {
    leaf_hash: Hash,
    siblings: std.ArrayList(Hash),
    indices: std.ArrayList(usize), // 0 = left, 1 = right
    
    pub fn deinit(self: *MerkleProof) void {
        self.siblings.deinit();
        self.indices.deinit();
    }
    
    /// Verify proof against a root hash
    pub fn verify(self: MerkleProof, root: Hash) bool {
        var current = self.leaf_hash;
        
        for (self.siblings.items, self.indices.items) |sibling, idx| {
            current = if (idx == 0)
                combineHashes(current, sibling)
            else
                combineHashes(sibling, current);
        }
        
        return std.mem.eql(u8, &current, &root);
    }
};

// ============================================================================
// CAS INTERFACE
// ============================================================================

/// Content Addressed Storage interface
pub const CAS = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, data: []const u8) anyerror!Hash,
        get: *const fn (ctx: *anyopaque, hash: Hash) anyerror!?[]const u8,
        exists: *const fn (ctx: *anyopaque, hash: Hash) bool,
        delete: *const fn (ctx: *anyopaque, hash: Hash) anyerror!void,
        ref: *const fn (ctx: *anyopaque, hash: Hash) anyerror!void,
        unref: *const fn (ctx: *anyopaque, hash: Hash) anyerror!void,
    };
    
    pub fn put(self: CAS, data: []const u8) !Hash {
        return self.vtable.put(self, data);
    }
    
    pub fn get(self: CAS, hash: Hash) !?[]const u8 {
        return self.vtable.get(self, hash);
    }
    
    pub fn exists(self: CAS, hash: Hash) bool {
        return self.vtable.exists(self, hash);
    }
    
    pub fn delete(self: CAS, hash: Hash) !void {
        return self.vtable.delete(self, hash);
    }
    
    pub fn ref(self: CAS, hash: Hash) !void {
        return self.vtable.ref(self, hash);
    }
    
    pub fn unref(self: CAS, hash: Hash) !void {
        return self.vtable.unref(self, hash);
    }
};

// ============================================================================
// MEMORY BACKEND
// ============================================================================

/// In-memory CAS backend
pub const MemoryStore = struct {
    allocator: Allocator,
    data: std.HashMap(Hash, []const u8, format.HashContext, std.hash_map.default_max_load_percentage),
    refs: std.HashMap(Hash, usize, format.HashContext, std.hash_map.default_max_load_percentage),
    total_size: usize,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .data = std.HashMap(Hash, []const u8, format.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .refs = std.HashMap(Hash, usize, format.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .total_size = 0,
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.data.valueIterator();
        while (it.next()) |data| {
            self.allocator.free(data.*);
        }
        self.data.deinit();
        self.refs.deinit();
    }
    
    pub fn put(self: *Self, data: []const u8) !Hash {
        const hash = computeHash(data);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if already exists
        if (self.data.contains(hash)) {
            return hash;
        }
        
        // Store data
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        
        try self.data.put(hash, copy);
        try self.refs.put(hash, 1);
        
        self.total_size += data.len;
        
        return hash;
    }
    
    pub fn get(self: *Self, hash: Hash) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.data.get(hash);
    }
    
    pub fn exists(self: *Self, hash: Hash) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.data.contains(hash);
    }
    
    pub fn ref(self: *Self, hash: Hash) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const entry = self.refs.getEntry(hash) orelse return error.NotFound;
        entry.value_ptr.* += 1;
    }
    
    pub fn unref(self: *Self, hash: Hash) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const entry = self.refs.getEntry(hash) orelse return error.NotFound;
        
        if (entry.value_ptr.* > 0) {
            entry.value_ptr.* -= 1;
        }
    }
    
    pub fn delete(self: *Self, hash: Hash) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Only delete if no references
        const ref_count = self.refs.get(hash) orelse 0;
        if (ref_count > 0) return error.HasReferences;
        
        if (self.data.fetchRemove(hash)) |kv| {
            self.total_size -= kv.value.len;
            self.allocator.free(kv.value);
        }
        
        _ = self.refs.remove(hash);
    }
    
    /// Garbage collect unreferenced objects
    pub fn gc(self: *Self) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var to_remove = std.ArrayList(Hash).init(self.allocator);
        defer to_remove.deinit();
        
        var it = self.refs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try to_remove.append(entry.key_ptr.*);
            }
        }
        
        var freed: usize = 0;
        for (to_remove.items) |hash| {
            if (self.data.fetchRemove(hash)) |kv| {
                freed += kv.value.len;
                self.allocator.free(kv.value);
            }
            _ = self.refs.remove(hash);
        }
        
        self.total_size -= freed;
        return freed;
    }
    
    pub fn cas(self: *Self) CAS {
        return .{
            .vtable = &.{
                .put = struct {
                    fn f(ctx: *anyopaque, data: []const u8) !Hash {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.put(data);
                    }
                }.f,
                .get = struct {
                    fn f(ctx: *anyopaque, hash: Hash) !?[]const u8 {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.get(hash);
                    }
                }.f,
                .exists = struct {
                    fn f(ctx: *anyopaque, hash: Hash) bool {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.exists(hash);
                    }
                }.f,
                .delete = struct {
                    fn f(ctx: *anyopaque, hash: Hash) !void {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.delete(hash);
                    }
                }.f,
                .ref = struct {
                    fn f(ctx: *anyopaque, hash: Hash) !void {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.ref(hash);
                    }
                }.f,
                .unref = struct {
                    fn f(ctx: *anyopaque, hash: Hash) !void {
                        const store: *MemoryStore = @ptrCast(@alignCast(ctx));
                        return store.unref(hash);
                    }
                }.f,
            },
        };
    }
};

// ============================================================================
// FILE BACKEND
// ============================================================================

/// File-based CAS backend
pub const FileStore = struct {
    allocator: Allocator,
    base_path: []const u8,
    index: std.HashMap(Hash, struct { offset: u64, size: u32 }, format.HashContext, std.hash_map.default_max_load_percentage),
    refs: std.HashMap(Hash, usize, format.HashContext, std.hash_map.default_max_load_percentage),
    data_file: ?std.fs.File,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    const INDEX_MAGIC = "EWIG_IDX\x00\x01";
    
    pub fn init(allocator: Allocator, base_path: []const u8) !Self {
        // Create directory
        try std.fs.cwd().makePath(base_path);
        
        var self = Self{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .index = std.HashMap(Hash, struct { offset: u64, size: u32 }, format.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .refs = std.HashMap(Hash, usize, format.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .data_file = null,
            .mutex = .{},
        };
        
        // Open data file
        const data_path = try std.fs.path.join(allocator, &.{ base_path, "data.bin" });
        defer allocator.free(data_path);
        
        self.data_file = try std.fs.cwd().createFile(data_path, .{
            .read = true,
            .truncate = false,
        });
        
        // Load index
        try self.loadIndex();
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.data_file) |*f| {
            f.close();
        }
        self.saveIndex() catch {};
        self.allocator.free(self.base_path);
        self.index.deinit();
        self.refs.deinit();
    }
    
    fn loadIndex(self: *Self) !void {
        const index_path = try std.fs.path.join(self.allocator, &.{ self.base_path, "index.bin" });
        defer self.allocator.free(index_path);
        
        const file = std.fs.cwd().openFile(index_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        
        var reader = file.reader();
        
        // Check magic
        var magic: [10]u8 = undefined;
        reader.readNoEof(&magic) catch return;
        if (!std.mem.eql(u8, &magic, INDEX_MAGIC)) return error.InvalidIndex;
        
        // Read entry count
        const count = reader.readInt(u64, .little) catch return;
        
        // Read entries
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            var hash: Hash = undefined;
            reader.readNoEof(&hash) catch break;
            
            const offset = reader.readInt(u64, .little) catch break;
            const size = reader.readInt(u32, .little) catch break;
            const refcount = reader.readInt(u64, .little) catch break;
            
            self.index.put(hash, .{ .offset = offset, .size = size }) catch break;
            self.refs.put(hash, refcount) catch break;
        }
    }
    
    fn saveIndex(self: *Self) !void {
        const index_path = try std.fs.path.join(self.allocator, &.{ self.base_path, "index.bin" });
        defer self.allocator.free(index_path);
        
        const file = try std.fs.cwd().createFile(index_path, .{});
        defer file.close();
        
        var writer = file.writer();
        
        // Write magic
        try writer.writeAll(INDEX_MAGIC);
        
        // Write entry count
        try writer.writeInt(u64, self.index.count(), .little);
        
        // Write entries
        var it = self.index.iterator();
        while (it.next()) |entry| {
            try writer.writeAll(&entry.key_ptr.*);
            try writer.writeInt(u64, entry.value_ptr.*.offset, .little);
            try writer.writeInt(u32, entry.value_ptr.*.size, .little);
            
            const refcount = self.refs.get(entry.key_ptr.*) orelse 1;
            try writer.writeInt(u64, refcount, .little);
        }
    }
    
    pub fn put(self: *Self, data: []const u8) !Hash {
        const hash = computeHash(data);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if already exists
        if (self.index.contains(hash)) {
            // Increment ref count
            const entry = self.refs.getEntry(hash) orelse return error.NotFound;
            entry.value_ptr.* += 1;
            return hash;
        }
        
        const f = self.data_file.?;
        
        // Seek to end
        const offset = try f.getEndPos();
        try f.seekFromEnd(0);
        
        // Write size prefix and data
        var writer = f.writer();
        try writer.writeInt(u32, @intCast(data.len), .little);
        try writer.writeAll(data);
        try f.sync();
        
        // Update index
        try self.index.put(hash, .{
            .offset = offset,
            .size = @intCast(data.len),
        });
        try self.refs.put(hash, 1);
        
        // Save index periodically (every 100 writes)
        if (self.index.count() % 100 == 0) {
            self.mutex.unlock();
            defer self.mutex.lock();
            try self.saveIndex();
        }
        
        return hash;
    }
    
    pub fn get(self: *Self, hash: Hash) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const entry = self.index.get(hash) orelse return null;
        
        const f = self.data_file.?;
        
        // Seek to position
        try f.seekTo(entry.offset + 4); // Skip size prefix
        
        // Read data
        var data = try self.allocator.alloc(u8, entry.size);
        errdefer self.allocator.free(data);
        
        const read = try f.read(data);
        if (read != entry.size) return error.IncompleteRead;
        
        return data;
    }
    
    pub fn exists(self: *Self, hash: Hash) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.index.contains(hash);
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "merkle tree" {
    var tree = MerkleTree.init(testing.allocator);
    defer tree.deinit();
    
    // Add some leaves
    try tree.addLeaf(computeHash("a"));
    try tree.addLeaf(computeHash("b"));
    try tree.addLeaf(computeHash("c"));
    try tree.addLeaf(computeHash("d"));
    
    // Build tree
    const root = try tree.build();
    
    // Root should not be zero
    var zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &root, &zero_hash));
    
    // Get proof for leaf 0
    var proof = try tree.getProof(0);
    defer proof.deinit();
    
    // Verify proof
    try testing.expect(proof.verify(root));
}

test "memory store deduplication" {
    var store = MemoryStore.init(testing.allocator);
    defer store.deinit();
    
    const data = "test data";
    
    // Put same data twice
    const hash1 = try store.put(data);
    const hash2 = try store.put(data);
    
    // Should get same hash
    try testing.expect(std.mem.eql(u8, &hash1, &hash2));
    
    // Should exist
    try testing.expect(store.exists(hash1));
    
    // Should retrieve
    const retrieved = try store.get(hash1);
    try testing.expectEqualStrings(data, retrieved.?);
}

test "memory store gc" {
    var store = MemoryStore.init(testing.allocator);
    defer store.deinit();
    
    const hash = try store.put("test");
    
    // Unref
    try store.unref(hash);
    
    // GC
    const freed = try store.gc();
    try testing.expect(freed > 0);
    
    // Should no longer exist
    try testing.expect(!store.exists(hash));
}
