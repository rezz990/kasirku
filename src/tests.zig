test {
    _ = @import("domain/root.zig");
    _ = @import("infra/db/sqlite.zig");
    _ = @import("app/pos.zig");
    _ = @import("bridge/dispatcher.zig");
}
