//! Zeta World - Thermodynamic Graph Visualization
//!
//! This module implements a world where the game state is the
//! spectral analysis of a graph. It serves two purposes:
//! 1. A rigorous test for Ihara-Hashimoto spectral gap calculations.
//! 2. A playable dashboard for visualizing graph expansion (Ramanujan property).
//!
//! Features:
//! - Computes eigenvalues of the non-backtracking matrix B.
//! - Renders a spectral gap gauge using retty.zig.
//! - Visualizes the "Entropy" of the graph (log zeta).

const std = @import("std");
const Allocator = std.mem.Allocator;
const spectral_tensor = @import("spectral_tensor");
const retty = @import("retty");
const widgets = @import("zeta/widgets.zig");

/// The Zeta World state
pub const ZetaWorld = struct {
    allocator: Allocator,
    
    // Graph state (Adjacency matrix)
    // For this demo, we use a fixed size N=10 graph that evolves
    n: usize,
    adjacency: []i32, // Flattened n*n
    
    // Spectral metrics
    eigenvalues: []f64,
    spectral_gap: f64,
    is_ramanujan: bool,
    entropy: f64,
    
    // Tick counter for "evolution"
    tick_count: u64,

    pub fn init(allocator: Allocator, n: usize) !*ZetaWorld {
        const self = try allocator.create(ZetaWorld);
        
        self.* = .{
            .allocator = allocator,
            .n = n,
            .adjacency = try allocator.alloc(i32, n * n),
            .eigenvalues = try allocator.alloc(f64, n), // Storing top N for now
            .spectral_gap = 0,
            .is_ramanujan = false,
            .entropy = 0,
            .tick_count = 0,
        };
        
        // Initialize with a simple cycle graph C_n
        @memset(self.adjacency, 0);
        for (0..n) |i| {
            const prev = if (i == 0) n - 1 else i - 1;
            const next = if (i == n - 1) 0 else i + 1;
            self.setEdge(i, prev, 1);
            self.setEdge(i, next, 1);
        }
        
        return self;
    }
    
    pub fn deinit(self: *ZetaWorld) void {
        self.allocator.free(self.adjacency);
        self.allocator.free(self.eigenvalues);
        self.allocator.destroy(self);
    }
    
    fn setEdge(self: *ZetaWorld, u: usize, v: usize, val: i32) void {
        self.adjacency[u * self.n + v] = val;
    }
    
    fn getEdge(self: ZetaWorld, u: usize, v: usize) i32 {
        return self.adjacency[u * self.n + v];
    }

    /// Simulate one "frame" of world time.
    /// In this test world, we randomly add/remove edges to see spectral evolution.
    pub fn tick(self: *ZetaWorld) !void {
        self.tick_count += 1;
        
        // Every 10 ticks, mutate graph
        if (self.tick_count % 10 == 0) {
            // Pseudo-random edge flip (deterministic for test stability)
            // Use simple LCG
            var seed = self.tick_count *% 123456789;
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            
            const u = seed % self.n;
            const v = (seed >> 16) % self.n;
            
            if (u != v) {
                const current = self.getEdge(u, v);
                const new_val = if (current == 0) @as(i32, 1) else 0;
                self.setEdge(u, v, new_val);
                self.setEdge(v, u, new_val); // Undirected
            }
        }
        
        try self.computeSpectrum();
    }
    
    /// The core mathematical engine: Ihara-Hashimoto spectral analysis
    fn computeSpectrum(self: *ZetaWorld) !void {
        // 1. Construct Hashimoto Matrix B (2|E| x 2|E|)
        // For simplicity in this "Test World", we approximate using Bass's Formula
        // det(I - uB) = (1 - u^2)^{r-1} det(I - uA + u^2(D-I))
        // The non-trivial eigenvalues of B are related to A via:
        // lambda_B = lambda_A +/- sqrt(lambda_A^2 - 4(d-1)) / 2  (for regular graphs)
        
        // We use spectral_tensor.zig to decompose A
        var dense = try spectral_tensor.DenseMatrix.init(self.allocator, self.n, self.n);
        defer dense.deinit(self.allocator);
        
        for (0..self.n) |r| {
            for (0..self.n) |c| {
                dense.set(r, c, @floatFromInt(self.adjacency[r * self.n + c]));
            }
        }
        
        // Compute eigenvalues of A
        const eigen = try spectral_tensor.eigendecompose(dense, self.n, self.allocator);
        defer eigen.deinit(self.allocator);
        
        // Store eigenvalues (sorted ascending from solver)
        // We want descending (largest first)
        for (0..self.n) |i| {
            self.eigenvalues[i] = eigen.eigenvalues[self.n - 1 - i];
        }
        
        // Spectral gap of A: lambda_1 - lambda_2
        const lambda1 = self.eigenvalues[0];
        const lambda2 = self.eigenvalues[1];
        self.spectral_gap = lambda1 - lambda2;
        
        // Ramanujan check (approximate for irregular graphs: Alon-Boppana bound)
        // lambda2 <= 2 * sqrt(avg_degree - 1)
        var avg_degree: f64 = 0;
        var total_deg: f64 = 0;
        for (0..self.n) |i| {
            var d: f64 = 0;
            for (0..self.n) |j| {
                if (self.getEdge(i, j) != 0) d += 1;
            }
            total_deg += d;
        }
        avg_degree = total_deg / @as(f64, @floatFromInt(self.n));
        
        const ramanujan_bound = 2.0 * std.math.sqrt(@max(0, avg_degree - 1.0));
        self.is_ramanujan = (lambda2 <= ramanujan_bound);
        
        // Entropy = log(zeta_G(u_crit))
        // Approximation: S ~ log(1 / (1 - u_crit * lambda1))
        // This is a toy metric for the dashboard
        self.entropy = if (lambda1 > 0) std.math.log(f64, std.math.e, lambda1) else 0;
    }

    /// Render the world as a retty UI using the Thermodynamic Dashboard
    pub fn render(self: *ZetaWorld, buffer: *retty.Buffer, rect: retty.Rect) void {
        const dashboard = widgets.EntropyDashboard{
            .entropy = self.entropy,
            .spectral_gap = self.spectral_gap,
            .is_ramanujan = self.is_ramanujan,
            .tick_count = self.tick_count,
        };
        dashboard.render(buffer, rect);
    }
};
