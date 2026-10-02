//! Asking the user on behalf of a plugin: confirm something, pick an option,
//! type a line, or fill a form (an MCP server's elicitation is a form). The
//! host shows the question to whichever client answers. Plugins also post
//! notices, which need no answer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Option = struct {
    /// What the answer carries when this option is picked.
    value: []const u8,
    /// What the user sees; empty shows `value`.
    label: []const u8 = "",
    description: []const u8 = "",
};

/// What the question asks for, and so what an accepted answer's `content`
/// holds (JSON text): nothing for `confirm`, the picked option's value as a
/// JSON string for `select`, the typed text as a JSON string for `input`,
/// and an object fitting the schema for `form`.
pub const Kind = union(enum) {
    /// Yes (`accept`) or no (`decline`).
    confirm: struct { detail: ?[]const u8 = null },
    select: struct { options: []const Option },
    input: struct { placeholder: ?[]const u8 = null, secret: bool = false },
    /// A JSON Schema object (as JSON text) of simple properties.
    form: struct { schema: []const u8 },
};

pub const Question = struct {
    /// The project the question is for.
    location: []const u8,
    /// Who asks, e.g. `mcp:docs` or a plugin id.
    source: []const u8,
    message: []const u8,
    kind: Kind,
    timeout_ms: u64,
    /// The session the question is about, when known: clients that cannot
    /// answer leave other sessions' questions alone.
    session: ?[]const u8 = null,
    /// Set when the answer is no longer wanted (the request was cancelled,
    /// or the call it belongs to ended); the question then resolves as
    /// `cancel`.
    withdrawn: ?*Io.Event = null,
};

pub const Action = enum { accept, decline, cancel };

pub const Answer = struct {
    action: Action,
    /// With `accept`: the answer as JSON text (see `Kind`), in the caller's
    /// arena.
    content: ?[]const u8 = null,
};

pub const Level = enum { info, warn, @"error" };

/// A message for the user that needs no answer.
pub const Notice = struct {
    location: []const u8,
    source: []const u8,
    message: []const u8,
    level: Level = .info,
    session: ?[]const u8 = null,
};

pub const Asker = struct {
    ctx: ?*anyopaque = null,
    /// Waits for an answer; no client to answer, or none in time, declines.
    ask: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, question: Question) anyerror!Answer = declineAll,
    /// Shows a notice to the clients that are listening.
    notify: *const fn (ctx: ?*anyopaque, notice: Notice) anyerror!void = dropNotice,

    /// Asks nobody: every question declines and notices go nowhere.
    pub const none: Asker = .{};

    fn declineAll(_: ?*anyopaque, _: Allocator, _: Io, _: Question) anyerror!Answer {
        return .{ .action = .decline };
    }

    fn dropNotice(_: ?*anyopaque, _: Notice) anyerror!void {}
};

test "the empty asker declines" {
    const q: Question = .{ .location = "/p", .source = "t", .message = "?", .kind = .{ .confirm = .{} }, .timeout_ms = 1 };
    const answer = try Asker.none.ask(null, std.testing.allocator, std.testing.io, q);
    try std.testing.expectEqual(Action.decline, answer.action);
    try Asker.none.notify(null, .{ .location = "/p", .source = "t", .message = "hi" });
}
