//! Wildcard matching for names and patterns in config (MCP tool filters,
//! hook matchers).
const std = @import("std");

/// '*' matches zero or more bytes and '?' exactly one character; every other
/// byte is literal. A trailing " *" may also match nothing, so `git *`
/// matches both `git` and `git status`.
pub fn match(pattern: []const u8, text: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, " *") and std.mem.eql(u8, text, pattern[0 .. pattern.len - 2])) return true;
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '?') {
            p += 1;
            t += charLen(text, t);
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = t;
        } else if (star) |s| {
            retry += 1;
            t = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

/// Byte length of the UTF-8 character at `i`; invalid bytes count as one.
fn charLen(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    if (i + n > text.len) return 1;
    _ = std.unicode.utf8Decode(text[i .. i + n]) catch return 1;
    return n;
}

test "star and question mark" {
    try std.testing.expect(match("a*b*c", "axbyc"));
    try std.testing.expect(!match("a*b", "abx"));
    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(match("a?c", "a\u{e9}c"));
    try std.testing.expect(!match("a?c", "ac"));
    try std.testing.expect(!match("a?c", "abbc"));
    try std.testing.expect(match("*.?s", "src/main.ts"));
    try std.testing.expect(match("git *", "git"));
    try std.testing.expect(match("git *", "git status"));
    try std.testing.expect(!match("git *", "gitk"));
    try std.testing.expect(!match("git*x", "git"));
}
