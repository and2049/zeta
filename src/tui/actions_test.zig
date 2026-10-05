//! More tests for `actions.zig`: questions, the selection and shell mode.
const std = @import("std");
const App = @import("App.zig");
const plugin = @import("plugin.zig");
const actions = @import("actions.zig");
const completion = @import("app_completion.zig");
const handle = actions.handle;
const Request = actions.Request;

test "Escape leaves shell mode, then stops the running command, then the turn" {
    var r = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins);
    defer r.deinit();
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    const a = std.testing.allocator;
    app.running = true;
    app.shell.set("sleep 9", 1);
    _ = try handle(&app, &r, a, .{ .text = '!' });
    // A path is not a slash command here.
    _ = try handle(&app, &r, a, .{ .text = '/' });
    try std.testing.expect((try completion.current(&app, &r, a)) == null);
    try std.testing.expectEqual(Request.none, try handle(&app, &r, a, .{ .key = .escape }));
    try std.testing.expect(!app.shell.mode);
    app.clearInput();
    try std.testing.expectEqual(Request.stop_shell, try handle(&app, &r, a, .{ .key = .escape }));
    app.shell.set(null, 0);
    try std.testing.expectEqual(Request.abort, try handle(&app, &r, a, .{ .key = .escape }));
    _ = try handle(&app, &r, a, .{ .text = '!' });
    _ = try handle(&app, &r, a, .{ .key = .clear });
    try std.testing.expect(!app.shell.mode);
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
