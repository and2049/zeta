//! Screen composition, top to bottom: transcript, working row, completion
//! list, queued input and attachments, the dock (see `view_dock.zig`),
//! footer.
//! No network or input logic here.
const std = @import("std");
const App = @import("App.zig");
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const plugin = @import("plugin.zig");
const Palette = @import("palette.zig").Palette;
const presentation = @import("presentation_text.zig");
const transcript = @import("transcript.zig");
const terminal_style = @import("terminal_style.zig");
const dock = @import("view_dock.zig");
const app_completion = @import("app_completion.zig");
const completion = @import("completion.zig");
const clock = @import("clock.zig");

/// What a frame is drawn with besides the app state.
pub const Frame = struct {
    registry: *const plugin.Registry,
    palette: Palette = .{},
    /// Epoch milliseconds, for the running turn's elapsed time.
    now_ms: i64 = 0,
};

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Run-loop-owned transcript cache: Markdown layout is reused across idle
/// frames and rebuilt on a projection revision, width, or toggle change.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    lines: ?[]presentation.Line = null,
    revision: u64 = 0,
    columns: usize = 0,
    count: usize = 0,
    expand_tools: bool = false,
    show_reasoning: bool = false,
    show_compaction: bool = false,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Cache) void {
        if (self.lines) |lines| presentation.freeLines(self.allocator, lines);
        self.lines = null;
    }
    fn get(self: *Cache, app: *const App, registry: *const plugin.Registry, cols: usize) ![]presentation.Line {
        if (self.lines != null and self.revision == app.render_revision and self.columns == cols and self.count == app.messages.items.len and self.expand_tools == app.expand_tools and self.show_reasoning == app.show_reasoning and self.show_compaction == app.show_compaction) return self.lines.?;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var entries: std.ArrayList(transcript.Entry) = .empty;
        for (app.messages.items) |message| {
            if (message.turn) |turn| {
                try entries.append(a, .{ .kind = .turn_end, .text = try turnLine(a, app, turn), .failed = turn.outcome == .failed, .stopped = turn.outcome == .stopped });
                continue;
            }
            if (message.origin != null and std.mem.eql(u8, message.origin.?, "compaction")) {
                var count: [16]u8 = undefined;
                var w: std.Io.Writer = .fixed(&count);
                if (message.tokens_before) |tokens| try @import("plugins/bars.zig").tokens(&w, tokens);
                const label = if (w.end > 0) try std.fmt.allocPrint(a, "Compaction ({s} tokens)", .{w.buffered()}) else "Compaction";
                try entries.append(a, .{ .kind = .compaction, .label = label, .text = message.text });
                continue;
            }
            if (message.thinking.len > 0) try entries.append(a, .{ .kind = .reasoning, .text = message.thinking });
            const tool = std.mem.eql(u8, message.role, "tool_call") or std.mem.eql(u8, message.role, "tool_result");
            const user = std.mem.eql(u8, message.role, "user");
            const notice = user and message.origin != null and std.mem.eql(u8, message.origin.?, "move");
            const kind: transcript.Kind = if (notice) .notice else if (user) .user else if (tool) .tool else .assistant;
            if (message.text.len == 0 and kind == .assistant and message.changes.len == 0) continue;
            const changes = try a.alloc(transcript.Change, message.changes.len);
            for (message.changes, changes) |from, *to| to.* = .{ .path = from.path, .before = from.before, .after = from.after, .truncated = from.truncated };
            const name = message.tool_name orelse "";
            // A result without its call (history cut before it) shows its text.
            const orphan = std.mem.eql(u8, message.role, "tool_result");
            const summary = if (!tool or orphan) "" else if (registry.toolRenderer(name)) |r| r.summary(a, message.text) catch "" else "";
            try entries.append(a, .{
                .kind = kind,
                .text = if (orphan) "" else message.text,
                .output = if (orphan) message.text else message.output,
                .label = name,
                .summary = summary,
                .pending = message.tool_running,
                .failed = message.is_error,
                .changes = changes,
            });
        }
        const fresh = try transcript.render(self.allocator, entries.items, .{ .width = cols, .expand_tools = app.expand_tools, .expand_reasoning = app.show_reasoning, .expand_compaction = app.show_compaction });
        if (self.lines) |old| presentation.freeLines(self.allocator, old);
        self.lines = fresh;
        self.revision = app.render_revision;
        self.columns = cols;
        self.count = app.messages.items.len;
        self.expand_tools = app.expand_tools;
        self.show_reasoning = app.show_reasoning;
        self.show_compaction = app.show_compaction;
        return fresh;
    }
};

/// `Worked for 4m 24s · 11:00 AM`, or how it stopped.
fn turnLine(a: std.mem.Allocator, app: *const App, turn: App.Turn) ![]const u8 {
    var span: [32]u8 = undefined;
    var at: [32]u8 = undefined;
    const verb = switch (turn.outcome) {
        .done => "Worked for",
        .stopped => "Stopped after",
        .failed => "Failed after",
    };
    return std.fmt.allocPrint(a, "{s} {s} · {s}", .{ verb, clock.duration(&span, turn.ended - turn.started), app.clock.time(&at, turn.ended) });
}

pub fn draw(screen: *Screen, app: *App, frame: Frame) ![]u8 {
    var cache = Cache.init(screen.allocator);
    defer cache.deinit();
    return drawCached(screen, app, frame, &cache);
}

pub fn drawCached(screen: *Screen, app: *App, frame: Frame, cache: *Cache) ![]u8 {
    screen.clear();
    var scratch: std.heap.ArenaAllocator = .init(screen.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const rows = screen.rows;
    if (app.running) app.tick +%= 1;
    const view: plugin.View = .{ .app = app, .palette = frame.palette, .spinner = spinner[(app.tick / 3) % spinner.len] };

    try bar(screen, a, frame.registry, view, rows -| 2, .footer_first, .footer_status);
    try bar(screen, a, frame.registry, view, rows -| 1, .footer_left, .footer_right);

    // The dock stack, from the footer up.
    const content = @min(dock.contentRows(app, frame.registry, screen.cols, rows), rows -| 6);
    const dock_top = rows -| (content + 4);
    const cursor = try dock.draw(screen, app, frame.registry, frame.palette, dock_top, @max(content, 1));
    var top = dock_top;
    if (app.attachments.items.len + app.embedded_images.items.len > 0 and top > 2) {
        top -= 1;
        const count = app.attachments.items.len + app.embedded_images.items.len;
        var buf: [80]u8 = undefined;
        const summary = try std.fmt.bufPrint(&buf, " 📎 {d} attachment{s}", .{ count, if (count == 1) @as([]const u8, "") else "s" });
        screen.drawStyledText(0, top, summary, .{ .dim = true });
        if (app.attachments.items.len > 0) screen.drawText(presentation.columns(summary) + 1, top, app.attachments.items[app.attachments.items.len - 1]);
    }
    if (app.pending.items.len > 0 and top > 2) {
        top -= 1;
        const last = app.pending.items[app.pending.items.len - 1];
        var buf: [100]u8 = undefined;
        const heading = try std.fmt.bufPrint(&buf, " Queued {d} ({s}): ", .{ app.pending.items.len, last.delivery });
        screen.drawStyledText(0, top, heading, .{ .dim = true });
        drawPreview(screen, presentation.columns(heading), top, last.text);
    }
    if (app.running and top > 3) {
        top -= 1;
        workingRow(screen, app, frame, view.spinner, top);
    }
    // The welcome keeps its layout while the completion list covers it.
    const without_list = top -| 2;
    if (app.overlay == .none) top = try completionList(screen, app, frame, a, top);

    // Blank rows at the top and above the dock.
    try transcriptArea(screen, app, frame, cache, 1, top -| 2, without_list);
    return screen.render(cursor);
}

/// `⠋ Thinking… 12s · Esc to stop` while a turn runs.
fn workingRow(screen: *Screen, app: *const App, frame: Frame, glyph: []const u8, y: usize) void {
    var buf: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    switch (app.activity) {
        .working => w.writeAll("Working…") catch {},
        .thinking => w.writeAll("Thinking…") catch {},
        .compacting => w.writeAll("Compacting…") catch {},
        .tool => w.print("Running {s}…", .{app.activity_tool}) catch {},
    }
    if (app.turn_started) |started| if (frame.now_ms > started) {
        var span: [32]u8 = undefined;
        w.print(" {s}", .{clock.duration(&span, frame.now_ms - started)}) catch {};
    };
    screen.drawStyledText(1, y, glyph, .{ .foreground = screen_mod.Color.cyan, .bold = true });
    const x = 2 + presentation.columns(glyph);
    screen.drawStyledText(x, y, w.buffered(), .{});
    screen.drawStyledText(x + presentation.columns(w.buffered()), y, " · Esc to stop", .{ .dim = true });
}

/// Draws the transcript into rows `first .. first + height`. The welcome
/// is laid out for `welcome_rows` and cut at `height`.
fn transcriptArea(screen: *Screen, app: *App, frame: Frame, cache: *Cache, first: usize, height: usize, welcome_rows: usize) !void {
    const lines = try cache.get(app, frame.registry, screen.cols);
    // Scroll is the distance from the end: new output does not move the
    // view while the user reads older history.
    if (app.follow_end) app.scroll = 0 else if (!app.history_prepend and lines.len > app.last_lines) app.scroll +|= lines.len - app.last_lines;
    app.history_prepend = false;
    app.last_lines = lines.len;
    if (app.messages.items.len == 0 and height > 1) {
        var b = presentation.Builder.init(screen.allocator);
        defer b.deinit();
        try frame.registry.renderSlot(.welcome, .{ .app = app, .palette = frame.palette, .spinner = "", .rows = welcome_rows, .columns = screen.cols }, &b, "");
        const welcome = try b.finish();
        defer presentation.freeLines(screen.allocator, welcome);
        for (welcome[0..@min(welcome.len, height)], first..) |line, y| drawSpans(screen, 0, y, line.spans);
        return;
    }
    app.scroll = @min(app.scroll, lines.len -| height);
    const end = lines.len -| app.scroll;
    const start = end -| height;
    for (lines[start..end], first..) |line, y| {
        drawSpans(screen, 0, y, line.spans);
        if (line.surface) screen.fill(0, y, frame.palette.surface);
    }
    if (app.scroll > 0 and height > 0) {
        var buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, " ↓ {d} more lines · End ", .{app.scroll});
        const x = (screen.cols -| presentation.columns(label)) / 2;
        screen.drawStyledText(x, first + height - 1, label, .{ .bold = true, .background = frame.palette.selected });
    }
}

/// The completion list above the dock; returns the new top row.
fn completionList(screen: *Screen, app: *App, frame: Frame, a: std.mem.Allocator, top: usize) !usize {
    const list = (try app_completion.current(app, frame.registry, a)) orelse return top;
    const shown = @min(completion.max_rows, list.indices.len);
    const count = @min(@max(shown, 1), top -| 3);
    if (count == 0) return top;
    const first = top - count;
    const window_start = if (list.selected >= count) list.selected - count + 1 else 0;
    if (list.indices.len == 0) {
        screen.drawStyledText(1, first, if (app.files.len == 0 and app.file_query.len == 0) "Searching…" else "No matching files", .{ .dim = true });
        screen.fill(0, first, frame.palette.surface);
        return first;
    }
    const column = completion.nameColumn(list.items, list.indices);
    for (0..count) |row| {
        const at = window_start + row;
        if (at >= list.indices.len) break;
        const item = list.items[list.indices[at]];
        const y = first + row;
        const active = at == list.selected;
        screen.drawStyledText(1, y, item.label, .{ .bold = active });
        if (item.detail.len > 0 and column + 4 < screen.cols) screen.drawStyledText(column + 3, y, item.detail, .{ .dim = !active });
        screen.fill(0, y, if (active) frame.palette.selected else frame.palette.surface);
    }
    return first;
}

/// Draws a slot row: `left` from the first column and `right` against the
/// right edge when it fits.
fn bar(screen: *Screen, a: std.mem.Allocator, registry: *const plugin.Registry, view: plugin.View, y: usize, left: plugin.Slot, right: ?plugin.Slot) !void {
    var b = presentation.Builder.init(a);
    try registry.renderSlot(left, view, &b, "  ");
    const left_width = b.used;
    const left_lines = try b.finish();
    drawSpans(screen, 1, y, left_lines[0].spans);
    const slot = right orelse return;
    var r = presentation.Builder.init(a);
    try registry.renderSlot(slot, view, &r, " · ");
    const right_width = r.used;
    const right_lines = try r.finish();
    if (right_width == 0) return;
    const x = if (left_width + right_width + 4 <= screen.cols) screen.cols - right_width - 1 else left_width + 3;
    drawSpans(screen, x, y, right_lines[0].spans);
}

fn drawSpans(screen: *Screen, x0: usize, y: usize, spans: []const presentation.Span) void {
    var x = x0;
    for (spans) |span| {
        screen.drawStyledText(x, y, span.text, terminal_style.styleFor(span.style));
        x += presentation.columns(span.text);
    }
}

/// The first line of `text`, cut with `…` to the rest of the row.
fn drawPreview(screen: *Screen, x: usize, y: usize, text: []const u8) void {
    if (x >= screen.cols) return;
    const first = text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
    var buf: [512]u8 = undefined;
    var length: usize = 0;
    var cells: usize = 0;
    const available = screen.cols - x;
    var iterator: @import("width.zig").Iterator = .{ .input = first };
    var clipped = false;
    while (iterator.next()) |rune| {
        if (cells + rune.columns > available -| 1 or length + rune.bytes.len > buf.len - 3) {
            clipped = true;
            break;
        }
        @memcpy(buf[length .. length + rune.bytes.len], rune.bytes);
        length += rune.bytes.len;
        cells += rune.columns;
    }
    if (clipped and cells < available) {
        @memcpy(buf[length .. length + "…".len], "…");
        length += "…".len;
    }
    screen.drawText(x, y, buf[0..length]);
}

test {
    _ = @import("view_test.zig");
}
