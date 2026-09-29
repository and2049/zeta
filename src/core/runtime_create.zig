//! Session admission and small runtime request helpers.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const Session = @import("session.zig").Session;
const config = @import("config.zig");
const permissions = @import("permissions.zig");
const types = @import("proto").event.types;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn init(gpa: Allocator, io: std.Io, bus: *@import("bus.zig").Bus, registry: *@import("plugin").Registry, env: *const std.process.Environ.Map, options: Runtime.Options) Runtime {
    return .{
        .gpa = gpa,
        .io = io,
        .bus = bus,
        .registry = registry,
        .env = env,
        .config_dir = options.config_dir,
        .sessions_dir = options.sessions_dir,
        .state_dir = options.state_dir,
        .resources = options.resources,
    };
}

/// Borrowed strings are valid only until this session is deleted.
pub fn createSession(rt: *Runtime, location: []const u8) !@import("session.zig").Info {
    return rt.createSessionWithOptions(location, .{});
}

/// Copies CLI overrides for the session lifetime; config is reloaded each run.
pub fn createSessionWithOptions(rt: *Runtime, location: []const u8, overrides: config.Options) !@import("session.zig").Info {
    return createSessionImpl(rt, null, location, overrides, .{});
}

/// Owns returned info in `arena`, safe across a concurrent DELETE. Route
/// handlers should serialize this value instead of the borrowed variant.
pub fn createSessionWithOptionsOwned(rt: *Runtime, arena: Allocator, location: []const u8, overrides: config.Options) !@import("session.zig").Info {
    return createSessionImpl(rt, arena, location, overrides, .{});
}

/// What a new session starts with besides its selectors: copied history
/// and where it was forked from.
const Seed = struct {
    /// The id chosen in advance (a fork's, whose saved output is copied
    /// to it first); otherwise a new one.
    id: ?[]const u8 = null,
    messages: []const @import("proto").Message = &.{},
    fork: ?@import("session.zig").Fork = null,
    /// A fork's saved-output directories: paths in the copied history
    /// pointing into `from` are rewritten to `to`, removed on failure.
    artifacts: ?struct { from: []const u8, to: []const u8 } = null,
    model_selected: bool = false,
};

/// Every tool call in `messages` is answered by a result after it: a batch
/// still running in the source would leave the copy with calls never
/// answered. Ids may repeat across batches.
fn complete(arena: Allocator, messages: []const @import("proto").Message) !bool {
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    for (messages) |m| {
        if (m.role == .tool_result) {
            if (m.toolCallId) |id| _ = pending.remove(id);
            continue;
        }
        for (m.content) |c| if (c == .tool_call) try pending.put(arena, c.tool_call.id, {});
    }
    return pending.count() == 0;
}

/// Copies session `source` up to and including message `at` (the latest
/// when null) into a new session in the same project with the same model
/// selection; results of tool calls in that message come along, and so
/// does saved tool output. Returned info lives in `arena`.
pub fn forkSession(rt: *Runtime, arena: Allocator, source: []const u8, at: ?[]const u8) !@import("session.zig").Info {
    const artifacts = @import("artifacts.zig");
    const id = try arena.dupe(u8, rt.ids.next(rt.io, .session).slice());
    var copy, const overrides, const selected, const model, const thinking, const end, const from, const to = blk: {
        // Under the lock, like a delete, so the source's strings and saved
        // output cannot go while they are copied.
        rt.mutex.lockUncancelable(rt.io);
        defer rt.mutex.unlock(rt.io);
        const entry = rt.sessions.get(source) orelse return error.SessionNotFound;
        var copy = try entry.session.snapshot(rt.gpa);
        errdefer copy.deinit();
        const messages = copy.messages;
        var end: usize = messages.len;
        if (at) |wanted| {
            end = for (messages, 0..) |m, i| {
                if (std.mem.eql(u8, m.id, wanted)) break i + 1;
            } else return error.MessageNotFound;
            while (end < messages.len and messages[end].role == .tool_result) end += 1;
        }
        if (!try complete(arena, messages[0..end])) return error.SessionBusy;
        const location = copy.info.location;
        const from = try artifacts.dir(arena, rt.sessions_dir, location, source);
        const to = try artifacts.dir(arena, rt.sessions_dir, location, id);
        // Until the new session owns the copy, a failure removes it.
        errdefer Io.Dir.cwd().deleteTree(rt.io, to) catch {};
        try artifacts.copyAll(rt.io, from, to);
        break :blk .{
            copy,
            try @import("runtime_state.zig").copyOptions(arena, entry.overrides),
            entry.session.model_selected,
            if (entry.session.metadata.model) |m| try arena.dupe(u8, m) else null,
            if (entry.session.metadata.thinking) |t| try arena.dupe(u8, t) else null,
            end,
            from,
            to,
        };
    };
    defer copy.deinit();
    const messages = copy.messages;
    var options = overrides;
    if (selected) options.model = model;
    options.thinking = thinking;
    return createSessionImpl(rt, arena, copy.info.location, options, .{
        .id = id,
        .messages = messages[0..end],
        .fork = if (end > 0) .{ .session = source, .message = messages[end - 1].id } else null,
        .artifacts = .{ .from = from, .to = to },
        .model_selected = selected,
    });
}

fn createSessionImpl(rt: *Runtime, owned: ?Allocator, location: []const u8, overrides: config.Options, seed: Seed) !@import("session.zig").Info {
    errdefer if (seed.artifacts) |dirs| Io.Dir.cwd().deleteTree(rt.io, dirs.to) catch {};
    var fresh: @TypeOf(rt.ids.next(rt.io, .session)) = undefined;
    const id = seed.id orelse blk: {
        fresh = rt.ids.next(rt.io, .session);
        break :blk fresh.slice();
    };
    var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
    defer scratch.deinit();
    // Worked out first, so undoing admission needs no allocation.
    const log = try @import("session_storage.zig").logPath(scratch.allocator(), rt.sessions_dir, location, id);
    const session = try Session.createFrom(rt.gpa, rt.io, rt.sessions_dir, id, location, .{
        .profile = overrides.profile,
        .model = overrides.model,
        .environment_present = overrides.environment != null,
        .environment_profile = if (overrides.environment) |env| env.profile else null,
        .environment_model = if (overrides.environment) |env| env.model else null,
    }, seed.fork);
    // A session that fails admission leaves no log to be restored later.
    errdefer {
        const persisted = session.file != null;
        session.destroy(rt.gpa, rt.io);
        if (persisted) Io.Dir.cwd().deleteFile(rt.io, log) catch {};
    }
    var messages = seed.messages;
    // The fork's saved output is its own copy, so deleting either session
    // leaves the other's intact.
    if (seed.artifacts) |dirs| messages = try @import("artifacts.zig").relink(scratch.allocator(), messages, dirs.from, dirs.to);
    for (messages) |m| try session.append(m);
    // Logged so the selection survives a restart, like an interactive pick.
    if (seed.model_selected) if (overrides.model) |m| try session.update(m, null, null);
    if (overrides.thinking) |level| {
        if (!@import("proto").thinking.validSelection(level)) return error.InvalidThinkingLevel;
        try session.update(null, null, level);
    }
    const entry = try rt.gpa.create(Runtime.Entry);
    errdefer rt.gpa.destroy(entry);
    const profile = if (overrides.profile) |p| try rt.gpa.dupe(u8, p) else null;
    errdefer if (profile) |p| rt.gpa.free(p);
    const model = if (overrides.model) |m| try rt.gpa.dupe(u8, m) else null;
    errdefer if (model) |m| rt.gpa.free(m);
    const current_profile = if (overrides.environment) |current| (if (current.profile) |p| try rt.gpa.dupe(u8, p) else null) else null;
    errdefer if (current_profile) |p| rt.gpa.free(p);
    const current_model = if (overrides.environment) |current| (if (current.model) |m| try rt.gpa.dupe(u8, m) else null) else null;
    errdefer if (current_model) |m| rt.gpa.free(m);
    entry.* = .{ .session = session, .inbox = .init(rt.gpa, rt.io), .overrides = .{
        .profile = profile,
        .model = model,
        .environment = if (overrides.environment != null) .{ .profile = current_profile, .model = current_model } else null,
    } };
    const result = if (owned) |arena| @import("session.zig").Info{
        .id = try arena.dupe(u8, session.info.id),
        .location = try arena.dupe(u8, session.info.location),
        .created = session.info.created,
        .title = null,
        .forkedFrom = if (session.info.forkedFrom) |v| try arena.dupe(u8, v) else null,
        .forkedAt = if (session.info.forkedAt) |v| try arena.dupe(u8, v) else null,
    } else session.info;
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    try rt.sessions.put(rt.gpa, session.info.id, entry);
    rt.bus.publishValue(types.session_created, session.info.id, location, .{ .session = session.info }) catch {};
    return result;
}

/// False for an unknown or already-answered permission request.
pub fn replyPermission(rt: *Runtime, id: []const u8, answer: permissions.Reply) bool {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    if (rt.broker) |*broker| return broker.reply(id, answer);
    return false;
}

/// The last event listener left: open permission asks deny and open
/// questions decline.
pub fn disconnectPermissions(rt: *Runtime) void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    if (rt.broker) |*broker| broker.disconnect();
    if (rt.asks) |*a| a.disconnect();
}

test "a fork needs every copied tool call answered" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const call: @import("proto").Message = .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{
        .{ .tool_call = .{ .id = "c1", .name = "read", .arguments = "{}" } },
        .{ .tool_call = .{ .id = "c2", .name = "read", .arguments = "{}" } },
    } };
    const one: @import("proto").Message = .{ .id = "r1", .role = .tool_result, .timestamp = 0, .toolCallId = "c1", .content = &.{} };
    const two: @import("proto").Message = .{ .id = "r2", .role = .tool_result, .timestamp = 0, .toolCallId = "c2", .content = &.{} };
    try std.testing.expect(!try complete(arena.allocator(), &.{ call, one }));
    try std.testing.expect(try complete(arena.allocator(), &.{ call, one, two }));
    // A result from an earlier batch does not answer a reused id.
    try std.testing.expect(!try complete(arena.allocator(), &.{ call, one, two, call, one }));
}
