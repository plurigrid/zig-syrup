//! witnessing_worm_cli.zig — Terminal runner for the C. elegans witnessing protocol
//!
//! Runs perpetual witnessing epochs and renders the connectome state as
//! ANSI-colored output. Each neuron is a colored block showing its
//! oppositional state: warm (forward), cool (backward), green (resymmetrized).
//!
//! Usage: zig build witness-worm && ./zig-out/bin/witness-worm [seed] [epochs]
//!
//! The worm swims through water. The water carries color.

const std = @import("std");
const worm = @import("witnessing_worm");

const posix = std.posix;

fn writeAll(bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        total += posix.write(posix.STDOUT_FILENO, bytes[total..]) catch return;
    }
}

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(buf, fmt, args) catch return;
    writeAll(slice);
}

pub fn main() !void {
    var gpa = if (@hasDecl(std.heap, "GeneralPurposeAllocator")) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const seed: u64 = if (args.len > 1) std.fmt.parseInt(u64, args[1], 10) catch 1069 else 1069;
    const n_epochs: u32 = if (args.len > 2) std.fmt.parseInt(u32, args[2], 10) catch 8 else 8;
    const steps_per_epoch: u32 = if (args.len > 3) std.fmt.parseInt(u32, args[3], 10) catch 50 else 50;

    var pw = try worm.PerpetualWitness.init(allocator, seed);
    defer pw.deinit();

    var buf: [4096]u8 = undefined;

    // Header
    writeAll("\x1b[2J\x1b[H"); // clear screen
    print(&buf, "\x1b[1;97m╔══════════════════════════════════════════════╗\x1b[0m\n", .{});
    print(&buf, "\x1b[1;97m║  C. elegans Witnessing Protocol  seed={d:<5} ║\x1b[0m\n", .{seed});
    print(&buf, "\x1b[1;97m╚══════════════════════════════════════════════╝\x1b[0m\n\n", .{});

    // Neuron layout: 4 rows matching the circuit layers
    const sensory_head = [_]u8{ 0, 1, 2, 3 };
    const command = [_]u8{ 4, 5, 6, 7, 8 };
    const inter = [_]u8{ 9, 10, 11, 12, 13, 14 };
    const motor_d = [_]u8{ 15, 16, 17, 18, 19, 20, 21, 22 };
    const motor_v = [_]u8{ 23, 24, 25, 26, 27, 28, 29, 30 };
    const sensory_tail = [_]u8{31};

    const layers = [_]struct { name: []const u8, indices: []const u8 }{
        .{ .name = "SENSORY HEAD", .indices = &sensory_head },
        .{ .name = "COMMAND     ", .indices = &command },
        .{ .name = "INTERNEURON ", .indices = &inter },
        .{ .name = "MOTOR DORSAL", .indices = &motor_d },
        .{ .name = "MOTOR VENTR ", .indices = &motor_v },
        .{ .name = "SENSORY TAIL", .indices = &sensory_tail },
    };

    var epoch: u32 = 0;
    while (epoch < n_epochs) : (epoch += 1) {
        const result = pw.witnessEpoch(steps_per_epoch);

        // Get color snapshot
        var rgba: [32 * 4]u8 = undefined;
        pw.snapshot(&rgba);

        // Render epoch header
        print(&buf, "\x1b[1;93m── Epoch {d} ──\x1b[0m", .{result.epoch});
        if (result.in_dissipative_regime) {
            writeAll("  \x1b[1;31m⚡ DISSIPATIVE\x1b[0m");
        }
        writeAll("\n");

        // Render each layer
        for (layers) |layer| {
            print(&buf, "  \x1b[90m{s}\x1b[0m ", .{layer.name});
            for (layer.indices) |idx| {
                const r = rgba[idx * 4];
                const g = rgba[idx * 4 + 1];
                const b = rgba[idx * 4 + 2];
                const neuron = pw.connectome.neurons[idx];

                // ANSI 24-bit color block + neuron name
                print(&buf, "\x1b[48;2;{d};{d};{d}m\x1b[38;2;255;255;255m {s} \x1b[0m", .{ r, g, b, neuron.name });
            }

            // Oppositional indicators for this layer
            writeAll(" ");
            for (layer.indices) |idx| {
                const neuron = pw.connectome.neurons[idx];
                const trit_char: []const u8 = switch (neuron.oppositional) {
                    .plus => "\x1b[91m+\x1b[0m",
                    .minus => "\x1b[94m-\x1b[0m",
                    .zero => "\x1b[92m○\x1b[0m",
                };
                writeAll(trit_char);
            }
            writeAll("\n");
        }

        // Stats
        print(&buf, "  \x1b[90mΣopp={d:>3}  resym={d:>2}  steps={d:>2}  crossmax={d}  witnessed={}\x1b[0m\n", .{
            result.witness.oppositional_sum,
            result.witness.resymmetrized_count,
            result.witness.steps,
            result.witness.max_crossing_depth,
            result.witness.fully_witnessed,
        });

        if (result.witness.isResymmetrized()) {
            writeAll("  \x1b[1;92m✓ RESYMMETRIZED — oppositional sum = 0, fully witnessed\x1b[0m\n");
        }

        writeAll("\n");

        // Reset wavefronts for next epoch (keep accumulated state)
        pw.resetWavefronts();
    }

    // Final summary
    writeAll("\x1b[1;97m═══════════════════════════════════════════════\x1b[0m\n");
    print(&buf, "\x1b[1;97m  {d} epochs │ {d} total resymmetrizations\x1b[0m\n", .{
        pw.epochs_completed,
        pw.total_resymmetrizations,
    });
    print(&buf, "\x1b[1;97m  final Σopp = {d}  │ dissipative = {}\x1b[0m\n", .{
        pw.oppositionalSum(),
        pw.in_dissipative_regime,
    });
    writeAll("\x1b[1;97m═══════════════════════════════════════════════\x1b[0m\n");
}
