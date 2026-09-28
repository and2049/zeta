//! Slash commands: prompt templates from a resource loader and commands
//! plugins register. Running one turns its arguments into a session prompt;
//! the history keeps only that text, as an ordinary user message. Templates
//! are read fresh on every listing and run.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Runtime = @import("Runtime.zig");
const Delivery = @import("inbox.zig").Delivery;
const Allocator = std.mem.Allocator;

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    argument_hint: ?[]const u8 = null,
    /// `user` or `project`.
    source: []const u8,
    path: []const u8,
    /// The body the arguments are substituted into (templates).
    template: []const u8 = "",
    /// Set for a plugin's command, which builds the text itself.
    runner: ?plugin.command.Command = null,
};

pub const Listing = struct {
    /// Sorted by name; a narrower scope has already replaced a wider one.
    commands: []const Command = &.{},
    /// Files that were skipped, with the reason.
    diagnostics: []const []const u8 = &.{},
};

/// The commands for a location: plugin commands, then prompt templates
/// (a template with a plugin command's name is hidden). Arena owned.
pub fn list(rt: *Runtime, arena: Allocator, location: []const u8) !Listing {
    const templates: Listing = if (rt.resources) |loader| if (loader.commands) |read| try read(loader.ctx, arena, rt.io, location) else .{} else .{};
    _ = try rt.registry.activate(arena, location);
    const view = try rt.registry.view(arena, location);
    if (view.commands.len == 0) return templates;
    var out: std.ArrayList(Command) = .empty;
    var diagnostics: std.ArrayList([]const u8) = .empty;
    try diagnostics.appendSlice(arena, templates.diagnostics);
    for (view.commands) |entry| try out.append(arena, .{
        .name = entry.value.name,
        .description = entry.value.description,
        .argument_hint = entry.value.argument_hint,
        .source = entry.plugin,
        .path = "",
        .runner = entry.value,
    });
    next: for (templates.commands) |template| {
        for (view.commands) |entry| if (std.mem.eql(u8, entry.value.name, template.name)) {
            try diagnostics.append(arena, try std.fmt.allocPrint(arena, "prompts: {s}: hidden by the command from plugin '{s}'", .{ template.path, entry.plugin }));
            continue :next;
        };
        try out.append(arena, template);
    }
    std.mem.sort(Command, out.items, {}, struct {
        fn less(_: void, a: Command, b: Command) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return .{ .commands = out.items, .diagnostics = diagnostics.items };
}

/// Expands command `name` with `arguments` for the session's location and
/// admits the result like a prompt. Returns the inbox id; on
/// `error.CommandFailed`, `problem` says why.
pub fn run(rt: *Runtime, session_id: []const u8, name: []const u8, arguments: []const u8, delivery: Delivery, images: []const proto.attachment.Image, problem: *plugin.command.Problem) !proto.id.Buf {
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = try rt.context(arena, session_id);
    // A plugin command may come from something still starting;
    // give it its bounded chance, as a run does.
    _ = try rt.registry.activate(arena, context.location);
    try rt.registry.settle(context.location);
    const listing = try list(rt, arena, context.location);
    for (listing.commands) |command| {
        if (!std.mem.eql(u8, command.name, name)) continue;
        const text = if (command.runner) |runner|
            try runner.run(runner.ctx, arena, rt.io, context.location, arguments, problem)
        else
            try expand(arena, command.template, arguments);
        return rt.promptWithImages(session_id, text, delivery, images);
    }
    return error.CommandNotFound;
}

/// Splits on whitespace; `'` or `"` group a run and are removed. There are
/// no escapes, an unmatched quote takes the rest and empty arguments are
/// dropped.
pub fn split(arena: Allocator, text: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    for (text) |c| {
        if (quote) |q| {
            if (c == q) quote = null else try current.append(arena, c);
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (std.ascii.isWhitespace(c)) {
            if (current.items.len > 0) {
                try args.append(arena, try current.toOwnedSlice(arena));
            }
        } else try current.append(arena, c);
    }
    if (current.items.len > 0) try args.append(arena, current.items);
    return args.items;
}

/// Substitutes `$1`, `$@`, `$ARGUMENTS`, `${N:-default}`, `${@:-default}`,
/// `${ARGUMENTS:-default}`, `${@:N}` and `${@:N:L}` in one pass: inserted
/// text is not expanded again. Missing arguments are empty, and arguments a
/// template does not reference are dropped.
pub fn expand(arena: Allocator, template: []const u8, arguments: []const u8) ![]const u8 {
    const args = try split(arena, arguments);
    const all = try std.mem.join(arena, " ", args);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$') if (try placeholder(arena, template[i + 1 ..], args, all)) |found| {
            try out.appendSlice(arena, found.value);
            i += 1 + found.len;
            continue;
        };
        try out.append(arena, template[i]);
        i += 1;
    }
    return out.items;
}

const Found = struct { value: []const u8, len: usize };

/// `rest` follows a `$`. Null when it is not a placeholder.
fn placeholder(arena: Allocator, rest: []const u8, args: []const []const u8, all: []const u8) !?Found {
    if (std.mem.startsWith(u8, rest, "ARGUMENTS")) return .{ .value = all, .len = "ARGUMENTS".len };
    if (std.mem.startsWith(u8, rest, "@")) return .{ .value = all, .len = 1 };
    if (digits(rest) > 0) {
        const n = digits(rest);
        return .{ .value = positional(args, rest[0..n]), .len = n };
    }
    if (!std.mem.startsWith(u8, rest, "{")) return null;
    const close = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
    const inner = rest[1..close];
    const len = close + 1;
    if (std.mem.indexOf(u8, inner, ":-")) |dash| {
        const target = inner[0..dash];
        const fallback = inner[dash + 2 ..];
        const value = if (std.mem.eql(u8, target, "@") or std.mem.eql(u8, target, "ARGUMENTS"))
            all
        else if (target.len > 0 and digits(target) == target.len)
            positional(args, target)
        else
            return null;
        return .{ .value = if (value.len > 0) value else fallback, .len = len };
    }
    if (!std.mem.startsWith(u8, inner, "@:")) return null;
    const spec = inner[2..];
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const start_text = spec[0 .. colon orelse spec.len];
    if (start_text.len == 0 or digits(start_text) != start_text.len) return null;
    const start = @min(number(start_text) -| 1, args.len);
    var end = args.len;
    if (colon) |c| {
        const count_text = spec[c + 1 ..];
        if (count_text.len == 0 or digits(count_text) != count_text.len) return null;
        end = @min(start +| number(count_text), args.len);
    }
    return .{ .value = try std.mem.join(arena, " ", args[start..end]), .len = len };
}

fn digits(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and std.ascii.isDigit(text[n])) n += 1;
    return n;
}

fn number(text: []const u8) usize {
    return std.fmt.parseInt(usize, text, 10) catch std.math.maxInt(usize);
}

fn positional(args: []const []const u8, text: []const u8) []const u8 {
    const n = number(text);
    return if (n >= 1 and n <= args.len) args[n - 1] else "";
}

test "arguments split on whitespace with quotes grouping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try split(arena, " one \"two three\"  'it''s' \"\" a\\b \"open rest");
    const expected = [_][]const u8{ "one", "two three", "its", "a\\b", "open rest" };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "placeholders expand in one pass" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { template: []const u8, arguments: []const u8, want: []const u8 }{
        .{ .template = "Review $1 then $2.", .arguments = "a.zig", .want = "Review a.zig then ." },
        .{ .template = "all: $@ | $ARGUMENTS", .arguments = "x  'y z'", .want = "all: x y z | x y z" },
        .{ .template = "${1:-main} ${2:-HEAD}", .arguments = "dev", .want = "dev HEAD" },
        .{ .template = "${@:-nothing}", .arguments = "", .want = "nothing" },
        .{ .template = "${@:2} / ${@:1:2} / ${@:0:1} / ${@:9}", .arguments = "a b c", .want = "b c / a b / a / " },
        .{ .template = "no placeholders", .arguments = "dropped", .want = "no placeholders" },
        .{ .template = "$$1 costs $5 ${x} ${@:} $", .arguments = "$@ b", .want = "$$@ costs  ${x} ${@:} $" },
        .{ .template = "$10", .arguments = "a", .want = "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.want, try expand(arena, case.template, case.arguments));
}

test "plugin commands list beside templates, hide a template of the same name, and run" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const Stub = struct {
        fn templates(_: ?*anyopaque, arena: Allocator, _: std.Io, _: []const u8) anyerror!Listing {
            return .{ .commands = try arena.dupe(Command, &.{
                .{ .name = "review", .description = "template", .source = "user", .path = "/p/review.md", .template = "Review $1" },
                .{ .name = "zz", .description = "template", .source = "user", .path = "/p/zz.md", .template = "last" },
            }) };
        }
        fn prepare(_: ?*anyopaque, _: Allocator, _: std.Io, _: []const u8, _: @import("config.zig").Config, _: []const plugin.tool.Tool) anyerror!Runtime.Prepared {
            return .{};
        }
        fn review(_: ?*anyopaque, arena: Allocator, _: std.Io, location: []const u8, arguments: []const u8, _: *plugin.command.Problem) anyerror![]const u8 {
            return std.fmt.allocPrint(arena, "plugin review of {s} in {s}", .{ arguments, location });
        }
    };
    var reg: plugin.Registry = .init(a, io);
    defer reg.deinit();
    const owner = try reg.addPlugin(.{ .id = "ext" });
    try reg.addCommand(owner, .{ .name = "review", .description = "from a plugin", .run = Stub.review });
    try std.testing.expectError(error.ReservedCommand, reg.addCommand(owner, .{ .name = "model", .run = Stub.review }));
    try std.testing.expectError(error.InvalidCommandName, reg.addCommand(owner, .{ .name = "two words", .run = Stub.review }));
    var bus: @import("bus.zig").Bus = .init(a, io);
    defer bus.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var rt = Runtime.init(a, io, &bus, &reg, &env, .{ .config_dir = dir, .sessions_dir = dir, .resources = .{ .prepare = Stub.prepare, .commands = Stub.templates } });
    defer rt.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const listing = try list(&rt, arena_state.allocator(), dir);
    try std.testing.expectEqual(@as(usize, 2), listing.commands.len);
    try std.testing.expectEqualStrings("from a plugin", listing.commands[0].description);
    try std.testing.expectEqualStrings("ext", listing.commands[0].source);
    try std.testing.expectEqualStrings("zz", listing.commands[1].name);
    try std.testing.expectEqual(@as(usize, 1), listing.diagnostics.len);
    const runner = listing.commands[0].runner.?;
    var problem: plugin.command.Problem = .{};
    const text = try runner.run(runner.ctx, arena_state.allocator(), io, dir, "a.zig", &problem);
    try std.testing.expect(std.mem.startsWith(u8, text, "plugin review of a.zig in "));
}
