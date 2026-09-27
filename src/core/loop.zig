//! The agent loop.
//!
//! Outer loop: keeps going while queued follow-ups arrive after the agent
//! would stop. Inner loop: one assistant response per turn, then its tool
//! calls, then steering messages, until there are neither. Both inbox queues
//! deliver one item at a time.
//!
//! Events: agent.start, turn.start, message.start, message.part.delta,
//! message.end, turn.end, agent.end.

const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Message = proto.Message;
const types = proto.event.types;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const tools = @import("tools.zig");
const Hooks = @import("hooks.zig").Hooks;
const compaction = @import("compaction.zig");

/// Encodes as `{}` (an empty anonymous literal would encode as `[]`).
const empty: struct {} = .{};

pub const Config = struct {
    api: plugin.provider.Api,
    options: plugin.provider.Options,
    provider_id: []const u8,
    model_id: []const u8,
    system: []const u8,
    tools: []const plugin.provider.ToolDecl = &.{},
    /// Frozen executable snapshot; the composition root derives matching
    /// provider declarations in `tools` from this same snapshot.
    executable_tools: []const plugin.tool.Tool = &.{},
    approval: ?tools.Approval = null,
    tool_timeout_ms: ?u64 = null,
    retry: Retry = .{},
    /// From the run's registry view, in load order.
    hooks: []const plugin.Registry.Resolved(plugin.hook.Hook) = &.{},
    /// Set for the session's first run in this process: session_start hooks
    /// run when the run starts, before any prompt hook, and then
    /// `session_started` (if set) becomes true.
    session_start: ?plugin.hook.SessionSource = null,
    session_started: ?*bool = null,
    compaction: compaction.Settings = .{},
    /// Where oversized tool results are saved in full; null cuts them.
    artifacts_dir: ?[]const u8 = null,
    /// Consecutive automatic compaction failures for the session; at
    /// `compaction.max_failures` it stops compacting on its own.
    compaction_failures: ?*u8 = null,
    /// How much the model reasons; null sends no setting.
    thinking: ?proto.thinking.Level = null,
};

const Pending = @import("loop_input.zig").Pending;

/// Bounded exponential backoff for retryable provider failures. Attempts
/// count across a reply's retries, whether or not output had streamed; tool
/// calls only run from a reply that completed, so no side effect repeats.
pub const Retry = struct {
    max_attempts: u32 = 3,
    base_ms: u64 = 1000,
    cap_ms: u64 = 30_000,

    /// Delay before attempt `tries + 1`, or null to give up.
    pub fn delay(r: Retry, failure: ?plugin.provider.Failure, tries: u32) ?u64 {
        if (tries >= r.max_attempts) return null;
        const f = failure orelse return null;
        if (!f.retryable) return null;
        const shift: u6 = @intCast(@min(tries - 1, 32));
        const backoff = @min(r.base_ms << shift, r.cap_ms);
        const wanted = f.retry_after_ms orelse return backoff;
        // The service asked for a longer pause than a retry is worth.
        if (wanted > r.cap_ms) return null;
        return @max(backoff, wanted);
    }
};

pub const Loop = struct {
    gpa: Allocator,
    io: Io,
    bus: *Bus,
    ids: *proto.id.Generator,
    session: *Session,
    inbox: *Inbox,
    /// Runtime's state lock: append and its corresponding event are one
    /// snapshot-visible transition. Null for standalone loop tests.
    state_mutex: ?*Io.Mutex = null,
    /// Runtime-owned projection of the currently streaming assistant. The
    /// content is borrowed from this turn's arena and guarded by state_mutex.
    inflight: ?*?Message = null,
    config: Config,
    /// Hash of the logged system entry for the last request.
    system_hash: ?[]const u8 = null,

    pub fn hooks(l: *const Loop) Hooks {
        return .{ .list = l.config.hooks, .scope = .{
            .session = l.session.info.id,
            .location = l.session.info.location,
            .provider = l.config.provider_id,
            .model = l.config.model_id,
        } };
    }

    pub fn run(l: *Loop) !void {
        var turn_arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer turn_arena.deinit();
        const arena = turn_arena.allocator();

        try l.emit(types.agent_start, empty);
        defer l.emit(types.agent_end, empty) catch {};

        if (l.config.session_start) |source| {
            if (try l.hooks().sessionStart(arena, l.io, source)) |text| try l.appendHookText(text);
            if (l.config.session_started) |flag| flag.* = true;
        }

        // A run starts from the oldest steering item, else the oldest queued
        // one. Nothing left (e.g. the only input was withdrawn) means no
        // model request.
        var pending: ?Pending = try l.take(arena, .steer) orelse try l.take(arena, .queue);
        // A turn.stop hook continued the last stop; the next cannot be.
        var continued = false;
        while (pending != null) {
            var more_tools = false;
            while (more_tools or pending != null) {
                try l.emit(types.turn_start, empty);

                if (pending) |next| try l.appendUser(arena, next);
                pending = null;
                // Inbox.takeNext copies into this arena. Keep the item alive
                // until Session.append has copied it into its own arena.
                _ = turn_arena.reset(.retain_capacity);
                try l.autoCompact();

                const reply = try l.streamAssistant(arena);
                const calls = try toolCalls(arena, reply);
                if (reply.stopReason == .@"error" or reply.stopReason == .aborted) {
                    const closed = l.closeTurn(reply, calls, &.{}, "Tool not executed because the assistant stream failed.");
                    // A canceled stream must not consume another prompt on
                    // this canceled worker; the cancel was already observed,
                    // so report it after the turn is paired and closed.
                    if (reply.stopReason == .aborted and l.state_mutex != null) {
                        closed catch {};
                        return error.Canceled;
                    }
                    try closed;
                    // Runtime owns queued prompts across runs. Do not launch
                    // them after a failed stream; Runtime.fail reports and
                    // clears the waiting inbox instead.
                    if (reply.stopReason == .@"error" and l.state_mutex != null) return error.AgentStreamFailed;
                    return;
                }

                const batch = tools.execute(arena, l.gpa, l.io, l.bus, l.session.info.id, l.session.info.location, l.config.executable_tools, calls, reply.stopReason == .length, l.config.approval, l.config.tool_timeout_ms, l.hooks(), l.config.artifacts_dir) catch |err| tools.Batch{ .outcomes = &.{}, .failure = err };
                const closed = l.closeTurn(reply, calls, batch.outcomes, tools.interrupted);
                if (batch.failure) |err| {
                    // Finished calls keep their real results (a completed
                    // write is not "interrupted"); the batch error wins.
                    closed catch {};
                    return err;
                }
                try closed;
                for (batch.outcomes) |outcome| if (outcome.denied) return;
                // Even truncated calls go back to the model as error
                // results so it can re-issue them.
                more_tools = calls.len > 0;
                pending = try l.take(arena, .steer);
                if (!more_tools and pending == null) {
                    const text = try l.hooks().turnStop(arena, l.io, .{ .reply = reply, .continued = continued });
                    continued = text != null;
                    if (text) |value| pending = .{
                        .item = .{ .id = try arena.dupe(u8, l.ids.next(l.io, .message).slice()), .text = value, .delivery = .steer },
                        .from_hook = true,
                    };
                }
            }
            pending = try l.take(arena, .queue);
        }
    }

    const steps = @import("loop_compaction.zig");
    const autoCompact = steps.autoCompact;
    const compactNow = steps.compactNow;

    const streamAssistant = @import("loop_stream.zig").streamAssistant;

    const input = @import("loop_input.zig");
    const take = input.take;
    const appendUser = input.appendUser;
    pub const appendHookText = input.appendHookText;

    /// Logs one result per assistant tool call, then ends the turn. Calls
    /// without an outcome (`outcomes` is empty or in call order) get
    /// `missing` as an error result, so history never has an unpaired call.
    fn closeTurn(l: *Loop, reply: Message, calls: []const proto.message.ToolCall, outcomes: []const tools.Outcome, missing: []const u8) !void {
        for (calls, 0..) |call, i| {
            if (i < outcomes.len) {
                const outcome = outcomes[i];
                try l.appendToolResultWithChanges(outcome.call, outcome.text, outcome.is_error, outcome.changes, outcome.images);
            } else try l.appendToolResult(call, missing, true);
        }
        try l.emit(types.turn_end, .{ .messageId = reply.id });
    }

    fn appendToolResult(l: *Loop, call: proto.message.ToolCall, text: []const u8, is_error: bool) !void {
        return l.appendToolResultWithChanges(call, text, is_error, &.{}, &.{});
    }

    fn appendToolResultWithChanges(l: *Loop, call: proto.message.ToolCall, text: []const u8, is_error: bool, changes: []const proto.message.FileChange, images: []const proto.attachment.Image) !void {
        const buf = l.ids.next(l.io, .message);
        var parts: [9]proto.message.Content = undefined;
        parts[0] = .{ .text = text };
        // Images a tool returned follow its text; a few at most.
        const shown = @min(images.len, parts.len - 1);
        for (images[0..shown], parts[1 .. shown + 1]) |image, *part| part.* = .{ .image = image };
        try l.appendMessage(.{
            .id = buf.slice(),
            .role = .tool_result,
            .content = parts[0 .. shown + 1],
            .timestamp = l.now(),
            .toolCallId = call.id,
            .toolName = call.name,
            .isError = is_error,
            .changes = changes,
        });
    }

    /// Logs a complete message, then announces it. User and tool messages
    /// get a start/end pair with no deltas.
    pub fn appendMessage(l: *Loop, m: Message) !void {
        return l.appendAnnounced(m, m.role != .assistant);
    }

    /// `appendMessage`, with a `message.start` when `start` is set.
    pub fn appendAnnounced(l: *Loop, m: Message, start: bool) !void {
        if (l.state_mutex) |mutex| mutex.lockUncancelable(l.io);
        defer if (l.state_mutex) |mutex| mutex.unlock(l.io);
        var finished = m;
        if (finished.role == .assistant) finished.completedAt = l.now();
        try l.session.append(finished);
        if (m.role == .user) {
            l.inbox.ack(m.id);
            var arena: std.heap.ArenaAllocator = .init(l.gpa);
            defer arena.deinit();
            if (l.inbox.snapshot(arena.allocator())) |items| {
                l.emit(types.session_inbox_updated, .{ .inbox = items }) catch {};
            } else |_| {}
        }
        if (start) try l.emit(types.message_start, .{ .message = finished });
        try l.emit(types.message_end, .{ .message = finished });
        if (m.role == .assistant) {
            if (l.inflight) |slot| slot.* = null;
        }
    }

    pub fn emit(l: *Loop, ty: []const u8, data: anytype) !void {
        try l.bus.publishValue(ty, l.session.info.id, l.session.info.location, data);
    }

    pub fn now(l: *Loop) i64 {
        return Io.Clock.real.now(l.io).toMilliseconds();
    }
};

fn toolCalls(arena: Allocator, m: Message) ![]proto.message.ToolCall {
    var out: std.ArrayList(proto.message.ToolCall) = .empty;
    for (m.content) |c| if (c == .tool_call) try out.append(arena, c.tool_call);
    return out.items;
}

test {
    _ = @import("loop_test.zig");
    _ = @import("loop_stream.zig");
}
