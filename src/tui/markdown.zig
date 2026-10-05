//! Deliberately small streaming-safe Markdown presenter: headings, lists,
//! quotes, rules, fenced code, tables (`markdown_table.zig`), and inline
//! code, **strong** and [links](url). Unclosed fences stay code until a
//! matching closing fence arrives; no parser state escapes render.
const std = @import("std");
const p = @import("presentation_text.zig");
const A = std.mem.Allocator;
const table = @import("markdown_table.zig");

pub fn render(a: A, source: []const u8, width: usize) ![]p.Line {
    var b = p.Builder.init(a);
    errdefer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var fence: u8 = 0;
    var fence_len: usize = 0;
    var all: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, source, '\n');
    while (split.next()) |raw| try all.append(sa, std.mem.trimEnd(u8, raw, "\r"));
    const lines = all.items;
    var at: usize = 0;
    while (at < lines.len) : (at += 1) {
        const line = lines[at];
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (fence != 0) {
            if (fenceMarker(trimmed)) |m| {
                if (m.char == fence and m.len >= fence_len and std.mem.trim(u8, trimmed[m.len..], " \t").len == 0) {
                    fence = 0;
                    try b.pad(" └", .muted);
                    try b.newline();
                    continue;
                }
            }
            try b.pad(" │ ", .muted);
            try code(&b, line, width);
            try b.newline();
            continue;
        }
        if (fenceMarker(trimmed)) |m| {
            fence = m.char;
            fence_len = m.len;
            try b.pad(" ┌ ", .muted);
            try b.wrap(std.mem.trim(u8, trimmed[m.len..], " \t"), .muted, width, "   ");
            try b.newline();
            continue;
        }
        if (trimmed.len == 0) {
            try b.newline();
            continue;
        }
        // A header row followed by a delimiter row starts a table.
        if (at + 1 < lines.len) if (try table.cells(sa, line)) |header| if (try table.delimiter(sa, lines[at + 1])) |aligns| if (aligns.len == header.len) {
            var rows: std.ArrayList([]const []const u8) = .empty;
            var next = at + 2;
            while (next < lines.len) : (next += 1) {
                const cols = (try table.cells(sa, lines[next])) orelse break;
                if (std.mem.trim(u8, lines[next], " \t").len == 0) break;
                try rows.append(sa, cols);
            }
            try table.render(&b, header, aligns, rows.items, width);
            at = next - 1;
            continue;
        };
        if (rule(trimmed)) {
            var bar: std.ArrayList(u8) = .empty;
            for (0..width -| 2) |_| try bar.appendSlice(sa, "─");
            try b.add(" ", .normal);
            try b.add(bar.items, .muted);
            try b.newline();
            continue;
        }
        if (trimmed[0] == '>') {
            const quoted = std.mem.trimStart(u8, trimmed[1..], " ");
            try b.pad(" │ ", .muted);
            try inlineSpans(&b, quoted, .reasoning, width, " │ ");
            try b.newline();
            continue;
        }
        var body = trimmed;
        var style: p.Style = .normal;
        if (trimmed[0] == '#') {
            const n = std.mem.indexOfNone(u8, trimmed, "#") orelse trimmed.len;
            if (n <= 6 and n < trimmed.len and trimmed[n] == ' ') {
                body = trimmed[n + 1 ..];
                style = .heading;
            }
        }
        // Nested lists keep their indent, up to a few levels.
        const indent = "        "[0..@min(8, line.len - trimmed.len)];
        var marker: []const u8 = "";
        if (style == .normal and trimmed.len > 2 and (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ "))) {
            marker = "• ";
            body = trimmed[2..];
        } else if (style == .normal) {
            const dot = std.mem.indexOfScalar(u8, trimmed, '.') orelse 0;
            if (dot > 0 and dot <= 3 and dot + 1 < trimmed.len and trimmed[dot + 1] == ' ' and std.ascii.isDigit(trimmed[0])) {
                marker = trimmed[0 .. dot + 2];
                body = trimmed[dot + 2 ..];
            }
        }
        try b.pad(" ", .normal);
        var continuation: [16]u8 = @splat(' ');
        const hang = 1 + @min(indent.len + p.columns(marker), continuation.len - 1);
        if (marker.len > 0) {
            try b.add(indent, .normal);
            try b.add(marker, .list_marker);
        }
        try inlineSpans(&b, body, style, width, continuation[0..hang]);
        try b.newline();
    }
    return b.finish();
}
/// `---`, `***` or `___` (three or more, spaces allowed) alone on a line.
fn rule(line: []const u8) bool {
    const c = line[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (line) |x| {
        if (x == c) count += 1 else if (x != ' ') return false;
    }
    return count >= 3;
}

/// Inline `code`, **strong** and [text](url) runs, wrapped into `b`;
/// other markup stays literal. A link shows its text, then the URL when it
/// differs.
pub fn inlineSpans(b: *p.Builder, text: []const u8, base: p.Style, width: usize, continuation: []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') if (link(text[i..])) |l| {
            if (i > start) try b.wrap(text[start..i], base, width, continuation);
            try b.wrap(l.label, .link, width, continuation);
            if (!std.mem.eql(u8, l.label, l.url)) {
                try b.wrap(" (", .muted, width, continuation);
                try b.wrap(l.url, .muted, width, continuation);
                try b.wrap(")", .muted, width, continuation);
            }
            i += l.len;
            start = i;
            continue;
        };
        const delimiter: []const u8 = if (text[i] == '`') "`" else if (std.mem.startsWith(u8, text[i..], "**")) "**" else {
            i += 1;
            continue;
        };
        const close = std.mem.indexOfPos(u8, text, i + delimiter.len, delimiter) orelse {
            i += delimiter.len;
            continue;
        };
        if (close == i + delimiter.len) {
            i = close + delimiter.len;
            continue;
        }
        if (i > start) try b.wrap(text[start..i], base, width, continuation);
        try b.wrap(text[i + delimiter.len .. close], if (delimiter.len == 1) .code else .strong, width, continuation);
        i = close + delimiter.len;
        start = i;
    }
    if (start < text.len) try b.wrap(text[start..], base, width, continuation);
}

const Link = struct { label: []const u8, url: []const u8, len: usize };

/// `[label](url)` at the start of `text`.
fn link(text: []const u8) ?Link {
    const close = std.mem.indexOfScalar(u8, text, ']') orelse return null;
    if (close < 2 or close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse return null;
    const url = text[close + 2 .. end];
    if (url.len == 0 or std.mem.indexOfScalar(u8, url, ' ') != null) return null;
    return .{ .label = text[1..close], .url = url, .len = end + 1 };
}

const Marker = struct { char: u8, len: usize };
fn fenceMarker(s: []const u8) ?Marker {
    if (s.len < 3 or (s[0] != '`' and s[0] != '~')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) : (n += 1) {}
    if (n < 3) return null;
    return .{ .char = s[0], .len = n };
}
fn code(b: *p.Builder, line: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i < line.len) {
        const start = i;
        var style: p.Style = .normal;
        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            i += 1;
            while (i < line.len and line[i] != quote) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) i += 1;
            }
            if (i < line.len) i += 1;
            style = .code_string;
        } else if (std.ascii.isDigit(line[i])) {
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.')) : (i += 1) {}
            style = .code_number;
        } else if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) : (i += 1) {}
            if (keyword(line[start..i])) style = .code_keyword;
        } else i += 1;
        try b.wrap(line[start..i], style, width, " │ ");
    }
}
fn keyword(s: []const u8) bool {
    for ([_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "for", "while", "try", "async", "await", "function", "class", "import", "export" }) |word| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    return false;
}

fn joined(lines: []const p.Line, i: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines[i].spans) |span| try out.appendSlice(std.testing.allocator, span.text);
    return out.toOwnedSlice(std.testing.allocator);
}

test "tables, quotes, rules and links" {
    const a = std.testing.allocator;
    const lines = try render(a, "| A | B |\n|---|--:|\n| x | 1 |\n\n> quoted\n\n---\nsee [docs](https://x.test) and [https://y](https://y)", 60);
    defer p.freeLines(a, lines);
    const top = try joined(lines, 0);
    defer a.free(top);
    try std.testing.expect(std.mem.startsWith(u8, top, " ┌"));
    const body = try joined(lines, 3);
    defer a.free(body);
    try std.testing.expectEqualStrings(" │ x   │   1 │", body);
    const quote = try joined(lines, 6);
    defer a.free(quote);
    try std.testing.expectEqualStrings(" │ quoted", quote);
    const bar = try joined(lines, 8);
    defer a.free(bar);
    try std.testing.expect(std.mem.startsWith(u8, bar, " ───"));
    const links = try joined(lines, 9);
    defer a.free(links);
    try std.testing.expectEqualStrings(" see docs (https://x.test) and https://y", links);
}

test "a table row still streaming in is plain text until its delimiter arrives" {
    const a = std.testing.allocator;
    const lines = try render(a, "| A | B |", 30);
    defer p.freeLines(a, lines);
    const only = try joined(lines, 0);
    defer a.free(only);
    try std.testing.expectEqualStrings(" | A | B |", only);
}

test "wrap headings lists and incomplete streaming fence" {
    const a = std.testing.allocator;
    const lines = try render(a, "# Heading\n- abcdef\n```zig\nconst x = 12\n``", 30);
    defer p.freeLines(a, lines);
    try std.testing.expect(lines.len >= 5);
    var found_keyword = false;
    var partial_ticks: usize = 0;
    for (lines) |line| for (line.spans) |span| {
        if (span.style == .code_keyword) found_keyword = true;
        if (std.mem.eql(u8, span.text, "`")) partial_ticks += 1;
    };
    try std.testing.expect(found_keyword and partial_ticks == 2);
    const wrapped = try render(a, "# Heading\n- abcdef", 7);
    defer p.freeLines(a, wrapped);
    try std.testing.expect(wrapped.len > 2);
}
