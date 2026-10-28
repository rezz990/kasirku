const std = @import("std");
const money = @import("money.zig");

pub const Error = money.Error || error{ DiscountExceedsBase, Underpayment };

pub const Discount = union(enum) {
    none,
    nominal: money.Amount,
    percent_bps: i64,
};

pub const ServiceCharge = union(enum) {
    none,
    nominal: money.Amount,
    percent_bps: i64,
};

pub const Tax = union(enum) {
    none,
    inclusive_bps: i64,
    exclusive_bps: i64,
};

pub const Line = struct {
    unit_price: money.Amount,
    quantity_milli: money.Quantity,
    discount: Discount = .none,
};

pub const LineTotals = struct {
    gross: money.Amount,
    discount: money.Amount,
    net: money.Amount,
};

pub const Options = struct {
    transaction_discount: Discount = .none,
    service_charge: ServiceCharge = .none,
    tax: Tax = .none,
    cash_rounding_increment: i64 = 1,
};

pub const Totals = struct {
    gross: money.Amount,
    line_discount: money.Amount,
    subtotal: money.Amount,
    transaction_discount: money.Amount,
    net_subtotal: money.Amount,
    service_charge: money.Amount,
    tax_base: money.Amount,
    tax: money.Amount,
    total_before_rounding: money.Amount,
    rounding_adjustment: i64,
    total: money.Amount,
};

pub const CashPayment = struct {
    amount_due: money.Amount,
    tendered: money.Amount,
    change: money.Amount,
};

pub fn discountAmount(base: money.Amount, discount: Discount) Error!money.Amount {
    try money.validate(base);
    const amount = switch (discount) {
        .none => 0,
        .nominal => |value| blk: {
            try money.validate(value);
            break :blk value;
        },
        .percent_bps => |rate| try money.rateAmount(base, rate),
    };
    if (amount > base) return error.DiscountExceedsBase;
    return amount;
}

pub fn calculateLine(line: Line) Error!LineTotals {
    const gross = try money.lineTotal(line.unit_price, line.quantity_milli);
    const discount = try discountAmount(gross, line.discount);
    return .{ .gross = gross, .discount = discount, .net = try money.subtract(gross, discount) };
}

pub fn calculate(lines: []const Line, options: Options) Error!Totals {
    try money.validateRoundingIncrement(options.cash_rounding_increment);
    var gross: money.Amount = 0;
    var line_discount: money.Amount = 0;
    for (lines) |line| {
        const totals = try calculateLine(line);
        gross = try money.add(gross, totals.gross);
        line_discount = try money.add(line_discount, totals.discount);
    }
    const subtotal = try money.subtract(gross, line_discount);
    const transaction_discount = try discountAmount(subtotal, options.transaction_discount);
    const net_subtotal = try money.subtract(subtotal, transaction_discount);
    const service_charge = try serviceChargeAmount(net_subtotal, options.service_charge);
    const amount_with_service = try money.add(net_subtotal, service_charge);
    var tax_base = amount_with_service;
    var tax: money.Amount = 0;
    switch (options.tax) {
        .none => {},
        .exclusive_bps => |rate| tax = try money.rateAmount(amount_with_service, rate),
        .inclusive_bps => |rate| {
            tax = try money.inclusiveTax(amount_with_service, rate);
            // Derive the base by subtraction so independently rounded tax cannot break reconciliation.
            tax_base = try money.subtract(amount_with_service, tax);
        },
    }
    const total_before_rounding = try money.add(tax_base, tax);
    const total = try money.roundCash(total_before_rounding, options.cash_rounding_increment);
    return .{
        .gross = gross,
        .line_discount = line_discount,
        .subtotal = subtotal,
        .transaction_discount = transaction_discount,
        .net_subtotal = net_subtotal,
        .service_charge = service_charge,
        .tax_base = tax_base,
        .tax = tax,
        .total_before_rounding = total_before_rounding,
        .rounding_adjustment = @intCast(@as(i128, total) - @as(i128, total_before_rounding)),
        .total = total,
    };
}

pub fn payCash(amount_due: money.Amount, tendered: money.Amount) Error!CashPayment {
    try money.validate(amount_due);
    try money.validate(tendered);
    if (tendered < amount_due) return error.Underpayment;
    return .{
        .amount_due = amount_due,
        .tendered = tendered,
        .change = try money.subtract(tendered, amount_due),
    };
}

fn serviceChargeAmount(base: money.Amount, charge: ServiceCharge) Error!money.Amount {
    return switch (charge) {
        .none => 0,
        .nominal => |value| blk: {
            try money.validate(value);
            break :blk value;
        },
        .percent_bps => |rate| money.rateAmount(base, rate),
    };
}

test "fractional quantity rounds the line before discount" {
    const result = try calculateLine(.{
        .unit_price = 15_001,
        .quantity_milli = 500,
        .discount = .{ .percent_bps = 5_000 },
    });
    try std.testing.expectEqual(@as(i64, 7_501), result.gross);
    try std.testing.expectEqual(@as(i64, 3_751), result.discount);
    try std.testing.expectEqual(@as(i64, 3_750), result.net);
}

test "line rounding is independent rather than rounding combined quantities" {
    const lines = [_]Line{
        .{ .unit_price = 1, .quantity_milli = 500 },
        .{ .unit_price = 1, .quantity_milli = 500 },
    };
    const result = try calculate(&lines, .{});
    try std.testing.expectEqual(@as(i64, 2), result.total);
}

test "line then transaction discounts then service and exclusive tax" {
    const lines = [_]Line{
        .{ .unit_price = 15_000, .quantity_milli = 500, .discount = .{ .nominal = 500 } },
        .{ .unit_price = 10_000, .quantity_milli = 1_000, .discount = .{ .percent_bps = 1_000 } },
    };
    const result = try calculate(&lines, .{
        .transaction_discount = .{ .percent_bps = 1_250 },
        .service_charge = .{ .percent_bps = 1_000 },
        .tax = .{ .exclusive_bps = 1_100 },
        .cash_rounding_increment = 100,
    });
    try std.testing.expectEqualDeep(Totals{
        .gross = 17_500,
        .line_discount = 1_500,
        .subtotal = 16_000,
        .transaction_discount = 2_000,
        .net_subtotal = 14_000,
        .service_charge = 1_400,
        .tax_base = 15_400,
        .tax = 1_694,
        .total_before_rounding = 17_094,
        .rounding_adjustment = 6,
        .total = 17_100,
    }, result);
    const payment = try payCash(result.total, 20_000);
    try std.testing.expectEqual(@as(i64, 2_900), payment.change);
}

test "nominal transaction discount follows percentage line discount" {
    const lines = [_]Line{.{ .unit_price = 101, .quantity_milli = 1_000, .discount = .{ .percent_bps = 5_000 } }};
    const result = try calculate(&lines, .{ .transaction_discount = .{ .nominal = 25 } });
    try std.testing.expectEqual(@as(i64, 51), result.line_discount);
    try std.testing.expectEqual(@as(i64, 50), result.subtotal);
    try std.testing.expectEqual(@as(i64, 25), result.total);
}

test "discounts reject negative nominal excess and invalid percent even on zero base" {
    try std.testing.expectError(error.NegativeAmount, discountAmount(100, .{ .nominal = -1 }));
    try std.testing.expectError(error.DiscountExceedsBase, discountAmount(100, .{ .nominal = 101 }));
    try std.testing.expectError(error.AmountOverflow, discountAmount(100, .{ .nominal = money.max_amount + 1 }));
    try std.testing.expectError(error.InvalidRate, discountAmount(0, .{ .percent_bps = -1 }));
    try std.testing.expectError(error.InvalidRate, discountAmount(0, .{ .percent_bps = 10_001 }));
    try std.testing.expectError(error.NegativeAmount, discountAmount(-1, .none));
    const lines = [_]Line{.{ .unit_price = 100, .quantity_milli = 1_000, .discount = .{ .nominal = 90 } }};
    try std.testing.expectError(error.DiscountExceedsBase, calculate(&lines, .{ .transaction_discount = .{ .nominal = 11 } }));
}

test "one hundred percent discounts reach zero without negative totals" {
    const lines = [_]Line{.{ .unit_price = 101, .quantity_milli = 1_000, .discount = .{ .percent_bps = 10_000 } }};
    const result = try calculate(&lines, .{
        .transaction_discount = .{ .percent_bps = 10_000 },
        .service_charge = .{ .percent_bps = 10_000 },
        .tax = .{ .exclusive_bps = 10_000 },
    });
    try std.testing.expectEqual(@as(i64, 101), result.line_discount);
    try std.testing.expectEqual(@as(i64, 0), result.total);
    const undiscounted = [_]Line{.{ .unit_price = 101, .quantity_milli = 1_000 }};
    const free = try calculate(&undiscounted, .{ .transaction_discount = .{ .percent_bps = 10_000 } });
    try std.testing.expectEqual(@as(i64, 0), free.total);
    try std.testing.expectEqual(@as(i64, 101), try discountAmount(101, .{ .nominal = 101 }));
}

test "inclusive tax includes service and does not increase the payable total" {
    const lines = [_]Line{.{ .unit_price = 10_000, .quantity_milli = 1_000 }};
    const result = try calculate(&lines, .{
        .service_charge = .{ .nominal = 1_100 },
        .tax = .{ .inclusive_bps = 1_100 },
    });
    try std.testing.expectEqual(@as(i64, 10_000), result.tax_base);
    try std.testing.expectEqual(@as(i64, 1_100), result.tax);
    try std.testing.expectEqual(@as(i64, 11_100), result.total);
}

test "tax boundaries include zero full rate and half up extraction" {
    const lines = [_]Line{.{ .unit_price = 1, .quantity_milli = 1_000 }};
    for ([_]Tax{ .none, .{ .inclusive_bps = 0 }, .{ .exclusive_bps = 0 } }) |tax| {
        const result = try calculate(&lines, .{ .tax = tax });
        try std.testing.expectEqual(@as(i64, 0), result.tax);
        try std.testing.expectEqual(@as(i64, 1), result.tax_base);
        try std.testing.expectEqual(@as(i64, 1), result.total);
    }
    const inclusive = try calculate(&lines, .{ .tax = .{ .inclusive_bps = 10_000 } });
    try std.testing.expectEqual(@as(i64, 1), inclusive.tax);
    try std.testing.expectEqual(@as(i64, 0), inclusive.tax_base);
    try std.testing.expectEqual(@as(i64, 1), inclusive.total);
    const exclusive = try calculate(&lines, .{ .tax = .{ .exclusive_bps = 10_000 } });
    try std.testing.expectEqual(@as(i64, 2), exclusive.total);
    const tie = try calculate(&lines, .{ .tax = .{ .exclusive_bps = 5_000 } });
    try std.testing.expectEqual(@as(i64, 1), tie.tax);
    for ([_]i64{ -1, 10_001, std.math.maxInt(i64) }) |rate| {
        try std.testing.expectError(error.InvalidRate, calculate(&lines, .{ .tax = .{ .inclusive_bps = rate } }));
        try std.testing.expectError(error.InvalidRate, calculate(&.{}, .{ .tax = .{ .exclusive_bps = rate } }));
    }
}

test "empty cart is zero and invalid options are not bypassed" {
    const empty = try calculate(&.{}, .{});
    try std.testing.expectEqual(@as(i64, 0), empty.gross);
    try std.testing.expectEqual(@as(i64, 0), empty.total);
    try std.testing.expectError(error.DiscountExceedsBase, calculate(&.{}, .{ .transaction_discount = .{ .nominal = 1 } }));
    try std.testing.expectError(error.NegativeAmount, calculate(&.{}, .{ .service_charge = .{ .nominal = -1 } }));
    try std.testing.expectError(error.InvalidRate, calculate(&.{}, .{ .service_charge = .{ .percent_bps = 10_001 } }));
    try std.testing.expectError(error.InvalidRoundingIncrement, calculate(&.{}, .{ .cash_rounding_increment = 25 }));
}

test "service can exceed its base but never exceed money bounds" {
    const lines = [_]Line{.{ .unit_price = 1, .quantity_milli = 1_000 }};
    const result = try calculate(&lines, .{ .service_charge = .{ .nominal = 100 } });
    try std.testing.expectEqual(@as(i64, 101), result.total);
    try std.testing.expectError(error.AmountOverflow, calculate(&lines, .{ .service_charge = .{ .nominal = money.max_amount } }));
    try std.testing.expectError(error.AmountOverflow, calculate(&.{}, .{ .service_charge = .{ .nominal = money.max_amount + 1 } }));
}

test "all cart boundaries reject negatives invalid quantity and overflow" {
    try std.testing.expectError(error.NegativeAmount, calculateLine(.{ .unit_price = -1, .quantity_milli = 1_000 }));
    try std.testing.expectError(error.InvalidQuantity, calculateLine(.{ .unit_price = 1, .quantity_milli = 0 }));
    try std.testing.expectError(error.InvalidQuantity, calculateLine(.{ .unit_price = 1, .quantity_milli = -1 }));
    try std.testing.expectError(error.QuantityOverflow, calculateLine(.{ .unit_price = 1, .quantity_milli = money.max_quantity + 1 }));
    const lines = [_]Line{.{ .unit_price = money.max_amount, .quantity_milli = 1_000 }};
    try std.testing.expectEqual(money.max_amount, (try calculate(&lines, .{})).total);
    try std.testing.expectError(error.AmountOverflow, calculate(&lines, .{ .tax = .{ .exclusive_bps = 1 } }));
    try std.testing.expectEqual(money.max_amount, (try calculate(&lines, .{ .tax = .{ .inclusive_bps = 10_000 } })).total);
    const too_large = lines ++ [_]Line{.{ .unit_price = 1, .quantity_milli = 1_000 }};
    try std.testing.expectError(error.AmountOverflow, calculate(&too_large, .{}));
}

test "cash payment uses the rounded payable total and rejects underpayment" {
    const lines = [_]Line{.{ .unit_price = 125, .quantity_milli = 1_000 }};
    const up = try calculate(&lines, .{ .cash_rounding_increment = 50 });
    try std.testing.expectEqual(@as(i64, 25), up.rounding_adjustment);
    try std.testing.expectError(error.Underpayment, payCash(up.total, 125));
    try std.testing.expectEqual(@as(i64, 0), (try payCash(up.total, 150)).change);
    const down = try calculate(&lines, .{ .cash_rounding_increment = 100 });
    try std.testing.expectEqual(@as(i64, -25), down.rounding_adjustment);
    try std.testing.expectEqual(@as(i64, 25), (try payCash(down.total, 125)).change);
    try std.testing.expectEqual(@as(i64, 0), (try payCash(0, 0)).change);
    try std.testing.expectEqual(money.max_amount, (try payCash(0, money.max_amount)).change);
    try std.testing.expectError(error.NegativeAmount, payCash(-1, 100));
    try std.testing.expectError(error.NegativeAmount, payCash(0, -1));
    try std.testing.expectError(error.AmountOverflow, payCash(0, money.max_amount + 1));
    try std.testing.expectError(error.AmountOverflow, payCash(money.max_amount + 1, money.max_amount));
}

test "11520 deterministic cart combinations reconcile discounts tax rounding and cash" {
    const prices = [_]i64{ 0, 1, 101, 12_500 };
    const quantities = [_]i64{ 1, 250, 1_000, 1_250 };
    const line_discounts = [_]Discount{ .none, .{ .nominal = 10 }, .{ .percent_bps = 1_250 }, .{ .percent_bps = 10_000 } };
    const transaction_discounts = [_]Discount{ .none, .{ .nominal = 17 }, .{ .percent_bps = 3_333 }, .{ .percent_bps = 10_000 } };
    const charges = [_]ServiceCharge{ .none, .{ .nominal = 51 }, .{ .percent_bps = 1_000 } };
    const taxes = [_]Tax{ .none, .{ .inclusive_bps = 1_100 }, .{ .exclusive_bps = 1_100 }, .{ .inclusive_bps = 10_000 }, .{ .exclusive_bps = 10_000 } };
    var combinations: usize = 0;
    for (prices) |price| {
        for (quantities) |quantity| {
            for (line_discounts) |configured_line_discount| {
                const line_discount: Discount = switch (configured_line_discount) {
                    .nominal => |amount| .{ .nominal = @min(amount, try money.lineTotal(price, quantity)) },
                    else => configured_line_discount,
                };
                const lines = [_]Line{
                    .{ .unit_price = price, .quantity_milli = quantity, .discount = line_discount },
                    .{ .unit_price = price + 7, .quantity_milli = quantity + 3, .discount = .{ .percent_bps = 500 } },
                };
                const first = try calculateLine(lines[0]);
                const second = try calculateLine(lines[1]);
                for (transaction_discounts) |configured_transaction_discount| {
                    const transaction_discount: Discount = switch (configured_transaction_discount) {
                        .nominal => |amount| .{ .nominal = @min(amount, first.net + second.net) },
                        else => configured_transaction_discount,
                    };
                    for (charges) |service_charge| {
                        for (taxes) |tax| {
                            for ([_]i64{ 1, 50, 100 }) |increment| {
                                const result = try calculate(&lines, .{
                                    .transaction_discount = transaction_discount,
                                    .service_charge = service_charge,
                                    .tax = tax,
                                    .cash_rounding_increment = increment,
                                });
                                try std.testing.expectEqual(first.gross + second.gross, result.gross);
                                try std.testing.expectEqual(first.discount + second.discount, result.line_discount);
                                try std.testing.expectEqual(first.net + second.net, result.subtotal);
                                try std.testing.expect(result.line_discount <= result.gross);
                                try std.testing.expect(result.transaction_discount <= result.subtotal);
                                try std.testing.expectEqual(result.gross - result.line_discount, result.subtotal);
                                try std.testing.expectEqual(result.subtotal - result.transaction_discount, result.net_subtotal);
                                const amount_with_service = result.net_subtotal + result.service_charge;
                                switch (tax) {
                                    .none => {
                                        try std.testing.expectEqual(@as(i64, 0), result.tax);
                                        try std.testing.expectEqual(amount_with_service, result.total_before_rounding);
                                    },
                                    .inclusive_bps => |rate| {
                                        const expected_tax: i64 = @intCast(@divTrunc(@as(i128, amount_with_service) * rate + @divTrunc(10_000 + rate, 2), 10_000 + rate));
                                        try std.testing.expectEqual(expected_tax, result.tax);
                                        try std.testing.expectEqual(amount_with_service, result.total_before_rounding);
                                    },
                                    .exclusive_bps => |rate| {
                                        const expected_tax: i64 = @intCast(@divTrunc(@as(i128, amount_with_service) * rate + 5_000, 10_000));
                                        try std.testing.expectEqual(expected_tax, result.tax);
                                        try std.testing.expectEqual(amount_with_service, result.tax_base);
                                        try std.testing.expectEqual(amount_with_service + result.tax, result.total_before_rounding);
                                    },
                                }
                                try std.testing.expectEqual(result.tax_base + result.tax, result.total_before_rounding);
                                try std.testing.expectEqual(result.total_before_rounding + result.rounding_adjustment, result.total);
                                try std.testing.expectEqual(@as(i64, 0), @mod(result.total, increment));
                                try std.testing.expect(result.rounding_adjustment >= -@divTrunc(increment, 2));
                                try std.testing.expect(result.rounding_adjustment <= @divTrunc(increment, 2));
                                inline for (std.meta.fields(Totals)) |field| {
                                    if (comptime !std.mem.eql(u8, field.name, "rounding_adjustment")) {
                                        try money.validate(@field(result, field.name));
                                    }
                                }
                                const payment = try payCash(result.total, result.total + 100);
                                try std.testing.expectEqual(@as(i64, 100), payment.change);
                                try std.testing.expectEqual(payment.tendered, payment.amount_due + payment.change);
                                if (result.total > 0) try std.testing.expectError(error.Underpayment, payCash(result.total, result.total - 1));
                                combinations += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 11_520), combinations);
}
