const std = @import("std");
const sqlite = @import("../infra/db/sqlite.zig");
const money = @import("../domain/money.zig");
const Database = sqlite.Database;
const Statement = sqlite.Statement;
const Allocator = std.mem.Allocator;

// Bounds the summary so a full shift always fits in one bridge response.
pub const max_entries = 100;

pub const CashEntry = struct {
    id: i64,
    created_at: []const u8,
    kind: []const u8,
    amount: i64,
    category: []const u8,
    note: []const u8,
};

pub const Summary = struct {
    id: i64,
    opened_at: []const u8,
    closed_at: ?[]const u8,
    opening_cash: i64,
    sale_count: i64,
    sales_total: i64,
    cash_sales: i64,
    cash_in: i64,
    cash_out: i64,
    expected_cash: i64,
    counted_cash: ?i64,
    difference: ?i64,
    close_note: []const u8,
    entries: []CashEntry,
};

pub const CashInput = struct {
    entry_key: []const u8,
    kind: []const u8,
    amount: i64,
    category: []const u8,
    note: []const u8,
};

fn validText(value: []const u8, max: usize) bool {
    if (value.len > max) return false;
    const view = std.unicode.Utf8View.init(value) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |cp| if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    return true;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 80) return false;
    for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn done(s: Statement) !void {
    if (try s.next()) return error.UnexpectedResult;
}

fn now(db: Database, a: Allocator) ![]const u8 {
    return db.text(a, "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now');");
}

fn openId(db: Database) !?i64 {
    const s = try db.prepare("SELECT id FROM shift WHERE closed_at IS NULL;");
    defer s.close();
    if (!try s.next()) return null;
    return s.columnInt(0);
}

fn summaryInternal(db: Database, a: Allocator, id: i64) !Summary {
    if (id < 1 or id > money.max_amount) return error.ShiftNotFound;
    const s = try db.prepare("SELECT opened_at,closed_at,opening_cash,expected_cash,counted_cash,close_note FROM shift WHERE id=?;");
    defer s.close();
    try s.bindInt(1, id);
    if (!try s.next()) return error.ShiftNotFound;
    var result = Summary{
        .id = id,
        .opened_at = try a.dupe(u8, s.columnText(0)),
        .closed_at = if (s.isNull(1)) null else try a.dupe(u8, s.columnText(1)),
        .opening_cash = s.columnInt(2),
        .sale_count = 0,
        .sales_total = 0,
        .cash_sales = 0,
        .cash_in = 0,
        .cash_out = 0,
        .expected_cash = 0,
        .counted_cash = if (s.isNull(4)) null else s.columnInt(4),
        .difference = null,
        .close_note = try a.dupe(u8, s.columnText(5)),
        .entries = &.{},
    };
    const stored_expected: ?i64 = if (s.isNull(3)) null else s.columnInt(3);
    {
        const sales = try db.prepare("SELECT count(*),coalesce(sum(sale.total),0),coalesce(sum(CASE WHEN payment.method='cash' THEN payment.amount END),0) FROM sale LEFT JOIN payment ON payment.sale_id=sale.id WHERE sale.shift_id=?;");
        defer sales.close();
        try sales.bindInt(1, id);
        if (!try sales.next()) return error.NoResult;
        result.sale_count = sales.columnInt(0);
        result.sales_total = sales.columnInt(1);
        result.cash_sales = sales.columnInt(2);
    }
    const entries = try db.prepare("SELECT id,created_at,kind,amount,category,note FROM cash_entry WHERE shift_id=? ORDER BY id;");
    defer entries.close();
    try entries.bindInt(1, id);
    var list: std.ArrayList(CashEntry) = .empty;
    while (try entries.next()) {
        const entry = CashEntry{
            .id = entries.columnInt(0),
            .created_at = try a.dupe(u8, entries.columnText(1)),
            .kind = try a.dupe(u8, entries.columnText(2)),
            .amount = entries.columnInt(3),
            .category = try a.dupe(u8, entries.columnText(4)),
            .note = try a.dupe(u8, entries.columnText(5)),
        };
        if (std.mem.eql(u8, entry.kind, "in")) result.cash_in = try money.add(result.cash_in, entry.amount) else result.cash_out = try money.add(result.cash_out, entry.amount);
        try list.append(a, entry);
    }
    result.entries = list.items;
    const inflow = try money.add(try money.add(result.opening_cash, result.cash_sales), result.cash_in);
    result.expected_cash = stored_expected orelse try money.subtract(inflow, result.cash_out);
    if (result.counted_cash) |counted| result.difference = counted - result.expected_cash;
    return result;
}

fn beginRead(db: Database) !bool {
    if (sqlite.c.sqlite3_get_autocommit(db.handle) == 0) return false;
    try db.exec("BEGIN;");
    return true;
}

// The caller's arena owns all returned strings.
pub fn current(db: Database, a: Allocator) !?Summary {
    const started = try beginRead(db);
    errdefer if (started) db.exec("ROLLBACK;") catch {};
    const result = if (try openId(db)) |id| try summaryInternal(db, a, id) else null;
    if (started) try db.exec("COMMIT;");
    return result;
}

pub fn get(db: Database, a: Allocator, id: i64) !Summary {
    const started = try beginRead(db);
    errdefer if (started) db.exec("ROLLBACK;") catch {};
    const result = try summaryInternal(db, a, id);
    if (started) try db.exec("COMMIT;");
    return result;
}

pub fn open(db: Database, a: Allocator, opening_cash: i64) !Summary {
    money.validate(opening_cash) catch return error.InvalidShift;
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    if (try db.integer("SELECT count(*) FROM business WHERE id=1;") != 1) return error.BusinessRequired;
    if (try openId(db) != null) return error.ShiftOpen;
    const s = try db.prepare("INSERT INTO shift(opened_at,opening_cash) VALUES(?,?);");
    defer s.close();
    try s.bindText(1, try now(db, a));
    try s.bindInt(2, opening_cash);
    try done(s);
    const result = try summaryInternal(db, a, sqlite.c.sqlite3_last_insert_rowid(db.handle));
    try db.exec("COMMIT;");
    return result;
}

pub fn recordCash(db: Database, a: Allocator, input: CashInput) !Summary {
    const category = std.mem.trim(u8, input.category, " ");
    const valid_kind = std.mem.eql(u8, input.kind, "in") or std.mem.eql(u8, input.kind, "out");
    if (!validKey(input.entry_key) or !valid_kind or input.amount < 1 or input.amount > money.max_amount or
        category.len == 0 or !validText(category, 64) or !validText(input.note, 160)) return error.InvalidCashEntry;
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    {
        const s = try db.prepare("SELECT shift_id,kind,amount,category,note FROM cash_entry WHERE entry_key=?;");
        defer s.close();
        try s.bindText(1, input.entry_key);
        if (try s.next()) {
            const same = std.mem.eql(u8, s.columnText(1), input.kind) and s.columnInt(2) == input.amount and
                std.mem.eql(u8, s.columnText(3), category) and std.mem.eql(u8, s.columnText(4), input.note);
            if (!same) return error.IdempotencyConflict;
            const result = try summaryInternal(db, a, s.columnInt(0));
            try db.exec("COMMIT;");
            return result;
        }
    }
    const shift_id = (try openId(db)) orelse return error.ShiftRequired;
    const before = try summaryInternal(db, a, shift_id);
    if (before.entries.len >= max_entries) return error.CashEntryLimit;
    if (std.mem.eql(u8, input.kind, "out")) {
        if (input.amount > before.expected_cash) return error.InsufficientCash;
    } else {
        _ = money.add(before.expected_cash, input.amount) catch return error.InvalidCashEntry;
    }
    const s = try db.prepare("INSERT INTO cash_entry(entry_key,shift_id,created_at,kind,amount,category,note) VALUES(?,?,?,?,?,?,?);");
    defer s.close();
    try s.bindText(1, input.entry_key);
    try s.bindInt(2, shift_id);
    try s.bindText(3, try now(db, a));
    try s.bindText(4, input.kind);
    try s.bindInt(5, input.amount);
    try s.bindText(6, category);
    try s.bindText(7, input.note);
    try done(s);
    const result = try summaryInternal(db, a, shift_id);
    try db.exec("COMMIT;");
    return result;
}

// A retried close with the same count returns the frozen report instead of failing.
pub fn close(db: Database, a: Allocator, id: i64, counted_cash: i64, note: []const u8) !Summary {
    money.validate(counted_cash) catch return error.InvalidShift;
    if (!validText(note, 160)) return error.InvalidShift;
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    const existing = try summaryInternal(db, a, id);
    if (existing.closed_at != null) {
        if (existing.counted_cash.? != counted_cash or !std.mem.eql(u8, existing.close_note, note)) return error.ShiftClosed;
        try db.exec("COMMIT;");
        return existing;
    }
    const s = try db.prepare("UPDATE shift SET closed_at=?,expected_cash=?,counted_cash=?,close_note=? WHERE id=? AND closed_at IS NULL;");
    defer s.close();
    try s.bindText(1, try now(db, a));
    try s.bindInt(2, existing.expected_cash);
    try s.bindInt(3, counted_cash);
    try s.bindText(4, note);
    try s.bindInt(5, id);
    try done(s);
    if (sqlite.c.sqlite3_changes(db.handle) != 1) return error.ShiftClosed;
    const result = try summaryInternal(db, a, id);
    try db.exec("COMMIT;");
    return result;
}

fn testDb() !Database {
    const db = try Database.open(":memory:");
    errdefer db.close();
    try db.migrate(std.testing.allocator, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Shift", .mode = "retail", .address = "" });
    return db;
}

fn testSale(db: Database, a: Allocator, key: []const u8) !void {
    const pos = @import("pos.zig");
    const existing = (try pos.listProducts(db, a, "", 0)).products;
    const product = if (existing.len > 0) existing[0] else try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Teh", .sku = "", .barcode = "", .category = "", .unit = "pcs", .price = 4_000, .cost = 1_500, .stock_milli = null });
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1_000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    _ = try pos.checkout(db, a, .{ .checkout_id = key, .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 5_000, .expected_total = 4_000 });
}

fn cash(key: []const u8, kind: []const u8, amount: i64, category: []const u8) CashInput {
    return .{ .entry_key = key, .kind = kind, .amount = amount, .category = category, .note = "" };
}

test "shift lifecycle reconciles cash sales, cash movements and the physical count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    try std.testing.expect((try current(db, a)) == null);
    try std.testing.expectError(error.ShiftRequired, testSale(db, a, "before-open"));
    try std.testing.expectError(error.ShiftRequired, recordCash(db, a, cash("early", "in", 1, "Modal")));
    const opened = try open(db, a, 100_000);
    try std.testing.expectEqual(@as(i64, 100_000), opened.expected_cash);
    try std.testing.expectError(error.ShiftOpen, open(db, a, 0));
    try testSale(db, a, "sale-1");
    try testSale(db, a, "sale-2");
    _ = try recordCash(db, a, cash("in-1", "in", 50_000, " Tambah modal "));
    var out = cash("out-1", "out", 12_500, "Beli es");
    out.note = "2 balok";
    const after_out = try recordCash(db, a, out);
    try std.testing.expectEqual(@as(i64, 2), after_out.sale_count);
    try std.testing.expectEqual(@as(i64, 8_000), after_out.sales_total);
    try std.testing.expectEqual(@as(i64, 8_000), after_out.cash_sales);
    try std.testing.expectEqual(@as(i64, 50_000), after_out.cash_in);
    try std.testing.expectEqual(@as(i64, 12_500), after_out.cash_out);
    try std.testing.expectEqual(@as(i64, 145_500), after_out.expected_cash);
    try std.testing.expectEqualStrings("Tambah modal", after_out.entries[0].category);
    try std.testing.expectEqualStrings("2 balok", after_out.entries[1].note);
    try std.testing.expectEqualDeep(after_out, try recordCash(db, a, out));
    out.amount += 1;
    try std.testing.expectError(error.IdempotencyConflict, recordCash(db, a, out));
    try std.testing.expectError(error.InsufficientCash, recordCash(db, a, cash("too-much", "out", 145_501, "Bayar listrik")));
    _ = try recordCash(db, a, cash("drain", "out", 145_500, "Setor bank"));
    try std.testing.expectEqual(@as(i64, 0), (try current(db, a)).?.expected_cash);
    try std.testing.expectEqual(@as(i64, 3), try db.integer("SELECT count(*) FROM cash_entry;"));

    const closed = try close(db, a, opened.id, 1_000, "Lebih seribu");
    try std.testing.expect(closed.closed_at != null);
    try std.testing.expectEqual(@as(?i64, 1_000), closed.counted_cash);
    try std.testing.expectEqual(@as(?i64, 1_000), closed.difference);
    try std.testing.expectEqualDeep(closed, try close(db, a, opened.id, 1_000, "Lebih seribu"));
    try std.testing.expectError(error.ShiftClosed, close(db, a, opened.id, 0, "Lebih seribu"));
    try std.testing.expect((try current(db, a)) == null);
    try std.testing.expectError(error.ShiftRequired, testSale(db, a, "after-close"));
    try std.testing.expectError(error.ShiftRequired, recordCash(db, a, cash("late", "in", 1, "Modal")));
    try std.testing.expectEqualDeep(closed, try get(db, a, opened.id));
    try std.testing.expectError(error.ShiftNotFound, get(db, a, opened.id + 1));
    try std.testing.expectError(error.ShiftNotFound, close(db, a, 0, 0, ""));

    const next = try open(db, a, 0);
    try std.testing.expectEqual(opened.id + 1, next.id);
    try testSale(db, a, "sale-3");
    const short = try close(db, a, next.id, 3_000, "");
    try std.testing.expectEqual(@as(i64, 4_000), short.expected_cash);
    try std.testing.expectEqual(@as(?i64, -1_000), short.difference);
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM sale WHERE shift_id=1;"));
}

test "shift input validation and entry limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    try std.testing.expectError(error.InvalidShift, open(db, a, -1));
    try std.testing.expectError(error.InvalidShift, open(db, a, money.max_amount + 1));
    const opened = try open(db, a, 10);
    for ([_]CashInput{
        cash("", "in", 1, "Modal"),
        cash("bad key", "in", 1, "Modal"),
        cash("k", "refund", 1, "Modal"),
        cash("k", "in", 0, "Modal"),
        cash("k", "in", 1, "   "),
        cash("k", "in", 1, "Es\x1b@"),
        cash("k", "in", 1, "x" ** 65),
        .{ .entry_key = "k", .kind = "in", .amount = 1, .category = "Modal", .note = "line\nbreak" },
    }) |input| try std.testing.expectError(error.InvalidCashEntry, recordCash(db, a, input));
    try std.testing.expectError(error.InvalidCashEntry, recordCash(db, a, cash("huge", "in", money.max_amount, "Modal")));
    try std.testing.expectError(error.InvalidShift, close(db, a, opened.id, 0, "\x07"));
    for (0..max_entries) |index| _ = try recordCash(db, a, cash(try std.fmt.allocPrint(a, "e{d}", .{index}), "in", 1, "Modal"));
    try std.testing.expectError(error.CashEntryLimit, recordCash(db, a, cash("overflow", "in", 1, "Modal")));
    try std.testing.expectEqual(@as(usize, max_entries), (try get(db, a, opened.id)).entries.len);
    try db.exec("DELETE FROM business;");
    _ = try close(db, a, opened.id, 0, "");
    try std.testing.expectError(error.BusinessRequired, open(db, a, 0));
}
