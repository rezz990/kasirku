const std = @import("std");
const db_module = @import("../infra/db/sqlite.zig");
const Database = db_module.Database;
const pos = @import("../app/pos.zig");
const device = @import("../app/device.zig");
const shift = @import("../app/shift.zig");
const money = @import("../domain/money.zig");
const Envelope = struct { id: []const u8, command: []const u8, payload: std.json.Value };
const max_message_bytes = 64 * 1024;

pub fn dispatch(allocator: std.mem.Allocator, db: Database, input: []const u8) ![]const u8 {
    if (input.len > max_message_bytes) return failure(allocator, null, "message_too_large");
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{ .max_value_len = max_message_bytes }) catch return failure(allocator, null, "invalid_request");
    defer parsed.deinit();
    const object = parsed.value;
    if (object != .object or object.object.count() != 3) return failure(allocator, null, "invalid_request");
    const id = object.object.get("id") orelse return failure(allocator, null, "invalid_request");
    const command = object.object.get("command") orelse return failure(allocator, null, "invalid_request");
    const payload = object.object.get("payload") orelse return failure(allocator, null, "invalid_request");
    if (id != .string or command != .string or payload != .object) return failure(allocator, null, "invalid_request");
    const request = Envelope{ .id = id.string, .command = command.string, .payload = payload };
    if (request.id.len == 0 or request.id.len > 80) return failure(allocator, null, "invalid_request");
    for (request.id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return failure(allocator, null, "invalid_request");
    }
    if (std.mem.eql(u8, request.command, "system.ping")) {
        if (request.payload.object.count() != 0) return failure(allocator, request.id, "invalid_payload");
        return success(allocator, request.id, .{ .pong = true, .protocol_version = @as(u32, 1) });
    }
    if (std.mem.eql(u8, request.command, "app.status")) {
        if (request.payload.object.count() != 0) return failure(allocator, request.id, "invalid_payload");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const business = db.business(arena.allocator()) catch return failure(allocator, request.id, "database_unavailable");
        return success(allocator, request.id, .{
            .version = "0.1.0",
            .schema_version = db_module.schema_version,
            .business = business,
            .storage = "sqlite",
            .durability = "wal_full",
        });
    }
    if (std.mem.eql(u8, request.command, "business.save")) {
        const value = businessPayload(request.payload) catch return failure(allocator, request.id, "invalid_business");
        db.saveBusiness(value) catch |err| return failure(allocator, request.id, switch (err) {
            error.InvalidBusiness => "invalid_business",
            error.DatabaseBusy => "database_busy",
            error.DiskFull => "disk_full",
            else => "database_unavailable",
        });
        return success(allocator, request.id, .{ .saved = true });
    }
    return dispatchPos(allocator, db, request) catch |err| failure(allocator, request.id, errorCode(err));
}

fn dispatchPos(allocator: std.mem.Allocator, db: Database, request: Envelope) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = request.payload;
    if (std.mem.eql(u8, request.command, "product.list")) {
        try fields(p, 2);
        return success(allocator, request.id, try pos.listProducts(db, a, try string(p, "query"), try integer(p, "offset")));
    }
    if (std.mem.eql(u8, request.command, "product.save")) {
        try fields(p, 10);
        const product = try pos.saveProduct(db, a, .{
            .id = try optionalInteger(p, "id"),
            .revision = try optionalInteger(p, "revision"),
            .name = try string(p, "name"),
            .sku = try string(p, "sku"),
            .barcode = try string(p, "barcode"),
            .category = try string(p, "category"),
            .unit = try string(p, "unit"),
            .price = try integer(p, "price"),
            .cost = try integer(p, "cost"),
            .stock_milli = try optionalInteger(p, "stock_milli"),
        });
        return success(allocator, request.id, .{ .product = product });
    }
    if (std.mem.eql(u8, request.command, "product.archive")) {
        try fields(p, 2);
        try pos.archiveProduct(db, try positiveInteger(p, "id"), try positiveInteger(p, "revision"));
        return success(allocator, request.id, .{ .archived = true });
    }
    if (std.mem.eql(u8, request.command, "cart.quote")) {
        return success(allocator, request.id, try pos.quote(db, a, try cartPayload(a, p)));
    }
    if (std.mem.eql(u8, request.command, "sale.checkout")) {
        try fields(p, 4);
        const sale = try pos.checkout(db, a, .{
            .checkout_id = try string(p, "checkout_id"),
            .cart = try cartPayload(a, try field(p, "cart")),
            .tendered = try integer(p, "tendered"),
            .expected_total = try integer(p, "expected_total"),
        });
        return checkoutSuccess(allocator, request.id, sale) catch error.CheckoutUnknown;
    }
    if (std.mem.eql(u8, request.command, "sale.list")) {
        try fields(p, 2);
        return success(allocator, request.id, try pos.listSales(db, a, try string(p, "date"), try integer(p, "offset")));
    }
    if (std.mem.eql(u8, request.command, "sale.get")) {
        try fields(p, 1);
        return success(allocator, request.id, .{ .sale = try pos.saleDetail(db, a, try positiveInteger(p, "id")) });
    }
    if (std.mem.eql(u8, request.command, "shift.current")) {
        try fields(p, 0);
        return success(allocator, request.id, .{ .shift = try shift.current(db, a) });
    }
    if (std.mem.eql(u8, request.command, "shift.get")) {
        try fields(p, 1);
        return success(allocator, request.id, .{ .shift = try shift.get(db, a, try positiveInteger(p, "id")) });
    }
    if (std.mem.eql(u8, request.command, "shift.open")) {
        try fields(p, 1);
        return success(allocator, request.id, .{ .shift = try shift.open(db, a, try integer(p, "opening_cash")) });
    }
    if (std.mem.eql(u8, request.command, "shift.cash")) {
        try fields(p, 5);
        return success(allocator, request.id, .{ .shift = try shift.recordCash(db, a, .{
            .entry_key = try string(p, "entry_key"),
            .kind = try string(p, "kind"),
            .amount = try integer(p, "amount"),
            .category = try string(p, "category"),
            .note = try string(p, "note"),
        }) });
    }
    if (std.mem.eql(u8, request.command, "shift.close")) {
        try fields(p, 3);
        return success(allocator, request.id, .{ .shift = try shift.close(db, a, try positiveInteger(p, "id"), try integer(p, "counted_cash"), try string(p, "note")) });
    }
    if (std.mem.eql(u8, request.command, "device.get")) {
        try fields(p, 0);
        const config = try device.loadConfig(db, a);
        const logo = if (try device.loadLogo(db, a)) |value| LogoJson{
            .width = value.width_px,
            .height = value.height_px,
            .bits_base64 = try encodeBase64(a, value.bits),
        } else null;
        return success(allocator, request.id, .{ .config = config, .logo = logo });
    }
    if (std.mem.eql(u8, request.command, "device.save")) {
        const config = try configPayload(p);
        // Reject settings that would make every future receipt unprintable.
        _ = try device.previewDraft(db, a, config);
        const response = try success(allocator, request.id, .{ .saved = true });
        errdefer allocator.free(response);
        try device.saveConfig(db, config);
        return response;
    }
    if (std.mem.eql(u8, request.command, "device.preview")) {
        const preview = try device.previewDraft(db, a, try configPayload(p));
        return success(allocator, request.id, .{ .text = preview.text, .width = preview.width });
    }
    if (std.mem.eql(u8, request.command, "device.logo_save")) {
        try fields(p, 3);
        const width = try positiveInteger(p, "width");
        const height = try positiveInteger(p, "height");
        if (width > device.max_logo_width or height > device.max_logo_height) return error.InvalidLogo;
        const encoded = try string(p, "bits_base64");
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidLogo;
        const bits = try a.alloc(u8, size);
        decoder.decode(bits, encoded) catch return error.InvalidLogo;
        const response = try success(allocator, request.id, .{ .saved = true });
        errdefer allocator.free(response);
        try device.saveLogo(db, a, .{ .width_px = @intCast(width), .height_px = @intCast(height), .bits = bits });
        return response;
    }
    if (std.mem.eql(u8, request.command, "device.logo_clear")) {
        try fields(p, 0);
        const response = try success(allocator, request.id, .{ .saved = true });
        errdefer allocator.free(response);
        try device.saveLogo(db, a, null);
        return response;
    }
    if (std.mem.eql(u8, request.command, "device.printers")) {
        try fields(p, 0);
        return success(allocator, request.id, .{ .printers = try device.listPrinters(a) });
    }
    if (std.mem.eql(u8, request.command, "receipt.preview")) {
        try fields(p, 1);
        const preview = try device.previewSale(db, a, try positiveInteger(p, "id"));
        return success(allocator, request.id, .{ .text = preview.text, .escpos_base64 = try encodeBase64(a, preview.bytes), .width = preview.width });
    }
    if (std.mem.eql(u8, request.command, "receipt.print") or std.mem.eql(u8, request.command, "receipt.reprint")) {
        try fields(p, 1);
        const sale_id = try positiveInteger(p, "id");
        const is_copy = std.mem.eql(u8, request.command, "receipt.reprint");
        // Allocate acknowledgement before irreversible printer IO.
        const response = try success(allocator, request.id, .{ .submitted = true, .is_copy = is_copy });
        errdefer allocator.free(response);
        try device.printSale(db, a, sale_id, is_copy);
        return response;
    }
    if (std.mem.eql(u8, request.command, "device.test_print")) {
        try fields(p, 0);
        const response = try success(allocator, request.id, .{ .submitted = true });
        errdefer allocator.free(response);
        try device.testPrint(db, a);
        return response;
    }
    if (std.mem.eql(u8, request.command, "device.open_drawer")) {
        try fields(p, 0);
        const response = try success(allocator, request.id, .{ .submitted = true });
        errdefer allocator.free(response);
        try device.openDrawer(db, a);
        return response;
    }
    return failure(allocator, request.id, "unknown_command");
}

const LogoJson = struct { width: u16, height: u16, bits_base64: []const u8 };

fn encodeBase64(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try a.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

fn configPayload(p: std.json.Value) !device.Config {
    try fields(p, 16);
    return .{
        .printer_kind = try string(p, "printer_kind"),
        .printer_name = try string(p, "printer_name"),
        .file_path = try string(p, "file_path"),
        .tcp_host = try string(p, "tcp_host"),
        .tcp_port = try integer(p, "tcp_port"),
        .paper_width = try integer(p, "paper_width"),
        .header = try string(p, "header"),
        .footer = try string(p, "footer"),
        .qr_payload = try string(p, "qr_payload"),
        .copies = try integer(p, "copies"),
        .feed_lines = try integer(p, "feed_lines"),
        .show_sku = try boolean(p, "show_sku"),
        .show_barcode = try boolean(p, "show_barcode"),
        .show_qr = try boolean(p, "show_qr"),
        .cash_drawer = try boolean(p, "cash_drawer"),
        .cut_paper = try boolean(p, "cut_paper"),
    };
}

fn boolean(value: std.json.Value, key: []const u8) !bool {
    const result = try field(value, key);
    if (result != .bool) return error.InvalidPayload;
    return result.bool;
}

fn fields(value: std.json.Value, count: usize) !void {
    if (value != .object or value.object.count() != count) return error.InvalidPayload;
}

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidPayload;
    return value.object.get(key) orelse error.InvalidPayload;
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    const result = try field(value, key);
    if (result != .string) return error.InvalidPayload;
    return result.string;
}

fn integer(value: std.json.Value, key: []const u8) !i64 {
    const result = try field(value, key);
    if (result != .integer or result.integer < 0 or result.integer > money.max_amount) return error.InvalidPayload;
    return result.integer;
}

fn positiveInteger(value: std.json.Value, key: []const u8) !i64 {
    const result = try integer(value, key);
    if (result == 0) return error.InvalidPayload;
    return result;
}

fn optionalInteger(value: std.json.Value, key: []const u8) !?i64 {
    const result = try field(value, key);
    if (result == .null) return null;
    return try integer(value, key);
}

fn cartPayload(a: std.mem.Allocator, value: std.json.Value) !pos.CartInput {
    try fields(value, 4);
    const lines = try field(value, "lines");
    if (lines != .array) return error.InvalidPayload;
    if (lines.array.items.len == 0 or lines.array.items.len > 40) return error.InvalidCart;
    const items = try a.alloc(pos.CartLine, lines.array.items.len);
    for (lines.array.items, items) |line, *item| {
        try fields(line, 6);
        item.* = .{
            .product_id = try positiveInteger(line, "product_id"),
            .revision = try positiveInteger(line, "revision"),
            .quantity_milli = try positiveInteger(line, "quantity_milli"),
            .discount_kind = try string(line, "discount_kind"),
            .discount_value = try integer(line, "discount_value"),
            .note = try string(line, "note"),
        };
    }
    return .{
        .lines = items,
        .discount_kind = try string(value, "discount_kind"),
        .discount_value = try integer(value, "discount_value"),
        .cash_rounding_increment = try integer(value, "cash_rounding_increment"),
    };
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPayload => "invalid_payload",
        error.InvalidProduct => "invalid_product",
        error.ProductConflict => "product_conflict",
        error.ProductNotFound => "product_not_found",
        error.ProductChanged => "product_changed",
        error.InvalidCart, error.NegativeAmount, error.AmountOverflow, error.Underflow, error.InvalidQuantity, error.QuantityOverflow, error.InvalidRoundingIncrement, error.NegativeStock, error.StockOverflow => "invalid_cart",
        error.InvalidDiscount, error.DiscountExceedsBase, error.InvalidRate => "invalid_discount",
        error.InvalidQuery => "invalid_query",
        error.BusinessRequired => "business_required",
        error.InsufficientStock => "insufficient_stock",
        error.Underpayment => "underpayment",
        error.TotalChanged => "total_changed",
        error.IdempotencyConflict => "idempotency_conflict",
        error.CheckoutUnknown => "checkout_unknown",
        error.SaleNotFound => "sale_not_found",
        error.ShiftRequired => "shift_required",
        error.ShiftOpen => "shift_open",
        error.ShiftClosed => "shift_closed",
        error.ShiftNotFound => "shift_not_found",
        error.InvalidShift => "invalid_shift",
        error.InvalidCashEntry => "invalid_cash_entry",
        error.CashEntryLimit => "cash_entry_limit",
        error.InsufficientCash => "insufficient_cash",
        error.InvalidConfig => "invalid_device_config",
        error.InvalidLogo => "invalid_logo",
        error.InvalidWidth, error.TooWide, error.InvalidBitmap, error.InvalidCode, error.InvalidReceiptText => "invalid_receipt",
        error.PrinterUnreachable => "printer_unreachable",
        error.PrinterNotFound => "printer_not_found",
        error.PrinterFailed, error.SpoolerOpenFailed, error.SpoolerJobFailed => "printer_failed",
        error.PrintUnknown => "print_unknown",
        error.DrawerUnknown => "drawer_unknown",
        error.DatabaseBusy => "database_busy",
        error.DiskFull => "disk_full",
        else => "database_unavailable",
    };
}

fn businessPayload(payload: std.json.Value) !db_module.Business {
    if (payload.object.count() != 3) return error.InvalidPayload;
    const name = payload.object.get("name") orelse return error.InvalidPayload;
    const mode = payload.object.get("mode") orelse return error.InvalidPayload;
    const address = payload.object.get("address") orelse return error.InvalidPayload;
    if (name != .string or mode != .string or address != .string) return error.InvalidPayload;
    return .{ .name = name.string, .mode = mode.string, .address = address.string };
}

fn success(allocator: std.mem.Allocator, id: []const u8, result: anytype) ![]const u8 {
    const response = try std.json.Stringify.valueAlloc(allocator, .{ .id = id, .ok = true, .result = result }, .{});
    if (response.len <= max_message_bytes) return response;
    allocator.free(response);
    return failure(allocator, id, "message_too_large");
}

fn checkoutSuccess(allocator: std.mem.Allocator, id: []const u8, sale: anytype) ![]const u8 {
    const response = std.json.Stringify.valueAlloc(allocator, .{ .id = id, .ok = true, .result = .{ .sale = sale } }, .{}) catch return failure(allocator, id, "checkout_unknown");
    if (response.len <= max_message_bytes) return response;
    allocator.free(response);
    return failure(allocator, id, "checkout_unknown");
}

fn failure(allocator: std.mem.Allocator, id: ?[]const u8, code: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .ok = false, .@"error" = .{ .code = code } }, .{});
}

test "typed bridge rejects malformed, unknown and oversized requests" {
    const a = std.testing.allocator;
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const cases = .{
        .{ "{", "invalid_request" },
        .{ "{\"id\":[120],\"command\":\"system.ping\",\"payload\":{}}", "invalid_request" },
        .{ "{\"id\":\"x\",\"command\":[115,121,115,116,101,109,46,112,105,110,103],\"payload\":{}}", "invalid_request" },
        .{ "{\"id\":\"x\",\"command\":\"system.ping\",\"payload\":{},\"extra\":true}", "invalid_request" },
        .{ "{\"id\":\"x\",\"id\":\"y\",\"command\":\"system.ping\",\"payload\":{}}", "invalid_request" },
        .{ "{\"id\":\"x\",\"command\":\"system.ping\",\"payload\":null}", "invalid_request" },
        .{ "{\"id\":\"x\",\"command\":\"sql.exec\",\"payload\":{}}", "unknown_command" },
        .{ "{\"id\":\"x\",\"command\":\"system.ping\",\"payload\":{\"a\":1}}", "invalid_payload" },
        .{ "{\"id\":\"x\",\"command\":\"business.save\",\"payload\":{\"name\":4,\"mode\":\"retail\",\"address\":\"\"}}", "invalid_business" },
    };
    inline for (cases) |case| {
        const response = try dispatch(a, db, case[0]);
        defer a.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer parsed.deinit();
        try std.testing.expect(!parsed.value.object.get("ok").?.bool);
        try std.testing.expectEqualStrings(case[1], parsed.value.object.get("error").?.object.get("code").?.string);
    }
    const huge = try a.alloc(u8, max_message_bytes + 1);
    defer a.free(huge);
    @memset(huge, ' ');
    const response = try dispatch(a, db, huge);
    defer a.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "message_too_large") != null);
}

test "ping and saving a business round trip through database" {
    const a = std.testing.allocator;
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const ping = try dispatch(a, db, "{\"id\":\"ping-1\",\"command\":\"system.ping\",\"payload\":{}}");
    defer a.free(ping);
    try std.testing.expectEqualStrings("{\"id\":\"ping-1\",\"ok\":true,\"result\":{\"pong\":true,\"protocol_version\":1}}", ping);
    const saved = try dispatch(a, db, "{\"id\":\"save-1\",\"command\":\"business.save\",\"payload\":{\"name\":\"Warung Sari\",\"mode\":\"food\",\"address\":\"Bandung\"}}");
    defer a.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"saved\":true") != null);
    const status = try dispatch(a, db, "{\"id\":\"status-1\",\"command\":\"app.status\",\"payload\":{}}");
    defer a.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Warung Sari") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "wal_full") != null);
}

test "bridge bounds serialized responses before native delivery" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, max_message_bytes);
    defer a.free(large);
    @memset(large, '"');
    const response = try success(a, "bounded-response", .{ .value = large });
    defer a.free(response);
    try std.testing.expect(response.len <= max_message_bytes);
    try std.testing.expect(std.mem.indexOf(u8, response, "message_too_large") != null);
    const committed_response = try checkoutSuccess(a, "bounded-checkout", .{ .value = large });
    defer a.free(committed_response);
    try std.testing.expect(std.mem.indexOf(u8, committed_response, "checkout_unknown") != null);
}

fn testCommand(a: std.mem.Allocator, db: Database, command: []const u8, payload: anytype) !std.json.Value {
    const input = try std.json.Stringify.valueAlloc(a, .{ .id = "test-request", .command = command, .payload = payload }, .{});
    const response = try dispatch(a, db, input);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
    return parsed.value;
}

fn testResult(response: std.json.Value) !std.json.Value {
    try std.testing.expect(response.object.get("ok").?.bool);
    return response.object.get("result").?;
}

fn testFailure(response: std.json.Value, expected: []const u8) !void {
    try std.testing.expect(!response.object.get("ok").?.bool);
    try std.testing.expectEqualStrings(expected, response.object.get("error").?.object.get("code").?.string);
}

test "POS bridge rejects wrong scalar types, unknown fields and invalid carts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Bridge Test", .mode = "retail", .address = "" });
    try testFailure(try testCommand(a, db, "product.list", .{ .query = .{120}, .offset = 0 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "product.list", .{ .query = "", .offset = "0" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "product.list", .{ .query = "", .offset = 0, .sql = "DELETE FROM product" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "product.archive", .{ .id = true, .revision = 1 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "sale.get", .{ .id = 9_007_199_254_740_992 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "product.list", .{ .query = "", .offset = -1 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "sale.list", .{ .date = "2026-02-29", .offset = 0 }), "invalid_query");
    const invalid_lines = [_]pos.CartLine{.{ .product_id = 1, .revision = 1, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "" }} ** 41;
    try testFailure(try testCommand(a, db, "cart.quote", .{ .lines = &invalid_lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }), "invalid_cart");
    try testFailure(try testCommand(a, db, "sale.checkout", .{ .checkout_id = "x", .cart = null, .tendered = 0, .expected_total = 0 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "cart.quote", .{ .lines = @as([]const pos.CartLine, &.{}), .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }), "invalid_cart");
    const cases = [_][]const u8{
        "{\"id\":\"x\",\"command\":\"product.archive\",\"payload\":{\"id\":1.0,\"revision\":1}}",
        "{\"id\":\"x\",\"command\":\"product.archive\",\"payload\":{\"id\":1,\"revision\":1,\"revision\":2}}",
        "{\"id\":\"x\",\"command\":\"product.save\",\"payload\":{\"id\":null,\"revision\":null,\"name\":[65],\"sku\":\"\",\"barcode\":\"\",\"category\":\"\",\"unit\":\"pcs\",\"price\":1,\"cost\":0,\"stock_milli\":null}}",
    };
    for (cases, 0..) |input, i| {
        const response = try dispatch(a, db, input);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        try testFailure(parsed.value, if (i == 1) "invalid_request" else "invalid_payload");
    }
}

test "checkout allocation failures never duplicate a sale on retry" {
    const a = std.testing.allocator;
    var completed = false;
    for (0..300) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const db = try Database.open(":memory:");
        defer db.close();
        try db.migrate(a, ":memory:");
        try db.saveBusiness(.{ .name = "Allocation Test", .mode = "retail", .address = "" });
        try db.exec(pos.test_open_shift);
        const product = try pos.saveProduct(db, arena.allocator(), .{ .id = null, .revision = null, .name = "Item", .sku = "", .barcode = "", .category = "", .unit = "pcs", .price = 100, .cost = 50, .stock_milli = 2000 });
        const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "" }};
        const payload = pos.CheckoutInput{ .checkout_id = "allocation-retry", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 100, .expected_total = 100 };
        const input = try std.json.Stringify.valueAlloc(a, .{ .id = "allocation-request", .command = "sale.checkout", .payload = payload }, .{});
        defer a.free(input);
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const response: ?[]const u8 = dispatch(failing.allocator(), db, input) catch |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            break :blk null;
        };
        if (response) |encoded| failing.allocator().free(encoded);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        const committed = try db.integer("SELECT count(*) FROM sale;");
        try std.testing.expect(committed == 0 or committed == 1);
        const retry = try dispatch(a, db, input);
        defer a.free(retry);
        try std.testing.expect(std.mem.indexOf(u8, retry, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
        const remaining = try pos.getProduct(db, arena.allocator(), product.id);
        try std.testing.expectEqual(@as(?i64, 1000), remaining.stock_milli);
        if (!failing.has_induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

test "separate database connections cannot sell the same last unit twice" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const work = arena.allocator();
    const directory = try temp.dir.realpathAlloc(work, ".");
    const path = try std.fmt.allocPrintSentinel(work, "{s}/concurrent.db", .{directory}, 0);
    const first = try Database.open(path);
    defer first.close();
    try first.migrate(a, path);
    try first.saveBusiness(.{ .name = "Last Unit", .mode = "retail", .address = "" });
    try first.exec(pos.test_open_shift);
    const product = try pos.saveProduct(first, work, .{ .id = null, .revision = null, .name = "Last unit", .sku = "", .barcode = "", .category = "", .unit = "pcs", .price = 100, .cost = 50, .stock_milli = 1000 });
    const second = try Database.open(path);
    defer second.close();
    try second.migrate(a, path);
    try first.exec("PRAGMA busy_timeout=0;");
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    var input = pos.CheckoutInput{ .checkout_id = "first-connection", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 100, .expected_total = 100 };
    try second.exec("BEGIN IMMEDIATE;");
    try testFailure(try testCommand(work, first, "sale.checkout", input), "database_busy");
    try std.testing.expectEqual(@as(i64, 0), try first.integer("SELECT count(*) FROM sale;"));
    try second.exec("ROLLBACK;");
    _ = try testResult(try testCommand(work, first, "sale.checkout", input));
    input.checkout_id = "second-connection";
    try testFailure(try testCommand(work, second, "sale.checkout", input), "product_changed");
    try std.testing.expectEqual(@as(i64, 1), try second.integer("SELECT count(*) FROM sale;"));
    try std.testing.expectEqual(@as(i64, 0), try second.integer("SELECT stock_milli FROM product;"));
}

test "POS bridge accepts a fully discounted cash sale without inventing payment value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Discount Test", .mode = "service", .address = "" });
    try db.exec(pos.test_open_shift);
    const product = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Service", .sku = "", .barcode = "", .category = "", .unit = "service", .price = 12_345, .cost = 0, .stock_milli = null });
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "percent", .discount_value = 10_000, .note = "" }};
    const input = pos.CheckoutInput{ .checkout_id = "full-discount", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 100 }, .expected_total = 0, .tendered = 0 };
    const result = try testResult(try testCommand(a, db, "sale.checkout", input));
    const sale = result.object.get("sale").?;
    try std.testing.expectEqual(@as(i64, 0), sale.object.get("totals").?.object.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 0), sale.object.get("change").?.integer);
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT amount FROM payment;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM stock_movement;"));
}

test "POS bridge creates quotes and commits a cash sale only once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const input = pos.ProductInput{ .id = null, .revision = null, .name = "Beras ' Pilihan", .sku = "RICE", .barcode = "012345", .category = "Sembako", .unit = "kg", .price = 15_001, .cost = 10_000, .stock_milli = 2_000 };
    try testFailure(try testCommand(a, db, "product.save", input), "business_required");
    try db.saveBusiness(.{ .name = "Toko Bridge", .mode = "retail", .address = "Jalan Uji" });
    try db.exec(pos.test_open_shift);
    const created = try testResult(try testCommand(a, db, "product.save", input));
    const product = created.object.get("product").?;
    const id = product.object.get("id").?.integer;
    const revision = product.object.get("revision").?.integer;
    const listed = try testResult(try testCommand(a, db, "product.list", .{ .query = "012345", .offset = 0 }));
    try std.testing.expectEqual(@as(usize, 1), listed.object.get("products").?.array.items.len);
    var lines = [_]pos.CartLine{.{ .product_id = id, .revision = revision, .quantity_milli = 500, .discount_kind = "nominal", .discount_value = 501, .note = "Setengah kilo" }};
    const cart = pos.CartInput{ .lines = &lines, .discount_kind = "percent", .discount_value = 1_000, .cash_rounding_increment = 100 };
    const quoted = try testResult(try testCommand(a, db, "cart.quote", cart));
    try std.testing.expectEqual(@as(i64, 6_300), quoted.object.get("totals").?.object.get("total").?.integer);
    var checkout = pos.CheckoutInput{ .checkout_id = "cash-retry-1", .cart = cart, .tendered = 6_000, .expected_total = 6_300 };
    try testFailure(try testCommand(a, db, "sale.checkout", checkout), "underpayment");
    checkout.tendered = 10_000;
    const first = try testResult(try testCommand(a, db, "sale.checkout", checkout));
    const sale = first.object.get("sale").?;
    const sale_id = sale.object.get("id").?.integer;
    try std.testing.expectEqual(@as(i64, 3_700), sale.object.get("change").?.integer);
    const second = try testResult(try testCommand(a, db, "sale.checkout", checkout));
    try std.testing.expectEqual(sale_id, second.object.get("sale").?.object.get("id").?.integer);
    checkout.tendered = 20_000;
    try testFailure(try testCommand(a, db, "sale.checkout", checkout), "idempotency_conflict");
    lines[0].quantity_milli = 3_000;
    try testFailure(try testCommand(a, db, "cart.quote", cart), "product_changed");
    const history = try testResult(try testCommand(a, db, "sale.list", .{ .date = "", .offset = 0 }));
    try std.testing.expectEqual(@as(usize, 1), history.object.get("sales").?.array.items.len);
    const updated = try pos.getProduct(db, a, id);
    try std.testing.expectEqual(@as(?i64, 1_500), updated.stock_milli);
    _ = try testResult(try testCommand(a, db, "product.archive", .{ .id = id, .revision = updated.revision }));
    const detail = try testResult(try testCommand(a, db, "sale.get", .{ .id = sale_id }));
    const saved_item = detail.object.get("sale").?.object.get("items").?.array.items[0];
    try std.testing.expectEqualStrings(input.name, saved_item.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 15_001), saved_item.object.get("unit_price").?.integer);
}

test "device bridge round trips config and rejects wrong types and unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const initial = try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})));
    try std.testing.expectEqual(@as(i64, 80), initial.object.get("config").?.object.get("paper_width").?.integer);
    var config = device.defaultConfig();
    config.paper_width = 58;
    config.footer = "Terima kasih";
    _ = try testResult(try testCommand(a, db, "device.save", config));
    const loaded = try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})));
    try std.testing.expectEqualStrings(config.footer, loaded.object.get("config").?.object.get("footer").?.string);
    try std.testing.expectEqual(@as(i64, 58), loaded.object.get("config").?.object.get("paper_width").?.integer);

    const encoded = try std.json.Stringify.valueAlloc(a, config, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    var bad = parsed.value;
    try bad.object.put("show_sku", .{ .integer = 1 });
    try testFailure(try testCommand(a, db, "device.save", bad), "invalid_payload");
    try bad.object.put("show_sku", .{ .bool = false });
    try bad.object.put("paper_width", .{ .string = "58" });
    try testFailure(try testCommand(a, db, "device.save", bad), "invalid_payload");
    try bad.object.put("paper_width", .{ .integer = 70 });
    try testFailure(try testCommand(a, db, "device.save", bad), "invalid_device_config");
    try bad.object.put("paper_width", .{ .integer = 58 });
    try bad.object.put("extra", .{ .bool = true });
    try testFailure(try testCommand(a, db, "device.save", bad), "invalid_payload");
    _ = bad.object.swapRemove("extra");
    _ = bad.object.swapRemove("header");
    try testFailure(try testCommand(a, db, "device.save", bad), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.get", .{ .extra = true }), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.printers", .{ .extra = true }), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.test_print", .{ .extra = true }), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.open_drawer", .{ .extra = true }), "invalid_payload");
    try testFailure(try testCommand(a, db, "receipt.print", .{ .id = 0 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "receipt.reprint", .{ .id = 1, .sql = "DELETE FROM sale" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "receipt.preview", .{ .id = "1" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "receipt.preview", .{ .id = 999 }), "sale_not_found");
}

test "device bridge previews drafts and stores logos without trusting the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Toko Logo", .mode = "retail", .address = "" });

    var draft = device.defaultConfig();
    draft.header = "Diskon akhir pekan";
    const preview = try testResult(try testCommand(a, db, "device.preview", draft));
    try std.testing.expect(std.mem.indexOf(u8, preview.object.get("text").?.string, "Diskon akhir pekan") != null);
    try std.testing.expectEqual(@as(i64, 80), preview.object.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM device_config;"));
    draft.qr_payload = "x" ** 512;
    draft.show_qr = true;
    _ = try testResult(try testCommand(a, db, "device.preview", draft));
    draft.copies = 0;
    try testFailure(try testCommand(a, db, "device.preview", draft), "invalid_device_config");

    try std.testing.expect((try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})))).object.get("logo").? == .null);
    _ = try testResult(try testCommand(a, db, "device.logo_save", .{ .width = 12, .height = 2, .bits_base64 = "8A+qVQ==" }));
    const loaded = try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})));
    const logo = loaded.object.get("logo").?.object;
    try std.testing.expectEqual(@as(i64, 12), logo.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 2), logo.get("height").?.integer);
    try std.testing.expectEqualStrings("8A+qVQ==", logo.get("bits_base64").?.string);
    try std.testing.expect(std.mem.indexOf(u8, (try testResult(try testCommand(a, db, "device.preview", device.defaultConfig()))).object.get("text").?.string, "[logo]") != null);

    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 12, .height = 2, .bits_base64 = "8A+q" }), "invalid_logo");
    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 12, .height = 2, .bits_base64 = "not base64!" }), "invalid_logo");
    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 385, .height = 2, .bits_base64 = "" }), "invalid_logo");
    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 8, .height = 193, .bits_base64 = "" }), "invalid_logo");
    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 0, .height = 2, .bits_base64 = "" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.logo_save", .{ .width = 12, .height = 2 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "device.logo_clear", .{ .extra = true }), "invalid_payload");
    try std.testing.expectEqualStrings("8A+qVQ==", (try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})))).object.get("logo").?.object.get("bits_base64").?.string);

    _ = try testResult(try testCommand(a, db, "device.logo_clear", @as(struct {}, .{})));
    try std.testing.expect((try testResult(try testCommand(a, db, "device.get", @as(struct {}, .{})))).object.get("logo").? == .null);
}

fn deviceBridgeSale(db: Database, a: std.mem.Allocator) !i64 {
    try db.saveBusiness(.{ .name = "Toko Perangkat", .mode = "retail", .address = "Jalan Uji" });
    try db.exec(pos.test_open_shift);
    const product = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Kopi", .sku = "KOPI", .barcode = "", .category = "", .unit = "pcs", .price = 10_000, .cost = 5_000, .stock_milli = 5_000 });
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    const sale = try pos.checkout(db, a, .{ .checkout_id = "bridge-device-seed", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 10_000, .expected_total = 10_000 });
    return sale.id;
}

test "receipt bridge previews exact bytes and submits print reprint and drawer through a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    const path = try std.fmt.allocPrint(a, "{s}/bridge-receipt.bin", .{directory});
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const sale_id = try deviceBridgeSale(db, a);
    var config = device.defaultConfig();
    config.printer_kind = "file";
    config.file_path = path;
    _ = try testResult(try testCommand(a, db, "device.save", config));

    const preview = try testResult(try testCommand(a, db, "receipt.preview", .{ .id = sale_id }));
    try std.testing.expect(std.mem.indexOf(u8, preview.object.get("text").?.string, "Toko Perangkat") != null);
    const base64 = preview.object.get("escpos_base64").?.string;
    const decoder = std.base64.standard.Decoder;
    const decoded = try a.alloc(u8, try decoder.calcSizeForSlice(base64));
    try decoder.decode(decoded, base64);
    const direct = try device.previewSale(db, a, sale_id);
    try std.testing.expectEqualSlices(u8, direct.bytes, decoded);
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM audit_log;"));

    const printed = try testResult(try testCommand(a, db, "receipt.print", .{ .id = sale_id }));
    try std.testing.expect(printed.object.get("submitted").?.bool);
    try std.testing.expect(!printed.object.get("is_copy").?.bool);
    const written = try std.fs.cwd().readFileAlloc(a, path, max_message_bytes);
    try std.testing.expectEqualSlices(u8, decoded, written);
    const reprinted = try testResult(try testCommand(a, db, "receipt.reprint", .{ .id = sale_id }));
    try std.testing.expect(reprinted.object.get("is_copy").?.bool);
    const copy = try std.fs.cwd().readFileAlloc(a, path, max_message_bytes);
    try std.testing.expect(std.mem.indexOf(u8, copy, "*** SALINAN ***") != null);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE kind='reprint';"));
    _ = try testResult(try testCommand(a, db, "device.test_print", @as(struct {}, .{})));
    const diagnostic = try std.fs.cwd().readFileAlloc(a, path, max_message_bytes);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "UJI-CETAK") != null);
    _ = try testResult(try testCommand(a, db, "device.open_drawer", @as(struct {}, .{})));
    const drawer = try std.fs.cwd().readFileAlloc(a, path, 64);
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, '@', 0x1B, 'p', 0, 25, 250 }, drawer);
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE kind='drawer_open';"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
    try std.testing.expectEqual(@as(i64, 4000), try db.integer("SELECT stock_milli FROM product;"));
}

test "printer failures stay separate from checkout and database failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const sale_id = try deviceBridgeSale(db, a);
    try testFailure(try testCommand(a, db, "receipt.print", .{ .id = sale_id }), "invalid_device_config");
    try testFailure(try testCommand(a, db, "device.test_print", @as(struct {}, .{})), "invalid_device_config");
    var config = device.defaultConfig();
    config.printer_kind = "file";
    config.file_path = try std.fmt.allocPrint(a, "{s}/missing/print.bin", .{directory});
    _ = try testResult(try testCommand(a, db, "device.save", config));
    try testFailure(try testCommand(a, db, "receipt.print", .{ .id = sale_id }), "printer_failed");
    try testFailure(try testCommand(a, db, "receipt.reprint", .{ .id = sale_id }), "printer_failed");
    try testFailure(try testCommand(a, db, "device.open_drawer", @as(struct {}, .{})), "printer_failed");
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
    try std.testing.expectEqual(@as(i64, 4000), try db.integer("SELECT stock_milli FROM product;"));
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM audit_log WHERE detail='failed';"));
}

test "device bridge distinguishes ambiguous output from definite failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realpathAlloc(a, ".");
    const path = try std.fmt.allocPrint(a, "{s}/ambiguous.bin", .{directory});
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const id = try deviceBridgeSale(db, a);
    var config = device.defaultConfig();
    config.printer_kind = "file";
    config.file_path = path;
    try device.saveConfig(db, config);
    try db.exec("CREATE TRIGGER reject_completion BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT,'audit unavailable'); END;");
    try testFailure(try testCommand(a, db, "receipt.reprint", .{ .id = id }), "print_unknown");
    try testFailure(try testCommand(a, db, "device.open_drawer", @as(struct {}, .{})), "drawer_unknown");
    try std.testing.expectEqual(@as(i64, 2), try db.integer("SELECT count(*) FROM audit_log WHERE detail='attempt';"));
    try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM sale;"));
}

test "receipt previews obey the native response cap even for large documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    try db.saveBusiness(.{ .name = "Large Receipt", .mode = "retail", .address = "" });
    try db.exec(pos.test_open_shift);
    var lines: [40]pos.CartLine = undefined;
    for (&lines, 0..) |*line, i| {
        const product = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Long product name repeated to deliberately exercise the receipt payload response size limit without truncating sale data", .sku = try std.fmt.allocPrint(a, "SKU-{d}", .{i}), .barcode = "", .category = "", .unit = "pcs", .price = 100, .cost = 50, .stock_milli = null });
        line.* = .{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "Long customer note repeated to deliberately exercise receipt wrapping and the response limit; printing must never be triggered by requesting the preview alone." };
    }
    const sale = try pos.checkout(db, a, .{ .checkout_id = "large-preview", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 4000, .expected_total = 4000 });
    var config = device.defaultConfig();
    config.copies = 5;
    try device.saveConfig(db, config);
    try testFailure(try testCommand(a, db, "receipt.preview", .{ .id = sale.id }), "message_too_large");
    try std.testing.expectEqual(@as(i64, 40), try db.integer("SELECT count(*) FROM sale_item;"));
    try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM audit_log;"));
}

test "printer acknowledgements allocate before IO and free every allocation on failure" {
    const allocator = std.testing.allocator;
    var completed = false;
    for (0..500) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const directory = try temp.dir.realpathAlloc(a, ".");
        const path = try std.fmt.allocPrint(a, "{s}/allocation.bin", .{directory});
        const db = try Database.open(":memory:");
        defer db.close();
        try db.migrate(a, ":memory:");
        const id = try deviceBridgeSale(db, a);
        var config = device.defaultConfig();
        config.printer_kind = "file";
        config.file_path = path;
        try device.saveConfig(db, config);
        const input = try std.json.Stringify.valueAlloc(a, .{ .id = "allocation-print", .command = "receipt.reprint", .payload = .{ .id = id } }, .{});
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const response = dispatch(failing.allocator(), db, input) catch |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            break :blk null;
        };
        if (response) |encoded| failing.allocator().free(encoded);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (failing.has_induced_failure) {
            try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
            try std.testing.expectEqual(@as(i64, 0), try db.integer("SELECT count(*) FROM audit_log;"));
        } else {
            try std.fs.cwd().access(path, .{});
            try std.testing.expectEqual(@as(i64, 1), try db.integer("SELECT count(*) FROM audit_log WHERE detail='submitted';"));
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

test "shift bridge opens, records cash, closes and maps shift errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Database.open(":memory:");
    defer db.close();
    try db.migrate(a, ":memory:");
    const empty = @as(struct {}, .{});
    try testFailure(try testCommand(a, db, "shift.open", .{ .opening_cash = 0 }), "business_required");
    try db.saveBusiness(.{ .name = "Toko Shift", .mode = "retail", .address = "" });
    try std.testing.expect((try testResult(try testCommand(a, db, "shift.current", empty))).object.get("shift").? == .null);
    const product = try pos.saveProduct(db, a, .{ .id = null, .revision = null, .name = "Kopi", .sku = "", .barcode = "", .category = "", .unit = "pcs", .price = 5_000, .cost = 2_000, .stock_milli = null });
    const lines = [_]pos.CartLine{.{ .product_id = product.id, .revision = product.revision, .quantity_milli = 1000, .discount_kind = "none", .discount_value = 0, .note = "" }};
    const checkout = pos.CheckoutInput{ .checkout_id = "shift-sale", .cart = .{ .lines = &lines, .discount_kind = "none", .discount_value = 0, .cash_rounding_increment = 1 }, .tendered = 10_000, .expected_total = 5_000 };
    try testFailure(try testCommand(a, db, "sale.checkout", checkout), "shift_required");
    const cash = .{ .entry_key = "ice-1", .kind = "out", .amount = 2_000, .category = "Beli es", .note = "" };
    try testFailure(try testCommand(a, db, "shift.cash", cash), "shift_required");
    try testFailure(try testCommand(a, db, "shift.open", .{ .opening_cash = -1 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "shift.open", .{ .opening_cash = "50000" }), "invalid_payload");
    const opened = (try testResult(try testCommand(a, db, "shift.open", .{ .opening_cash = 50_000 }))).object.get("shift").?;
    const id = opened.object.get("id").?.integer;
    try testFailure(try testCommand(a, db, "shift.open", .{ .opening_cash = 0 }), "shift_open");
    _ = try testResult(try testCommand(a, db, "sale.checkout", checkout));
    const after_cash = (try testResult(try testCommand(a, db, "shift.cash", cash))).object.get("shift").?;
    try std.testing.expectEqual(@as(i64, 53_000), after_cash.object.get("expected_cash").?.integer);
    try std.testing.expectEqualStrings("Beli es", after_cash.object.get("entries").?.array.items[0].object.get("category").?.string);
    try testFailure(try testCommand(a, db, "shift.cash", .{ .entry_key = "ice-1", .kind = "out", .amount = 2_001, .category = "Beli es", .note = "" }), "idempotency_conflict");
    try testFailure(try testCommand(a, db, "shift.cash", .{ .entry_key = "big", .kind = "out", .amount = 53_001, .category = "Setor", .note = "" }), "insufficient_cash");
    try testFailure(try testCommand(a, db, "shift.cash", .{ .entry_key = "bad", .kind = "refund", .amount = 1, .category = "Setor", .note = "" }), "invalid_cash_entry");
    try testFailure(try testCommand(a, db, "shift.cash", .{ .entry_key = "bad", .kind = "in", .amount = 1, .category = "Setor" }), "invalid_payload");
    try testFailure(try testCommand(a, db, "shift.close", .{ .id = id + 1, .counted_cash = 0, .note = "" }), "shift_not_found");
    const closed = (try testResult(try testCommand(a, db, "shift.close", .{ .id = id, .counted_cash = 52_500, .note = "Kurang" }))).object.get("shift").?;
    try std.testing.expectEqual(@as(i64, -500), closed.object.get("difference").?.integer);
    try std.testing.expect(closed.object.get("closed_at").? == .string);
    _ = try testResult(try testCommand(a, db, "shift.close", .{ .id = id, .counted_cash = 52_500, .note = "Kurang" }));
    try testFailure(try testCommand(a, db, "shift.close", .{ .id = id, .counted_cash = 53_000, .note = "Kurang" }), "shift_closed");
    const fetched = (try testResult(try testCommand(a, db, "shift.get", .{ .id = id }))).object.get("shift").?;
    try std.testing.expectEqual(@as(i64, 1), fetched.object.get("sale_count").?.integer);
    try testFailure(try testCommand(a, db, "shift.get", .{ .id = 0 }), "invalid_payload");
    try testFailure(try testCommand(a, db, "shift.current", .{ .extra = true }), "invalid_payload");
}
