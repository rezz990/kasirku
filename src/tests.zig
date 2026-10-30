test {
    _ = @import("domain/root.zig");
    _ = @import("domain/receipt_golden.zig");
    _ = @import("infra/db/sqlite.zig");
    _ = @import("infra/printer.zig");
    _ = @import("app/pos.zig");
    _ = @import("app/device.zig");
    _ = @import("app/shift.zig");
    _ = @import("bridge/dispatcher.zig");
}
