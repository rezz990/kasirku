const std = @import("std");
const receipt = @import("receipt.zig");
const golden = @import("golden_options");

fn checkGolden(a: std.mem.Allocator, name: []const u8, actual: []const u8) !void {
    const path = try std.fs.path.join(a, &[_][]const u8{ golden.dir, name });
    defer a.free(path);
    const expected = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch {
        std.debug.print("missing golden reference {s}; run `zig build golden`\n", .{path});
        return error.GoldenMissing;
    };
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "escpos golden bytes are stable for 80mm and 58mm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wide = receipt.sampleTemplate(.mm80);
    const wide_bytes = try receipt.renderEscPos(a, try receipt.build(a, receipt.sampleSale(), wide, false), wide);
    try checkGolden(a, "sale-80mm.bin", wide_bytes);

    var narrow = receipt.sampleTemplate(.mm58);
    narrow.show_sku = true;
    narrow.footer = "Terima kasih";
    const narrow_bytes = try receipt.renderEscPos(a, try receipt.build(a, receipt.sampleSale(), narrow, false), narrow);
    try checkGolden(a, "sale-58mm.bin", narrow_bytes);
}
