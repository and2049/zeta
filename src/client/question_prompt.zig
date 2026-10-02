//! Answering a plugin's question on a terminal (`zeta run`): the question
//! goes to stderr and the answer is read from stdin, never touching stdout.
//! Without a terminal, at EOF, on unreadable input or when time runs out,
//! the question is declined.
const std = @import("std");
const platform = @import("platform");
const questions = @import("questions.zig");
const Question = questions.Question;
const Io = std.Io;
const A = std.mem.Allocator;
const Value = std.json.Value;

pub const Reply = struct {
    action: []const u8,
    content: ?Value = null,

    const decline: Reply = .{ .action = "decline" };
};

pub fn ask(a: A, io: Io, stderr: *Io.Writer, q: Question) !Reply {
    if (!(Io.File.stdin().isTty(io) catch false)) return .decline;
    try stderr.print("\n{s} asks: {s}\n", .{ q.source, q.message });
    switch (q.kind) {
        .confirm => {
            if (q.detail) |d| try stderr.print("  {s}\n", .{d});
            try stderr.writeAll("Allow? [y/N]: ");
            try stderr.flush();
            const line = try readLine(a, io, Io.File.stdin(), q.expiresAt) orelse return .decline;
            return if (questions.yes(std.mem.trim(u8, line, " \t\r"))) .{ .action = "accept" } else .decline;
        },
        .select => {
            for (q.options, 1..) |o, i| try stderr.print("  {d}. {s}{s}{s}\n", .{ i, o.text(), if (o.description.len > 0) " - " else "", o.description });
            try stderr.print("Choose 1-{d} (empty declines): ", .{q.options.len});
            try stderr.flush();
            const line = try readLine(a, io, Io.File.stdin(), q.expiresAt) orelse return .decline;
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, line, " \t\r"), 10) catch return .decline;
            if (n == 0 or n > q.options.len) return .decline;
            return .{ .action = "accept", .content = .{ .string = q.options[n - 1].value } };
        },
        .input => {
            if (q.secret) {
                const secret = platform.terminal.readSecretPrompt(a, io, "> ") catch return .decline;
                return .{ .action = "accept", .content = .{ .string = secret } };
            }
            if (q.placeholder) |p| try stderr.print("  ({s})\n", .{p});
            try stderr.writeAll("> ");
            try stderr.flush();
            const line = try readLine(a, io, Io.File.stdin(), q.expiresAt) orelse return .decline;
            return .{ .action = "accept", .content = .{ .string = std.mem.trimEnd(u8, line, "\r") } };
        },
        .form => {
            var object: std.json.ObjectMap = .empty;
            for (try questions.fields(a, q.schema.?)) |f| {
                while (true) {
                    try stderr.print("{s}{s}", .{ f.label, if (f.required) " *" else "" });
                    if (f.choices.len > 0) {
                        try stderr.writeAll(" (");
                        for (f.choices, 0..) |c, i| try stderr.print("{s}{s}", .{ if (i == 0) "" else "/", c });
                        try stderr.writeAll(")");
                    } else if (f.type == .boolean) try stderr.writeAll(" [y/n]");
                    if (f.description.len > 0) try stderr.print(" - {s}", .{f.description});
                    try stderr.writeAll(": ");
                    try stderr.flush();
                    const line = try readLine(a, io, Io.File.stdin(), q.expiresAt) orelse return .decline;
                    const value = questions.fieldValue(a, f, line) catch {
                        try stderr.writeAll("  not a valid answer\n");
                        continue;
                    };
                    if (value) |v| try object.put(a, f.name, v);
                    break;
                }
            }
            return .{ .action = "accept", .content = .{ .object = object } };
        },
    }
}

/// One line from `file` before `expires_at` (real-clock ms; 0 waits
/// without limit), or null at EOF, on a read error or when time runs out.
fn readLine(a: A, io: Io, file: Io.File, expires_at: i64) !?[]const u8 {
    const remaining = if (expires_at == 0) std.math.maxInt(i64) else expires_at -| Io.Clock.real.now(io).toMilliseconds();
    if (remaining <= 0) return null;
    const Done = union(enum) { input: ?[]const u8, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.input, readOne, .{ a, file, io });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(@min(remaining, 7 * 24 * 3600 * 1000)), Io.Clock.awake });
    return switch (try select.await()) {
        .input => |line| line,
        .deadline => |result| blk: {
            try result;
            break :blk null;
        },
    };
}

fn readOne(a: A, file: Io.File, io: Io) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return null;
    return a.dupe(u8, line orelse return null) catch null;
}

test "an expired question does not wait for input" {
    try std.testing.expect(try readLine(std.testing.allocator, std.testing.io, Io.File.stdin(), 1) == null);
}

test "an unanswered pipe read ends at the deadline" {
    const io = std.testing.io;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const input: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const output: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer output.close(io);
    const expires_at = Io.Clock.real.now(io).toMilliseconds() + 20;
    try std.testing.expect(try readLine(std.testing.allocator, io, input, expires_at) == null);
}
