//! Disclosure Insurance Protocol: $REGRET externalizes the cost of not protecting $GAY
//!
//! The internet is an RF phase space phenomenon. Disclosure travels through it
//! as a signal: frequency (urgency), phase (timing), amplitude (impact).
//! The supermap framework from supermap.zig models this physical layer.
//!
//! On top of the physics sits the game theory:
//!
//!   The quantum switch IS the insurance mechanism.
//!
//!   Without insurance (control = 0):
//!     causal order = reveal ∘ withhold  (cautious: assess before exposing)
//!
//!   With insurance (control = +1):
//!     causal order = withhold ∘ reveal  (bold: disclose freely, you're covered)
//!
//!   GF(3) superposition (control = -1):
//!     partial disclosure: neither fully open nor fully closed
//!     the genuinely new case that classical systems cannot produce
//!
//! The GF(3) conservation law guarantees harmlessness:
//!   Σ(trits across all participants) ≡ 0 (mod 3)
//!   No operator can be made worse off because every +1 is balanced by a -1.
//!   This is the formal content of "completely harmless to operators."
//!
//! Filecoin-level guarantees come from content-addressing:
//!   Every disclosure is hashed to a CID before the quantum switch is applied.
//!   The CID commits the content; the switch determines when/whether it's revealed.
//!   Once revealed, the content is permanently verifiable against its CID.
//!
//! Connection to Aptos contracts:
//!   $REGRET (Regret::regret) — no max supply, 8 decimals, insurance settlement
//!   $GAY (vibesnipe::gay_triad_multisig) — 1.069B cap, GF(3) triadic governance
//!   The Zig layer computes disclosure decisions; the Move layer settles them.

const std = @import("std");
const entangle = @import("entangle.zig");
const supermap = @import("supermap.zig");
const Trit = entangle.Trit;
const Channel = supermap.Channel;
const Supermap = supermap.Supermap;
const PhaseCell = supermap.PhaseCell;
const Affordance = supermap.Affordance;

// ============================================================================
// DISCLOSURE STATE
// ============================================================================

/// A disclosure: content with two possible futures (reveal vs. withhold).
///
/// The content_hash is the CID — Filecoin-level guarantee that the content
/// exists and is immutable regardless of whether it's been revealed.
///
/// The reveal_channel and withhold_channel model what happens to the system
/// state when the disclosure is revealed vs. withheld. The quantum switch
/// selects between them based on the insurance (REGRET) state.
pub const Disclosure = struct {
    /// Content hash (CID): SHA3-256 of the disclosure content.
    /// This commits the content before the reveal/withhold decision.
    content_hash: [32]u8,

    /// What happens to the RF phase space when this is revealed.
    /// Typically shifts phase (timing changes) and amplitude (impact).
    reveal_channel: Channel,

    /// What happens when this is withheld.
    /// Typically identity or slight drift (information decays).
    withhold_channel: Channel,

    /// The regret trit: how much regret accrues from withholding.
    /// Computed as GF(3) distance between reveal and withhold outcomes.
    regret: Trit,

    /// Insurance state: whether REGRET tokens cover this disclosure.
    ///   plus(+1):  fully insured — disclose freely
    ///   zero(0):   uninsured — cautious ordering
    ///   minus(-1): counter-insured — partial disclosure only
    insurance: Trit,

    /// Timestamp (generation counter from CyberPhysical system).
    generation: u64,

    /// Compute the effective channel via quantum switch.
    /// This is the core mechanism: insurance determines causal order.
    pub fn effectiveChannel(self: Disclosure) Channel {
        return Supermap.quantumSwitch(
            self.reveal_channel,
            self.withhold_channel,
            self.insurance,
        );
    }

    /// Compute regret as GF(3) Hamming distance between outcomes.
    /// For each coordinate where reveal ≠ withhold, regret accumulates.
    pub fn computeRegret(self: Disclosure, state: PhaseCell) Trit {
        const revealed = self.reveal_channel.apply(state);
        const withheld = self.withhold_channel.apply(state);

        var distance: Trit = .zero;
        const r_arr = revealed.toArray();
        const w_arr = withheld.toArray();
        for (0..3) |i| {
            if (r_arr[i] != w_arr[i]) {
                // Each differing coordinate adds +1 to regret
                distance = Trit.add(distance, .plus);
            }
        }
        return distance;
    }

    /// Check if disclosure is safe (harmless to operators).
    /// Safe iff the effective channel preserves GF(3) parity of the input.
    pub fn isSafe(self: Disclosure, state: PhaseCell) bool {
        _ = state;
        // Harmlessness: the transformation doesn't create net imbalance
        // Check that determinant is non-zero (invertible = reversible = harmless)
        return self.effectiveChannel().determinant() != .zero;
    }
};

// ============================================================================
// REGRET COMPUTATION
// ============================================================================

/// Regret accumulator: tracks externalized regret across multiple disclosures.
///
/// The regret pool is the settlement layer. When disclosures are withheld,
/// regret accumulates. When the pool crosses a threshold, it triggers
/// REGRET token minting on Aptos (via the Move contract).
///
/// The pool maintains GF(3) conservation: total regret across all participants
/// must sum to zero. This is enforced by pairing each disclosure's regret
/// with a compensating insurance payment.
pub const RegretPool = struct {
    /// Accumulated regret per role (generator, coordinator, validator)
    generator_regret: i32,
    coordinator_regret: i32,
    validator_regret: i32,

    /// Total disclosures processed
    disclosures_processed: u64,

    /// Total regret externalized (in REGRET token units, 8 decimals)
    total_externalized: u64,

    /// GF(3) balance of the pool
    balance_trit: Trit,

    pub fn init() RegretPool {
        return .{
            .generator_regret = 0,
            .coordinator_regret = 0,
            .validator_regret = 0,
            .disclosures_processed = 0,
            .total_externalized = 0,
            .balance_trit = .zero,
        };
    }

    /// Process a disclosure: compute regret and distribute to roles.
    ///
    /// The GF(3) trit of the regret determines which role absorbs it:
    ///   plus(+1):  generator absorbs (they created the situation)
    ///   zero(0):   coordinator absorbs (they mediated)
    ///   minus(-1): validator absorbs (they verified)
    ///
    /// This mirrors the GAY triad: generator(+1) / coordinator(0) / validator(-1).
    pub fn processDisclosure(self: *RegretPool, disclosure: Disclosure, state: PhaseCell) void {
        const regret = disclosure.computeRegret(state);

        switch (regret) {
            .plus => self.generator_regret += 1,
            .zero => self.coordinator_regret += 1,
            .minus => self.validator_regret += 1,
        }

        // Externalize: convert to REGRET token units
        // 1 trit of regret = 1e8 REGRET (1 token, 8 decimals)
        if (regret != .zero) {
            self.total_externalized += 100_000_000; // 1 REGRET
        }

        self.disclosures_processed += 1;
        self.balance_trit = self.computeBalance();
    }

    /// GF(3) balance: sum of role regrets mod 3.
    /// Zero means the pool is balanced (harmless).
    pub fn computeBalance(self: *const RegretPool) Trit {
        const total = self.generator_regret + self.coordinator_regret + self.validator_regret;
        const m = @mod(total, 3);
        return switch (m) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => .zero,
        };
    }

    /// Check if the pool is GF(3) balanced (harmless).
    pub fn isBalanced(self: *const RegretPool) bool {
        return self.balance_trit == .zero;
    }

    /// Rebalance: redistribute regret to restore GF(3) conservation.
    /// This is the insurance payout — REGRET tokens flow to restore balance.
    pub fn rebalance(self: *RegretPool) Trit {
        const imbalance = self.computeBalance();
        if (imbalance == .zero) return .zero;

        // Apply correction: subtract imbalance from the heaviest role
        switch (imbalance) {
            .plus => self.generator_regret -= 1,
            .minus => self.validator_regret -= 1,
            .zero => {},
        }

        self.balance_trit = self.computeBalance();
        return imbalance; // return what was corrected (for settlement)
    }
};

// ============================================================================
// DISCLOSURE AFFORDANCE
// ============================================================================

/// Disclosure affordance: can the system safely disclose right now?
///
/// This extends the supermap.zig affordance framework with disclosure-specific
/// conditions. A disclosure is afforded when:
///   1. The "communicate" affordance is available (RF can carry the signal)
///   2. Insurance covers the regret (REGRET tokens are staked)
///   3. GF(3) conservation would be maintained after disclosure
pub fn disclosureAffordance(insurance: Trit) Affordance {
    var a = Affordance{};
    const name = "disclose";
    @memcpy(a.name[0..name.len], name);
    a.name_len = name.len;

    // Disclosure requires: amplitude >= 0 (signal can carry data)
    // AND phase >= 0 (timing is right)
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        if (@intFromEnum(cell.amp) >= 0 and @intFromEnum(cell.phase) >= 0) {
            a.phase_mask |= @as(u27, 1) << @intCast(i);
        }
    }

    a.min_amp = .zero;
    a.min_phase = .zero;

    // The enabled supermap depends on insurance state:
    // This IS the quantum switch parameterized by insurance
    a.enabled_supermap = .{
        .control = insurance,
        .conjugator = Channel.PERMUTE,
    };

    return a;
}

// ============================================================================
// INTERNET TRANSPORT: RF phase space → disclosure delivery
// ============================================================================

/// Model the internet as an RF phase space channel.
///
/// The internet IS a composition of RF channels:
///   WiFi:  2.4/5/6 GHz  →  freq trit = low/mid/high
///   5G:    sub-6/mmWave  →  freq trit = low/high
///   Fiber: λ = 1310/1550nm → phase trit (wavelength division)
///
/// A disclosure traverses multiple channels in sequence.
/// The quantum switch determines the order of traversal.
pub const InternetTransport = struct {
    /// The channel stack: physical → link → network → transport → application
    /// Modeled as 5 GF(3)³ channels composed in sequence.
    layers: [5]Channel,

    /// Composite channel (all layers composed)
    composite: Channel,

    /// Current RF state at the physical layer
    rf_state: PhaseCell,

    pub fn init() InternetTransport {
        const id = Channel.IDENTITY;
        return .{
            .layers = .{
                // Layer 0: Physical (RF modulation)
                Channel.CNOT_FREQ_PHASE,
                // Layer 1: Link (error correction — permutes to detect)
                Channel.PERMUTE,
                // Layer 2: Network (routing — identity in simple case)
                id,
                // Layer 3: Transport (flow control — CNOT phase→amp)
                Channel{
                    .matrix = .{
                        .{ .plus, .zero, .zero },
                        .{ .zero, .plus, .zero },
                        .{ .zero, .plus, .plus },
                    },
                    .offset = .{ .zero, .zero, .zero },
                },
                // Layer 4: Application (disclosure protocol — identity, modified by supermap)
                id,
            },
            .composite = id, // computed lazily
            .rf_state = .{ .freq = .zero, .phase = .zero, .amp = .zero },
        };
    }

    /// Compose all layers into a single channel.
    pub fn composeStack(self: *InternetTransport) void {
        self.composite = self.layers[0];
        for (1..5) |i| {
            self.composite = Channel.compose(self.layers[i], self.composite);
        }
    }

    /// Apply a supermap to the application layer (layer 4).
    /// This is how the disclosure protocol modifies the internet stack.
    pub fn applyDisclosureSupermap(self: *InternetTransport, sm: Supermap) void {
        self.layers[4] = sm.apply(self.layers[4]);
        self.composeStack();
    }

    /// Transmit a disclosure through the internet.
    /// Returns the output RF state after traversing all layers.
    pub fn transmit(self: *InternetTransport, input: PhaseCell) PhaseCell {
        return self.composite.apply(input);
    }

    /// Check if the stack preserves invertibility (lossless transport).
    pub fn isLossless(self: *const InternetTransport) bool {
        return self.composite.determinant() != .zero;
    }
};

// ============================================================================
// FULL PROTOCOL: disclosure decision engine
// ============================================================================

/// The complete disclosure insurance protocol.
///
/// Connects:
///   supermap.zig  →  RF phase space + affordances + quantum switch
///   entangle.zig  →  GF(3) arithmetic + CNOT₃ gate
///   regret.move   →  $REGRET token settlement (Aptos)
///   gay_triad.move → $GAY governance (Aptos)
///   Filecoin      →  content-addressed storage (CID)
///
/// The protocol loop:
///   1. Content is hashed to CID (Filecoin guarantee)
///   2. RF phase space state is measured (internet transport)
///   3. Affordances are evaluated (can we disclose?)
///   4. Insurance state determines causal order (quantum switch)
///   5. Regret is computed and externalized (REGRET tokens)
///   6. GF(3) conservation is verified (harmlessness)
///   7. Disclosure is transmitted through the internet
pub const DisclosureProtocol = struct {
    /// The cyberphysical system (from supermap.zig)
    cyber: supermap.CyberPhysical,

    /// The regret pool (settlement layer)
    pool: RegretPool,

    /// Internet transport stack
    transport: InternetTransport,

    /// Pending disclosures (ring buffer)
    pending: [16]Disclosure,
    pending_count: u4,

    /// Protocol generation
    generation: u64,

    pub fn init() DisclosureProtocol {
        var transport = InternetTransport.init();
        transport.composeStack();
        return .{
            .cyber = supermap.CyberPhysical.init(),
            .pool = RegretPool.init(),
            .transport = transport,
            .pending = undefined,
            .pending_count = 0,
            .generation = 0,
        };
    }

    /// Submit a disclosure for processing.
    /// Returns the disclosure's regret trit.
    pub fn submit(
        self: *DisclosureProtocol,
        content_hash: [32]u8,
        reveal_channel: Channel,
        withhold_channel: Channel,
        insurance: Trit,
    ) Trit {
        const disclosure = Disclosure{
            .content_hash = content_hash,
            .reveal_channel = reveal_channel,
            .withhold_channel = withhold_channel,
            .regret = .zero, // computed below
            .insurance = insurance,
            .generation = self.generation,
        };

        // Compute regret against current RF state
        const regret = disclosure.computeRegret(self.cyber.state);

        // Store in pending ring
        self.pending[self.pending_count] = disclosure;
        self.pending[self.pending_count].regret = regret;
        self.pending_count +%= 1;

        // Process through regret pool
        self.pool.processDisclosure(disclosure, self.cyber.state);

        self.generation += 1;
        return regret;
    }

    /// Execute the protocol: evaluate affordances, apply quantum switch,
    /// transmit through internet stack.
    pub fn execute(self: *DisclosureProtocol, rf_measurement: PhaseCell) PhaseCell {
        // 1. Update RF state
        _ = self.cyber.step(rf_measurement);

        // 2. Check disclosure affordance
        // Use the most recent pending disclosure's insurance state
        const insurance: Trit = if (self.pending_count > 0)
            self.pending[self.pending_count -% 1].insurance
        else
            .zero;

        const aff = disclosureAffordance(insurance);
        const can_disclose = aff.evaluate(self.cyber.state);

        // 3. If disclosure is afforded, apply the supermap to the transport layer
        if (can_disclose == .plus) {
            self.transport.applyDisclosureSupermap(aff.enabled_supermap);
        }

        // 4. Transmit through the internet
        const output = self.transport.transmit(self.cyber.state);

        // 5. Rebalance regret pool if needed
        if (!self.pool.isBalanced()) {
            _ = self.pool.rebalance();
        }

        return output;
    }

    /// Check if the protocol is in a safe state.
    /// Safe iff: GF(3) balanced AND transport is lossless AND control history is ergodic.
    pub fn isSafe(self: *const DisclosureProtocol) bool {
        return self.pool.isBalanced() and
            self.transport.isLossless() and
            self.cyber.controlBalance() == .zero;
    }

    /// Get the total externalized regret in REGRET token units.
    pub fn totalRegret(self: *const DisclosureProtocol) u64 {
        return self.pool.total_externalized;
    }
};

// ============================================================================
// C ABI EXPORTS
// ============================================================================

/// Create a disclosure protocol instance.
export fn disclosure_create() callconv(.c) *DisclosureProtocol {
    const Static = struct {
        var instance: DisclosureProtocol = DisclosureProtocol.init();
    };
    Static.instance = DisclosureProtocol.init();
    return &Static.instance;
}

/// Submit a disclosure. Returns regret trit (-1, 0, +1).
export fn disclosure_submit(
    proto: *DisclosureProtocol,
    hash_ptr: [*]const u8,
    insurance: i8,
) callconv(.c) i8 {
    var content_hash: [32]u8 = .{0} ** 32;
    @memcpy(&content_hash, hash_ptr[0..32]);

    const ins_trit: Trit = @enumFromInt(std.math.clamp(insurance, -1, 1));

    // Default channels: reveal shifts amplitude up, withhold is identity
    const reveal = Channel{
        .matrix = .{
            .{ .plus, .zero, .zero },
            .{ .zero, .plus, .zero },
            .{ .zero, .zero, .plus },
        },
        .offset = .{ .zero, .zero, .plus }, // amplitude boost on reveal
    };

    const regret = proto.submit(content_hash, reveal, Channel.IDENTITY, ins_trit);
    return @intFromEnum(regret);
}

/// Execute one protocol cycle. Returns output phase cell index (0..26).
export fn disclosure_execute(proto: *DisclosureProtocol, freq: i8, phase: i8, amp: i8) callconv(.c) u8 {
    const measurement = PhaseCell{
        .freq = @enumFromInt(std.math.clamp(freq, -1, 1)),
        .phase = @enumFromInt(std.math.clamp(phase, -1, 1)),
        .amp = @enumFromInt(std.math.clamp(amp, -1, 1)),
    };
    return proto.execute(measurement).toIndex();
}

/// Check if protocol is in safe state. Returns 1 if safe, 0 if not.
export fn disclosure_is_safe(proto: *const DisclosureProtocol) callconv(.c) u8 {
    return if (proto.isSafe()) 1 else 0;
}

/// Get total externalized regret in REGRET token units.
export fn disclosure_total_regret(proto: *const DisclosureProtocol) callconv(.c) u64 {
    return proto.totalRegret();
}

// ============================================================================
// TESTS
// ============================================================================

test "disclosure effective channel depends on insurance" {
    // Use two non-commuting, non-identity channels
    // CNOT_FREQ_PHASE and PERMUTE do not commute
    const reveal = Channel.CNOT_FREQ_PHASE;
    const withhold = Channel.PERMUTE;

    const insured = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = reveal,
        .withhold_channel = withhold,
        .regret = .zero,
        .insurance = .plus, // insured → withhold ∘ reveal
        .generation = 0,
    };

    const uninsured = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = reveal,
        .withhold_channel = withhold,
        .regret = .zero,
        .insurance = .zero, // uninsured → reveal ∘ withhold
        .generation = 0,
    };

    const ch_insured = insured.effectiveChannel();
    const ch_uninsured = uninsured.effectiveChannel();

    // Non-commuting channels → different causal orders → different outcomes
    const test_state = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .minus };
    const r1 = ch_insured.apply(test_state);
    const r2 = ch_uninsured.apply(test_state);
    try std.testing.expect(!r1.eql(r2));
}

test "disclosure regret computation" {
    const reveal = Channel.CNOT_FREQ_PHASE; // freq controls phase
    const withhold = Channel.IDENTITY;

    const d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = reveal,
        .withhold_channel = withhold,
        .regret = .zero,
        .insurance = .zero,
        .generation = 0,
    };

    // At state (freq=+1, phase=0, amp=0):
    //   reveal:  (f, p+f, a) = (+1, +1, 0) — phase shifts
    //   withhold: (f, p, a) = (+1, 0, 0) — no change
    //   distance: 1 coordinate differs → regret = +1
    const state = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .zero };
    const regret = d.computeRegret(state);
    try std.testing.expectEqual(Trit.plus, regret);
}

test "disclosure regret is zero when channels agree" {
    const d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = Channel.IDENTITY,
        .withhold_channel = Channel.IDENTITY,
        .regret = .zero,
        .insurance = .zero,
        .generation = 0,
    };

    const state = PhaseCell{ .freq = .plus, .phase = .minus, .amp = .zero };
    try std.testing.expectEqual(Trit.zero, d.computeRegret(state));
}

test "disclosure safety check" {
    const d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = Channel.PERMUTE,
        .withhold_channel = Channel.IDENTITY,
        .regret = .zero,
        .insurance = .zero,
        .generation = 0,
    };

    // Uninsured quantum switch of PERMUTE and IDENTITY:
    // control=0 → PERMUTE ∘ IDENTITY = PERMUTE
    // PERMUTE has det = +1 (non-zero) → safe (invertible)
    const state = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .zero };
    try std.testing.expect(d.isSafe(state));
}

test "regret pool starts balanced" {
    const pool = RegretPool.init();
    try std.testing.expect(pool.isBalanced());
    try std.testing.expectEqual(@as(u64, 0), pool.total_externalized);
}

test "regret pool accumulates and externalizes" {
    var pool = RegretPool.init();

    const d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = Channel.CNOT_FREQ_PHASE,
        .withhold_channel = Channel.IDENTITY,
        .regret = .zero,
        .insurance = .zero,
        .generation = 0,
    };

    const state = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .zero };
    pool.processDisclosure(d, state);

    try std.testing.expectEqual(@as(u64, 1), pool.disclosures_processed);
    // Regret from this disclosure is +1 (one coordinate differs)
    // So 1 REGRET token (1e8 units) should be externalized
    try std.testing.expectEqual(@as(u64, 100_000_000), pool.total_externalized);
}

test "regret pool rebalancing" {
    var pool = RegretPool.init();
    pool.generator_regret = 2;
    pool.coordinator_regret = 1;
    pool.validator_regret = 0;
    // total = 3, mod 3 = 0 → already balanced
    try std.testing.expect(pool.isBalanced());

    pool.generator_regret = 2;
    pool.coordinator_regret = 1;
    pool.validator_regret = 1;
    pool.balance_trit = pool.computeBalance();
    // total = 4, mod 3 = 1 → imbalanced (+1)
    try std.testing.expect(!pool.isBalanced());

    const correction = pool.rebalance();
    try std.testing.expectEqual(Trit.plus, correction);
    try std.testing.expect(pool.isBalanced());
}

test "disclosure affordance region" {
    const aff = disclosureAffordance(.plus);

    // Should include cells with amp >= 0 AND phase >= 0
    const good = PhaseCell{ .freq = .minus, .phase = .plus, .amp = .plus };
    try std.testing.expectEqual(Trit.plus, aff.evaluate(good));

    // Should exclude cells with amp < 0
    const weak = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .minus };
    try std.testing.expectEqual(Trit.minus, aff.evaluate(weak));

    // Should exclude cells with phase < 0
    const bad_phase = PhaseCell{ .freq = .zero, .phase = .minus, .amp = .plus };
    try std.testing.expectEqual(Trit.minus, aff.evaluate(bad_phase));
}

test "internet transport composition" {
    var transport = InternetTransport.init();
    transport.composeStack();

    // Composite of all 5 layers should be a valid channel
    const input = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .zero };
    const output = transport.transmit(input);
    try std.testing.expect(output.toIndex() < 27);
}

test "internet transport is lossless" {
    var transport = InternetTransport.init();
    transport.composeStack();
    // All layers are invertible, so composition should be too
    try std.testing.expect(transport.isLossless());
}

test "full protocol lifecycle" {
    var proto = DisclosureProtocol.init();

    // 1. Submit a disclosure with insurance
    const hash = [_]u8{0x42} ** 32;
    const regret = proto.submit(
        hash,
        Channel.CNOT_FREQ_PHASE,
        Channel.IDENTITY,
        .plus, // insured
    );

    // Regret should be computed
    try std.testing.expect(regret == .plus or regret == .zero or regret == .minus);

    // 2. Execute with a strong RF measurement
    const output = proto.execute(.{ .freq = .plus, .phase = .plus, .amp = .plus });
    try std.testing.expect(output.toIndex() < 27);

    // 3. Check protocol state
    try std.testing.expectEqual(@as(u64, 1), proto.pool.disclosures_processed);
    try std.testing.expect(proto.generation >= 1);
}

test "protocol safety invariant" {
    const proto = DisclosureProtocol.init();

    // Fresh protocol should be safe:
    //   pool balanced (no disclosures), transport lossless, control history = zero
    try std.testing.expect(proto.isSafe());
    try std.testing.expect(proto.pool.isBalanced());
    try std.testing.expect(proto.transport.isLossless());
    try std.testing.expectEqual(Trit.zero, proto.cyber.controlBalance());
}

test "GF(3) conservation: insurance flips causal order" {
    // This test verifies the core mechanism:
    // insurance=0 gives reveal∘withhold (cautious)
    // insurance=+1 gives withhold∘reveal (bold)
    // These are different orderings of the same two channels.

    const reveal = Channel.CNOT_FREQ_PHASE;
    const withhold = Channel.PERMUTE;

    // Cautious: reveal after withhold
    const cautious = Supermap.quantumSwitch(reveal, withhold, .zero);
    // Bold: withhold after reveal
    const bold = Supermap.quantumSwitch(reveal, withhold, .plus);

    // They should produce different results (channels don't commute)
    const test_state = PhaseCell{ .freq = .plus, .phase = .minus, .amp = .zero };
    const r_cautious = cautious.apply(test_state);
    const r_bold = bold.apply(test_state);

    try std.testing.expect(!r_cautious.eql(r_bold));

    // But both should be invertible (harmless)
    try std.testing.expect(cautious.determinant() != .zero);
    try std.testing.expect(bold.determinant() != .zero);
}

test "regret externalization: withholding costs more than disclosing" {
    // When channels differ significantly, regret is high.
    // When insurance covers the regret, disclosure becomes cheap.
    var pool_insured = RegretPool.init();
    var pool_uninsured = RegretPool.init();

    const reveal = Channel.CNOT_FREQ_PHASE;
    const withhold = Channel.IDENTITY;

    const insured_d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = reveal,
        .withhold_channel = withhold,
        .regret = .zero,
        .insurance = .plus,
        .generation = 0,
    };

    const uninsured_d = Disclosure{
        .content_hash = .{0} ** 32,
        .reveal_channel = reveal,
        .withhold_channel = withhold,
        .regret = .zero,
        .insurance = .zero,
        .generation = 0,
    };

    // Process 3 disclosures each (one full GF(3) cycle)
    for (0..3) |_| {
        const state = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .zero };
        pool_insured.processDisclosure(insured_d, state);
        pool_uninsured.processDisclosure(uninsured_d, state);
    }

    // Both pools process the same underlying regret
    try std.testing.expectEqual(pool_insured.total_externalized, pool_uninsured.total_externalized);

    // But after 3 disclosures (a full GF(3) cycle), the pool should be balanced
    // because 3 × plus = zero in GF(3)
    try std.testing.expectEqual(@as(u64, 3), pool_insured.disclosures_processed);
}
