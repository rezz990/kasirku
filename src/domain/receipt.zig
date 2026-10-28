const std = @import("std");
const money = @import("money.zig");

pub const Error = money.Error || error{
    InvalidWidth,
    TooWide,
    InvalidBitmap,
    InvalidCode,
    InvalidReceiptText,
};

pub const Width = enum(u16) {
    mm58 = 32,
    mm80 = 48,

    pub fn columns(self: Width) usize {
        return @intFromEnum(self);
    }
};

pub const Align = enum { left, center, right };

pub const Logo = struct {
    width_px: u16,
    height_px: u16,
    // Row-major packed bits, one bit per pixel, MSB first; a set bit prints black.
    // Each row occupies ceil(width_px / 8) bytes.
    bits: []const u8,
};

pub const Template = struct {
    logo: ?Logo = null,
    business_name: []const u8 = "",
    business_address: []const u8 = "",
    header: []const u8 = "",
    footer: []const u8 = "",
    width: Width = .mm80,
    show_sku: bool = false,
    show_barcode: bool = false,
    show_qr: bool = false,
    qr_payload: []const u8 = "",
    copies: u8 = 1,
    cash_drawer: bool = true,
    cut_paper: bool = true,
    feed_lines: u8 = 3,
};

pub const Style = struct {
    bold: bool = false,
    double_width: bool = false,
    double_height: bool = false,
};

pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
};

// Text and label/amount slices produced by build are arena-owned; renderers only
// read them, so nothing needs freeing until the caller destroys the arena.
pub const Line = union(enum) {
    text: struct {
        alignment: Align = .left,
        segments: []const Segment,
    },
    two_column: struct {
        label: []const u8,
        amount: []const u8,
        label_style: Style = .{},
        amount_style: Style = .{},
    },
    rule: struct {
        char: u8 = '-',
        bold: bool = false,
    },
    gap,
    raster: Logo,
    barcode: struct {
        data: []const u8,
        height_dots: u8 = 80,
    },
    qr: struct {
        payload: []const u8,
        module_size: u8 = 6,
    },
};

pub const Receipt = struct {
    lines: []const Line,
    cash_drawer: bool,
    cut_paper: bool,
    feed_lines: u8,
    copies: u8,
};

pub fn formatRupiah(allocator: std.mem.Allocator, amount: i64) (Error || std.mem.Allocator.Error)![]const u8 {
    try money.validate(amount);
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{amount}) catch unreachable;
    const out = try allocator.alloc(u8, 3 + digits.len + @divTrunc(digits.len, 3) + 1);
    @memcpy(out[0..3], "Rp ");
    var w: usize = 3;
    const leading = digits.len % 3;
    var i: usize = 0;
    if (leading != 0) {
        @memcpy(out[w..][0..leading], digits[0..leading]);
        w += leading;
        i = leading;
    }
    while (i < digits.len) : (i += 3) {
        if (w > 3) {
            out[w] = '.';
            w += 1;
        }
        @memcpy(out[w..][0..3], digits[i .. i + 3]);
        w += 3;
    }
    return out[0..w];
}

pub fn formatQuantity(allocator: std.mem.Allocator, quantity_milli: i64) (Error || std.mem.Allocator.Error)![]const u8 {
    try money.validateQuantity(quantity_milli);
    const whole = @divTrunc(quantity_milli, money.milliunits_per_unit);
    const frac = @mod(quantity_milli, money.milliunits_per_unit);
    if (frac == 0) return std.fmt.allocPrint(allocator, "{d}", .{whole});
    const frac_digits: [3]u8 = .{
        @intCast(@divTrunc(frac, 100) + '0'),
        @intCast(@divTrunc(@mod(frac, 100), 10) + '0'),
        @intCast(@mod(frac, 10) + '0'),
    };
    var end: usize = 3;
    while (end > 1 and frac_digits[end - 1] == '0') end -= 1;
    return std.fmt.allocPrint(allocator, "{d},{s}", .{ whole, frac_digits[0..end] });
}

fn seg(text: []const u8) Segment {
    return .{ .text = text };
}

fn styled(text: []const u8, style: Style) Segment {
    return .{ .text = text, .style = style };
}

fn oneSeg(allocator: std.mem.Allocator, s: Segment) ![]const Segment {
    const slice = try allocator.alloc(Segment, 1);
    slice[0] = s;
    return slice;
}

fn centerText(allocator: std.mem.Allocator, s: Segment) !Line {
    return .{ .text = .{ .alignment = .center, .segments = try oneSeg(allocator, s) } };
}

fn leftText(allocator: std.mem.Allocator, s: Segment) !Line {
    return .{ .text = .{ .alignment = .left, .segments = try oneSeg(allocator, s) } };
}

// Build lays out a sale into display lines. `a` must be an arena: every string it
// formats lives until the arena is destroyed, which keeps the model borrow-only
// and the function free of leaks by construction.
pub fn build(a: std.mem.Allocator, sale: anytype, template: Template, is_copy: bool) !Receipt {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(a);

    if (template.logo) |logo| {
        try validateLogo(template.width, logo);
        try lines.append(a, .{ .raster = logo });
    }
    if (template.business_name.len > 0) {
        try lines.append(a, try centerText(a, styled(template.business_name, .{ .bold = true, .double_width = true, .double_height = true })));
    }
    if (template.business_address.len > 0) {
        try lines.append(a, try centerText(a, seg(template.business_address)));
    }
    try lines.append(a, .{ .rule = .{} });
    try lines.append(a, .{ .two_column = .{ .label = "No", .amount = sale.number } });
    try lines.append(a, try leftText(a, seg(try std.fmt.allocPrint(a, "Tgl  {s}", .{sale.created_at}))));
    if (is_copy) {
        try lines.append(a, try centerText(a, styled("*** SALINAN ***", .{ .bold = true })));
    }
    if (template.header.len > 0) {
        try lines.append(a, try centerText(a, seg(template.header)));
    }
    try lines.append(a, .{ .rule = .{} });

    for (sale.items) |item| {
        const qty = try formatQuantity(a, item.quantity_milli);
        const label = try std.fmt.allocPrint(a, "{s} {s}{s}{s}", .{
            qty,
            if (item.unit.len > 0) " " else "",
            item.unit,
            "",
        });
        const name_line = try std.fmt.allocPrint(a, "{s} {s}", .{ label, item.name });
        const net = try formatRupiah(a, item.net);
        try lines.append(a, .{ .two_column = .{ .label = name_line, .amount = net } });

        const price = try formatRupiah(a, item.unit_price);
        try lines.append(a, try leftText(a, seg(try std.fmt.allocPrint(a, "  {s} x {s}", .{ qty, price }))));

        if (item.discount > 0) {
            const disc = try formatRupiah(a, item.discount);
            const kind = if (std.mem.eql(u8, item.discount_kind, "percent")) "Diskon %" else "Diskon";
            try lines.append(a, try leftText(a, seg(try std.fmt.allocPrint(a, "  {s} -{s}", .{ kind, disc }))));
        }
        if (item.note.len > 0) {
            try lines.append(a, try leftText(a, seg(try std.fmt.allocPrint(a, "  Catatan: {s}", .{item.note}))));
        }
        if (template.show_sku and item.sku.len > 0) {
            try lines.append(a, try leftText(a, seg(try std.fmt.allocPrint(a, "  SKU: {s}", .{item.sku}))));
        }
        if (template.show_barcode and item.barcode.len > 0) {
            try lines.append(a, .{ .barcode = .{ .data = item.barcode, .height_dots = 60 } });
        }
    }

    try lines.append(a, .{ .rule = .{} });
    try appendTotals(a, &lines, sale.totals);

    try lines.append(a, .{ .two_column = .{ .label = "Tunai", .amount = try formatRupiah(a, sale.tendered) } });
    try lines.append(a, .{ .two_column = .{ .label = "Kembali", .amount = try formatRupiah(a, sale.change) } });

    if (template.show_qr and template.qr_payload.len > 0) {
        try lines.append(a, .{ .qr = .{ .payload = template.qr_payload, .module_size = if (template.width == .mm58) 3 else 6 } });
    }
    if (template.footer.len > 0) {
        try lines.append(a, .{ .rule = .{} });
        try lines.append(a, try centerText(a, seg(template.footer)));
    }

    return .{
        .lines = try lines.toOwnedSlice(a),
        .cash_drawer = template.cash_drawer,
        .cut_paper = template.cut_paper,
        .feed_lines = template.feed_lines,
        .copies = if (template.copies == 0) 1 else template.copies,
    };
}

fn appendTotals(a: std.mem.Allocator, lines: *std.ArrayList(Line), totals: anytype) !void {
    try lines.append(a, .{ .two_column = .{ .label = "Subtotal", .amount = try formatRupiah(a, totals.gross) } });
    if (totals.line_discount > 0) {
        try lines.append(a, .{ .two_column = .{
            .label = "Diskon item",
            .amount = try std.fmt.allocPrint(a, "-{s}", .{try formatRupiah(a, totals.line_discount)}),
        } });
    }
    if (totals.transaction_discount > 0) {
        try lines.append(a, .{ .two_column = .{
            .label = "Diskon",
            .amount = try std.fmt.allocPrint(a, "-{s}", .{try formatRupiah(a, totals.transaction_discount)}),
        } });
    }
    if (totals.service_charge > 0) {
        try lines.append(a, .{ .two_column = .{ .label = "Layanan", .amount = try formatRupiah(a, totals.service_charge) } });
    }
    if (totals.tax > 0) {
        try lines.append(a, .{ .two_column = .{ .label = "Pajak", .amount = try formatRupiah(a, totals.tax) } });
    }
    if (totals.rounding_adjustment != 0) {
        const amount = try formatRupiah(a, @as(i64, @intCast(@abs(totals.rounding_adjustment))));
        try lines.append(a, .{ .two_column = .{
            .label = "Pembulatan",
            .amount = try std.fmt.allocPrint(a, "{s}{s}", .{ if (totals.rounding_adjustment < 0) "-" else "", amount }),
        } });
    }
    try lines.append(a, .{ .rule = .{ .bold = true } });
    const big = Style{ .bold = true, .double_width = true, .double_height = true };
    try lines.append(a, .{ .two_column = .{
        .label = "TOTAL",
        .amount = try formatRupiah(a, totals.total),
        .label_style = big,
        .amount_style = big,
    } });
    try lines.append(a, .{ .rule = .{ .bold = true } });
}

fn paperDots(width: Width) usize {
    return switch (width) {
        .mm58 => 384,
        .mm80 => 576,
    };
}

fn rasterRowBytes(logo: Logo) usize {
    return (@as(usize, logo.width_px) + 7) / 8;
}

fn validateLogo(width: Width, logo: Logo) Error!void {
    if (logo.width_px == 0 or logo.height_px == 0) return error.InvalidBitmap;
    if (logo.width_px > paperDots(width)) return error.TooWide;
    const expected = rasterRowBytes(logo) * @as(usize, logo.height_px);
    if (logo.bits.len != expected) return error.InvalidBitmap;
}

const esc = 0x1B;
const gs = 0x1D;

pub fn renderEscPos(scratch: std.mem.Allocator, receipt: Receipt, template: Template) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(scratch);
    var copy: usize = 0;
    while (copy < receipt.copies) : (copy += 1) {
        try emitDocument(scratch, &out, receipt, template, copy == 0);
    }
    return out.toOwnedSlice(scratch);
}

fn emitDocument(a: std.mem.Allocator, out: *std.ArrayList(u8), receipt: Receipt, template: Template, first_copy: bool) !void {
    try out.appendSlice(a, &[_]u8{ esc, '@' });
    try out.appendSlice(a, &[_]u8{ esc, 'a', 0 });
    const w = template.width.columns();
    for (receipt.lines) |line| {
        switch (line) {
            .raster => |logo| try emitRaster(a, out, logo, template.width),
            .barcode => |code| try emitBarcode(a, out, code.data, code.height_dots, template.width),
            .qr => |code| try emitQr(a, out, code.payload, code.module_size),
            .gap => try out.appendSlice(a, "\n"),
            .rule => |rule| {
                try validateRule(rule.char);
                try setStyle(a, out, .{ .bold = rule.bold });
                try out.appendNTimes(a, rule.char, w);
                try out.append(a, '\n');
                try setStyle(a, out, .{});
            },
            .text => |text| {
                const layout = try layoutText(a, text.segments, w);
                try emitAligned(a, out, text.alignment, layout.wrapped, layout.style);
            },
            .two_column => |tc| try emitTwoColumn(a, out, tc.label, tc.amount, w, tc.label_style, tc.amount_style),
        }
    }
    if (first_copy and receipt.cash_drawer) try out.appendSlice(a, &[_]u8{ esc, 'p', 0, 25, 250 });
    try out.appendNTimes(a, '\n', receipt.feed_lines);
    if (receipt.cut_paper) try out.appendSlice(a, &[_]u8{ gs, 'V', 'B', 0 });
}

fn dominantStyle(segments: []const Segment) Style {
    var style = Style{};
    for (segments) |s| {
        style.bold = style.bold or s.style.bold;
        style.double_width = style.double_width or s.style.double_width;
        style.double_height = style.double_height or s.style.double_height;
    }
    return style;
}

fn setStyle(a: std.mem.Allocator, out: *std.ArrayList(u8), style: Style) !void {
    try out.appendSlice(a, &[_]u8{ esc, 'E', @intFromBool(style.bold) });
    var size: u8 = 0;
    if (style.double_height) size |= 0x01;
    if (style.double_width) size |= 0x10;
    try out.appendSlice(a, &[_]u8{ gs, '!', size });
}

fn flatten(a: std.mem.Allocator, segments: []const Segment) ![]u8 {
    var total: usize = 0;
    for (segments) |s| total += s.text.len;
    const buf = try a.alloc(u8, total);
    var offset: usize = 0;
    for (segments) |s| {
        @memcpy(buf[offset..][0..s.text.len], s.text);
        offset += s.text.len;
    }
    return buf;
}

fn emitAligned(a: std.mem.Allocator, out: *std.ArrayList(u8), alignment: Align, text: []const u8, style: Style) !void {
    const align_byte: u8 = switch (alignment) {
        .left => 0,
        .center => 1,
        .right => 2,
    };
    try out.appendSlice(a, &[_]u8{ esc, 'a', align_byte });
    try setStyle(a, out, style);
    try out.appendSlice(a, text);
    try out.append(a, '\n');
    try out.appendSlice(a, &[_]u8{ esc, 'a', 0 });
    try setStyle(a, out, .{});
}

fn styleMultiplier(style: Style) usize {
    return if (style.double_width) 2 else 1;
}

fn validateRule(char: u8) Error!void {
    if (char < 0x20 or char > 0x7E) return error.InvalidReceiptText;
}

fn asciiText(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidReceiptText;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeUtf8(text, i);
        i += d.len;
        switch (d.cp) {
            '\r' => {
                if (i < text.len and text[i] == '\n') i += 1;
                try out.append(a, '\n');
            },
            '\n' => try out.append(a, '\n'),
            '\t' => try out.append(a, ' '),
            0...8, 11, 12, 14...31, 127 => return error.InvalidReceiptText,
            else => try out.append(a, if (d.cp < 128) @intCast(d.cp) else '?'),
        }
    }
    return out.toOwnedSlice(a);
}

const TextLayout = struct { wrapped: []const u8, style: Style };

fn layoutText(a: std.mem.Allocator, segments: []const Segment, w: usize) !TextLayout {
    const style = dominantStyle(segments);
    const plain = try asciiText(a, try flatten(a, segments));
    return .{ .wrapped = try wrapDisplay(a, plain, w / styleMultiplier(style)), .style = style };
}

const ColumnRow = struct {
    label: []const u8 = "",
    amount: ?[]const u8 = null,
    amount_style: Style = .{},
    padding: usize = 0,
};

fn layoutTwoColumn(a: std.mem.Allocator, label: []const u8, amount: []const u8, w: usize, label_style: Style, amount_style: Style) ![]const ColumnRow {
    const plain_label = try asciiText(a, label);
    const plain_amount = try asciiText(a, amount);
    const label_scale = styleMultiplier(label_style);
    var right_style = amount_style;
    const single_line = std.mem.indexOfScalar(u8, plain_amount, '\n') == null;
    const reduce_width = single_line and right_style.double_width and plain_amount.len * 2 > w;
    // Keep large monetary amounts intact rather than splitting digit groups.
    if (reduce_width) right_style.double_width = false;
    const amount_scale = styleMultiplier(right_style);
    if (w < label_scale or w < amount_scale) return error.InvalidWidth;
    const amount_cols = plain_amount.len * amount_scale;
    const together = !reduce_width and single_line and
        amount_cols <= w and w - amount_cols >= label_scale + 1;
    var rows: std.ArrayList(ColumnRow) = .empty;
    errdefer rows.deinit(a);
    const label_budget = if (together) (w - amount_cols - 1) / label_scale else w / label_scale;
    const wrapped_label = try wrapDisplay(a, plain_label, label_budget);
    var labels = std.mem.splitScalar(u8, wrapped_label, '\n');
    if (plain_label.len > 0 or together) {
        while (labels.next()) |row| {
            const first = rows.items.len == 0;
            try rows.append(a, .{
                .label = row,
                .amount = if (together and first) plain_amount else null,
                .amount_style = right_style,
                .padding = if (together and first) w - amount_cols - row.len * label_scale else 0,
            });
        }
    }
    if (!together) {
        const wrapped_amount = try wrapDisplay(a, plain_amount, w / amount_scale);
        var amounts = std.mem.splitScalar(u8, wrapped_amount, '\n');
        while (amounts.next()) |row| {
            try rows.append(a, .{ .amount = row, .amount_style = right_style, .padding = w - row.len * amount_scale });
        }
    }
    return rows.toOwnedSlice(a);
}

fn emitTwoColumn(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, amount: []const u8, w: usize, label_style: Style, amount_style: Style) !void {
    const rows = try layoutTwoColumn(a, label, amount, w, label_style, amount_style);
    for (rows) |row| {
        try out.appendSlice(a, &[_]u8{ esc, 'a', 0 });
        try setStyle(a, out, label_style);
        try out.appendSlice(a, row.label);
        try setStyle(a, out, .{});
        if (row.amount) |right| {
            try out.appendNTimes(a, ' ', row.padding);
            try setStyle(a, out, row.amount_style);
            try out.appendSlice(a, right);
            try setStyle(a, out, .{});
        }
        try out.append(a, '\n');
    }
}

fn emitRaster(a: std.mem.Allocator, out: *std.ArrayList(u8), logo: Logo, width: Width) !void {
    try validateLogo(width, logo);
    const row_bytes = rasterRowBytes(logo);
    try out.appendSlice(a, &[_]u8{ esc, 'a', 1 });
    const low_x: u8 = @truncate(row_bytes);
    const high_x: u8 = @truncate(row_bytes >> 8);
    const low_y: u8 = @truncate(logo.height_px);
    const high_y: u8 = @truncate(logo.height_px >> 8);
    try out.appendSlice(a, &[_]u8{ gs, 'v', '0', 0, low_x, high_x, low_y, high_y });
    try out.appendSlice(a, logo.bits);
    try out.appendSlice(a, &[_]u8{ esc, 'a', 0 });
}

fn validateBarcode(data: []const u8, width: Width) Error!void {
    if (data.len == 0 or data.len > 255) return error.InvalidCode;
    for (data) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
            c == '-' or c == '.' or c == ' ' or c == '$' or c == '/' or c == '+' or c == '%';
        if (!ok) return error.InvalidCode;
    }
    const module_dots = 2;
    const wide_ratio = 3;
    const character_modules = 6 + 3 * wide_ratio + 1;
    const required_dots = (data.len + 2) * character_modules * module_dots - module_dots;
    if (required_dots > paperDots(width)) return error.TooWide;
}

fn emitBarcode(a: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8, height: u8, width: Width) !void {
    try validateBarcode(data, width);
    try out.appendSlice(a, &[_]u8{ gs, 'H', 2 });
    try out.appendSlice(a, &[_]u8{ gs, 'h', height });
    // GS w 2 selects two-dot narrow bars and a 3:1 CODE39 wide:narrow ratio.
    try out.appendSlice(a, &[_]u8{ gs, 'w', 2 });
    try out.appendSlice(a, &[_]u8{ gs, 'k', 69, @intCast(data.len) });
    try out.appendSlice(a, data);
    try out.append(a, '\n');
}

fn validateQr(payload: []const u8) Error!void {
    if (payload.len == 0 or payload.len > 700) return error.InvalidCode;
}

fn emitQr(a: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8, module_size: u8) !void {
    try validateQr(payload);
    const size = @min(@max(module_size, 1), 16);
    const store_len: u16 = @intCast(payload.len + 3);
    const pl: u8 = @truncate(store_len & 0xFF);
    const ph: u8 = @truncate((store_len >> 8) & 0xFF);
    try out.appendSlice(a, &[_]u8{ esc, 'a', 1 });
    try out.appendSlice(a, &[_]u8{ gs, '(', 'k', 4, 0, 49, 65, 50, 0 });
    try out.appendSlice(a, &[_]u8{ gs, '(', 'k', 3, 0, 49, 67, size });
    try out.appendSlice(a, &[_]u8{ gs, '(', 'k', 3, 0, 49, 69, 48 });
    try out.appendSlice(a, &[_]u8{ gs, '(', 'k', pl, ph, 49, 80, 48 });
    try out.appendSlice(a, payload);
    try out.appendSlice(a, &[_]u8{ gs, '(', 'k', 3, 0, 49, 81, 48 });
    try out.appendSlice(a, &[_]u8{ esc, 'a', 0 });
    try out.append(a, '\n');
}

fn decodeUtf8(s: []const u8, i: usize) struct { len: usize, cp: u21 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .len = 1, .cp = s[i] };
    if (i + n > s.len) return .{ .len = 1, .cp = s[i] };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .len = 1, .cp = s[i] };
    return .{ .len = n, .cp = cp };
}

fn cpColumns(cp: u21) usize {
    if (cp < 0x20) return 0;
    if (cp >= 0x1100 and
        (cp <= 0x115F or cp == 0x2329 or cp == 0x232A or
            (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
            (cp >= 0xAC00 and cp <= 0xD7A3) or
            (cp >= 0xF900 and cp <= 0xFAFF) or
            (cp >= 0xFE30 and cp <= 0xFE6F) or
            (cp >= 0xFF00 and cp <= 0xFF60) or
            (cp >= 0xFFE0 and cp <= 0xFFE6) or
            (cp >= 0x20000 and cp <= 0x3FFFD))) return 2;
    return 1;
}

pub fn displayWidth(text: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < text.len) {
        const d = decodeUtf8(text, i);
        cols += cpColumns(d.cp);
        i += @max(d.len, 1);
    }
    return cols;
}

pub fn wrapDisplay(a: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0) return error.InvalidWidth;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |paragraph| : (index += 1) {
        if (index > 0) try out.append(a, '\n');
        if (paragraph.len > 0) try wrapParagraph(a, &out, paragraph, width);
    }
    return out.toOwnedSlice(a);
}

fn wrapParagraph(a: std.mem.Allocator, out: *std.ArrayList(u8), paragraph: []const u8, width: usize) !void {
    var line_cols: usize = 0;
    var cols_since_space: usize = 0;
    var has_word = false;
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < paragraph.len) {
        const d = decodeUtf8(paragraph, i);
        const cw = cpColumns(d.cp);
        if (cw > width) return error.TooWide;
        if (cw > width - line_cols) {
            if (last_space) |sp| {
                out.items[sp] = '\n';
                line_cols = cols_since_space;
            } else {
                try out.append(a, '\n');
                line_cols = 0;
            }
            last_space = null;
            cols_since_space = 0;
            has_word = line_cols != 0;
            if (cw > width - line_cols) {
                try out.append(a, '\n');
                line_cols = 0;
                has_word = false;
            }
        }
        if (d.cp == ' ' and has_word) {
            last_space = out.items.len;
            cols_since_space = 0;
        } else {
            cols_since_space += cw;
        }
        try out.appendSlice(a, paragraph[i .. i + d.len]);
        line_cols += cw;
        if (d.cp != ' ') has_word = true;
        i += d.len;
    }
}

pub fn renderText(scratch: std.mem.Allocator, receipt: Receipt, template: Template) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(scratch);
    const w = template.width.columns();
    for (receipt.lines) |line| {
        switch (line) {
            .raster => |logo| {
                try validateLogo(template.width, logo);
                try out.appendSlice(scratch, "[logo]\n");
            },
            .barcode => |code| {
                try validateBarcode(code.data, template.width);
                try appendCodePreview(scratch, &out, "barcode", code.data, w);
            },
            .qr => |code| {
                try validateQr(code.payload);
                try appendCodePreview(scratch, &out, "qr", code.payload, w);
            },
            .gap => try out.appendSlice(scratch, "\n"),
            .rule => |rule| {
                try validateRule(rule.char);
                try out.appendNTimes(scratch, rule.char, w);
                try out.appendSlice(scratch, "\n");
            },
            .text => |text| {
                const layout = try layoutText(scratch, text.segments, w);
                var rows = std.mem.splitScalar(u8, layout.wrapped, '\n');
                while (rows.next()) |row| {
                    try appendAligned(scratch, &out, text.alignment, row, w, layout.style);
                    try out.appendSlice(scratch, "\n");
                }
            },
            .two_column => |tc| {
                const rows = try layoutTwoColumn(scratch, tc.label, tc.amount, w, tc.label_style, tc.amount_style);
                for (rows) |row| {
                    try out.appendSlice(scratch, row.label);
                    if (row.amount) |right| {
                        try out.appendNTimes(scratch, ' ', row.padding);
                        try out.appendSlice(scratch, right);
                    }
                    try out.appendSlice(scratch, "\n");
                }
            },
        }
    }
    return out.toOwnedSlice(scratch);
}

fn appendCodePreview(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, payload: []const u8, w: usize) !void {
    const safe = try a.alloc(u8, payload.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < payload.len) : (n += 1) {
        const d = decodeUtf8(payload, i);
        safe[n] = if (d.cp >= 0x20 and d.cp <= 0x7E) @intCast(d.cp) else '?';
        i += d.len;
    }
    const annotation = try std.fmt.allocPrint(a, "[{s} {s}]", .{ kind, safe[0..n] });
    try out.appendSlice(a, try wrapDisplay(a, annotation, w));
    try out.append(a, '\n');
}

fn appendAligned(a: std.mem.Allocator, out: *std.ArrayList(u8), alignment: Align, row: []const u8, w: usize, style: Style) !void {
    const cols = displayWidth(row) * styleMultiplier(style);
    if (cols > w) return error.TooWide;
    const gap = w - cols;
    const lead: usize = switch (alignment) {
        .left => 0,
        .center => gap / 2,
        .right => gap,
    };
    try out.appendNTimes(a, ' ', lead);
    try out.appendSlice(a, row);
}

// Golden generation is explicit; tests never rewrite their own references.
pub fn writeGoldens(dir_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();

    const wide = sampleTemplate(.mm80);
    const wide_bytes = try renderEscPos(a, try build(a, sampleSale(), wide, false), wide);
    try writeAll(dir, "sale-80mm.bin", wide_bytes);

    var narrow = sampleTemplate(.mm58);
    narrow.show_sku = true;
    narrow.footer = "Terima kasih";
    const narrow_bytes = try renderEscPos(a, try build(a, sampleSale(), narrow, false), narrow);
    try writeAll(dir, "sale-58mm.bin", narrow_bytes);
}

fn writeAll(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

const SampleTotals = struct {
    gross: i64,
    line_discount: i64,
    subtotal: i64,
    transaction_discount: i64,
    net_subtotal: i64,
    service_charge: i64,
    tax_base: i64,
    tax: i64,
    total_before_rounding: i64,
    rounding_adjustment: i64,
    total: i64,
};

const SampleItem = struct {
    product_id: i64,
    name: []const u8,
    sku: []const u8,
    barcode: []const u8,
    unit: []const u8,
    unit_price: i64,
    quantity_milli: i64,
    discount_kind: []const u8,
    discount_value: i64,
    note: []const u8,
    discount: i64,
    net: i64,
};

const SampleSale = struct {
    number: []const u8,
    created_at: []const u8,
    totals: SampleTotals,
    tendered: i64,
    change: i64,
    items: []const SampleItem,
};

pub fn sampleSale() SampleSale {
    return .{
        .number = "INV-20261028-0007",
        .created_at = "28 Okt 2026 14:05",
        .totals = .{
            .gross = 69_750,
            .line_discount = 1_500,
            .subtotal = 68_250,
            .transaction_discount = 0,
            .net_subtotal = 68_250,
            .service_charge = 0,
            .tax_base = 68_250,
            .tax = 0,
            .total_before_rounding = 68_250,
            .rounding_adjustment = 0,
            .total = 68_250,
        },
        .tendered = 100_000,
        .change = 31_750,
        .items = &[_]SampleItem{
            .{
                .product_id = 1,
                .name = "Kopi Susu Gula Aren Kemasan Botol Besar",
                .sku = "KOP-001",
                .barcode = "8991234567890",
                .unit = "pcs",
                .unit_price = 18_000,
                .quantity_milli = 2_000,
                .discount_kind = "none",
                .discount_value = 0,
                .note = "",
                .discount = 0,
                .net = 36_000,
            },
            .{
                .product_id = 2,
                .name = "Gula Pasir Curah",
                .sku = "GUL-002",
                .barcode = "",
                .unit = "kg",
                .unit_price = 13_500,
                .quantity_milli = 2_500,
                .discount_kind = "nominal",
                .discount_value = 1_500,
                .note = "timbang ulang",
                .discount = 1_500,
                .net = 32_250,
            },
        },
    };
}

pub fn sampleTemplate(width: Width) Template {
    return .{
        .width = width,
        .business_name = "Toko Maju Jaya",
        .business_address = "Jl. Merdeka No. 10, Jakarta",
        .footer = "Terima kasih atas kunjungan Anda",
    };
}

test "golden sample totals agree with the item prices quantities and discounts" {
    const sale = sampleSale();
    var gross: i64 = 0;
    var discount: i64 = 0;
    var net: i64 = 0;
    for (sale.items) |item| {
        const line_gross = @divTrunc(item.unit_price * item.quantity_milli, 1000);
        try std.testing.expectEqual(line_gross - item.discount, item.net);
        gross += line_gross;
        discount += item.discount;
        net += item.net;
    }
    try std.testing.expectEqual(gross, sale.totals.gross);
    try std.testing.expectEqual(discount, sale.totals.line_discount);
    try std.testing.expectEqual(net, sale.totals.total);
    try std.testing.expectEqual(sale.tendered - net, sale.change);
}

test "rupiah and quantity formatting match Indonesian locale" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Rp 0", try formatRupiah(a, 0));
    try std.testing.expectEqualStrings("Rp 1.000", try formatRupiah(a, 1_000));
    try std.testing.expectEqualStrings("Rp 61.500", try formatRupiah(a, 61_500));
    try std.testing.expectEqualStrings("Rp 1.000.000", try formatRupiah(a, 1_000_000));
    try std.testing.expectEqualStrings("Rp 12.345.678", try formatRupiah(a, 12_345_678));
    try std.testing.expectEqualStrings("2", try formatQuantity(a, 2_000));
    try std.testing.expectEqualStrings("2,5", try formatQuantity(a, 2_500));
    try std.testing.expectEqualStrings("0,5", try formatQuantity(a, 500));
    try std.testing.expectEqualStrings("0,001", try formatQuantity(a, 1));
    try std.testing.expectError(error.NegativeAmount, formatRupiah(a, -1));
    try std.testing.expectError(error.InvalidQuantity, formatQuantity(a, 0));
}

test "display width counts wide codepoints as two columns" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("abcde"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("漢字"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "wrapping breaks on spaces and force breaks long words without overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wrapped = try wrapDisplay(a, "Kopi Susu Gula Aren Kemasan Botol Besar", 20);
    var it = std.mem.splitScalar(u8, wrapped, '\n');
    while (it.next()) |row| try std.testing.expect(displayWidth(row) <= 20);
    const long = try wrapDisplay(a, "Supercalifragilisticexpialidocious", 10);
    var cols: usize = 0;
    it = std.mem.splitScalar(u8, long, '\n');
    while (it.next()) |row| {
        try std.testing.expect(row.len > 0);
        try std.testing.expect(displayWidth(row) <= 10);
        cols += displayWidth(row);
    }
    try std.testing.expectEqual(@as(usize, 34), cols);
}

test "every rendered text row fits the configured width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ Width.mm58, Width.mm80 }) |width| {
        const template = sampleTemplate(width);
        const receipt = try build(a, sampleSale(), template, false);
        const text = try renderText(a, receipt, template);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |row| {
            if (row.len == 0) continue;
            try std.testing.expect(displayWidth(row) <= width.columns());
        }
    }
}

test "copy mark and drawer kick and cut follow the template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = sampleTemplate(.mm80);
    const copy_bytes = try renderEscPos(a, try build(a, sampleSale(), template, true), template);
    try std.testing.expect(std.mem.indexOf(u8, copy_bytes, "*** SALINAN ***") != null);
    try std.testing.expect(std.mem.indexOf(u8, copy_bytes, &[_]u8{ esc, 'p', 0, 25, 250 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, copy_bytes, &[_]u8{ gs, 'V', 'B', 0 }) != null);

    template.cash_drawer = false;
    template.cut_paper = false;
    const plain_bytes = try renderEscPos(a, try build(a, sampleSale(), template, false), template);
    try std.testing.expect(std.mem.indexOf(u8, plain_bytes, "*** SALINAN ***") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_bytes, &[_]u8{ esc, 'p', 0, 25, 250 }) == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_bytes, &[_]u8{ gs, 'V', 'B', 0 }) == null);
}

test "copies multiply the document and each restarts with init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = sampleTemplate(.mm58);
    template.copies = 2;
    const receipt = try build(a, sampleSale(), template, false);
    const bytes = try renderEscPos(a, receipt, template);
    try std.testing.expectEqual(@as(u8, 2), receipt.copies);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, idx, &[_]u8{ esc, '@' })) |found| : (idx = found + 1) count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "logo raster is emitted and validated against the width budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = sampleTemplate(.mm58);
    template.logo = .{ .width_px = 8, .height_px = 2, .bits = &[_]u8{ 0xFF, 0x00 } };
    const bytes = try renderEscPos(a, try build(a, sampleSale(), template, false), template);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ 0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x02, 0x00, 0xFF, 0x00 }) != null);

    template.logo = .{ .width_px = 600, .height_px = 2, .bits = &[_]u8{ 0, 0 } };
    try std.testing.expectError(error.TooWide, build(a, sampleSale(), template, false));
    template.logo = .{ .width_px = 8, .height_px = 2, .bits = &[_]u8{0xFF} };
    try std.testing.expectError(error.InvalidBitmap, build(a, sampleSale(), template, false));
}

test "barcode rejects invalid code39 characters and qr guards payload size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try emitBarcode(a, &out, "8991234567890", 60, .mm80);
    try std.testing.expectError(error.InvalidCode, emitBarcode(a, &out, "BAD*CODE", 60, .mm80));
    try std.testing.expectError(error.InvalidCode, emitBarcode(a, &out, "", 60, .mm80));
    try emitQr(a, &out, "https://kasirku.local/r/1", 6);
    const huge = try a.alloc(u8, 701);
    @memset(huge, 'a');
    try std.testing.expectError(error.InvalidCode, emitQr(a, &out, huge, 6));
}

fn testReceipt(lines: []const Line) Receipt {
    return .{ .lines = lines, .cash_drawer = false, .cut_paper = false, .feed_lines = 0, .copies = 1 };
}

fn expectTextLayout(a: std.mem.Allocator, bytes: []const u8, width: usize, preview: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(a);
    var i: usize = 0;
    var scale: usize = 1;
    var alignment: u8 = 0;
    var columns: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == 0x1B) {
            try std.testing.expect(i + 1 < bytes.len);
            switch (bytes[i + 1]) {
                '@' => {
                    scale = 1;
                    alignment = 0;
                    i += 2;
                },
                'a' => {
                    alignment = bytes[i + 2];
                    i += 3;
                },
                'E' => i += 3,
                else => return error.UnexpectedPrinterCommand,
            }
        } else if (c == 0x1D) {
            try std.testing.expect(i + 2 < bytes.len);
            try std.testing.expectEqual(@as(u8, '!'), bytes[i + 1]);
            scale = @as(usize, bytes[i + 2] >> 4) + 1;
            i += 3;
        } else if (c == '\n') {
            try std.testing.expect(columns <= width);
            const padding = switch (alignment) {
                0 => @as(usize, 0),
                1 => (width - columns) / 2,
                2 => width - columns,
                else => return error.UnexpectedAlignment,
            };
            try text.appendNTimes(a, ' ', padding);
            try text.appendSlice(a, row.items);
            try text.append(a, '\n');
            row.clearRetainingCapacity();
            columns = 0;
            i += 1;
        } else {
            try std.testing.expect(c >= 0x20 and c <= 0x7E);
            columns += scale;
            try std.testing.expect(columns <= width);
            try row.append(a, c);
            i += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), row.items.len);
    try std.testing.expectEqualStrings(preview, text.items);
}

fn expectInvalidText(a: std.mem.Allocator, line: Line) !void {
    const receipt = testReceipt(&.{line});
    try std.testing.expectError(error.InvalidReceiptText, renderText(a, receipt, .{ .width = .mm58 }));
    try std.testing.expectError(error.InvalidReceiptText, renderEscPos(a, receipt, .{ .width = .mm58 }));
}

test "GS size flags independently encode only double height and width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const styles = [_]Style{ .{}, .{ .double_height = true }, .{ .double_width = true }, .{ .bold = true, .double_height = true, .double_width = true } };
    const expected = [_][6]u8{
        .{ 0x1B, 0x45, 0x00, 0x1D, 0x21, 0x00 },
        .{ 0x1B, 0x45, 0x00, 0x1D, 0x21, 0x01 },
        .{ 0x1B, 0x45, 0x00, 0x1D, 0x21, 0x10 },
        .{ 0x1B, 0x45, 0x01, 0x1D, 0x21, 0x11 },
    };
    for (styles, expected) |style, bytes| {
        out.clearRetainingCapacity();
        try setStyle(a, &out, style);
        try std.testing.expectEqualSlices(u8, &bytes, out.items);
    }
}

test "raster framing uses rounded row bytes and validates direct receipts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try emitRaster(a, &out, .{ .width_px = 9, .height_px = 2, .bits = &.{ 0xFF, 0x80, 0x00, 0x80 } }, .mm58);
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, 0x61, 1, 0x1D, 0x76, 0x30, 0, 2, 0, 2, 0, 0xFF, 0x80, 0, 0x80, 0x1B, 0x61, 0 }, out.items);
    const logos = [_]Logo{
        .{ .width_px = 65535, .height_px = 65535, .bits = "" },
        .{ .width_px = 385, .height_px = 1, .bits = "" },
        .{ .width_px = 0, .height_px = 1, .bits = "" },
        .{ .width_px = 8, .height_px = 0, .bits = "" },
        .{ .width_px = 9, .height_px = 1, .bits = &.{0xFF} },
    };
    for (logos, 0..) |logo, index| {
        const receipt = testReceipt(&.{.{ .raster = logo }});
        const expected: Error = if (index < 2) error.TooWide else error.InvalidBitmap;
        try std.testing.expectError(expected, renderEscPos(a, receipt, .{ .width = .mm58 }));
        try std.testing.expectError(expected, renderText(a, receipt, .{ .width = .mm58 }));
    }
    const bits = [_]u8{0} ** 72;
    out.clearRetainingCapacity();
    try emitRaster(a, &out, .{ .width_px = 576, .height_px = 1, .bits = &bits }, .mm80);
    try std.testing.expectEqualSlices(u8, &.{ 0x1D, 0x76, 0x30, 0, 72, 0, 1, 0 }, out.items[3..11]);
}

test "CODE39 length framing and 3 to 1 geometry respect both paper budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try emitBarcode(a, &out, "A-1", 60, .mm58);
    try std.testing.expectEqualSlices(u8, &.{ 0x1D, 0x48, 2, 0x1D, 0x68, 60, 0x1D, 0x77, 2, 0x1D, 0x6B, 69, 3, 'A', '-', '1', 10 }, out.items);
    try emitBarcode(a, &out, "1234567890", 60, .mm58);
    try emitBarcode(a, &out, "1234567890123456", 60, .mm80);
    try std.testing.expectError(error.TooWide, emitBarcode(a, &out, "12345678901", 60, .mm58));
    try std.testing.expectError(error.TooWide, emitBarcode(a, &out, "12345678901234567", 60, .mm80));
    for ([_][]const u8{ "lowercase", "A*B", "A\x00B", "A\x1BB", "漢", "" }) |data| {
        try std.testing.expectError(error.InvalidCode, emitBarcode(a, &out, data, 60, .mm80));
        const receipt = testReceipt(&.{.{ .barcode = .{ .data = data } }});
        try std.testing.expectError(error.InvalidCode, renderText(a, receipt, .{}));
        try std.testing.expectError(error.InvalidCode, renderEscPos(a, receipt, .{}));
    }
    const narrow = testReceipt(&.{.{ .barcode = .{ .data = "12345678901" } }});
    try std.testing.expectError(error.TooWide, renderText(a, narrow, .{ .width = .mm58 }));
    try std.testing.expectError(error.TooWide, renderEscPos(a, narrow, .{ .width = .mm58 }));
}

test "QR opaque bytes stay length framed and preview remains printable and wrapped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const payload = "A\x00\x1B\x1DB";
    try emitQr(a, &out, payload, 6);
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, 0x61, 1, 0x1D, 0x28, 0x6B, 4, 0, 49, 65, 50, 0, 0x1D, 0x28, 0x6B, 3, 0, 49, 67, 6, 0x1D, 0x28, 0x6B, 3, 0, 49, 69, 48, 0x1D, 0x28, 0x6B, 8, 0, 49, 80, 48, 'A', 0, 0x1B, 0x1D, 'B', 0x1D, 0x28, 0x6B, 3, 0, 49, 81, 48, 0x1B, 0x61, 0, 10 }, out.items);
    try std.testing.expectEqualStrings("[qr A???B]\n", try renderText(a, testReceipt(&.{.{ .qr = .{ .payload = payload } }}), .{}));
    const long = [_]u8{'A'} ** 100;
    const receipt = testReceipt(&.{.{ .qr = .{ .payload = &long } }});
    const preview = try renderText(a, receipt, .{ .width = .mm58 });
    var rows = std.mem.splitScalar(u8, preview, '\n');
    while (rows.next()) |row| try std.testing.expect(row.len <= 32);
    const huge = [_]u8{'A'} ** 701;
    const invalid = testReceipt(&.{.{ .qr = .{ .payload = &huge } }});
    try std.testing.expectError(error.InvalidCode, renderText(a, invalid, .{}));
    try std.testing.expectError(error.InvalidCode, renderEscPos(a, invalid, .{}));
}

test "wrapping counts leading spaces and rejects zero or unfit wide character budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("    \nabc", try wrapDisplay(a, "    abc", 4));
    try std.testing.expectEqualStrings("   \n   \nx", try wrapDisplay(a, "      x", 3));
    try std.testing.expectError(error.InvalidWidth, wrapDisplay(a, "", 0));
    try std.testing.expectError(error.InvalidWidth, wrapDisplay(a, "abc", 0));
    try std.testing.expectError(error.TooWide, wrapDisplay(a, "漢", 1));
    for ([_][]const u8{ "   漢字漢字 abcdefghijklmnop", "       longword\n   漢字漢字\n", "    \n  \n漢字漢字漢字", "a  漢字漢字 aaaaaaaaa" }) |input| {
        for (2..9) |width| {
            const wrapped = try wrapDisplay(a, input, width);
            var rows = std.mem.splitScalar(u8, wrapped, '\n');
            while (rows.next()) |row| try std.testing.expect(displayWidth(row) <= width);
        }
    }
}

test "render boundaries reject invalid UTF8 and every unsafe text control" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..128) |value| {
        if (value >= 32 and value != 127) continue;
        if (value == 9 or value == 10 or value == 13) continue;
        const text = [_]u8{ 'A', @intCast(value), 'B' };
        try expectInvalidText(a, .{ .text = .{ .segments = &.{.{ .text = &text }} } });
        try expectInvalidText(a, .{ .two_column = .{ .label = &text, .amount = "Rp 1" } });
        try expectInvalidText(a, .{ .two_column = .{ .label = "Total", .amount = &text } });
        try expectInvalidText(a, .{ .rule = .{ .char = @intCast(value) } });
    }
    for ([_][]const u8{ "\xFF", "\xC0\xAF", "\xED\xA0\x80", "\xE2\x82", "\xF4\x90\x80\x80" }) |text| {
        try expectInvalidText(a, .{ .text = .{ .segments = &.{.{ .text = text }} } });
        try expectInvalidText(a, .{ .two_column = .{ .label = text, .amount = "Rp 1" } });
        try expectInvalidText(a, .{ .two_column = .{ .label = "Total", .amount = text } });
    }
    for ([_]u8{ '\n', '\r', '\t', 0x80, 0xFF }) |char| try expectInvalidText(a, .{ .rule = .{ .char = char } });
}

test "ASCII fallback and newline normalization agree between both renderers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receipt = testReceipt(&.{.{ .text = .{ .segments = &.{.{ .text = "Café 漢字 😀\r\nA\tB\rC\nD" }} } }});
    const preview = try renderText(a, receipt, .{ .width = .mm58 });
    try std.testing.expectEqualStrings("Caf? ?? ?\nA B\nC\nD\n", preview);
    try expectTextLayout(a, try renderEscPos(a, receipt, .{ .width = .mm58 }), 32, preview);
    const columns = testReceipt(&.{.{ .two_column = .{ .label = "漢字", .amount = "é" } }});
    const column_preview = try renderText(a, columns, .{ .width = .mm58 });
    try std.testing.expect(std.mem.startsWith(u8, column_preview, "??"));
    try expectTextLayout(a, try renderEscPos(a, columns, .{ .width = .mm58 }), 32, column_preview);
}

test "58mm styled TOTAL preserves maximum money intact by reducing amount width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = Style{ .bold = true, .double_width = true, .double_height = true };
    const receipt = testReceipt(&.{.{ .two_column = .{ .label = "TOTAL", .amount = try formatRupiah(a, money.max_amount), .label_style = big, .amount_style = big } }});
    const preview = try renderText(a, receipt, .{ .width = .mm58 });
    try std.testing.expectEqualStrings("TOTAL\n        Rp 9.000.000.000.000.000\n", preview);
    try expectTextLayout(a, try renderEscPos(a, receipt, .{ .width = .mm58 }), 32, preview);
    const normal = testReceipt(&.{.{ .two_column = .{ .label = "TOTAL", .amount = "Rp 61.500", .label_style = big, .amount_style = big } }});
    const normal_preview = try renderText(a, normal, .{ .width = .mm58 });
    try std.testing.expectEqualStrings("TOTAL    Rp 61.500\n", normal_preview);
    try expectTextLayout(a, try renderEscPos(a, normal, .{ .width = .mm58 }), 32, normal_preview);
}

test "amount equals width and multiline styled content cannot underflow padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const amount = "12345678901234567890123456789012";
    const receipt = testReceipt(&.{.{ .two_column = .{ .label = "Label", .amount = amount } }});
    const preview = try renderText(a, receipt, .{ .width = .mm58 });
    try std.testing.expectEqualStrings("Label\n12345678901234567890123456789012\n", preview);
    try expectTextLayout(a, try renderEscPos(a, receipt, .{ .width = .mm58 }), 32, preview);
    inline for (.{ Width.mm58, Width.mm80 }) |width| {
        const template = Template{ .width = width };
        const long = testReceipt(&.{
            .{ .text = .{ .alignment = .center, .segments = &.{.{ .text = "    abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n  漢字 long words and more words\n", .style = .{ .double_width = true } }} } },
            .{ .text = .{ .alignment = .right, .segments = &.{.{ .text = "   abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n   end", .style = .{ .double_width = true, .double_height = true } }} } },
            .{ .two_column = .{ .label = "  Very long label\nwith a second long line and 漢字", .amount = "12345678901234567890123456789012\nABCDEFG", .label_style = .{ .double_width = true }, .amount_style = .{ .double_width = true } } },
            .{ .two_column = .{ .label = "", .amount = amount } },
            .{ .two_column = .{ .label = "Label", .amount = amount[0..16], .amount_style = .{ .double_width = true } } },
        });
        const long_preview = try renderText(a, long, template);
        try expectTextLayout(a, try renderEscPos(a, long, template), width.columns(), long_preview);
        var rows = std.mem.splitScalar(u8, long_preview, '\n');
        while (rows.next()) |row| try std.testing.expect(row.len <= width.columns());
    }
}

test "copies kick drawer once but retain feed and cut for each document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var receipt = testReceipt(&.{.{ .text = .{ .segments = &.{.{ .text = "Sale" }} } }});
    receipt.copies = 3;
    receipt.cash_drawer = true;
    receipt.cut_paper = true;
    receipt.feed_lines = 2;
    const bytes = try renderEscPos(a, receipt, .{});
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\x1B@"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, &.{ 0x1B, 0x70, 0, 25, 250 }));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, &.{ 10, 10, 0x1D, 0x56, 0x42, 0 }));
}

test "build and render survive every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllAllocationFailures, .{});
}

fn exerciseAllAllocationFailures(a: std.mem.Allocator) !void {
    inline for (.{ Width.mm58, Width.mm80 }) |width| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const work = arena.allocator();
        var template = sampleTemplate(width);
        template.show_sku = true;
        template.show_barcode = true;
        var items = sampleSale().items[0..2].*;
        items[0].barcode = "1234567890";
        var sale = sampleSale();
        sale.items = &items;
        const receipt = try build(work, sale, template, false);
        _ = try renderEscPos(work, receipt, template);
        _ = try renderText(work, receipt, template);
    }
}
