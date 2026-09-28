//! Small, deliberately non-validating HTML-to-Markdown converter for fetched pages.
const std = @import("std");

pub fn markdown(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    var skip: ?[]const u8 = null;
    var href: ?[]const u8 = null;
    var in_pre = false;
    var pending_space = false;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const raw = std.mem.trim(u8, html[i + 1 .. end], " \t\r\n");
            i = end + 1;
            if (raw.len == 0 or raw[0] == '!') continue;
            const closing = raw[0] == '/';
            const tag_text = if (closing) raw[1..] else raw;
            const tag_end = std.mem.indexOfAny(u8, tag_text, " \t\r\n/") orelse tag_text.len;
            const tag = tag_text[0..tag_end];
            if (skip) |hidden| {
                if (closing and std.ascii.eqlIgnoreCase(tag, hidden)) skip = null;
                continue;
            }
            if (!closing and (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style"))) {
                skip = tag;
            } else if (std.ascii.eqlIgnoreCase(tag, "br")) {
                try out.writer.writeAll("\n");
            } else if (std.ascii.eqlIgnoreCase(tag, "pre")) {
                try out.writer.writeAll(if (closing) "\n```\n" else "\n```\n");
                in_pre = !closing;
            } else if (std.ascii.eqlIgnoreCase(tag, "code")) {
                if (!in_pre) try out.writer.writeByte('`');
            } else if (std.ascii.eqlIgnoreCase(tag, "a")) {
                if (closing) {
                    if (href) |link| {
                        try out.writer.print("]({s})", .{link});
                        href = null;
                    }
                } else if (attribute(tag_text[tag_end..], "href")) |link| {
                    href = link;
                    if (pending_space and out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte(' ');
                    pending_space = false;
                    try out.writer.writeByte('[');
                }
            } else if (std.ascii.eqlIgnoreCase(tag, "li")) {
                if (closing) try out.writer.writeByte('\n') else try out.writer.writeAll("\n- ");
            } else if (std.ascii.eqlIgnoreCase(tag, "p") or std.ascii.eqlIgnoreCase(tag, "div") or std.ascii.eqlIgnoreCase(tag, "ul") or std.ascii.eqlIgnoreCase(tag, "ol")) {
                try out.writer.writeByte('\n');
            } else if (tag.len == 2 and std.ascii.toLower(tag[0]) == 'h' and tag[1] >= '1' and tag[1] <= '6') {
                try out.writer.writeByte('\n');
                if (!closing) {
                    for (0..tag[1] - '0') |_| try out.writer.writeByte('#');
                    try out.writer.writeByte(' ');
                } else try out.writer.writeByte('\n');
            }
            continue;
        }
        if (skip != null) {
            i += 1;
            continue;
        }
        if (html[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, html, i, ';')) |end| {
                if (end - i <= 10) {
                    const entity = html[i + 1 .. end];
                    const ch: ?u8 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "nbsp")) ' ' else null;
                    if (ch) |value| {
                        try out.writer.writeByte(value);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        if (!in_pre and std.ascii.isWhitespace(html[i])) {
            pending_space = true;
        } else {
            if (pending_space and out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte(' ');
            pending_space = false;
            try out.writer.writeByte(html[i]);
        }
        i += 1;
    }
    return std.mem.trim(u8, out.written(), " \r\n\t");
}

fn attribute(attrs: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (std.ascii.isWhitespace(attrs[i]) or attrs[i] == '/')) : (i += 1) {}
        const start = i;
        while (i < attrs.len and (std.ascii.isAlphanumeric(attrs[i]) or attrs[i] == '-')) : (i += 1) {}
        if (start == i) {
            i += 1;
            continue;
        }
        const name = attrs[start..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len or attrs[i] != '=') continue;
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;
        const quote = attrs[i];
        if (quote == '"' or quote == '\'') i += 1;
        const value_start = i;
        if (quote == '"' or quote == '\'') {
            while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
        } else {
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '>') : (i += 1) {}
        }
        const value = attrs[value_start..i];
        if (i < attrs.len and (quote == '"' or quote == '\'')) i += 1;
        if (std.ascii.eqlIgnoreCase(name, key)) return value;
    }
    return null;
}

test "headings links lists code and hidden content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try markdown(arena.allocator(), "<style>x</style><h2>Title</h2><p>Hi <a href=\"https://example.test\">there</a></p><ul><li>One</li><li>Two</li></ul><pre><code>a &lt; b</code></pre><script>bad()</script>");
    try std.testing.expect(std.mem.indexOf(u8, text, "## Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[there](https://example.test)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- One") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```\na < b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bad()") == null);
}
