const std = @import("std");

pub fn assertS(cond: bool, comptime format: []const u8, args: anytype) void {
    @disableInstrumentation();
    if (!cond) {
        std.debug.panic(format, args);
        unreachable;
    }
}
