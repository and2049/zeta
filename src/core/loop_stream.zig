//! One model request of the loop: the request built from the session
//! history, its streaming attempts and retries, and recovery from a request
//! too long for the model's context.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Message = proto.Message;
const types = proto.event.types;
const Loop = @import("loop.zig").Loop;
const Assembler = @import("assemble.zig").Assembler;
const projection = @import("projection.zig");
const steps = @import("loop_compaction.zig");

/// Streams one reply. A retryable failure before any output retries the
/// same message; one after output logs the partial reply as an error
/// (without its unfinished tool calls) and retries under a new message,
/// which the next request sees instead.
///
/// A request the model rejects as too long for its context, before any
/// output, is not logged: the history is compacted and the request
/// rebuilt and sent once more. If that fails too, the error is logged.
pub fn streamAssistant(l: *Loop, arena: Allocator) !Message {
    var recovered = false;
    while (true) {
        var projected: std.heap.ArenaAllocator = .init(l.gpa);
        defer projected.deinit();
        var request = try buildRequest(l, projected.allocator());
        // What the model is told is logged before a request that tells it,
        // when it differs from the last logged entry.
        l.system_hash = try l.session.recordSystem(projected.allocator(), request.system, request.tools, l.now());
        request.system_hash = l.system_hash;
        request.session_id = l.session.info.id;
        request.thinking = l.config.thinking;
        const may_recover = !recovered and steps.mayRecover(l);
        var tries: u32 = 1;
        const attempt = while (true) : (tries += 1) {
            const attempt = try streamAttempt(l, arena, request, &tries, may_recover);
            const delay = attempt.retry_ms orelse break attempt;
            l.io.sleep(.fromMilliseconds(@intCast(delay)), .awake) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                break attempt;
            };
        };
        if (!attempt.overflow) return attempt.message;
        recovered = true;
        if (try steps.compactNow(l, .overflow, null)) continue;
        // Its draft was withdrawn: clients get a start again, in the same
        // locked step that logs it.
        try l.appendAnnounced(attempt.message, true);
        return attempt.message;
    }
}

/// The context layer: session history adapted to the model, then the
/// context.build and provider.request hooks. Lives in `arena`.
fn buildRequest(l: *Loop, arena: Allocator) !plugin.provider.Request {
    const h = l.hooks();
    const history = try projection.forModel(arena, l.session.messages.items, .{
        .provider = l.config.provider_id,
        .model = l.config.model_id,
        .accepts_images = l.config.options.accepts_images,
    });
    return h.providerRequest(arena, l.io, .{
        .model = l.config.model_id,
        .location = l.session.info.location,
        .system = l.config.system,
        .messages = try h.contextBuild(arena, l.io, history),
        .tools = l.config.tools,
    });
}

const Attempt = struct {
    message: Message,
    /// Set when the reply failed after output and should be retried.
    retry_ms: ?u64 = null,
    /// The model rejected the request as too long before any output;
    /// `message` was withdrawn, not logged.
    overflow: bool = false,
};

/// `withdraw_overflow`: a context overflow before any output withdraws
/// the message instead of logging it, for the caller to compact first.
fn streamAttempt(l: *Loop, arena: Allocator, request: plugin.provider.Request, tries: *u32, withdraw_overflow: bool) !Attempt {
    const id = try arena.dupe(u8, l.ids.next(l.io, .message).slice());
    var draft: Message = .{
        .id = id,
        .role = .assistant,
        .content = &.{},
        .timestamp = l.now(),
        .provider = l.config.provider_id,
        .model = l.config.model_id,
        .systemHash = l.system_hash,
    };
    errdefer {
        if (l.state_mutex) |mutex| mutex.lockUncancelable(l.io);
        if (l.inflight) |slot| {
            if (slot.* != null) {
                slot.* = null;
                l.emit(types.message_cancelled, .{ .messageId = id }) catch {};
            }
        }
        if (l.state_mutex) |mutex| mutex.unlock(l.io);
    }
    if (l.state_mutex) |mutex| mutex.lockUncancelable(l.io);
    if (l.inflight) |slot| slot.* = draft;
    const start_result = l.emit(types.message_start, .{ .message = draft });
    if (l.state_mutex) |mutex| mutex.unlock(l.io);
    try start_result;

    var asm_: Assembler = .{
        .arena = arena,
        .bus = l.bus,
        .session_id = l.session.info.id,
        .location = l.session.info.location,
        .message_id = id,
        .io = l.io,
        .state_mutex = l.state_mutex,
        .inflight = l.inflight,
    };
    var retry_ms: ?u64 = null;
    const failed: ?anyerror = while (true) : (tries.* += 1) {
        var attempt: std.heap.ArenaAllocator = .init(l.gpa);
        defer attempt.deinit();
        l.config.api.stream(l.config.api.ctx, attempt.allocator(), l.io, l.config.options, request, asm_.sink()) catch |err| {
            if (err == error.Canceled) break err;
            const delay = l.config.retry.delay(asm_.failure, tries.*) orelse break err;
            l.emit(types.message_retry, .{
                .messageId = id,
                .attempt = tries.*,
                .maxAttempts = l.config.retry.max_attempts,
                .delayMs = delay,
                .errorMessage = asm_.failure.?.message,
            }) catch {};
            if (asm_.streamed()) {
                retry_ms = delay;
                break err;
            }
            asm_.clearFailure();
            l.io.sleep(.fromMilliseconds(@intCast(delay)), .awake) catch |sleep_err| break sleep_err;
            continue;
        };
        break null;
    };
    if (failed) |err| {
        draft.stopReason = if (err == error.Canceled) .aborted else .@"error";
        draft.errorMessage = if (asm_.failure) |f| f.message else @errorName(err);
    }
    if (draft.stopReason == null) {
        draft.stopReason = asm_.stop orelse .@"error";
        if (asm_.stop == null) draft.errorMessage = "stream ended without a stop reason";
    }
    draft.content = try asm_.content();
    // Calls from a reply that will be retried never run, so they are not
    // logged: history never holds a call without a result.
    if (retry_ms != null) draft.content = try withoutToolCalls(arena, draft.content);
    draft.usage = asm_.usage.priced(l.config.options.price);
    const overflow = failed != null and failed.? != error.Canceled and !asm_.streamed() and
        if (asm_.failure) |f| f.overflow else false;
    if (overflow and withdraw_overflow) {
        withdraw(l, id);
        return .{ .message = draft, .overflow = true };
    }
    try l.appendMessage(draft);
    return .{ .message = draft, .retry_ms = retry_ms };
}

/// Drops the in-flight message `id` without logging it.
fn withdraw(l: *Loop, id: []const u8) void {
    if (l.state_mutex) |mutex| mutex.lockUncancelable(l.io);
    defer if (l.state_mutex) |mutex| mutex.unlock(l.io);
    if (l.inflight) |slot| slot.* = null;
    l.emit(types.message_cancelled, .{ .messageId = id }) catch {};
}

fn withoutToolCalls(arena: Allocator, content: []const proto.message.Content) ![]const proto.message.Content {
    var out: std.ArrayList(proto.message.Content) = .empty;
    for (content) |c| if (c != .tool_call) try out.append(arena, c);
    return out.items;
}
