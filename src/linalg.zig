//! Linear Algebra module for Complex arithmetic
//!
//! Provides LU decomposition with partial pivoting, forward/back substitution,
//! matrix-vector and matrix-matrix multiply, determinant, transpose, and norms.
//! Works with the Complex type defined in homotopy.zig.

const std = @import("std");
const homotopy = @import("homotopy.zig");
const Complex = homotopy.Complex;
const Allocator = std.mem.Allocator;

/// Allocate an n x m matrix of Complex zeros
pub fn allocMatrix(n: usize, m: usize, allocator: Allocator) ![][]Complex {
    const rows = try allocator.alloc([]Complex, n);
    for (rows) |*row| {
        row.* = try allocator.alloc(Complex, m);
        @memset(row.*, Complex.zero);
    }
    return rows;
}

/// Free an allocated matrix
pub fn freeMatrix(mat: [][]Complex, allocator: Allocator) void {
    for (mat) |row| {
        allocator.free(row);
    }
    allocator.free(mat);
}

/// LU decomposition with partial pivoting.
/// Decomposes A in-place into L\U (L lower-triangular with unit diagonal stored
/// below, U upper-triangular stored on and above diagonal). perm receives the
/// row permutation.
pub fn luDecompose(n: usize, A: [][]Complex, perm: []usize) !void {
    // Initialize permutation to identity
    for (0..n) |i| perm[i] = i;

    for (0..n) |k| {
        // Partial pivoting: find row with max |A[i][k]| for i >= k
        var max_val: f64 = Complex.abs(A[k][k]);
        var max_row: usize = k;
        for (k + 1..n) |i| {
            const v = Complex.abs(A[i][k]);
            if (v > max_val) {
                max_val = v;
                max_row = i;
            }
        }

        if (max_val < 1e-15) return error.SingularMatrix;

        // Swap rows k and max_row in A and perm
        if (max_row != k) {
            const tmp_row = A[k];
            A[k] = A[max_row];
            A[max_row] = tmp_row;

            const tmp_p = perm[k];
            perm[k] = perm[max_row];
            perm[max_row] = tmp_p;
        }

        // Eliminate below pivot
        for (k + 1..n) |i| {
            const factor = Complex.div(A[i][k], A[k][k]);
            A[i][k] = factor; // store L factor
            for (k + 1..n) |j| {
                A[i][j] = Complex.sub(A[i][j], Complex.mul(factor, A[k][j]));
            }
        }
    }
}

/// Solve LU * x = P * b using forward/back substitution.
/// LU is the in-place decomposition from luDecompose; perm is the permutation.
pub fn luSolve(n: usize, LU: [][]Complex, perm: []usize, b: []const Complex, x: []Complex) void {
    // Forward substitution: L * y = P * b
    // y is stored in x temporarily
    for (0..n) |i| {
        x[i] = b[perm[i]];
        for (0..i) |j| {
            x[i] = Complex.sub(x[i], Complex.mul(LU[i][j], x[j]));
        }
    }

    // Back substitution: U * x = y
    var ii: usize = n;
    while (ii > 0) {
        ii -= 1;
        for (ii + 1..n) |j| {
            x[ii] = Complex.sub(x[ii], Complex.mul(LU[ii][j], x[j]));
        }
        x[ii] = Complex.div(x[ii], LU[ii][ii]);
    }
}

/// Matrix-vector multiply: y = A * x
pub fn matVecMul(n: usize, A: []const []const Complex, x: []const Complex, y: []Complex) void {
    for (0..n) |i| {
        var sum = Complex.zero;
        for (0..n) |j| {
            sum = Complex.add(sum, Complex.mul(A[i][j], x[j]));
        }
        y[i] = sum;
    }
}

/// Matrix-matrix multiply: C = A * B (all n x n)
pub fn matMul(n: usize, A: []const []const Complex, B: []const []const Complex, C: [][]Complex) void {
    for (0..n) |i| {
        for (0..n) |j| {
            var sum = Complex.zero;
            for (0..n) |k| {
                sum = Complex.add(sum, Complex.mul(A[i][k], B[k][j]));
            }
            C[i][j] = sum;
        }
    }
}

/// Determinant via LU decomposition.
/// Note: modifies A in-place.
pub fn det(n: usize, A: [][]Complex, perm: []usize) Complex {
    luDecompose(n, A, perm) catch return Complex.zero;

    // det = sign * product of diagonal of U
    var result = Complex.one;
    for (0..n) |i| {
        result = Complex.mul(result, A[i][i]);
    }

    // Count transpositions in perm to determine sign
    var swaps: usize = 0;
    // Make a mutable copy of perm to count cycles
    var visited = [_]bool{false} ** 64; // supports up to 64x64
    for (0..n) |i| {
        if (visited[i]) continue;
        var cycle_len: usize = 0;
        var j = i;
        while (!visited[j]) {
            visited[j] = true;
            j = perm[j];
            cycle_len += 1;
        }
        if (cycle_len > 1) swaps += cycle_len - 1;
    }

    if (swaps % 2 == 1) {
        result = Complex.scale(result, -1.0);
    }
    return result;
}

/// Transpose: B = A^T. Allocates and returns the transposed matrix.
pub fn transpose(n: usize, m: usize, A: []const []const Complex, allocator: Allocator) ![][]Complex {
    var B = try allocMatrix(m, n, allocator);
    for (0..n) |i| {
        for (0..m) |j| {
            B[j][i] = A[i][j];
        }
    }
    return B;
}

/// Euclidean (L2) norm of a complex vector
pub fn norm2(v: []const Complex) f64 {
    var sum: f64 = 0;
    for (v) |c| {
        sum += c.re * c.re + c.im * c.im;
    }
    return @sqrt(sum);
}

// ============================================================================
// TESTS
// ============================================================================

test "LU decompose and solve 3x3" {
    const allocator = std.testing.allocator;

    // A = [[2, 1, 1], [4, 3, 3], [8, 7, 9]]
    // b = [1, 1, 1]
    // Solution: x = [1, -1, 1] (verified by hand: 2-1+1=2? No, let's use a proper system)
    // Actually let's pick: A*x = b where A = [[2,1,1],[4,3,3],[8,7,9]], x = [1,1,-1]
    // b = [2+1-1, 4+3-3, 8+7-9] = [2, 4, 6]

    var A = try allocMatrix(3, 3, allocator);
    defer freeMatrix(A, allocator);

    A[0][0] = Complex.init(2, 0);
    A[0][1] = Complex.init(1, 0);
    A[0][2] = Complex.init(1, 0);
    A[1][0] = Complex.init(4, 0);
    A[1][1] = Complex.init(3, 0);
    A[1][2] = Complex.init(3, 0);
    A[2][0] = Complex.init(8, 0);
    A[2][1] = Complex.init(7, 0);
    A[2][2] = Complex.init(9, 0);

    const b = [_]Complex{
        Complex.init(2, 0),
        Complex.init(4, 0),
        Complex.init(6, 0),
    };

    const perm = try allocator.alloc(usize, 3);
    defer allocator.free(perm);
    const x = try allocator.alloc(Complex, 3);
    defer allocator.free(x);

    try luDecompose(3, A, perm);
    luSolve(3, A, perm, &b, x);

    // Expected: x = [1, 1, -1]
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), x[0].re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), x[1].re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), x[2].re, 1e-10);
    // Imaginary parts should be ~0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x[0].im, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x[1].im, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x[2].im, 1e-10);
}

test "norm2" {
    // ||(3+4i)|| = 5
    const v = [_]Complex{Complex.init(3, 4)};
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), norm2(&v), 1e-10);

    // ||(1, 1i)|| = sqrt(1+1) = sqrt(2)
    const v2 = [_]Complex{ Complex.init(1, 0), Complex.init(0, 1) };
    try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), norm2(&v2), 1e-10);
}

test "matVecMul" {
    const allocator = std.testing.allocator;

    // A = [[1, 2], [3, 4]], x = [1, 1] => y = [3, 7]
    var A = try allocMatrix(2, 2, allocator);
    defer freeMatrix(A, allocator);
    A[0][0] = Complex.init(1, 0);
    A[0][1] = Complex.init(2, 0);
    A[1][0] = Complex.init(3, 0);
    A[1][1] = Complex.init(4, 0);

    const x = [_]Complex{ Complex.init(1, 0), Complex.init(1, 0) };
    var y: [2]Complex = undefined;

    // Need to cast to []const []const Complex
    const A_const: []const []const Complex = @as([]const []const Complex, @ptrCast(A));
    matVecMul(2, A_const, &x, &y);

    try std.testing.expectApproxEqAbs(@as(f64, 3.0), y[0].re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), y[1].re, 1e-10);
}
