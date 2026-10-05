//! Incremental byte decoder. Events are values except paste, whose bytes the
//! caller owns and frees with the allocator passed to Parser.init.
const std = @import("std");

pub const Key = enum {
    escape,
    enter,
    newline,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    word_left,
    word_right,
    word_backspace,
    word_delete,
    clear,
    tab,
    queue,
    page_up,
    page_down,
    follow_end,
};
/// A button press, a move with the button held, or its release, at a
/// zero-based cell.
pub const Mouse = struct {
    kind: enum { press, drag, release },
    button: enum { left, middle, right },
    x: u16,
    y: u16,
};
pub const Event = union(enum) {
    text: u21,
    key: Key,
    /// Ctrl plus a letter (lowercase) the editor does not use; keybindings
    /// decide what it does.
    ctrl: u8,
    paste: []u8,
    wheel: i8, // -1 up, +1 down
    mouse: Mouse,
    ignored,

    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .paste => |bytes| allocator.free(bytes),
            else => {},
        }
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    pasting: bool = false,
    paste: std.ArrayList(u8) = .empty,
    pub const max_paste = 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.allocator);
        self.paste.deinit(self.allocator);
    }
    pub fn feed(self: *Parser, bytes: []const u8) !void {
        // Bound unparsed sequences, even if input is malicious.
        if (self.pending.items.len + bytes.len > max_paste + 64) return error.InputTooLarge;
        try self.pending.appendSlice(self.allocator, bytes);
    }
    fn consume(self: *Parser, n: usize) void {
        const items = self.pending.items;
        std.mem.copyForwards(u8, items[0 .. items.len - n], items[n..]);
        self.pending.items.len -= n;
    }
    /// Call repeatedly until null after each feed. An isolated ESC is
    /// ambiguous; call flushEscape after a short idle timeout (e.g. 30 ms).
    pub fn next(self: *Parser) !?Event {
        const bytes = self.pending.items;
        if (bytes.len == 0) return null;
        if (self.pasting) {
            const end = std.mem.indexOf(u8, bytes, "\x1b[201~");
            const keep = if (end == null) @min(bytes.len, 5) else 0;
            const take = end orelse bytes.len - keep;
            if (self.paste.items.len + take > max_paste) return error.InputTooLarge;
            try self.paste.appendSlice(self.allocator, bytes[0..take]);
            self.consume(take + if (end != null) @as(usize, 6) else 0);
            if (end == null) return null;
            self.pasting = false;
            const result = try self.allocator.dupe(u8, self.paste.items);
            self.paste.clearRetainingCapacity();
            return .{ .paste = result };
        }
        if (bytes[0] == 27) {
            if (bytes.len == 1) return null;
            if (bytes[1] == '[') {
                const final = for (bytes[2..], 2..) |b, i| {
                    if (b >= 0x40 and b <= 0x7e) break i;
                    if (i >= 63) {
                        self.consume(i + 1);
                        return .ignored;
                    }
                } else return null;
                var seq_buf: [64]u8 = undefined;
                const seq = seq_buf[0 .. final - 1];
                @memcpy(seq, bytes[2 .. final + 1]);
                self.consume(final + 1);
                if (std.mem.eql(u8, seq, "200~")) {
                    self.pasting = true;
                    return self.next();
                }
                if (std.mem.startsWith(u8, seq, "<") and (seq[seq.len - 1] == 'M' or seq[seq.len - 1] == 'm')) return mouse(seq);
                if (seq[seq.len - 1] == 'u' or std.mem.startsWith(u8, seq, "27;")) return modifiedKey(seq);
                if (std.mem.eql(u8, seq, "5~")) return .{ .key = .page_up };
                if (std.mem.eql(u8, seq, "6~")) return .{ .key = .page_down };
                if (std.mem.eql(u8, seq, "F") or std.mem.eql(u8, seq, "4~")) return .{ .key = .follow_end };
                const key: Key = if (std.mem.eql(u8, seq, "A")) .up else if (std.mem.eql(u8, seq, "B")) .down else if (std.mem.eql(u8, seq, "C")) .right else if (std.mem.eql(u8, seq, "D")) .left else if (std.mem.eql(u8, seq, "H") or std.mem.eql(u8, seq, "1~")) .home else if (std.mem.eql(u8, seq, "F") or std.mem.eql(u8, seq, "4~")) .end else if (std.mem.eql(u8, seq, "3~")) .delete else if (std.mem.eql(u8, seq, "1;5D")) .word_left else if (std.mem.eql(u8, seq, "1;5C")) .word_right else return .ignored;
                return .{ .key = key };
            }
            if (bytes[1] == 'O') {
                if (bytes.len < 3) return null;
                const key: Key = switch (bytes[2]) {
                    'H' => .home,
                    'F' => .follow_end,
                    else => .escape,
                };
                self.consume(3);
                return .{ .key = key };
            }
            if (bytes[1] == '\r' or bytes[1] == '\n') {
                self.consume(2);
                return .{ .key = .queue };
            }
            // Alt+printable is ignored rather than submitting accidentally.
            self.consume(2);
            return .ignored;
        }
        if (control(bytes[0])) |event| {
            self.consume(1);
            return event;
        }
        if (bytes[0] < 32 or bytes[0] == 0x7f) {
            self.consume(1);
            return .ignored;
        }
        const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch {
            self.consume(1);
            return .ignored;
        };
        if (bytes.len < len) return null;
        const cp = std.unicode.utf8Decode(bytes[0..len]) catch {
            self.consume(1);
            return .ignored;
        };
        self.consume(len);
        return .{ .text = cp };
    }
    pub fn flushEscape(self: *Parser) ?Event {
        if (self.pending.items.len == 1 and self.pending.items[0] == 27) {
            self.consume(1);
            return .{ .key = .escape };
        }
        return null;
    }
};

/// A control byte: an editor key, or a Ctrl+letter chord for keybindings.
fn control(byte: u8) ?Event {
    if (controlKey(byte)) |k| return .{ .key = k };
    if (byte >= 1 and byte <= 26) return .{ .ctrl = 'a' + byte - 1 };
    return null;
}

fn controlKey(byte: u8) ?Key {
    return switch (byte) {
        3, 21 => .clear,
        10 => .newline,
        13 => .enter,
        8, 127 => .backspace,
        4 => .delete,
        23 => .word_backspace,
        9 => .tab,
        1 => .home,
        5 => .end,
        11 => .word_delete,
        else => null,
    };
}

/// An SGR mouse report, `< code ; column ; row` then `M` (press, move) or
/// `m` (release). The code's low bits are the button, 32 marks a move and
/// 64 the wheel; the modifier bits (4, 8, 16) are dropped.
fn mouse(seq: []const u8) Event {
    var parts = std.mem.splitScalar(u8, seq[1 .. seq.len - 1], ';');
    const code = (std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .ignored) & ~@as(u16, 28);
    const column = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .ignored;
    const row = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return .ignored;
    const pressed = seq[seq.len - 1] == 'M';
    if (code & 64 != 0) {
        if (!pressed) return .ignored;
        return if (code == 64) .{ .wheel = -1 } else if (code == 65) .{ .wheel = 1 } else .ignored;
    }
    if (column == 0 or row == 0 or code & 3 == 3) return .ignored;
    return .{ .mouse = .{
        .kind = if (!pressed) .release else if (code & 32 != 0) .drag else .press,
        .button = switch (code & 3) {
            0 => .left,
            1 => .middle,
            else => .right,
        },
        .x = column - 1,
        .y = row - 1,
    } };
}

const shift = 1;
const alt = 2;
const ctrl = 4;

/// Decodes keys with modifiers reported as `CSI code[:shifted] [; mods[:event]] u`
/// (the fixterms/kitty form) or `CSI 27 ; mods ; code ~` (xterm
/// modifyOtherKeys). Modifiers are sent as 1 + a bit set; only shift, alt
/// and ctrl are considered, and key releases are ignored.
fn modifiedKey(seq: []const u8) Event {
    const legacy = seq[seq.len - 1] == '~';
    var fields = std.mem.splitScalar(u8, seq[0 .. seq.len - 1], ';');
    if (legacy) _ = fields.next(); // "27"
    const first = fields.next() orelse return .ignored;
    const second = fields.next();
    const key_field = if (legacy) second orelse return .ignored else first;
    const mods_field = if (legacy) first else second orelse "1";

    var key_parts = std.mem.splitScalar(u8, key_field, ':');
    const code = std.fmt.parseInt(u21, key_parts.next().?, 10) catch return .ignored;
    const shifted = std.fmt.parseInt(u21, key_parts.next() orelse "", 10) catch null;
    var mod_parts = std.mem.splitScalar(u8, mods_field, ':');
    const raw = std.fmt.parseInt(u8, mod_parts.next().?, 10) catch return .ignored;
    if (std.mem.eql(u8, mod_parts.next() orelse "1", "3")) return .ignored;
    if (raw == 0) return .ignored;
    const mods = (raw - 1) & (shift | alt | ctrl);

    return switch (code) {
        13 => switch (mods) {
            0 => .{ .key = .enter },
            shift => .{ .key = .newline },
            alt => .{ .key = .queue },
            else => .ignored,
        },
        9 => if (mods == 0) .{ .key = .tab } else .ignored,
        27 => if (mods == 0) .{ .key = .escape } else .ignored,
        127, 8 => switch (mods) {
            0 => .{ .key = .backspace },
            alt, ctrl => .{ .key = .word_backspace },
            else => .ignored,
        },
        else => if (mods == ctrl and code >= 'a' and code <= 'z')
            control(@intCast(code & 0x1f)) orelse .ignored
        else if (mods == 0 or mods == shift)
            printable(if (mods == shift) shifted orelse upper(code) else code)
        else
            .ignored,
    };
}

fn upper(code: u21) u21 {
    return if (code >= 'a' and code <= 'z') code - 32 else code;
}

fn printable(code: u21) Event {
    if (code < 32 or code == 127 or !std.unicode.utf8ValidCodepoint(code)) return .ignored;
    return .{ .text = code };
}

test "fragmented UTF-8, escape, bracket paste, wheel and controls" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("\xe7\x95");
    try std.testing.expect((try p.next()) == null);
    try p.feed("\x8c\x1b[1;5D\x1b[200~a\x1b[20");
    try std.testing.expectEqual(@as(u21, '界'), (try p.next()).?.text);
    try std.testing.expectEqual(Key.word_left, (try p.next()).?.key);
    try std.testing.expect((try p.next()) == null);
    try p.feed("1~\x1b[<64;9;2M\x11\x03");
    const paste = (try p.next()).?;
    defer paste.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", paste.paste);
    try std.testing.expectEqual(@as(i8, -1), (try p.next()).?.wheel);
    try std.testing.expectEqual(@as(u8, 'q'), (try p.next()).?.ctrl);
    try std.testing.expectEqual(Key.clear, (try p.next()).?.key);
    try p.feed("\x1b\r\x1b[13;2u\x1b[13;3u\x1b");
    try std.testing.expectEqual(Key.queue, (try p.next()).?.key);
    try std.testing.expectEqual(Key.newline, (try p.next()).?.key);
    try std.testing.expectEqual(Key.queue, (try p.next()).?.key);
    try std.testing.expectEqual(Key.escape, p.flushEscape().?.key);
}

test "mouse press, drag and release decode with zero-based cells" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("\x1b[<0;5;3M\x1b[<32;9;3M\x1b[<0;9;3m\x1b[<2;1;1M\x1b[<68;1;1M\x1b[<35;4;4M");
    for ([_]Event{
        .{ .mouse = .{ .kind = .press, .button = .left, .x = 4, .y = 2 } },
        .{ .mouse = .{ .kind = .drag, .button = .left, .x = 8, .y = 2 } },
        .{ .mouse = .{ .kind = .release, .button = .left, .x = 8, .y = 2 } },
        .{ .mouse = .{ .kind = .press, .button = .right, .x = 0, .y = 0 } },
        .{ .wheel = -1 }, // with shift held
        .ignored, // a move with no button
    }) |want| try std.testing.expectEqual(want, (try p.next()).?);
}

test "modified keys in CSI u and modifyOtherKeys form" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("\x1b[13u\x1b[13;1u\x1b[27;2;13~\x1b[27;3;13~\x1b[13;2:3u\x1b[13;5u" ++
        "\x1b[9u\x1b[27u\x1b[127;3u\x1b[127;5u\x1b[99;5u\x1b[27;5;113~\x1b[97;2u\x1b[97:65;2u\x1b[233u\x1b[97;3u\x1b[99999999;2u");
    const expected = [_]Event{
        .{ .key = .enter },
        .{ .key = .enter },
        .{ .key = .newline },
        .{ .key = .queue },
        .ignored, // release
        .ignored, // ctrl+enter has no binding
        .{ .key = .tab },
        .{ .key = .escape },
        .{ .key = .word_backspace },
        .{ .key = .word_backspace },
        .{ .key = .clear },
        .{ .ctrl = 'q' },
        .{ .text = 'A' },
        .{ .text = 'A' },
        .{ .text = 0xe9 },
        .ignored, // alt+printable
        .ignored, // malformed
    };
    for (expected) |want| try std.testing.expectEqual(want, (try p.next()).?);
    try std.testing.expect((try p.next()) == null);
}

test "navigation and toggles decode without intercepting pasted control bytes" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("\x1b[5~\x1b[6~\x1b[F\x0c\x0f\x14\x1b[200~a\x0cb\x1b[201~");
    for ([_]Event{ .{ .key = .page_up }, .{ .key = .page_down }, .{ .key = .follow_end }, .{ .ctrl = 'l' }, .{ .ctrl = 'o' }, .{ .ctrl = 't' } }) |expected| {
        try std.testing.expectEqual(expected, (try p.next()).?);
    }
    const paste = (try p.next()).?;
    defer paste.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\x0cb", paste.paste);
}
