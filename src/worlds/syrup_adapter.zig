//! Syrup adapter for world-tile integration
//!
//! Bridges world state with syrup tile system for serialization,
//! content-addressing, and CapTP distribution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syrup = @import("syrup");
const World = @import("world.zig").World;
const WorldState = @import("world.zig").WorldState;
const Player = @import("world.zig").Player;

/// A tile in the world grid
pub const WorldTile = struct {
    /// Tile coordinates
    x: i32,
    y: i32,
    z: i32,
    /// Tile content (serialized)
    content: syrup.Value,
    /// Tile metadata
    metadata: TileMetadata,
    
    pub const TileMetadata = struct {
        /// Last modified tick
        modified_tick: u64,
        /// Owner player ID (null = unowned)
        owner: ?u32,
        /// Tile type
        tile_type: TileType,
    };
    
    pub const TileType = enum {
        empty,
        terrain,
        object,
        player_spawn,
        interactive,
        circuit,
    };
    
    /// Serialize to syrup record
    pub fn toSyrup(self: WorldTile, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        try entries.append(arena_allocator, .{
            .key = syrup.Value.fromSymbol("x"),
            .value = syrup.Value.fromInteger(self.x),
        });
        try entries.append(arena_allocator, .{
            .key = syrup.Value.fromSymbol("y"),
            .value = syrup.Value.fromInteger(self.y),
        });
        try entries.append(arena_allocator, .{
            .key = syrup.Value.fromSymbol("z"),
            .value = syrup.Value.fromInteger(self.z),
        });
        try entries.append(arena_allocator, .{
            .key = syrup.Value.fromSymbol("type"),
            .value = syrup.Value.fromSymbol(@tagName(self.metadata.tile_type)),
        });
        try entries.append(arena_allocator, .{
            .key = syrup.Value.fromSymbol("modified"),
            .value = syrup.Value.fromInteger(@intCast(self.metadata.modified_tick)),
        });
        
        if (self.metadata.owner) |owner| {
            try entries.append(arena_allocator, .{
                .key = syrup.Value.fromSymbol("owner"),
                .value = syrup.Value.fromInteger(owner),
            });
        }
        
        const label = syrup.Value.fromSymbol("tile");
        var fields = try allocator.alloc(syrup.Value, 2);
        defer allocator.free(fields);
        
        fields[0] = syrup.Value.fromDictionary(try entries.toOwnedSlice(allocator));
        fields[1] = self.content;
        
        return syrup.Value.fromRecord(&label, fields);
    }
};

/// Mapping between world coordinates and tiles
pub const TileMapping = struct {
    /// Tile size in world units
    tile_size: f32,
    /// Origin offset
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    
    /// Convert world position to tile coordinates
    pub fn worldToTile(self: TileMapping, x: f32, y: f32, z: f32) [3]i32 {
        return .{
            @intFromFloat((x - self.origin_x) / self.tile_size),
            @intFromFloat((y - self.origin_y) / self.tile_size),
            @intFromFloat((z - self.origin_z) / self.tile_size),
        };
    }
    
    /// Convert tile coordinates to world position (center)
    pub fn tileToWorld(self: TileMapping, tx: i32, ty: i32, tz: i32) [3]f32 {
        return .{
            self.origin_x + (@as(f32, @floatFromInt(tx)) + 0.5) * self.tile_size,
            self.origin_y + (@as(f32, @floatFromInt(ty)) + 0.5) * self.tile_size,
            self.origin_z + (@as(f32, @floatFromInt(tz)) + 0.5) * self.tile_size,
        };
    }
};

/// Syrup adapter for world serialization
pub const SyrupAdapter = struct {
    const Self = @This();
    
    allocator: Allocator,
    mapping: TileMapping,
    tile_cache: std.AutoHashMapUnmanaged(TileKey, WorldTile),
    
    const TileKey = struct {
        x: i32,
        y: i32,
        z: i32,
        
        pub fn hash(self: TileKey) u32 {
            var h: u32 = @bitCast(self.x);
            h = h *% 31 +% @as(u32, @bitCast(self.y));
            h = h *% 31 +% @bitCast(self.z);
            return h;
        }
        
        pub fn eql(a: TileKey, b: TileKey) bool {
            return a.x == b.x and a.y == b.y and a.z == b.z;
        }
    };
    
    pub fn init(allocator: Allocator, mapping: TileMapping) Self {
        return .{
            .allocator = allocator,
            .mapping = mapping,
            .tile_cache = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.tile_cache.deinit(self.allocator);
    }
    
    /// Convert world state to tile grid
    pub fn worldToTiles(self: *Self, world: World) ![]WorldTile {
        var tiles = std.ArrayListUnmanaged(WorldTile){};
        defer tiles.deinit(self.allocator);
        
        // Create tiles from player positions
        for (world.getActivePlayers()) |player| {
            const tile_coords = self.mapping.worldToTile(0, 0, 0); // Would use actual position
            
            const tile = WorldTile{
                .x = tile_coords[0],
                .y = tile_coords[1],
                .z = tile_coords[2],
                .content = try player.toSyrup(self.allocator),
                .metadata = .{
                    .modified_tick = world.getTick(),
                    .owner = player.id,
                    .tile_type = .player_spawn,
                },
            };
            
            try tiles.append(self.allocator, tile);
        }
        
        return tiles.toOwnedSlice(self.allocator);
    }
    
    /// Serialize world as tile grid
    pub fn serializeWorld(self: *Self, world: World) !syrup.Value {
        const tiles = try self.worldToTiles(world);
        defer self.allocator.free(tiles);
        
        var tile_list = std.ArrayListUnmanaged(syrup.Value){};
        defer tile_list.deinit(self.allocator);
        
        for (tiles) |tile| {
            try tile_list.append(self.allocator, try tile.toSyrup(self.allocator));
        }
        
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(self.allocator);
        
        try entries.append(self.allocator, .{
            .key = syrup.Value.fromSymbol("uri"),
            .value = syrup.Value.fromString(world.config.uri),
        });
        try entries.append(self.allocator, .{
            .key = syrup.Value.fromSymbol("tick"),
            .value = syrup.Value.fromInteger(@intCast(world.getTick())),
        });
        try entries.append(self.allocator, .{
            .key = syrup.Value.fromSymbol("tiles"),
            .value = syrup.Value.fromList(try tile_list.toOwnedSlice(self.allocator)),
        });
        
        const label = syrup.Value.fromSymbol("world");
        var fields = try self.allocator.alloc(syrup.Value, 1);
        defer self.allocator.free(fields);
        
        fields[0] = syrup.Value.fromDictionary(try entries.toOwnedSlice(self.allocator));
        
        return syrup.Value.fromRecord(&label, fields);
    }
    
    /// Deserialize tiles to world (partial reconstruction)
    pub fn deserializeTiles(self: *Self, value: syrup.Value) ![]WorldTile {
        _ = self;
        _ = value;
        // Implementation would parse syrup and reconstruct tiles
        return &[_]WorldTile{};
    }
    
    /// Get or create tile at coordinates
    pub fn getTile(self: *Self, x: i32, y: i32, z: i32) !*WorldTile {
        const key = TileKey{ .x = x, .y = y, .z = z };
        
        if (self.tile_cache.get(key)) |*tile| {
            return tile;
        }
        
        const new_tile = WorldTile{
            .x = x,
            .y = y,
            .z = z,
            .content = syrup.Value.fromSymbol("empty"),
            .metadata = .{
                .modified_tick = 0,
                .owner = null,
                .tile_type = .empty,
            },
        };
        
        try self.tile_cache.put(self.allocator, key, new_tile);
        return @as(*WorldTile, self.tile_cache.getPtr(key).?);
    }
    
    /// Update tile content
    pub fn updateTile(self: *Self, x: i32, y: i32, z: i32, content: syrup.Value, tick: u64) !void {
        const tile = try self.getTile(x, y, z);
        tile.content = content;
        tile.metadata.modified_tick = tick;
    }
    
    /// Compute CID for tile grid
    pub fn computeTileGridCid(self: *Self, world: World, out: *[32]u8) !void {
        const world_syrup = try self.serializeWorld(world);
        defer {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
        }
        
        try syrup.computeCid(world_syrup, out);
    }
    
    /// Create damage tracking for tiles (only changed since last sync)
    pub fn computeDelta(self: *Self, _: World, since_tick: u64) ![]WorldTile {
        var deltas = std.ArrayListUnmanaged(WorldTile){};
        defer deltas.deinit(self.allocator);
        
        var it = self.tile_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.metadata.modified_tick >= since_tick) {
                try deltas.append(self.allocator, entry.value_ptr.*);
            }
        }
        
        return deltas.toOwnedSlice(self.allocator);
    }
    
    /// Merge tile state from remote source (CapTP sync)
    pub fn mergeRemoteTiles(self: *Self, remote_tiles: []WorldTile, strategy: MergeStrategy) !void {
        for (remote_tiles) |tile| {
            const key = TileKey{ .x = tile.x, .y = tile.y, .z = tile.z };
            
            switch (strategy) {
                .overwrite => {
                    try self.tile_cache.put(self.allocator, key, tile);
                },
                .keep_local => {
                    // Only insert if not exists
                    if (!self.tile_cache.contains(key)) {
                        try self.tile_cache.put(self.allocator, key, tile);
                    }
                },
                .max_tick => {
                    if (self.tile_cache.get(key)) |local| {
                        if (tile.metadata.modified_tick > local.metadata.modified_tick) {
                            try self.tile_cache.put(self.allocator, key, tile);
                        }
                    } else {
                        try self.tile_cache.put(self.allocator, key, tile);
                    }
                },
            }
        }
    }
    
    pub const MergeStrategy = enum {
        /// Overwrite local with remote
        overwrite,
        /// Keep local, only add new
        keep_local,
        /// Keep tile with higher tick (last writer wins)
        max_tick,
    };
};

/// Tile-based world operations
pub const TileOperations = struct {
    /// Apply a function to all tiles in a region
    pub fn mapRegion(
        adapter: *SyrupAdapter,
        min_x: i32,
        min_y: i32,
        min_z: i32,
        max_x: i32,
        max_y: i32,
        max_z: i32,
        comptime op: fn (*WorldTile) void,
    ) !void {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            var y = min_y;
            while (y <= max_y) : (y += 1) {
                var z = min_z;
                while (z <= max_z) : (z += 1) {
                    const tile = try adapter.getTile(x, y, z);
                    op(tile);
                }
            }
        }
    }
    
    /// Find tiles matching predicate
    pub fn findTiles(
        allocator: Allocator,
        adapter: *SyrupAdapter,
        predicate: fn (WorldTile) bool,
    ) ![]WorldTile {
        var results = std.ArrayListUnmanaged(WorldTile){};
        defer results.deinit(allocator);
        
        var it = adapter.tile_cache.iterator();
        while (it.next()) |entry| {
            if (predicate(entry.value_ptr.*)) {
                try results.append(allocator, entry.value_ptr.*);
            }
        }
        
        return results.toOwnedSlice(allocator);
    }
};

// Tests
const testing = std.testing;

test "tile mapping" {
    const mapping = TileMapping{
        .tile_size = 1.0,
        .origin_x = 0,
        .origin_y = 0,
        .origin_z = 0,
    };
    
    const tile = mapping.worldToTile(1.5, 2.5, 3.5);
    try testing.expectEqual(@as(i32, 1), tile[0]);
    try testing.expectEqual(@as(i32, 2), tile[1]);
    try testing.expectEqual(@as(i32, 3), tile[2]);
    
    const world = mapping.tileToWorld(1, 2, 3);
    try testing.expectApproxEqAbs(@as(f32, 1.5), world[0], 0.001);
}

test "syrup adapter" {
    const allocator = testing.allocator;
    
    const mapping = TileMapping{
        .tile_size = 1.0,
        .origin_x = 0,
        .origin_y = 0,
        .origin_z = 0,
    };
    
    var adapter = SyrupAdapter.init(allocator, mapping);
    defer adapter.deinit();
    
    const tile = try adapter.getTile(0, 0, 0);
    try testing.expectEqual(@as(i32, 0), tile.x);
    try testing.expectEqual(@as(i32, 0), tile.y);
    try testing.expectEqual(@as(i32, 0), tile.z);
}

test "world tile serialization" {
    const allocator = testing.allocator;
    
    const tile = WorldTile{
        .x = 1,
        .y = 2,
        .z = 3,
        .content = syrup.Value.fromString("test"),
        .metadata = .{
            .modified_tick = 100,
            .owner = 0,
            .tile_type = .terrain,
        },
    };
    
    const syrup_val = try tile.toSyrup(allocator);
    defer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
    }
    
    try testing.expect(syrup_val == .record);
}
