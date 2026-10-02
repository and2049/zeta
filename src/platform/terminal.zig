//! Secret input from stdin: hide echo for the read and restore on return.
const std = @import("std");
const Io = std.Io;

const max_key = 64 * 1024;

/// Returns an allocated single line without LF/CRLF; caller must overwrite
/// the bytes before freeing. Does not consume a second line from a pipe.
pub fn readSecret(allocator: std.mem.Allocator, io: Io) ![]u8 {
    return readSecretFrom(allocator, io, Io.File.stdin(), Io.File.stderr(), "API key: ");
}

/// `readSecret` with another prompt on a terminal.
pub fn readSecretPrompt(allocator: std.mem.Allocator, io: Io, prompt: []const u8) ![]u8 {
    return readSecretFrom(allocator, io, Io.File.stdin(), Io.File.stderr(), prompt);
}

fn readSecretFrom(allocator: std.mem.Allocator, io: Io, input: Io.File, prompt_file: Io.File, prompt: []const u8) ![]u8 {
    const tty = try input.isTty(io);
    if (tty) {
        const original = try std.posix.tcgetattr(input.handle);
        var hidden = original;
        hidden.lflag.ECHO = false;
        hidden.lflag.ECHONL = false;
        hidden.lflag.ICANON = false;
        // Handle keyboard cancellation as input so the restoration defer runs.
        hidden.lflag.ISIG = false;
        hidden.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        hidden.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(input.handle, .FLUSH, hidden);
        defer std.posix.tcsetattr(input.handle, .FLUSH, original) catch {};
        try prompt_file.writeStreamingAll(io, prompt);
        defer prompt_file.writeStreamingAll(io, "\n") catch {};
        return readLine(allocator, io, input, true);
    }
    return readLine(allocator, io, input, false);
}

fn readLine(allocator: std.mem.Allocator, io: Io, input: Io.File, tty: bool) ![]u8 {
    var bytes: [max_key]u8 = undefined;
    defer @memset(&bytes, 0);
    var len: usize = 0;
    var c: [1]u8 = undefined;
    while (true) {
        const n = input.readStreaming(io, &.{&c}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
        if (n == 0 or c[0] == '\n') break;
        if (tty) switch (c[0]) {
            3, 4, 26 => return error.InputCanceled,
            8, 127 => {
                if (len > 0) len -= 1;
                continue;
            },
            21 => {
                len = 0;
                continue;
            },
            else => {},
        };
        if (len == max_key) return error.ApiKeyTooLong;
        bytes[len] = c[0];
        len += 1;
    }
    if (len > 0 and bytes[len - 1] == '\r') len -= 1;
    if (len == 0) return error.EmptyApiKey;
    return try allocator.dupe(u8, bytes[0..len]);
}

test "pipe input consumes exactly one line" {
    const io = std.testing.io;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const input: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const output: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    try output.writeStreamingAll(io, "secret\r\nsecond\n");
    output.close(io);
    const secret = try readSecretFrom(std.testing.allocator, io, input, Io.File.stderr(), "API key: ");
    defer std.testing.allocator.free(secret);
    try std.testing.expectEqualStrings("secret", secret);
}
