//! The completion list for the word at the editor cursor: registered slash
//! commands and prompt templates, workspace files, or directories.
const std = @import("std");
const App = @import("App.zig");
const plugin = @import("plugin.zig");
const picker = @import("picker.zig");
const completion = @import("completion.zig");

pub const Current = struct {
    token: completion.Token,
    items: []const picker.Item,
    /// Matching `items`, best first.
    indices: []const usize,
    /// Index into `indices`.
    selected: usize,

    pub fn chosen(c: Current) ?picker.Item {
        if (c.indices.len == 0) return null;
        return c.items[c.indices[c.selected]];
    }
};

/// The word at the cursor, including the argument of a command that
/// completes directories.
pub fn tokenAt(app: *const App, registry: *const plugin.Registry) completion.Token {
    const text = app.editor.text();
    for (registry.commands.items) |c| if (c.complete == .directory) {
        if (completion.argument(text, app.editor.cursor, c.name)) |t| return t;
    };
    return completion.token(text, app.editor.cursor);
}

/// The open list, or null. Allocations go to `arena`.
pub fn current(app: *App, registry: *const plugin.Registry, arena: std.mem.Allocator) !?Current {
    const token = tokenAt(app, registry);
    if (!app.completion.open(token)) return null;
    const items: []const picker.Item = switch (token.kind) {
        .none => unreachable,
        .command => try commands(arena, registry, app.templates),
        // Results for an older query are still shown until new ones arrive.
        .file => app.files,
        .directory => app.directories,
    };
    const indices = switch (token.kind) {
        .command => try completion.filter(arena, items, token.query),
        .directory => try directories(arena, app, token.query),
        else => blk: {
            const all = try arena.alloc(usize, items.len);
            for (all, 0..) |*index, i| index.* = i;
            break :blk all;
        },
    };
    if (indices.len == 0 and token.kind != .file) return null;
    if (app.completion.selected >= indices.len) app.completion.selected = 0;
    return .{ .token = token, .items = items, .indices = indices, .selected = app.completion.selected };
}

/// Listed subdirectories of the typed parent starting with the typed name;
/// hidden ones only once the name starts with `.`.
fn directories(arena: std.mem.Allocator, app: *const App, query: []const u8) ![]usize {
    const split = completion.splitPath(query);
    const parent = app.directory_parent orelse return &.{};
    if (!std.mem.eql(u8, parent, split.parent)) return &.{};
    var out: std.ArrayList(usize) = .empty;
    for (app.directories, 0..) |item, i| {
        if (item.label.len > 0 and item.label[0] == '.' and !std.mem.startsWith(u8, split.prefix, ".")) continue;
        if (std.ascii.startsWithIgnoreCase(item.label, split.prefix)) try out.append(arena, i);
    }
    return out.items;
}

/// Registered slash commands, then templates not shadowing one.
pub fn commands(arena: std.mem.Allocator, registry: *const plugin.Registry, templates: []const picker.Item) ![]const picker.Item {
    var out: std.ArrayList(picker.Item) = .empty;
    for (registry.commands.items) |c| {
        if (!c.slash) continue;
        const id = try std.fmt.allocPrint(arena, "/{s}", .{c.name});
        const label = if (c.argument_hint) |hint| try std.fmt.allocPrint(arena, "{s} {s}", .{ id, hint }) else id;
        try out.append(arena, .{ .id = id, .label = label, .detail = c.description });
    }
    for (templates) |t| {
        if (registry.command(t.id[1..]) == null) try out.append(arena, t);
    }
    return out.items;
}

test "templates follow built-ins and never shadow them" {
    const S = struct {
        fn noop(_: *plugin.Context, _: []const u8) anyerror!void {}
        fn setup(r: *plugin.Registry) anyerror!void {
            try r.addCommand(.{ .name = "model", .description = "Choose", .run = noop });
            try r.addCommand(.{ .name = "hidden", .slash = false, .run = noop });
        }
    };
    var r = try plugin.Registry.init(std.testing.allocator, &.{.{ .id = "t", .setup = S.setup }});
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = try commands(arena.allocator(), &r, &.{ .{ .id = "/model", .label = "/model" }, .{ .id = "/review", .label = "/review <path>" } });
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("/review <path>", list[1].label);

    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    try app.editor.insert("/mo");
    _ = app.completion.observe(@import("completion.zig").token("/mo", 3));
    const open = (try current(&app, &r, arena.allocator())).?;
    try std.testing.expectEqualStrings("/model", open.chosen().?.id);
    try app.editor.insert("x");
    try std.testing.expect(try current(&app, &r, arena.allocator()) == null);
}
