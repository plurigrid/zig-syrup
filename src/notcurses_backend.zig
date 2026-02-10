const std = @import("std");
const retty = @import("retty");

const c = @cImport({
    @cInclude("notcurses/notcurses.h");
});

pub const NotcursesBackend = struct {
    nc: *c.notcurses,
    plane: *c.ncplane,
    width: u16,
    height: u16,
    /// Previous frame cell hashes for damage-based skip (O(1) per cell)
    prev_frame: ?[]u64,
    allocator: ?std.mem.Allocator,
    /// Frame counter for stats
    frame_count: u64,
    /// Cells actually written (not skipped) in last frame
    cells_written: u32,
    /// Terminal capabilities detected at init
    caps: Capabilities,

    pub const Capabilities = struct {
        /// True 24-bit RGB support
        truecolor: bool = false,
        /// Pixel graphics (Kitty/Sixel/LinuxFB)
        pixel: bool = false,
        /// UTF-8 support
        utf8: bool = false,
        /// Half-block blitting (▀▄)
        halfblock: bool = false,
        /// Quadrant blitting (▖▗▘▝)
        quadrant: bool = false,
        /// Braille blitting (⠿)
        braille: bool = false,
        /// Sextant blitting
        sextant: bool = false,
    };

    pub fn init() !NotcursesBackend {
        return initWithAllocator(null);
    }

    pub fn initWithAllocator(allocator: ?std.mem.Allocator) !NotcursesBackend {
        var opts: c.notcurses_options = std.mem.zeroes(c.notcurses_options);
        opts.flags = c.NCOPTION_NO_ALTERNATE_SCREEN | c.NCOPTION_SUPPRESS_BANNERS;

        const nc_ctx = c.notcurses_init(&opts, null) orelse return error.NotcursesInitFailed;
        const std_plane = c.notcurses_stdplane(nc_ctx) orelse return error.NotcursesPlaneFailed;

        var dimy: c_uint = 0;
        var dimx: c_uint = 0;
        c.ncplane_dim_yx(std_plane, &dimy, &dimx);

        // Detect capabilities
        var caps = Capabilities{};
        const nc_caps = c.notcurses_capabilities(nc_ctx);
        if (nc_caps != null) {
            caps.truecolor = nc_caps.*.rgb;
            caps.utf8 = nc_caps.*.utf8;
            caps.halfblock = nc_caps.*.halfblocks;
            caps.quadrant = nc_caps.*.quadrants;
            caps.braille = nc_caps.*.braille;
            caps.sextant = nc_caps.*.sextants;
        }
        // Pixel support: check if any pixel blitter is available
        caps.pixel = c.notcurses_check_pixel_support(nc_ctx) > 0;

        // Allocate previous frame buffer for damage-skip rendering
        var prev_frame: ?[]u64 = null;
        if (allocator) |alloc| {
            const size = @as(usize, dimx) * dimy;
            if (size > 0) {
                prev_frame = try alloc.alloc(u64, size);
                @memset(prev_frame.?, 0);
            }
        }

        return NotcursesBackend{
            .nc = nc_ctx,
            .plane = std_plane,
            .width = @intCast(dimx),
            .height = @intCast(dimy),
            .prev_frame = prev_frame,
            .allocator = allocator,
            .frame_count = 0,
            .cells_written = 0,
            .caps = caps,
        };
    }

    pub fn deinit(self: *NotcursesBackend) void {
        if (self.prev_frame) |pf| {
            if (self.allocator) |alloc| {
                alloc.free(pf);
            }
        }
        _ = c.notcurses_stop(self.nc);
    }

    /// Hash a retty cell for damage comparison (FNV-1a inspired, no alloc)
    inline fn cellHash(cell: retty.Cell) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h ^= @as(u64, cell.codepoint);
        h *%= 0x100000001b3;
        h ^= @as(u64, cell.fg.toRgb24());
        h *%= 0x100000001b3;
        h ^= @as(u64, cell.bg.toRgb24());
        h *%= 0x100000001b3;
        h ^= @as(u64, @as(u8, @bitCast(cell.attrs)));
        h *%= 0x100000001b3;
        return h;
    }

    /// Damage-aware draw: only writes cells that changed since last frame.
    /// Notcurses itself does rendered-mode diffing, but pre-skipping at the
    /// retty→notcurses boundary avoids nccell_load + putc overhead entirely.
    pub fn draw(self: *NotcursesBackend, buffer: *const retty.Buffer) void {
        // Resize check
        var dimy: c_uint = 0;
        var dimx: c_uint = 0;
        c.ncplane_dim_yx(self.plane, &dimy, &dimx);

        // Handle resize: invalidate prev_frame
        if (@as(u16, @intCast(dimx)) != self.width or @as(u16, @intCast(dimy)) != self.height) {
            self.width = @intCast(dimx);
            self.height = @intCast(dimy);
            // Reallocate prev_frame on resize
            if (self.allocator) |alloc| {
                if (self.prev_frame) |pf| alloc.free(pf);
                const size = @as(usize, dimx) * dimy;
                self.prev_frame = alloc.alloc(u64, size) catch null;
                if (self.prev_frame) |pf| @memset(pf, 0);
            }
        }

        var written: u32 = 0;

        // Iterate and draw
        var y: u16 = buffer.area.y;
        while (y < buffer.area.bottom()) : (y += 1) {
            var x: u16 = buffer.area.x;
            while (x < buffer.area.right()) : (x += 1) {
                if (x >= self.width or y >= self.height) continue;

                const cell = buffer.get(x, y);

                // Damage skip: compare hash with previous frame
                if (self.prev_frame) |pf| {
                    const idx = @as(usize, y) * self.width + x;
                    if (idx < pf.len) {
                        const h = cellHash(cell);
                        if (pf[idx] == h) continue; // Skip — cell unchanged
                        pf[idx] = h;
                    }
                }

                var ncc: c.nccell = std.mem.zeroes(c.nccell);

                var buf: [4]u8 = undefined;
                _ = std.unicode.utf8Encode(cell.codepoint, &buf) catch 1;
                _ = c.nccell_load(self.plane, &ncc, @ptrCast(&buf[0]));

                const fg = cell.fg.toRgb24();
                const bg = cell.bg.toRgb24();

                _ = c.ncchannels_set_fg_rgb(&ncc.channels, fg);
                _ = c.ncchannels_set_bg_rgb(&ncc.channels, bg);

                var styles: u64 = 0;
                if (cell.attrs.bold) styles |= c.NCSTYLE_BOLD;
                if (cell.attrs.italic) styles |= c.NCSTYLE_ITALIC;
                if (cell.attrs.underline) styles |= c.NCSTYLE_UNDERLINE;
                ncc.stylemask = @intCast(styles);

                _ = c.ncplane_putc_yx(self.plane, @intCast(y), @intCast(x), &ncc);
                c.nccell_release(self.plane, &ncc);
                written += 1;
            }
        }
        _ = c.notcurses_render(self.nc);
        self.cells_written = written;
        self.frame_count += 1;
    }

    /// Fade the standard plane out over duration_ms (cinematic transitions)
    pub fn fadeOut(self: *NotcursesBackend, duration_ms: u32) void {
        const ts = c.struct_timespec{
            .tv_sec = @intCast(duration_ms / 1000),
            .tv_nsec = @intCast((@as(i64, duration_ms % 1000)) * 1_000_000),
        };
        _ = c.ncplane_fadeout(self.plane, &ts, null, null);
    }

    /// Fade the standard plane in over duration_ms
    pub fn fadeIn(self: *NotcursesBackend, duration_ms: u32) void {
        const ts = c.struct_timespec{
            .tv_sec = @intCast(duration_ms / 1000),
            .tv_nsec = @intCast((@as(i64, duration_ms % 1000)) * 1_000_000),
        };
        _ = c.ncplane_fadein(self.plane, &ts, null, null);
    }

    /// Get render efficiency (0.0 = all skipped, 1.0 = all written)
    pub fn efficiency(self: *const NotcursesBackend) f32 {
        const total = @as(u32, self.width) * self.height;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.cells_written)) / @as(f32, @floatFromInt(total));
    }
    
    /// Non-blocking input. Returns null if no event within timeout_ms.
    pub const InputEvent = struct {
        id: u32, // Unicode codepoint or special key
        evtype: EventType,
        modifiers: Modifiers,

        pub const EventType = enum { unknown, press, repeat, release };
        pub const Modifiers = packed struct(u8) {
            shift: bool = false,
            alt: bool = false,
            ctrl: bool = false,
            _pad: u5 = 0,
        };

        // Special keys (from notcurses NCKEY_* range)
        pub const RESIZE: u32 = 0x04000000 + 0x19; // NCKEY_RESIZE
        pub const ENTER: u32 = 0x04000000 + 0x04;
        pub const BACKSPACE: u32 = 0x04000000 + 0x17;
        pub const ESCAPE: u32 = 0x04000000 + 0x01;
        pub const UP: u32 = 0x04000000 + 0x41;
        pub const DOWN: u32 = 0x04000000 + 0x42;
        pub const F1: u32 = 0x04000000 + 0x6f;
    };

    pub fn getInput(self: *NotcursesBackend, timeout_ms: u32) ?InputEvent {
        var ni: c.ncinput = std.mem.zeroes(c.ncinput);
        const ts = c.struct_timespec{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_nsec = @intCast((@as(i64, timeout_ms % 1000)) * 1_000_000),
        };
        const id = c.notcurses_get(self.nc, &ts, &ni);
        if (id == 0) return null; // timeout

        return InputEvent{
            .id = @intCast(id),
            .evtype = switch (ni.evtype) {
                1 => .press,
                2 => .repeat,
                3 => .release,
                else => .unknown,
            },
            .modifiers = .{
                .shift = ni.shift,
                .alt = ni.alt,
                .ctrl = ni.ctrl,
            },
        };
    }

    // Output method to satisfy interface if needed, or we just call draw()
    pub fn output(self: *NotcursesBackend) []const u8 {
        _ = self;
        return "";
    }
};
