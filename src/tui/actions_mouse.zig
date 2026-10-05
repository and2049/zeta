//! Mouse buttons: dragging selects transcript text.
const std = @import("std");
const App = @import("App.zig");
const input = @import("input.zig");
const Request = @import("actions.zig").Request;

pub fn handle(app: *App, mouse: input.Mouse) Request {
    const s = &app.selection;
    switch (mouse.button) {
        .left => {},
        .middle => return .none,
        .right => return if (mouse.kind == .press and !s.copy_on_release and s.active()) .copy_selection else .none,
    }
    switch (mouse.kind) {
        .press => s.press(mouse.x, mouse.y),
        .drag => s.drag(mouse.x, mouse.y),
        .release => if (s.release() and s.copy_on_release) return .copy_selection,
    }
    return .none;
}

/// While a drag is held past the transcript's edge: scrolls a row at a
/// time and extends the selection. Call on every frame.
pub fn tick(app: *App) void {
    const s = &app.selection;
    if (!s.dragging or s.autoscroll == 0 or s.now_ms - s.scrolled_ms < 40) return;
    s.scrolled_ms = s.now_ms;
    const vp = &s.viewport;
    if (s.autoscroll < 0) {
        if (vp.start == 0) return;
        app.scrollUp(1);
        vp.start -= 1;
        s.head.line = vp.start;
    } else {
        const end = vp.start + vp.height;
        if (end >= vp.total) return;
        app.scrollDown(1);
        vp.start += 1;
        s.head.line = end;
    }
    s.moved = true;
}

test "release copies when set to; otherwise a right click does" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    app.selection.viewport = .{ .first = 0, .height = 5, .start = 0, .total = 5 };
    try std.testing.expectEqual(Request.none, handle(&app, .{ .kind = .press, .button = .left, .x = 1, .y = 1 }));
    _ = handle(&app, .{ .kind = .drag, .button = .left, .x = 6, .y = 1 });
    try std.testing.expectEqual(Request.copy_selection, handle(&app, .{ .kind = .release, .button = .left, .x = 6, .y = 1 }));
    try std.testing.expectEqual(Request.none, handle(&app, .{ .kind = .press, .button = .right, .x = 6, .y = 1 }));

    app.selection.copy_on_release = false;
    _ = handle(&app, .{ .kind = .press, .button = .left, .x = 1, .y = 1 });
    _ = handle(&app, .{ .kind = .drag, .button = .left, .x = 6, .y = 1 });
    try std.testing.expectEqual(Request.none, handle(&app, .{ .kind = .release, .button = .left, .x = 6, .y = 1 }));
    try std.testing.expectEqual(Request.copy_selection, handle(&app, .{ .kind = .press, .button = .right, .x = 6, .y = 1 }));
}

test "a drag held above the transcript scrolls it and extends the selection" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    app.selection.viewport = .{ .first = 1, .height = 4, .start = 10, .total = 30 };
    _ = handle(&app, .{ .kind = .press, .button = .left, .x = 1, .y = 2 });
    _ = handle(&app, .{ .kind = .drag, .button = .left, .x = 1, .y = 0 });
    app.selection.now_ms = 100;
    tick(&app);
    tick(&app); // too soon
    try std.testing.expectEqual(@as(usize, 1), app.scroll);
    try std.testing.expectEqual(@as(usize, 9), app.selection.head.line);
    try std.testing.expect(!app.follow_end);
}
