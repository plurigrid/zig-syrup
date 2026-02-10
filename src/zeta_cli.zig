const std = @import("std");
const retty = @import("retty");
const worlds = @import("worlds");
const ZetaWorld = worlds.zeta.ZetaWorld;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize world with N=15 nodes
    var world = try ZetaWorld.init(allocator, 15);
    defer world.deinit();

    // Initialize UI
    // Default to 80x24 if we can't detect size
    const width: u16 = 80;
    const height: u16 = 24;

    // Allocate buffer on heap to avoid stack overflow (Buffer is large)
    const buffer = try allocator.create(retty.Buffer);
    buffer.* = retty.Buffer.init(retty.Rect{ .width = width, .height = height });
    defer allocator.destroy(buffer);

    var backend = retty.AnsiBackend.init(width, height);

    // Main loop
    var tick: u64 = 0;
    while (true) : (tick += 1) {
        // Update world
        try world.tick();

        // Render UI
        buffer.* = retty.Buffer.init(retty.Rect{ .width = width, .height = height });
        
        const area = buffer.area;
        world.render(buffer, area);

        // Draw to backend
        backend.reset();
        if (tick == 0) backend.clear(); // Clear screen on first frame
        backend.draw(buffer); 

        // Output to terminal
        _ = try std.posix.write(std.posix.STDOUT_FILENO, backend.output());

        // Sleep 100ms
        // const ts = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
        // std.posix.nanosleep(&ts, null);

        // Just run for 100 ticks then exit for this demo/test to avoid infinite loop
        // In a real TUI this would wait for input
        if (tick >= 100) break;
    }
}
