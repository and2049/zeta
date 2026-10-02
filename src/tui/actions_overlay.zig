//! Keys while the dock shows something other than the editor: a picker, a
//! provider sign-in step.
const std = @import("std");
const App = @import("App.zig");
const input = @import("input.zig");
const picker = @import("picker.zig");
const width = @import("width.zig");
const Request = @import("actions.zig").Request;

pub fn handle(app: *App, arena: std.mem.Allocator, ev: input.Event) !Request {
    switch (app.overlay) {
        .none, .help, .question => return .none,
        .connect_oauth => return oauth(app, ev),
        .connect_key => return secret(app, ev),
        .models, .thinking, .sessions, .pending, .connect_providers, .connect_methods => return choose(app, arena, ev),
    }
}

fn oauth(app: *App, ev: input.Event) Request {
    if (ev != .key) return .none;
    const flow = app.connect_flow orelse return .none;
    const page = @max(@as(usize, 1), app.connect_page_width);
    switch (ev.key) {
        .enter => return .{ .open_auth_url = flow.url },
        .left => app.connect_url_offset = app.connect_url_offset -| page,
        .right => app.connect_url_offset = @min(flow.url.len, app.connect_url_offset +| page),
        .up => app.connect_instructions_offset = app.connect_instructions_offset -| page,
        .down => app.connect_instructions_offset = @min(flow.instructions.len, app.connect_instructions_offset +| page),
        .home => app.connect_url_offset = 0,
        .end => app.connect_url_offset = flow.url.len -| page,
        else => {},
    }
    return .none;
}

fn secret(app: *App, ev: input.Event) !Request {
    switch (ev) {
        .text => |cp| {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try app.connect_secret.appendSlice(app.allocator, buf[0..n]);
        },
        .paste => |text| try app.connect_secret.appendSlice(app.allocator, text),
        .key => |key| switch (key) {
            .backspace => if (app.connect_secret.items.len > 0) {
                const bytes = app.connect_secret.items;
                const boundary = lastCluster(bytes);
                @memset(bytes[boundary..], 0);
                app.connect_secret.items.len = boundary;
            },
            .enter => if (app.connect_secret.items.len > 0) return .save_key,
            else => {},
        },
        else => {},
    }
    return .none;
}

fn lastCluster(bytes: []const u8) usize {
    var boundary: usize = 0;
    while (width.clusterEnd(bytes, boundary) < bytes.len) boundary = width.clusterEnd(bytes, boundary);
    return boundary;
}

fn choose(app: *App, arena: std.mem.Allocator, ev: input.Event) !Request {
    switch (ev) {
        .text => |cp| {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try app.picker_query.appendSlice(app.allocator, buf[0..n]);
            app.picker_selected = 0;
        },
        .key => |k| switch (k) {
            .backspace => if (app.picker_query.items.len > 0) {
                app.picker_query.items.len = lastCluster(app.picker_query.items);
                app.picker_selected = 0;
            },
            .up => app.picker_selected -|= 1,
            // Stops at the last match, so Up moves again at once.
            .down => {
                const rendered = try picker.render(arena, app.picker_items, app.picker_query.items, app.picker_selected, 0, 80);
                defer rendered.deinit(arena);
                if (app.picker_selected + 1 < rendered.indices.len) app.picker_selected += 1;
            },
            .delete => if (app.overlay == .pending) {
                const item = try selected(app, arena) orelse return .none;
                return .{ .remove_inbox = item.id };
            },
            .enter => {
                if (app.picker_waiting) {
                    app.picker_confirm_pending = true;
                    return .none;
                }
                const item = try selected(app, arena) orelse return .none;
                const previous = app.overlay;
                app.overlay = if (app.questions.items.items.len > 0) .question else .none;
                return switch (previous) {
                    .sessions => .{ .select_session = item.id },
                    .models => .{ .select_model = item.id },
                    .thinking => .{ .select_thinking = item.id },
                    .connect_providers => .{ .select_provider = item.id },
                    .connect_methods => .{ .select_method = item.id },
                    .pending => if (app.session != null) .{ .edit_pending = .{ .id = item.id, .text = item.label } } else .none,
                    else => .none,
                };
            },
            else => {},
        },
        else => {},
    }
    return .none;
}

fn selected(app: *App, arena: std.mem.Allocator) !?picker.Item {
    const rendered = try picker.render(arena, app.picker_items, app.picker_query.items, app.picker_selected, 10, 80);
    defer rendered.deinit(arena);
    if (rendered.indices.len == 0) return null;
    return app.picker_items[rendered.indices[rendered.selected]];
}

test "connect key input stays separate from the draft" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    try app.editor.insert("original draft");
    app.overlay = .connect_key;
    _ = try handle(&app, std.testing.allocator, .{ .paste = @constCast("secret-value") });
    try std.testing.expectEqualStrings("secret-value", app.connect_secret.items);
    try std.testing.expectEqualStrings("original draft", app.editor.text());
    try std.testing.expect(try handle(&app, std.testing.allocator, .{ .key = .enter }) == .save_key);
}

test "a picker returns the highlighted item" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    app.openPicker(.thinking, false);
    app.picker_items = &@import("plugins/session.zig").levels;
    _ = try handle(&app, std.testing.allocator, .{ .text = 'h' });
    const choice = try handle(&app, std.testing.allocator, .{ .key = .enter });
    try std.testing.expectEqualStrings("high", choice.select_thinking);
    try std.testing.expectEqual(App.Overlay.none, app.overlay);
}
