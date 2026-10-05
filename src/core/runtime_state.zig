//! Snapshot, pagination, and per-session lifecycle transitions.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const types = proto.event.types;
const session_storage = @import("session_storage.zig");
const Snapshot = Runtime.Snapshot;
const Context = Runtime.Context;
const MessagePage = Runtime.MessagePage;

/// Returns an arena-owned, atomic view. Subscribe to Bus first, fetch this
/// snapshot, then ignore queued frames through `revision` and apply later
/// frames. A missed/overflowed feed requires a fresh subscribe + snapshot.
/// `before` is an exclusive message id; unknown ids are invalid cursors.
pub fn snapshot(rt: *Runtime, arena: Allocator, id: []const u8) !Snapshot {
    return rt.snapshotPage(arena, id, null, 50);
}

pub fn messages(rt: *Runtime, arena: Allocator, id: []const u8, before: ?[]const u8, limit: usize) !MessagePage {
    const state = try rt.snapshotPage(arena, id, before, limit);
    return .{ .messages = state.messages, .nextBefore = state.nextBefore };
}

pub fn context(rt: *Runtime, arena: Allocator, id: []const u8) !Context {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    var options = try copyOptions(arena, entry.overrides);
    // Explicit interactive selection supersedes the creation-time environment
    // model, just as runOnce does. Resource reads and image admission must see
    // the same effective model while retaining the profile environment.
    if (entry.session.model_selected) {
        if (options.environment) |*environment| {
            if (environment.model) |model| arena.free(model);
            environment.model = null;
        } else options.environment = .{
            .profile = if (rt.env.get("ZETA_PROFILE")) |profile| try arena.dupe(u8, profile) else null,
        };
    }
    return .{
        .location = try arena.dupe(u8, entry.session.info.location),
        .options = options,
    };
}

pub fn copyOptions(arena: Allocator, opts: config.Options) !config.Options {
    var result: config.Options = .{};
    errdefer {
        if (result.profile) |v| arena.free(v);
        if (result.model) |v| arena.free(v);
        if (result.environment) |env| {
            if (env.profile) |v| arena.free(v);
            if (env.model) |v| arena.free(v);
        }
    }
    if (opts.profile) |v| result.profile = try arena.dupe(u8, v);
    if (opts.model) |v| result.model = try arena.dupe(u8, v);
    if (opts.environment) |env| {
        result.environment = .{};
        if (env.profile) |v| result.environment.?.profile = try arena.dupe(u8, v);
        if (env.model) |v| result.environment.?.model = try arena.dupe(u8, v);
    }
    return result;
}

pub fn snapshotPage(rt: *Runtime, arena: Allocator, id: []const u8, before: ?[]const u8, requested_limit: usize) !Snapshot {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    entry.session.mutex.lockUncancelable(rt.io);
    defer entry.session.mutex.unlock(rt.io);
    const history = entry.session.messages.items;
    var end = history.len;
    if (before) |cursor| {
        end = for (history, 0..) |message, index| {
            if (std.mem.eql(u8, message.id, cursor)) break index;
        } else return error.InvalidCursor;
    }
    const limit = if (requested_limit == 0) @as(usize, 50) else @min(requested_limit, 200);
    const start = end -| limit;
    const page = try arena.alloc(proto.Message, end - start);
    for (history[start..end], page) |source, *dest| {
        dest.* = try copyMessage(arena, source);
    }
    const info = entry.session.info;
    return .{
        .revision = rt.bus.revision(),
        .info = .{
            .id = try arena.dupe(u8, info.id),
            .location = try arena.dupe(u8, info.location),
            .created = info.created,
            .title = if (info.title) |title| try arena.dupe(u8, title) else null,
            .forkedFrom = if (info.forkedFrom) |v| try arena.dupe(u8, v) else null,
            .forkedAt = if (info.forkedAt) |v| try arena.dupe(u8, v) else null,
        },
        .options = try withThinking(arena, try copyOptions(arena, entry.overrides), entry.session.metadata.thinking),
        .running = entry.running,
        .inbox = try entry.inbox.snapshot(arena),
        .messages = page,
        .inflight = if (entry.draft) |draft| try copyMessage(arena, draft) else null,
        .nextBefore = if (start > 0) try arena.dupe(u8, history[start].id) else null,
        .shell = if (entry.shell) |running| .{ .id = try arena.dupe(u8, running.id), .command = try arena.dupe(u8, running.command), .startedAt = running.startedAt } else null,
    };
}

fn withThinking(arena: Allocator, options: config.Options, thinking: ?[]const u8) !config.Options {
    var out = options;
    out.thinking = if (thinking) |t| try arena.dupe(u8, t) else null;
    return out;
}

fn copyMessage(arena: Allocator, source: proto.Message) !proto.Message {
    const json = try std.json.Stringify.valueAlloc(arena, source, .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return proto.Message.parse(arena, value);
}

/// Newest creation first, id as a deterministic tie breaker. Caller owns
/// returned info and strings in `arena`.
/// Newest first; with `query`, only sessions whose title or message text
/// contains it (ignoring ASCII case).
pub fn listSessions(rt: *Runtime, arena: Allocator, location: ?[]const u8, query: ?[]const u8) ![]@import("session.zig").Info {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    var result: std.ArrayList(@import("session.zig").Info) = .empty;
    var it = rt.sessions.valueIterator();
    while (it.next()) |entry| {
        // Includes restored legacy logs whose only records are a header or updates.
        entry.*.session.mutex.lockUncancelable(rt.io);
        const has_messages = entry.*.session.messages.items.len != 0;
        entry.*.session.mutex.unlock(rt.io);
        if (!has_messages) continue;
        const info = entry.*.session.info;
        if (location) |filter| if (!std.mem.eql(u8, filter, info.location)) continue;
        if (query) |text| if (!@import("session_search.zig").matches(entry.*.session, text)) continue;
        try result.append(arena, .{
            .id = try arena.dupe(u8, info.id),
            .location = try arena.dupe(u8, info.location),
            .created = info.created,
            .title = if (info.title) |title| try arena.dupe(u8, title) else null,
            .forkedFrom = if (info.forkedFrom) |v| try arena.dupe(u8, v) else null,
            .forkedAt = if (info.forkedAt) |v| try arena.dupe(u8, v) else null,
        });
    }
    std.mem.sort(@import("session.zig").Info, result.items, {}, struct {
        fn less(_: void, a: @import("session.zig").Info, b: @import("session.zig").Info) bool {
            if (a.created != b.created) return a.created > b.created;
            return std.mem.lessThan(u8, b.id, a.id);
        }
    }.less);
    return result.items;
}

/// Synchronously stop one session only. A simultaneous prompt/delete sees
/// SessionBusy until the worker has joined and the inbox has been cleared.
pub fn abortSession(rt: *Runtime, id: []const u8) !void {
    rt.mutex.lockUncancelable(rt.io);
    const entry = rt.sessions.get(id) orelse {
        rt.mutex.unlock(rt.io);
        return error.SessionNotFound;
    };
    if (entry.stopping) {
        rt.mutex.unlock(rt.io);
        return error.SessionBusy;
    }
    entry.stopping = true;
    rt.mutex.unlock(rt.io);
    entry.worker.cancel(rt.io);
    entry.title_worker.cancel(rt.io);
    rt.mutex.lockUncancelable(rt.io);
    entry.inbox.clear();
    rt.publishInbox(entry);
    entry.running = false;
    rt.bus.publishValue(types.session_idle, id, entry.session.info.location, .{}) catch {};
    entry.stopping = false;
    rt.mutex.unlock(rt.io);
}

pub fn abort(rt: *Runtime, id: []const u8) !void {
    return rt.abortSession(id);
}

/// Deletes an idle or active session; never destroys its memory before its
/// worker is joined. Storage deletion is delegated to Session.delete.
pub fn deleteSession(rt: *Runtime, id: []const u8) !void {
    rt.mutex.lockUncancelable(rt.io);
    const entry = rt.sessions.get(id) orelse {
        rt.mutex.unlock(rt.io);
        return error.SessionNotFound;
    };
    if (entry.stopping) {
        rt.mutex.unlock(rt.io);
        return error.SessionBusy;
    }
    entry.stopping = true;
    rt.mutex.unlock(rt.io);
    entry.worker.cancel(rt.io);
    entry.title_worker.cancel(rt.io);
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    errdefer {
        entry.inbox.clear();
        rt.publishInbox(entry);
        entry.running = false;
        entry.stopping = false;
    }
    // Persisted data must be removed before the entry becomes unreachable.
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    // Saved results first: if they cannot go, the session stays and the
    // delete can be retried.
    const saved = try @import("artifacts.zig").dir(arena_state.allocator(), rt.sessions_dir, entry.session.info.location, id);
    try Io.Dir.cwd().deleteTree(rt.io, saved);
    const path = try session_storage.logPath(arena_state.allocator(), rt.sessions_dir, entry.session.info.location, id);
    if (entry.session.file != null) try Io.Dir.cwd().deleteFile(rt.io, path);
    rt.bus.publishValue(types.session_deleted, id, entry.session.info.location, .{}) catch {};
    _ = rt.sessions.remove(id);
    entry.inbox.deinit();
    if (entry.pending_options) |pending| freeOverrides(rt, pending);
    freeOverrides(rt, entry.overrides);
    @import("shell.zig").drop(rt, entry);
    entry.session.destroy(rt.gpa, rt.io);
    rt.gpa.destroy(entry);
}

pub fn freeOverrides(rt: *Runtime, opts: config.Options) void {
    if (opts.profile) |v| rt.gpa.free(v);
    if (opts.model) |v| rt.gpa.free(v);
    if (opts.environment) |env| {
        if (env.profile) |v| rt.gpa.free(v);
        if (env.model) |v| rt.gpa.free(v);
    }
}
