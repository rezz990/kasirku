pub const money = @import("money.zig");
pub const cart = @import("cart.zig");
pub const inventory = @import("inventory.zig");
pub const receipt = @import("receipt.zig");

test {
    _ = money;
    _ = cart;
    _ = inventory;
    _ = receipt;
}
