//! Transcript presentation: user messages on a raised surface, assistant
//! Markdown with one column of padding, one-line tool entries (expanded on
//! request) and collapsible reasoning. Never imports core.
const std = @import("std");
const p = @import("presentation_text.zig");
const md = @import("markdown.zig");
const A = std.mem.Allocator;
/// `notice`: a one-line note the client added, e.g. a moved session.
/// `compaction`: a summary of older history. `turn_end`: how long a turn
/// took (`text` is the line). `shell`: a command the user ran (`text`)
/// and what it printed (`output`).
pub const Kind = enum { user, assistant, reasoning, tool, notice, compaction, turn_end, shell };
pub const Change = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
    truncated: bool = false,
};
pub const Entry = struct {
    kind: Kind,
    /// User or assistant text, reasoning, or a tool call's JSON arguments.
    text: []const u8,
    /// Tool name.
    label: []const u8 = "",
    /// Tool call summary (from its renderer), e.g. a path.
    summary: []const u8 = "",
    /// Tool result text.
    output: []const u8 = "",
    pending: bool = false,
    failed: bool = false,
    changes: []const Change = &.{},
    /// A `turn_end` that was stopped (not failed).
    stopped: bool = false,
};
pub const Options = struct { width: usize, expand_reasoning: bool = false, expand_tools: bool = false, expand_compaction: bool = false };

const max_output_lines = 40;
/// A command the user ran shows this much output until tools are expanded.
const shell_output_lines = 20;
const max_argument_lines = 12;
const max_diff_lines = 24;

/// Returns owned lines (free with p.freeLines). Source slices may be
/// temporary; everything is copied.
pub fn render(a: A, entries: []const Entry, options: Options) ![]p.Line {
    var b = p.Builder.init(a);
    errdefer b.deinit();
    const inner = options.width -| 1;
    for (entries, 0..) |entry, i| {
        // Consecutive tool entries stay together; everything else is spaced.
        if (i > 0 and !(entry.kind == .tool and entries[i - 1].kind == .tool)) try b.newline();
        switch (entry.kind) {
            .user => {
                b.surface = true;
                try b.newline();
                var parts = std.mem.splitScalar(u8, std.mem.trim(u8, entry.text, "\r\n"), '\n');
                while (parts.next()) |part| {
                    try b.pad(" ", .normal);
                    try b.wrapLinked(part, .user, .link, inner, " ");
                    try b.newline();
                }
                try b.newline();
                b.surface = false;
            },
            .assistant => {
                const rendered = try md.render(a, std.mem.trim(u8, entry.text, "\r\n"), inner);
                defer p.freeLines(a, rendered);
                try b.extend(rendered);
            },
            .reasoning => try disclosure(&b, "Thinking", entry.text, .reasoning, options.expand_reasoning, options.width),
            .compaction => try disclosure(&b, entry.label, entry.text, .muted, options.expand_compaction, options.width),
            .turn_end => {
                try b.pad(" ", .normal);
                try b.add(entry.text, if (entry.failed) .failure else if (entry.stopped) .warning else .muted);
                try b.newline();
            },
            .tool => try tool(&b, entry, options),
            .shell => {
                b.surface = true;
                try b.newline();
                try b.pad(" ", .normal);
                try b.add("! ", if (entry.failed) .failure else .accent);
                try b.wrapLinked(std.mem.trim(u8, entry.text, "\r\n"), .user, .link, inner, "   ");
                try b.newline();
                try b.newline();
                b.surface = false;
                try block(&b, entry.output, .tool, if (options.expand_tools) std.math.maxInt(usize) else shell_output_lines, options.width);
            },
            .notice => {
                try b.add(" → ", .muted);
                try b.wrapLinked(std.mem.trim(u8, entry.text, " \t\r\n"), .muted, .link, options.width, "   ");
                try b.newline();
            },
        }
    }
    return b.finish();
}

/// Collapsed: `▶ Label: …tail` on one row. Expanded: `▼ Label:` and the
/// whole text indented under it.
fn disclosure(b: *p.Builder, label: []const u8, text: []const u8, style: p.Style, expanded: bool, width: usize) !void {
    const body = std.mem.trim(u8, text, " \t\r\n");
    try b.add(if (expanded) " ▼ " else " ▶ ", style);
    try b.add(label, style);
    try b.add(":", style);
    if (!expanded) {
        const flat = try flatten(b.a, body);
        defer b.a.free(flat);
        if (flat.len > 0) {
            try b.add(" ", style);
            try tail(b, flat, style, width);
        }
        return b.newline();
    }
    try b.newline();
    var parts = std.mem.splitScalar(u8, body, '\n');
    while (parts.next()) |part| {
        try b.pad("   ", .normal);
        try b.wrapLinked(part, style, .link, width -| 1, "   ");
        try b.newline();
    }
}

/// `text` with every run of whitespace as one space.
fn flatten(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// The end of `text` that fits the rest of the row, after `…` when cut.
fn tail(b: *p.Builder, text: []const u8, style: p.Style, width: usize) !void {
    const safe = try p.clean(b.a, text);
    defer b.a.free(safe);
    const available = (if (width == 0) 80 else width) -| b.used -| 1;
    if (p.columns(safe) <= available) return b.add(safe, style);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(b.a);
    var it: @import("width.zig").Iterator = .{ .input = safe };
    var at: usize = 0;
    while (it.next()) |_| {
        try starts.append(b.a, at);
        at = it.index;
    }
    var cells: usize = 0;
    var start = safe.len;
    var i = starts.items.len;
    while (i > 0) {
        i -= 1;
        const cluster = p.columns(safe[starts.items[i]..start]);
        if (cells + cluster > available -| 1) break;
        cells += cluster;
        start = starts.items[i];
    }
    try b.add("…", style);
    try b.add(safe[start..], style);
}

fn tool(b: *p.Builder, entry: Entry, options: Options) !void {
    try b.pad(" ", .normal);
    if (entry.pending) try b.add("○ ", .muted) else if (entry.failed) try b.add("✗ ", .failure) else try b.add("✓ ", .success);
    try b.add(entry.label, .tool_name);
    const summary = if (entry.summary.len > 0) entry.summary else firstLine(entry.text);
    if (summary.len > 0) {
        try b.add(" ", .normal);
        try clipped(b, summary, .muted, options.width);
    }
    try b.newline();
    if (!options.expand_tools) {
        // A failure says why even when collapsed.
        if (entry.failed and !entry.pending) {
            try b.pad("   ", .normal);
            try clipped(b, firstLine(entry.output), .failure, options.width);
            try b.newline();
        }
        return;
    }
    try block(b, entry.text, .muted, max_argument_lines, options.width);
    if (entry.output.len > 0) try block(b, entry.output, if (entry.failed) .failure else .tool, max_output_lines, options.width);
    for (entry.changes) |change| try renderChange(b, change, options.width);
}

/// Up to `limit` lines of `text`, indented, then a count of the rest.
fn block(b: *p.Builder, text: []const u8, style: p.Style, limit: usize, width: usize) !void {
    const trimmed = std.mem.trim(u8, text, "\r\n");
    if (trimmed.len == 0) return;
    var parts = std.mem.splitScalar(u8, trimmed, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    while (parts.next()) |part| : (total += 1) {
        if (shown == limit) continue;
        try b.pad("   ", .normal);
        try b.wrapLinked(part, style, .link, width, "   ");
        try b.newline();
        shown += 1;
    }
    if (total > shown) {
        var buf: [48]u8 = undefined;
        try b.add(try std.fmt.bufPrint(&buf, "   … {d} more lines", .{total - shown}), .muted);
        try b.newline();
    }
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

/// Adds `raw` cut to the rest of the row, with `…` when cut.
fn clipped(b: *p.Builder, raw: []const u8, style: p.Style, width: usize) !void {
    const safe = try p.clean(b.a, raw);
    defer b.a.free(safe);
    const available = if (width == 0) 80 else width -| b.used;
    if (p.columns(safe) <= available) return b.add(safe, style);
    var it: @import("width.zig").Iterator = .{ .input = safe };
    var end: usize = 0;
    var cells: usize = 0;
    while (it.next()) |cluster| {
        if (cells + cluster.columns > available -| 1) break;
        cells += cluster.columns;
        end = it.index;
    }
    try b.add(safe[0..end], style);
    if (available > 0) try b.add("…", style);
}

fn renderChange(b: *p.Builder, change: Change, width: usize) !void {
    try b.add("   Δ ", .muted);
    try b.wrap(change.path, .tool, width, "     ");
    try b.newline();
    var clipped_diff = false;
    for ([_]struct { text: []const u8, marker: []const u8, style: p.Style }{
        .{ .text = change.before, .marker = "- ", .style = .removed },
        .{ .text = change.after, .marker = "+ ", .style = .added },
    }) |part| {
        if (part.text.len == 0) continue;
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, part.text, '\n');
        while (lines.next()) |line| : (count += 1) {
            if (count >= max_diff_lines / 2) {
                clipped_diff = true;
                break;
            }
            try b.pad("   ", .normal);
            try b.add(part.marker, part.style);
            try b.wrapLinked(line, part.style, part.style, width, "     ");
            try b.newline();
        }
    }
    if (clipped_diff or change.truncated) {
        try b.add(if (change.truncated) "   … diff truncated at source" else "   … diff truncated for display", .muted);
        try b.newline();
    }
}

fn rowText(lines: []const p.Line, i: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines[i].spans) |span| try out.appendSlice(std.testing.allocator, span.text);
    return out.toOwnedSlice(std.testing.allocator);
}

test "user messages sit on a surface with padding rows; reasoning collapses" {
    const a = std.testing.allocator;
    const lines = try render(a, &.{ .{ .kind = .user, .text = "hello" }, .{ .kind = .reasoning, .text = "secret" }, .{ .kind = .assistant, .text = "Hi" } }, .{ .width = 30 });
    defer p.freeLines(a, lines);
    try std.testing.expect(lines[0].surface and lines[1].surface and lines[2].surface);
    const user = try rowText(lines, 1);
    defer a.free(user);
    try std.testing.expectEqualStrings(" hello", user);
    try std.testing.expect(!lines[3].surface);
    const thinking = try rowText(lines, 4);
    defer a.free(thinking);
    try std.testing.expectEqualStrings(" ▶ Thinking: secret", thinking);
    const reply = try rowText(lines, 6);
    defer a.free(reply);
    try std.testing.expectEqualStrings(" Hi", reply);
}

test "tools are one line until expanded; failures show their reason" {
    const a = std.testing.allocator;
    const entries = [_]Entry{
        .{ .kind = .tool, .label = "read", .summary = "src/main.zig", .text = "{}", .output = "line1\nTAIL" },
        .{ .kind = .tool, .label = "bash", .summary = "false", .text = "{}", .output = "exit 1\nmore", .failed = true },
    };
    const compact = try render(a, &entries, .{ .width = 40 });
    defer p.freeLines(a, compact);
    try std.testing.expectEqual(@as(usize, 3), compact.len);
    const first = try rowText(compact, 0);
    defer a.free(first);
    try std.testing.expectEqualStrings(" ✓ read src/main.zig", first);
    const reason = try rowText(compact, 2);
    defer a.free(reason);
    try std.testing.expectEqualStrings("   exit 1", reason);
    const expanded = try render(a, &entries, .{ .width = 40, .expand_tools = true });
    defer p.freeLines(a, expanded);
    var found = false;
    for (expanded, 0..) |_, i| {
        const line = try rowText(expanded, i);
        defer a.free(line);
        if (std.mem.eql(u8, line, "   TAIL")) found = true;
    }
    try std.testing.expect(found);
}

test "expanded diff uses markers and truncation" {
    const a = std.testing.allocator;
    const lines = try render(a, &.{.{ .kind = .tool, .label = "edit", .text = "", .output = "", .changes = &.{.{ .path = "file", .before = "old", .after = "new", .truncated = true }} }}, .{ .width = 40, .expand_tools = true });
    defer p.freeLines(a, lines);
    try std.testing.expectEqualStrings("- ", lines[2].spans[1].text);
    try std.testing.expectEqualStrings("+ ", lines[3].spans[1].text);
    try std.testing.expectEqualStrings("   … diff truncated at source", lines[4].spans[0].text);
}

test "disclosures show the tail collapsed and everything expanded" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .kind = .compaction, .label = "Compaction", .text = "first part\n\nlast words here" };
    const collapsed = try render(a, &.{entry}, .{ .width = 30 });
    defer p.freeLines(a, collapsed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);
    const line = try rowText(collapsed, 0);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, " ▶ Compaction: …"));
    try std.testing.expect(std.mem.endsWith(u8, line, "words here"));
    try std.testing.expect(p.columns(line) <= 30);
    const expanded = try render(a, &.{entry}, .{ .width = 30, .expand_compaction = true });
    defer p.freeLines(a, expanded);
    const head = try rowText(expanded, 0);
    defer a.free(head);
    try std.testing.expectEqualStrings(" ▼ Compaction:", head);
    const body = try rowText(expanded, 1);
    defer a.free(body);
    try std.testing.expectEqualStrings("   first part", body);
}

test "a command the user ran shows its output, cut until expanded" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .kind = .shell, .text = "seq 30", .output = "1\n" ** 30 ++ "Command exited with code 1", .failed = true };
    const short = try render(a, &.{entry}, .{ .width = 40 });
    defer p.freeLines(a, short);
    const head = try rowText(short, 1);
    defer a.free(head);
    try std.testing.expectEqualStrings(" ! seq 30", head);
    try std.testing.expect(short[1].surface and !short[3].surface);
    const more = try rowText(short, short.len - 1);
    defer a.free(more);
    try std.testing.expectEqualStrings("   … 11 more lines", more);
    const all = try render(a, &.{entry}, .{ .width = 40, .expand_tools = true });
    defer p.freeLines(a, all);
    const last = try rowText(all, all.len - 1);
    defer a.free(last);
    try std.testing.expectEqualStrings("   Command exited with code 1", last);
}

test "a notice is one muted line" {
    const a = std.testing.allocator;
    const lines = try render(a, &.{.{ .kind = .notice, .text = "The project directory is now /x." }}, .{ .width = 60 });
    defer p.freeLines(a, lines);
    const line = try rowText(lines, 0);
    defer a.free(line);
    try std.testing.expectEqualStrings(" → The project directory is now /x.", line);
    try std.testing.expect(!lines[0].surface);
}

test "a long tool summary stays on one row" {
    const a = std.testing.allocator;
    const lines = try render(a, &.{.{ .kind = .tool, .text = "abcdefghijklmnopqrstuvwxyz0123456789", .label = "run" }}, .{ .width = 14 });
    defer p.freeLines(a, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    var cells: usize = 0;
    for (lines[0].spans) |span| cells += p.columns(span.text);
    try std.testing.expect(cells <= 14);
}
