//! ACP Extensions for mnx.fi Prediction Market
//!
//! Extends Agent Client Protocol with market-specific message types
//! for compositional game theory applications on mnx.fi.
//!
//! Architecture: Messages as open games with play/coplay semantics
//! - MarketStateUpdate: Forward market observation → agent strategy
//! - PositionOpenRequest: Agent action → market execution
//! - PortfolioSnapshot: Backward valuation → utility feedback
//! - BrickDiagramMeta: Compositional structure for parallel markets
//!
//! Integration: Lives in ACP.Message enum as discriminated union

const std = @import("std");
const syrup = @import("syrup");

const Allocator = std.mem.Allocator;

// ============================================================================
// Market Data Types (Play: Observations → Strategy)
// ============================================================================

/// Real-time market state observation
pub const MarketState = struct {
    market_id: []const u8,        // GPU_Utilization, CustomizationCost, InferenceSpeed
    timestamp_ms: i64,
    bid_price: f64,
    ask_price: f64,
    mid_price: f64,
    last_trade_price: f64,
    bid_volume: f64,
    ask_volume: f64,
    total_volume: f64,
    entropy: f64,                  // Shannon entropy of belief distribution
    open_interest: f64,

    pub fn toSyrup(self: MarketState, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 11);
        entries[0] = .{ .key = syrup.symbol("marketId"), .value = syrup.string(self.market_id) };
        entries[1] = .{ .key = syrup.symbol("timestampMs"), .value = syrup.number(self.timestamp_ms) };
        entries[2] = .{ .key = syrup.symbol("bidPrice"), .value = syrup.number(self.bid_price) };
        entries[3] = .{ .key = syrup.symbol("askPrice"), .value = syrup.number(self.ask_price) };
        entries[4] = .{ .key = syrup.symbol("midPrice"), .value = syrup.number(self.mid_price) };
        entries[5] = .{ .key = syrup.symbol("lastTradePrice"), .value = syrup.number(self.last_trade_price) };
        entries[6] = .{ .key = syrup.symbol("bidVolume"), .value = syrup.number(self.bid_volume) };
        entries[7] = .{ .key = syrup.symbol("askVolume"), .value = syrup.number(self.ask_volume) };
        entries[8] = .{ .key = syrup.symbol("totalVolume"), .value = syrup.number(self.total_volume) };
        entries[9] = .{ .key = syrup.symbol("entropy"), .value = syrup.number(self.entropy) };
        entries[10] = .{ .key = syrup.symbol("openInterest"), .value = syrup.number(self.open_interest) };
        return syrup.dictionary(entries);
    }
};

/// Market state broadcast (pushed from market, pulled by agents)
pub const MarketStateUpdate = struct {
    market_state: MarketState,
    market_maker_inventory: f64,   // MM position delta
    funding_rate: f64,             // Perpetual funding
    volatility: f64,               // Annualized IV

    pub fn toSyrup(self: MarketStateUpdate, allocator: Allocator) !syrup.Value {
        const state_syrup = try self.market_state.toSyrup(allocator);
        const entries = try allocator.alloc(syrup.Value.DictEntry, 4);
        entries[0] = .{ .key = syrup.symbol("marketState"), .value = state_syrup };
        entries[1] = .{ .key = syrup.symbol("marketMakerInventory"), .value = syrup.number(self.market_maker_inventory) };
        entries[2] = .{ .key = syrup.symbol("fundingRate"), .value = syrup.number(self.funding_rate) };
        entries[3] = .{ .key = syrup.symbol("volatility"), .value = syrup.number(self.volatility) };
        return syrup.dictionary(entries);
    }
};

// ============================================================================
// Trading Actions (Play: Strategy → Market Order)
// ============================================================================

/// Position direction in GF(3) framework
pub const PositionTrit = enum {
    short,           // -1 (RED): SHORT BIAS belief
    neutral,         // 0 (YELLOW): MARKET NEUTRAL arbitrage
    long,            // +1 (GREEN): LONG BIAS belief

    pub fn toSyrup(self: PositionTrit) syrup.Value {
        const name = switch (self) {
            .short => "short",
            .neutral => "neutral",
            .long => "long",
        };
        return syrup.symbol(name);
    }
};

/// Market order (limit order, stop loss, take profit)
pub const Order = struct {
    order_id: []const u8,          // UUID from agent
    market_id: []const u8,
    side: enum { buy, sell },
    order_type: enum { market, limit, stop_limit },
    quantity: f64,
    limit_price: ?f64 = null,
    stop_price: ?f64 = null,
    tif: enum { ioc, fok, gtc } = .gtc,  // Time in force
    leverage: ?f64 = null,         // For perpetuals

    pub fn toSyrup(self: Order, allocator: Allocator) !syrup.Value {
        const side_str = switch (self.side) { .buy => "buy", .sell => "sell" };
        const type_str = switch (self.order_type) {
            .market => "market",
            .limit => "limit",
            .stop_limit => "stopLimit"
        };
        const tif_str = switch (self.tif) {
            .ioc => "ioc",
            .fok => "fok",
            .gtc => "gtc"
        };

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("orderId"), .value = syrup.string(self.order_id) });
        try entries.append(.{ .key = syrup.symbol("marketId"), .value = syrup.string(self.market_id) });
        try entries.append(.{ .key = syrup.symbol("side"), .value = syrup.symbol(side_str) });
        try entries.append(.{ .key = syrup.symbol("orderType"), .value = syrup.symbol(type_str) });
        try entries.append(.{ .key = syrup.symbol("quantity"), .value = syrup.number(self.quantity) });
        if (self.limit_price) |p| try entries.append(.{ .key = syrup.symbol("limitPrice"), .value = syrup.number(p) });
        if (self.stop_price) |p| try entries.append(.{ .key = syrup.symbol("stopPrice"), .value = syrup.number(p) });
        try entries.append(.{ .key = syrup.symbol("tif"), .value = syrup.symbol(tif_str) });
        if (self.leverage) |lev| try entries.append(.{ .key = syrup.symbol("leverage"), .value = syrup.number(lev) });

        return syrup.dictionary(entries.items);
    }
};

/// Position opening request with GF(3) trifurcation strategy
pub const PositionOpenRequest = struct {
    session_id: []const u8,        // ACP session
    market_id: []const u8,
    position_trit: PositionTrit,   // Strategy: -1/0/+1
    size: f64,
    orders: []const Order,         // Market + limit orders
    rationale: ?[]const u8 = null, // Why this trit: empirical data/belief

    pub fn toSyrup(self: PositionOpenRequest, allocator: Allocator) !syrup.Value {
        var orders_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.orders) |order| {
            try orders_syrup.append(try order.toSyrup(allocator));
        }

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("sessionId"), .value = syrup.string(self.session_id) });
        try entries.append(.{ .key = syrup.symbol("marketId"), .value = syrup.string(self.market_id) });
        try entries.append(.{ .key = syrup.symbol("positionTrit"), .value = self.position_trit.toSyrup() });
        try entries.append(.{ .key = syrup.symbol("size"), .value = syrup.number(self.size) });
        try entries.append(.{ .key = syrup.symbol("orders"), .value = syrup.array(orders_syrup.items) });
        if (self.rationale) |r| try entries.append(.{ .key = syrup.symbol("rationale"), .value = syrup.string(r) });

        return syrup.dictionary(entries.items);
    }
};

/// Order execution result
pub const OrderFill = struct {
    order_id: []const u8,
    market_id: []const u8,
    filled_quantity: f64,
    average_fill_price: f64,
    commission: f64,
    timestamp_ms: i64,

    pub fn toSyrup(self: OrderFill, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 6);
        entries[0] = .{ .key = syrup.symbol("orderId"), .value = syrup.string(self.order_id) };
        entries[1] = .{ .key = syrup.symbol("marketId"), .value = syrup.string(self.market_id) };
        entries[2] = .{ .key = syrup.symbol("filledQuantity"), .value = syrup.number(self.filled_quantity) };
        entries[3] = .{ .key = syrup.symbol("averageFillPrice"), .value = syrup.number(self.average_fill_price) };
        entries[4] = .{ .key = syrup.symbol("commission"), .value = syrup.number(self.commission) };
        entries[5] = .{ .key = syrup.symbol("timestampMs"), .value = syrup.number(self.timestamp_ms) };
        return syrup.dictionary(entries);
    }
};

/// Response after position opening
pub const PositionOpenResponse = struct {
    request_id: []const u8,
    fills: []const OrderFill,
    total_cost: f64,
    position_id: []const u8,       // Assigned by market
    status: enum { filled, partial, rejected },
    error_message: ?[]const u8 = null,

    pub fn toSyrup(self: PositionOpenResponse, allocator: Allocator) !syrup.Value {
        var fills_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.fills) |fill| {
            try fills_syrup.append(try fill.toSyrup(allocator));
        }

        const status_str = switch (self.status) {
            .filled => "filled",
            .partial => "partial",
            .rejected => "rejected",
        };

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("requestId"), .value = syrup.string(self.request_id) });
        try entries.append(.{ .key = syrup.symbol("fills"), .value = syrup.array(fills_syrup.items) });
        try entries.append(.{ .key = syrup.symbol("totalCost"), .value = syrup.number(self.total_cost) });
        try entries.append(.{ .key = syrup.symbol("positionId"), .value = syrup.string(self.position_id) });
        try entries.append(.{ .key = syrup.symbol("status"), .value = syrup.symbol(status_str) });
        if (self.error_message) |e| try entries.append(.{ .key = syrup.symbol("error"), .value = syrup.string(e) });

        return syrup.dictionary(entries.items);
    }
};

// ============================================================================
// Portfolio State (Coplay: Utility Feedback → Next Strategy)
// ============================================================================

/// Single position valuation
pub const Position = struct {
    position_id: []const u8,
    market_id: []const u8,
    trit: PositionTrit,
    entry_price: f64,
    current_price: f64,
    quantity: f64,
    unrealized_pnl: f64,
    margin_used: f64,

    pub fn toSyrup(self: Position, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 8);
        entries[0] = .{ .key = syrup.symbol("positionId"), .value = syrup.string(self.position_id) };
        entries[1] = .{ .key = syrup.symbol("marketId"), .value = syrup.string(self.market_id) };
        entries[2] = .{ .key = syrup.symbol("trit"), .value = self.trit.toSyrup() };
        entries[3] = .{ .key = syrup.symbol("entryPrice"), .value = syrup.number(self.entry_price) };
        entries[4] = .{ .key = syrup.symbol("currentPrice"), .value = syrup.number(self.current_price) };
        entries[5] = .{ .key = syrup.symbol("quantity"), .value = syrup.number(self.quantity) };
        entries[6] = .{ .key = syrup.symbol("unrealizedPnl"), .value = syrup.number(self.unrealized_pnl) };
        entries[7] = .{ .key = syrup.symbol("marginUsed"), .value = syrup.number(self.margin_used) };
        return syrup.dictionary(entries);
    }
};

/// Portfolio snapshot with GF(3) balance constraint
pub const PortfolioSnapshot = struct {
    session_id: []const u8,
    timestamp_ms: i64,
    positions: []const Position,
    total_collateral: f64,
    available_margin: f64,
    margin_ratio: f64,
    total_unrealized_pnl: f64,
    gf3_balance: i64,              // sum(trits) mod 3, should be 0
    entropy: f64,                  // Portfolio entropy across positions

    pub fn toSyrup(self: PortfolioSnapshot, allocator: Allocator) !syrup.Value {
        var positions_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.positions) |pos| {
            try positions_syrup.append(try pos.toSyrup(allocator));
        }

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("sessionId"), .value = syrup.string(self.session_id) });
        try entries.append(.{ .key = syrup.symbol("timestampMs"), .value = syrup.number(self.timestamp_ms) });
        try entries.append(.{ .key = syrup.symbol("positions"), .value = syrup.array(positions_syrup.items) });
        try entries.append(.{ .key = syrup.symbol("totalCollateral"), .value = syrup.number(self.total_collateral) });
        try entries.append(.{ .key = syrup.symbol("availableMargin"), .value = syrup.number(self.available_margin) });
        try entries.append(.{ .key = syrup.symbol("marginRatio"), .value = syrup.number(self.margin_ratio) });
        try entries.append(.{ .key = syrup.symbol("totalUnrealizedPnl"), .value = syrup.number(self.total_unrealized_pnl) });
        try entries.append(.{ .key = syrup.symbol("gf3Balance"), .value = syrup.number(self.gf3_balance) });
        try entries.append(.{ .key = syrup.symbol("entropy"), .value = syrup.number(self.entropy) });

        return syrup.dictionary(entries.items);
    }
};

// ============================================================================
// Compositional Game Structure (Brick Diagrams)
// ============================================================================

/// Market composition metadata (for brick diagrams)
pub const BrickDiagramMeta = struct {
    diagram_id: []const u8,
    composition: enum {
        parallel,                  // ⊗: Independent markets
        sequential,                // ;: Order flow cascade
        composed,                  // ∘: Lens composition
    },
    markets: []const []const u8,   // Market IDs in composition
    players: []const enum {
        market_maker,
        long_trader,
        short_trader,
        arbitrageur
    },
    gf3_trits: []const i8,        // Trit for each player (-1, 0, +1)

    pub fn toSyrup(self: BrickDiagramMeta, allocator: Allocator) !syrup.Value {
        const comp_str = switch (self.composition) {
            .parallel => "parallel",
            .sequential => "sequential",
            .composed => "composed",
        };

        var markets_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.markets) |market| {
            try markets_syrup.append(syrup.string(market));
        }

        var players_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.players) |player| {
            const player_str = switch (player) {
                .market_maker => "marketMaker",
                .long_trader => "longTrader",
                .short_trader => "shortTrader",
                .arbitrageur => "arbitrageur",
            };
            try players_syrup.append(syrup.symbol(player_str));
        }

        var trits_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.gf3_trits) |trit| {
            try trits_syrup.append(syrup.number(trit));
        }

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("diagramId"), .value = syrup.string(self.diagram_id) });
        try entries.append(.{ .key = syrup.symbol("composition"), .value = syrup.symbol(comp_str) });
        try entries.append(.{ .key = syrup.symbol("markets"), .value = syrup.array(markets_syrup.items) });
        try entries.append(.{ .key = syrup.symbol("players"), .value = syrup.array(players_syrup.items) });
        try entries.append(.{ .key = syrup.symbol("gf3Trits"), .value = syrup.array(trits_syrup.items) });

        return syrup.dictionary(entries.items);
    }
};

// ============================================================================
// Session Mode (GF(3) Role Designation)
// ============================================================================

pub const SessionMode = enum {
    market_maker,      // 0 (ERGODIC/YELLOW): Provide liquidity, neutral
    long_bias,         // +1 (PLUS/GREEN): Accumulate bullish positions
    short_bias,        // -1 (MINUS/RED): Accumulate bearish positions
    arbitrageur,       // 0 (ERGODIC/YELLOW): Exploit spreads
    bifurcation,       // Mixed: Trifurcated agent with multiple roles

    pub fn toSyrup(self: SessionMode) syrup.Value {
        const name = switch (self) {
            .market_maker => "marketMaker",
            .long_bias => "longBias",
            .short_bias => "shortBias",
            .arbitrageur => "arbitrageur",
            .bifurcation => "bifurcation",
        };
        return syrup.symbol(name);
    }

    pub fn gf3Trit(self: SessionMode) i8 {
        return switch (self) {
            .market_maker => 0,
            .long_bias => 1,
            .short_bias => -1,
            .arbitrageur => 0,
            .bifurcation => 0,  // Mixed, depends on composition
        };
    }
};

// ============================================================================
// Settlement & Liquidation (OCapN Resource Coordination)
// ============================================================================

/// Arkhai resource liquidation event
pub const ArkaiLiquidation = struct {
    session_id: []const u8,
    margin_call_timestamp_ms: i64,
    liquidation_start_timestamp_ms: i64,
    margin_ratio_at_call: f64,
    positions_liquidated: []const Position,
    total_loss: f64,
    liquidation_fee: f64,
    arkhai_resource_claim: ?[]const u8 = null,  // OCapN promise

    pub fn toSyrup(self: ArkaiLiquidation, allocator: Allocator) !syrup.Value {
        var positions_syrup = std.ArrayList(syrup.Value).init(allocator);
        for (self.positions_liquidated) |pos| {
            try positions_syrup.append(try pos.toSyrup(allocator));
        }

        var entries = std.ArrayList(syrup.Value.DictEntry).init(allocator);
        try entries.append(.{ .key = syrup.symbol("sessionId"), .value = syrup.string(self.session_id) });
        try entries.append(.{ .key = syrup.symbol("marginCallTimestampMs"), .value = syrup.number(self.margin_call_timestamp_ms) });
        try entries.append(.{ .key = syrup.symbol("liquidationStartTimestampMs"), .value = syrup.number(self.liquidation_start_timestamp_ms) });
        try entries.append(.{ .key = syrup.symbol("marginRatioAtCall"), .value = syrup.number(self.margin_ratio_at_call) });
        try entries.append(.{ .key = syrup.symbol("positionsLiquidated"), .value = syrup.array(positions_syrup.items) });
        try entries.append(.{ .key = syrup.symbol("totalLoss"), .value = syrup.number(self.total_loss) });
        try entries.append(.{ .key = syrup.symbol("liquidationFee"), .value = syrup.number(self.liquidation_fee) });
        if (self.arkhai_resource_claim) |claim| {
            try entries.append(.{ .key = syrup.symbol("arkhaiResourceClaim"), .value = syrup.string(claim) });
        }

        return syrup.dictionary(entries.items);
    }
};

// ============================================================================
// Tests
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test MarketState
    var state = MarketState{
        .market_id = "GPU_Utilization",
        .timestamp_ms = 1707294600000,
        .bid_price = 49.5,
        .ask_price = 50.5,
        .mid_price = 50.0,
        .last_trade_price = 49.8,
        .bid_volume = 100.0,
        .ask_volume = 150.0,
        .total_volume = 50000.0,
        .entropy = 0.556,
        .open_interest = 5000.0,
    };

    const state_syrup = try state.toSyrup(allocator);
    std.debug.print("MarketState: {}\n", .{state_syrup});

    // Test PortfolioSnapshot with GF(3) balance
    var positions = std.ArrayList(Position).init(allocator);
    try positions.append(Position{
        .position_id = "pos_1",
        .market_id = "GPU_Utilization",
        .trit = .long,
        .entry_price = 49.0,
        .current_price = 50.2,
        .quantity = 100.0,
        .unrealized_pnl = 120.0,
        .margin_used = 2000.0,
    });
    try positions.append(Position{
        .position_id = "pos_2",
        .market_id = "CustomizationCost",
        .trit = .short,
        .entry_price = 0.25,
        .current_price = 0.24,
        .quantity = 1000.0,
        .unrealized_pnl = 10.0,
        .margin_used = 500.0,
    });

    var portfolio = PortfolioSnapshot{
        .session_id = "sess_mnxfi_001",
        .timestamp_ms = 1707294600000,
        .positions = positions.items,
        .total_collateral = 10000.0,
        .available_margin = 7500.0,
        .margin_ratio = 0.75,
        .total_unrealized_pnl = 130.0,
        .gf3_balance = 0,  // +1 (long) + (-1 (short) = 0 mod 3 ✓
        .entropy = 0.667,
    };

    const portfolio_syrup = try portfolio.toSyrup(allocator);
    std.debug.print("PortfolioSnapshot: {}\n", .{portfolio_syrup});

    std.debug.print("\n✅ ACP mnx.fi Extensions Phase 1 Complete\n", .{});
}
