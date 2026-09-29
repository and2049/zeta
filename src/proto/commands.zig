//! Slash commands shared by the server listing and clients.
const std = @import("std");

/// Reserved names shared by the server and client command helpers.
/// A template with one of these names is skipped with a diagnostic.
pub const builtin = [_][]const u8{ "new", "resume", "model", "connect", "rename", "delete", "reload", "mcp", "extensions", "compact", "fork", "undo", "attach", "pending", "help", "quit" };

pub fn isBuiltin(name: []const u8) bool {
    for (builtin) |reserved| if (std.mem.eql(u8, reserved, name)) return true;
    return false;
}

/// One entry of `GET /commands`.
pub const Info = struct {
    name: []const u8,
    description: []const u8,
    argumentHint: ?[]const u8 = null,
    /// `user` or `project`.
    source: []const u8,
};

test "built-in names are reserved" {
    try std.testing.expect(isBuiltin("model"));
    try std.testing.expect(!isBuiltin("review"));
}
