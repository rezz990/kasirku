const std = @import("std");
const receipt = @import("receipt.zig");
const golden = @import("golden_options");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    const dir = if (args.len > 1) args[1] else golden.dir;
    try receipt.writeGoldens(dir);
    std.debug.print("wrote receipt goldens to {s}\n", .{dir});
}
