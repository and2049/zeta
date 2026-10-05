//! Input decisions are instantaneous: the run loop dispatches requests later.
const std = @import("std");
const App = @import("App.zig");
const input = @import("input.zig");
const plugin = @import("plugin.zig");
const picker = @import("picker.zig");
const completion = @import("app_completion.zig");

pub const Request = union(enum) {
    none,
    /// Run a registered command.
    command: struct { name: []const u8, arguments: []const u8 = "" },
    list_providers,
    select_provider: []const u8,
    select_method: []const u8,
    save_key,
    cancel_flow: []const u8,
    open_auth_url: []const u8,
    select_session: []const u8,
    select_model: []const u8,
    select_thinking: []const u8,
    remove_inbox: []const u8,
    edit_pending: struct { id: []const u8, text: []const u8 },
    /// The `@` word changed: search the workspace for it.
    search_files: []const u8,
    /// The `/` list opened: fetch prompt templates.
    list_templates,
    /// A directory argument moved to another folder: list it (as typed).
    list_directories: []const u8,
    send: struct { text: []const u8, delivery: enum { queue, steer } },
    abort,
    answer_question: struct { id: []const u8, action: []const u8, content: ?std.json.Value },
    older,
    /// Put the selected transcript text on the clipboard.
    copy_selection,
};

/// Returned strings are owned by the caller's request arena.
pub fn handle(app: *App, registry: *const plugin.Registry, arena: std.mem.Allocator, ev: input.Event) !Request {
    if (ev == .mouse) return @import("actions_mouse.zig").handle(app, ev.mouse);
    // Any key but scrolling drops the selection; Escape does only that.
    const scrolling = ev == .wheel or ev == .ignored or ev == .key and (ev.key == .page_up or ev.key == .page_down or ev.key == .follow_end);
    if (!scrolling and app.selection.anchor != null) {
        const selected = app.selection.active();
        app.selection.clear();
        if (selected and ev == .key and ev.key == .escape) return .none;
    }
    if (ev == .key and ev.key == .escape and app.overlay == .question) {
        if (app.questions.items.items.len > 0) return .{ .answer_question = .{ .id = app.questions.items.items[0].question.id, .action = "decline", .content = null } };
        app.overlay = .none;
        return .none;
    }
    switch (ev) {
        .wheel => |direction| {
            if (direction < 0) app.scrollUp(3) else app.scrollDown(3);
            return .none;
        },
        .ctrl => |letter| {
            // Only quitting while typing a secret or answering a question.
            if ((app.overlay == .connect_key or app.overlay == .question) and letter != 'q') return .none;
            const c = registry.bound(letter) orelse return .none;
            return .{ .command = .{ .name = c.name } };
        },
        .key => |key| switch (key) {
            .clear => {
                if (app.overlay == .connect_key) app.clearSecret() else app.clearInput();
                return .none;
            },
            .page_up => {
                app.scrollUp(10);
                return .older;
            },
            .page_down => {
                app.scrollDown(10);
                return .none;
            },
            .follow_end => {
                app.scroll = 0;
                app.follow_end = true;
                return .none;
            },
            .escape => {
                if (app.overlay != .none) {
                    if (app.overlay == .connect_key) app.clearSecret();
                    const flow = if (app.overlay == .connect_oauth and app.connect_flow != null) app.connect_flow.?.id else null;
                    app.overlay = if (app.questions.items.items.len > 0) .question else .none;
                    app.picker_confirm_pending = false;
                    if (flow) |id| return .{ .cancel_flow = id };
                    return .none;
                }
                const token = completion.tokenAt(app, registry);
                if (app.completion.open(token)) {
                    app.completion.dismissed = token;
                    return .none;
                }
                if (app.running) return .abort;
                return .none;
            },
            else => {},
        },
        else => {},
    }
    if (app.overlay == .question) {
        if (app.questions.items.items.len == 0) {
            app.overlay = .none;
            return .none;
        }
        const entry = &app.questions.items.items[0];
        const renderer = registry.questionRenderer(entry.question.kind) orelse return .none;
        if (try renderer.handle(entry, ev)) |answer| return .{ .answer_question = .{ .id = entry.question.id, .action = answer.action, .content = answer.content } };
        return .none;
    }
    if (app.overlay != .none) return @import("actions_overlay.zig").handle(app, arena, ev);
    if (try completion.current(app, registry, arena)) |list| if (try completing(app, registry, arena, ev, list)) |request| return request;
    switch (ev) {
        .paste, .text => try app.editor.apply(ev),
        .key => |key| switch (key) {
            .up, .down, .newline, .backspace, .delete, .left, .right, .home, .end, .word_left, .word_right, .word_backspace, .word_delete, .tab => try app.editor.apply(ev),
            .queue => {
                const text = std.mem.trim(u8, app.editor.text(), " \t\r\n");
                if (text.len == 0 and app.attachments.items.len == 0 and app.embedded_images.items.len == 0) return .none;
                return .{ .send = .{ .text = try arena.dupe(u8, text), .delivery = .queue } };
            },
            .enter => return submit(app, registry, arena),
            else => {},
        },
        else => {},
    }
    return changed(app, registry, arena);
}

/// Enter: a registered slash command runs; anything else is sent (the
/// worker routes a prompt template to its command).
fn submit(app: *App, registry: *const plugin.Registry, arena: std.mem.Allocator) !Request {
    const text = std.mem.trim(u8, app.editor.text(), " \t\r\n");
    if (text.len == 0 and app.attachments.items.len == 0 and app.embedded_images.items.len == 0) return .none;
    if (text.len > 1 and text[0] == '/') {
        const space = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
        if (registry.command(text[1..space])) |c| if (c.slash) {
            const arguments = try arena.dupe(u8, std.mem.trim(u8, text[space..], " \t\r\n"));
            app.editor.clear();
            return .{ .command = .{ .name = c.name, .arguments = arguments } };
        };
    }
    return .{ .send = .{ .text = try arena.dupe(u8, text), .delivery = if (app.running) .steer else .queue } };
}

/// Keys the open completion list takes: moving the highlight, Tab to insert
/// it, Enter to insert it and run a command that needs no arguments.
fn completing(app: *App, registry: *const plugin.Registry, arena: std.mem.Allocator, ev: input.Event, list: completion.Current) !?Request {
    if (ev != .key) return null;
    switch (ev.key) {
        .up, .down => if (list.indices.len > 0) {
            app.completion.move(if (ev.key == .up) -1 else 1, list.indices.len);
            return .none;
        },
        .tab, .enter => {
            const item = list.chosen() orelse return null;
            const editor = &app.editor;
            if (list.token.kind == .file) {
                while (editor.cursor > list.token.start + 1) try editor.apply(.{ .key = .backspace });
                try editor.insert(item.id);
                try editor.insert(" ");
                return try changed(app, registry, arena);
            }
            if (list.token.kind == .directory) {
                // Enter after a finished path (`dir/`, `.`, `..`) runs it as typed.
                const prefix = @import("completion.zig").splitPath(list.token.query).prefix;
                if (ev.key == .enter and (prefix.len == 0 or std.mem.eql(u8, prefix, ".") or std.mem.eql(u8, prefix, ".."))) return null;
                while (editor.cursor > list.token.start) try editor.apply(.{ .key = .backspace });
                try editor.insert(item.id);
                if (ev.key == .enter) return try submit(app, registry, arena);
                return try changed(app, registry, arena);
            }
            const name = item.id[1..];
            const takes_arguments = std.mem.indexOfScalar(u8, item.label, ' ') != null;
            editor.clear();
            try editor.insert(item.id);
            if (ev.key == .tab or takes_arguments and registry.command(name) == null or required(item.label)) {
                try editor.insert(" ");
                return try changed(app, registry, arena);
            }
            return try submit(app, registry, arena);
        },
        else => {},
    }
    return null;
}

/// The label's argument hint is required (`<path>`, not `[focus]`).
fn required(label: []const u8) bool {
    const space = std.mem.indexOfScalar(u8, label, ' ') orelse return false;
    return label.len > space + 1 and label[space + 1] == '<';
}

/// After an edit: fetch what the completion list now needs.
fn changed(app: *App, registry: *const plugin.Registry, arena: std.mem.Allocator) !Request {
    const token = completion.tokenAt(app, registry);
    const was = app.completion.last_kind;
    if (!app.completion.observe(token)) return .none;
    return switch (token.kind) {
        .none => .none,
        .file => .{ .search_files = try arena.dupe(u8, token.query) },
        .command => if (was != .command) .list_templates else .none,
        .directory => {
            const parent = @import("completion.zig").splitPath(token.query).parent;
            if (app.directory_parent) |listed| if (std.mem.eql(u8, listed, parent)) return .none;
            return .{ .list_directories = try arena.dupe(u8, parent) };
        },
    };
}

test "control keys, steer, and Ctrl+C never quits" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    const a = std.testing.allocator;
    try app.appendText("hello");
    app.running = true;
    const request = try handle(&app, &r, a, .{ .key = .enter });
    defer a.free(request.send.text);
    try std.testing.expectEqualStrings("hello", request.send.text);
    try std.testing.expectEqual(.steer, request.send.delivery);
    _ = try handle(&app, &r, a, .{ .key = .clear });
    try std.testing.expectEqualStrings("", app.editor.text());
    try std.testing.expectEqualStrings("quit", (try handle(&app, &r, a, .{ .ctrl = 'q' })).command.name);
}

test "slash completion opens while typing; Tab inserts and Enter runs" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Request.list_templates, try handle(&app, &r, a, .{ .text = '/' }));
    for ("ren") |c| _ = try handle(&app, &r, a, .{ .text = c });
    _ = try handle(&app, &r, a, .{ .key = .tab });
    try std.testing.expectEqualStrings("/rename ", app.editor.text());
    app.clearInput();
    for ("/mod") |c| _ = try handle(&app, &r, a, .{ .text = c });
    const run = try handle(&app, &r, a, .{ .key = .enter });
    try std.testing.expectEqualStrings("model", run.command.name);
    try std.testing.expectEqualStrings("", app.editor.text());
}

test "a slash name that is not registered is sent for the worker to route" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    const a = std.testing.allocator;
    try app.appendText("/review src 'two words'");
    const request = try handle(&app, &r, a, .{ .key = .enter });
    defer a.free(request.send.text);
    try std.testing.expectEqualStrings("/review src 'two words'", request.send.text);
}

test "a /cd argument completes directories: Tab descends, Enter runs" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/work/project");
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ("/cd ../o") |c| _ = try handle(&app, &r, a, .{ .text = c });
    // The listing for "../" arrives.
    app.directories = &.{ .{ .id = "../other/", .label = "other/" }, .{ .id = "../.hidden/", .label = ".hidden/" }, .{ .id = "../zeta/", .label = "zeta/" } };
    app.directory_parent = "../";
    const list = (try completion.current(&app, &r, a)).?;
    try std.testing.expectEqual(@as(usize, 1), list.indices.len);
    const descend = try handle(&app, &r, a, .{ .key = .tab });
    try std.testing.expectEqualStrings("/cd ../other/", app.editor.text());
    try std.testing.expectEqualStrings("../other/", descend.list_directories);
    const run = try handle(&app, &r, a, .{ .key = .enter });
    try std.testing.expectEqualStrings("cd", run.command.name);
    try std.testing.expectEqualStrings("../other/", run.command.arguments);
}

test "escape hides the completion list before it aborts" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    app.running = true;
    _ = try handle(&app, &r, arena.allocator(), .{ .text = '/' });
    try std.testing.expectEqual(Request.none, try handle(&app, &r, arena.allocator(), .{ .key = .escape }));
    try std.testing.expectEqual(Request.abort, try handle(&app, &r, arena.allocator(), .{ .key = .escape }));
}

test {
    _ = picker;
    _ = @import("actions_mouse.zig");
}

test "a key drops the selection, and Escape does nothing else then" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    const a = std.testing.allocator;
    app.running = true;
    app.selection.viewport = .{ .first = 0, .height = 5, .start = 0, .total = 5 };
    for (0..2) |_| {
        _ = try handle(&app, &r, a, .{ .mouse = .{ .kind = .press, .button = .left, .x = 1, .y = 1 } });
        _ = try handle(&app, &r, a, .{ .mouse = .{ .kind = .drag, .button = .left, .x = 4, .y = 1 } });
        try std.testing.expectEqual(Request.copy_selection, try handle(&app, &r, a, .{ .mouse = .{ .kind = .release, .button = .left, .x = 4, .y = 1 } }));
        _ = try handle(&app, &r, a, .{ .wheel = -1 });
        try std.testing.expect(app.selection.active());
        try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .key = .escape }));
        try std.testing.expect(!app.selection.active());
    }
    try std.testing.expectEqual(Request.abort, try handle(&app, &r, a, .{ .key = .escape }));
    _ = try handle(&app, &r, a, .{ .mouse = .{ .kind = .press, .button = .left, .x = 1, .y = 1 } });
    _ = try handle(&app, &r, a, .{ .mouse = .{ .kind = .drag, .button = .left, .x = 4, .y = 1 } });
    _ = try handle(&app, &r, a, .{ .text = 'x' });
    try std.testing.expect(!app.selection.active());
    try std.testing.expectEqualStrings("x", app.editor.text());
}

test "question keys answer confirm, select, input and validate form" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    app.session = "s";
    try app.setSessionLocation("/tmp");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const samples = [_][]const u8{
        \\{"id":"c","kind":"confirm","source":"hook","message":"Allow?"}
        ,
        \\{"id":"s","kind":"select","source":"hook","message":"Pick","options":[{"value":"one"},{"value":"two"}]}
        ,
        \\{"id":"i","kind":"input","source":"hook","message":"Name","secret":true}
        ,
        \\{"id":"f","kind":"form","source":"hook","message":"Config","schema":{"properties":{"count":{"type":"integer","title":"Count"},"mode":{"type":"string","enum":["safe","fast"]}},"required":["count"]}}
        ,
    };
    for (samples) |sample| try app.ask(try std.json.parseFromSliceLeaky(std.json.Value, a, sample, .{}), "s", null);
    try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .ctrl = 'c' }));
    try std.testing.expectEqualStrings("quit", (try handle(&app, &r, a, .{ .ctrl = 'q' })).command.name);
    try std.testing.expectEqualStrings("accept", (try handle(&app, &r, a, .{ .text = 'y' })).answer_question.action);
    app.resolve("c");
    _ = try handle(&app, &r, a, .{ .key = .down });
    try std.testing.expectEqualStrings("two", (try handle(&app, &r, a, .{ .key = .enter })).answer_question.content.?.string);
    try std.testing.expectEqualStrings("one", (try handle(&app, &r, a, .{ .text = '1' })).answer_question.content.?.string);
    app.resolve("s");
    _ = try handle(&app, &r, a, .{ .text = 'é' });
    _ = try handle(&app, &r, a, .{ .key = .backspace });
    _ = try handle(&app, &r, a, .{ .text = 'x' });
    try std.testing.expectEqualStrings("x", (try handle(&app, &r, a, .{ .key = .enter })).answer_question.content.?.string);
    app.resolve("i");
    _ = try handle(&app, &r, a, .{ .text = 'x' });
    try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .key = .enter }));
    try std.testing.expect(app.questions.items.items[0].invalid);
    _ = try handle(&app, &r, a, .{ .key = .backspace });
    _ = try handle(&app, &r, a, .{ .text = '3' });
    try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .key = .enter }));
    for ("unsafe") |ch| _ = try handle(&app, &r, a, .{ .text = ch });
    try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .key = .enter }));
    for (0..6) |_| _ = try handle(&app, &r, a, .{ .key = .backspace });
    for ("safe") |ch| _ = try handle(&app, &r, a, .{ .text = ch });
    const result = (try handle(&app, &r, a, .{ .key = .enter })).answer_question;
    try std.testing.expectEqualStrings("accept", result.action);
    try std.testing.expectEqual(@as(i64, 3), result.content.?.object.get("count").?.integer);
    try std.testing.expectEqualStrings("safe", result.content.?.object.get("mode").?.string);
    try std.testing.expectEqualStrings("decline", (try handle(&app, &r, a, .{ .key = .escape })).answer_question.action);
}
