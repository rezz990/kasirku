const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    SpoolerOpenFailed,
    SpoolerJobFailed,
    PrinterNotFound,
    PrinterUnreachable,
    PrintUnknown,
    UnsupportedTarget,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError;

pub const Target = union(enum) {
    // Windows print spooler, submitted with the RAW datatype so pre-rendered
    // ESC/POS bytes reach the port untouched by any driver.
    spooler: []const u8,
    // Write to a file; lets the cashier verify output without hardware.
    file: []const u8,
    // Network printer listening on the raw JetDirect port, normally 9100.
    tcp: struct { host: []const u8, port: u16 },
};

pub const Printer = struct {
    name: []const u8,
    is_default: bool,
};

const DWORD = u32;
const HANDLE = ?*anyopaque;

extern "winspool" fn OpenPrinterW(p: [*:0]const u16, ph: *HANDLE, pd: ?*anyopaque) DWORD;
extern "winspool" fn ClosePrinter(h: HANDLE) DWORD;
extern "winspool" fn StartDocPrinterW(h: HANDLE, level: DWORD, di: *DOC_INFO_1W) DWORD;
extern "winspool" fn EndDocPrinter(h: HANDLE) DWORD;
extern "winspool" fn StartPagePrinter(h: HANDLE) DWORD;
extern "winspool" fn EndPagePrinter(h: HANDLE) DWORD;
extern "winspool" fn WritePrinter(h: HANDLE, buf: [*]const u8, len: DWORD, written: *DWORD) DWORD;
extern "winspool" fn AbortPrinter(h: HANDLE) DWORD;
extern "winspool" fn EnumPrintersW(flags: DWORD, name: ?[*:0]const u16, level: DWORD, buf: ?[*]u8, cb: DWORD, needed: *DWORD, returned: *DWORD) DWORD;
extern "winspool" fn GetDefaultPrinterW(buf: ?[*]u16, size: *DWORD) DWORD;
extern "kernel32" fn GetLastError() DWORD;

const PRINTER_ENUM_LOCAL = 0x00000002;
const PRINTER_ENUM_CONNECTIONS = 0x00000004;

const DOC_INFO_1W = extern struct {
    pDocName: [*:0]const u16,
    pOutputFile: ?[*:0]const u16,
    pDatatype: [*:0]const u16,
};

const PRINTER_INFO_1W = extern struct {
    Flags: DWORD,
    pDescription: ?[*:0]const u16,
    pName: ?[*:0]const u16,
    pComment: ?[*:0]const u16,
};

pub fn listPrinters(allocator: std.mem.Allocator) Error![]Printer {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedTarget;
    var needed: DWORD = 0;
    var count: DWORD = 0;
    const flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    if (EnumPrintersW(flags, null, 1, null, 0, &needed, &count) == 0 and GetLastError() != 122) return error.SpoolerOpenFailed;
    if (needed == 0) return allocator.alloc(Printer, 0);
    const buffer = try allocator.alignedAlloc(u8, .of(PRINTER_INFO_1W), needed);
    defer allocator.free(buffer);
    if (EnumPrintersW(flags, null, 1, buffer.ptr, needed, &needed, &count) == 0) return error.SpoolerOpenFailed;

    const default_name = readDefaultPrinter(allocator) catch |err| switch (err) {
        error.PrinterNotFound => null,
        else => return err,
    };
    defer if (default_name) |n| allocator.free(n);

    const infos: [*]PRINTER_INFO_1W = @ptrCast(buffer.ptr);
    var list: std.ArrayList(Printer) = .empty;
    errdefer {
        for (list.items) |entry| allocator.free(entry.name);
        list.deinit(allocator);
    }
    var i: DWORD = 0;
    while (i < count) : (i += 1) {
        const wide = infos[i].pName orelse continue;
        const name = try wideToUtf8(allocator, wide);
        errdefer allocator.free(name);
        const is_default = if (default_name) |d| std.mem.eql(u8, d, name) else false;
        try list.append(allocator, .{ .name = name, .is_default = is_default });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freePrinters(allocator: std.mem.Allocator, printers: []Printer) void {
    for (printers) |entry| allocator.free(entry.name);
    allocator.free(printers);
}

fn readDefaultPrinter(allocator: std.mem.Allocator) Error![]u8 {
    var size: DWORD = 0;
    _ = GetDefaultPrinterW(null, &size);
    if (size == 0) return error.PrinterNotFound;
    const wide = try allocator.alloc(u16, size);
    defer allocator.free(wide);
    if (GetDefaultPrinterW(wide.ptr, &size) == 0) return error.PrinterNotFound;
    const slice = wide[0 .. size - 1];
    return std.unicode.utf16LeToUtf8Alloc(allocator, slice) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpoolerOpenFailed,
    };
}

fn wideToUtf8(allocator: std.mem.Allocator, wide: [*:0]const u16) Error![]u8 {
    const length = std.mem.len(wide);
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..length]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpoolerOpenFailed,
    };
}

fn sendToSpooler(name: []const u8, bytes: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
    var handle: HANDLE = null;
    if (OpenPrinterW(wide_name.ptr, &handle, null) == 0) return if (GetLastError() == 1801) error.PrinterNotFound else error.SpoolerOpenFailed;
    defer _ = ClosePrinter(handle);

    const doc_name = try std.unicode.utf8ToUtf16LeAllocZ(a, "KasirKu");
    const datatype = try std.unicode.utf8ToUtf16LeAllocZ(a, "RAW");
    var info = DOC_INFO_1W{ .pDocName = doc_name.ptr, .pOutputFile = null, .pDatatype = datatype.ptr };
    if (StartDocPrinterW(handle, 1, &info) == 0) return error.SpoolerJobFailed;
    // Abort incomplete jobs, but RAW bytes may already have reached the device.
    var doc_open = true;
    defer {
        if (doc_open) _ = AbortPrinter(handle);
    }

    if (StartPagePrinter(handle) == 0) return error.SpoolerJobFailed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk: DWORD = @intCast(@min(bytes.len - offset, 0xFFFF));
        var written: DWORD = 0;
        if (WritePrinter(handle, bytes.ptr + offset, chunk, &written) == 0 or written != chunk) return error.PrintUnknown;
        offset += written;
    }
    if (EndPagePrinter(handle) == 0) return error.PrintUnknown;
    if (EndDocPrinter(handle) == 0) return error.PrintUnknown;
    doc_open = false;
}

fn sendToFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    file.writeAll(bytes) catch return error.PrintUnknown;
}

fn sendToTcp(host: []const u8, port: u16, bytes: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var stream = std.net.tcpConnectToHost(arena.allocator(), host, port) catch return error.PrinterUnreachable;
    defer stream.close();
    stream.writeAll(bytes) catch return error.PrintUnknown;
}

pub fn send(target: Target, bytes: []const u8) Error!void {
    switch (target) {
        .spooler => |name| try sendToSpooler(name, bytes),
        .file => |path| try sendToFile(path, bytes),
        .tcp => |tcp| try sendToTcp(tcp.host, tcp.port, bytes),
    }
}

test "file target writes the exact bytes and reports unwritable paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payload = "ABC\x1B@def\x00\x1D";
    var random: [8]u8 = undefined;
    std.crypto.random.bytes(&random);
    const name = try std.fmt.allocPrint(a, "kasirku-printer-{s}.bin", .{std.fmt.bytesToHex(random, .lower)});
    defer std.fs.cwd().deleteFile(name) catch {};

    try send(.{ .file = name }, payload);
    const written = try std.fs.cwd().readFileAlloc(a, name, 4096);
    try std.testing.expectEqualStrings(payload, written);

    try std.testing.expectError(error.FileNotFound, send(.{ .file = "kasirku-missing-dir/out.bin" }, payload));
}

test "Windows printer names convert without losing unicode or accepting invalid UTF16" {
    const a = std.testing.allocator;
    const name = [_:0]u16{ 'P', 'O', 'S', ' ', 0x00E9 };
    const converted = try wideToUtf8(a, &name);
    defer a.free(converted);
    try std.testing.expectEqualStrings("POS é", converted);
    const invalid = [_:0]u16{0xD800};
    try std.testing.expectError(error.SpoolerOpenFailed, wideToUtf8(a, &invalid));
}

test "owned printer names and list can be released together" {
    const a = std.testing.allocator;
    const entries = try a.alloc(Printer, 2);
    entries[0] = .{ .name = try a.dupe(u8, "POS 58"), .is_default = true };
    entries[1] = .{ .name = try a.dupe(u8, "POS 80"), .is_default = false };
    freePrinters(a, entries);
}
