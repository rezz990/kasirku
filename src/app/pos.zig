const std = @import("std");
const sqlite = @import("../infra/db/sqlite.zig");
const cart = @import("../domain/cart.zig");
const money = @import("../domain/money.zig");
const inventory = @import("../domain/inventory.zig");
const Database = sqlite.Database;
const Statement = sqlite.Statement;
const Allocator = std.mem.Allocator;
const bound = money.max_amount;

pub const ProductInput = struct {
    id: ?i64,
    revision: ?i64,
    name: []const u8,
    sku: []const u8,
    barcode: []const u8,
    category: []const u8,
    unit: []const u8,
    price: i64,
    cost: i64,
    stock_milli: ?i64,
};
pub const Product = struct {
    id: i64,
    revision: i64,
    name: []const u8,
    sku: []const u8,
    barcode: []const u8,
    category: []const u8,
    unit: []const u8,
    price: i64,
    cost: i64,
    stock_milli: ?i64,
};
pub const ProductPage = struct { products: []Product, has_more: bool };
pub const CartLine = struct {
    product_id: i64,
    revision: i64,
    quantity_milli: i64,
    discount_kind: []const u8,
    discount_value: i64,
    note: []const u8,
};
pub const CartInput = struct {
    lines: []const CartLine,
    discount_kind: []const u8,
    discount_value: i64,
    cash_rounding_increment: i64,
};
pub const Item = struct {
    product_id: i64,
    revision: i64,
    name: []const u8,
    sku: []const u8,
    barcode: []const u8,
    category: []const u8,
    unit: []const u8,
    unit_price: i64,
    unit_cost: i64,
    quantity_milli: i64,
    discount_kind: []const u8,
    discount_value: i64,
    note: []const u8,
    gross: i64,
    discount: i64,
    net: i64,
};
pub const Quote = struct { items: []Item, totals: cart.Totals };
pub const CheckoutInput = struct {
    checkout_id: []const u8,
    cart: CartInput,
    tendered: i64,
    expected_total: i64,
};
pub const Sale = struct {
    id: i64,
    number: []const u8,
    created_at: []const u8,
    business_name: []const u8,
    business_address: []const u8,
    totals: cart.Totals,
    tendered: i64,
    change: i64,
    items: []Item,
};
pub const SaleSummary = struct {
    id: i64,
    number: []const u8,
    created_at: []const u8,
    total: i64,
    tendered: i64,
    change: i64,
    item_count: i64,
};
pub const SalePage = struct { sales: []SaleSummary, has_more: bool };

// An arena owns intermediate snapshots; only a completed deep copy escapes.
fn copyOwned(comptime T: type, a: Allocator, value: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result = value;
            var completed: usize = 0;
            errdefer inline for (info.fields, 0..) |field, index| {
                if (index < completed) freeOwned(field.type, a, @field(result, field.name));
            };
            inline for (info.fields) |field| {
                @field(result, field.name) = try copyOwned(field.type, a, @field(value, field.name));
                completed += 1;
            }
            return result;
        },
        .pointer => |info| {
            comptime std.debug.assert(info.size == .slice);
            const result = try a.alloc(info.child, value.len);
            var completed: usize = 0;
            errdefer {
                for (result[0..completed]) |entry| freeOwned(info.child, a, entry);
                a.free(result);
            }
            for (value, result) |entry, *target| {
                target.* = try copyOwned(info.child, a, entry);
                completed += 1;
            }
            return result;
        },
        else => return value,
    }
}

fn freeOwned(comptime T: type, a: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| freeOwned(field.type, a, @field(value, field.name)),
        .pointer => |info| {
            comptime std.debug.assert(info.size == .slice);
            for (value) |entry| freeOwned(info.child, a, entry);
            a.free(value);
        },
        else => {},
    }
}

fn nonnegative(value: i64) bool {
    return value >= 0 and value <= bound;
}
fn positive(value: i64) bool {
    return value > 0 and value <= bound;
}
fn validText(value: []const u8, max: usize, note: bool) bool {
    if (value.len > max) return false;
    const view = std.unicode.Utf8View.init(value) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |cp| {
        if (note and (cp == '\n' or cp == '\t')) continue;
        if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    }
    return true;
}
fn validateProduct(input: ProductInput) !ProductInput {
    if ((input.id == null) != (input.revision == null)) return error.InvalidProduct;
    if (input.id) |id| if (!positive(id) or !positive(input.revision.?)) return error.InvalidProduct;
    if (!validText(input.name, 120, false) or !validText(input.unit, 16, false) or
        !validText(input.sku, 64, false) or !validText(input.barcode, 64, false) or
        !validText(input.category, 64, false) or !nonnegative(input.price) or !nonnegative(input.cost)) return error.InvalidProduct;
    if (input.stock_milli) |stock| if (!nonnegative(stock)) return error.InvalidProduct;
    var result = input;
    result.name = std.mem.trim(u8, input.name, " ");
    result.unit = std.mem.trim(u8, input.unit, " ");
    if (result.name.len == 0 or result.unit.len == 0) return error.InvalidProduct;
    return result;
}
fn requireBusiness(db: Database) !void {
    if (try db.integer("SELECT count(*) FROM business WHERE id=1;") != 1) return error.BusinessRequired;
}
fn done(s: Statement) !void {
    if (try s.next()) return error.UnexpectedResult;
}
fn bindOptional(s: Statement, index: c_int, value: ?i64) !void {
    if (value) |v| try s.bindInt(index, v) else try s.bindNull(index);
}
fn optionalInt(s: Statement, index: c_int) ?i64 {
    return if (s.isNull(index)) null else s.columnInt(index);
}
fn beginRead(db: Database) !bool {
    if (sqlite.c.sqlite3_get_autocommit(db.handle) == 0) return false;
    try db.exec("BEGIN;");
    return true;
}
fn rollback(db: Database, started: bool) void {
    if (started) db.exec("ROLLBACK;") catch {};
}
const product_columns = "id,revision,name,sku,barcode,category,unit,price,cost,stock_milli";
fn readProduct(s: Statement, a: Allocator) !Product {
    return .{
        .id = s.columnInt(0),
        .revision = s.columnInt(1),
        .name = try a.dupe(u8, s.columnText(2)),
        .sku = try a.dupe(u8, s.columnText(3)),
        .barcode = try a.dupe(u8, s.columnText(4)),
        .category = try a.dupe(u8, s.columnText(5)),
        .unit = try a.dupe(u8, s.columnText(6)),
        .price = s.columnInt(7),
        .cost = s.columnInt(8),
        .stock_milli = optionalInt(s, 9),
    };
}
fn productInternal(db: Database, a: Allocator, id: i64) !Product {
    if (!positive(id)) return error.ProductNotFound;
    const s = try db.prepare("SELECT " ++ product_columns ++ " FROM product WHERE id=? AND active=1;");
    defer s.close();
    try s.bindInt(1, id);
    if (!try s.next()) return error.ProductNotFound;
    return readProduct(s, a);
}
pub fn getProduct(db: Database, a: Allocator, id: i64) !Product {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return copyOwned(Product, a, try productInternal(db, arena.allocator(), id));
}

fn movement(db: Database, id: i64, sale_id: ?i64, kind: []const u8, before: ?i64, after: ?i64) !void {
    const s = try db.prepare("INSERT INTO stock_movement(product_id,sale_id,kind,quantity_milli,before_milli,after_milli) VALUES(?,?,?,?,?,?);");
    defer s.close();
    try s.bindInt(1, id);
    try bindOptional(s, 2, sale_id);
    try s.bindText(3, kind);
    try s.bindInt(4, (after orelse 0) - (before orelse 0));
    try bindOptional(s, 5, before);
    try bindOptional(s, 6, after);
    try done(s);
}
fn bindProduct(s: Statement, input: ProductInput) !void {
    try s.bindText(1, input.name);
    try s.bindText(2, input.sku);
    try s.bindText(3, input.barcode);
    try s.bindText(4, input.category);
    try s.bindText(5, input.unit);
    try s.bindInt(6, input.price);
    try s.bindInt(7, input.cost);
    try bindOptional(s, 8, input.stock_milli);
}
fn productWrite(db: Database, s: Statement) !void {
    done(s) catch |err| {
        if (err == error.ConstraintViolation and sqlite.c.sqlite3_extended_errcode(db.handle) == sqlite.c.SQLITE_CONSTRAINT_UNIQUE) return error.ProductConflict;
        return err;
    };
}
pub fn saveProduct(db: Database, a: Allocator, input: ProductInput) !Product {
    const normalized = try validateProduct(input);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    try db.exec("BEGIN IMMEDIATE;");
    errdefer rollback(db, true);
    try requireBusiness(db);
    var id: i64 = undefined;
    if (normalized.id) |existing_id| {
        const previous = try productInternal(db, work, existing_id);
        if (previous.revision != normalized.revision.? or previous.revision == bound) return error.ProductChanged;
        const s = try db.prepare("UPDATE product SET name=?,sku=?,barcode=?,category=?,unit=?,price=?,cost=?,stock_milli=?,revision=revision+1 WHERE id=? AND revision=? AND active=1;");
        defer s.close();
        try bindProduct(s, normalized);
        try s.bindInt(9, existing_id);
        try s.bindInt(10, normalized.revision.?);
        try productWrite(db, s);
        if (sqlite.c.sqlite3_changes(db.handle) != 1) return error.ProductChanged;
        if (previous.stock_milli != normalized.stock_milli) try movement(db, existing_id, null, "adjustment", previous.stock_milli, normalized.stock_milli);
        id = existing_id;
    } else {
        const s = try db.prepare("INSERT INTO product(name,sku,barcode,category,unit,price,cost,stock_milli) VALUES(?,?,?,?,?,?,?,?);");
        defer s.close();
        try bindProduct(s, normalized);
        try productWrite(db, s);
        id = sqlite.c.sqlite3_last_insert_rowid(db.handle);
        if (normalized.stock_milli != null) try movement(db, id, null, "initial", null, normalized.stock_milli);
    }
    const result = try copyOwned(Product, a, try productInternal(db, work, id));
    errdefer freeOwned(Product, a, result);
    try db.exec("COMMIT;");
    return result;
}
pub fn archiveProduct(db: Database, id: i64, revision: i64) !void {
    if (!positive(id) or !positive(revision)) return error.InvalidProduct;
    try db.exec("BEGIN IMMEDIATE;");
    errdefer rollback(db, true);
    try requireBusiness(db);
    const read = try db.prepare("SELECT revision FROM product WHERE id=? AND active=1;");
    defer read.close();
    try read.bindInt(1, id);
    if (!try read.next()) return error.ProductNotFound;
    if (read.columnInt(0) != revision or revision == bound) return error.ProductChanged;
    const s = try db.prepare("UPDATE product SET active=0,revision=revision+1 WHERE id=? AND revision=? AND active=1;");
    defer s.close();
    try s.bindInt(1, id);
    try s.bindInt(2, revision);
    try done(s);
    if (sqlite.c.sqlite3_changes(db.handle) != 1) return error.ProductChanged;
    try db.exec("COMMIT;");
}
fn validateOffset(offset: i64) !void {
    if (offset < 0 or offset > 1_000_000_000) return error.InvalidQuery;
}
pub fn listProducts(db: Database, a: Allocator, query: []const u8, offset: i64) !ProductPage {
    try validateOffset(offset);
    if (!validText(query, 120, false)) return error.InvalidQuery;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const s = try db.prepare("SELECT " ++ product_columns ++
        " FROM product WHERE active=1 AND (?1='' OR instr(lower(name),lower(?1))>0 OR instr(lower(sku),lower(?1))>0 OR instr(lower(barcode),lower(?1))>0 OR instr(lower(category),lower(?1))>0) ORDER BY CASE WHEN ?1<>'' AND (sku=?1 OR barcode=?1) THEN 0 ELSE 1 END,name COLLATE NOCASE,id LIMIT 21 OFFSET ?2;");
    defer s.close();
    try s.bindText(1, query);
    try s.bindInt(2, offset);
    var products: std.ArrayList(Product) = .empty;
    var has_more = false;
    while (try s.next()) {
        if (products.items.len == 20) {
            has_more = true;
            break;
        }
        try products.append(work, try readProduct(s, work));
    }
    return copyOwned(ProductPage, a, .{ .products = products.items, .has_more = has_more });
}

fn discount(kind: []const u8, value: i64) !cart.Discount {
    if (!nonnegative(value)) return error.InvalidDiscount;
    if (std.mem.eql(u8, kind, "none")) {
        if (value != 0) return error.InvalidDiscount;
        return .none;
    }
    if (std.mem.eql(u8, kind, "nominal")) return .{ .nominal = value };
    if (std.mem.eql(u8, kind, "percent") and value <= 10_000) return .{ .percent_bps = value };
    return error.InvalidDiscount;
}
fn validateCart(input: CartInput) !void {
    if (input.lines.len == 0 or input.lines.len > 40) return error.InvalidCart;
    _ = try discount(input.discount_kind, input.discount_value);
    try money.validateRoundingIncrement(input.cash_rounding_increment);
    for (input.lines, 0..) |line, i| {
        if (!positive(line.product_id) or !positive(line.revision) or !positive(line.quantity_milli) or !validText(line.note, 160, true)) return error.InvalidCart;
        _ = try discount(line.discount_kind, line.discount_value);
        for (input.lines[0..i]) |previous| if (previous.product_id == line.product_id) return error.InvalidCart;
    }
}
fn quoteInternal(db: Database, a: Allocator, input: CartInput) !Quote {
    try validateCart(input);
    try requireBusiness(db);
    const items = try a.alloc(Item, input.lines.len);
    var lines: [40]cart.Line = undefined;
    for (input.lines, items, 0..) |line, *item, index| {
        const product = try productInternal(db, a, line.product_id);
        if (product.revision != line.revision) return error.ProductChanged;
        const stock: inventory.Stock = if (product.stock_milli) |available| .{ .tracked = available } else .untracked;
        _ = try inventory.sale(stock, line.quantity_milli);
        lines[index] = .{ .unit_price = product.price, .quantity_milli = line.quantity_milli, .discount = try discount(line.discount_kind, line.discount_value) };
        const totals = try cart.calculateLine(lines[index]);
        item.* = .{
            .product_id = product.id,
            .revision = product.revision,
            .name = product.name,
            .sku = product.sku,
            .barcode = product.barcode,
            .category = product.category,
            .unit = product.unit,
            .unit_price = product.price,
            .unit_cost = product.cost,
            .quantity_milli = line.quantity_milli,
            .discount_kind = line.discount_kind,
            .discount_value = line.discount_value,
            .note = line.note,
            .gross = totals.gross,
            .discount = totals.discount,
            .net = totals.net,
        };
    }
    return .{ .items = items, .totals = try cart.calculate(lines[0..input.lines.len], .{
        .transaction_discount = try discount(input.discount_kind, input.discount_value),
        .cash_rounding_increment = input.cash_rounding_increment,
    }) };
}
pub fn quote(db: Database, a: Allocator, input: CartInput) !Quote {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const started = try beginRead(db);
    errdefer rollback(db, started);
    const result = try copyOwned(Quote, a, try quoteInternal(db, arena.allocator(), input));
    errdefer freeOwned(Quote, a, result);
    if (started) try db.exec("COMMIT;");
    return result;
}

const totals_columns = "gross,line_discount,subtotal,transaction_discount,net_subtotal,service_charge,tax_base,tax,total_before_rounding,rounding_adjustment,total";
fn readTotals(s: Statement, start: c_int) cart.Totals {
    var result: cart.Totals = undefined;
    inline for (std.meta.fields(cart.Totals), 0..) |field, index| {
        @field(result, field.name) = s.columnInt(start + @as(c_int, @intCast(index)));
    }
    return result;
}
fn bindTotals(s: Statement, start: c_int, totals: cart.Totals) !void {
    inline for (std.meta.fields(cart.Totals), 0..) |field, index| {
        try s.bindInt(start + @as(c_int, @intCast(index)), @field(totals, field.name));
    }
}
fn readItem(s: Statement, a: Allocator) !Item {
    return .{
        .product_id = s.columnInt(0),
        .revision = s.columnInt(1),
        .name = try a.dupe(u8, s.columnText(2)),
        .sku = try a.dupe(u8, s.columnText(3)),
        .barcode = try a.dupe(u8, s.columnText(4)),
        .category = try a.dupe(u8, s.columnText(5)),
        .unit = try a.dupe(u8, s.columnText(6)),
        .unit_price = s.columnInt(7),
        .unit_cost = s.columnInt(8),
        .quantity_milli = s.columnInt(9),
        .discount_kind = try a.dupe(u8, s.columnText(10)),
        .discount_value = s.columnInt(11),
        .note = try a.dupe(u8, s.columnText(12)),
        .gross = s.columnInt(13),
        .discount = s.columnInt(14),
        .net = s.columnInt(15),
    };
}
fn saleInternal(db: Database, a: Allocator, id: i64) !Sale {
    if (!positive(id)) return error.SaleNotFound;
    const s = try db.prepare("SELECT id,number,created_at,business_name,business_address," ++ totals_columns ++ ",tendered,change FROM sale WHERE id=?;");
    defer s.close();
    try s.bindInt(1, id);
    if (!try s.next()) return error.SaleNotFound;
    var result = Sale{
        .id = s.columnInt(0),
        .number = try a.dupe(u8, s.columnText(1)),
        .created_at = try a.dupe(u8, s.columnText(2)),
        .business_name = try a.dupe(u8, s.columnText(3)),
        .business_address = try a.dupe(u8, s.columnText(4)),
        .totals = readTotals(s, 5),
        .tendered = s.columnInt(16),
        .change = s.columnInt(17),
        .items = undefined,
    };
    const item_statement = try db.prepare("SELECT product_id,revision,name,sku,barcode,category,unit,unit_price,unit_cost,quantity_milli,discount_kind,discount_value,note,gross,discount,net FROM sale_item WHERE sale_id=? ORDER BY position;");
    defer item_statement.close();
    try item_statement.bindInt(1, id);
    var items: std.ArrayList(Item) = .empty;
    while (try item_statement.next()) try items.append(a, try readItem(item_statement, a));
    result.items = items.items;
    return result;
}
pub fn saleDetail(db: Database, a: Allocator, id: i64) !Sale {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const started = try beginRead(db);
    errdefer rollback(db, started);
    const result = try copyOwned(Sale, a, try saleInternal(db, arena.allocator(), id));
    errdefer freeOwned(Sale, a, result);
    if (started) try db.exec("COMMIT;");
    return result;
}
fn validateCheckoutId(id: []const u8) !void {
    if (id.len == 0 or id.len > 80) return error.InvalidCart;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidCart;
}
fn inputHash(a: Allocator, input: CheckoutInput) ![64]u8 {
    const canonical = try std.json.Stringify.valueAlloc(a, input, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn writeItem(db: Database, sale_id: i64, position: usize, item: Item) !void {
    const s = try db.prepare("INSERT INTO sale_item(sale_id,position,product_id,revision,name,sku,barcode,category,unit,unit_price,unit_cost,quantity_milli,discount_kind,discount_value,note,gross,discount,net) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);");
    defer s.close();
    try s.bindInt(1, sale_id);
    try s.bindInt(2, @intCast(position));
    try s.bindInt(3, item.product_id);
    try s.bindInt(4, item.revision);
    try s.bindText(5, item.name);
    try s.bindText(6, item.sku);
    try s.bindText(7, item.barcode);
    try s.bindText(8, item.category);
    try s.bindText(9, item.unit);
    try s.bindInt(10, item.unit_price);
    try s.bindInt(11, item.unit_cost);
    try s.bindInt(12, item.quantity_milli);
    try s.bindText(13, item.discount_kind);
    try s.bindInt(14, item.discount_value);
    try s.bindText(15, item.note);
    try s.bindInt(16, item.gross);
    try s.bindInt(17, item.discount);
    try s.bindInt(18, item.net);
    try done(s);
}
fn consumeStock(db: Database, a: Allocator, sale_id: i64, item: Item) !void {
    const product = try productInternal(db, a, item.product_id);
    if (product.revision != item.revision) return error.ProductChanged;
    if (product.stock_milli) |before| {
        if (product.revision == bound) return error.ProductChanged;
        const after = (try inventory.sale(.{ .tracked = before }, item.quantity_milli)).tracked;
        const s = try db.prepare("UPDATE product SET stock_milli=?,revision=revision+1 WHERE id=? AND revision=? AND active=1;");
        defer s.close();
        try s.bindInt(1, after);
        try s.bindInt(2, item.product_id);
        try s.bindInt(3, item.revision);
        try done(s);
        if (sqlite.c.sqlite3_changes(db.handle) != 1) return error.ProductChanged;
        try movement(db, item.product_id, sale_id, "sale", before, after);
    }
}
pub fn checkout(db: Database, a: Allocator, input: CheckoutInput) !Sale {
    try validateCheckoutId(input.checkout_id);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const hash = try inputHash(work, input);
    try db.exec("BEGIN IMMEDIATE;");
    errdefer rollback(db, true);
    // Replay does not depend on today's business, active products, or revisions.
    {
        const s = try db.prepare("SELECT id,input_hash FROM sale WHERE checkout_id=?;");
        defer s.close();
        try s.bindText(1, input.checkout_id);
        if (try s.next()) {
            if (!std.mem.eql(u8, s.columnText(1), &hash)) return error.IdempotencyConflict;
            const result = try copyOwned(Sale, a, try saleInternal(db, work, s.columnInt(0)));
            errdefer freeOwned(Sale, a, result);
            try db.exec("COMMIT;");
            return result;
        }
    }
    const quoted = try quoteInternal(db, work, input.cart);
    const shift_id = blk: {
        const s = try db.prepare("SELECT id FROM shift WHERE closed_at IS NULL;");
        defer s.close();
        if (!try s.next()) return error.ShiftRequired;
        break :blk s.columnInt(0);
    };
    try money.validate(input.expected_total);
    if (quoted.totals.total != input.expected_total) return error.TotalChanged;
    const cash = try cart.payCash(quoted.totals.total, input.tendered);
    const business = (try db.business(work)) orelse return error.BusinessRequired;
    const date_statement = try db.prepare("SELECT date('now','localtime'),strftime('%Y-%m-%dT%H:%M:%fZ','now');");
    defer date_statement.close();
    if (!try date_statement.next()) return error.NoResult;
    const date = try work.dupe(u8, date_statement.columnText(0));
    const created_at = try work.dupe(u8, date_statement.columnText(1));
    {
        const s = try db.prepare("INSERT INTO sale_sequence(sale_date,sequence) VALUES(?,1) ON CONFLICT(sale_date) DO UPDATE SET sequence=sequence+1;");
        defer s.close();
        try s.bindText(1, date);
        try done(s);
    }
    const sequence_statement = try db.prepare("SELECT sequence FROM sale_sequence WHERE sale_date=?;");
    defer sequence_statement.close();
    try sequence_statement.bindText(1, date);
    if (!try sequence_statement.next()) return error.NoResult;
    const sequence: u64 = @intCast(sequence_statement.columnInt(0));
    const number = try std.fmt.allocPrint(work, "INV-{s}{s}{s}-{d:0>4}", .{ date[0..4], date[5..7], date[8..10], sequence });
    const sale_id = blk: {
        const s = try db.prepare("INSERT INTO sale(checkout_id,input_hash,number,created_at,sale_date,business_name,business_address,discount_kind,discount_value,cash_rounding_increment," ++ totals_columns ++ ",tendered,change,shift_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);");
        defer s.close();
        try s.bindText(1, input.checkout_id);
        try s.bindText(2, &hash);
        try s.bindText(3, number);
        try s.bindText(4, created_at);
        try s.bindText(5, date);
        try s.bindText(6, business.name);
        try s.bindText(7, business.address);
        try s.bindText(8, input.cart.discount_kind);
        try s.bindInt(9, input.cart.discount_value);
        try s.bindInt(10, input.cart.cash_rounding_increment);
        try bindTotals(s, 11, quoted.totals);
        try s.bindInt(22, cash.tendered);
        try s.bindInt(23, cash.change);
        try s.bindInt(24, shift_id);
        try done(s);
        break :blk sqlite.c.sqlite3_last_insert_rowid(db.handle);
    };
    for (quoted.items, 0..) |item, position| {
        try writeItem(db, sale_id, position, item);
        try consumeStock(db, work, sale_id, item);
    }
    {
        const s = try db.prepare("INSERT INTO payment(sale_id,method,amount,tendered,change) VALUES(?,'cash',?,?,?);");
        defer s.close();
        try s.bindInt(1, sale_id);
        try s.bindInt(2, cash.amount_due);
        try s.bindInt(3, cash.tendered);
        try s.bindInt(4, cash.change);
        try done(s);
    }
    // Read the actual stored snapshots and finish all caller allocations before commit.
    const result = try copyOwned(Sale, a, try saleInternal(db, work, sale_id));
    errdefer freeOwned(Sale, a, result);
    try db.exec("COMMIT;");
    return result;
}

fn validateDate(date: []const u8) !void {
    if (date.len == 0) return;
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidQuery;
    for (date, 0..) |byte, index| {
        if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return error.InvalidQuery;
    }
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return error.InvalidQuery;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return error.InvalidQuery;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return error.InvalidQuery;
    if (year == 0 or month < 1 or month > 12 or day < 1) return error.InvalidQuery;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days: [12]u8 = .{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > days[month - 1]) return error.InvalidQuery;
}
pub fn listSales(db: Database, a: Allocator, date: []const u8, offset: i64) !SalePage {
    try validateOffset(offset);
    try validateDate(date);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const s = try db.prepare("SELECT id,number,created_at,total,tendered,change,(SELECT count(*) FROM sale_item WHERE sale_id=sale.id) FROM sale WHERE (?1='' OR sale_date=?1) ORDER BY id DESC LIMIT 21 OFFSET ?2;");
    defer s.close();
    try s.bindText(1, date);
    try s.bindInt(2, offset);
    var sales: std.ArrayList(SaleSummary) = .empty;
    var has_more = false;
    while (try s.next()) {
        if (sales.items.len == 20) {
            has_more = true;
            break;
        }
        try sales.append(work, .{
            .id = s.columnInt(0),
            .number = try work.dupe(u8, s.columnText(1)),
            .created_at = try work.dupe(u8, s.columnText(2)),
            .total = s.columnInt(3),
            .tendered = s.columnInt(4),
            .change = s.columnInt(5),
            .item_count = s.columnInt(6),
        });
    }
    return copyOwned(SalePage, a, .{ .sales = sales.items, .has_more = has_more });
}

fn testDb() !Database {
    const db = try Database.open(":memory:");
    errdefer db.close();
    try db.migrate(std.testing.allocator, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Snapshot", .mode = "retail", .address = "Jalan Lama" });
    try db.exec(test_open_shift);
    return db;
}
pub const test_open_shift = "INSERT INTO shift(opened_at,opening_cash) VALUES(strftime('%Y-%m-%dT%H:%M:%fZ','now'),0);";
fn testProduct() ProductInput {
    return .{ .id = null, .revision = null, .name = "Beras", .sku = "RICE", .barcode = "0123", .category = "Sembako", .unit = "kg", .price = 15_001, .cost = 10_000, .stock_milli = 2_000 };
}
fn testLine(product: Product) CartLine {
    return .{ .product_id = product.id, .revision = product.revision, .quantity_milli = 500, .discount_kind = "nominal", .discount_value = 501, .note = "Setengah\nkilo\tbaik" };
}
fn testCart(lines: []const CartLine) CartInput {
    return .{ .lines = lines, .discount_kind = "percent", .discount_value = 1_000, .cash_rounding_increment = 100 };
}

test "POS products CRUD, active uniqueness, tracking transitions and validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    var input = testProduct();
    input.name = " Beras ";
    input.unit = " kg ";
    const product = try saveProduct(db, a, input);
    try std.testing.expectEqualStrings("Beras", product.name);
    try std.testing.expectEqualStrings("kg", product.unit);
    try std.testing.expectEqual(@as(i64, 1), product.revision);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM stock_movement WHERE kind='initial' AND quantity_milli=2000;"));
    try std.testing.expectError(error.ProductConflict, saveProduct(db, a, input));
    input.sku = "OTHER";
    try std.testing.expectError(error.ProductConflict, saveProduct(db, a, input));
    input.id = product.id;
    input.revision = product.revision;
    input.stock_milli = null;
    const disabled = try saveProduct(db, a, input);
    try std.testing.expect(disabled.stock_milli == null);
    try std.testing.expectError(error.ProductChanged, saveProduct(db, a, input));
    input.revision = disabled.revision;
    input.stock_milli = 0;
    const enabled = try saveProduct(db, a, input);
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM stock_movement WHERE kind='adjustment';"));
    try std.testing.expectError(error.ProductChanged, archiveProduct(db, enabled.id, disabled.revision));
    try archiveProduct(db, enabled.id, enabled.revision);
    try std.testing.expectError(error.ProductNotFound, getProduct(db, a, enabled.id));
    try std.testing.expectEqual(@as(i64, 3), try db.integer("SELECT count(*) FROM stock_movement;"));
    _ = try saveProduct(db, a, testProduct());
    var invalid = testProduct();
    invalid.id = 1;
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    invalid = testProduct();
    invalid.name = " \t ";
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    invalid.name = "\xff";
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    invalid.name = "Control\xc2\x85";
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    invalid = testProduct();
    invalid.price = bound + 1;
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    invalid = testProduct();
    invalid.stock_milli = -1;
    try std.testing.expectError(error.InvalidProduct, saveProduct(db, a, invalid));
    try db.exec("DELETE FROM business;");
    try std.testing.expectError(error.BusinessRequired, saveProduct(db, a, testProduct()));
    const active = (try listProducts(db, a, "", 0)).products[0];
    try std.testing.expectError(error.BusinessRequired, archiveProduct(db, active.id, active.revision));
}

test "POS literal substring search, exact code priority and twenty row paging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    for (0..23) |index| {
        var input = testProduct();
        input.name = try std.fmt.allocPrint(a, "Item {d:0>2}", .{index});
        input.sku = "";
        input.barcode = "";
        input.category = if (index == 22) "100%_literal" else "General";
        input.stock_milli = null;
        _ = try saveProduct(db, a, input);
    }
    const first = try listProducts(db, a, "", 0);
    const second = try listProducts(db, a, "", 20);
    try std.testing.expectEqual(@as(usize, 20), first.products.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqual(@as(usize, 3), second.products.len);
    try std.testing.expect(!second.has_more);
    try std.testing.expectEqual(@as(usize, 1), (try listProducts(db, a, "%_", 0)).products.len);
    var exact = testProduct();
    exact.name = "Zulu";
    exact.sku = "Item";
    exact.barcode = "";
    _ = try saveProduct(db, a, exact);
    try std.testing.expectEqualStrings("Zulu", (try listProducts(db, a, "Item", 0)).products[0].name);
    try std.testing.expectEqual(@as(usize, 24), @as(usize, @intCast(try db.integer("SELECT count(*) FROM product;"))));
    try std.testing.expectError(error.InvalidQuery, listProducts(db, a, "", -1));
    try std.testing.expectError(error.InvalidQuery, listProducts(db, a, "", 1_000_000_001));
    try std.testing.expectError(error.InvalidQuery, listProducts(db, a, &([_]u8{'x'} ** 121), 0));
    try std.testing.expectEqual(@as(usize, 0), (try listProducts(db, a, "", 1_000_000_000)).products.len);
}

test "POS fractional quantities, authoritative discounts, rounding and cart validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    const product = try saveProduct(db, a, testProduct());
    var lines = [_]CartLine{testLine(product)};
    const input = testCart(&lines);
    const result = try quote(db, a, input);
    try std.testing.expectEqual(@as(i64, 7_501), result.items[0].gross);
    try std.testing.expectEqual(@as(i64, 501), result.items[0].discount);
    try std.testing.expectEqual(@as(i64, 6_300), result.totals.total);
    lines[0].discount_kind = "percent";
    lines[0].discount_value = 5_000;
    try std.testing.expectEqual(@as(i64, 3_751), (try quote(db, a, input)).items[0].discount);
    lines[0].discount_value = 10_001;
    try std.testing.expectError(error.InvalidDiscount, quote(db, a, input));
    lines[0] = testLine(product);
    lines[0].quantity_milli = 0;
    try std.testing.expectError(error.InvalidCart, quote(db, a, input));
    lines[0].quantity_milli = 2_001;
    try std.testing.expectError(error.InsufficientStock, quote(db, a, input));
    lines[0] = testLine(product);
    lines[0].note = "bad\rnote";
    try std.testing.expectError(error.InvalidCart, quote(db, a, input));
    lines[0] = testLine(product);
    lines[0].discount_kind = "none";
    try std.testing.expectError(error.InvalidDiscount, quote(db, a, input));
    lines[0].discount_kind = "nominal";
    lines[0].discount_value = 7_502;
    try std.testing.expectError(error.DiscountExceedsBase, quote(db, a, input));
    const duplicated = [_]CartLine{ testLine(product), testLine(product) };
    try std.testing.expectError(error.InvalidCart, quote(db, a, testCart(&duplicated)));
    try std.testing.expectError(error.InvalidCart, quote(db, a, testCart(&.{})));
    const too_many = [_]CartLine{testLine(product)} ** 41;
    try std.testing.expectError(error.InvalidCart, quote(db, a, testCart(&too_many)));
    lines[0] = testLine(product);
    var update = testProduct();
    update.id = product.id;
    update.revision = product.revision;
    update.price += 100;
    _ = try saveProduct(db, a, update);
    try std.testing.expectError(error.ProductChanged, quote(db, a, input));
    try db.exec("DELETE FROM business;");
    try std.testing.expectError(error.BusinessRequired, quote(db, a, input));
}

test "POS checkout rollback on real trigger failure includes invoice sequence and stock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    const product = try saveProduct(db, a, testProduct());
    const lines = [_]CartLine{testLine(product)};
    var input = CheckoutInput{ .checkout_id = "atomic", .cart = testCart(&lines), .tendered = 10_000, .expected_total = 6_300 };
    input.expected_total = 6_301;
    try std.testing.expectError(error.TotalChanged, checkout(db, a, input));
    input.expected_total = 6_300;
    input.tendered = 6_299;
    try std.testing.expectError(error.Underpayment, checkout(db, a, input));
    input.tendered = 10_000;
    try db.exec("CREATE TRIGGER reject_payment BEFORE INSERT ON payment BEGIN SELECT RAISE(ABORT,'test failure'); END;");
    try std.testing.expectError(error.ConstraintViolation, checkout(db, a, input));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sale;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sale_item;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM payment;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sale_sequence;"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM stock_movement;"));
    const unchanged = try getProduct(db, a, product.id);
    try std.testing.expectEqual(product.revision, unchanged.revision);
    try std.testing.expectEqual(product.stock_milli, unchanged.stock_milli);
    try db.exec("DROP TRIGGER reject_payment;");
    const sale = try checkout(db, a, input);
    try std.testing.expect(std.mem.endsWith(u8, sale.number, "-0001"));
    try std.testing.expect(std.mem.startsWith(u8, sale.number, "INV-"));
    try std.testing.expect(std.mem.endsWith(u8, sale.created_at, "Z"));
    try std.testing.expectEqual(@as(i64, 3_700), sale.change);
    const remaining = try getProduct(db, a, product.id);
    try std.testing.expectEqual(product.revision + 1, remaining.revision);
    try std.testing.expectEqual(@as(?i64, 1_500), remaining.stock_milli);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM stock_movement WHERE kind='sale' AND quantity_milli=-500 AND before_milli=2000 AND after_milli=1500;"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM payment WHERE method='cash' AND amount=6300 AND tendered=10000 AND change=3700;"));
}

test "POS sale snapshots survive edits and archive, replay precedes business and products" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    const product = try saveProduct(db, a, testProduct());
    const lines = [_]CartLine{testLine(product)};
    var input = CheckoutInput{ .checkout_id = "snapshot-replay", .cart = testCart(&lines), .tendered = 10_000, .expected_total = 6_300 };
    const original = try checkout(db, a, input);
    try std.testing.expectEqualDeep(original, try checkout(db, a, input));
    input.tendered += 1;
    try std.testing.expectError(error.IdempotencyConflict, checkout(db, a, input));
    input.tendered -= 1;
    const current = try getProduct(db, a, product.id);
    var edit = testProduct();
    edit.id = current.id;
    edit.revision = current.revision;
    edit.name = "Baru";
    edit.sku = "NEW";
    edit.barcode = "999";
    edit.category = "New category";
    edit.unit = "pcs";
    edit.price = 20_000;
    edit.cost = 12_000;
    const edited = try saveProduct(db, a, edit);
    try db.saveBusiness(.{ .name = "New business", .mode = "food", .address = "New address" });
    try archiveProduct(db, edited.id, edited.revision);
    const detail = try saleDetail(db, a, original.id);
    try std.testing.expectEqualDeep(original, detail);
    try std.testing.expectEqualStrings("0123", detail.items[0].barcode);
    try std.testing.expectEqualStrings("Sembako", detail.items[0].category);
    try db.exec("DELETE FROM business;");
    try std.testing.expectEqualDeep(original, try checkout(db, a, input));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
    input.expected_total += 1;
    try std.testing.expectError(error.IdempotencyConflict, checkout(db, a, input));
    try std.testing.expectError(error.SaleNotFound, saleDetail(db, a, original.id + 1));
}

test "POS sale date validation, local date filtering, newest first and pagination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testDb();
    defer db.close();
    var product_input = testProduct();
    product_input.stock_milli = null;
    const product = try saveProduct(db, a, product_input);
    const lines = [_]CartLine{testLine(product)};
    for (0..22) |index| {
        _ = try checkout(db, a, .{ .checkout_id = try std.fmt.allocPrint(a, "history-{d}", .{index}), .cart = testCart(&lines), .tendered = 10_000, .expected_total = 6_300 });
    }
    const first = try listSales(db, a, "", 0);
    const second = try listSales(db, a, "", 20);
    try std.testing.expectEqual(@as(usize, 20), first.sales.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqual(@as(i64, 22), first.sales[0].id);
    try std.testing.expectEqual(@as(i64, 1), first.sales[0].item_count);
    try std.testing.expectEqual(@as(usize, 2), second.sales.len);
    try std.testing.expect(!second.has_more);
    const date = try db.text(a, "SELECT date('now','localtime');");
    try std.testing.expectEqual(@as(usize, 20), (try listSales(db, a, date, 0)).sales.len);
    try db.exec("UPDATE sale SET sale_date='2024-02-29' WHERE id=1;");
    try std.testing.expectEqual(@as(usize, 1), (try listSales(db, a, "2024-02-29", 0)).sales.len);
    for ([_][]const u8{ "2026-02-29", "1900-02-29", "2026-04-31", "2026-00-10", "2026-01-00", "2026-13-01", "2026-1-01", "0000-01-01", "2026-01-01'" }) |invalid| {
        try std.testing.expectError(error.InvalidQuery, listSales(db, a, invalid, 0));
    }
    try std.testing.expectEqual(@as(usize, 0), (try listSales(db, a, "2000-02-29", 0)).sales.len);
    try std.testing.expectError(error.InvalidQuery, listSales(db, a, "", -1));
}

fn testAllocationRollback(a: Allocator) !void {
    const db = try testDb();
    defer db.close();
    const setup = std.testing.allocator;
    const product = try saveProduct(db, setup, testProduct());
    defer freeOwned(Product, setup, product);
    const lines = [_]CartLine{testLine(product)};
    const input = CheckoutInput{ .checkout_id = "oom-retry", .cart = testCart(&lines), .tendered = 10_000, .expected_total = 6_300 };
    const sale = checkout(db, a, input) catch |err| {
        try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sale;"));
        try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM sale_sequence;"));
        try std.testing.expectEqual(@as(i64, 2_000), try db.integer("SELECT stock_milli FROM product;"));
        const retry = try checkout(db, setup, input);
        defer freeOwned(Sale, setup, retry);
        try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
        return err;
    };
    defer freeOwned(Sale, a, sale);
    const replay = try checkout(db, a, input);
    defer freeOwned(Sale, a, replay);
    try std.testing.expectEqualDeep(sale, replay);
}

test "POS checkout and replay release partial owned results under every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAllocationRollback, .{});
}
