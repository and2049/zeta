//! The dock: the editor between two full-width rules, or what replaces the
//! editor (a picker, a permission question, a sign-in step, help). The top
//! rule shows the picker's title; its color follows the thinking level.
const std = @import("std");
const App = @import("App.zig");
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const plugin = @import("plugin.zig");
const picker = @import("picker.zig");
const presentation = @import("presentation_text.zig");
const terminal_style = @import("terminal_style.zig");
const editor_view = @import("editor_view.zig");
const width = @import("width.zig");
const Palette = @import("palette.zig").Palette;

pub const Cursor = editor_view.Cursor;

/// Rows between the two rules.
pub fn contentRows(app: *const App, registry: *const plugin.Registry, cols: usize, rows: usize) usize {
    return switch (app.overlay) {
        .none => @min(@max(@as(usize, 1), editor_view.rowCount(app.editor.text(), cols)), @max(@as(usize, 5), rows * 3 / 10)),
        .help => helpLines(registry) + 1,
        .permission, .connect_oauth => 4,
        .connect_key => 2,
        .models, .thinking, .sessions, .pending, .connect_providers, .connect_methods => @max(@as(usize, 2), @min(app.picker_items.len + 1, @min(@as(usize, 12), rows / 2))),
    };
}

/// Draws the rules at `top` and `top + content + 1` and the content between.
pub fn draw(screen: *Screen, app: *App, registry: *const plugin.Registry, palette: Palette, top: usize, content: usize) !Cursor {
    const rule: screen_mod.Style = .{ .foreground = terminal_style.ruleColor(app.thinking) };
    for ([_]usize{ top, top + content + 1 }) |y| {
        var x: usize = 0;
        while (x < screen.cols) : (x += 1) screen.drawStyledText(x, y, "─", rule);
    }
    const title: []const u8 = switch (app.overlay) {
        .none, .permission => "",
        .help => "Keys",
        .models => "Model",
        .thinking => "Thinking level",
        .sessions => "Session",
        .pending => "Queued",
        .connect_providers => "Provider",
        .connect_methods => "Method",
        .connect_key => "API key",
        .connect_oauth => "Login",
    };
    if (title.len > 0) {
        screen.drawStyledText(3, top, " ", .{});
        screen.drawStyledText(4, top, title, .{ .bold = true });
        screen.drawStyledText(4 + width.displayWidth(title), top, " ", .{});
    }
    const y = top + 1;
    switch (app.overlay) {
        .none => return editor_view.draw(screen, app.editor.text(), app.editor.cursor, y, content),
        .help => {
            var row = y;
            for (registry.keybinds.items) |k| {
                const command = registry.command(k.command) orelse continue;
                var buf: [96]u8 = undefined;
                screen.drawText(1, row, std.fmt.bufPrint(&buf, "Ctrl-{c}", .{std.ascii.toUpper(k.ctrl)}) catch "");
                screen.drawStyledText(14, row, command.description, .{ .dim = true });
                row += 1;
            }
            for (fixed_keys) |key| {
                screen.drawText(1, row, key[0]);
                screen.drawStyledText(14, row, key[1], .{ .dim = true });
                row += 1;
            }
            screen.drawStyledText(1, row, "Type / for commands and @ for files. Esc closes.", .{ .dim = true });
        },
        .permission => if (app.permission) |p| {
            screen.drawStyledText(1, y, "Allow this?", .{ .foreground = screen_mod.Color.yellow, .bold = true });
            screen.drawStyledText(1, y + 1, p.action, .{ .bold = true });
            screen.drawText(1, y + 2, p.pattern);
            screen.drawStyledText(1, y + 3, "1 allow once · 2 allow for this session · 3 deny", .{ .dim = true });
        },
        .connect_key => {
            screen.drawStyledText(1, y, "Paste the key (hidden) · Enter save · Esc cancel", .{ .dim = true });
            const count = @min(app.connect_secret.items.len, screen.cols -| 2);
            for (0..count) |i| screen.drawText(i + 1, y + 1, "•");
            return .{ .x = @min(1 + count, screen.cols - 1), .y = y + 1 };
        },
        .connect_oauth => {
            screen.drawStyledText(1, y, "Enter opens the URL · Esc cancel · ←/→ URL · ↑/↓ code", .{ .dim = true });
            if (app.connect_flow) |flow| {
                app.connect_page_width = screen.cols -| 6;
                screen.drawStyledText(1, y + 1, "URL", .{ .dim = true });
                screen.drawText(6, y + 1, page(flow.url, app.connect_url_offset, app.connect_page_width));
                screen.drawStyledText(1, y + 2, "Code", .{ .dim = true });
                screen.drawText(6, y + 2, page(flow.instructions, app.connect_instructions_offset, app.connect_page_width));
                screen.drawStyledText(1, y + 3, "Waiting for authorization…", .{ .dim = true });
            } else screen.drawStyledText(1, y + 1, "Starting login…", .{ .dim = true });
        },
        .models, .thinking, .sessions, .pending, .connect_providers, .connect_methods => {
            if (app.picker_query.items.len == 0)
                screen.drawStyledText(1, y, if (app.picker_waiting) "Loading…" else "Type to search", .{ .dim = true })
            else
                screen.drawText(1, y, app.picker_query.items);
            const result = try picker.render(screen.allocator, app.picker_items, app.picker_query.items, app.picker_selected, content -| 1, screen.cols -| 1);
            defer result.deinit(screen.allocator);
            for (result.lines, 0..) |line, i| {
                if (app.picker_waiting and app.picker_items.len == 0) break;
                var x: usize = 1;
                for (line.spans) |span| {
                    screen.drawStyledText(x, y + 1 + i, span.text, terminal_style.styleFor(span.style));
                    x += presentation.columns(span.text);
                }
                if (line.spans.len > 0 and line.spans[0].style == .selected) screen.fill(0, y + 1 + i, palette.selected);
            }
            return .{ .x = @min(1 + presentation.columns(app.picker_query.items), screen.cols - 1), .y = y };
        },
    }
    return .{ .x = 1, .y = y };
}

const fixed_keys = [_][2][]const u8{
    .{ "Enter", "Send (steers a running turn)" },
    .{ "Alt-Enter", "Queue after the running turn" },
    .{ "Ctrl-J", "New line" },
    .{ "Esc", "Stop the turn; close lists" },
    .{ "Ctrl-C", "Clear the input" },
    .{ "PgUp/PgDn", "Scroll; End jumps to the latest" },
};

fn helpLines(registry: *const plugin.Registry) usize {
    return registry.keybinds.items.len + fixed_keys.len;
}

/// A clipped, UTF-8-aligned page; arrow keys move the window on small terminals.
pub fn page(text: []const u8, requested: usize, columns: usize) []const u8 {
    var start: usize = 0;
    while (start < @min(requested, text.len)) start = width.clusterEnd(text, start);
    var end = start;
    var used: usize = 0;
    while (end < text.len) {
        const next = width.clusterEnd(text, end);
        const cells = width.displayWidth(text[end..next]);
        if (used + cells > columns) break;
        used += cells;
        end = next;
    }
    return text[start..end];
}
