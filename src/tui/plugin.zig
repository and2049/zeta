//! TUI plugin host. Every built-in part (slash commands, keybindings, top
//! bar and footer contents, tool summaries) is a plugin registered through
//! `Registry`; the host keeps only the transcript, editor, completion list
//! and pickers. Plugins are compiled in (`builtins.zig`); out-of-process
//! code can only contribute data through the server (prompt templates).
const std = @import("std");
const App = @import("App.zig");
const Worker = @import("app_network.zig").Worker;
const Builder = @import("presentation_text.zig").Builder;
const Palette = @import("palette.zig").Palette;
const questions = @import("questions.zig");
const input = @import("input.zig");
const Screen = @import("screen.zig").Screen;
const Cursor = @import("editor_view.zig").Cursor;

/// What a command may touch: the UI state and the background request queue.
pub const Context = struct {
    app: *App,
    worker: *Worker,
};

pub const Command = struct {
    /// Slash name without the `/`, e.g. `model`.
    name: []const u8,
    description: []const u8 = "",
    argument_hint: ?[]const u8 = null,
    /// Listed in `/` completion. Keybinding-only commands set false.
    slash: bool = true,
    /// What completes the argument while it is typed.
    complete: enum { none, directory } = .none,
    /// Runs with the text after the name (trimmed, possibly empty).
    run: *const fn (ctx: *Context, arguments: []const u8) anyerror!void,
};

/// A Ctrl+letter chord (lowercase letter).
pub const Keybind = struct { ctrl: u8, command: []const u8 };

/// Named places plugins draw into. Left and right parts of a row are
/// joined with separators; the right part is aligned to the edge.
/// `footer_first` and `footer_status` share the footer's first row (status
/// on the right); `footer_left`/`footer_right` the second. `welcome` fills
/// an empty conversation and may add several lines.
pub const Slot = enum { footer_first, footer_status, footer_left, footer_right, welcome };

/// Read-only data a slot draws from.
pub const View = struct {
    app: *const App,
    palette: Palette,
    spinner: []const u8,
    /// Rows the slot may fill (the conversation area for `welcome`).
    rows: usize = 1,
    /// Columns the slot may fill.
    columns: usize = 80,
};

pub const SlotEntry = struct {
    slot: Slot,
    /// Lower comes first.
    order: i32 = 0,
    /// Adds spans to `b` (one row; the host clips). Adding nothing hides it.
    render: *const fn (view: View, b: *Builder) anyerror!void,
};

pub const ToolRenderer = struct {
    /// Tool name, or `*` for any tool without its own renderer.
    tool: []const u8,
    /// One-line summary of the call from its JSON arguments, e.g. a path.
    summary: *const fn (a: std.mem.Allocator, arguments: []const u8) anyerror![]const u8,
};

pub const Plugin = struct {
    id: []const u8,
    setup: *const fn (r: *Registry) anyerror!void,
};

/// A question kind's complete dock behavior.
pub const QuestionRenderer = struct {
    kind: @import("client").questions.Kind,
    rows: *const fn (*const questions.Entry) usize,
    draw: *const fn (*Screen, *const questions.Entry, usize, usize) ?Cursor,
    handle: *const fn (*questions.Entry, input.Event) anyerror!?questions.Answer,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    keybinds: std.ArrayList(Keybind) = .empty,
    slots: std.ArrayList(SlotEntry) = .empty,
    tools: std.ArrayList(ToolRenderer) = .empty,
    question_renderers: std.ArrayList(QuestionRenderer) = .empty,

    /// Registers every plugin in order; a later command or keybinding with
    /// the same name or chord replaces an earlier one.
    pub fn init(gpa: std.mem.Allocator, plugins: []const Plugin) !Registry {
        var r: Registry = .{ .gpa = gpa };
        errdefer r.deinit();
        for (plugins) |plugin| try plugin.setup(&r);
        return r;
    }

    pub fn deinit(r: *Registry) void {
        r.commands.deinit(r.gpa);
        r.keybinds.deinit(r.gpa);
        r.slots.deinit(r.gpa);
        r.tools.deinit(r.gpa);
        r.question_renderers.deinit(r.gpa);
    }

    pub fn addCommand(r: *Registry, entry: Command) !void {
        for (r.commands.items) |*existing| if (std.mem.eql(u8, existing.name, entry.name)) {
            existing.* = entry;
            return;
        };
        try r.commands.append(r.gpa, entry);
    }

    pub fn addKeybind(r: *Registry, keybind: Keybind) !void {
        for (r.keybinds.items) |*existing| if (existing.ctrl == keybind.ctrl) {
            existing.* = keybind;
            return;
        };
        try r.keybinds.append(r.gpa, keybind);
    }

    pub fn addSlot(r: *Registry, entry: SlotEntry) !void {
        var at = r.slots.items.len;
        while (at > 0 and r.slots.items[at - 1].order > entry.order) at -= 1;
        try r.slots.insert(r.gpa, at, entry);
    }

    pub fn addToolRenderer(r: *Registry, renderer: ToolRenderer) !void {
        try r.tools.append(r.gpa, renderer);
    }

    pub fn addQuestionRenderer(r: *Registry, renderer: QuestionRenderer) !void {
        for (r.question_renderers.items) |*existing| if (existing.kind == renderer.kind) {
            existing.* = renderer;
            return;
        };
        try r.question_renderers.append(r.gpa, renderer);
    }

    pub fn questionRenderer(r: *const Registry, kind: @import("client").questions.Kind) ?QuestionRenderer {
        for (r.question_renderers.items) |entry| if (entry.kind == kind) return entry;
        return null;
    }

    pub fn command(r: *const Registry, name: []const u8) ?Command {
        for (r.commands.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The command bound to Ctrl+`letter`, if any.
    pub fn bound(r: *const Registry, letter: u8) ?Command {
        for (r.keybinds.items) |k| if (k.ctrl == letter) return r.command(k.command);
        return null;
    }

    pub fn toolRenderer(r: *const Registry, tool: []const u8) ?ToolRenderer {
        var fallback: ?ToolRenderer = null;
        for (r.tools.items) |t| {
            if (std.mem.eql(u8, t.tool, tool)) return t;
            if (std.mem.eql(u8, t.tool, "*")) fallback = t;
        }
        return fallback;
    }

    /// Renders every entry of `slot`, joined by `separator`.
    pub fn renderSlot(r: *const Registry, slot: Slot, view: View, b: *Builder, separator: []const u8) !void {
        var any = false;
        for (r.slots.items) |entry| {
            if (entry.slot != slot) continue;
            const before = b.spans.items.len;
            if (any) try b.add(separator, .muted);
            const after_separator = b.spans.items.len;
            try entry.render(view, b);
            if (b.spans.items.len == after_separator) {
                // Nothing drawn: drop the separator too.
                while (b.spans.items.len > before) {
                    const span = b.spans.pop().?;
                    b.used -= @import("presentation_text.zig").columns(span.text);
                    b.a.free(span.text);
                }
            } else any = true;
        }
    }
};

fn noop(_: *Context, _: []const u8) anyerror!void {}

test "later registrations replace earlier ones and slots keep order" {
    const S = struct {
        fn one(r: *Registry) anyerror!void {
            try r.addCommand(.{ .name = "a", .description = "first", .run = noop });
            try r.addKeybind(.{ .ctrl = 'o', .command = "a" });
            try r.addSlot(.{ .slot = .footer_first, .order = 10, .render = second });
            try r.addSlot(.{ .slot = .footer_first, .order = 0, .render = first });
            try r.addSlot(.{ .slot = .footer_first, .order = 5, .render = empty });
        }
        fn two(r: *Registry) anyerror!void {
            try r.addCommand(.{ .name = "a", .description = "second", .run = noop });
        }
        fn first(_: View, b: *Builder) anyerror!void {
            try b.add("x", .normal);
        }
        fn second(_: View, b: *Builder) anyerror!void {
            try b.add("y", .normal);
        }
        fn empty(_: View, _: *Builder) anyerror!void {}
    };
    var r = try Registry.init(std.testing.allocator, &.{ .{ .id = "one", .setup = S.one }, .{ .id = "two", .setup = S.two } });
    defer r.deinit();
    try std.testing.expectEqualStrings("second", r.bound('o').?.description);
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try r.renderSlot(.footer_first, .{ .app = &app, .palette = .{}, .spinner = "" }, &b, " · ");
    const lines = try b.finish();
    defer @import("presentation_text.zig").freeLines(std.testing.allocator, lines);
    try std.testing.expectEqual(@as(usize, 3), lines[0].spans.len);
    try std.testing.expectEqualStrings("y", lines[0].spans[2].text);
}
