//! Local wall-clock time for display ("11:00 AM", "Sep 30"), from the
//! system time zone file; UTC when it cannot be read.
const std = @import("std");

pub const Clock = struct {
    /// UTC offsets in seconds that start at each `starts` time (seconds),
    /// ascending. Empty: UTC.
    starts: []const i64 = &.{},
    offsets: []const i32 = &.{},

    /// Reads `/etc/localtime`. Allocations go to `arena`.
    pub fn load(arena: std.mem.Allocator, io: std.Io) Clock {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, "/etc/localtime", arena, .limited(1 << 20)) catch return .{};
        return parse(arena, bytes) catch .{};
    }

    fn parse(arena: std.mem.Allocator, bytes: []const u8) !Clock {
        var reader: std.Io.Reader = .fixed(bytes);
        const tz = try std.tz.Tz.parse(arena, &reader);
        if (tz.transitions.len == 0) {
            if (tz.timetypes.len == 0) return .{};
            return .{ .starts = try arena.dupe(i64, &.{std.math.minInt(i64)}), .offsets = try arena.dupe(i32, &.{tz.timetypes[0].offset}) };
        }
        const starts = try arena.alloc(i64, tz.transitions.len + 1);
        const offsets = try arena.alloc(i32, tz.transitions.len + 1);
        // Before the first transition: the first standard time type.
        starts[0] = std.math.minInt(i64);
        offsets[0] = tz.timetypes[0].offset;
        for (tz.transitions, starts[1..], offsets[1..]) |t, *s, *o| {
            s.* = t.ts;
            o.* = t.timetype.offset;
        }
        return .{ .starts = starts, .offsets = offsets };
    }

    /// Seconds east of UTC at `seconds` since the epoch.
    pub fn offset(c: Clock, seconds: i64) i64 {
        var result: i32 = 0;
        for (c.starts, c.offsets) |start, o| {
            if (start > seconds) break;
            result = o;
        }
        return result;
    }

    /// `11:05 AM` for epoch milliseconds `ms`.
    pub fn time(c: Clock, buf: []u8, ms: i64) []const u8 {
        const local = @divFloor(ms, 1000) + c.offset(@divFloor(ms, 1000));
        const minutes: u64 = @intCast(@mod(@divFloor(local, 60), 24 * 60));
        const hour = minutes / 60;
        const twelve = if (hour % 12 == 0) 12 else hour % 12;
        return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ twelve, minutes % 60, if (hour < 12) "AM" else "PM" }) catch "";
    }

    /// `Sep 30 11:05 AM` for epoch milliseconds `ms`.
    pub fn dateTime(c: Clock, buf: []u8, ms: i64) []const u8 {
        const local = @divFloor(ms, 1000) + c.offset(@divFloor(ms, 1000));
        const day = std.time.epoch.EpochDay{ .day = @intCast(@max(0, @divFloor(local, 86400))) };
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var clock_buf: [16]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s} {d} {s}", .{ names[month_day.month.numeric() - 1], month_day.day_index + 1, c.time(&clock_buf, ms) }) catch "";
    }
};

/// `4m 24s`, `12s`, `1h 3m` for a duration in milliseconds.
pub fn duration(buf: []u8, ms: i64) []const u8 {
    const s: u64 = @intCast(@divFloor(@max(ms, 0), 1000));
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ s / 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ s / 3600, s / 60 % 60 }) catch "";
}

test "times, dates and durations" {
    var buf: [32]u8 = undefined;
    const utc: Clock = .{};
    // 2026-09-30 11:05:00 UTC.
    const ms: i64 = 1790766300 * 1000;
    try std.testing.expectEqualStrings("11:05 AM", utc.time(&buf, ms));
    try std.testing.expectEqualStrings("Sep 30 11:05 AM", utc.dateTime(&buf, ms));
    const pacific: Clock = .{ .starts = &.{std.math.minInt(i64)}, .offsets = &.{-7 * 3600} };
    try std.testing.expectEqualStrings("4:05 AM", pacific.time(&buf, ms));
    try std.testing.expectEqualStrings("12:00 PM", utc.time(&buf, 12 * 3600 * 1000));
    try std.testing.expectEqualStrings("4m 24s", duration(&buf, 264_000));
    try std.testing.expectEqualStrings("12s", duration(&buf, 12_400));
    try std.testing.expectEqualStrings("1h 3m", duration(&buf, 3_780_000));
}
