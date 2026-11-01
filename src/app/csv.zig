const std = @import("std");
const sqlite = @import("../infra/db/sqlite.zig");
const money = @import("../domain/money.zig");
const pos = @import("pos.zig");
const report = @import("report.zig");
const Database = sqlite.Database;
const Allocator = std.mem.Allocator;

pub const max_import_bytes = 8 * 1024 * 1024;
pub const max_import_rows = 20_000;
const max_preview_rows = 10;
const max_preview_errors = 20;
const product_header = [_][]const u8{ "name", "sku", "barcode", "category", "unit", "price", "cost", "stock_milli", "min_stock_milli" };

pub const Export = union(enum) {
    products,
    dashboard: []const u8,
    sales: struct { from: []const u8, to: []const u8, group_by: []const u8 },
    profit: struct { from: []const u8, to: []const u8 },
    stock: []const u8,
};

pub const ImportError = struct { line: u32, code: []const u8 };
pub const ImportRow = struct { line: u32, product: pos.ProductInput };
pub const ImportPreview = struct {
    valid: bool,
    row_count: usize,
    error_count: usize,
    rows: []ImportRow,
    errors: []ImportError,
};

pub const ImportSession = struct {
    bytes: std.ArrayList(u8) = .empty,
    token: [32]u8 = undefined,
    ready: bool = false,

    pub fn begin(self: *ImportSession) ![]const u8 {
        self.bytes.clearRetainingCapacity();
        var random: [16]u8 = undefined;
        std.crypto.random.bytes(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        @memcpy(&self.token, &hex);
        self.ready = true;
        return &self.token;
    }

    pub fn append(self: *ImportSession, a: Allocator, token: []const u8, encoded: []const u8) !void {
        if (!self.matches(token)) return error.ImportSessionInvalid;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidPayload;
        if (size > 24 * 1024 or self.bytes.items.len + size > max_import_bytes) return error.ImportTooLarge;
        const decoded = try a.alloc(u8, size);
        defer a.free(decoded);
        decoder.decode(decoded, encoded) catch return error.InvalidPayload;
        try self.bytes.appendSlice(a, decoded);
    }

    pub fn matches(self: *const ImportSession, token: []const u8) bool {
        return self.ready and token.len == self.token.len and std.mem.eql(u8, token, &self.token);
    }

    pub fn clear(self: *ImportSession) void {
        self.ready = false;
        self.bytes.clearRetainingCapacity();
    }
};

const CsvWriter = struct {
    file: std.fs.File,
    column: usize = 0,

    fn write(self: *CsvWriter, bytes: []const u8) !void {
        self.file.writeAll(bytes) catch return error.ExportFailed;
    }

    fn raw(self: *CsvWriter, value: []const u8) !void {
        if (self.column != 0) try self.write(",");
        self.column += 1;
        try self.write(value);
    }

    fn text(self: *CsvWriter, value: []const u8) !void {
        if (self.column != 0) try self.write(",");
        self.column += 1;
        const dangerous = value.len > 0 and (value[0] == '=' or value[0] == '+' or value[0] == '-' or value[0] == '@');
        if (dangerous) try self.write("'");
        var quoted = dangerous;
        for (value) |byte| {
            if (byte == '"' or byte == ',' or byte == '\r' or byte == '\n') {
                quoted = true;
                break;
            }
        }
        if (!quoted) return self.write(value);
        try self.write("\"");
        for (value) |byte| {
            if (byte == '"') try self.write("\"\"") else try self.write(&.{byte});
        }
        try self.write("\"");
    }

    fn integer(self: *CsvWriter, value: anytype) !void {
        var buffer: [32]u8 = undefined;
        const text_value = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try self.raw(text_value);
    }

    fn optional(self: *CsvWriter, value: ?i64) !void {
        if (value) |number| try self.integer(number) else try self.text("");
    }

    fn row(self: *CsvWriter) !void {
        try self.write("\r\n");
        self.column = 0;
    }

    fn header(self: *CsvWriter, values: []const []const u8) !void {
        for (values) |value| try self.text(value);
        try self.row();
    }
};

fn summaryRows(writer: *CsvWriter, values: anytype) !void {
    inline for (values) |entry| {
        try writer.text(entry[0]);
        try writer.integer(entry[1]);
        try writer.row();
    }
}

pub fn exportFile(db: Database, a: Allocator, path: []const u8, selection: Export) !void {
    if (path.len == 0) return error.ExportFailed;
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.ExportFailed;
    defer file.close();
    var writer = CsvWriter{ .file = file };
    try writer.write("\xEF\xBB\xBF");
    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch {};
    switch (selection) {
        .products => try exportProducts(db, &writer),
        .dashboard => |date| try exportDashboard(db, a, &writer, date),
        .sales => |value| {
            var offset: i64 = 0;
            try writer.header(&.{ "group", "unit", "sale_count", "quantity_milli", "revenue", "cogs", "gross_profit" });
            while (true) {
                const result = try report.sales(db, a, value.from, value.to, value.group_by, offset);
                for (result.groups) |group| {
                    try writer.text(group.key);
                    try writer.text(group.unit);
                    try writer.integer(group.sale_count);
                    try writer.integer(group.quantity_milli);
                    try writer.integer(group.revenue);
                    try writer.integer(group.cogs);
                    try writer.integer(group.gross_profit);
                    try writer.row();
                }
                if (!result.has_more) break;
                offset += 50;
            }
        },
        .profit => |value| {
            const first = try report.profit(db, a, value.from, value.to, 0);
            try writer.header(&.{ "metric", "value" });
            try summaryRows(&writer, .{
                .{ "revenue", first.revenue },
                .{ "cogs", first.cogs },
                .{ "gross_profit", first.gross_profit },
                .{ "expense_total", first.expense_total },
                .{ "net_profit", first.net_profit },
            });
            try writer.row();
            try writer.header(&.{ "category", "amount" });
            var offset: i64 = 0;
            while (true) {
                const result = if (offset == 0) first else try report.profit(db, a, value.from, value.to, offset);
                for (result.expense_categories) |category| {
                    try writer.text(category.category);
                    try writer.integer(category.amount);
                    try writer.row();
                }
                if (!result.has_more) break;
                offset += 50;
            }
        },
        .stock => |filter| {
            var offset: i64 = 0;
            try writer.header(&.{ "name", "category", "unit", "cost", "stock_milli", "min_stock_milli", "stock_value", "last_sold_at", "low_stock", "dead_stock" });
            while (true) {
                const result = try report.stock(db, a, filter, offset);
                for (result.products) |product| {
                    try writer.text(product.name);
                    try writer.text(product.category);
                    try writer.text(product.unit);
                    try writer.integer(product.cost);
                    try writer.optional(product.stock_milli);
                    try writer.optional(product.min_stock_milli);
                    try writer.integer(product.stock_value);
                    try writer.text(product.last_sold_at orelse "");
                    try writer.integer(@intFromBool(product.low_stock));
                    try writer.integer(@intFromBool(product.dead_stock));
                    try writer.row();
                }
                if (!result.has_more) break;
                offset += 50;
            }
        },
    }
    try db.exec("COMMIT;");
    file.sync() catch return error.ExportFailed;
}

fn exportProducts(db: Database, writer: *CsvWriter) !void {
    try writer.header(&product_header);
    const s = try db.prepare("SELECT name,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli FROM product WHERE active=1 ORDER BY name COLLATE NOCASE,id;");
    defer s.close();
    while (try s.next()) {
        for (0..5) |index| try writer.text(s.columnText(@intCast(index)));
        try writer.integer(s.columnInt(5));
        try writer.integer(s.columnInt(6));
        try writer.optional(if (s.isNull(7)) null else s.columnInt(7));
        try writer.optional(if (s.isNull(8)) null else s.columnInt(8));
        try writer.row();
    }
}

fn exportDashboard(db: Database, a: Allocator, writer: *CsvWriter, date: []const u8) !void {
    const result = try report.dashboard(db, a, date);
    try writer.header(&.{ "metric", "value" });
    try summaryRows(writer, .{
        .{ "sale_count", result.sale_count },
        .{ "sales_total", result.sales_total },
        .{ "average_sale", result.average_sale },
        .{ "revenue", result.revenue },
        .{ "cogs", result.cogs },
        .{ "gross_profit", result.gross_profit },
    });
    try writer.row();
    try writer.header(&.{ "hour", "sale_count", "sales_total" });
    for (result.hours) |hour| {
        try writer.integer(hour.hour);
        try writer.integer(hour.sale_count);
        try writer.integer(hour.sales_total);
        try writer.row();
    }
    try writer.row();
    try writer.header(&.{ "product", "unit", "quantity_milli", "revenue", "cogs", "gross_profit" });
    for (result.top_products) |product| {
        try writer.text(product.name);
        try writer.text(product.unit);
        try writer.integer(product.quantity_milli);
        try writer.integer(product.revenue);
        try writer.integer(product.cogs);
        try writer.integer(product.gross_profit);
        try writer.row();
    }
}

const Record = struct { line: u32, fields: [][]const u8 };

fn nextRecord(a: Allocator, input: []const u8, index: *usize, line: *u32) !?Record {
    while (true) {
        if (index.* >= input.len) return null;
        const record_line = line.*;
        var fields: std.ArrayList([]const u8) = .empty;
        while (true) {
            var value: std.ArrayList(u8) = .empty;
            if (index.* < input.len and input[index.*] == '"') {
                index.* += 1;
                while (true) {
                    if (index.* >= input.len) return error.InvalidCsv;
                    const byte = input[index.*];
                    index.* += 1;
                    if (byte == '"') {
                        if (index.* < input.len and input[index.*] == '"') {
                            try value.append(a, '"');
                            index.* += 1;
                            continue;
                        }
                        break;
                    }
                    if (byte == '\n') line.* += 1;
                    if (byte == '\r' and (index.* >= input.len or input[index.*] != '\n')) line.* += 1;
                    try value.append(a, byte);
                }
                if (index.* < input.len and input[index.*] != ',' and input[index.*] != '\r' and input[index.*] != '\n') return error.InvalidCsv;
            } else {
                while (index.* < input.len and input[index.*] != ',' and input[index.*] != '\r' and input[index.*] != '\n') {
                    if (input[index.*] == '"') return error.InvalidCsv;
                    try value.append(a, input[index.*]);
                    index.* += 1;
                }
            }
            try fields.append(a, try value.toOwnedSlice(a));
            if (index.* >= input.len) break;
            if (input[index.*] == ',') {
                index.* += 1;
                continue;
            }
            if (input[index.*] == '\r') {
                index.* += 1;
                if (index.* < input.len and input[index.*] == '\n') index.* += 1;
            } else if (input[index.*] == '\n') index.* += 1;
            line.* += 1;
            break;
        }
        if (fields.items.len == 1 and fields.items[0].len == 0) continue;
        return .{ .line = record_line, .fields = fields.items };
    }
}

const ImportBuilder = struct {
    products: std.ArrayList(pos.ProductInput) = .empty,
    rows: std.ArrayList(ImportRow) = .empty,
    errors: std.ArrayList(ImportError) = .empty,
    error_count: usize = 0,

    fn fail(self: *ImportBuilder, a: Allocator, line: u32, code: []const u8) !void {
        self.error_count += 1;
        if (self.errors.items.len < max_preview_errors) try self.errors.append(a, .{ .line = line, .code = code });
    }
};

fn integerField(value: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidProduct;
    const result = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidProduct;
    if (result < 0 or result > money.max_amount) return error.InvalidProduct;
    return result;
}

fn optionalIntegerField(value: []const u8) !?i64 {
    if (std.mem.trim(u8, value, " \t").len == 0) return null;
    return try integerField(value);
}

pub fn previewImport(db: Database, a: Allocator, source: []const u8) !ImportPreview {
    if (source.len == 0 or source.len > max_import_bytes or !std.unicode.utf8ValidateSlice(source)) return error.InvalidCsv;
    const input = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
    var builder = ImportBuilder{};
    var index: usize = 0;
    var line: u32 = 1;
    const header = nextRecord(a, input, &index, &line) catch {
        try builder.fail(a, 1, "invalid_csv");
        return .{ .valid = false, .row_count = 0, .error_count = builder.error_count, .rows = &.{}, .errors = builder.errors.items };
    } orelse {
        try builder.fail(a, 1, "invalid_csv");
        return .{ .valid = false, .row_count = 0, .error_count = builder.error_count, .rows = &.{}, .errors = builder.errors.items };
    };
    if (header.fields.len != product_header.len) {
        try builder.fail(a, header.line, "invalid_csv");
    } else {
        for (product_header, header.fields) |expected, actual| {
            if (!std.mem.eql(u8, expected, actual)) {
                try builder.fail(a, header.line, "invalid_csv");
                break;
            }
        }
    }
    if (builder.error_count != 0) return .{ .valid = false, .row_count = 0, .error_count = builder.error_count, .rows = &.{}, .errors = builder.errors.items };
    var skus = std.StringHashMap(u32).init(a);
    var barcodes = std.StringHashMap(u32).init(a);
    while (true) {
        const record = nextRecord(a, input, &index, &line) catch {
            try builder.fail(a, line, "invalid_csv");
            break;
        } orelse break;
        if (builder.products.items.len >= max_import_rows) {
            try builder.fail(a, record.line, "import_row_limit");
            break;
        }
        if (record.fields.len != product_header.len) {
            try builder.fail(a, record.line, "invalid_csv");
            continue;
        }
        const input_product = blk: {
            const value = pos.ProductInput{
                .id = null,
                .revision = null,
                .name = record.fields[0],
                .sku = record.fields[1],
                .barcode = record.fields[2],
                .category = record.fields[3],
                .unit = record.fields[4],
                .price = integerField(record.fields[5]) catch {
                    try builder.fail(a, record.line, "invalid_product");
                    continue;
                },
                .cost = integerField(record.fields[6]) catch {
                    try builder.fail(a, record.line, "invalid_product");
                    continue;
                },
                .stock_milli = optionalIntegerField(record.fields[7]) catch {
                    try builder.fail(a, record.line, "invalid_product");
                    continue;
                },
                .min_stock_milli = optionalIntegerField(record.fields[8]) catch {
                    try builder.fail(a, record.line, "invalid_product");
                    continue;
                },
            };
            break :blk pos.validateProduct(value) catch {
                try builder.fail(a, record.line, "invalid_product");
                continue;
            };
        };
        var duplicate = false;
        if (input_product.sku.len > 0) {
            if (skus.contains(input_product.sku)) duplicate = true else try skus.put(input_product.sku, record.line);
        }
        if (input_product.barcode.len > 0) {
            if (barcodes.contains(input_product.barcode)) duplicate = true else try barcodes.put(input_product.barcode, record.line);
        }
        if (duplicate) {
            try builder.fail(a, record.line, "product_conflict");
            continue;
        }
        const conflicts = try db.prepare("SELECT (SELECT count(*) FROM product WHERE active=1 AND sku=?1 AND sku<>''),(SELECT count(*) FROM product WHERE active=1 AND barcode=?2 AND barcode<>'');");
        defer conflicts.close();
        try conflicts.bindText(1, input_product.sku);
        try conflicts.bindText(2, input_product.barcode);
        if (!try conflicts.next()) return error.NoResult;
        if (conflicts.columnInt(0) != 0 or conflicts.columnInt(1) != 0) {
            try builder.fail(a, record.line, "product_conflict");
            continue;
        }
        try builder.products.append(a, input_product);
        if (builder.rows.items.len < max_preview_rows) try builder.rows.append(a, .{ .line = record.line, .product = input_product });
    }
    if (builder.products.items.len == 0 and builder.error_count == 0) try builder.fail(a, 1, "invalid_csv");
    return .{
        .valid = builder.error_count == 0,
        .row_count = builder.products.items.len,
        .error_count = builder.error_count,
        .rows = builder.rows.items,
        .errors = builder.errors.items,
    };
}

pub fn applyImport(db: Database, a: Allocator, source: []const u8) !usize {
    const preview = try previewImport(db, a, source);
    if (!preview.valid) return error.InvalidCsv;
    const count = preview.row_count;
    var index: usize = 0;
    var line: u32 = 1;
    const input = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
    _ = try nextRecord(a, input, &index, &line);
    var products: std.ArrayList(pos.ProductInput) = .empty;
    while (try nextRecord(a, input, &index, &line)) |record| {
        try products.append(a, try pos.validateProduct(.{
            .id = null,
            .revision = null,
            .name = record.fields[0],
            .sku = record.fields[1],
            .barcode = record.fields[2],
            .category = record.fields[3],
            .unit = record.fields[4],
            .price = try integerField(record.fields[5]),
            .cost = try integerField(record.fields[6]),
            .stock_milli = try optionalIntegerField(record.fields[7]),
            .min_stock_milli = try optionalIntegerField(record.fields[8]),
        }));
    }
    try pos.importProducts(db, products.items);
    return count;
}

test "CSV product import previews quoted rows and applies atomically" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko CSV", .mode = "retail", .address = "" });
    const source = "\xEF\xBB\xBFname,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\r\n\"Kopi, enak\",K-1,899,\"Minuman\",\"gelas\",10000,6000,2.5,1\r\nJasa,,,\"\",layanan,5000,0,,\r\n";
    const invalid = try previewImport(db, work, source);
    try std.testing.expect(!invalid.valid);
    try std.testing.expectEqual(@as(usize, 1), invalid.error_count);
    try std.testing.expectEqual(@as(u32, 2), invalid.errors[0].line);
    const valid_source = "\xEF\xBB\xBFname,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\r\n\"Kopi, enak\",K-1,899,\"Minuman\",\"gelas\",10000,6000,2500,1000\r\nJasa,,,\"\",layanan,5000,0,,\r\n";
    const preview = try previewImport(db, work, valid_source);
    try std.testing.expect(preview.valid);
    try std.testing.expectEqual(@as(usize, 2), preview.row_count);
    try std.testing.expectEqualStrings("Kopi, enak", preview.rows[0].product.name);
    try std.testing.expectEqual(@as(usize, 2), try applyImport(db, work, valid_source));
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM product;"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM stock_movement WHERE kind='initial';"));
    const conflict = try previewImport(db, work, valid_source);
    try std.testing.expect(!conflict.valid);
    try std.testing.expectEqualStrings("product_conflict", conflict.errors[0].code);
}

test "CSV rejects malformed headers duplicates and imports nothing after an error" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko CSV", .mode = "retail", .address = "" });
    const duplicate = "name,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\nSatu,X,,,pcs,1000,0,,\nDua,X,,,pcs,2000,0,,\n";
    const preview = try previewImport(db, work, duplicate);
    try std.testing.expect(!preview.valid);
    try std.testing.expectEqual(@as(u32, 3), preview.errors[0].line);
    try std.testing.expectError(error.InvalidCsv, applyImport(db, work, duplicate));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM product;"));
    const malformed = "name,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\n\"Belum selesai,X,,,pcs,1000,0,,";
    try std.testing.expect(!(try previewImport(db, work, malformed)).valid);
    const wrong_header = "nama,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli\n";
    try std.testing.expect(!(try previewImport(db, work, wrong_header)).valid);
}

test "CSV export writes Excel safe UTF8 and every report row" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(work, ".");
    const path = try std.fmt.allocPrint(work, "{s}/products.csv", .{directory});
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko CSV", .mode = "retail", .address = "" });
    _ = try pos.saveProduct(db, work, .{ .id = null, .revision = null, .name = "=HYPERLINK(\"bad\")", .sku = "X,1", .barcode = "", .category = "Uji", .unit = "pcs", .price = 1000, .cost = 500, .stock_milli = null });
    try exportFile(db, work, path, .products);
    const bytes = try std.fs.cwd().readFileAlloc(work, path, 1 << 16);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "'\"=HYPERLINK(\"\"bad\"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"X,1\"") != null);
    const today = try report.dashboard(db, work, "");
    const dashboard_path = try std.fmt.allocPrint(work, "{s}/dashboard.csv", .{directory});
    try exportFile(db, work, dashboard_path, .{ .dashboard = today.date });
    const dashboard_csv = try std.fs.cwd().readFileAlloc(work, dashboard_path, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_csv, "gross_profit") != null);
}
