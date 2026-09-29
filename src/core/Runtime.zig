//! Sessions and their workers. One worker task per busy session; prompts
//! land in the session inbox and the worker drains it through the loop.

const Runtime = @This();

const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bus = @import("bus.zig").Bus;
const Session = @import("session.zig").Session;
const Inbox = @import("inbox.zig").Inbox;
const Delivery = @import("inbox.zig").Delivery;
const Loop = @import("loop.zig").Loop;
const config = @import("config.zig");
const prompt_mod = @import("prompt.zig");
const permissions = @import("permissions.zig");
const types = proto.event.types;

pub const Snapshot = struct {
    /// Subscribe first; discard frames with seq <= revision. `inbox` includes
    /// leased inputs until persisted; `inflight` folds all prior deltas.
    /// session.inbox.updated replaces the inbox and permission.resolved
    /// removes pending asks in later frames.
    revision: u64,
    info: @import("session.zig").Info,
    options: config.Options,
    running: bool,
    inbox: []const @import("inbox.zig").Item,
    pendingPermissions: []const permissions.Broker.PendingInfo,
    messages: []const proto.Message,
    /// Current assistant draft, including every delta through `revision`.
    /// Null when no message is streaming. Arena-owned like `messages`.
    inflight: ?proto.Message,
    /// Cursor for the next, older page; null at the beginning of history.
    nextBefore: ?[]const u8,
};

pub const Context = struct {
    location: []const u8,
    options: config.Options,
};

pub const MessagePage = struct {
    messages: []const proto.Message,
    nextBefore: ?[]const u8,
};

gpa: Allocator,
io: Io,
bus: *Bus,
registry: *plugin.Registry,
env: *const std.process.Environ.Map,
config_dir: []const u8,
sessions_dir: []const u8,
/// Where the last picked model is remembered; null remembers nothing.
state_dir: ?[]const u8 = null,
ids: proto.id.Generator = .{},
mutex: Io.Mutex = .init,
sessions: std.StringHashMapUnmanaged(*Entry) = .empty,
broker: ?permissions.Broker = null,
/// Questions plugins ask the user; made on first use (it keeps a pointer
/// to `ids`, so not before the runtime has its place).
asks: ?@import("elicitation.zig").Asks = null,
resources: ?Resources = null,

pub const Entry = struct {
    session: *Session,
    inbox: Inbox,
    overrides: config.Options,
    /// Frozen on admission; the next run observes later selector changes.
    pending_options: ?config.Options = null,
    pending_selected: bool = false,
    /// The thinking selection when the pending run was admitted; bytes in
    /// the session arena.
    pending_thinking: ?[]const u8 = null,
    running: bool = false,
    active_images: ?bool = null,
    stopping: bool = false,
    /// session_start hooks have run in this process. Worker-only.
    started: bool = false,
    /// Consecutive automatic compaction failures. Worker-only.
    compaction_failures: u8 = 0,
    worker: Io.Group = .init,
    title_worker: Io.Group = .init,
    title_running: bool = false,
    /// Borrowed from the active loop arena; accessed only under rt.mutex.
    draft: ?proto.Message = null,
};

pub const Options = struct {
    config_dir: []const u8,
    sessions_dir: []const u8,
    state_dir: ?[]const u8 = null,
    resources: ?Resources = null,
};

pub const Prepared = struct {
    /// Plugin id the listing shows for these tools.
    plugin: []const u8 = "resources",
    /// Additional tools and prompt sections, borrowed from the run arena.
    tools: []const plugin.tool.Tool = &.{},
    sections: []const prompt_mod.Section = &.{},
};

/// Composition-root extension seam for per-location skills/resources.
pub const Resources = struct {
    ctx: ?*anyopaque = null,
    prepare: *const fn (?*anyopaque, Allocator, Io, []const u8, config.Config, []const plugin.tool.Tool) anyerror!Prepared,
    /// Extra listing entries (an object, e.g. `skills`) for the registry
    /// listing; wholly owned by the given arena.
    inspect: ?*const fn (?*anyopaque, Allocator, Io, config.Config, []const u8) anyerror!std.json.Value = null,
    /// Prompt-template commands for a location, read fresh on each call;
    /// wholly owned by the given arena.
    commands: ?*const fn (?*anyopaque, Allocator, Io, []const u8) anyerror!@import("commands.zig").Listing = null,
};

pub const init = @import("runtime_create.zig").init;
pub const runView = @import("runtime_view.zig").assemble;

pub fn deinit(rt: *Runtime) void {
    var workers = rt.sessions.valueIterator();
    while (workers.next()) |entry| {
        entry.*.worker.cancel(rt.io);
        entry.*.title_worker.cancel(rt.io);
    }
    var it = rt.sessions.valueIterator();
    while (it.next()) |e| {
        e.*.inbox.deinit();
        if (rt.broker) |*broker| broker.clearSession(e.*.session.info.id);
        if (e.*.overrides.profile) |profile| rt.gpa.free(profile);
        if (e.*.overrides.model) |model| rt.gpa.free(model);
        if (e.*.overrides.environment) |current| {
            if (current.profile) |profile| rt.gpa.free(profile);
            if (current.model) |model| rt.gpa.free(model);
        }
        if (e.*.pending_options) |pending| @import("runtime_state.zig").freeOverrides(rt, pending);
        e.*.session.destroy(rt.gpa, rt.io);
        rt.gpa.destroy(e.*);
    }
    if (rt.broker) |*broker| broker.deinit();
    if (rt.asks) |*asks| asks.deinit();
    rt.sessions.deinit(rt.gpa);
}

pub const createSession = @import("runtime_create.zig").createSession;
pub const createSessionWithOptions = @import("runtime_create.zig").createSessionWithOptions;
pub const createSessionWithOptionsOwned = @import("runtime_create.zig").createSessionWithOptionsOwned;
pub const fork = @import("runtime_create.zig").forkSession;
pub const replyPermission = @import("runtime_create.zig").replyPermission;
pub const disconnectPermissions = @import("runtime_create.zig").disconnectPermissions;
pub const asker = @import("runtime_asks.zig").asker;
pub const replyElicitation = @import("runtime_asks.zig").reply;
pub const elicitations = @import("runtime_asks.zig").list;

pub const restore = @import("runtime_restore.zig").restore;
pub const move = @import("session_move.zig").move;
pub const RestoreReport = @import("runtime_restore.zig").RestoreReport;
pub const snapshot = @import("runtime_state.zig").snapshot;
pub const snapshotPage = @import("runtime_state.zig").snapshotPage;
pub const messages = @import("runtime_state.zig").messages;
pub const context = @import("runtime_state.zig").context;
pub const listSessions = @import("runtime_state.zig").listSessions;
pub const abortSession = @import("runtime_state.zig").abortSession;
pub const abort = @import("runtime_state.zig").abort;
pub const deleteSession = @import("runtime_state.zig").deleteSession;
pub const updateSession = @import("runtime_actions.zig").updateSession;
pub const removeInboxItem = @import("runtime_actions.zig").removeInboxItem;
pub const removeInboxItemOwned = @import("runtime_actions.zig").removeInboxItemOwned;
pub const Update = @import("runtime_actions.zig").Update;
pub const requestTitle = @import("runtime_title.zig").requestTitle;
pub const command = @import("commands.zig").run;

/// Queues a compaction of the session's history (after anything already
/// waiting), with optional instructions for the summary. Returns its inbox id.
pub fn compact(rt: *Runtime, session_id: []const u8, instructions: []const u8) !proto.id.Buf {
    const inbox_id = rt.ids.next(rt.io, .message);
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    try entry.inbox.pushCompact(inbox_id.slice(), instructions);
    rt.publishInbox(entry);
    try rt.ensureWorker(entry);
    return inbox_id;
}

/// Admits a prompt and makes sure a worker is draining the inbox. Returns
/// the inbox id (also the user message id).
pub fn prompt(rt: *Runtime, session_id: []const u8, text: []const u8, delivery: Delivery) !proto.id.Buf {
    return rt.promptWithImages(session_id, text, delivery, &.{});
}

/// Validates and owns image contents in the inbox until durable promotion.
pub fn promptWithImages(rt: *Runtime, session_id: []const u8, text: []const u8, delivery: Delivery, images: []const proto.attachment.Image) !proto.id.Buf {
    const inbox_id = rt.ids.next(rt.io, .message);
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(session_id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    if (images.len > 0) try @import("runtime_images.zig").check(rt, entry);
    try entry.inbox.pushWithImages(inbox_id.slice(), text, delivery, images);
    rt.publishInbox(entry);
    try rt.ensureWorker(entry);
    return inbox_id;
}

/// Starts a worker for `entry` unless one is draining it. Caller holds
/// rt.mutex.
fn ensureWorker(rt: *Runtime, entry: *Entry) !void {
    if (!entry.running) {
        entry.pending_options = try @import("runtime_state.zig").copyOptions(rt.gpa, entry.overrides);
        entry.pending_selected = entry.session.model_selected;
        entry.pending_thinking = entry.session.metadata.thinking;
        // Reap the old completed worker before reusing its group.
        entry.worker.await(rt.io) catch {};
        entry.running = true;
        entry.active_images = null;
        entry.worker.concurrent(rt.io, work, .{ rt, entry }) catch |err| {
            @import("runtime_state.zig").freeOverrides(rt, entry.pending_options.?);
            entry.pending_options = null;
            entry.running = false;
            return err;
        };
    }
}

fn work(rt: *Runtime, entry: *Entry) Io.Cancelable!void {
    while (true) {
        rt.runOnce(entry) catch |err| switch (err) {
            error.Canceled => {
                rt.mutex.lockUncancelable(rt.io);
                if (!entry.stopping) {
                    entry.inbox.clear();
                    rt.publishInbox(entry);
                    entry.running = false;
                    rt.bus.publishValue(types.session_idle, entry.session.info.id, entry.session.info.location, .{}) catch {};
                }
                rt.mutex.unlock(rt.io);
                return error.Canceled;
            },
            else => rt.fail(entry, err),
        };
        rt.mutex.lockUncancelable(rt.io);
        defer rt.mutex.unlock(rt.io);
        if (entry.inbox.isEmpty()) {
            entry.running = false;
            rt.bus.publishValue(types.session_idle, entry.session.info.id, entry.session.info.location, .{}) catch {};
            return;
        }
    }
}

fn runOnce(rt: *Runtime, entry: *Entry) !void {
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const location = entry.session.info.location;
    rt.mutex.lockUncancelable(rt.io);
    const pending = entry.pending_options;
    const selected = if (pending != null) entry.pending_selected else entry.session.model_selected;
    // Session-arena bytes: stable while the session lives.
    const selected_thinking = if (pending != null) entry.pending_thinking else entry.session.metadata.thinking;
    const run_options = pending orelse @import("runtime_state.zig").copyOptions(rt.gpa, entry.overrides) catch |err| {
        rt.mutex.unlock(rt.io);
        return err;
    };
    entry.pending_options = null;
    rt.mutex.unlock(rt.io);
    defer @import("runtime_state.zig").freeOverrides(rt, run_options);
    var cfg = try config.loadWithOptions(arena, rt.io, rt.env, rt.config_dir, location, run_options);
    if (selected) cfg.model = run_options.model;
    // Plugins connecting in the background (e.g. MCP servers) get a bounded
    // chance to be part of this run.
    _ = try rt.registry.activate(arena, location);
    try rt.registry.settle(location);
    try @import("runtime_model.zig").fill(rt, arena, location, &cfg);
    const model_ref = cfg.model orelse return error.NoModelConfigured;
    const ref = config.splitModel(model_ref) orelse return error.InvalidModelRef;
    // Resuming later continues on what this session ran with.
    if (!selected) try @import("runtime_model.zig").pin(rt, entry, model_ref, if (selected_thinking == null) cfg.thinking else null);

    const view = try @import("runtime_view.zig").assemble(rt, arena, location, cfg);
    for (view.diagnostics) |message| std.log.warn("{s}: {s}", .{ location, message });
    if (view.config_invalid) return error.InvalidPluginConfig;
    // Deferred tools run only through a dispatch tool.
    var offered: std.ArrayList(plugin.provider.ToolDecl) = .empty;
    for (view.tools) |tool| if (!tool.deferred) try offered.append(arena, tool.declaration());
    const declarations = offered.items;
    rt.mutex.lockUncancelable(rt.io);
    if (rt.broker == null) {
        rt.broker = permissions.Broker.init(rt.gpa, rt.io, rt.bus, &rt.ids);
        rt.broker.?.state_mutex = &rt.mutex;
    }
    rt.mutex.unlock(rt.io);
    var gate: Gate = .{ .rt = rt, .entry = entry, .rules = cfg.permission, .timeout_ms = cfg.tool_timeout_ms, .hooks = .{
        .list = view.registry.hooks,
        .scope = .{ .session = entry.session.info.id, .location = location, .provider = ref.provider, .model = ref.model },
    } };
    // Only this worker reads or writes `started`.
    const session_start: ?plugin.hook.SessionSource = if (entry.started) null else if (entry.session.messages.items.len == 0) .startup else .@"resume";

    const route = @import("runtime_route.zig");
    const routed = try route.resolve(view.registry, arena, rt.io, cfg, ref.provider, ref.model);
    rt.mutex.lockUncancelable(rt.io);
    entry.active_images = routed.options.accepts_images;
    rt.mutex.unlock(rt.io);

    var loop: Loop = .{
        .gpa = rt.gpa,
        .io = rt.io,
        .bus = rt.bus,
        .ids = &rt.ids,
        .session = entry.session,
        .inbox = &entry.inbox,
        .state_mutex = &rt.mutex,
        .inflight = &entry.draft,
        .config = .{
            .api = routed.api,
            .options = routed.options,
            .provider_id = ref.provider,
            .model_id = ref.model,
            .system = view.system,
            .tools = declarations,
            .executable_tools = view.tools,
            .approval = .{ .ctx = &gate, .check = Gate.check },
            .tool_timeout_ms = cfg.tool_timeout_ms,
            .hooks = view.registry.hooks,
            .session_start = session_start,
            .session_started = &entry.started,
            .compaction = cfg.compaction,
            .artifacts_dir = try @import("artifacts.zig").dir(arena, rt.sessions_dir, location, entry.session.info.id),
            .compaction_failures = &entry.compaction_failures,
            .thinking = route.thinkingLevel(selected_thinking, routed.options, cfg.thinking),
        },
    };
    try loop.run();
}

const Gate = @import("runtime_gate.zig").Gate;

/// A failure outside the loop (bad config, …): report it and drop what was
/// waiting, since retrying would fail the same way.
fn fail(rt: *Runtime, entry: *Entry, err: anyerror) void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dropped = if (entry.inbox.snapshot(a)) |items| items.len else |_| 0;
    entry.inbox.clear();
    rt.publishInbox(entry);
    rt.bus.publishValue(types.session_error, entry.session.info.id, entry.session.info.location, .{
        .@"error" = @errorName(err),
        .dropped = dropped,
    }) catch {};
}

/// Caller holds rt.mutex. Publishing a full inbox projection means an SSE
/// subscriber can replace its hydrated inbox after an admission or clearing.
pub fn publishInbox(rt: *Runtime, entry: *Entry) void {
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    const items = entry.inbox.snapshot(arena.allocator()) catch return;
    rt.bus.publishValue(types.session_inbox_updated, entry.session.info.id, entry.session.info.location, .{ .inbox = items }) catch {};
}

test {
    _ = @import("runtime_lifecycle_test.zig");
    _ = @import("runtime_snapshot_test.zig");
    _ = @import("runtime_title_test.zig");
    _ = @import("runtime_provider_test.zig");
    _ = @import("runtime_tools.zig");
    _ = @import("runtime_route.zig");
    _ = @import("runtime_view.zig");
    _ = @import("inspect.zig");
    _ = @import("commands.zig");
    _ = @import("compaction.zig");
    _ = @import("artifacts.zig");
    _ = @import("compaction_test.zig");
    _ = @import("plugin_config.zig");
    _ = @import("hooks.zig");
    _ = @import("runtime_model.zig");
    _ = @import("runtime_model_test.zig");
}
