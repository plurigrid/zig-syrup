//! point_cloud.zig — PLY point cloud ingest for BCI station spatial reasoning
//!
//! Reads PLY files from RoomPlan/ARKit LiDAR scans and integrates with
//! the zig-syrup spatial system (czernowitz.zig, worlds/, propagator.zig).
//!
//! The point cloud feeds the station placement propagator:
//!   - Each point has a classification (wall/floor/ceiling/door/window)
//!   - Placement zones are computed for the GF(3) station triad
//!   - The propagator merges sensor data with placement constraints
//!
//! PLY → PointCloud → PlacementZone[3] → Syrup record → world:// state

const std = @import("std");
const syrup = @import("syrup.zig");
const Allocator = std.mem.Allocator;

/// Point classification from RoomPlan/ARKit
pub const Classification = enum(u3) {
    wall = 0,
    floor = 1,
    ceiling = 2,
    door = 3,
    window = 4,
    furniture = 5,
    unknown = 6,
};

/// Single point with color and classification
pub const Point = struct {
    x: f32,
    y: f32,
    z: f32,
    r: u8,
    g: u8,
    b: u8,
    class: Classification,
};

/// 3D Gaussian Splat (3DGS) — richer than a point, stores a full ellipsoid
/// Properties match the PLY format from ml-sharp / gsplat / nerfstudio
pub const GaussianSplat = struct {
    // position
    x: f32,
    y: f32,
    z: f32,
    // spherical harmonics DC (degree 0) = base color
    f_dc_0: f32, // R channel
    f_dc_1: f32, // G channel
    f_dc_2: f32, // B channel
    // opacity (logit space, sigmoid to get [0,1])
    opacity: f32,
    // log-scale of the 3 axes of the ellipsoid
    scale_0: f32,
    scale_1: f32,
    scale_2: f32,
    // rotation quaternion (wxyz)
    rot_0: f32,
    rot_1: f32,
    rot_2: f32,
    rot_3: f32,

    /// Convert SH DC to sRGB [0,255]
    /// DC coefficient: color = 0.5 + C0 * f_dc, where C0 = 0.28209479
    pub fn rgb(self: *const GaussianSplat) [3]u8 {
        const C0 = 0.28209479;
        const r = @min(@as(f32, 255.0), @max(0.0, (0.5 + C0 * self.f_dc_0) * 255.0));
        const g = @min(@as(f32, 255.0), @max(0.0, (0.5 + C0 * self.f_dc_1) * 255.0));
        const b = @min(@as(f32, 255.0), @max(0.0, (0.5 + C0 * self.f_dc_2) * 255.0));
        return .{ @intFromFloat(r), @intFromFloat(g), @intFromFloat(b) };
    }

    /// Sigmoid of opacity
    pub fn alpha(self: *const GaussianSplat) f32 {
        return 1.0 / (1.0 + @exp(-self.opacity));
    }

    /// Convert to simple Point for placement analysis
    pub fn toPoint(self: *const GaussianSplat) Point {
        const c = self.rgb();
        return .{
            .x = self.x,
            .y = self.y,
            .z = self.z,
            .r = c[0],
            .g = c[1],
            .b = c[2],
            .class = classifyByHeight(self.z),
        };
    }

    fn classifyByHeight(z: f32) Classification {
        if (z < 0.05) return .floor;
        if (z > 2.5) return .ceiling;
        return .wall;
    }

    /// Size of one splat in binary PLY (14 floats = 56 bytes)
    pub const binary_size = 14 * @sizeOf(f32);
};

/// Station trit assignment for placement zones
pub const StationTrit = enum(i2) {
    blue = -1, // chair, afferent, sieve
    horse = 0, // screen, crossover, shimmer
    red = 1, // pegboard, efferent, cosieve

    pub fn label(self: StationTrit) []const u8 {
        return switch (self) {
            .blue => "chair",
            .horse => "screen",
            .red => "pegboard",
        };
    }

    /// GF(3) conservation: blue + horse + red = -1 + 0 + 1 = 0
    pub fn conserved() bool {
        return true; // by construction
    }
};

/// Placement zone: a region in the point cloud suitable for a station object
pub const PlacementZone = struct {
    trit: StationTrit,
    center: [3]f32,
    normal: [3]f32,
    dimensions: [3]f32,
    score: f32,

    /// Distance between two zone centers
    pub fn distTo(self: *const PlacementZone, other: *const PlacementZone) f32 {
        const dx = self.center[0] - other.center[0];
        const dy = self.center[1] - other.center[1];
        const dz = self.center[2] - other.center[2];
        return @sqrt(dx * dx + dy * dy + dz * dz);
    }

    /// Encode as Syrup record for world:// state
    pub fn toSyrup(self: *const PlacementZone, alloc: Allocator) !syrup.Value {
        var fields = std.ArrayList(syrup.Value).init(alloc);
        try fields.append(syrup.Value{ .integer = @as(i64, @intFromEnum(self.trit)) });
        try fields.append(syrup.Value{ .float = @as(f64, self.center[0]) });
        try fields.append(syrup.Value{ .float = @as(f64, self.center[1]) });
        try fields.append(syrup.Value{ .float = @as(f64, self.center[2]) });
        try fields.append(syrup.Value{ .float = @as(f64, self.score) });
        return syrup.Value{ .record = .{
            .label = "placement-zone",
            .fields = try fields.toOwnedSlice(),
        } };
    }
};

/// Point cloud with spatial index and optional Gaussian splat data
pub const PointCloud = struct {
    points: std.ArrayList(Point),
    allocator: Allocator,

    /// Gaussian splat storage (populated by parseBinaryPLY)
    splats: std.ArrayList(GaussianSplat),

    pub fn init(alloc: Allocator) PointCloud {
        return .{
            .points = std.ArrayList(Point).init(alloc),
            .splats = std.ArrayList(GaussianSplat).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *PointCloud) void {
        self.points.deinit();
        self.splats.deinit();
    }

    /// Parse binary little-endian PLY (3D Gaussian Splat format from ml-sharp)
    /// Header: element vertex N, 14 float properties, then N * 56 bytes of data
    pub fn parseBinaryPLY(self: *PointCloud, data: []const u8) !void {
        var vertex_count: usize = 0;
        var header_end: usize = 0;

        // Parse header
        var offset: usize = 0;
        while (offset < data.len) {
            const nl = std.mem.indexOfScalar(u8, data[offset..], '\n') orelse break;
            const line = data[offset .. offset + nl];
            offset += nl + 1;

            if (std.mem.startsWith(u8, line, "element vertex ")) {
                vertex_count = try std.fmt.parseInt(usize, line["element vertex ".len..], 10);
            } else if (std.mem.eql(u8, line, "end_header")) {
                header_end = offset;
                break;
            }
        }

        if (header_end == 0 or vertex_count == 0) return error.InvalidPLY;

        const splat_data = data[header_end..];
        const expected = vertex_count * GaussianSplat.binary_size;
        if (splat_data.len < expected) return error.TruncatedPLY;

        try self.splats.ensureTotalCapacity(vertex_count);
        try self.points.ensureTotalCapacity(vertex_count);

        var i: usize = 0;
        while (i < vertex_count) : (i += 1) {
            const base = i * GaussianSplat.binary_size;
            const floats: *const [14]f32 = @ptrCast(@alignCast(splat_data[base..][0 .. 14 * 4]));

            const splat = GaussianSplat{
                .x = floats[0],
                .y = floats[1],
                .z = floats[2],
                .f_dc_0 = floats[3],
                .f_dc_1 = floats[4],
                .f_dc_2 = floats[5],
                .opacity = floats[6],
                .scale_0 = floats[7],
                .scale_1 = floats[8],
                .scale_2 = floats[9],
                .rot_0 = floats[10],
                .rot_1 = floats[11],
                .rot_2 = floats[12],
                .rot_3 = floats[13],
            };

            self.splats.appendAssumeCapacity(splat);
            self.points.appendAssumeCapacity(splat.toPoint());
        }
    }

    /// Parse ASCII PLY file
    pub fn parsePLYAscii(self: *PointCloud, data: []const u8) !void {
        var lines = std.mem.splitSequence(u8, data, "\n");
        var vertex_count: usize = 0;
        var in_header = true;

        while (lines.next()) |line| {
            if (in_header) {
                if (std.mem.startsWith(u8, line, "element vertex ")) {
                    vertex_count = try std.fmt.parseInt(usize, line["element vertex ".len..], 10);
                } else if (std.mem.eql(u8, line, "end_header")) {
                    in_header = false;
                }
                continue;
            }

            // Data line: x y z r g b
            var parts = std.mem.splitSequence(u8, line, " ");
            const x = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            const y = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            const z = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            const r = std.fmt.parseInt(u8, parts.next() orelse "128", 10) catch 128;
            const g = std.fmt.parseInt(u8, parts.next() orelse "128", 10) catch 128;
            const b = std.fmt.parseInt(u8, parts.next() orelse "128", 10) catch 128;

            try self.points.append(.{
                .x = x,
                .y = y,
                .z = z,
                .r = r,
                .g = g,
                .b = b,
                .class = classifyByHeight(z),
            });
        }
    }

    /// Height-based classification (refined by RoomPlan structured data)
    fn classifyByHeight(z: f32) Classification {
        if (z < 0.05) return .floor;
        if (z > 2.5) return .ceiling;
        return .wall;
    }

    /// Find wall segments suitable for screen/pegboard placement
    /// Returns centroids of wall clusters at eye height (1.1-1.4m)
    pub fn findWallSegments(self: *const PointCloud, alloc: Allocator) !std.ArrayList([3]f32) {
        var segments = std.ArrayList([3]f32).init(alloc);

        // Grid-based clustering: 0.5m cells
        const cell_size: f32 = 0.5;
        var grid = std.AutoHashMap([2]i32, struct { sum_x: f64, sum_y: f64, sum_z: f64, count: u32 }).init(alloc);
        defer grid.deinit();

        for (self.points.items) |p| {
            if (p.z < 1.1 or p.z > 1.4) continue; // eye height only
            if (p.class != .wall) continue;

            const gx: i32 = @intFromFloat(@floor(p.x / cell_size));
            const gy: i32 = @intFromFloat(@floor(p.y / cell_size));
            const key = [2]i32{ gx, gy };

            const entry = try grid.getOrPut(key);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .sum_x = 0, .sum_y = 0, .sum_z = 0, .count = 0 };
            }
            entry.value_ptr.sum_x += @as(f64, p.x);
            entry.value_ptr.sum_y += @as(f64, p.y);
            entry.value_ptr.sum_z += @as(f64, p.z);
            entry.value_ptr.count += 1;
        }

        // Clusters with enough points → wall segments
        var it = grid.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.count >= 50) { // minimum density
                const n: f64 = @floatFromInt(entry.value_ptr.count);
                try segments.append(.{
                    @floatCast(entry.value_ptr.sum_x / n),
                    @floatCast(entry.value_ptr.sum_y / n),
                    @floatCast(entry.value_ptr.sum_z / n),
                });
            }
        }

        return segments;
    }

    /// Compute placement zones for the GF(3) station triad
    pub fn computePlacement(self: *const PointCloud, alloc: Allocator) !struct { zones: [3]PlacementZone } {
        var walls = try self.findWallSegments(alloc);
        defer walls.deinit();

        // Best wall → screen (trit 0)
        // TODO: score by window proximity, width, etc.
        const screen_center = if (walls.items.len > 0)
            walls.items[0]
        else
            [3]f32{ 1.5, 3.5, 1.25 }; // fallback: synthetic room center

        // Pegboard: 0.5m right of screen, same wall
        const pegboard_center = [3]f32{
            screen_center[0] + 0.5,
            screen_center[1],
            screen_center[2] - 0.25,
        };

        // Chair: 0.8m in front of screen (towards room center)
        const chair_center = [3]f32{
            screen_center[0],
            screen_center[1] - 0.8,
            0.0,
        };

        return .{ .zones = .{
            .{ .trit = .blue, .center = chair_center, .normal = .{ 0, 0, 1 }, .dimensions = .{ 0.7, 0.5, 0.7 }, .score = 0.8 },
            .{ .trit = .horse, .center = screen_center, .normal = .{ 0, -1, 0 }, .dimensions = .{ 0.6, 0.4, 0.05 }, .score = 0.9 },
            .{ .trit = .red, .center = pegboard_center, .normal = .{ 0, -1, 0 }, .dimensions = .{ 0.4, 0.6, 0.1 }, .score = 0.85 },
        } };
    }

    /// Bounding box
    pub fn bounds(self: *const PointCloud) struct { min: [3]f32, max: [3]f32 } {
        var mn = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var mx = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

        for (self.points.items) |p| {
            mn[0] = @min(mn[0], p.x);
            mn[1] = @min(mn[1], p.y);
            mn[2] = @min(mn[2], p.z);
            mx[0] = @max(mx[0], p.x);
            mx[1] = @max(mx[1], p.y);
            mx[2] = @max(mx[2], p.z);
        }

        return .{ .min = mn, .max = mx };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse PLY" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 3
        \\property float x
        \\property float y
        \\property float z
        \\property uchar red
        \\property uchar green
        \\property uchar blue
        \\end_header
        \\1.0 2.0 0.0 255 0 0
        \\1.5 2.0 1.2 0 255 0
        \\1.0 2.0 2.8 0 0 255
    ;

    var cloud = PointCloud.init(std.testing.allocator);
    defer cloud.deinit();

    try cloud.parsePLYAscii(ply);
    try std.testing.expectEqual(cloud.points.items.len, 3);
    try std.testing.expectEqual(cloud.points.items[0].class, .floor);
    try std.testing.expectEqual(cloud.points.items[1].class, .wall);
    try std.testing.expectEqual(cloud.points.items[2].class, .ceiling);
}

test "GF(3) station conservation" {
    // The triad always conserves: -1 + 0 + 1 = 0
    try std.testing.expect(StationTrit.conserved());

    const sum: i8 = @as(i8, @intFromEnum(StationTrit.blue)) +
        @as(i8, @intFromEnum(StationTrit.horse)) +
        @as(i8, @intFromEnum(StationTrit.red));
    try std.testing.expectEqual(@mod(sum, 3), 0);
}

test "placement zone distance" {
    const a = PlacementZone{
        .trit = .blue,
        .center = .{ 0, 0, 0 },
        .normal = .{ 0, 0, 1 },
        .dimensions = .{ 1, 1, 1 },
        .score = 1.0,
    };
    const b = PlacementZone{
        .trit = .horse,
        .center = .{ 3, 4, 0 },
        .normal = .{ 0, -1, 0 },
        .dimensions = .{ 1, 1, 1 },
        .score = 1.0,
    };
    try std.testing.expectApproxEqAbs(a.distTo(&b), 5.0, 0.001);
}
