//! Browser opener: no shell, no terminal output, never interpolates the URL.
const std = @import("std");

pub fn open(io: std.Io, url: []const u8) !void {
    return openWith(io, url, launch);
}

fn openWith(io: std.Io, url: []const u8, launcher: *const fn (std.Io, []const []const u8) anyerror!void) !void {
    const command = switch (@import("builtin").os.tag) {
        .linux => "xdg-open",
        .macos => "open",
        else => return error.UnsupportedPlatform,
    };
    try launcher(io, &.{ command, url });
}

fn launch(io: std.Io, argv: []const []const u8) !void {
    _ = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

test "opener passes full URL as one argument, without shell expansion" {
    const fake = struct {
        fn launch(_: std.Io, argv: []const []const u8) !void {
            try std.testing.expectEqual(@as(usize, 2), argv.len);
            try std.testing.expectEqualStrings("https://example.test/?q=x&danger=$(touch /tmp/no)", argv[1]);
            try std.testing.expectEqualStrings(if (@import("builtin").os.tag == .macos) "open" else "xdg-open", argv[0]);
        }
    }.launch;
    try openWith(std.testing.io, "https://example.test/?q=x&danger=$(touch /tmp/no)", fake);
}
