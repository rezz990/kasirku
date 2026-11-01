const std = @import("std");
const sqlite = @import("../infra/db/sqlite.zig");
const pos = @import("pos.zig");
const Database = sqlite.Database;
const Allocator = std.mem.Allocator;

pub const HourBucket = struct { hour: u8, sale_count: i64, sales_total: i64 };
pub const ProductSales = struct {
    product_id: i64,
    name: []const u8,
    unit: []const u8,
    quantity_milli: i64,
    revenue: i64,
    cogs: i64,
    gross_profit: i64,
};
pub const StockAlert = struct {
    product_id: i64,
    name: []const u8,
    unit: []const u8,
    stock_milli: i64,
    min_stock_milli: i64,
};
pub const Dashboard = struct {
    date: []const u8,
    sale_count: i64,
    sales_total: i64,
    average_sale: i64,
    revenue: i64,
    cogs: i64,
    gross_profit: i64,
    hours: [24]HourBucket,
    top_products: []ProductSales,
    low_stock: []StockAlert,
};
pub const SalesGroup = struct {
    key: []const u8,
    product_id: ?i64,
    unit: []const u8,
    sale_count: i64,
    quantity_milli: i64,
    revenue: i64,
    cogs: i64,
    gross_profit: i64,
};
pub const SalesReport = struct {
    from: []const u8,
    to: []const u8,
    group_by: []const u8,
    sale_count: i64,
    sales_total: i64,
    revenue: i64,
    cogs: i64,
    gross_profit: i64,
    groups: []SalesGroup,
    has_more: bool,
};
pub const ExpenseCategory = struct { category: []const u8, amount: i64 };
pub const ProfitReport = struct {
    from: []const u8,
    to: []const u8,
    revenue: i64,
    cogs: i64,
    gross_profit: i64,
    expense_total: i64,
    net_profit: i64,
    expense_categories: []ExpenseCategory,
    has_more: bool,
};
pub const StockItem = struct {
    product_id: i64,
    name: []const u8,
    category: []const u8,
    unit: []const u8,
    cost: i64,
    stock_milli: ?i64,
    min_stock_milli: ?i64,
    stock_value: i64,
    last_sold_at: ?[]const u8,
    low_stock: bool,
    dead_stock: bool,
};
pub const StockReport = struct {
    filter: []const u8,
    total_products: i64,
    tracked_products: i64,
    low_stock_count: i64,
    dead_stock_count: i64,
    stock_value: i64,
    products: []StockItem,
    has_more: bool,
};

const valued_items =
    \\WITH valued AS (
    \\SELECT si.sale_id,si.product_id,si.name,si.category,si.unit,si.quantity_milli,s.sale_date,s.created_at,
    \\si.net-CASE WHEN s.subtotal=0 THEN 0 ELSE
    \\SUM(si.net) OVER (PARTITION BY si.sale_id ORDER BY si.position ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)*s.transaction_discount/s.subtotal-
    \\COALESCE(SUM(si.net) OVER (PARTITION BY si.sale_id ORDER BY si.position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)*s.transaction_discount/s.subtotal END AS revenue,
    \\(si.unit_cost*si.quantity_milli+500)/1000 AS cogs
    \\FROM sale_item si JOIN sale s ON s.id=si.sale_id
    \\)
;

const stock_source =
    \\WITH inventory AS (
    \\SELECT p.id,p.name,p.category,p.unit,p.cost,p.stock_milli,p.min_stock_milli,
    \\(SELECT MAX(s.created_at) FROM sale_item si JOIN sale s ON s.id=si.sale_id WHERE si.product_id=p.id) AS last_sold_at,
    \\CASE WHEN p.stock_milli IS NULL THEN 0 ELSE (p.cost*p.stock_milli+500)/1000 END AS stock_value,
    \\CASE WHEN p.stock_milli IS NOT NULL AND p.min_stock_milli IS NOT NULL AND p.stock_milli<=p.min_stock_milli THEN 1 ELSE 0 END AS low_stock,
    \\CASE WHEN p.stock_milli IS NOT NULL AND ((SELECT MAX(s.created_at) FROM sale_item si JOIN sale s ON s.id=si.sale_id WHERE si.product_id=p.id) IS NULL OR
    \\(SELECT MAX(s.created_at) FROM sale_item si JOIN sale s ON s.id=si.sale_id WHERE si.product_id=p.id)<strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days')) THEN 1 ELSE 0 END AS dead_stock
    \\FROM product p WHERE p.active=1
    \\)
;

fn beginRead(db: Database) !bool {
    if (sqlite.c.sqlite3_get_autocommit(db.handle) == 0) return false;
    try db.exec("BEGIN;");
    return true;
}
fn rollback(db: Database, started: bool) void {
    if (started) db.exec("ROLLBACK;") catch {};
}
fn validateRange(from: []const u8, to: []const u8) !void {
    try pos.validateDate(from);
    try pos.validateDate(to);
    if (std.mem.order(u8, from, to) == .gt) return error.InvalidQuery;
}
fn saleSummary(db: Database, from: []const u8, to: []const u8, single_day: bool) !struct { sale_count: i64, sales_total: i64, revenue: i64, cogs: i64 } {
    const sales_sql = if (single_day)
        "SELECT count(*),coalesce(sum(total),0),coalesce(sum(net_subtotal),0) FROM sale WHERE sale_date=?1;"
    else
        "SELECT count(*),coalesce(sum(total),0),coalesce(sum(net_subtotal),0) FROM sale WHERE sale_date BETWEEN ?1 AND ?2;";
    const sale_statement = try db.prepare(sales_sql);
    defer sale_statement.close();
    try sale_statement.bindText(1, from);
    if (!single_day) try sale_statement.bindText(2, to);
    if (!try sale_statement.next()) return error.NoResult;
    const cogs_sql = if (single_day)
        valued_items ++ " SELECT coalesce(sum(cogs),0) FROM valued WHERE sale_date=?1;"
    else
        valued_items ++ " SELECT coalesce(sum(cogs),0) FROM valued WHERE sale_date BETWEEN ?1 AND ?2;";
    const costs = try db.prepare(cogs_sql);
    defer costs.close();
    try costs.bindText(1, from);
    if (!single_day) try costs.bindText(2, to);
    if (!try costs.next()) return error.NoResult;
    return .{ .sale_count = sale_statement.columnInt(0), .sales_total = sale_statement.columnInt(1), .revenue = sale_statement.columnInt(2), .cogs = costs.columnInt(0) };
}

pub fn dashboard(db: Database, a: Allocator, date: []const u8) !Dashboard {
    if (date.len != 0) try pos.validateDate(date);
    const started = try beginRead(db);
    errdefer rollback(db, started);
    const selected = if (date.len == 0) try db.text(a, "SELECT date('now','localtime');") else date;
    const totals = try saleSummary(db, selected, selected, true);
    var result = Dashboard{
        .date = selected,
        .sale_count = totals.sale_count,
        .sales_total = totals.sales_total,
        .average_sale = if (totals.sale_count == 0) 0 else @divTrunc(totals.sales_total + @divTrunc(totals.sale_count, 2), totals.sale_count),
        .revenue = totals.revenue,
        .cogs = totals.cogs,
        .gross_profit = totals.revenue - totals.cogs,
        .hours = undefined,
        .top_products = &.{},
        .low_stock = &.{},
    };
    for (&result.hours, 0..) |*bucket, hour| bucket.* = .{ .hour = @intCast(hour), .sale_count = 0, .sales_total = 0 };
    {
        const s = try db.prepare("SELECT CAST(strftime('%H',created_at,'localtime') AS INTEGER),count(*),sum(total) FROM sale WHERE sale_date=? GROUP BY 1;");
        defer s.close();
        try s.bindText(1, selected);
        while (try s.next()) {
            const hour: usize = @intCast(s.columnInt(0));
            result.hours[hour].sale_count = s.columnInt(1);
            result.hours[hour].sales_total = s.columnInt(2);
        }
    }
    {
        const s = try db.prepare(valued_items ++ " SELECT v.product_id,p.name,p.unit,sum(v.quantity_milli),sum(v.revenue),sum(v.cogs),sum(v.revenue)-sum(v.cogs) FROM valued v JOIN product p ON p.id=v.product_id WHERE v.sale_date=? GROUP BY v.product_id,p.name,p.unit ORDER BY sum(v.revenue) DESC,v.product_id LIMIT 5;");
        defer s.close();
        try s.bindText(1, selected);
        var items: std.ArrayList(ProductSales) = .empty;
        while (try s.next()) try items.append(a, try readProductSales(s, a));
        result.top_products = items.items;
    }
    {
        const s = try db.prepare("SELECT id,name,unit,stock_milli,min_stock_milli FROM product WHERE active=1 AND stock_milli IS NOT NULL AND min_stock_milli IS NOT NULL AND stock_milli<=min_stock_milli ORDER BY stock_milli-min_stock_milli,name COLLATE NOCASE,id LIMIT 10;");
        defer s.close();
        var items: std.ArrayList(StockAlert) = .empty;
        while (try s.next()) try items.append(a, .{
            .product_id = s.columnInt(0),
            .name = try a.dupe(u8, s.columnText(1)),
            .unit = try a.dupe(u8, s.columnText(2)),
            .stock_milli = s.columnInt(3),
            .min_stock_milli = s.columnInt(4),
        });
        result.low_stock = items.items;
    }
    if (started) try db.exec("COMMIT;");
    return result;
}

fn readProductSales(s: sqlite.Statement, a: Allocator) !ProductSales {
    return .{
        .product_id = s.columnInt(0),
        .name = try a.dupe(u8, s.columnText(1)),
        .unit = try a.dupe(u8, s.columnText(2)),
        .quantity_milli = s.columnInt(3),
        .revenue = s.columnInt(4),
        .cogs = s.columnInt(5),
        .gross_profit = s.columnInt(6),
    };
}

pub fn sales(db: Database, a: Allocator, from: []const u8, to: []const u8, group_by: []const u8, offset: i64) !SalesReport {
    try validateRange(from, to);
    try pos.validateOffset(offset);
    const group = if (std.mem.eql(u8, group_by, "day")) "day" else if (std.mem.eql(u8, group_by, "product")) "product" else if (std.mem.eql(u8, group_by, "category")) "category" else return error.InvalidQuery;
    const started = try beginRead(db);
    errdefer rollback(db, started);
    const totals = try saleSummary(db, from, to, false);
    const query = if (std.mem.eql(u8, group, "day"))
        valued_items ++ " SELECT sale_date,NULL,'',count(DISTINCT sale_id),sum(quantity_milli),sum(revenue),sum(cogs),sum(revenue)-sum(cogs) FROM valued WHERE sale_date BETWEEN ?1 AND ?2 GROUP BY sale_date ORDER BY sale_date DESC LIMIT 51 OFFSET ?3;"
    else if (std.mem.eql(u8, group, "product"))
        valued_items ++ " SELECT p.name,v.product_id,p.unit,count(DISTINCT v.sale_id),sum(v.quantity_milli),sum(v.revenue),sum(v.cogs),sum(v.revenue)-sum(v.cogs) FROM valued v JOIN product p ON p.id=v.product_id WHERE v.sale_date BETWEEN ?1 AND ?2 GROUP BY v.product_id,p.name,p.unit ORDER BY sum(v.revenue) DESC,v.product_id LIMIT 51 OFFSET ?3;"
    else
        valued_items ++ " SELECT category,NULL,'',count(DISTINCT sale_id),sum(quantity_milli),sum(revenue),sum(cogs),sum(revenue)-sum(cogs) FROM valued WHERE sale_date BETWEEN ?1 AND ?2 GROUP BY category ORDER BY sum(revenue) DESC,category LIMIT 51 OFFSET ?3;";
    const s = try db.prepare(query);
    defer s.close();
    try s.bindText(1, from);
    try s.bindText(2, to);
    try s.bindInt(3, offset);
    var groups: std.ArrayList(SalesGroup) = .empty;
    var has_more = false;
    while (try s.next()) {
        if (groups.items.len == 50) {
            has_more = true;
            break;
        }
        try groups.append(a, .{
            .key = try a.dupe(u8, s.columnText(0)),
            .product_id = if (s.isNull(1)) null else s.columnInt(1),
            .unit = try a.dupe(u8, s.columnText(2)),
            .sale_count = s.columnInt(3),
            .quantity_milli = s.columnInt(4),
            .revenue = s.columnInt(5),
            .cogs = s.columnInt(6),
            .gross_profit = s.columnInt(7),
        });
    }
    if (started) try db.exec("COMMIT;");
    return .{
        .from = from,
        .to = to,
        .group_by = group,
        .sale_count = totals.sale_count,
        .sales_total = totals.sales_total,
        .revenue = totals.revenue,
        .cogs = totals.cogs,
        .gross_profit = totals.revenue - totals.cogs,
        .groups = groups.items,
        .has_more = has_more,
    };
}

pub fn profit(db: Database, a: Allocator, from: []const u8, to: []const u8, offset: i64) !ProfitReport {
    try validateRange(from, to);
    try pos.validateOffset(offset);
    const started = try beginRead(db);
    errdefer rollback(db, started);
    const totals = try saleSummary(db, from, to, false);
    const expense_total = blk: {
        const s = try db.prepare("SELECT coalesce(sum(amount),0) FROM cash_entry WHERE kind='out' AND date(created_at,'localtime') BETWEEN ?1 AND ?2;");
        defer s.close();
        try s.bindText(1, from);
        try s.bindText(2, to);
        if (!try s.next()) return error.NoResult;
        break :blk s.columnInt(0);
    };
    const s = try db.prepare("SELECT category,sum(amount) FROM cash_entry WHERE kind='out' AND date(created_at,'localtime') BETWEEN ?1 AND ?2 GROUP BY category ORDER BY sum(amount) DESC,category LIMIT 51 OFFSET ?3;");
    defer s.close();
    try s.bindText(1, from);
    try s.bindText(2, to);
    try s.bindInt(3, offset);
    var categories: std.ArrayList(ExpenseCategory) = .empty;
    var has_more = false;
    while (try s.next()) {
        if (categories.items.len == 50) {
            has_more = true;
            break;
        }
        try categories.append(a, .{ .category = try a.dupe(u8, s.columnText(0)), .amount = s.columnInt(1) });
    }
    if (started) try db.exec("COMMIT;");
    return .{
        .from = from,
        .to = to,
        .revenue = totals.revenue,
        .cogs = totals.cogs,
        .gross_profit = totals.revenue - totals.cogs,
        .expense_total = expense_total,
        .net_profit = totals.revenue - totals.cogs - expense_total,
        .expense_categories = categories.items,
        .has_more = has_more,
    };
}

pub fn stock(db: Database, a: Allocator, filter: []const u8, offset: i64) !StockReport {
    try pos.validateOffset(offset);
    if (!std.mem.eql(u8, filter, "all") and !std.mem.eql(u8, filter, "low") and !std.mem.eql(u8, filter, "dead")) return error.InvalidQuery;
    const started = try beginRead(db);
    errdefer rollback(db, started);
    var result = StockReport{ .filter = filter, .total_products = 0, .tracked_products = 0, .low_stock_count = 0, .dead_stock_count = 0, .stock_value = 0, .products = &.{}, .has_more = false };
    {
        const s = try db.prepare(stock_source ++ " SELECT count(*),sum(stock_milli IS NOT NULL),sum(low_stock),sum(dead_stock),sum(stock_value) FROM inventory;");
        defer s.close();
        if (!try s.next()) return error.NoResult;
        result.total_products = s.columnInt(0);
        result.tracked_products = s.columnInt(1);
        result.low_stock_count = s.columnInt(2);
        result.dead_stock_count = s.columnInt(3);
        result.stock_value = s.columnInt(4);
    }
    const query = if (std.mem.eql(u8, filter, "low"))
        stock_source ++ " SELECT id,name,category,unit,cost,stock_milli,min_stock_milli,stock_value,last_sold_at,low_stock,dead_stock FROM inventory WHERE low_stock=1 ORDER BY low_stock DESC,dead_stock DESC,name COLLATE NOCASE,id LIMIT 51 OFFSET ?1;"
    else if (std.mem.eql(u8, filter, "dead"))
        stock_source ++ " SELECT id,name,category,unit,cost,stock_milli,min_stock_milli,stock_value,last_sold_at,low_stock,dead_stock FROM inventory WHERE dead_stock=1 ORDER BY low_stock DESC,dead_stock DESC,name COLLATE NOCASE,id LIMIT 51 OFFSET ?1;"
    else
        stock_source ++ " SELECT id,name,category,unit,cost,stock_milli,min_stock_milli,stock_value,last_sold_at,low_stock,dead_stock FROM inventory ORDER BY low_stock DESC,dead_stock DESC,name COLLATE NOCASE,id LIMIT 51 OFFSET ?1;";
    const s = try db.prepare(query);
    defer s.close();
    try s.bindInt(1, offset);
    var products: std.ArrayList(StockItem) = .empty;
    while (try s.next()) {
        if (products.items.len == 50) {
            result.has_more = true;
            break;
        }
        try products.append(a, .{
            .product_id = s.columnInt(0),
            .name = try a.dupe(u8, s.columnText(1)),
            .category = try a.dupe(u8, s.columnText(2)),
            .unit = try a.dupe(u8, s.columnText(3)),
            .cost = s.columnInt(4),
            .stock_milli = if (s.isNull(5)) null else s.columnInt(5),
            .min_stock_milli = if (s.isNull(6)) null else s.columnInt(6),
            .stock_value = s.columnInt(7),
            .last_sold_at = if (s.isNull(8)) null else try a.dupe(u8, s.columnText(8)),
            .low_stock = s.columnInt(9) != 0,
            .dead_stock = s.columnInt(10) != 0,
        });
    }
    result.products = products.items;
    if (started) try db.exec("COMMIT;");
    return result;
}

fn testDb() !Database {
    const db = try Database.open(":memory:");
    errdefer db.close();
    try db.migrate(std.testing.allocator, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Laporan", .mode = "retail", .address = "" });
    try db.exec(pos.test_open_shift);
    return db;
}

test "reports reconcile discounts, cost, cash expenses, stock alerts and pagination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    const rice = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Beras", .sku = "", .barcode = "", .category = "Sembako", .unit = "kg", .price = 10_000, .cost = 6_000, .stock_milli = 10_000, .min_stock_milli = 500 });
    const tea = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Teh", .sku = "", .barcode = "", .category = "Minuman", .unit = "pcs", .price = 5_000, .cost = 1_000, .stock_milli = 2_000, .min_stock_milli = 1_000 });
    _ = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Barang lama", .sku = "", .barcode = "", .category = "Lain", .unit = "pcs", .price = 2_000, .cost = 500, .stock_milli = 4_000 });
    _ = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Jasa", .sku = "", .barcode = "", .category = "Jasa", .unit = "layanan", .price = 2_000, .cost = 0, .stock_milli = null });
    const first_lines = [_]pos.CartLine{
        .{ .product_id = rice.id, .revision = rice.revision, .quantity_milli = 2_000, .discount_kind = "none", .discount_value = 0, .note = "" },
        .{ .product_id = tea.id, .revision = tea.revision, .quantity_milli = 1_000, .discount_kind = "none", .discount_value = 0, .note = "" },
    };
    const first = try pos.checkout(db, a, .{ .checkout_id = "report-1", .cart = .{ .lines = &first_lines, .discount_kind = "nominal", .discount_value = 500, .cash_rounding_increment = 1 }, .tendered = 25_000, .expected_total = 24_500 });
    const current_rice = try pos.getProduct(db, a, rice.id);
    const second_lines = [_]pos.CartLine{.{ .product_id = current_rice.id, .revision = current_rice.revision, .quantity_milli = 1_000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    _ = try pos.checkout(db, a, .{ .checkout_id = "report-2", .cart = .{ .lines = &second_lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 10_000, .expected_total = 10_000 });
    try db.exec("UPDATE sale SET created_at='2026-10-27T10:00:00.000Z',sale_date='2026-10-27' WHERE id=1; UPDATE sale SET created_at='2026-10-26T09:00:00.000Z',sale_date='2026-10-26' WHERE id=2;");
    const shift_module = @import("shift.zig");
    _ = try shift_module.recordCash(db, a, .{ .entry_key = "expense", .kind = "out", .amount = 1_500, .category = "Belanja", .note = "" });
    _ = try shift_module.recordCash(db, a, .{ .entry_key = "capital", .kind = "in", .amount = 700, .category = "Modal", .note = "" });
    try db.exec("UPDATE cash_entry SET created_at='2026-10-27T11:00:00.000Z';");

    const today = try dashboard(db, a, "2026-10-27");
    try std.testing.expectEqual(@as(i64, 1), today.sale_count);
    try std.testing.expectEqual(@as(i64, 24_500), today.sales_total);
    try std.testing.expectEqual(@as(i64, 24_500), today.average_sale);
    try std.testing.expectEqual(@as(i64, 24_500), today.revenue);
    try std.testing.expectEqual(@as(i64, 13_000), today.cogs);
    try std.testing.expectEqual(@as(i64, 11_500), today.gross_profit);
    var hourly_total: i64 = 0;
    for (today.hours) |bucket| hourly_total += bucket.sales_total;
    try std.testing.expectEqual(today.sales_total, hourly_total);
    try std.testing.expectEqual(@as(usize, 2), today.top_products.len);
    try std.testing.expectEqual(@as(i64, 19_600), today.top_products[0].revenue);
    try std.testing.expectEqual(@as(i64, 7_600), today.top_products[0].gross_profit);
    try std.testing.expectEqual(@as(i64, 4_900), today.top_products[1].revenue);
    try std.testing.expectEqual(@as(usize, 1), today.low_stock.len);
    try std.testing.expectEqualStrings("Teh", today.low_stock[0].name);

    const by_product = try sales(db, a, "2026-10-26", "2026-10-27", "product", 0);
    try std.testing.expectEqual(@as(i64, 2), by_product.sale_count);
    try std.testing.expectEqual(@as(i64, 34_500), by_product.revenue);
    try std.testing.expectEqual(@as(i64, 19_000), by_product.cogs);
    try std.testing.expectEqual(@as(usize, 2), by_product.groups.len);
    try std.testing.expectEqual(@as(i64, 29_600), by_product.groups[0].revenue);
    try std.testing.expectEqual(@as(i64, 3_000), by_product.groups[0].quantity_milli);
    const by_day = try sales(db, a, "2026-10-26", "2026-10-27", "day", 0);
    try std.testing.expectEqualStrings("2026-10-27", by_day.groups[0].key);
    const by_category = try sales(db, a, "2026-10-26", "2026-10-27", "category", 0);
    try std.testing.expectEqual(@as(usize, 2), by_category.groups.len);
    try std.testing.expectError(error.InvalidQuery, sales(db, a, "2026-10-28", "2026-10-27", "day", 0));
    try std.testing.expectError(error.InvalidQuery, sales(db, a, "2026-10-26", "2026-10-27", "cashier", 0));

    const earnings = try profit(db, a, "2026-10-27", "2026-10-27", 0);
    try std.testing.expectEqual(@as(i64, 11_500), earnings.gross_profit);
    try std.testing.expectEqual(@as(i64, 1_500), earnings.expense_total);
    try std.testing.expectEqual(@as(i64, 10_000), earnings.net_profit);
    try std.testing.expectEqual(@as(usize, 1), earnings.expense_categories.len);
    try std.testing.expectEqualStrings("Belanja", earnings.expense_categories[0].category);

    const inventory = try stock(db, a, "all", 0);
    try std.testing.expectEqual(@as(i64, 4), inventory.total_products);
    try std.testing.expectEqual(@as(i64, 3), inventory.tracked_products);
    try std.testing.expectEqual(@as(i64, 1), inventory.low_stock_count);
    try std.testing.expectEqual(@as(i64, 1), inventory.dead_stock_count);
    try std.testing.expectEqual(@as(i64, 45_000), inventory.stock_value);
    try std.testing.expectEqual(@as(usize, 1), (try stock(db, a, "low", 0)).products.len);
    try std.testing.expectEqualStrings("Barang lama", (try stock(db, a, "dead", 0)).products[0].name);
    try std.testing.expectEqual(first.id, 1);
    try std.testing.expectError(error.InvalidQuery, stock(db, a, "archived", 0));
}
