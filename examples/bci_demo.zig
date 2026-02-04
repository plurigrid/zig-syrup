//! BCI-Aptos Bridge Demo (JSON Output)
//!
//! Simulates a user session and outputs JSON lines to stdout
//! for visualization by external tools (e.g., Julia/Notcurses).

const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h"); // for sleep
});
const worlds = @import("worlds");
const bci_aptos = worlds.bci_aptos;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // const stdout = std.io.getStdOut().writer();

    // Initialize Bridge
    var bridge = worlds.BciAptosBridge.init(allocator);
    defer bridge.deinit();

    // Initialize Propagator Network (SDF Chapter 7)
    // We lift the BCI state processing into a constraint network
    const propagator = @import("propagator");
    
    var focus_cell = propagator.Cell(f32).init(allocator, "focus");
    defer focus_cell.deinit();
    
    var relax_cell = propagator.Cell(f32).init(allocator, "relax");
    defer relax_cell.deinit();
    
    var thresh_cell = propagator.Cell(f32).init(allocator, "threshold");
    defer thresh_cell.deinit();
    
    var action_cell = propagator.Cell(f32).init(allocator, "action");
    defer action_cell.deinit();

    // The gate is the "Propagator" connecting the cells
    const inputs = [_]*propagator.Cell(f32){ &focus_cell, &relax_cell, &thresh_cell };
    const outputs = [_]*propagator.Cell(f32){ &action_cell };
    
    var gate = propagator.Propagator(f32){
        .inputs = &inputs,
        .outputs = &outputs,
        .function = propagator.neurofeedback_gate,
    };

    // Wire up the network
    try focus_cell.add_neighbor(&gate);
    try relax_cell.add_neighbor(&gate);
    try thresh_cell.add_neighbor(&gate);
    
    // Set parameters
    try thresh_cell.set_content(0.8);

    bridge.setNeurofeedback(.{
        .target_focus = 0.8,
        .target_relaxation = 0.2,
        .tolerance = 0.2,
        .reward_function = .threshold,
    });

    const rand = std.crypto.random;
    const start_time = std.time.milliTimestamp();
    const duration_ms = 20 * 1000; // 20 seconds
    
    var t = std.time.milliTimestamp();
    
    while (t < start_time + duration_ms) : (t = std.time.milliTimestamp()) {
        const elapsed_sec = @as(f64, @floatFromInt(t - start_time)) / 1000.0;
        
        // Brain state simulation
        var focus: f32 = 0.0;
        var relax: f32 = 0.0;
        
        if (elapsed_sec < 5.0) {
            focus = 0.3 + rand.float(f32) * 0.2;
            relax = 0.5 + rand.float(f32) * 0.2;
        } else {
            focus = 0.85 + rand.float(f32) * 0.15;
            relax = 0.1 + rand.float(f32) * 0.1;
        }

        const state = bci_aptos.OpenBciState{
            .timestamp = t,
            .focus_level = focus,
            .relaxation_level = relax,
            .engagement_level = focus,
            .fatigue_level = 0.1,
            .band_powers = .{0} ** 5,
            .signal_quality = .{0} ** 16,
        };

        // Propagate Values
        // Note: In a real system, we'd clear content or use timestamps. 
        // Here we just overwrite.
        try focus_cell.set_content(focus);
        try relax_cell.set_content(relax);

        const should_act = if (action_cell.get_content()) |val| val > 0.5 else false;

        if (should_act) {
             // Only process state if propagator says so
             if (try bridge.processState(state)) |action| {
                 const payload = try action.toAptosPayload(allocator);
                 defer allocator.free(payload);
                 
                 _ = c.printf("{\"timestamp\": %ld, \"focus\": %.2f, \"relax\": %.2f, \"action\": \"%s\", \"confidence\": %.2f, \"payload\": \"%s\"}\n",
                    t, focus, relax, @tagName(action.role).ptr, action.confidence, payload.ptr
                 );
             } else {
                 // Even if propagated, bridge internal logic might gate it (double check)
                  _ = c.printf("{\"timestamp\": %ld, \"focus\": %.2f, \"relax\": %.2f, \"action\": null, \"confidence\": 0.0}\n",
                    t, focus, relax
                 );
             }
        } else {
             _ = c.printf("{\"timestamp\": %ld, \"focus\": %.2f, \"relax\": %.2f, \"action\": null, \"confidence\": 0.0}\n",
                t, focus, relax
             );
        }

        // std.time.sleep(200 * 1000 * 1000); // 200ms (5 Hz)
        _ = c.usleep(200 * 1000);
    }
}
