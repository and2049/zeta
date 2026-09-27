//! Interception points. A hook looks at one step of a run and says what
//! happens next. Hooks run in load order (built-in, user, project; in
//! registration order within a layer); each sees what earlier ones changed,
//! and the first that blocks or continues a turn ends the chain.
//!
//! Errors: a failing `tool_pre` hook blocks the call and a failing
//! `permission` hook denies it; a failing `turn_stop` hook lets the turn
//! stop; any other failing hook is logged and skipped.

const std = @import("std");
const proto = @import("proto");
const provider = @import("provider.zig");
const tool = @import("tool.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Which run a hook is looking at.
pub const Scope = struct {
    session: []const u8,
    location: []const u8,
    provider: []const u8,
    model: []const u8,
};

/// A tool call whose arguments passed the tool's schema.
pub const Call = struct {
    id: []const u8,
    name: []const u8,
    args: std.json.Value,
};

pub const ToolPre = union(enum) {
    @"continue",
    /// New arguments; checked against the schema again.
    rewrite: std.json.Value,
    /// The call does not run; the model gets this reason as an error result.
    block: []const u8,
};

pub const ToolPost = union(enum) {
    @"continue",
    replace: tool.Result,
};

pub const ProviderRequest = union(enum) {
    @"continue",
    replace: provider.Request,
};

pub const ContextBuild = union(enum) {
    @"continue",
    /// The history the model sees instead; the log is unchanged.
    replace: []const proto.Message,
};

pub const TurnStop = union(enum) {
    stop,
    /// Run one more step with this text as a user message. Honoured once:
    /// the next stop cannot be continued again.
    @"continue": []const u8,
};

/// The agent would stop: `reply` is its final message. `continued` is set
/// when a hook already continued the previous stop.
pub const Stop = struct {
    reply: proto.Message,
    continued: bool,
};

/// Why a session's run is its first in this server process: a new session
/// (`startup`) or one with history from before a restart (`resume`).
pub const SessionSource = enum { startup, @"resume" };

/// A prompt about to become a user message.
pub const Prompt = struct {
    /// The inbox id, which becomes the message id.
    id: []const u8,
    text: []const u8,
};

pub const PromptSubmit = union(enum) {
    @"continue",
    /// Text the model sees after the prompt, for this turn's history.
    context: []const u8,
    /// The prompt is dropped; clients get this reason.
    block: []const u8,
};

/// A call that permission rules would ask the user about.
pub const Ask = struct {
    call: Call,
    action: []const u8,
    pattern: []const u8,
};

pub const Permission = union(enum) {
    /// Ask the user as usual.
    @"continue",
    /// Run without asking, with these arguments if set (checked against the
    /// schema again).
    allow: ?std.json.Value,
    /// Deny with this reason.
    deny: []const u8,
};

/// Everything a hook receives is borrowed for the call; what it returns must
/// live in `arena`, which lasts as long as the step it changes.
pub const Hook = struct {
    ctx: ?*anyopaque = null,
    point: Point,
};

pub const Point = union(enum) {
    /// The session's first run in this process; returned text (or null) is
    /// added to the history before its first prompt.
    session_start: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, source: SessionSource) anyerror!?[]const u8,
    prompt_submit: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, prompt: Prompt) anyerror!PromptSubmit,
    permission: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, ask: Ask) anyerror!Permission,
    context_build: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, messages: []const proto.Message) anyerror!ContextBuild,
    provider_request: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, request: provider.Request) anyerror!ProviderRequest,
    tool_pre: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, call: Call) anyerror!ToolPre,
    tool_post: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, call: Call, result: tool.Result) anyerror!ToolPost,
    turn_stop: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, scope: Scope, stop: Stop) anyerror!TurnStop,
};
