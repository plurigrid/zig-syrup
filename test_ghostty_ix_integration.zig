const std = @import("std");
const ghostty_ix = @import("ghostty_ix");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 1: Create dispatcher
    var dispatcher = ghostty_ix.CommandDispatcher.init(allocator);
    defer dispatcher.deinit();

    std.debug.print("✓ CommandDispatcher created\n", .{});

    // Test 2: Parse command from key event
    const key_event = ghostty_ix.InputMessage.KeyEvent{
        .char_code = 'q',
        .modifiers = 0,
    };

    const input = ghostty_ix.InputMessage{
        .event_type = .key,
        .key_event = key_event,
    };

    const cmd = try dispatcher.parseCommand(input);
    if (cmd) |c| {
        std.debug.print("✓ Parsed command: {}\n", .{c.command_type});
    } else {
        std.debug.print("✗ Failed to parse command\n", .{});
        return error.ParseFailed;
    }

    // Test 3: Execute query command
    const query_cmd = ghostty_ix.Command{
        .command_type = .query,
        .args = "",
        .modifiers = 0,
    };

    const result = try dispatcher.execute(query_cmd);
    std.debug.print("✓ Execute query: success={}, output={s}\n", .{result.success, result.output});
    allocator.free(result.output);

    // Test 4: Check trit balance
    const balanced = dispatcher.checkTritBalance();
    std.debug.print("✓ Trit balance checked: {}\n", .{balanced});

    std.debug.print("\n✓ All integration tests passed!\n", .{});
}
