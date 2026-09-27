//! Names reserved from plugin commands.
const std = @import("std");

/// Reserved names unavailable to plugin commands.
pub const builtin = [_][]const u8{ "new", "resume", "model", "connect", "rename", "delete", "reload", "compact", "fork", "undo", "attach", "pending", "help", "quit" };

pub fn isBuiltin(name: []const u8) bool {
    for (builtin) |reserved| if (std.mem.eql(u8, reserved, name)) return true;
    return false;
}

test "built-in names are reserved" {
    try std.testing.expect(isBuiltin("model"));
    try std.testing.expect(!isBuiltin("review"));
}
