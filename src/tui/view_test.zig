const std = @import("std");
const App = @import("App.zig");
const Screen = @import("screen.zig").Screen;
const plugin = @import("plugin.zig");
const view = @import("view.zig");
const dock = @import("view_dock.zig");

const Fixture = struct {
    registry: plugin.Registry,
    app: App,
    screen: Screen,

    fn init(cols: usize, rows: usize) !Fixture {
        return .{
            .registry = try plugin.Registry.init(std.testing.allocator, &@import("builtins.zig").plugins),
            .app = App.init(std.testing.allocator, "/home/me/project"),
            .screen = try Screen.init(std.testing.allocator, cols, rows),
        };
    }
    fn deinit(f: *Fixture) void {
        f.screen.deinit();
        f.app.deinit();
        f.registry.deinit();
    }
    fn draw(f: *Fixture) !void {
        const bytes = try view.draw(&f.screen, &f.app, .{ .registry = &f.registry });
        std.testing.allocator.free(bytes);
    }
    /// Row `y` as text, trailing blanks removed; caller frees.
    fn row(f: *Fixture, y: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (f.screen.cells[y * f.screen.cols .. (y + 1) * f.screen.cols]) |cell| {
            if (!cell.continuation) try out.appendSlice(std.testing.allocator, cell.glyph[0..cell.len]);
        }
        const trimmed = std.mem.trimEnd(u8, out.items, " ");
        out.items.len = trimmed.len;
        return out.toOwnedSlice(std.testing.allocator);
    }
    fn contains(f: *Fixture, needle: []const u8) !bool {
        for (0..f.screen.rows) |y| {
            const text = try f.row(y);
            defer std.testing.allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return true;
        }
        return false;
    }
};

test "layout: welcome, full-width rules, footer" {
    var f = try Fixture.init(60, 16);
    defer f.deinit();
    f.app.connected = true;
    f.app.title = "Greeting";
    f.app.home = "/home/me";
    f.app.branch = "main";
    f.app.model = "openai/gpt";
    f.app.status = "";
    try f.draw();
    // No top bar: the first row is blank and the title is not shown.
    const top = try f.row(0);
    defer std.testing.allocator.free(top);
    try std.testing.expectEqualStrings("", top);
    try std.testing.expect(!try f.contains("Greeting"));
    // Both rules span the whole width, around one editor row.
    for ([_]usize{ 11, 13 }) |y| {
        const rule = try f.row(y);
        defer std.testing.allocator.free(rule);
        try std.testing.expectEqual(@as(usize, 60 * "─".len), rule.len);
    }
    const first = try f.row(14);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings(" ~/project (main)", first);
    try std.testing.expect(try f.contains("openai/gpt"));
    // Too short for the logo: name and keys only.
    try std.testing.expect(try f.contains("zeta v"));
    try std.testing.expect(try f.contains("commands"));
    try std.testing.expect(!try f.contains("⣿"));
}

test "a tall empty conversation shows the name and keys beside the logo" {
    var f = try Fixture.init(80, 40);
    defer f.deinit();
    try f.draw();
    var beside = false;
    for (0..40) |y| {
        const text = try f.row(y);
        defer std.testing.allocator.free(text);
        const name = std.mem.indexOf(u8, text, "zeta v") orelse continue;
        beside = std.mem.indexOf(u8, text[0..name], "⣿") != null;
    }
    try std.testing.expect(beside);
    try std.testing.expect(try f.contains("/project"));
}

test "the completion list covers the logo instead of dropping it" {
    var f = try Fixture.init(80, 32);
    defer f.deinit();
    try f.app.editor.insert("/");
    try f.draw();
    try std.testing.expect(try f.contains("/model"));
    var beside = false;
    for (0..32) |y| {
        const text = try f.row(y);
        defer std.testing.allocator.free(text);
        const name = std.mem.indexOf(u8, text, "zeta v") orelse continue;
        beside = std.mem.indexOf(u8, text[0..name], "⣿") != null;
    }
    try std.testing.expect(beside);
}

test "a narrow empty conversation drops the logo" {
    var f = try Fixture.init(50, 40);
    defer f.deinit();
    try f.draw();
    try std.testing.expect(!try f.contains("⣿"));
    try std.testing.expect(try f.contains("zeta v"));
}

test "user messages get the surface background, without labels" {
    var f = try Fixture.init(40, 14);
    defer f.deinit();
    try f.app.appendMessage("user", "hello");
    try f.app.appendMessage("assistant", "Hi there");
    try f.draw();
    try std.testing.expect(!try f.contains("You"));
    var user_row: ?usize = null;
    for (0..14) |y| {
        const text = try f.row(y);
        defer std.testing.allocator.free(text);
        if (std.mem.eql(u8, text, " hello")) user_row = y;
    }
    const y = user_row.?;
    const surface = (@import("palette.zig").Palette{}).surface;
    try std.testing.expectEqual(surface, f.screen.cells[y * 40 + 39].style.background);
    try std.testing.expectEqual(surface, f.screen.cells[(y - 1) * 40].style.background);
}

test "typing / lists commands above the editor with the first highlighted" {
    var f = try Fixture.init(60, 20);
    defer f.deinit();
    try f.app.editor.insert("/mo");
    try f.draw();
    try std.testing.expect(try f.contains("/model"));
    try std.testing.expect(try f.contains("Choose the model"));
}

test "connect key is masked" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    f.app.overlay = .connect_key;
    try f.app.connect_secret.appendSlice(f.app.allocator, "super-secret-key");
    try f.draw();
    try std.testing.expect(!try f.contains("super-secret-key"));
    try std.testing.expect(try f.contains("••••"));
}

test "narrow OAuth screen pages through the full URL" {
    var f = try Fixture.init(24, 16);
    defer f.deinit();
    f.app.overlay = .connect_oauth;
    f.app.connect_flow = .{ .id = "flow", .url = "https://example.test/long-path/device?code=ABCD1234", .instructions = "Visit the URL and enter CODE-9876" };
    try f.draw();
    try std.testing.expect(std.mem.startsWith(u8, dock.page(f.app.connect_flow.?.url, 0, f.app.connect_page_width), "https://"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try @import("actions.zig").handle(&f.app, &f.registry, arena.allocator(), .{ .key = .end });
    try std.testing.expect(std.mem.indexOf(u8, dock.page(f.app.connect_flow.?.url, f.app.connect_url_offset, f.app.connect_page_width), "ABCD1234") != null);
}

test "multiline input grows the dock and the cursor follows" {
    var f = try Fixture.init(36, 20);
    defer f.deinit();
    try f.app.editor.insert("first\nsecond界");
    const bytes = try view.draw(&f.screen, &f.app, .{ .registry = &f.registry });
    defer std.testing.allocator.free(bytes);
    const a = try f.row(15);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings(" first", a);
    // Row 17, column 10 (1-based): after "second" and the wide glyph.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[17;10H") != null);
}

test "prepending older history keeps the distance from the end" {
    var f = try Fixture.init(36, 16);
    defer f.deinit();
    for (0..10) |_| try f.app.appendMessage("user", "latest");
    try f.draw();
    f.app.scrollUp(1);
    f.app.history_prepend = true;
    try f.app.messages.insert(std.testing.allocator, 0, .{ .role = "user", .text = "older" });
    try f.draw();
    try std.testing.expectEqual(@as(usize, 1), f.app.scroll);
    try std.testing.expect(try f.contains("1 more lines"));
}

test "footer shows usage, cost and context use" {
    var f = try Fixture.init(90, 12);
    defer f.deinit();
    f.app.usage_input = 12_345;
    f.app.usage_output = 700;
    f.app.cost = 0.0123;
    f.app.last_context = 27_200;
    f.app.context_window = 272_000;
    try f.draw();
    const last = try f.row(11);
    defer std.testing.allocator.free(last);
    try std.testing.expect(std.mem.startsWith(u8, last, " ↑12k ↓700 $0.012 10.0%/272k"));
}

test "queued input shows a bounded one-line preview above the dock" {
    var f = try Fixture.init(48, 14);
    defer f.deinit();
    try f.app.pending.append(std.testing.allocator, .{ .id = "1", .text = "earlier", .delivery = "queue" });
    try f.app.pending.append(std.testing.allocator, .{ .id = "2", .text = "RESTORED_INPUT\nprivate continuation", .delivery = "steer" });
    try f.draw();
    try std.testing.expect(try f.contains(" Queued 2 (steer): RESTORED_INPUT"));
    try std.testing.expect(!try f.contains("private continuation"));
}

test "a long picker scrolls to keep the highlight visible" {
    var f = try Fixture.init(60, 30);
    defer f.deinit();
    var items: [40]@import("picker.zig").Item = undefined;
    var labels: [40][8]u8 = undefined;
    for (&items, &labels, 0..) |*item, *label, i| {
        const text = try std.fmt.bufPrint(label, "item{d:0>2}", .{i});
        item.* = .{ .id = text, .label = text };
    }
    f.app.openPicker(.sessions, false);
    f.app.picker_items = &items;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..25) |_| _ = try @import("actions.zig").handle(&f.app, &f.registry, arena.allocator(), .{ .key = .down });
    for (0..30) |_| _ = try @import("actions.zig").handle(&f.app, &f.registry, arena.allocator(), .{ .key = .down });
    try f.draw();
    try std.testing.expect(try f.contains("item39"));
    try std.testing.expect(!try f.contains("item00"));
    // Down stops at the last item, so one Up moves the highlight at once.
    _ = try @import("actions.zig").handle(&f.app, &f.registry, arena.allocator(), .{ .key = .up });
    try std.testing.expectEqual(@as(usize, 38), f.app.picker_selected);
}
