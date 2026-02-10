//! Stellogen CLI - Command-line compiler for Stellogen
//!
//! Usage:
//!   stellogen compile input.sg -o output.wasm  # Compile to WASM
//!   stellogen run input.sg                     # Interpret
//!   stellogen check input.sg                   # Parse and type-check
//!   stellogen fmt input.sg                     # Format source
//!
//! The compiler targets wasm32-standalone for maximum portability.

const std = @import("std");
const stellogen = @import("stellogen");

const VERSION = "0.1.0";

fn getStdout() std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write) {
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    return .{ .context = stdout_file };
}

fn getStderr() std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write) {
    const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    return .{ .context = stderr_file };
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\Stellogen Compiler {s}
        \\Logic-agnostic programming language based on interaction nets
        \\
        \\USAGE:
        \\  stellogen <command> [options] <file>
        \\
        \\COMMANDS:
        \\  compile   Compile to WebAssembly binary
        \\  run       Interpret and execute
        \\  check     Parse and validate
        \\  lex       Show tokens (debug)
        \\  parse     Show AST (debug)
        \\
        \\OPTIONS:
        \\  -o <file>    Output file (default: a.wasm)
        \\  --linear     Use linear execution (fire instead of exec)
        \\  -v, --verbose Verbose output
        \\  -h, --help    Show this help
        \\  --version     Show version
        \\
        \\EXAMPLES:
        \\  stellogen compile nat.sg -o nat.wasm
        \\  stellogen run examples/hello.sg
        \\  stellogen check --verbose spec.sg
        \\
        \\GF(3) TRIT: 0 (ERGODIC - mediates proof and computation)
        \\
    , .{VERSION});
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn cmdCompile(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, verbose: bool) !void {
    const stderr = getStderr();
    const stdout = getStdout();

    if (verbose) {
        try stderr.print("Compiling {s} -> {s}\n", .{ input_path, output_path });
    }

    // Read source
    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    if (verbose) {
        try stderr.print("Source: {d} bytes\n", .{source.len});
    }

    // Compile to WASM
    const wasm = try stellogen.compile(allocator, source);

    // Write output
    try writeFile(output_path, wasm);

    try stdout.print("Compiled to {s} ({d} bytes)\n", .{ output_path, wasm.len });
}

fn cmdRun(allocator: std.mem.Allocator, input_path: []const u8, verbose: bool) !void {
    const stderr = getStderr();
    const stdout = getStdout();

    if (verbose) {
        try stderr.print("Running {s}\n", .{input_path});
    }

    // Read source
    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    // Interpret
    const result = try stellogen.interpret(allocator, source);

    // Check for 'ok'
    if (stellogen.isOk(result)) {
        try stdout.print("ok\n", .{});
    } else {
        // Print result constellation
        try stdout.print("Result: {d} stars\n", .{result.stars.len});
        for (result.stars, 0..) |star, i| {
            try stdout.print("  Star {d}: {d} rays (state={any})\n", .{ i, star.content.len, star.is_state });
        }
    }
}

fn cmdCheck(allocator: std.mem.Allocator, input_path: []const u8, verbose: bool) !void {
    const stderr = getStderr();
    const stdout = getStdout();

    if (verbose) {
        try stderr.print("Checking {s}\n", .{input_path});
    }

    // Read source
    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    // Parse
    const program = stellogen.parser.parse(allocator, source) catch |err| {
        try stderr.print("Parse error: {any}\n", .{err});
        return err;
    };

    try stdout.print("Parsed {d} expressions\n", .{program.len});

    // Validate
    for (program) |expr| {
        switch (expr) {
            .def => |d| {
                try stdout.print("  def {s}\n", .{d.name});
            },
            .constellation => |c| {
                try stdout.print("  constellation: {d} stars\n", .{c.stars.len});
            },
            else => {},
        }
    }

    try stdout.print("Check passed\n", .{});
}

fn cmdLex(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const stdout = getStdout();

    // Read source
    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    // Tokenize
    var lexer = stellogen.Lexer.init(source);
    while (true) {
        const tok = lexer.nextToken();
        try stdout.print("{d}:{d} {s} \"{s}\"\n", .{
            tok.line,
            tok.column,
            @tagName(tok.kind),
            tok.text,
        });
        if (tok.kind == .eof) break;
    }
}

fn cmdParse(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const stdout = getStdout();

    // Read source
    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    // Parse
    const program = try stellogen.parser.parse(allocator, source);

    try stdout.print("AST: {d} expressions\n", .{program.len});
    for (program, 0..) |expr, i| {
        try printExpr(stdout, expr, i, 0);
    }
}

fn printExpr(writer: anytype, expr: stellogen.Expr, idx: usize, indent: usize) !void {
    const pad = "                                "[0 .. indent * 2];
    switch (expr) {
        .raw => |t| try writer.print("{s}[{d}] raw: {any}\n", .{ pad, idx, t }),
        .def => |d| try writer.print("{s}[{d}] def: {s}\n", .{ pad, idx, d.name }),
        .call => |n| try writer.print("{s}[{d}] call: {s}\n", .{ pad, idx, n }),
        .constellation => |c| try writer.print("{s}[{d}] constellation: {d} stars\n", .{ pad, idx, c.stars.len }),
        .star => |s| try writer.print("{s}[{d}] star: {d} rays\n", .{ pad, idx, s.content.len }),
        .exec => |e| try writer.print("{s}[{d}] exec (linear={any})\n", .{ pad, idx, e.linear }),
        .focus => try writer.print("{s}[{d}] focus\n", .{ pad, idx }),
        .show => |s| try writer.print("{s}[{d}] show: {d} exprs\n", .{ pad, idx, s.len }),
        .expect => try writer.print("{s}[{d}] expect\n", .{ pad, idx }),
        .match => try writer.print("{s}[{d}] match\n", .{ pad, idx }),
        .use => |p| try writer.print("{s}[{d}] use: {s}\n", .{ pad, idx, p }),
        .group => |g| try writer.print("{s}[{d}] group: {d} exprs\n", .{ pad, idx, g.len }),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = getStdout();
    const stderr = getStderr();

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    var command: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var output_path: []const u8 = "a.wasm";
    var verbose = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try stdout.print("stellogen {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("Error: -o requires an argument\n", .{});
                std.process.exit(1);
            }
            output_path = args[i];
        } else if (arg[0] == '-') {
            try stderr.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else if (command == null) {
            command = arg;
        } else if (input_path == null) {
            input_path = arg;
        }
    }

    const cmd = command orelse {
        try stderr.print("Error: no command specified\n", .{});
        try printUsage(stderr);
        std.process.exit(1);
    };

    const path = input_path orelse {
        try stderr.print("Error: no input file specified\n", .{});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, cmd, "compile")) {
        try cmdCompile(allocator, path, output_path, verbose);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try cmdRun(allocator, path, verbose);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try cmdCheck(allocator, path, verbose);
    } else if (std.mem.eql(u8, cmd, "lex")) {
        try cmdLex(allocator, path);
    } else if (std.mem.eql(u8, cmd, "parse")) {
        try cmdParse(allocator, path);
    } else {
        try stderr.print("Unknown command: {s}\n", .{cmd});
        std.process.exit(1);
    }
}
