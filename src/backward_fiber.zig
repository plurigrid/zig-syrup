//! Backward Fiber — TODO #2 for deep-inference-interleave.
//!
//! Exposes the Radul-Sussman continuation as a concrete "backward fiber"
//! over a forward kernel chain, matching Hedges/Smithe's compositional
//! Bayesian inference:
//!
//!     forward:    π → φ → ψ      (pushforward chain)
//!     backward:   k ← ψ'_σ ← φ'_π   (continuation chain)
//!
//! The fiber at each cell carries:
//!   * the pushed prior (forward belief)
//!   * the local Bayesian inverse parameters
//!   * the continuation k that consumes a distribution on the NEXT cell
//!
//! Chain rule:  (φ;ψ)†_π = ψ†_{π;φ} ; φ†_π
//! — encoded as fiber composition here.

const std = @import("std");

/// Linear-Gaussian belief N(μ, τ²).
pub const GaussBelief = struct {
    mu: f64,
    tau: f64,

    pub fn precision(self: GaussBelief) f64 {
        return 1.0 / (self.tau * self.tau);
    }
};

/// Linear-Gaussian kernel y = slope*x + N(0, sigma²).
/// trit ∈ {-1, 0, +1} for GF(3) conservation tracking.
pub const GaussKernel = struct {
    slope: f64,
    sigma: f64,
    trit: i2,

    /// Pushforward of prior π along this kernel.
    pub fn pushforward(self: GaussKernel, pi: GaussBelief) GaussBelief {
        return .{
            .mu = self.slope * pi.mu,
            .tau = @sqrt(self.slope * self.slope * pi.tau * pi.tau + self.sigma * self.sigma),
        };
    }

    /// Bayesian inverse φ†_π evaluated at observation y.
    pub fn invert(self: GaussKernel, pi: GaussBelief, y: f64) GaussBelief {
        const prec = pi.precision() + (self.slope * self.slope) / (self.sigma * self.sigma);
        const var_post = 1.0 / prec;
        const mu_post = var_post * (pi.mu * pi.precision() + self.slope * y / (self.sigma * self.sigma));
        return .{ .mu = mu_post, .tau = @sqrt(var_post) };
    }
};

/// A single cell in the backward fiber.
pub const Fiber = struct {
    pushed_prior: GaussBelief,
    kernel: GaussKernel,

    /// Propagate an observation backward through this fiber to a posterior.
    pub fn back(self: Fiber, obs: f64) GaussBelief {
        return self.kernel.invert(self.pushed_prior, obs);
    }
};

/// Compose two kernels: (φ;ψ) with GF(3) trit sum.
pub fn compose(phi: GaussKernel, psi: GaussKernel) GaussKernel {
    const sigma = @sqrt(psi.slope * psi.slope * phi.sigma * phi.sigma + psi.sigma * psi.sigma);
    const trit_sum: i32 = @as(i32, phi.trit) + @as(i32, psi.trit);
    const normalized = @mod(trit_sum + 3, 3);
    const out_trit: i2 = if (normalized == 2) -1 else @intCast(normalized);
    return .{
        .slope = phi.slope * psi.slope,
        .sigma = sigma,
        .trit = out_trit,
    };
}

/// Build the backward fiber for a two-step chain π → φ → ψ.
/// Returns (fiber_phi, fiber_psi) such that running back in order
/// ψ then φ reproduces the chain-rule posterior.
pub const ChainFiber = struct {
    phi_fiber: Fiber,
    psi_fiber: Fiber,

    pub fn init(pi: GaussBelief, phi: GaussKernel, psi: GaussKernel) ChainFiber {
        const pushed = phi.pushforward(pi);
        return .{
            .phi_fiber = .{ .pushed_prior = pi, .kernel = phi },
            .psi_fiber = .{ .pushed_prior = pushed, .kernel = psi },
        };
    }

    /// Chain-rule posterior on x given observation z:
    ///     ψ†_{π;φ}(z) → y_point_estimate → φ†_π(y) → x
    pub fn posterior(self: ChainFiber, z: f64) GaussBelief {
        const post_y = self.psi_fiber.back(z);
        return self.phi_fiber.back(post_y.mu);
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "pushforward linearity" {
    const phi = GaussKernel{ .slope = 1.3, .sigma = 0.5, .trit = -1 };
    const pi = GaussBelief{ .mu = 0, .tau = 1 };
    const pushed = phi.pushforward(pi);
    try testing.expectApproxEqAbs(@as(f64, 0), pushed.mu, 1e-9);
    try testing.expect(pushed.tau > pi.tau);
}

test "chain rule posterior matches direct composite (mean)" {
    const phi = GaussKernel{ .slope = 1.3, .sigma = 0.5, .trit = -1 };
    const psi = GaussKernel{ .slope = 0.7, .sigma = 0.4, .trit = 1 };
    const pi = GaussBelief{ .mu = 0, .tau = 1 };

    const chain = ChainFiber.init(pi, phi, psi);
    const phipsi = compose(phi, psi);
    const direct_fiber = Fiber{ .pushed_prior = pi, .kernel = phipsi };

    var z: f64 = -2;
    while (z <= 2) : (z += 1) {
        const a = chain.posterior(z);
        const b = direct_fiber.back(z);
        try testing.expectApproxEqAbs(a.mu, b.mu, 1e-9);
    }
}

test "composite of -1 and +1 is 0 (GF3)" {
    const phi = GaussKernel{ .slope = 1.3, .sigma = 0.5, .trit = -1 };
    const psi = GaussKernel{ .slope = 0.7, .sigma = 0.4, .trit = 1 };
    const c = compose(phi, psi);
    try testing.expectEqual(@as(i2, 0), c.trit);
}
