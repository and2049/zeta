//! Owning terminal session. Always call deinit (including on error exits).
const std = @import("std");
const Io = std.Io;

pub const Size = struct { columns: u16, rows: u16 };
/// Also pops the window title saved on entry (`CSI 23;0t`).
const restore_screen = "\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?1006l\x1b[?1000l\x1b[?2004l\x1b[?7h\x1b[?1049l\x1b[23;0t";

/// The terminal a live `Terminal` changed, for `restoreOnPanic`. A panic does
/// not run defers, so `deinit` never gets the chance.
var panic_restore: ?struct { input: std.posix.fd_t, output: std.posix.fd_t, original: std.posix.termios } = null;

/// Puts the terminal back from a panic handler: plain syscalls, no Io, no
/// allocation. Safe to call when no Terminal is active.
pub fn restoreOnPanic() void {
    const saved = panic_restore orelse return;
    panic_restore = null;
    _ = std.c.write(saved.output, restore_screen, restore_screen.len);
    std.posix.tcsetattr(saved.input, .FLUSH, saved.original) catch {};
}

pub const Terminal = struct {
    io: Io,
    input: Io.File,
    output: Io.File,
    original: std.posix.termios,
    active: bool = true,
    size: Size,
    /// The terminal's background color, when it answered the query.
    background: ?[3]u8 = null,
    /// Input that arrived while waiting for the query's answer; `read`
    /// returns it first.
    early: [256]u8 = undefined,
    early_len: usize = 0,

    /// Requires a TTY on both stdin and stderr; borrows those handles and io.
    /// Raw mode disables signals and IXON so Ctrl-C/Q arrive as bytes.
    pub fn init(io: Io) !Terminal {
        const input = Io.File.stdin();
        const output = Io.File.stderr();
        if (!try input.isTty(io) or !try output.isTty(io)) return error.NotATerminal;
        const original = try std.posix.tcgetattr(input.handle);
        var raw = original;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(input.handle, .FLUSH, raw);
        errdefer std.posix.tcsetattr(input.handle, .FLUSH, original) catch {};
        // A streaming write can fail after activating the alternate screen.
        errdefer output.writeStreamingAll(io, restore_screen) catch {};
        try output.writeStreamingAll(io, "\x1b[22;0t\x1b[?1049h\x1b[?7l\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[2J\x1b[H\x1b[?25l");
        panic_restore = .{ .input = input.handle, .output = output.handle, .original = original };
        var self: Terminal = .{ .io = io, .input = input, .output = output, .original = original, .size = querySize(output.handle) };
        self.queryBackground() catch {};
        return self;
    }

    /// Asks for the background color (OSC 11), followed by a device
    /// attributes request that every terminal answers, so a terminal that
    /// ignores OSC 11 costs no timeout. Waits at most 300 ms in total.
    fn queryBackground(self: *Terminal) !void {
        try self.output.writeStreamingAll(self.io, "\x1b]11;?\x1b\\\x1b[c");
        var reply: [512]u8 = undefined;
        var len: usize = 0;
        var waited: i32 = 0;
        while (waited < 300 and len < reply.len) : (waited += 50) {
            const n = (try self.read(50, reply[len..])) orelse continue;
            if (n == 0) break;
            len += n;
            if (attributesEnd(reply[0..len])) |end| {
                self.background = parseBackground(reply[0..end]);
                const rest = reply[end..len];
                const keep = @min(rest.len, self.early.len);
                @memcpy(self.early[0..keep], rest[0..keep]);
                self.early_len = keep;
                return;
            }
        }
        self.background = parseBackground(reply[0..len]);
    }

    /// Idempotent; restore terminal even if the final write fails.
    pub fn deinit(self: *Terminal) void {
        if (!self.active) return;
        self.active = false;
        panic_restore = null;
        self.output.writeStreamingAll(self.io, restore_screen) catch {};
        std.posix.tcsetattr(self.input.handle, .FLUSH, self.original) catch {};
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        try self.output.writeStreamingAll(self.io, bytes);
    }

    /// Poll for input at most timeout_ms milliseconds; null means no input.
    /// Poll size() on each tick to detect SIGWINCH without installing a handler.
    pub fn read(self: *Terminal, timeout_ms: i32, buffer: []u8) !?usize {
        if (self.early_len > 0) {
            const n = @min(self.early_len, buffer.len);
            @memcpy(buffer[0..n], self.early[0..n]);
            std.mem.copyForwards(u8, self.early[0 .. self.early_len - n], self.early[n..self.early_len]);
            self.early_len -= n;
            return n;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = self.input.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return null;
        return self.input.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }

    pub fn pollResize(self: *Terminal) ?Size {
        const next = querySize(self.output.handle);
        if (std.meta.eql(next, self.size)) return null;
        self.size = next;
        return next;
    }
};

fn querySize(handle: std.posix.fd_t) Size {
    var ws: std.posix.winsize = undefined;
    // Use the target's request code (Linux and macOS differ).
    if (std.c.ioctl(handle, std.posix.T.IOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0)
        return .{ .columns = ws.col, .rows = ws.row };
    return .{ .columns = 80, .rows = 24 };
}

/// The end of a device attributes reply (`ESC [ ? … c`), if present.
fn attributesEnd(bytes: []const u8) ?usize {
    const start = std.mem.indexOf(u8, bytes, "\x1b[?") orelse return null;
    for (bytes[start + 3 ..], start + 3..) |b, i| {
        if (b == 'c') return i + 1;
        if (!std.ascii.isDigit(b) and b != ';') return null;
    }
    return null;
}

/// Reads `ESC ] 11 ; rgb:R/G/B` with 1-4 hex digits per channel.
fn parseBackground(bytes: []const u8) ?[3]u8 {
    const start = std.mem.indexOf(u8, bytes, "\x1b]11;rgb:") orelse return null;
    var rest = bytes[start + "\x1b]11;rgb:".len ..];
    var color: [3]u8 = undefined;
    for (&color, 0..) |*channel, i| {
        const end = std.mem.indexOfNone(u8, rest, "0123456789abcdefABCDEF") orelse rest.len;
        if (end == 0 or end > 4) return null;
        const value = std.fmt.parseInt(u16, rest[0..end], 16) catch return null;
        const max: u32 = (@as(u32, 1) << @intCast(4 * end)) - 1;
        channel.* = @intCast(@as(u32, value) * 255 / max);
        if (i < 2) {
            if (end >= rest.len or rest[end] != '/') return null;
            rest = rest[end + 1 ..];
        }
    }
    return color;
}

test "background reply parses with any digit count" {
    try std.testing.expectEqual([3]u8{ 0x28, 0x2c, 0x34 }, parseBackground("\x1b]11;rgb:2828/2c2c/3434\x1b\\\x1b[?62;c").?);
    try std.testing.expectEqual([3]u8{ 255, 0, 17 }, parseBackground("\x1b]11;rgb:f/0/11\x07").?);
    try std.testing.expect(parseBackground("\x1b[?62;c") == null);
    try std.testing.expectEqual(@as(?usize, 7), attributesEnd("\x1b[?62;cxy"));
}

test "invalid descriptor dimensions use fallback" {
    try std.testing.expectEqual(Size{ .columns = 80, .rows = 24 }, querySize(-1));
}
