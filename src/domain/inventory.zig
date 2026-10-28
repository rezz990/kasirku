const std = @import("std");
const money = @import("money.zig");

pub const Error = money.Error || error{ NegativeStock, StockOverflow, InsufficientStock };
pub const max_stock: i64 = money.max_quantity;

pub const Stock = union(enum) {
    untracked,
    tracked: i64,
};

pub fn init(quantity_milli: i64) Error!Stock {
    try validateTracked(quantity_milli);
    return .{ .tracked = quantity_milli };
}

pub fn sale(stock: Stock, quantity_milli: money.Quantity) Error!Stock {
    try money.validateQuantity(quantity_milli);
    return switch (stock) {
        .untracked => .untracked,
        .tracked => |available| blk: {
            try validateTracked(available);
            if (quantity_milli > available) return error.InsufficientStock;
            const remaining: i128 = @as(i128, available) - @as(i128, quantity_milli);
            break :blk .{ .tracked = @intCast(remaining) };
        },
    };
}

pub fn returnSale(stock: Stock, quantity_milli: money.Quantity) Error!Stock {
    try money.validateQuantity(quantity_milli);
    return switch (stock) {
        .untracked => .untracked,
        .tracked => |available| blk: {
            try validateTracked(available);
            const replenished: i128 = @as(i128, available) + @as(i128, quantity_milli);
            if (replenished > max_stock) return error.StockOverflow;
            break :blk .{ .tracked = @intCast(replenished) };
        },
    };
}

fn validateTracked(quantity_milli: i64) Error!void {
    if (quantity_milli < 0) return error.NegativeStock;
    if (quantity_milli > max_stock) return error.StockOverflow;
}

test "tracked stock accepts zero and the JavaScript safe maximum" {
    try std.testing.expectEqualDeep(Stock{ .tracked = 0 }, try init(0));
    try std.testing.expectEqualDeep(Stock{ .tracked = max_stock }, try init(max_stock));
    try std.testing.expectError(error.NegativeStock, init(-1));
    try std.testing.expectError(error.NegativeStock, init(std.math.minInt(i64)));
    try std.testing.expectError(error.StockOverflow, init(max_stock + 1));
    try std.testing.expectError(error.StockOverflow, init(std.math.maxInt(i64)));
}

test "fractional kilogram sale and return preserve exact milliunits" {
    const initial = try init(1_500);
    const sold = try sale(initial, 250);
    try std.testing.expectEqualDeep(Stock{ .tracked = 1_250 }, sold);
    try std.testing.expectEqualDeep(initial, try returnSale(sold, 250));
    const empty = try sale(initial, 1_500);
    try std.testing.expectEqualDeep(Stock{ .tracked = 0 }, empty);
    try std.testing.expectEqualDeep(initial, try returnSale(empty, 1_500));
}

test "insufficient stock is rejected without changing the original value" {
    const stock = try init(100);
    try std.testing.expectError(error.InsufficientStock, sale(stock, 101));
    try std.testing.expectEqualDeep(Stock{ .tracked = 100 }, stock);
    try std.testing.expectError(error.InsufficientStock, sale(try init(0), 1));
}

test "returns use wide addition and reject overflow" {
    try std.testing.expectEqualDeep(Stock{ .tracked = max_stock }, try returnSale(try init(max_stock - 1), 1));
    try std.testing.expectError(error.StockOverflow, returnSale(try init(max_stock), 1));
    try std.testing.expectError(error.StockOverflow, returnSale(try init(max_stock), max_stock));
    try std.testing.expectEqualDeep(Stock{ .tracked = 0 }, try sale(try init(max_stock), max_stock));
}

test "untracked services do not gain or consume stock" {
    try std.testing.expectEqualDeep(@as(Stock, .untracked), try sale(.untracked, 1));
    try std.testing.expectEqualDeep(@as(Stock, .untracked), try sale(.untracked, max_stock));
    try std.testing.expectEqualDeep(@as(Stock, .untracked), try returnSale(.untracked, 1_000));
    try std.testing.expectEqualDeep(@as(Stock, .untracked), try returnSale(.untracked, max_stock));
}

test "tracked and untracked stock still require valid positive sale and return quantities" {
    for ([_]Stock{ .untracked, .{ .tracked = 1_000 } }) |stock| {
        for ([_]i64{ 0, -1, std.math.minInt(i64) }) |quantity| {
            try std.testing.expectError(error.InvalidQuantity, sale(stock, quantity));
            try std.testing.expectError(error.InvalidQuantity, returnSale(stock, quantity));
        }
        try std.testing.expectError(error.QuantityOverflow, sale(stock, money.max_quantity + 1));
        try std.testing.expectError(error.QuantityOverflow, returnSale(stock, money.max_quantity + 1));
    }
}

test "directly constructed stock cannot bypass validation" {
    try std.testing.expectError(error.NegativeStock, sale(.{ .tracked = -1 }, 1));
    try std.testing.expectError(error.NegativeStock, returnSale(.{ .tracked = -1 }, 1));
    try std.testing.expectError(error.StockOverflow, sale(.{ .tracked = max_stock + 1 }, 1));
    try std.testing.expectError(error.StockOverflow, returnSale(.{ .tracked = max_stock + 1 }, 1));
}

test "10000 deterministic sale return combinations reconcile stock" {
    var combinations: usize = 0;
    for (0..100) |stock_index| {
        const available: i64 = @intCast(stock_index * 37);
        const initial = try init(available);
        for (0..100) |quantity_index| {
            const quantity: i64 = @intCast(quantity_index * 41 + 1);
            if (quantity <= available) {
                const sold = try sale(initial, quantity);
                try std.testing.expectEqual(available - quantity, sold.tracked);
                try std.testing.expectEqualDeep(initial, try returnSale(sold, quantity));
            } else {
                try std.testing.expectError(error.InsufficientStock, sale(initial, quantity));
            }
            const returned = try returnSale(initial, quantity);
            try std.testing.expectEqual(available + quantity, returned.tracked);
            try std.testing.expectEqualDeep(initial, try sale(returned, quantity));
            combinations += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 10_000), combinations);
}
