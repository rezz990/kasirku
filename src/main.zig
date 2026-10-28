const std = @import("std");
const Database = @import("infra/db/sqlite.zig").Database;
const bridge = @import("bridge/dispatcher.zig");
const win = @cImport({
    @cDefine("UNICODE", "1");
    @cInclude("windows.h");
});
extern fn kasirku_host_run(data_dir: [*:0]const u16, smoke: bool) c_int;
var database: ?Database = null;
var smoke_mode = false;

pub fn main() void {
    const result = start() catch |err| {
        std.debug.print("KasirKu startup failed: {s}\n", .{@errorName(err)});
        if (smoke_mode) std.process.exit(1);
        const message = std.unicode.utf8ToUtf16LeStringLiteral("KasirKu tidak dapat membuka data lokal. Pastikan folder data dapat ditulis, ruang disk tersedia, dan versi aplikasi sesuai. Data lama tidak dihapus.");
        _ = win.MessageBoxW(null, message, std.unicode.utf8ToUtf16LeStringLiteral("KasirKu"), win.MB_OK | win.MB_ICONERROR);
        std.process.exit(1);
    };
    std.process.exit(result);
}

fn start() !u8 {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke-test");
    smoke_mode = smoke;
    if (args.len > 1 and !smoke) return error.InvalidArguments;
    const local = try std.process.getEnvVarOwned(allocator, if (smoke) "TEMP" else "LOCALAPPDATA");
    defer allocator.free(local);
    var random: [12]u8 = undefined;
    std.crypto.random.bytes(&random);
    const folder = if (smoke) try std.fmt.allocPrint(allocator, "KasirKu-smoke-{s}", .{std.fmt.bytesToHex(random, .lower)}) else try allocator.dupe(u8, "KasirKu");
    defer allocator.free(folder);
    const data_dir = try std.fs.path.join(allocator, &.{ local, folder });
    defer allocator.free(data_dir);
    try std.fs.cwd().makePath(data_dir);
    defer if (smoke) std.fs.cwd().deleteTree(data_dir) catch {};
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/kasirku.db", .{data_dir}, 0);
    defer allocator.free(db_path);
    const data_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, data_dir);
    defer allocator.free(data_wide);
    database = try Database.open(db_path);
    defer {
        database.?.close();
        database = null;
    }
    try database.?.migrate(allocator, db_path);
    const result = kasirku_host_run(data_wide, smoke);
    if (result != 0) return 1;
    if (smoke) std.debug.print("WebView2 -> Zig: smoke test passed; SQLite initialized\n", .{});
    return 0;
}

export fn kasirku_dispatch(request: [*:0]const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const response = bridge.dispatch(allocator, database.?, std.mem.span(request)) catch return null;
    defer allocator.free(response);
    const terminated = allocator.dupeZ(u8, response) catch return null;
    return terminated.ptr;
}

export fn kasirku_free(response: [*:0]u8) void {
    std.heap.c_allocator.free(std.mem.span(response));
}
