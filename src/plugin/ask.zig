//! Asking the user for input on behalf of a plugin (an MCP server's
//! elicitation): a message and a form described by a JSON Schema object
//! of simple properties. The host shows it to whichever client answers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Question = struct {
    /// The project the question is for.
    location: []const u8,
    /// Who asks, e.g. `mcp:docs`.
    source: []const u8,
    message: []const u8,
    /// JSON Schema object (as JSON text) for the answer.
    schema: []const u8,
    timeout_ms: u64,
    /// The session whose tool call asks, when known: clients that cannot
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
    /// With `accept`: the answer as a JSON object, in the caller's arena.
    content: ?[]const u8 = null,
};

pub const Asker = struct {
    ctx: ?*anyopaque,
    /// Waits for an answer; no client to answer, or none in time, declines.
    ask: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, question: Question) anyerror!Answer,
};
