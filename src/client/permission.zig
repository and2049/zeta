//! TTY approval input lives on stderr/stdin, never contaminating run stdout.
const std = @import("std");
const Io = std.Io;

pub const Reply = enum { allow_once, allow_session, deny };
pub const Ask = struct {
    id: []const u8,
    action: []const u8,
    pattern: []const u8,
    timeout_ms: u64,
    expires_at: i64,
};

pub fn parse(data: std.json.Value) ?Ask {
    if (data != .object) return null;
    const id = data.object.get("id") orelse return null;
    const action = data.object.get("action") orelse return null;
    const pattern = data.object.get("pattern") orelse return null;
    const timeout = data.object.get("timeoutMs") orelse return null;
    const expires = data.object.get("expiresAt") orelse return null;
    if (id != .string or action != .string or pattern != .string or timeout != .integer or expires != .integer or timeout.integer < 0) return null;
    return .{
        .id = id.string,
        .action = action.string,
        .pattern = pattern.string,
        .timeout_ms = @intCast(timeout.integer),
        .expires_at = expires.integer,
    };
}

pub fn parseReply(raw: []const u8) ?Reply {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return std.meta.stringToEnum(Reply, text);
}

/// EOF, non-TTY, malformed input, read errors, and deadline all deny.
pub fn prompt(io: Io, stderr: *Io.Writer, ask: Ask) !Reply {
    if (!(Io.File.stdin().isTty(io) catch false)) return .deny;
    if (Io.Clock.real.now(io).toMilliseconds() >= ask.expires_at) return .deny;
    try stderr.print("Permission requested: {s} {s}\nReply [allow_once/allow_session/deny]: ", .{ ask.action, ask.pattern });
    try stderr.flush();
    return readBounded(io, Io.File.stdin(), ask.expires_at);
}

fn readLine(file: Io.File, io: Io) Reply {
    var buf: [256]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return .deny;
    return parseReply(line orelse return .deny) orelse .deny;
}

/// Isolated for testing cancellation of a pending stdin read on a pipe.
fn readBounded(io: Io, file: Io.File, expires_at: i64) !Reply {
    const remaining = @max(0, expires_at -| Io.Clock.real.now(io).toMilliseconds());
    if (remaining == 0) return .deny;
    const Done = union(enum) { input: Reply, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.input, readLine, .{ file, io });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(remaining), Io.Clock.awake });
    return switch (try select.await()) {
        .input => |reply| reply,
        .deadline => |result| blk: {
            try result;
            break :blk .deny;
        },
    };
}

test "permission event parsing and strict replies" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"id":"per_1","action":"shell","pattern":"rm *","timeoutMs":120000,"expiresAt":1790000000000}
    , .{});
    try std.testing.expectEqualStrings("rm *", parse(v).?.pattern);
    try std.testing.expectEqual(Reply.allow_session, parseReply("allow_session\r\n").?);
    try std.testing.expect(parseReply("yes") == null);
    try std.testing.expect(parse(.null) == null);
    try std.testing.expectEqual(@as(u64, 120000), parse(v).?.timeout_ms);
}

test "expired prompt does not wait for input" {
    try std.testing.expectEqual(Reply.deny, try readBounded(std.testing.io, Io.File.stdin(), 0));
}

test "unanswered pipe read is cancelled at deadline" {
    const io = std.testing.io;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const input: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const output: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer output.close(io);
    const expires_at = Io.Clock.real.now(io).toMilliseconds() + 20;
    try std.testing.expectEqual(Reply.deny, try readBounded(io, input, expires_at));
}
