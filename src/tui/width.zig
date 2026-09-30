//! Approximate terminal grapheme widths for common emoji, modifiers, flags,
//! ZWJ and combining sequences. No locale-dependent libc wcwidth required.
const std = @import("std");

pub const Rune = struct { bytes: []const u8, columns: u2 };

pub fn columns(cp: u21) u2 {
    if (cp == 0 or cp < 32 or cp == 0x7f or cp >= 0x80 and cp < 0xa0) return 0;
    if (isExtend(cp) or cp == 0x200d) return 0;
    if (cp >= 0x1100 and (cp <= 0x115f or cp == 0x2329 or cp == 0x232a or
        cp >= 0x2e80 and cp <= 0xa4cf or cp >= 0xac00 and cp <= 0xd7a3 or
        cp >= 0xf900 and cp <= 0xfaff or cp >= 0xfe10 and cp <= 0xfe19 or
        cp >= 0xfe30 and cp <= 0xfe6f or cp >= 0xff00 and cp <= 0xff60 or
        cp >= 0xffe0 and cp <= 0xffe6 or cp >= 0x1f1e6 and cp <= 0x1f1ff or
        cp >= 0x1f300 and cp <= 0x1faff or cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn isExtend(cp: u21) bool {
    return cp >= 0x300 and cp <= 0x36f or cp >= 0x1ab0 and cp <= 0x1aff or
        cp >= 0x1dc0 and cp <= 0x1dff or cp >= 0x20d0 and cp <= 0x20ff or
        cp >= 0xfe00 and cp <= 0xfe0f or cp >= 0xfe20 and cp <= 0xfe2f or
        cp >= 0xe0100 and cp <= 0xe01ef;
}
fn isModifier(cp: u21) bool {
    return cp >= 0x1f3fb and cp <= 0x1f3ff;
}
fn isRegional(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}
fn codepoint(text: []const u8, at: usize) ?struct { cp: u21, end: usize } {
    if (at >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return null;
    if (at + len > text.len) return null;
    return .{ .cp = std.unicode.utf8Decode(text[at .. at + len]) catch return null, .end = at + len };
}

/// Next boundary of a valid UTF-8 grapheme-like cluster. CR/LF are separate.
/// Extended Unicode segmentation (Indic conjuncts, tags) is not attempted.
pub fn clusterEnd(text: []const u8, start: usize) usize {
    const first = codepoint(text, start) orelse return @min(start + 1, text.len);
    var end = first.end;
    if (first.cp == '\n' or first.cp == '\r') return end;
    var last = first.cp;
    var regionals: u8 = if (isRegional(first.cp)) 1 else 0;
    while (codepoint(text, end)) |next| {
        if (next.cp == '\n' or next.cp == '\r') break;
        if (isExtend(next.cp) or isModifier(next.cp) or next.cp == 0x200d or
            last == 0x200d or isRegional(last) and isRegional(next.cp) and regionals == 1)
        {
            end = next.end;
            last = next.cp;
            if (isRegional(next.cp)) regionals += 1;
        } else break;
    }
    return end;
}

fn clusterWidth(text: []const u8) u2 {
    var at: usize = 0;
    var result: u2 = 0;
    while (codepoint(text, at)) |r| {
        result = @max(result, columns(r.cp));
        if (r.cp == 0xfe0f or r.cp == 0x20e3) result = 2;
        at = r.end;
    }
    return result;
}

/// Never exposes control/ANSI bytes as printable content. Invalid sequences
/// consume one byte and yield replacement glyph; C1 controls are discarded.
pub const Iterator = struct {
    input: []const u8,
    index: usize = 0,
    pub fn next(self: *Iterator) ?Rune {
        while (self.index < self.input.len) {
            const start = self.index;
            const b = self.input[start];
            self.index += 1;
            if (b == 27) {
                if (self.index < self.input.len and self.input[self.index] == '[') {
                    self.index += 1;
                    while (self.index < self.input.len) : (self.index += 1) {
                        if (self.input[self.index] >= 0x40 and self.input[self.index] <= 0x7e) {
                            self.index += 1;
                            break;
                        }
                    }
                } else if (self.index < self.input.len and self.input[self.index] == ']') {
                    self.index += 1;
                    while (self.index < self.input.len) : (self.index += 1) {
                        if (self.input[self.index] == 7) {
                            self.index += 1;
                            break;
                        }
                        if (self.input[self.index] == 27 and self.index + 1 < self.input.len and self.input[self.index + 1] == '\\') {
                            self.index += 2;
                            break;
                        }
                    }
                }
                continue;
            }
            if (b < 32 or b == 127) continue;
            const first = codepoint(self.input, start) orelse return .{ .bytes = "�", .columns = 1 };
            if (first.cp >= 0x80 and first.cp < 0xa0) {
                self.index = first.end;
                continue;
            }
            const end = clusterEnd(self.input, start);
            self.index = end;
            return .{ .bytes = self.input[start..end], .columns = clusterWidth(self.input[start..end]) };
        }
        return null;
    }
};

pub fn displayWidth(text: []const u8) usize {
    var it: Iterator = .{ .input = text };
    var n: usize = 0;
    while (it.next()) |r| n += r.columns;
    return n;
}

test "clusters, ANSI and C1 filtering" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a界e\xcc\x81🙂\x1b[31m\x03"));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xff"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👩🏽‍💻"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🇺🇸"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("❤️"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("1️⃣"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("a\xc2\x9b界"));
    var it: Iterator = .{ .input = "x\xc2\x9by" };
    try std.testing.expectEqualStrings("x", it.next().?.bytes);
    try std.testing.expectEqualStrings("y", it.next().?.bytes);
}
