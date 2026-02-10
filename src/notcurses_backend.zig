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

    pub fn init() !NotcursesBackend {
        var opts: c.notcurses_options = std.mem.zeroes(c.notcurses_options);
        opts.flags = c.NCOPTION_NO_ALTERNATE_SCREEN | c.NCOPTION_SUPPRESS_BANNERS;
        
        const nc_ctx = c.notcurses_init(&opts, null) orelse return error.NotcursesInitFailed;
        const std_plane = c.notcurses_stdplane(nc_ctx) orelse return error.NotcursesPlaneFailed;

        var dimy: c_uint = 0;
        var dimx: c_uint = 0;
        c.ncplane_dim_yx(std_plane, &dimy, &dimx);

        return NotcursesBackend{
            .nc = nc_ctx,
            .plane = std_plane,
            .width = @intCast(dimx),
            .height = @intCast(dimy),
        };
    }

    pub fn deinit(self: *NotcursesBackend) void {
        _ = c.notcurses_stop(self.nc);
    }

    pub fn draw(self: *NotcursesBackend, buffer: *const retty.Buffer) void {
        // Resize check
        var dimy: c_uint = 0;
        var dimx: c_uint = 0;
        c.ncplane_dim_yx(self.plane, &dimy, &dimx);
        self.width = @intCast(dimx);
        self.height = @intCast(dimy);

        // Iterate and draw
        var y: u16 = buffer.area.y;
        while (y < buffer.area.bottom()) : (y += 1) {
            var x: u16 = buffer.area.x;
            while (x < buffer.area.right()) : (x += 1) {
                // Skip if out of bounds (shouldn't happen with correct resizing)
                if (x >= self.width or y >= self.height) continue;

                const cell = buffer.get(x, y);
                var ncc: c.nccell = std.mem.zeroes(c.nccell);
                
                // Set char (UTF-8)
                // Zig's u21 codepoint to char string
                var buf: [4]u8 = undefined;
                _ = std.unicode.utf8Encode(cell.codepoint, &buf) catch 1;
                // nccell_load requires c_char pointer
                _ = c.nccell_load(self.plane, &ncc, @ptrCast(&buf[0]));

                // Set colors
                const fg = cell.fg.toRgb24();
                const bg = cell.bg.toRgb24();
                
                _ = c.ncchannels_set_fg_rgb(&ncc.channels, fg);
                _ = c.ncchannels_set_bg_rgb(&ncc.channels, bg);
                
                // Set attributes
                var styles: u64 = 0;
                if (cell.attrs.bold) styles |= c.NCSTYLE_BOLD;
                if (cell.attrs.italic) styles |= c.NCSTYLE_ITALIC;
                if (cell.attrs.underline) styles |= c.NCSTYLE_UNDERLINE;
                ncc.stylemask = @intCast(styles);

                _ = c.ncplane_putc_yx(self.plane, @intCast(y), @intCast(x), &ncc);
                c.nccell_release(self.plane, &ncc);
            }
        }
        _ = c.notcurses_render(self.nc);
    }
    
    // Output method to satisfy interface if needed, or we just call draw()
    pub fn output(self: *NotcursesBackend) []const u8 {
        _ = self;
        return "";
    }
};
