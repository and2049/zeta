//! Web addresses in text: finding bare ones and deciding what may be
//! opened. Only `http://` and `https://` made of printable ASCII count, so
//! an address can go into a terminal sequence or a command line as it is.
const std = @import("std");

pub const Found = struct { start: usize, end: usize };

const schemes = [_][]const u8{ "https://", "http://" };

/// The next address in `text` at or after `from`. Punctuation that ends a
/// sentence or closes a bracket opened before the address is left out.
pub fn next(text: []const u8, from: usize) ?Found {
    var at = from;
    while (std.mem.indexOfPos(u8, text, at, "http")) |start| : (at = start + 1) {
        const scheme = for (schemes) |s| {
            if (std.mem.startsWith(u8, text[start..], s)) break s;
        } else continue;
        if (start > 0 and std.ascii.isAlphanumeric(text[start - 1])) continue;
        var end = start + scheme.len;
        while (end < text.len and part(text[end])) end += 1;
        while (end > start + scheme.len) {
            const last = text[end - 1];
            const opener: u8 = switch (last) {
                '.', ',', ';', ':', '!', '?', '\'', '*', '_', '~' => 0,
                ')' => '(',
                ']' => '[',
                '}' => '{',
                else => break,
            };
            // A closing bracket belongs to the address when it opened there.
            if (opener != 0 and std.mem.count(u8, text[start..end], &.{opener}) >= std.mem.count(u8, text[start..end], &.{last})) break;
            end -= 1;
        }
        if (end == start + scheme.len) continue;
        return .{ .start = start, .end = end };
    }
    return null;
}

fn part(byte: u8) bool {
    return byte > ' ' and byte < 0x7f and byte != '<' and byte != '>' and byte != '"' and byte != '`';
}

/// Whether `url` is one this client opens: a whole http(s) address.
pub fn openable(url: []const u8) bool {
    if (url.len > 2048) return false;
    const scheme = for (schemes) |s| {
        if (std.mem.startsWith(u8, url, s)) break s;
    } else return false;
    if (url.len == scheme.len) return false;
    for (url) |byte| if (byte <= ' ' or byte >= 0x7f) return false;
    return true;
}

/// The host of an address, for messages.
pub fn host(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const end = std.mem.indexOfAnyPos(u8, url, start, "/?#") orelse url.len;
    return url[start..end];
}

fn expectLinks(text: []const u8, want: []const []const u8) !void {
    var at: usize = 0;
    for (want) |url| {
        const found = next(text, at) orelse return error.TestExpectedLink;
        try std.testing.expectEqualStrings(url, text[found.start..found.end]);
        at = found.end;
    }
    try std.testing.expect(next(text, at) == null);
}

test "bare addresses end before sentence punctuation and unmatched brackets" {
    try expectLinks("see https://a.test/x. Then (http://b.test/y_(z)), ok", &.{ "https://a.test/x", "http://b.test/y_(z)" });
    try expectLinks("**https://a.test/p?q=1&r=2#f** <https://b.test> `https://c.test/`", &.{ "https://a.test/p?q=1&r=2#f", "https://b.test", "https://c.test/" });
    try expectLinks("xhttps://no.test https:// http:/x ftp://f.test shttp://no", &.{});
    try expectLinks("https://a.test/é", &.{"https://a.test/"});
    try expectLinks("[https://a.test/x]", &.{"https://a.test/x"});
}

test "only whole http and https addresses in printable ASCII open" {
    try std.testing.expect(openable("https://example.test/a?b=c"));
    try std.testing.expect(openable("http://localhost:8080"));
    try std.testing.expect(!openable("https://"));
    try std.testing.expect(!openable("file:///etc/passwd"));
    try std.testing.expect(!openable("javascript:alert(1)"));
    try std.testing.expect(!openable("https://a.test/\x1b]8;;evil"));
    try std.testing.expect(!openable("https://a.test/ b"));
    try std.testing.expectEqualStrings("example.test:8080", host("https://example.test:8080/a/b"));
    try std.testing.expectEqualStrings("example.test", host("http://example.test?x"));
}
