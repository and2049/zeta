//! Server-sent events: frame encoding and an incremental decoder.
//! Used for the server's `/event` feed and for provider streams.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Writes one frame. `data` may contain newlines; each line becomes a `data:` field.
pub fn writeFrame(w: *std.Io.Writer, event: ?[]const u8, data: []const u8) std.Io.Writer.Error!void {
    if (event) |e| try w.print("event: {s}\n", .{e});
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| try w.print("data: {s}\n", .{line});
    try w.writeByte('\n');
}

pub fn writeComment(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.print(": {s}\n\n", .{text});
}

pub const Event = struct {
    event: []const u8,
    data: []const u8,
};

/// Reads frames from a stream. Returned slices are valid until the next call.
/// Lines are assembled independently of the reader's buffer size; a frame
/// whose data (or a single line) exceeds `max_data` fails with
/// `error.FrameTooLarge`.
pub const Decoder = struct {
    gpa: Allocator,
    event: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    max_data: usize = 16 * 1024 * 1024,

    pub fn init(gpa: Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Decoder) void {
        d.event.deinit(d.gpa);
        d.data.deinit(d.gpa);
        d.line.deinit(d.gpa);
    }

    pub const Error = error{ ReadFailed, StreamTooLong, OutOfMemory, FrameTooLarge };

    /// Returns null at end of stream. A trailing frame without a blank line is
    /// still delivered.
    pub fn next(d: *Decoder, r: *std.Io.Reader) Error!?Event {
        d.event.clearRetainingCapacity();
        d.data.clearRetainingCapacity();
        var has_data = false;
        while (try d.readLine(r)) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) {
                if (has_data) return d.current();
                d.event.clearRetainingCapacity();
                continue;
            }
            if (line[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':');
            const field = if (colon) |c| line[0..c] else line;
            var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') value = value[1..];

            if (std.mem.eql(u8, field, "data")) {
                if (has_data) try d.data.append(d.gpa, '\n');
                if (d.data.items.len + value.len > d.max_data) return error.FrameTooLarge;
                try d.data.appendSlice(d.gpa, value);
                has_data = true;
            } else if (std.mem.eql(u8, field, "event")) {
                d.event.clearRetainingCapacity();
                try d.event.appendSlice(d.gpa, value);
            }
        }
        return if (has_data) d.current() else null;
    }

    /// Returns the next line without its `\n`, or null at end of stream. A
    /// final unterminated line is still returned.
    fn readLine(d: *Decoder, r: *std.Io.Reader) Error!?[]const u8 {
        d.line.clearRetainingCapacity();
        // Field name, colon, and space on top of the data limit.
        const max_line = d.max_data + 64;
        while (true) {
            const buffered = r.buffered();
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |i| {
                if (d.line.items.len + i > max_line) return error.FrameTooLarge;
                try d.line.appendSlice(d.gpa, buffered[0..i]);
                r.toss(i + 1);
                return d.line.items;
            }
            if (d.line.items.len + buffered.len > max_line) return error.FrameTooLarge;
            try d.line.appendSlice(d.gpa, buffered);
            r.toss(buffered.len);
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return if (d.line.items.len > 0) d.line.items else null,
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    fn current(d: *Decoder) Event {
        return .{ .event = d.event.items, .data = d.data.items };
    }
};

test "round trip through writer and decoder" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeFrame(&out.writer, "message.part.delta", "{\"a\":1}");
    try writeComment(&out.writer, "heartbeat");
    try writeFrame(&out.writer, null, "line1\nline2");

    var r: std.Io.Reader = .fixed(out.written());
    var d: Decoder = .init(std.testing.allocator);
    defer d.deinit();

    const a = (try d.next(&r)).?;
    try std.testing.expectEqualStrings("message.part.delta", a.event);
    try std.testing.expectEqualStrings("{\"a\":1}", a.data);
    const b = (try d.next(&r)).?;
    try std.testing.expectEqualStrings("", b.event);
    try std.testing.expectEqualStrings("line1\nline2", b.data);
    try std.testing.expectEqual(@as(?Event, null), try d.next(&r));
}

test "lines longer than the reader buffer" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'x');
    const input = try std.fmt.allocPrint(allocator, "event: big\ndata: {s}\n\ndata: next\n\n", .{payload});
    defer allocator.free(input);

    // Deliver the input through a reader whose buffer is far smaller than a line.
    var source: std.Io.Reader = .fixed(input);
    var small: [256]u8 = undefined;
    var limited = source.limited(.unlimited, &small);
    var d: Decoder = .init(allocator);
    defer d.deinit();
    const a = (try d.next(&limited.interface)).?;
    try std.testing.expectEqualStrings("big", a.event);
    try std.testing.expectEqualSlices(u8, payload, a.data);
    try std.testing.expectEqualStrings("next", (try d.next(&limited.interface)).?.data);
    try std.testing.expectEqual(@as(?Event, null), try d.next(&limited.interface));

    var again: std.Io.Reader = .fixed(input);
    var capped: Decoder = .init(allocator);
    defer capped.deinit();
    capped.max_data = 1024;
    try std.testing.expectError(error.FrameTooLarge, capped.next(&again));
}

test "openai style stream with CRLF and no trailing blank line" {
    const input = "data: {\"x\":1}\r\n\r\n: ping\r\n\r\ndata:[DONE]";
    var r: std.Io.Reader = .fixed(input);
    var d: Decoder = .init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expectEqualStrings("{\"x\":1}", (try d.next(&r)).?.data);
    try std.testing.expectEqualStrings("[DONE]", (try d.next(&r)).?.data);
    try std.testing.expectEqual(@as(?Event, null), try d.next(&r));
}
