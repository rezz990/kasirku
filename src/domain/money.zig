const std = @import("std");

pub const Amount = i64;
pub const Quantity = i64;

// The bridge can serialize these integers as JavaScript numbers without losing precision.
pub const max_amount: Amount = 9_000_000_000_000_000;
pub const max_quantity: Quantity = 9_000_000_000_000_000;
pub const milliunits_per_unit: i64 = 1_000;
pub const basis_points_per_whole: i64 = 10_000;

pub const Error = error{
    NegativeAmount,
    AmountOverflow,
    Underflow,
    InvalidQuantity,
    QuantityOverflow,
    InvalidRate,
    InvalidRoundingIncrement,
};

pub fn validate(amount: Amount) Error!void {
    if (amount < 0) return error.NegativeAmount;
    if (amount > max_amount) return error.AmountOverflow;
}

pub fn validateQuantity(quantity_milli: Quantity) Error!void {
    if (quantity_milli <= 0) return error.InvalidQuantity;
    if (quantity_milli > max_quantity) return error.QuantityOverflow;
}

pub fn validateRate(basis_points: i64) Error!void {
    if (basis_points < 0 or basis_points > basis_points_per_whole) return error.InvalidRate;
}

pub fn validateRoundingIncrement(increment: i64) Error!void {
    if (increment != 1 and increment != 50 and increment != 100) return error.InvalidRoundingIncrement;
}

pub fn add(a: Amount, b: Amount) Error!Amount {
    try validate(a);
    try validate(b);
    return bounded(@as(i128, a) + @as(i128, b));
}

pub fn subtract(a: Amount, b: Amount) Error!Amount {
    try validate(a);
    try validate(b);
    if (b > a) return error.Underflow;
    return bounded(@as(i128, a) - @as(i128, b));
}

pub fn lineTotal(unit_price: Amount, quantity_milli: Quantity) Error!Amount {
    try validate(unit_price);
    try validateQuantity(quantity_milli);
    return bounded(roundHalfUp(@as(i128, unit_price) * @as(i128, quantity_milli), milliunits_per_unit));
}

pub fn rateAmount(base: Amount, basis_points: i64) Error!Amount {
    try validate(base);
    try validateRate(basis_points);
    return bounded(roundHalfUp(@as(i128, base) * @as(i128, basis_points), basis_points_per_whole));
}

pub fn inclusiveTax(total_including_tax: Amount, basis_points: i64) Error!Amount {
    try validate(total_including_tax);
    try validateRate(basis_points);
    return bounded(roundHalfUp(
        @as(i128, total_including_tax) * @as(i128, basis_points),
        @as(i128, basis_points_per_whole) + @as(i128, basis_points),
    ));
}

pub fn roundCash(amount: Amount, increment: i64) Error!Amount {
    try validate(amount);
    try validateRoundingIncrement(increment);
    return bounded(roundHalfUp(amount, increment) * @as(i128, increment));
}

fn bounded(value: i128) Error!Amount {
    if (value < 0) return error.NegativeAmount;
    if (value > max_amount) return error.AmountOverflow;
    return @intCast(value);
}

fn roundHalfUp(numerator: i128, denominator: i128) i128 {
    return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
}

test "amount bounds remain nonnegative and JavaScript safe" {
    try validate(0);
    try validate(max_amount);
    try std.testing.expect(max_amount <= 9_007_199_254_740_991);
    try std.testing.expectError(error.NegativeAmount, validate(-1));
    try std.testing.expectError(error.NegativeAmount, validate(std.math.minInt(i64)));
    try std.testing.expectError(error.AmountOverflow, validate(max_amount + 1));
    try std.testing.expectError(error.AmountOverflow, validate(std.math.maxInt(i64)));
}

test "checked addition and subtraction reject invalid operands and overflow" {
    try std.testing.expectEqual(@as(Amount, max_amount), try add(max_amount - 1, 1));
    try std.testing.expectEqual(@as(Amount, 0), try subtract(max_amount, max_amount));
    try std.testing.expectError(error.AmountOverflow, add(max_amount, 1));
    try std.testing.expectError(error.AmountOverflow, add(max_amount, max_amount));
    try std.testing.expectError(error.Underflow, subtract(0, 1));
    try std.testing.expectError(error.NegativeAmount, add(-1, 1));
    try std.testing.expectError(error.NegativeAmount, subtract(1, -1));
    try std.testing.expectError(error.AmountOverflow, subtract(max_amount + 1, 1));
}

test "quantities are positive bounded integer milliunits" {
    try validateQuantity(1);
    try validateQuantity(max_quantity);
    try std.testing.expectError(error.InvalidQuantity, validateQuantity(0));
    try std.testing.expectError(error.InvalidQuantity, validateQuantity(-1));
    try std.testing.expectError(error.QuantityOverflow, validateQuantity(max_quantity + 1));
    try std.testing.expectError(error.InvalidQuantity, lineTotal(0, 0));
    try std.testing.expectError(error.NegativeAmount, lineTotal(-1, 1));
}

test "line totals round half up including fractional kilograms" {
    try std.testing.expectEqual(@as(Amount, 0), try lineTotal(1, 499));
    try std.testing.expectEqual(@as(Amount, 1), try lineTotal(1, 500));
    try std.testing.expectEqual(@as(Amount, 2), try lineTotal(1, 1_500));
    try std.testing.expectEqual(@as(Amount, 3_750), try lineTotal(15_000, 250));
    try std.testing.expectEqual(@as(Amount, 18_750), try lineTotal(15_000, 1_250));
    try std.testing.expectEqual(@as(Amount, 0), try lineTotal(0, max_quantity));
}

test "wide intermediates preserve valid money and reject oversized results" {
    try std.testing.expectEqual(max_amount, try lineTotal(max_amount, 1_000));
    try std.testing.expectEqual(max_amount, try rateAmount(max_amount, 10_000));
    try std.testing.expectEqual(@divTrunc(max_amount, 2), try inclusiveTax(max_amount, 10_000));
    try std.testing.expectError(error.AmountOverflow, lineTotal(max_amount, 1_001));
    try std.testing.expectError(error.AmountOverflow, lineTotal(max_amount, max_quantity));
}

test "basis point rates include zero and one hundred percent with half up ties" {
    try std.testing.expectEqual(@as(Amount, 0), try rateAmount(100, 0));
    try std.testing.expectEqual(@as(Amount, 100), try rateAmount(100, 10_000));
    try std.testing.expectEqual(@as(Amount, 1), try rateAmount(1, 5_000));
    try std.testing.expectEqual(@as(Amount, 0), try rateAmount(1, 4_999));
    try std.testing.expectError(error.InvalidRate, rateAmount(0, -1));
    try std.testing.expectError(error.InvalidRate, rateAmount(0, 10_001));
    try std.testing.expectError(error.InvalidRate, inclusiveTax(0, 10_001));
    try std.testing.expectError(error.NegativeAmount, inclusiveTax(-1, 0));
}

test "inclusive tax is extracted rather than added" {
    try std.testing.expectEqual(@as(Amount, 1_100), try inclusiveTax(11_100, 1_100));
    try std.testing.expectEqual(@as(Amount, 0), try inclusiveTax(11_100, 0));
    try std.testing.expectEqual(@as(Amount, 1), try inclusiveTax(1, 10_000));
    try std.testing.expectEqual(@as(Amount, 1), try inclusiveTax(3, 5_000));
    try std.testing.expectEqual(@as(Amount, 0), try inclusiveTax(0, 10_000));
}

test "cash rounds to supported increments with upward ties" {
    try std.testing.expectEqual(@as(Amount, 124), try roundCash(124, 1));
    try std.testing.expectEqual(@as(Amount, 100), try roundCash(124, 50));
    try std.testing.expectEqual(@as(Amount, 150), try roundCash(125, 50));
    try std.testing.expectEqual(@as(Amount, 100), try roundCash(149, 100));
    try std.testing.expectEqual(@as(Amount, 200), try roundCash(150, 100));
    try std.testing.expectEqual(@as(Amount, 0), try roundCash(0, 100));
    try std.testing.expectEqual(max_amount, try roundCash(max_amount - 1, 100));
    try std.testing.expectEqual(max_amount, try roundCash(max_amount, 50));
    for ([_]i64{ -100, 0, 2, 25, 200 }) |increment| {
        try std.testing.expectError(error.InvalidRoundingIncrement, roundCash(0, increment));
    }
    try std.testing.expectError(error.NegativeAmount, roundCash(-1, 1));
    try std.testing.expectError(error.AmountOverflow, roundCash(max_amount + 1, 100));
}
