//! query.zig - Query language for Ewig
//!
//! SQL-like query interface:
//! - Event filtering: `type=PlayerAction AND player=Alice`
//! - Aggregation: `COUNT, SUM, AVG` over time ranges
//! - Temporal queries: `SINCE timestamp`, `UNTIL timestamp`
//! - State diff queries: `DIFF at t1 and t2`
//! - SQL-like interface

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const log = @import("log.zig");
const timeline = @import("timeline.zig");

const Hash = format.Hash;
const Event = log.Event;
const EventType = format.EventType;
const EventLog = log.EventLog;
const Timeline = timeline.Timeline;

// ============================================================================
// QUERY AST
// ============================================================================

/// Query expression AST
pub const Query = union(enum) {
    /// Select events matching criteria
    Select: SelectQuery,
    /// Aggregate over events
    Aggregate: AggregateQuery,
    /// Temporal query
    Temporal: TemporalQuery,
    /// State diff
    Diff: DiffQuery,
    /// Custom function
    Custom: CustomQuery,
    
    pub fn deinit(self: *Query, allocator: Allocator) void {
        switch (self.*) {
            .Select => |*q| q.deinit(allocator),
            .Aggregate => |*q| q.deinit(allocator),
            .Temporal => |*q| q.deinit(allocator),
            .Diff => |*q| q.deinit(allocator),
            .Custom => |*q| q.deinit(allocator),
        }
    }
};

pub const SelectQuery = struct {
    columns: []const []const u8,
    from: []const u8,
    where: ?*Expr,
    order_by: ?[]const OrderClause,
    limit: ?usize,
    
    pub fn deinit(self: *SelectQuery, allocator: Allocator) void {
        for (self.columns) |col| {
            allocator.free(col);
        }
        allocator.free(self.columns);
        allocator.free(self.from);
        if (self.where) |w| {
            w.deinit(allocator);
            allocator.destroy(w);
        }
        if (self.order_by) |ob| {
            for (ob) |o| {
                allocator.free(o.column);
            }
            allocator.free(ob);
        }
    }
};

pub const OrderClause = struct {
    column: []const u8,
    direction: enum { Asc, Desc },
};

pub const AggregateQuery = struct {
    function: AggregateFunction,
    column: []const u8,
    from: []const u8,
    where: ?*Expr,
    group_by: ?[]const []const u8,
    
    pub fn deinit(self: *AggregateQuery, allocator: Allocator) void {
        allocator.free(self.column);
        allocator.free(self.from);
        if (self.where) |w| {
            w.deinit(allocator);
            allocator.destroy(w);
        }
        if (self.group_by) |gb| {
            for (gb) |g| allocator.free(g);
            allocator.free(gb);
        }
    }
};

pub const AggregateFunction = enum {
    Count,
    Sum,
    Avg,
    Min,
    Max,
    First,
    Last,
};

pub const TemporalQuery = struct {
    query: *Query,
    since: ?i64,
    until: ?i64,
    window: ?TemporalWindow,
    
    pub fn deinit(self: *TemporalQuery, allocator: Allocator) void {
        self.query.deinit(allocator);
        allocator.destroy(self.query);
    }
};

pub const TemporalWindow = struct {
    duration: i64,
    step: i64,
};

pub const DiffQuery = struct {
    world_uri: []const u8,
    t1: i64,
    t2: i64,
    
    pub fn deinit(self: *DiffQuery, allocator: Allocator) void {
        allocator.free(self.world_uri);
    }
};

pub const CustomQuery = struct {
    name: []const u8,
    args: []const Value,
    
    pub fn deinit(self: *CustomQuery, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.args) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.args);
    }
};

// ============================================================================
// EXPRESSIONS
// ============================================================================

/// Expression for WHERE clauses
pub const Expr = union(enum) {
    Binary: BinaryExpr,
    Unary: UnaryExpr,
    Literal: Value,
    Column: []const u8,
    Function: FunctionExpr,
    
    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .Binary => |*b| b.deinit(allocator),
            .Unary => |*u| u.deinit(allocator),
            .Literal => |*l| l.deinit(allocator),
            .Column => |c| allocator.free(c),
            .Function => |*f| f.deinit(allocator),
        }
    }
    
    /// Evaluate expression against an event
    pub fn evaluate(self: Expr, event: Event) bool {
        switch (self) {
            .Binary => |b| {
                const left = b.left.evaluate(event);
                const right = b.right.evaluate(event);
                return switch (b.op) {
                    .And => left and right,
                    .Or => left or right,
                    .Eq => {
                        const lv = b.left.getValue(event);
                        const rv = b.right.getValue(event);
                        return lv.eql(rv);
                    },
                    .Neq => {
                        const lv = b.left.getValue(event);
                        const rv = b.right.getValue(event);
                        return !lv.eql(rv);
                    },
                    .Lt, .Gt, .Lte, .Gte => {
                        const lv = b.left.getValue(event);
                        const rv = b.right.getValue(event);
                        const cmp = lv.compare(rv);
                        return switch (b.op) {
                            .Lt => cmp == .lt,
                            .Gt => cmp == .gt,
                            .Lte => cmp == .lt or cmp == .eq,
                            .Gte => cmp == .gt or cmp == .eq,
                            else => unreachable,
                        };
                    },
                };
            },
            .Unary => |u| {
                const val = u.operand.evaluate(event);
                return switch (u.op) {
                    .Not => !val,
                };
            },
            .Literal => |l| switch (l) {
                .Bool => |b| b,
                else => false,
            },
            .Column => |c| {
                if (std.mem.eql(u8, c, "type")) {
                    return true; // Always true if column exists
                }
                return false;
            },
            .Function => return false, // Not implemented
        }
    }
    
    /// Get value from expression
    fn getValue(self: Expr, event: Event) Value {
        switch (self) {
            .Literal => |l| return l,
            .Column => |c| {
                if (std.mem.eql(u8, c, "type")) {
                    return .{ .String = @tagName(event.type) };
                } else if (std.mem.eql(u8, c, "timestamp")) {
                    return .{ .Int = event.timestamp };
                } else if (std.mem.eql(u8, c, "seq")) {
                    return .{ .Uint = event.seq };
                } else if (std.mem.eql(u8, c, "world_uri")) {
                    return .{ .String = event.world_uri };
                } else if (std.mem.eql(u8, c, "payload")) {
                    return .{ .String = event.payload };
                }
                return .{ .Null = {} };
            },
            else => return .{ .Null = {} },
        }
    }
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
    
    pub fn deinit(self: *BinaryExpr, allocator: Allocator) void {
        self.left.deinit(allocator);
        allocator.destroy(self.left);
        self.right.deinit(allocator);
        allocator.destroy(self.right);
    }
};

pub const BinaryOp = enum {
    And,
    Or,
    Eq,
    Neq,
    Lt,
    Gt,
    Lte,
    Gte,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    
    pub fn deinit(self: *UnaryExpr, allocator: Allocator) void {
        self.operand.deinit(allocator);
        allocator.destroy(self.operand);
    }
};

pub const UnaryOp = enum {
    Not,
};

pub const FunctionExpr = struct {
    name: []const u8,
    args: []*Expr,
    
    pub fn deinit(self: *FunctionExpr, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.args) |arg| {
            arg.deinit(allocator);
            allocator.destroy(arg);
        }
        allocator.free(self.args);
    }
};

/// Value types for query expressions
pub const Value = union(enum) {
    Null: void,
    Bool: bool,
    Int: i64,
    Uint: u64,
    Float: f64,
    String: []const u8,
    Bytes: []const u8,
    
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .String => |s| allocator.free(s),
            .Bytes => |b| allocator.free(b),
            else => {},
        }
    }
    
    pub fn eql(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        return switch (self) {
            .Null => true,
            .Bool => |a| a == other.Bool,
            .Int => |a| a == other.Int,
            .Uint => |a| a == other.Uint,
            .Float => |a| a == other.Float,
            .String => |a| std.mem.eql(u8, a, other.String),
            .Bytes => |a| std.mem.eql(u8, a, other.Bytes),
        };
    }
    
    pub fn compare(self: Value, other: Value) std.math.Order {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return .eq; // Different types can't be compared
        }
        return switch (self) {
            .Null => .eq,
            .Bool => |a| std.math.order(@intFromBool(a), @intFromBool(other.Bool)),
            .Int => |a| std.math.order(a, other.Int),
            .Uint => |a| std.math.order(a, other.Uint),
            .Float => |a| std.math.order(a, other.Float),
            .String => |a| std.mem.order(u8, a, other.String),
            .Bytes => |a| std.mem.order(u8, a, other.Bytes),
        };
    }
};

// ============================================================================
// QUERY EXECUTOR
// ============================================================================

/// Executes queries against event logs
pub const QueryExecutor = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Execute a query
    pub fn execute(self: Self, query: Query, event_log: *EventLog) !QueryResult {
        switch (query) {
            .Select => |s| return self.executeSelect(s, event_log),
            .Aggregate => |a| return self.executeAggregate(a, event_log),
            .Temporal => |t| return self.executeTemporal(t, event_log),
            .Diff => |d| return self.executeDiff(d),
            .Custom => |c| return self.executeCustom(c, event_log),
        }
    }
    
    fn executeSelect(self: Self, query: SelectQuery, event_log: *EventLog) !QueryResult {
        var results = std.ArrayList(Event).init(self.allocator);
        errdefer results.deinit();
        
        // Filter events
        var it = log.EventIterator.init(event_log, .Forward);
        while (it.next()) |event| {
            if (self.matchesWhere(event, query.where)) {
                try results.append(event);
            }
        }
        
        // Apply ordering
        if (query.order_by) |ob| {
            self.sortEvents(results.items, ob);
        }
        
        // Apply limit
        const limited = if (query.limit) |l|
            results.items[0..@min(l, results.items.len)]
        else
            results.items;
        
        return QueryResult{
            .events = try results.toOwnedSlice(),
            .count = limited.len,
            .aggregates = null,
            .allocator = self.allocator,
        };
    }
    
    fn executeAggregate(self: Self, query: AggregateQuery, event_log: *EventLog) !QueryResult {
        // Filter events
        var events = std.ArrayList(Event).init(self.allocator);
        defer events.deinit();
        
        var it = log.EventIterator.init(event_log, .Forward);
        while (it.next()) |event| {
            if (self.matchesWhere(event, query.where)) {
                try events.append(event);
            }
        }
        
        // Compute aggregate
        const value = self.computeAggregate(query.function, events.items, query.column);
        
        var aggregates = try self.allocator.alloc(AggregateValue, 1);
        aggregates[0] = .{
            .function = query.function,
            .column = try self.allocator.dupe(u8, query.column),
            .value = value,
        };
        
        return QueryResult{
            .events = &.{},
            .count = events.items.len,
            .aggregates = aggregates,
            .allocator = self.allocator,
        };
    }
    
    fn executeTemporal(self: Self, query: TemporalQuery, event_log: *EventLog) !QueryResult {
        // Apply time filter
        var filtered = std.ArrayList(Event).init(self.allocator);
        defer filtered.deinit();
        
        var it = log.EventIterator.init(event_log, .Forward);
        while (it.next()) |event| {
            if (query.since) |since| {
                if (event.timestamp < since) continue;
            }
            if (query.until) |until| {
                if (event.timestamp > until) continue;
            }
            try filtered.append(event);
        }
        
        // Execute inner query on filtered events
        // Simplified: just return filtered events
        _ = self;
        _ = query.query;
        
        return QueryResult{
            .events = try filtered.toOwnedSlice(),
            .count = filtered.items.len,
            .aggregates = null,
            .allocator = self.allocator,
        };
    }
    
    fn executeDiff(self: Self, query: DiffQuery) !QueryResult {
        _ = self;
        _ = query;
        // Would compute state diff between t1 and t2
        return error.NotImplemented;
    }
    
    fn executeCustom(self: Self, query: CustomQuery, event_log: *EventLog) !QueryResult {
        _ = self;
        _ = query;
        _ = event_log;
        return error.NotImplemented;
    }
    
    fn matchesWhere(self: Self, event: Event, where: ?*Expr) bool {
        _ = self;
        if (where) |w| {
            return w.evaluate(event);
        }
        return true;
    }
    
    fn sortEvents(self: Self, events: []Event, order_by: []const OrderClause) void {
        _ = self;
        if (order_by.len == 0) return;
        
        const primary = order_by[0];
        
        std.sort.insertion(Event, events, primary, struct {
            fn lessThan(ob: OrderClause, a: Event, b: Event) bool {
                const cmp = compareByColumn(a, b, ob.column);
                return if (ob.direction == .Asc) cmp == .lt else cmp == .gt;
            }
        }.lessThan);
    }
    
    fn computeAggregate(
        self: Self,
        func: AggregateFunction,
        events: []const Event,
        column: []const u8,
    ) Value {
        _ = self;
        _ = column;
        
        switch (func) {
            .Count => return .{ .Uint = @intCast(events.len) },
            .First => return if (events.len > 0) .{ .Uint = events[0].seq } else .{ .Null = {} },
            .Last => return if (events.len > 0) .{ .Uint = events[events.len - 1].seq } else .{ .Null = {} },
            .Min, .Max, .Sum, .Avg => return .{ .Null = {} }, // Would need column value extraction
        }
    }
};

fn compareByColumn(a: Event, b: Event, column: []const u8) std.math.Order {
    if (std.mem.eql(u8, column, "timestamp")) {
        return std.math.order(a.timestamp, b.timestamp);
    } else if (std.mem.eql(u8, column, "seq")) {
        return std.math.order(a.seq, b.seq);
    } else if (std.mem.eql(u8, column, "type")) {
        return std.mem.order(u8, @tagName(a.type), @tagName(b.type));
    }
    return .eq;
}

// ============================================================================
// QUERY RESULT
// ============================================================================

pub const QueryResult = struct {
    events: []const Event,
    count: usize,
    aggregates: ?[]AggregateValue,
    allocator: Allocator,
    
    pub fn deinit(self: *QueryResult) void {
        self.allocator.free(self.events);
        if (self.aggregates) |aggs| {
            for (aggs) |agg| {
                self.allocator.free(agg.column);
            }
            self.allocator.free(aggs);
        }
    }
    
    /// Convert to JSON
    pub fn toJson(self: QueryResult, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        
        const writer = output.writer();
        
        try writer.writeAll("{\n");
        try writer.print("  \"count\": {d},\n", .{self.count});
        
        // Write events
        try writer.writeAll("  \"events\": [\n");
        for (self.events, 0..) |event, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.print("      \"seq\": {d},\n", .{event.seq});
            try writer.print("      \"timestamp\": {d},\n", .{event.timestamp});
            try writer.print("      \"type\": \"{s}\",\n", .{@tagName(event.type)});
            try writer.print("      \"world_uri\": \"{s}\"\n", .{event.world_uri});
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ]");
        
        // Write aggregates
        if (self.aggregates) |aggs| {
            try writer.writeAll(",\n  \"aggregates\": [\n");
            for (aggs, 0..) |agg, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.writeAll("    {\n");
                try writer.print("      \"function\": \"{s}\",\n", .{@tagName(agg.function)});
                try writer.print("      \"column\": \"{s}\",\n", .{agg.column});
                try writer.writeAll("      \"value\": ");
                try writeValue(writer, agg.value);
                try writer.writeAll("\n    }");
            }
            try writer.writeAll("\n  ]");
        }
        
        try writer.writeAll("\n}");
        
        return output.toOwnedSlice();
    }
};

fn writeValue(writer: anytype, value: Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Bool => |b| try writer.print("{}", .{b}),
        .Int => |i| try writer.print("{d}", .{i}),
        .Uint => |u| try writer.print("{d}", .{u}),
        .Float => |f| try writer.print("{d}", .{f}),
        .String => |s| try writer.print("\"{s}\"", .{s}),
        .Bytes => |b| try writer.print("\"{}\", .{std.fmt.fmtSliceHexLower(b)}"),
    }
}

pub const AggregateValue = struct {
    function: AggregateFunction,
    column: []const u8,
    value: Value,
};

// ============================================================================
// QUERY PARSER
// ============================================================================

/// Parse SQL-like query string
pub const QueryParser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, input: []const u8) Self {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
        };
    }
    
    /// Parse a query string
    pub fn parse(self: *Self) !Query {
        self.skipWhitespace();
        
        if (self.matchKeyword("SELECT")) {
            return self.parseSelect();
        } else if (self.matchKeyword("COUNT")) {
            return self.parseAggregate(.Count);
        } else if (self.matchKeyword("SINCE") or self.matchKeyword("UNTIL")) {
            return self.parseTemporal();
        } else if (self.matchKeyword("DIFF")) {
            return self.parseDiff();
        }
        
        return error.InvalidQuery;
    }
    
    fn parseSelect(self: *Self) !Query {
        // Simplified parser
        var columns = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (columns.items) |c| self.allocator.free(c);
            columns.deinit();
        }
        
        try columns.append(try self.allocator.dupe(u8, "*"));
        
        // Parse FROM
        self.skipWhitespace();
        if (!self.matchKeyword("FROM")) return error.ExpectedFrom;
        
        self.skipWhitespace();
        const from = try self.parseIdentifier();
        
        // Parse optional WHERE
        var where: ?*Expr = null;
        self.skipWhitespace();
        if (self.matchKeyword("WHERE")) {
            where = try self.parseWhere();
        }
        
        return Query{
            .Select = .{
                .columns = try columns.toOwnedSlice(),
                .from = from,
                .where = where,
                .order_by = null,
                .limit = null,
            },
        };
    }
    
    fn parseAggregate(self: *Self, func: AggregateFunction) !Query {
        _ = self;
        _ = func;
        return error.NotImplemented;
    }
    
    fn parseTemporal(self: *Self) !Query {
        _ = self;
        return error.NotImplemented;
    }
    
    fn parseDiff(self: *Self) !Query {
        _ = self;
        return error.NotImplemented;
    }
    
    fn parseWhere(self: *Self) !*Expr {
        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        
        self.skipWhitespace();
        
        // Parse simple condition: column = value
        const column = try self.parseIdentifier();
        
        self.skipWhitespace();
        
        var op: BinaryOp = .Eq;
        if (self.match("=")) {
            op = .Eq;
        } else if (self.match("!=")) {
            op = .Neq;
        } else {
            return error.ExpectedOperator;
        }
        
        self.skipWhitespace();
        
        // Parse value
        const value = try self.parseValue();
        
        // Create column expression
        const col_expr = try self.allocator.create(Expr);
        col_expr.* = .{ .Column = column };
        
        // Create value expression
        const val_expr = try self.allocator.create(Expr);
        val_expr.* = .{ .Literal = value };
        
        // Create binary expression
        const bin = try self.allocator.create(BinaryExpr);
        bin.* = .{
            .op = op,
            .left = col_expr,
            .right = val_expr,
        };
        
        expr.* = .{ .Binary = bin.* };
        
        return expr;
    }
    
    fn parseIdentifier(self: *Self) ![]const u8 {
        self.skipWhitespace();
        
        const start = self.pos;
        while (self.pos < self.input.len and 
               (std.ascii.isAlphanumeric(self.input[self.pos]) or 
                self.input[self.pos] == '_' or
                self.input[self.pos] == ':')) {
            self.pos += 1;
        }
        
        if (self.pos == start) return error.ExpectedIdentifier;
        
        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }
    
    fn parseValue(self: *Self) !Value {
        self.skipWhitespace();
        
        if (self.pos >= self.input.len) return error.ExpectedValue;
        
        // String literal
        if (self.input[self.pos] == '\'' or self.input[self.pos] == '"') {
            const quote = self.input[self.pos];
            self.pos += 1;
            
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                self.pos += 1;
            }
            
            const str = self.input[start..self.pos];
            if (self.pos < self.input.len) self.pos += 1; // Skip closing quote
            
            return .{ .String = try self.allocator.dupe(u8, str) };
        }
        
        // Number
        if (std.ascii.isDigit(self.input[self.pos]) or self.input[self.pos] == '-') {
            const start = self.pos;
            if (self.input[self.pos] == '-') self.pos += 1;
            
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            
            const num = try std.fmt.parseInt(i64, self.input[start..self.pos], 10);
            return .{ .Int = num };
        }
        
        return error.InvalidValue;
    }
    
    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }
    
    fn matchKeyword(self: *Self, keyword: []const u8) bool {
        self.skipWhitespace();
        
        if (self.pos + keyword.len > self.input.len) return false;
        
        const slice = self.input[self.pos..self.pos + keyword.len];
        if (std.ascii.eqlIgnoreCase(slice, keyword)) {
            // Make sure it's a complete word
            const end = self.pos + keyword.len;
            if (end >= self.input.len or !std.ascii.isAlphabetic(self.input[end])) {
                self.pos += keyword.len;
                return true;
            }
        }
        
        return false;
    }
    
    fn match(self: *Self, s: []const u8) bool {
        self.skipWhitespace();
        
        if (self.pos + s.len > self.input.len) return false;
        
        if (std.mem.eql(u8, self.input[self.pos..self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        
        return false;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "expression evaluation" {
    const event = Event{
        .timestamp = 1000,
        .seq = 42,
        .hash = [_]u8{0xAA} ** 32,
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://world",
        .type = .PlayerAction,
        .payload = "{}",
    };
    
    // Test column expression
    const col_expr = Expr{ .Column = try testing.allocator.dupe(u8, "seq") };
    defer testing.allocator.free(col_expr.Column);
    
    const val = col_expr.getValue(event);
    try testing.expectEqual(@as(u64, 42), val.Uint);
}

test "query executor select" {
    var events = try EventLog.initInMemory(testing.allocator);
    defer events.deinit();
    
    _ = try events.append(.WorldCreated, "a://world", "{}");
    _ = try events.append(.PlayerAction, "a://world", "{\"action\":\"jump\"}");
    _ = try events.append(.StateChanged, "a://world", "{\"x\":1}");
    _ = try events.append(.PlayerAction, "a://world", "{\"action\":\"run\"}");
    
    const executor = QueryExecutor.init(testing.allocator);
    
    // Create simple query: SELECT * FROM events WHERE type = 'PlayerAction'
    const col_val = try testing.allocator.create(Expr);
    col_val.* = .{ .Column = try testing.allocator.dupe(u8, "type") };
    
    const str_val = try testing.allocator.create(Expr);
    str_val.* = .{ .Literal = .{ .String = try testing.allocator.dupe(u8, "PlayerAction") } };
    
    const bin = try testing.allocator.create(BinaryExpr);
    bin.* = .{
        .op = .Eq,
        .left = col_val,
        .right = str_val,
    };
    
    const where_expr = try testing.allocator.create(Expr);
    where_expr.* = .{ .Binary = bin.* };
    
    const query = Query{
        .Select = .{
            .columns = &.{"*"},
            .from = try testing.allocator.dupe(u8, "events"),
            .where = where_expr,
            .order_by = null,
            .limit = null,
        },
    };
    defer query.deinit(testing.allocator);
    
    var result = try executor.execute(query, &events);
    defer result.deinit();
    
    try testing.expectEqual(@as(usize, 2), result.count);
}

test "query parser" {
    var parser = QueryParser.init(testing.allocator, "SELECT * FROM events WHERE type = 'PlayerAction'");
    
    const query = try parser.parse();
    defer query.deinit(testing.allocator);
    
    try testing.expectEqual(@as(std.meta.Tag(Query), .Select), std.meta.activeTag(query));
}

test "query result to json" {
    const events = try testing.allocator.alloc(Event, 2);
    defer testing.allocator.free(events);
    
    events[0] = .{
        .timestamp = 1000,
        .seq = 1,
        .hash = [_]u8{0xAA} ** 32,
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://world",
        .type = .WorldCreated,
        .payload = "{}",
    };
    
    events[1] = .{
        .timestamp = 2000,
        .seq = 2,
        .hash = [_]u8{0xBB} ** 32,
        .parent = [_]u8{0xAA} ** 32,
        .world_uri = "a://world",
        .type = .StateChanged,
        .payload = "{}",
    };
    
    var result = QueryResult{
        .events = events,
        .count = 2,
        .aggregates = null,
        .allocator = testing.allocator,
    };
    
    const json = try result.toJson(testing.allocator);
    defer testing.allocator.free(json);
    
    try testing.expect(json.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "count"));
}
