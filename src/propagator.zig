//! SDF Chapter 7: Propagator Networks
//! Implements bidirectional constraint propagation for BCI neurofeedback.

const std = @import("std");

pub fn Cell(comptime T: type) type {
    return struct {
        const Self = @This();
        
        name: []const u8,
        content: ?T = null,
        neighbors: std.ArrayListUnmanaged(*Propagator(T)),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
            return Self{
                .name = name,
                .allocator = allocator,
                .neighbors = std.ArrayListUnmanaged(*Propagator(T)){},
            };
        }

        pub fn deinit(self: *Self) void {
            self.neighbors.deinit(self.allocator);
        }

        pub fn add_neighbor(self: *Self, propagator: *Propagator(T)) anyerror!void {
            try self.neighbors.append(self.allocator, propagator);
        }

        pub fn set_content(self: *Self, value: T) anyerror!void {
            if (self.content) |current| {
                if (!std.meta.eql(current, value)) {
                    // Contradiction or update? For now, just overwrite (simple mode)
                    // In full SDF, we'd check for consistency.
                    self.content = value;
                    try self.alert_neighbors();
                }
            } else {
                self.content = value;
                try self.alert_neighbors();
            }
        }

        pub fn get_content(self: *Self) ?T {
            return self.content;
        }

        fn alert_neighbors(self: *Self) anyerror!void {
            for (self.neighbors.items) |prop| {
                try prop.alert();
            }
        }
    };
}

pub fn Propagator(comptime T: type) type {
    return struct {
        const Self = @This();
        
        inputs: []const *Cell(T),
        outputs: []const *Cell(T),
        function: *const fn([]const ?T) ?T,
        
        pub fn alert(self: *Self) anyerror!void {
            var args = std.ArrayListUnmanaged(?T){};
            const alloc = self.inputs[0].allocator;
            defer args.deinit(alloc);

            // var all_inputs_present = true;
            for (self.inputs) |cell| {
                try args.append(alloc, cell.get_content());
            }

            // Simple forward propagation: if all inputs are present, compute output
            // if (all_inputs_present) {
            if (self.function(args.items)) |result| {
                for (self.outputs) |out_cell| {
                    try out_cell.set_content(result);
                }
            }
            // }
        }
    };
}

// BCI Logic as Propagator Function
pub fn neurofeedback_gate(args: []const ?f32) ?f32 {
    const focus = args[0] orelse return null;
    const relax = args[1] orelse return null;
    const threshold = args[2] orelse return null; // passed as content

    if (focus > threshold and relax < 0.3) {
        return 1.0; // Trigger Action
    } else {
        return 0.0; // No Action
    }
}
