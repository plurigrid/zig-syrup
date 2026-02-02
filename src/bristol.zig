const std = @import("std");
const syrup = @import("syrup");

// Bristol Fashion MPC Circuit Parser & Syrup Serializer

pub const GateType = enum {
    AND, XOR, INV, EQ, EQW, MAND,
    
    pub fn fromString(s: []const u8) !GateType {
        if (std.mem.eql(u8, s, "AND")) return .AND;
        if (std.mem.eql(u8, s, "XOR")) return .XOR;
        if (std.mem.eql(u8, s, "INV")) return .INV;
        if (std.mem.eql(u8, s, "EQ")) return .EQ;
        if (std.mem.eql(u8, s, "EQW")) return .EQW;
        if (std.mem.eql(u8, s, "MAND")) return .MAND;
        return error.UnknownGate;
    }
};

pub const Gate = struct {
    num_in: u32,
    num_out: u32,
    input_wires: []u32,
    output_wires: []u32,
    op: GateType,

    pub fn toSyrup(self: Gate, allocator: std.mem.Allocator) !syrup.Value {
        // Encode gate as record: <'gate {op: "AND", in: [0, 1], out: [2]}>
        const label = syrup.Value.fromSymbol("gate");
        
        // Build input list
        var in_list = std.ArrayListUnmanaged(syrup.Value){};
        defer in_list.deinit(allocator);
        for (self.input_wires) |w| try in_list.append(allocator, syrup.Value.fromInteger(w));
        
        // Build output list
        var out_list = std.ArrayListUnmanaged(syrup.Value){};
        defer out_list.deinit(allocator);
        for (self.output_wires) |w| try out_list.append(allocator, syrup.Value.fromInteger(w));

        // Build dictionary
        var dict_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer dict_entries.deinit(allocator);

        try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("in"), .value = syrup.Value.fromList(try in_list.toOwnedSlice(allocator)) });
        try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("op"), .value = syrup.Value.fromString(@tagName(self.op)) });
        try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("out"), .value = syrup.Value.fromList(try out_list.toOwnedSlice(allocator)) });

        // Dict keys must be sorted: "in", "op", "out" -> "in", "op", "out" (alphabetical)
        // i, o, o -> 'i' (105), 'o' (111). 'op' vs 'out' -> 'p' (112) vs 'u' (117)
        // Sort order: "in", "op", "out". Correct.

        const dict = syrup.Value.fromDictionary(try dict_entries.toOwnedSlice(allocator));
        
        // Record fields list
        var fields_list = std.ArrayListUnmanaged(syrup.Value){};
        defer fields_list.deinit(allocator);
        try fields_list.append(allocator, dict);

        return syrup.Value.fromRecord(&label, try fields_list.toOwnedSlice(allocator));
    }
};

pub const Circuit = struct {
    num_gates: u32,
    num_wires: u32,
    inputs: []u32, // Wires per input value
    outputs: []u32, // Wires per output value
    gates: []Gate,

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Circuit {
        var it = std.mem.tokenizeAny(u8, input, " \n\r\t");
        
        const num_gates = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
        const num_wires = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);

        const niv = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
        const inputs = try allocator.alloc(u32, niv);
        for (inputs) |*i| {
            i.* = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
        }

        const nov = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
        const outputs = try allocator.alloc(u32, nov);
        for (outputs) |*o| {
            o.* = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
        }

        var gates = try allocator.alloc(Gate, num_gates);
        var gate_idx: usize = 0;
        
        while (gate_idx < num_gates) : (gate_idx += 1) {
            const n_in = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
            const n_out = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
            
            const in_wires = try allocator.alloc(u32, n_in);
            for (in_wires) |*w| {
                w.* = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
            }
            
            const out_wires = try allocator.alloc(u32, n_out);
            for (out_wires) |*w| {
                w.* = try std.fmt.parseInt(u32, it.next() orelse return error.UnexpectedEOF, 10);
            }
            
            const op_str = it.next() orelse return error.UnexpectedEOF;
            const op = try GateType.fromString(op_str);
            
            gates[gate_idx] = .{
                .num_in = n_in,
                .num_out = n_out,
                .input_wires = in_wires,
                .output_wires = out_wires,
                .op = op,
            };
        }

        return Circuit{
            .num_gates = num_gates,
            .num_wires = num_wires,
            .inputs = inputs,
            .outputs = outputs,
            .gates = gates,
        };
    }
    
    pub fn toSyrup(self: Circuit, allocator: std.mem.Allocator) !syrup.Value {
        // Circuit Record: <'circuit {gates: [...], meta: {ng: ..., nw: ...}}>
        const label = syrup.Value.fromSymbol("circuit");
        
        // Gates List
        var gates_list = std.ArrayListUnmanaged(syrup.Value){};
        defer gates_list.deinit(allocator);
        for (self.gates) |g| {
            try gates_list.append(allocator, try g.toSyrup(allocator));
        }
        
        // Metadata Dictionary
        var meta_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer meta_entries.deinit(allocator);
        
        try meta_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("gates"), .value = syrup.Value.fromInteger(self.num_gates) });
        try meta_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("wires"), .value = syrup.Value.fromInteger(self.num_wires) });
        
        const meta_dict = syrup.Value.fromDictionary(try meta_entries.toOwnedSlice(allocator));
        
        // Main Dictionary
        var main_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer main_entries.deinit(allocator);
        
        try main_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("body"), .value = syrup.Value.fromList(try gates_list.toOwnedSlice(allocator)) });
        try main_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("meta"), .value = meta_dict });
        
        const main_dict = syrup.Value.fromDictionary(try main_entries.toOwnedSlice(allocator));
        
        // Fields list
        var fields = try allocator.alloc(syrup.Value, 1);
        fields[0] = main_dict;
        
        return syrup.Value.fromRecord(&label, fields);
    }
};
