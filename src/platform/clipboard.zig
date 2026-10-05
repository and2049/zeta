//! Clipboard writes: through the terminal (OSC 52) and through the
//! desktop's clipboard program. No shell; the text only travels on stdin.
const std = @import("std");
const Io = std.Io;

/// The display servers the environment names (`WAYLAND_DISPLAY`,
/// `DISPLAY`); they decide which programs are tried.
pub const Hosts = struct { wayland: bool = false, x11: bool = false };

/// Longer text is not sent through the terminal; many cut it off.
pub const osc52_max = 100 * 1024;

/// The sequence that asks the terminal to set its clipboard, owned by the
/// caller; null when `text` is too long for it.
pub fn osc52(a: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len > osc52_max) return null;
    const prefix = "\x1b]52;c;";
    const encoder = std.base64.standard.Encoder;
    const out = try a.alloc(u8, prefix.len + encoder.calcSize(text.len) + 2);
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len .. out.len - 2], text);
    @memcpy(out[out.len - 2 ..], "\x1b\\");
    return out;
}

const Launcher = *const fn (Io, []const []const u8, []const u8) anyerror!void;

/// Hands `text` to the first clipboard program that is installed. Blocks
/// until the program has taken it.
pub fn copy(io: Io, hosts: Hosts, text: []const u8) !void {
    return copyWith(io, hosts, text, @import("builtin").os.tag == .macos, pipe);
}

fn copyWith(io: Io, hosts: Hosts, text: []const u8, macos: bool, launcher: Launcher) !void {
    const programs = [_]struct { use: bool, argv: []const []const u8 }{
        .{ .use = macos, .argv = &.{"pbcopy"} },
        .{ .use = hosts.wayland, .argv = &.{"wl-copy"} },
        .{ .use = hosts.x11, .argv = &.{ "xclip", "-selection", "clipboard" } },
        .{ .use = hosts.x11, .argv = &.{ "xsel", "--clipboard", "--input" } },
    };
    for (programs) |program| {
        if (!program.use) continue;
        launcher(io, program.argv, text) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        return;
    }
    return error.NoClipboardProgram;
}

fn pipe(io: Io, argv: []const []const u8, text: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const stdin = child.stdin.?;
    child.stdin = null;
    // A program that exits without reading ends the write; its status says so.
    stdin.writeStreamingAll(io, text) catch {};
    stdin.close(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.ClipboardProgramFailed;
}

test "the terminal sequence carries base64 and has a size limit" {
    const a = std.testing.allocator;
    const sequence = (try osc52(a, "hi there")).?;
    defer a.free(sequence);
    try std.testing.expectEqualStrings("\x1b]52;c;aGkgdGhlcmU=\x1b\\", sequence);
    const big = try a.alloc(u8, osc52_max + 1);
    defer a.free(big);
    @memset(big, 'x');
    try std.testing.expect(try osc52(a, big) == null);
}

test "programs are tried in order for the display servers present" {
    const fake = struct {
        var tried: [4][]const u8 = undefined;
        var count: usize = 0;
        fn missing(_: Io, argv: []const []const u8, _: []const u8) anyerror!void {
            tried[count] = argv[0];
            count += 1;
            return error.FileNotFound;
        }
        fn xclipOnly(_: Io, argv: []const []const u8, text: []const u8) anyerror!void {
            tried[count] = argv[0];
            count += 1;
            if (!std.mem.eql(u8, argv[0], "xclip")) return error.FileNotFound;
            try std.testing.expectEqualStrings("$(rm -rf)", text);
        }
    };
    try std.testing.expectError(error.NoClipboardProgram, copyWith(std.testing.io, .{}, "x", false, fake.missing));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    try copyWith(std.testing.io, .{ .wayland = true, .x11 = true }, "$(rm -rf)", false, fake.xclipOnly);
    try std.testing.expectEqualStrings("wl-copy", fake.tried[0]);
    try std.testing.expectEqualStrings("xclip", fake.tried[1]);
    try std.testing.expectEqual(@as(usize, 2), fake.count);
    fake.count = 0;
    try std.testing.expectError(error.NoClipboardProgram, copyWith(std.testing.io, .{ .x11 = true }, "x", true, fake.missing));
    try std.testing.expectEqualStrings("pbcopy", fake.tried[0]);
    try std.testing.expectEqual(@as(usize, 3), fake.count);
}

test "a real program receives the text on stdin; a missing one is skipped" {
    try pipe(std.testing.io, &.{ "sh", "-c", "test \"$(cat)\" = 'two words'" }, "two words");
    try std.testing.expectError(error.ClipboardProgramFailed, pipe(std.testing.io, &.{ "sh", "-c", "exit 3" }, "x"));
    try std.testing.expectError(error.FileNotFound, pipe(std.testing.io, &.{"zeta-no-such-clipboard-program"}, "x"));
}
