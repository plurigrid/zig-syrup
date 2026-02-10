//! Stellogen WASM Runtime - Embedded runtime for wasm32-standalone
//!
//! This module provides the runtime support for executing compiled Stellogen
//! programs in a WASM environment. It implements:
//!
//! - Term heap management
//! - Unification algorithm
//! - Star fusion
//! - Constellation execution
//!
//! Exports (C ABI):
//!   - stellogen_init(): Initialize runtime
//!   - stellogen_alloc_term(tag, size): Allocate a term node
//!   - stellogen_unify(a, b): Unify two terms
//!   - stellogen_fuse(state, action): Fuse two stars
//!   - stellogen_exec(constellation, linear): Execute constellation
//!   - stellogen_has_ok(constellation): Check for 'ok' result

const std = @import("std");

// ============================================================================
// Memory Layout
// ============================================================================

// WASM linear memory layout:
// 0x00000000 - 0x0000FFFF: Reserved (64KB)
// 0x00010000 - 0x00FFFFFF: Term heap (16MB)
// 0x01000000 - onwards: Stack/scratch space

const HEAP_START: u32 = 0x10000;
const HEAP_SIZE: u32 = 0xF00000; // ~15MB

// Global state (stored at fixed addresses)
var heap_ptr: u32 = HEAP_START;

// Term tags
const TAG_VAR: u8 = 0;
const TAG_FUNC: u8 = 1;
const TAG_STAR: u8 = 2;
const TAG_CONSTELLATION: u8 = 3;

// Polarity values
const POL_POS: i8 = 1;
const POL_NEG: i8 = -1;
const POL_NULL: i8 = 0;

// ============================================================================
// Memory Operations
// ============================================================================

fn readU8(addr: u32) u8 {
    const ptr: [*]const u8 = @ptrFromInt(addr);
    return ptr[0];
}

fn writeU8(addr: u32, val: u8) void {
    const ptr: [*]u8 = @ptrFromInt(addr);
    ptr[0] = val;
}

fn readU32(addr: u32) u32 {
    const ptr: [*]const u32 = @ptrFromInt(addr);
    return ptr[0];
}

fn writeU32(addr: u32, val: u32) void {
    const ptr: [*]u32 = @ptrFromInt(addr);
    ptr[0] = val;
}

fn readI8(addr: u32) i8 {
    const ptr: [*]const i8 = @ptrFromInt(addr);
    return ptr[0];
}

fn writeI8(addr: u32, val: i8) void {
    const ptr: [*]i8 = @ptrFromInt(addr);
    ptr[0] = val;
}

// ============================================================================
// Heap Allocation
// ============================================================================

fn alloc(size: u32) u32 {
    const addr = heap_ptr;
    heap_ptr += size;
    // Align to 4 bytes
    heap_ptr = (heap_ptr + 3) & ~@as(u32, 3);
    return addr;
}

// ============================================================================
// Term Structure
// ============================================================================

// Variable term: [tag:1, name_len:4, name_bytes:N, index:4]
// Function term: [tag:1, polarity:1, name_len:4, name_bytes:N, arg_count:4, args:N*4]

fn makeVar(name: []const u8, index: u32) u32 {
    const size = 1 + 4 + @as(u32, @intCast(name.len)) + 4;
    const addr = alloc(size);

    writeU8(addr, TAG_VAR);
    writeU32(addr + 1, @intCast(name.len));

    var i: u32 = 0;
    while (i < name.len) : (i += 1) {
        writeU8(addr + 5 + i, name[i]);
    }

    writeU32(addr + 5 + @as(u32, @intCast(name.len)), index);

    return addr;
}

fn makeFunc(polarity: i8, name: []const u8, args: []const u32) u32 {
    const size = 1 + 1 + 4 + @as(u32, @intCast(name.len)) + 4 + @as(u32, @intCast(args.len)) * 4;
    const addr = alloc(size);

    writeU8(addr, TAG_FUNC);
    writeI8(addr + 1, polarity);
    writeU32(addr + 2, @intCast(name.len));

    var i: u32 = 0;
    while (i < name.len) : (i += 1) {
        writeU8(addr + 6 + i, name[i]);
    }

    const args_start = addr + 6 + @as(u32, @intCast(name.len));
    writeU32(args_start, @intCast(args.len));

    i = 0;
    while (i < args.len) : (i += 1) {
        writeU32(args_start + 4 + i * 4, args[i]);
    }

    return addr;
}

fn getTermTag(term: u32) u8 {
    return readU8(term);
}

fn getFuncPolarity(term: u32) i8 {
    return readI8(term + 1);
}

fn getFuncNameLen(term: u32) u32 {
    return readU32(term + 2);
}

fn getFuncName(term: u32) []const u8 {
    const len = getFuncNameLen(term);
    const ptr: [*]const u8 = @ptrFromInt(term + 6);
    return ptr[0..len];
}

fn getFuncArgCount(term: u32) u32 {
    const name_len = getFuncNameLen(term);
    return readU32(term + 6 + name_len);
}

fn getFuncArg(term: u32, idx: u32) u32 {
    const name_len = getFuncNameLen(term);
    return readU32(term + 10 + name_len + idx * 4);
}

// ============================================================================
// Unification
// ============================================================================

fn polarityCompatible(p1: i8, p2: i8) bool {
    return (p1 == POL_POS and p2 == POL_NEG) or
        (p1 == POL_NEG and p2 == POL_POS) or
        p1 == POL_NULL or p2 == POL_NULL;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn termEql(a: u32, b: u32) bool {
    const tag_a = getTermTag(a);
    const tag_b = getTermTag(b);

    if (tag_a != tag_b) return false;

    if (tag_a == TAG_VAR) {
        // Compare variable names and indices
        const name_len_a = readU32(a + 1);
        const name_len_b = readU32(b + 1);
        if (name_len_a != name_len_b) return false;

        var i: u32 = 0;
        while (i < name_len_a) : (i += 1) {
            if (readU8(a + 5 + i) != readU8(b + 5 + i)) return false;
        }

        const idx_a = readU32(a + 5 + name_len_a);
        const idx_b = readU32(b + 5 + name_len_b);
        return idx_a == idx_b;
    }

    if (tag_a == TAG_FUNC) {
        // Compare function names
        const name_a = getFuncName(a);
        const name_b = getFuncName(b);
        if (!strEql(name_a, name_b)) return false;

        // Compare polarities
        if (getFuncPolarity(a) != getFuncPolarity(b)) return false;

        // Compare arguments
        const argc_a = getFuncArgCount(a);
        const argc_b = getFuncArgCount(b);
        if (argc_a != argc_b) return false;

        var i: u32 = 0;
        while (i < argc_a) : (i += 1) {
            if (!termEql(getFuncArg(a, i), getFuncArg(b, i))) return false;
        }

        return true;
    }

    return false;
}

// Simplified unification (returns 1 if unifiable, 0 otherwise)
fn unifyTerms(a: u32, b: u32) u32 {
    const tag_a = getTermTag(a);
    const tag_b = getTermTag(b);

    // Identical terms
    if (termEql(a, b)) return 1;

    // Variable binds to anything
    if (tag_a == TAG_VAR or tag_b == TAG_VAR) return 1;

    // Function decomposition
    if (tag_a == TAG_FUNC and tag_b == TAG_FUNC) {
        const name_a = getFuncName(a);
        const name_b = getFuncName(b);

        if (!strEql(name_a, name_b)) return 0;
        if (!polarityCompatible(getFuncPolarity(a), getFuncPolarity(b))) return 0;

        const argc_a = getFuncArgCount(a);
        const argc_b = getFuncArgCount(b);
        if (argc_a != argc_b) return 0;

        var i: u32 = 0;
        while (i < argc_a) : (i += 1) {
            if (unifyTerms(getFuncArg(a, i), getFuncArg(b, i)) == 0) return 0;
        }

        return 1;
    }

    return 0;
}

// ============================================================================
// Exported Functions (C ABI)
// ============================================================================

/// Initialize the runtime
export fn stellogen_init() void {
    heap_ptr = HEAP_START;
}

/// Allocate a term node
export fn stellogen_alloc_term(size: u32) u32 {
    return alloc(size);
}

/// Write a byte to memory
export fn stellogen_write_u8(addr: u32, val: u8) void {
    writeU8(addr, val);
}

/// Write a u32 to memory
export fn stellogen_write_u32(addr: u32, val: u32) void {
    writeU32(addr, val);
}

/// Read a u32 from memory
export fn stellogen_read_u32(addr: u32) u32 {
    return readU32(addr);
}

/// Create a variable term
export fn stellogen_make_var(name_ptr: u32, name_len: u32, index: u32) u32 {
    const ptr: [*]const u8 = @ptrFromInt(name_ptr);
    const name = ptr[0..name_len];
    return makeVar(name, index);
}

/// Create a function term (no args)
export fn stellogen_make_atom(polarity: i8, name_ptr: u32, name_len: u32) u32 {
    const ptr: [*]const u8 = @ptrFromInt(name_ptr);
    const name = ptr[0..name_len];
    return makeFunc(polarity, name, &.{});
}

/// Unify two terms
export fn stellogen_unify(a: u32, b: u32) u32 {
    return unifyTerms(a, b);
}

/// Check if terms are equal
export fn stellogen_term_eq(a: u32, b: u32) u32 {
    return if (termEql(a, b)) 1 else 0;
}

/// Get term tag
export fn stellogen_get_tag(term: u32) u8 {
    return getTermTag(term);
}

/// Check for 'ok' atom (name == "ok", no args)
export fn stellogen_is_ok(term: u32) u32 {
    if (getTermTag(term) != TAG_FUNC) return 0;
    const name = getFuncName(term);
    if (name.len != 2) return 0;
    if (name[0] != 'o' or name[1] != 'k') return 0;
    if (getFuncArgCount(term) != 0) return 0;
    return 1;
}

/// Get heap pointer (for debugging)
export fn stellogen_heap_ptr() u32 {
    return heap_ptr;
}

// ============================================================================
// Panic Handler (required for freestanding)
// ============================================================================

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = ret_addr;
    @trap();
}
