const std = @import("std");
const sqlite = @import("../infra/db/sqlite.zig");
const printer = @import("../infra/printer.zig");
const receipt = @import("../domain/receipt.zig");
const pos = @import("pos.zig");
const Database = sqlite.Database;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    printer_kind: []const u8,
    printer_name: []const u8,
    file_path: []const u8,
    tcp_host: []const u8,
    tcp_port: i64,
    paper_width: i64,
    header: []const u8,
    footer: []const u8,
    qr_payload: []const u8,
    copies: i64,
    feed_lines: i64,
    show_sku: bool,
    show_barcode: bool,
    show_qr: bool,
    cash_drawer: bool,
    cut_paper: bool,
};

pub const Preview = struct {
    text: []u8,
    bytes: []u8,
    width: i64,
};

pub fn defaultConfig() Config {
    return .{
        .printer_kind = "spooler",
        .printer_name = "",
        .file_path = "",
        .tcp_host = "",
        .tcp_port = 9100,
        .paper_width = 80,
        .header = "",
        .footer = "",
        .qr_payload = "",
        .copies = 1,
        .feed_lines = 3,
        .show_sku = false,
        .show_barcode = false,
        .show_qr = false,
        .cash_drawer = true,
        .cut_paper = true,
    };
}

pub fn validateConfig(config: Config) !void {
    if (!std.mem.eql(u8, config.printer_kind, "spooler") and
        !std.mem.eql(u8, config.printer_kind, "file") and
        !std.mem.eql(u8, config.printer_kind, "tcp")) return error.InvalidConfig;
    if (config.paper_width != 58 and config.paper_width != 80) return error.InvalidConfig;
    if (config.tcp_port < 1 or config.tcp_port > 65535) return error.InvalidConfig;
    if (config.copies < 1 or config.copies > 5) return error.InvalidConfig;
    if (config.feed_lines < 0 or config.feed_lines > 20) return error.InvalidConfig;
    try validText(config.printer_name, 255, false);
    try validText(config.file_path, 512, false);
    try validText(config.tcp_host, 255, false);
    try validText(config.header, 512, true);
    try validText(config.footer, 512, true);
    try validText(config.qr_payload, 512, false);
}

fn validText(value: []const u8, max_bytes: usize, multiline: bool) !void {
    if (value.len > max_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidConfig;
    for (value) |byte| {
        if (multiline and (byte == '\n' or byte == '\r' or byte == '\t')) continue;
        if (byte < 32 or byte == 127) return error.InvalidConfig;
    }
}

// The caller's arena owns all returned strings.
pub fn loadConfig(db: Database, a: Allocator) !Config {
    const s = try db.prepare("SELECT printer_kind,printer_name,file_path,tcp_host,tcp_port,paper_width,header,footer,qr_payload,copies,feed_lines,show_sku,show_barcode,show_qr,cash_drawer,cut_paper FROM device_config WHERE id=1;");
    defer s.close();
    if (!try s.next()) return defaultConfig();
    const config = Config{
        .printer_kind = try a.dupe(u8, s.columnText(0)),
        .printer_name = try a.dupe(u8, s.columnText(1)),
        .file_path = try a.dupe(u8, s.columnText(2)),
        .tcp_host = try a.dupe(u8, s.columnText(3)),
        .tcp_port = s.columnInt(4),
        .paper_width = s.columnInt(5),
        .header = try a.dupe(u8, s.columnText(6)),
        .footer = try a.dupe(u8, s.columnText(7)),
        .qr_payload = try a.dupe(u8, s.columnText(8)),
        .copies = s.columnInt(9),
        .feed_lines = s.columnInt(10),
        .show_sku = s.columnInt(11) != 0,
        .show_barcode = s.columnInt(12) != 0,
        .show_qr = s.columnInt(13) != 0,
        .cash_drawer = s.columnInt(14) != 0,
        .cut_paper = s.columnInt(15) != 0,
    };
    try validateConfig(config);
    return config;
}

pub fn saveConfig(db: Database, config: Config) !void {
    try validateConfig(config);
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    const s = try db.prepare("INSERT INTO device_config(id,printer_kind,printer_name,file_path,tcp_host,tcp_port,paper_width,header,footer,qr_payload,copies,feed_lines,show_sku,show_barcode,show_qr,cash_drawer,cut_paper) VALUES(1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET printer_kind=excluded.printer_kind,printer_name=excluded.printer_name,file_path=excluded.file_path,tcp_host=excluded.tcp_host,tcp_port=excluded.tcp_port,paper_width=excluded.paper_width,header=excluded.header,footer=excluded.footer,qr_payload=excluded.qr_payload,copies=excluded.copies,feed_lines=excluded.feed_lines,show_sku=excluded.show_sku,show_barcode=excluded.show_barcode,show_qr=excluded.show_qr,cash_drawer=excluded.cash_drawer,cut_paper=excluded.cut_paper,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');");
    defer s.close();
    try s.bindText(1, config.printer_kind);
    try s.bindText(2, config.printer_name);
    try s.bindText(3, config.file_path);
    try s.bindText(4, config.tcp_host);
    try s.bindInt(5, config.tcp_port);
    try s.bindInt(6, config.paper_width);
    try s.bindText(7, config.header);
    try s.bindText(8, config.footer);
    try s.bindText(9, config.qr_payload);
    try s.bindInt(10, config.copies);
    try s.bindInt(11, config.feed_lines);
    try s.bindInt(12, @intFromBool(config.show_sku));
    try s.bindInt(13, @intFromBool(config.show_barcode));
    try s.bindInt(14, @intFromBool(config.show_qr));
    try s.bindInt(15, @intFromBool(config.cash_drawer));
    try s.bindInt(16, @intFromBool(config.cut_paper));
    if (try s.next()) return error.UnexpectedResult;
    try db.exec("COMMIT;");
}

pub fn listPrinters(a: Allocator) ![]printer.Printer {
    return printer.listPrinters(a);
}

fn templateFrom(config: Config, business_name: []const u8, business_address: []const u8) !receipt.Template {
    const width: receipt.Width = switch (config.paper_width) {
        58 => .mm58,
        80 => .mm80,
        else => return error.InvalidConfig,
    };
    return .{
        .logo = null,
        .business_name = business_name,
        .business_address = business_address,
        .header = config.header,
        .footer = config.footer,
        .width = width,
        .show_sku = config.show_sku,
        .show_barcode = config.show_barcode,
        .show_qr = config.show_qr,
        .qr_payload = config.qr_payload,
        .copies = @intCast(config.copies),
        .cash_drawer = config.cash_drawer,
        .cut_paper = config.cut_paper,
        .feed_lines = @intCast(config.feed_lines),
    };
}

fn targetFrom(config: Config) !printer.Target {
    if (std.mem.eql(u8, config.printer_kind, "spooler")) {
        if (config.printer_name.len == 0) return error.InvalidConfig;
        return .{ .spooler = config.printer_name };
    }
    if (std.mem.eql(u8, config.printer_kind, "file")) {
        if (config.file_path.len == 0) return error.InvalidConfig;
        return .{ .file = config.file_path };
    }
    if (std.mem.eql(u8, config.printer_kind, "tcp")) {
        if (config.tcp_host.len == 0) return error.InvalidConfig;
        return .{ .tcp = .{ .host = config.tcp_host, .port = @intCast(config.tcp_port) } };
    }
    return error.InvalidConfig;
}

fn send(config: Config, bytes: []const u8) !void {
    const target = try targetFrom(config);
    printer.send(target, bytes) catch |err| return switch (err) {
        error.PrinterUnreachable => error.PrinterUnreachable,
        error.PrinterNotFound => error.PrinterNotFound,
        error.PrintUnknown => error.PrintUnknown,
        error.OutOfMemory => error.OutOfMemory,
        else => error.PrinterFailed,
    };
}

pub fn previewSale(db: Database, a: Allocator, sale_id: i64) !Preview {
    const config = try loadConfig(db, a);
    const sale = try pos.saleDetail(db, a, sale_id);
    const template = try templateFrom(config, sale.business_name, sale.business_address);
    const built = try receipt.build(a, sale, template, false);
    return .{
        .text = try receipt.renderText(a, built, template),
        .bytes = try receipt.renderEscPos(a, built, template),
        .width = config.paper_width,
    };
}

pub fn printSale(db: Database, a: Allocator, sale_id: i64, is_copy: bool) !void {
    const config = try loadConfig(db, a);
    const sale = try pos.saleDetail(db, a, sale_id);
    var template = try templateFrom(config, sale.business_name, sale.business_address);
    if (is_copy) template.cash_drawer = false;
    const built = try receipt.build(a, sale, template, is_copy);
    const bytes = try receipt.renderEscPos(a, built, template);
    if (is_copy) {
        try sendAudited(db, config, bytes, "reprint", "sale", sale.number);
    } else {
        try send(config, bytes);
    }
}

pub fn testPrint(db: Database, a: Allocator) !void {
    const config = try loadConfig(db, a);
    const business = try db.business(a);
    const name = if (business) |b| b.name else "KasirKu";
    const address = if (business) |b| b.address else "";
    var template = try templateFrom(config, name, address);
    template.cash_drawer = false;
    const built = try receipt.build(a, testSale(), template, false);
    const bytes = try receipt.renderEscPos(a, built, template);
    try send(config, bytes);
}

pub fn openDrawer(db: Database, a: Allocator) !void {
    const config = try loadConfig(db, a);
    const kick = &[_]u8{ 0x1B, '@', 0x1B, 'p', 0, 25, 250 };
    sendAudited(db, config, kick, "drawer_open", "device", "") catch |err| return switch (err) {
        error.PrintUnknown => error.DrawerUnknown,
        else => err,
    };
}

fn sendAudited(db: Database, config: Config, bytes: []const u8, kind: []const u8, entity_type: []const u8, entity_id: []const u8) !void {
    _ = try targetFrom(config);
    // Persist the attempt before IO; a crash must not erase the audit trail.
    const id = try audit(db, kind, entity_type, entity_id);
    send(config, bytes) catch |err| {
        finishAudit(db, id, if (err == error.PrintUnknown) "unknown" else "failed") catch return error.PrintUnknown;
        return err;
    };
    finishAudit(db, id, "submitted") catch return error.PrintUnknown;
}

fn audit(db: Database, kind: []const u8, entity_type: []const u8, entity_id: []const u8) !i64 {
    const s = try db.prepare("INSERT INTO audit_log(kind,entity_type,entity_id,detail) VALUES(?,?,?,'attempt');");
    defer s.close();
    try s.bindText(1, kind);
    try s.bindText(2, entity_type);
    try s.bindText(3, entity_id);
    if (try s.next()) return error.UnexpectedResult;
    return sqlite.c.sqlite3_last_insert_rowid(db.handle);
}

fn finishAudit(db: Database, id: i64, detail: []const u8) !void {
    const s = try db.prepare("UPDATE audit_log SET detail=? WHERE id=?;");
    defer s.close();
    try s.bindText(1, detail);
    try s.bindInt(2, id);
    if (try s.next()) return error.UnexpectedResult;
}

const TestTotals = struct {
    gross: i64,
    line_discount: i64,
    transaction_discount: i64,
    service_charge: i64,
    tax: i64,
    rounding_adjustment: i64,
    total: i64,
};

const TestItem = struct {
    name: []const u8,
    sku: []const u8,
    barcode: []const u8,
    unit: []const u8,
    unit_price: i64,
    quantity_milli: i64,
    discount_kind: []const u8,
    discount: i64,
    note: []const u8,
    net: i64,
};

const TestSale = struct {
    number: []const u8,
    created_at: []const u8,
    totals: TestTotals,
    tendered: i64,
    change: i64,
    items: []const TestItem,
};

fn testSale() TestSale {
    return .{
        .number = "UJI-CETAK",
        .created_at = "halaman uji cetak",
        .totals = .{ .gross = 10_000, .line_discount = 0, .transaction_discount = 0, .service_charge = 0, .tax = 0, .rounding_adjustment = 0, .total = 10_000 },
        .tendered = 10_000,
        .change = 0,
        .items = &[_]TestItem{.{
            .name = "Barang uji",
            .sku = "UJI",
            .barcode = "",
            .unit = "pcs",
            .unit_price = 10_000,
            .quantity_milli = 1_000,
            .discount_kind = "none",
            .discount = 0,
            .note = "",
            .net = 10_000,
        }},
    };
}

fn seedSale(db: Database, a: Allocator) !i64 {
    const product = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Kopi", .sku = "", .barcode = "", .category = "", .unit = "pcs", .price = 10_000, .cost = 5_000, .stock_milli = 5_000 });
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1_000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    const sale = try pos.checkout(db, a, .{ .checkout_id = "device-seed", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 10_000, .expected_total = 10_000 });
    return sale.id;
}

fn fileConfig(path: []const u8) Config {
    var config = defaultConfig();
    config.printer_kind = "file";
    config.file_path = path;
    return config;
}

test "device config defaults, round trips, and rejects invalid values" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");

    const initial = try loadConfig(db, work);
    try std.testing.expectEqualStrings("spooler", initial.printer_kind);
    try std.testing.expectEqual(@as(i64, 80), initial.paper_width);
    try std.testing.expectEqual(@as(i64, 9100), initial.tcp_port);
    try std.testing.expect(initial.cash_drawer);

    var config = defaultConfig();
    config.printer_kind = "tcp";
    config.tcp_host = "192.168.1.20";
    config.paper_width = 58;
    config.header = "Selamat datang";
    config.footer = "Terima kasih";
    config.copies = 2;
    config.show_sku = true;
    config.cut_paper = false;
    try saveConfig(db, config);

    const loaded = try loadConfig(db, work);
    try std.testing.expectEqualStrings("tcp", loaded.printer_kind);
    try std.testing.expectEqualStrings("192.168.1.20", loaded.tcp_host);
    try std.testing.expectEqual(@as(i64, 58), loaded.paper_width);
    try std.testing.expectEqualStrings("Selamat datang", loaded.header);
    try std.testing.expectEqual(@as(i64, 2), loaded.copies);
    try std.testing.expect(loaded.show_sku);
    try std.testing.expect(!loaded.cut_paper);

    var bad = defaultConfig();
    bad.printer_kind = "carrier-pigeon";
    try std.testing.expectError(error.InvalidConfig, saveConfig(db, bad));
    bad = defaultConfig();
    bad.paper_width = 70;
    try std.testing.expectError(error.InvalidConfig, saveConfig(db, bad));
    bad = defaultConfig();
    bad.header = "inject\x1B@command";
    try std.testing.expectError(error.InvalidConfig, saveConfig(db, bad));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM device_config;"));
}

test "receipt preview renders text and escpos from a stored sale" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Uji", .mode = "retail", .address = "Jalan Uji" });
    const sale_id = try seedSale(db, work);

    var config = fileConfig("unused");
    config.footer = "Terima kasih";
    try saveConfig(db, config);

    const preview = try previewSale(db, work, sale_id);
    try std.testing.expect(preview.bytes.len > 2);
    try std.testing.expectEqual(@as(u8, 0x1B), preview.bytes[0]);
    try std.testing.expectEqual(@as(u8, '@'), preview.bytes[1]);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "Toko Uji") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "Terima kasih") != null);
    try std.testing.expectEqual(@as(i64, 80), preview.width);
    try std.testing.expectError(error.SaleNotFound, previewSale(db, work, 999));
}

test "reprint to a file target marks a copy and writes an audit row" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(work, ".");
    const out = try std.fmt.allocPrint(work, "{s}/receipt.bin", .{directory});

    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Uji", .mode = "retail", .address = "" });
    const sale_id = try seedSale(db, work);
    try saveConfig(db, fileConfig(out));

    try printSale(db, work, sale_id, true);
    const copy_bytes = try std.fs.cwd().readFileAlloc(work, out, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, copy_bytes, "*** SALINAN ***") != null);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE kind='reprint';"));
    const entity = try db.text(work, "SELECT entity_id FROM audit_log WHERE kind='reprint';");
    try std.testing.expect(entity.len > 0);

    try printSale(db, work, sale_id, false);
    const plain_bytes = try std.fs.cwd().readFileAlloc(work, out, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, plain_bytes, "*** SALINAN ***") == null);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE kind='reprint';"));
}

test "manual drawer open sends the kick and audits" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(work, ".");
    const out = try std.fmt.allocPrint(work, "{s}/drawer.bin", .{directory});

    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try saveConfig(db, fileConfig(out));

    try openDrawer(db, work);
    const bytes = try std.fs.cwd().readFileAlloc(work, out, 64);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1B, '@', 0x1B, 'p', 0, 25, 250 }, bytes);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE kind='drawer_open';"));
}

test "device test print writes a branded diagnostic page" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(work, ".");
    const out = try std.fmt.allocPrint(work, "{s}/test.bin", .{directory});

    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Uji", .mode = "retail", .address = "" });
    try saveConfig(db, fileConfig(out));

    try testPrint(db, work);
    const bytes = try std.fs.cwd().readFileAlloc(work, out, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Toko Uji") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "UJI-CETAK") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &.{ 0x1B, 'p', 0, 25, 250 }) == null);
}

test "audited actions stop before IO if the audit cannot be persisted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    const out = try std.fmt.allocPrint(a, "{s}/blocked.bin", .{directory});
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Audit Test", .mode = "retail", .address = "" });
    const id = try seedSale(db, a);
    try saveConfig(db, fileConfig(out));
    try db.exec("CREATE TRIGGER reject_audit BEFORE INSERT ON audit_log BEGIN SELECT RAISE(ABORT,'audit unavailable'); END;");
    try std.testing.expectError(error.ConstraintViolation, printSale(db, a, id, true));
    try std.testing.expectError(error.ConstraintViolation, openDrawer(db, a));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(out, .{}));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM audit_log;"));
}

test "audit completion failure reports uncertainty after IO without losing the attempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    const out = try std.fmt.allocPrint(a, "{s}/uncertain.bin", .{directory});
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Audit Test", .mode = "retail", .address = "" });
    const id = try seedSale(db, a);
    try saveConfig(db, fileConfig(out));
    try db.exec("CREATE TRIGGER reject_completion BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT,'audit unavailable'); END;");
    try std.testing.expectError(error.PrintUnknown, printSale(db, a, id, true));
    const copy = try std.fs.cwd().readFileAlloc(a, out, 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, copy, "*** SALINAN ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, copy, &.{ 0x1B, 'p', 0, 25, 250 }) == null);
    try std.testing.expectError(error.DrawerUnknown, openDrawer(db, a));
    const drawer = try std.fs.cwd().readFileAlloc(a, out, 64);
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, '@', 0x1B, 'p', 0, 25, 250 }, drawer);
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM audit_log WHERE detail='attempt';"));
}

test "restored configuration cannot inject commands or lose multiline text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    var config = defaultConfig();
    config.header = "Baris satu\r\nBaris dua";
    config.footer = "Terima\tkasih\nKembali lagi";
    try saveConfig(db, config);
    const restored = try loadConfig(db, a);
    try std.testing.expectEqualStrings(config.header, restored.header);
    try db.exec("UPDATE device_config SET footer='evil'||char(27)||'@';");
    try std.testing.expectError(error.InvalidConfig, loadConfig(db, a));
}
