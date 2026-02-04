//! URI Handler for World Schemes
//!
//! a://, b://, c:// URI resolution and caching
//! Content-addressed storage

const std = @import("std");
const World = @import("world.zig").World;
const WorldVariant = @import("world.zig").WorldVariant;
// const ewig = @import("ewig/ewig.zig");
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const crypto = std.crypto;

/// Content-addressed cache entry
pub const CacheEntry = struct {
    hash: [32]u8,
    uri: []const u8,
    world: *World,
    access_count: u64,
    last_accessed: i64,
    size_bytes: usize,
};

/// URI resolver and cache
pub const UriResolver = struct {
    allocator: std.mem.Allocator,
    cache: StringHashMap(CacheEntry),
    // ewig: ?*ewig.Ewig,
    aliases: StringHashMap([]const u8), // alias -> canonical URI
    max_cache_size: usize,
    current_cache_size: usize,
    
    pub fn init(
        allocator: std.mem.Allocator,
        // ewig_opt: ?*ewig.Ewig,
        max_cache_size: usize,
    ) UriResolver {
        return .{
            .allocator = allocator,
            .cache = StringHashMap(CacheEntry).init(allocator),
            // .ewig = ewig_opt,
            .aliases = StringHashMap([]const u8).init(allocator),
            .max_cache_size = max_cache_size,
            .current_cache_size = 0,
        };
    }
    
    pub fn deinit(self: *UriResolver) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.world.destroy();
            self.allocator.free(entry.uri);
        }
        self.cache.deinit();
        
        var alias_it = self.aliases.iterator();
        while (alias_it.next()) |e| {
            self.allocator.free(e.value_ptr.*);
        }
        self.aliases.deinit();
    }
    
    /// Parse and validate URI
    pub fn parseUri(uri: []const u8) !ParsedUri {
        // Check scheme
        const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidScheme;
        const scheme = uri[0..scheme_end];
        
        const variant = std.meta.stringToEnum(WorldVariant, scheme) orelse {
            return error.UnknownScheme;
        };
        
        var result = ParsedUri{
            .variant = variant,
            .name = undefined,
            .version = null,
            .params = std.StringHashMap([]const u8).init(std.heap.page_allocator),
            .hash = null,
        };
        
        // Parse rest
        const rest_start = scheme_end + 3;
        var rest = uri[rest_start..];
        
        // Check for hash fragment
        if (std.mem.indexOf(u8, rest, "#")) |hash_idx| {
            result.hash = rest[hash_idx + 1 ..];
            rest = rest[0..hash_idx];
        }
        
        // Check for query params
        if (std.mem.indexOf(u8, rest, "?")) |query_idx| {
            const query = rest[query_idx + 1 ..];
            rest = rest[0..query_idx];
            
            // Parse params
            var it = std.mem.split(u8, query, "&");
            while (it.next()) |pair| {
                if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
                    const key = pair[0..eq_idx];
                    const value = pair[eq_idx + 1 ..];
                    try result.params.put(key, value);
                }
            }
        }
        
        result.name = rest;
        return result;
    }
    
    /// Resolve URI to world
    pub fn resolve(self: *UriResolver, uri: []const u8) !*World {
        // Check aliases
        const canonical = self.aliases.get(uri) orelse uri;
        
        // Check if content hash is specified
        const parsed = try parseUri(canonical);
        defer parsed.params.deinit();
        
        // If hash specified, lookup by hash
        if (parsed.hash) |hash_str| {
            var hash: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&hash, hash_str);
            
            if (self.findByHash(hash)) |entry| {
                return entry.world;
            }
        }
        
        // Check cache by URI
        if (self.cache.get(canonical)) |entry| {
            // Update access stats
            var updated = entry;
            updated.access_count += 1;
            updated.last_accessed = std.time.milliTimestamp();
            try self.cache.put(canonical, updated);
            return entry.world;
        }
        
        // Not in cache - construct from ewig or create new
        const world = try self.constructWorld(canonical, parsed);
        
        // Cache it
        try self.cacheWorld(canonical, world);
        
        return world;
    }
    
    /// Construct world from URI
    fn constructWorld(
        self: *UriResolver,
        uri: []const u8,
        parsed: ParsedUri,
    ) !*World {
        _ = parsed;
        
        // Try to reconstruct from ewig log
        // if (self.ewig) |ewig_instance| {
        //     // Check if there's history for this URI
        //     const timeline = try ewig_instance.timeline(uri);
        //     
        //     // Get latest state
        //     if (timeline.events.len > 0) {
        //         const latest = timeline.events[timeline.events.len - 1];
        //         const world = try World.create(self.allocator, uri, ewig_instance.log);
        //         try world.restore(latest.hash);
        //         return world;
        //     }
        // }
        
        // Create new world
        // return try World.create(self.allocator, uri, if (self.ewig) |e| e.log else null);
        return try World.create(self.allocator, uri, null);
    }
    
    /// Cache a world
    fn cacheWorld(self: *UriResolver, uri: []const u8, world: *World) !void {
        // Check cache size
        const entry_size = @sizeOf(CacheEntry) + uri.len;
        
        while (self.current_cache_size + entry_size > self.max_cache_size) {
            try self.evictLRU();
        }
        
        const entry = CacheEntry{
            .hash = world.state.hash,
            .uri = try self.allocator.dupe(u8, uri),
            .world = world,
            .access_count = 1,
            .last_accessed = std.time.milliTimestamp(),
            .size_bytes = entry_size,
        };
        
        try self.cache.put(uri, entry);
        self.current_cache_size += entry_size;
    }
    
    /// Find world by content hash
    fn findByHash(self: *UriResolver, hash: [32]u8) ?CacheEntry {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.hash, &hash)) {
                return entry.*;
            }
        }
        return null;
    }
    
    /// Evict least recently used entry
    fn evictLRU(self: *UriResolver) !void {
        var oldest: ?struct { key: []const u8, time: i64 } = null;
        
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (oldest == null or entry.value_ptr.last_accessed < oldest.?.time) {
                oldest = .{ .key = entry.key_ptr.*, .time = entry.value_ptr.last_accessed };
            }
        }
        
        if (oldest) |o| {
            if (self.cache.fetchRemove(o.key)) |removed| {
                self.allocator.free(removed.value.uri);
                removed.value.world.destroy();
                self.current_cache_size -= removed.value.size_bytes;
            }
        }
    }
    
    /// Create alias
    pub fn alias(self: *UriResolver, alias_name: []const u8, canonical_uri: []const u8) !void {
        try self.aliases.put(
            try self.allocator.dupe(u8, alias_name),
            try self.allocator.dupe(u8, canonical_uri),
        );
    }
    
    /// Invalidate cache entry
    pub fn invalidate(self: *UriResolver, uri: []const u8) void {
        if (self.cache.fetchRemove(uri)) |removed| {
            self.allocator.free(removed.value.uri);
            removed.value.world.destroy();
            self.current_cache_size -= removed.value.size_bytes;
        }
    }
    
    /// Get cache statistics
    pub fn getStats(self: *UriResolver) CacheStats {
        var stats = CacheStats{
            .entries = @intCast(self.cache.count()),
            .size_bytes = self.current_cache_size,
            .max_size_bytes = self.max_cache_size,
            .hit_count = 0,
            .miss_count = 0,
        };
        
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            if (entry.access_count > 1) {
                stats.hit_count += entry.access_count - 1;
            }
            stats.miss_count += 1;
        }
        
        return stats;
    }
    
    /// List all cached URIs
    pub fn listCached(self: *UriResolver, allocator: std.mem.Allocator) ![][]const u8 {
        var list = ArrayList([]const u8).init(allocator);
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit();
        }
        
        var it = self.cache.keyIterator();
        while (it.next()) |key| {
            try list.append(try allocator.dupe(u8, key.*));
        }
        
        return list.toOwnedSlice();
    }
    
    /// Resolve multiple URIs in batch
    pub fn resolveBatch(
        self: *UriResolver,
        uris: []const []const u8,
    ) ![]*World {
        var worlds = try self.allocator.alloc(*World, uris.len);
        errdefer self.allocator.free(worlds);
        
        for (uris, 0..) |uri, i| {
            worlds[i] = try self.resolve(uri);
        }
        
        return worlds;
    }
};

pub const ParsedUri = struct {
    variant: WorldVariant,
    name: []const u8,
    version: ?[]const u8,
    params: std.StringHashMap([]const u8),
    hash: ?[]const u8,
    
    pub fn deinit(self: *ParsedUri) void {
        self.params.deinit();
    }
    
    pub fn getParam(self: ParsedUri, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
};

pub const CacheStats = struct {
    entries: u32,
    size_bytes: usize,
    max_size_bytes: usize,
    hit_count: u64,
    miss_count: u64,
    
    pub fn hitRate(self: CacheStats) f64 {
        const total = self.hit_count + self.miss_count;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total));
    }
};

/// Protocol handler registration
pub const ProtocolRegistry = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(HandlerFn),
    
    pub const HandlerFn = *const fn (
        allocator: std.mem.Allocator,
        uri: []const u8,
        params: std.StringHashMap([]const u8),
    ) anyerror!*World;
    
    pub fn init(allocator: std.mem.Allocator) ProtocolRegistry {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
        };
    }
    
    pub fn deinit(self: *ProtocolRegistry) void {
        self.handlers.deinit();
    }
    
    pub fn register(
        self: *ProtocolRegistry,
        scheme: []const u8,
        handler: HandlerFn,
    ) !void {
        try self.handlers.put(try self.allocator.dupe(u8, scheme), handler);
    }
    
    pub fn resolve(
        self: *ProtocolRegistry,
        uri: []const u8,
    ) !*World {
        const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidUri;
        const scheme = uri[0..scheme_end];
        
        const handler = self.handlers.get(scheme) orelse return error.UnknownScheme;
        
        const parsed = try UriResolver.parseUri(uri);
        defer parsed.params.deinit();
        
        return handler(self.allocator, uri, parsed.params);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UriResolver parseUri" {
    const parsed = try UriResolver.parseUri("a://baseline#abc123");
    defer parsed.params.deinit();
    
    try std.testing.expectEqual(WorldVariant.A, parsed.variant);
    try std.testing.expectEqualStrings("baseline", parsed.name);
    try std.testing.expectEqualStrings("abc123", parsed.hash.?);
}

test "UriResolver parseUri with params" {
    const parsed = try UriResolver.parseUri("b://variant?players=3&difficulty=hard");
    defer parsed.params.deinit();
    
    try std.testing.expectEqual(WorldVariant.B, parsed.variant);
    try std.testing.expectEqualStrings("variant", parsed.name);
    try std.testing.expectEqualStrings("3", parsed.getParam("players").?);
    try std.testing.expectEqualStrings("hard", parsed.getParam("difficulty").?);
}

test "UriResolver cache" {
    const allocator = std.testing.allocator;
    
    var resolver = UriResolver.init(allocator, 1024 * 1024);
    defer resolver.deinit();
    
    // Resolve same URI twice
    const world1 = try resolver.resolve("a://test-world");
    const world2 = try resolver.resolve("a://test-world");
    
    // Should be same world (cached)
    try std.testing.expectEqual(world1, world2);
    
    // Check stats
    const stats = resolver.getStats();
    try std.testing.expect(stats.hit_count > 0);
}
