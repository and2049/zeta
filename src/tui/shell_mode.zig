//! The editor's shell mode (`!` in an empty editor: Enter runs the text as
//! a command) and the command running for the session.
const std = @import("std");
const App = @import("App.zig");
const input = @import("input.zig");
const Request = @import("actions.zig").Request;
const width = @import("width.zig");

/// Columns the `!` marker takes before the editor's text.
pub const marker_columns = 2;

pub const State = struct {
    /// The editor holds a command, not a prompt.
    mode: bool = false,
    /// The session's command in progress, for the working row: when it
    /// started (epoch ms) and its first line, cut to fit.
    started: ?i64 = null,
    buffer: [96]u8 = undefined,
    len: usize = 0,

    pub fn command(s: *const State) []const u8 {
        return s.buffer[0..s.len];
    }

    /// Sets or clears the running command.
    pub fn set(s: *State, running: ?[]const u8, started: i64) void {
        const text = running orelse {
            s.started = null;
            return;
        };
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        var end: usize = 0;
        while (end < line.len) {
            const next = width.clusterEnd(line, end);
            if (next > s.buffer.len) break;
            end = next;
        }
        @memcpy(s.buffer[0..end], line[0..end]);
        s.len = end;
        s.started = started;
    }
};

/// Keys while the editor may be or is in shell mode; null when the event
/// is not for it. Returned strings belong to `arena`.
pub fn handle(app: *App, arena: std.mem.Allocator, ev: input.Event) !?Request {
    const s = &app.shell;
    if (!s.mode) {
        if (ev == .text and ev.text == '!' and app.editor.text().len == 0) {
            s.mode = true;
            return .none;
        }
        return null;
    }
    switch (ev) {
        .paste, .text => try app.editor.apply(ev),
        .key => |key| switch (key) {
            .backspace, .word_backspace => if (app.editor.text().len == 0) {
                s.mode = false;
            } else try app.editor.apply(ev),
            .enter, .queue => {
                const text = std.mem.trim(u8, app.editor.text(), " \t\r\n");
                if (text.len == 0) return .none;
                const command = try arena.dupe(u8, text);
                app.editor.clear();
                s.mode = false;
                return .{ .shell = command };
            },
            .up, .down, .newline, .delete, .left, .right, .home, .end, .word_left, .word_right, .word_delete, .tab => try app.editor.apply(ev),
            else => {},
        },
        else => {},
    }
    return .none;
}

test "! in an empty editor starts shell mode; Enter runs the text and leaves it" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try handle(&app, a, .{ .text = 'l' }) == null);
    try app.editor.insert("hi");
    // Not at the start: an ordinary character.
    try std.testing.expect(try handle(&app, a, .{ .text = '!' }) == null);
    app.editor.clear();
    try std.testing.expectEqual(Request.none, (try handle(&app, a, .{ .text = '!' })).?);
    try std.testing.expect(app.shell.mode);
    try std.testing.expectEqualStrings("", app.editor.text());
    // Nothing typed: Enter does nothing, Backspace leaves the mode.
    try std.testing.expectEqual(Request.none, (try handle(&app, a, .{ .key = .enter })).?);
    _ = try handle(&app, a, .{ .key = .backspace });
    try std.testing.expect(!app.shell.mode);

    _ = try handle(&app, a, .{ .text = '!' });
    for ("/bin/ls -l") |c| _ = try handle(&app, a, .{ .text = c });
    _ = try handle(&app, a, .{ .key = .backspace });
    try std.testing.expect(app.shell.mode);
    const request = (try handle(&app, a, .{ .key = .enter })).?;
    try std.testing.expectEqualStrings("/bin/ls -", request.shell);
    try std.testing.expect(!app.shell.mode);
    try std.testing.expectEqualStrings("", app.editor.text());
}

test "the running command is kept as one clipped line" {
    var s: State = .{};
    s.set("echo one\necho two", 5);
    try std.testing.expectEqualStrings("echo one", s.command());
    try std.testing.expectEqual(@as(?i64, 5), s.started);
    s.set("x" ** 95 ++ "界界", 6);
    try std.testing.expectEqual(@as(usize, 95), s.len);
    s.set(null, 0);
    try std.testing.expect(s.started == null);
}
