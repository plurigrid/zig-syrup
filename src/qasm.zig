//! Quantum Circuit ASCII Art Renderer
//!
//! Renders QASM-style quantum circuit diagrams into terminal cells
//! via CellSync for distributed visualization.
//!
//! Wire format follows Qiskit/Cirq ASCII conventions:
//!   q0: ──┤H├──●──┌M┐
//!              │
//!   q1: ──────⊕──┌M┐
//!
//! Colors use the GF(3) trit mapping from spectrum.zig:
//!   +1 (generation/warm) = qubit |1⟩
//!    0 (neutral)         = superposition
//!   -1 (verification/cool) = qubit |0⟩

const std = @import("std");
const cell_sync = @import("cell_sync.zig");

const CellSync = cell_sync.CellSync;
const Cell = @import("damage.zig").Cell;

/// Gate symbols for ASCII rendering
pub const WIRE: u21 = '─';
pub const WIRE_VERT: u21 = '│';
pub const CONTROL: u21 = '●';
pub const TARGET: u21 = '⊕';
pub const MEASURE_TOP: u21 = '┌';
pub const MEASURE_BOT: u21 = '└';
pub const BOX_TL: u21 = '┤';
pub const BOX_TR: u21 = '├';

/// GF(3) trit colors for quantum state visualization
pub const COLOR_ONE: u24 = 0xFF6B35; // warm orange — |1⟩
pub const COLOR_SUPER: u24 = 0xA0A0A0; // neutral gray — superposition
pub const COLOR_ZERO: u24 = 0x3B82F6; // cool blue — |0⟩
pub const COLOR_WIRE: u24 = 0x666666; // dim wire
pub const COLOR_GATE: u24 = 0xFFD700; // gold gate label

/// Render a single qubit wire into cells
pub fn renderWire(sync: *CellSync, qubit: u16, start_col: u16, end_col: u16) void {
    const row = qubit * 2;
    var col = start_col;
    while (col < end_col) : (col += 1) {
        sync.writeCell(col, row, .{
            .codepoint = WIRE,
            .fg = COLOR_WIRE,
            .bg = 0x000000,
        });
    }
}

/// Render a single-qubit gate (H, X, Z, S, T, etc.)
pub fn renderGate(sync: *CellSync, qubit: u16, col: u16, label: u21) void {
    const row = qubit * 2;
    sync.writeCell(col, row, .{
        .codepoint = BOX_TL,
        .fg = COLOR_GATE,
        .bg = 0x000000,
    });
    sync.writeCell(col + 1, row, .{
        .codepoint = label,
        .fg = COLOR_GATE,
        .bg = 0x1a1a2e,
        .attrs = .{ .bold = true },
    });
    sync.writeCell(col + 2, row, .{
        .codepoint = BOX_TR,
        .fg = COLOR_GATE,
        .bg = 0x000000,
    });
}

/// Render a CNOT (control + target on different qubits)
pub fn renderCnot(sync: *CellSync, control: u16, target: u16, col: u16) void {
    const ctrl_row = control * 2;
    const tgt_row = target * 2;
    sync.writeCell(col + 1, ctrl_row, .{
        .codepoint = CONTROL,
        .fg = COLOR_ONE,
        .bg = 0x000000,
    });
    sync.writeCell(col + 1, tgt_row, .{
        .codepoint = TARGET,
        .fg = COLOR_ZERO,
        .bg = 0x000000,
    });
    const min_row = @min(ctrl_row, tgt_row) + 1;
    const max_row = @max(ctrl_row, tgt_row);
    var r = min_row;
    while (r < max_row) : (r += 1) {
        sync.writeCell(col + 1, r, .{
            .codepoint = WIRE_VERT,
            .fg = COLOR_WIRE,
            .bg = 0x000000,
        });
    }
}

/// Render measurement symbol
pub fn renderMeasure(sync: *CellSync, qubit: u16, col: u16) void {
    const row = qubit * 2;
    sync.writeCell(col, row, .{
        .codepoint = MEASURE_TOP,
        .fg = COLOR_SUPER,
        .bg = 0x000000,
    });
    sync.writeCell(col + 1, row, .{
        .codepoint = 'M',
        .fg = COLOR_SUPER,
        .bg = 0x1a1a2e,
        .attrs = .{ .bold = true },
    });
    sync.writeCell(col + 2, row, .{
        .codepoint = MEASURE_BOT,
        .fg = COLOR_SUPER,
        .bg = 0x000000,
    });
}

/// Render a Bell state circuit: H on q0, CNOT q0→q1, measure both
pub fn renderBellCircuit(sync: *CellSync, start_col: u16) void {
    renderWire(sync, 0, start_col, start_col + 20);
    renderWire(sync, 1, start_col, start_col + 20);

    sync.writeCell(start_col, 0, .{ .codepoint = 'q', .fg = COLOR_ZERO });
    sync.writeCell(start_col + 1, 0, .{ .codepoint = '0', .fg = COLOR_ZERO });
    sync.writeCell(start_col, 2, .{ .codepoint = 'q', .fg = COLOR_ONE });
    sync.writeCell(start_col + 1, 2, .{ .codepoint = '1', .fg = COLOR_ONE });

    renderGate(sync, 0, start_col + 4, 'H');
    renderCnot(sync, 0, 1, start_col + 9);
    renderMeasure(sync, 0, start_col + 14);
    renderMeasure(sync, 1, start_col + 14);
}

// ============================================================================
// TESTS
// ============================================================================

test "bell circuit renders" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 40, 10);
    defer sync.deinit();

    var init_snap = try sync.commit();
    init_snap.deinit(allocator);

    renderBellCircuit(&sync, 0);

    var snapshot = try sync.commit();
    defer snapshot.deinit(allocator);

    try std.testing.expect(snapshot.diffs.len > 10);

    const h_cell = sync.pane.getCell(5, 0);
    try std.testing.expect(h_cell != null);
    try std.testing.expectEqual(@as(u21, 'H'), h_cell.?.codepoint);
}

test "bell circuit syncs across nodes via packed binary" {
    const allocator = std.testing.allocator;

    var node_a = try CellSync.init(allocator, 1, 40, 10);
    defer node_a.deinit();
    var node_b = try CellSync.init(allocator, 2, 40, 10);
    defer node_b.deinit();

    var a_init = try node_a.commit();
    a_init.deinit(allocator);
    var b_init = try node_b.commit();
    b_init.deinit(allocator);

    renderBellCircuit(&node_a, 0);
    var snapshot = try node_a.commit();
    defer snapshot.deinit(allocator);

    // Syrup roundtrip with packed binary
    const syrup_val = try node_a.snapshotToSyrup(&snapshot, allocator);
    defer {
        const syrup_mod = @import("syrup.zig");
        allocator.free(syrup_val.record.fields[6].bytes);
        allocator.free(syrup_val.record.fields);
        const label_slice: *[1]syrup_mod.Value = @ptrCast(@constCast(syrup_val.record.label));
        allocator.free(label_slice);
    }

    var decoded = try CellSync.snapshotFromSyrup(allocator, syrup_val);
    defer decoded.deinit(allocator);

    node_b.applyRemote(&decoded);

    const h_cell = node_b.pane.getCell(5, 0);
    try std.testing.expect(h_cell != null);
    try std.testing.expectEqual(@as(u21, 'H'), h_cell.?.codepoint);
    try std.testing.expectEqual(COLOR_GATE, h_cell.?.fg);
}
