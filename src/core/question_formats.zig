//! The string formats elicitation forms may ask for: email, uri, date,
//! date-time.
const std = @import("std");

/// The string formats forms may ask for: email, uri, date, date-time.
pub fn fits(format: []const u8, text: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, format, "email")) return email(text);
    if (eql(u8, format, "uri")) return uri(text);
    if (eql(u8, format, "date")) return date(text);
    if (eql(u8, format, "date-time")) return dateTime(text);
    return true;
}

/// An absolute URI (RFC 3986): a scheme; only characters a URI may hold,
/// with well-formed `%XX` escapes; brackets only around a host; at most
/// one `#`.
fn uri(text: []const u8) bool {
    const parsed = std.Uri.parse(text) catch return false;
    if (parsed.scheme.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '%') {
            if (i + 2 >= text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return false;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/?#[]@!$&'()*+,;=", c) == null) return false;
    }
    if (std.mem.count(u8, text, "#") > 1) return false;
    // Brackets hold an IPv6 host and nothing else: `scheme://[v6]:port`.
    if (std.mem.indexOfAny(u8, text, "[]") == null) return true;
    const start = (std.mem.indexOf(u8, text, "://") orelse return false) + 3;
    const end = std.mem.indexOfAnyPos(u8, text, start, "/?#") orelse text.len;
    const authority = text[start..end];
    const host = authority[if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0..];
    if (std.mem.count(u8, text, "[") != 1 or std.mem.count(u8, text, "]") != 1 or host.len == 0 or host[0] != '[') return false;
    const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
    // Then nothing, or `:` and a port.
    const port = host[close + 1 ..];
    if (port.len > 0) {
        if (port[0] != ':') return false;
        for (port[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    }
    _ = std.Io.net.Ip6Address.parse(host[1..close], 0) catch return false;
    return true;
}

/// `local@domain`: dot-separated atoms (no empty ones) on both sides,
/// the domain with at least two labels.
fn email(text: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    const local = text[0..at];
    const domain = text[at + 1 ..];
    if (std.mem.indexOfScalar(u8, domain, '@') != null) return false;
    if (!atoms(local, "!#$%&'*+/=?^_`{|}~-")) return false;
    if (!atoms(domain, "-") or std.mem.indexOfScalar(u8, domain, '.') == null) return false;
    return true;
}

fn atoms(text: []const u8, extra: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extra, c) == null) return false;
    }
    return true;
}

/// `YYYY-MM-DD`, a day that exists.
fn date(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    const year = number(text[0..4]) orelse return false;
    const month = number(text[5..7]) orelse return false;
    const day = number(text[8..10]) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= days[month - 1];
}

/// RFC 3339: a date, `T`, `HH:MM:SS[.frac]`, then `Z` or `±HH:MM`.
fn dateTime(text: []const u8) bool {
    if (text.len < 20 or !date(text[0..10]) or (text[10] != 'T' and text[10] != 't')) return false;
    // No leap seconds: they cannot be told from mistakes without a table.
    if (!clock(text[11..19], 23, 59)) return false;
    var rest = text[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var n: usize = 1;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 1) return false;
        rest = rest[n..];
    }
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) return true;
    return rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':' and
        (number(rest[1..3]) orelse 99) <= 23 and (number(rest[4..6]) orelse 99) <= 59;
}

/// `HH:MM:SS` within the given maxima.
fn clock(text: []const u8, hours: u32, seconds: u32) bool {
    if (text[2] != ':' or text[5] != ':') return false;
    const h = number(text[0..2]) orelse return false;
    const m = number(text[3..5]) orelse return false;
    const sec = number(text[6..8]) orelse return false;
    return h <= hours and m <= 59 and sec <= seconds;
}

fn number(digits: []const u8) ?u32 {
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

test "formats" {
    try std.testing.expect(dateTime("2026-09-29T10:20:30.5+02:00") and dateTime("2024-02-29T00:00:00Z"));
    try std.testing.expect(!dateTime("2026-09-29Taa:bb:cc") and !dateTime("2026-09-29T10:20:30"));
    try std.testing.expect(!dateTime("2026-09-29T10:20:60Z"));
    try std.testing.expect(uri("https://example.com/a%20b?q=1#x") and !uri("https://example.com/a b") and !uri("https://example.com/%GG"));
    try std.testing.expect(uri("http://[::1]:8080/x") and !uri("https://example.com/a[b]") and !uri("https://example.com/#a#b"));
    try std.testing.expect(!uri("https://user[name]@example.com/") and !uri("https://[not-ip]/") and !uri("http://[::1]:junk:80/"));
    try std.testing.expect(email("first.last+tag@mail.example.com") and !email("a..b@example.com") and !email("a@example..com") and !email("a@localhost"));
}
