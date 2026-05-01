const real_main = @import("src/main.zig");
pub const main = real_main.main;

test {
    _ = @import("src/main.zig");
}
