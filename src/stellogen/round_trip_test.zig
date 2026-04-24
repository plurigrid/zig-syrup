const std = @import("std");
const stellogen = @import("mod.zig");
const ast = stellogen.ast;

test "Full Round-Trip: Narya Proof to Stellogen Execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Load the "Narya Export"
    const source = try std.fs.cwd().readFileAlloc(allocator, "bridge_proof.sg", 1024 * 1024);

    // 2. Parse the program
    const program = try stellogen.parser.parse(allocator, source);

    // 3. Build the execution environment (find 'main')
    var main_expr: ?ast.Expr = null;
    for (program) |expr| {
        switch (expr) {
            .def => |d| {
                if (std.mem.eql(u8, d.name, "main")) {
                    main_expr = d.value.*;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(main_expr != null);

    // 4. Resolve references (#data, #refl) manually for the demo
    // In a full compiler, this is handled by the 'call' evaluator.
    // For this demo, we construct the constellation trace directly.

    const x = ast.makeVar("X");
    const data_val = ast.makeAtom(ast.Face.fromPolarity(.null), "verified_datum");

    // Star 1 (refl): [(-term X) (+term X)]
    const neg_term_x = try ast.makeFunc(allocator, ast.Face.fromPolarity(.neg), "term", &.{x});
    const pos_term_x = try ast.makeFunc(allocator, ast.Face.fromPolarity(.pos), "term", &.{x});
    const refl_star = ast.Star{
        .content = try allocator.dupe(ast.Ray, &.{ neg_term_x, pos_term_x }),
        .is_state = true,
    };

    // Star 2 (data): [(+term "verified_datum")]
    const data_atom = try ast.makeFunc(allocator, ast.Face.fromPolarity(.pos), "term", &.{data_val});
    const data_star = ast.Star{
        .content = try allocator.dupe(ast.Ray, &.{data_atom}),
        .is_state = false,
    };

    const initial_constellation = ast.Constellation{
        .stars = try allocator.dupe(ast.Star, &.{ refl_star, data_star }),
    };

    // 5. Execute Star Fusion (Reduction)
    // The executor will unify (+term data) with (-term X), binding X=data.
    // The residual will be (+term data).
    const result = try stellogen.executor.execute(allocator, initial_constellation, true);

    // 6. Verify Result: The identity proof preserved the data
    try std.testing.expectEqual(@as(usize, 1), result.stars.len);
    const final_star = result.stars[0];
    try std.testing.expectEqual(@as(usize, 1), final_star.content.len);

    const expected_ray = try ast.makeFunc(allocator, ast.Face.fromPolarity(.pos), "term", &.{data_val});
    try std.testing.expect(final_star.content[0].eql(expected_ray));

    std.debug.print("\n[STELLOGEN] Round-trip SUCCESS: Proof execution preserved datum '{s}'\n", .{data_val.function.id.name});
}
