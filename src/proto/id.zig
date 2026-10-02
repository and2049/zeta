//! Time-sortable, prefixed identifiers.
//!
//! Layout: `<prefix>_` + 12 hex ms timestamp + 4 hex counter + 10 base62 random.
//! The hex part is `ms << 16 | counter` from one process-wide atomic, so IDs
//! sort in creation order even within the same millisecond.
//! We keep the full
//! 48-bit ms and give the counter its own 16 bits.)

const std = @import("std");

pub const Kind = enum {
    session,
    message,
    part,
    event,
    question,

    pub fn prefix(kind: Kind) []const u8 {
        return switch (kind) {
            .session => "ses",
            .message => "msg",
            .part => "prt",
            .event => "evt",
            .question => "que",
        };
    }
};

const hex_len = 16;
const rand_len = 10;
const body_len = hex_len + rand_len;
pub const max_len = 4 + body_len;

const base62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub const Buf = struct {
    bytes: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn slice(b: *const Buf) []const u8 {
        return b.bytes[0..b.len];
    }
};

pub const Generator = struct {
    last: std.atomic.Value(u64) = .init(0),

    pub fn next(g: *Generator, io: std.Io, kind: Kind) Buf {
        const ms: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        var random: [rand_len]u8 = undefined;
        io.random(&random);
        return format(kind, g.advance(ms), random);
    }

    /// Returns a value strictly greater than every earlier one.
    fn advance(g: *Generator, ms: u64) u64 {
        var prev = g.last.load(.monotonic);
        while (true) {
            const candidate = @max(prev + 1, ms << 16);
            prev = g.last.cmpxchgWeak(prev, candidate, .monotonic, .monotonic) orelse
                return candidate;
        }
    }
};

fn format(kind: Kind, value: u64, random: [rand_len]u8) Buf {
    var buf: Buf = .{};
    const p = kind.prefix();
    @memcpy(buf.bytes[0..p.len], p);
    buf.bytes[p.len] = '_';
    const start = p.len + 1;
    _ = std.fmt.bufPrint(buf.bytes[start..][0..hex_len], "{x:0>16}", .{value}) catch unreachable;
    for (random, 0..) |r, i| buf.bytes[start + hex_len + i] = base62[r % base62.len];
    buf.len = @intCast(start + body_len);
    return buf;
}

pub fn hasKind(id: []const u8, kind: Kind) bool {
    const p = kind.prefix();
    return id.len == p.len + 1 + body_len and std.mem.startsWith(u8, id, p) and id[p.len] == '_';
}

test "format layout and timestamp round trip" {
    const random: [rand_len]u8 = @splat(0);
    const buf = format(.session, 1_790_000_000_000 << 16 | 7, random);
    const id = buf.slice();
    try std.testing.expectEqual(@as(usize, 30), id.len);
    try std.testing.expect(hasKind(id, .session));
    try std.testing.expect(!hasKind(id, .message));
    try std.testing.expectEqualStrings("01a0c4506c000007", id[4..20]);
    try std.testing.expectEqualStrings("0007", id[16..20]);
    try std.testing.expectEqualStrings("0000000000", id[20..]);
}

test "ids from one generator sort in creation order" {
    var g: Generator = .{};
    var prev = g.next(std.testing.io, .message);
    for (0..1000) |_| {
        const cur = g.next(std.testing.io, .message);
        try std.testing.expect(std.mem.order(u8, prev.slice()[0..20], cur.slice()[0..20]) == .lt);
        prev = cur;
    }
}

test "advance never goes backwards when the clock does" {
    var g: Generator = .{};
    const a = g.advance(2000);
    const b = g.advance(1000);
    try std.testing.expect(b > a);
}
