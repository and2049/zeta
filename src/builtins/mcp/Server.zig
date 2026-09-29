//! One configured MCP server at one location: connects in the background,
//! lists its tools and registers them as the plugin `mcp:<name>` in that
//! location's project layer. A server that dies or fails to connect is
//! `failed` (its tools are gone) until reload or retry; a
//! `tools/list_changed` notification lists and registers them again.
const Server = @This();
const callbacks = @import("server_callbacks.zig");

const std = @import("std");
const plugin = @import("plugin");
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const Stdio = @import("stdio.zig").Stdio;
const Http = @import("http.zig").Http;
const listing = @import("listing.zig");
const requests = @import("requests.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// `needs_auth`: a remote server refused to connect without a sign-in.
pub const State = enum { pending, connected, disabled, failed, needs_auth };

/// What every server shares; owned by the manager.
pub const Host = struct {
    gpa: Allocator,
    registry: *plugin.Registry,
    env: *const std.process.Environ.Map,
    version: []const u8,
    /// Where sign-ins are stored; null leaves remote servers without them.
    data_dir: ?[]const u8 = null,
    /// Asks the user for a server's elicitations; null declares none.
    asker: ?plugin.ask.Asker = null,
};

/// One connection attempt. Kept until the server goes, because a tool call
/// or a run waiting for it may still be using it.
pub const Link = struct {
    server: *Server,
    conn: rpc.Connection,
    transport: union(enum) { none, stdio: *Stdio, http: *Http } = .none,
    stopped: bool = false,
    /// Set once this attempt is no longer pending; never reset.
    ready: Io.Event = .unset,
    /// From `initialize`: the server's instructions (owned by the gpa) and
    /// whether it has prompts.
    instructions: []u8 = &.{},
    tools: bool = true,
    prompts: bool = false,
    /// `tools/call` requests in flight and questions the server has open
    /// (see `requests.zig`); under the server's mutex.
    calls: std.ArrayList(*requests.Call) = .empty,
    questions: std.ArrayList(*requests.Asked) = .empty,
};

host: *Host,
io: Io,
/// Spec, location and names.
arena: std.heap.ArenaAllocator,
spec: config.Server,
location: []const u8,
startup_ms: u64,
mutex: Io.Mutex = .init,
state: State = .pending,
/// Why it failed; owned by the gpa.
problem: ?[]u8 = null,
tool_count: usize = 0,
/// The current attempt; null for a disabled server.
link: ?*Link = null,
links: std.ArrayList(*Link) = .empty,
owner: ?plugin.Registry.Owner = null,
/// Memory of every tool registration; views taken earlier may still use it.
versions: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
tasks: Io.Group = .init,
closing: bool = false,
/// Serializes retry and shutdown.
lifecycle: Io.Mutex = .init,

/// Starts connecting unless the server is disabled.
pub fn create(host: *Host, io: Io, location: []const u8, spec: config.Server, startup_ms: u64) !*Server {
    const s = try host.gpa.create(Server);
    s.* = .{ .host = host, .io = io, .arena = .init(host.gpa), .spec = undefined, .location = undefined, .startup_ms = startup_ms };
    errdefer {
        s.arena.deinit();
        host.gpa.destroy(s);
    }
    const a = s.arena.allocator();
    s.location = try a.dupe(u8, location);
    s.spec = try config.clone(a, spec);
    if (spec.disabled) {
        s.state = .disabled;
        return s;
    }
    try s.attempt();
    return s;
}

/// Starts a connection attempt. It is current at once, so a run that
/// settles right after waits for it.
fn attempt(s: *Server) !void {
    const gpa = s.host.gpa;
    const link = try gpa.create(Link);
    link.* = .{ .server = s, .conn = .{ .gpa = gpa, .io = s.io, .transport = undefined, .notice = .{ .ctx = link, .notify = callbacks.notified, .closed = callbacks.closed, .request = requests.received } } };
    s.mutex.lockUncancelable(s.io);
    s.links.append(gpa, link) catch |err| {
        s.mutex.unlock(s.io);
        gpa.destroy(link);
        return err;
    };
    s.link = link;
    s.mutex.unlock(s.io);
    s.tasks.concurrent(s.io, connect, .{ s, link }) catch |err| {
        link.ready.set(s.io);
        return err;
    };
}

/// Removes the server's tools at once and stops further registration;
/// fast, no I/O. `shutdown` stops the connection afterwards.
pub fn detach(s: *Server) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.closing = true;
    s.state = .failed;
    s.release();
}

/// Removes the registered tools; the caller holds `mutex`, so nobody sees
/// the owner gone while its plugin id is still taken.
fn release(s: *Server) void {
    if (s.owner) |o| s.host.registry.dispose(o);
    s.owner = null;
    s.tool_count = 0;
}

/// Detaches the server and stops its connection. The memory stays until
/// `destroy`, because a run may still be waiting on it or calling a tool.
pub fn shutdown(s: *Server) void {
    s.lifecycle.lockUncancelable(s.io);
    defer s.lifecycle.unlock(s.io);
    s.detach();
    // The transport's readers go first: they are what schedules tasks.
    s.stopLink();
    s.tasks.cancel(s.io);
    s.mutex.lockUncancelable(s.io);
    const link = s.link;
    s.mutex.unlock(s.io);
    if (link) |l| l.ready.set(s.io);
}

/// Shuts the server down and frees it.
pub fn destroy(s: *Server) void {
    const gpa = s.host.gpa;
    s.shutdown();
    for (s.links.items) |link| {
        switch (link.transport) {
            .none => {},
            .stdio => |t| t.destroy(),
            .http => |t| t.destroy(),
        }
        link.conn.deinit();
        gpa.free(link.instructions);
        link.calls.deinit(gpa);
        link.questions.deinit(gpa);
        gpa.destroy(link);
    }
    s.links.deinit(gpa);
    for (s.versions.items) |version| {
        version.deinit();
        gpa.destroy(version);
    }
    s.versions.deinit(gpa);
    if (s.problem) |p| gpa.free(p);
    s.arena.deinit();
    gpa.destroy(s);
}

/// Connects again after a failure (or at once when connected); false when
/// the server is disabled or shut down. Its tools are gone until the new
/// attempt lists them, and runs wait for that attempt.
pub fn retry(s: *Server) !bool {
    s.lifecycle.lockUncancelable(s.io);
    defer s.lifecycle.unlock(s.io);
    s.mutex.lockUncancelable(s.io);
    const stop = s.state == .disabled or s.closing;
    s.mutex.unlock(s.io);
    if (stop) return false;
    s.stopLink();
    s.tasks.cancel(s.io);
    s.mutex.lockUncancelable(s.io);
    s.state = .pending;
    if (s.problem) |p| s.host.gpa.free(p);
    s.problem = null;
    s.release();
    const old = s.link;
    s.mutex.unlock(s.io);
    if (old) |l| l.ready.set(s.io);
    try s.attempt();
    return true;
}

/// Waits until the current attempt finished, at most `ms`.
pub fn settle(s: *Server, ms: u64) Io.Cancelable!void {
    s.mutex.lockUncancelable(s.io);
    const link = s.link;
    s.mutex.unlock(s.io);
    const current = link orelse return;
    const Done = union(enum) { ready: Io.Cancelable!void, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(s.io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.ready, Io.Event.wait, .{ &current.ready, s.io }) catch return;
    select.concurrent(.deadline, Io.sleep, .{ s.io, Io.Duration.fromMilliseconds(@intCast(@min(ms, rpc.forever_ms))), Io.Clock.awake }) catch return;
    _ = try select.await();
}

pub const Status = struct { name: []const u8, status: State, tools: usize, @"error": ?[]const u8 = null };

pub fn status(s: *Server, arena: Allocator) !Status {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return .{ .name = s.spec.name, .status = s.state, .tools = s.tool_count, .@"error" = if (s.problem) |p| try arena.dupe(u8, p) else null };
}

fn connect(s: *Server, link: *Link) Io.Cancelable!void {
    s.establish(link) catch |err| {
        if (err == error.Canceled) {
            link.ready.set(s.io);
            return error.Canceled;
        }
        if (err == error.McpUnauthorized and s.signsIn()) return s.failAs(link, .needs_auth, "sign-in required");
        s.fail(link, @errorName(err));
    };
}

/// A request on `link` was refused and the sign-in could not be renewed:
/// the server needs a new one, and its tools go.
pub fn refused(s: *Server, link: *Link) void {
    s.failAs(link, .needs_auth, "sign-in required");
}

/// Whether the server takes a stored sign-in: a remote server with OAuth
/// on and no `Authorization` header of its own.
pub fn signsIn(s: *const Server) bool {
    const remote = switch (s.spec.transport) {
        .remote => |r| r,
        .local => return false,
    };
    if (!remote.oauth.enabled or s.host.data_dir == null) return false;
    for (remote.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) return false;
    return true;
}

fn bearer(s: *Server) !?@import("auth.zig").Bearer {
    if (!s.signsIn()) return null;
    return try .init(s.host.gpa, s.io, s.host.data_dir.?, s.spec.name, s.spec.transport.remote.url);
}

fn establish(s: *Server, link: *Link) !void {
    const gpa = s.host.gpa;

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const transport: @FieldType(Link, "transport") = switch (s.spec.transport) {
        .local => |local| blk: {
            var env = try s.host.env.clone(a);
            for (local.environment) |pair| try env.put(pair.name, pair.value);
            const cwd = if (local.cwd) |dir| if (std.fs.path.isAbsolute(dir)) dir else try std.fs.path.join(a, &.{ s.location, dir }) else s.location;
            break :blk .{ .stdio = try Stdio.start(gpa, s.io, &link.conn, .{ .command = local.command, .cwd = cwd, .env = &env }) };
        },
        .remote => |remote| .{ .http = try Http.start(gpa, s.io, &link.conn, remote.url, remote.headers, try s.bearer()) },
    };
    // Published under the lock: a link stopped meanwhile never saw this
    // transport, so stopping it is ours. Either way it is freed at destroy.
    s.mutex.lockUncancelable(s.io);
    link.transport = transport;
    const stopped = link.stopped;
    s.mutex.unlock(s.io);
    if (stopped) {
        stopTransport(transport);
        return error.Canceled;
    }
    const capabilities = try std.json.parseFromSliceLeaky(Value, a, if (s.host.asker != null)
        \\{"roots":{"listChanged":false},"elicitation":{"form":{}}}
    else
        \\{"roots":{"listChanged":false}}
    , .{});
    const init = try link.conn.request(a, "initialize", .{
        .protocolVersion = @import("http.zig").protocol_version,
        .capabilities = capabilities,
        .clientInfo = .{ .name = "zeta", .version = s.host.version },
    }, s.startup_ms, null);
    if (init == .object) {
        if (init.object.get("protocolVersion")) |v| if (v == .string) {
            if (link.transport == .http) try link.transport.http.negotiated(v.string);
        };
        if (init.object.get("instructions")) |v| if (v == .string) {
            link.instructions = try gpa.dupe(u8, v.string);
        };
        if (init.object.get("capabilities")) |caps| if (caps == .object) {
            link.tools = caps.object.get("tools") != null;
            link.prompts = caps.object.get("prompts") != null;
        };
    }
    try link.conn.notify(a, "notifications/initialized", rpc.empty);
    try listing.refresh(s, link);
    s.mutex.lockUncancelable(s.io);
    if (s.link == link and !s.closing) s.state = .connected;
    s.mutex.unlock(s.io);
    link.ready.set(s.io);
}

/// Attempt `link` failed: unless another attempt replaced it, the server
/// is failed and its tools are gone.
pub fn fail(s: *Server, link: *Link, reason: []const u8) void {
    s.failAs(link, .failed, reason);
}

fn failAs(s: *Server, link: *Link, state: State, reason: []const u8) void {
    const gpa = s.host.gpa;
    var detail: std.heap.ArenaAllocator = .init(gpa);
    defer detail.deinit();
    const stderr: []const u8 = switch (link.transport) {
        .stdio => |t| t.errors(detail.allocator()) catch "",
        else => "",
    };
    const text = (if (stderr.len > 0)
        std.fmt.allocPrint(gpa, "{s}: {s}", .{ reason, stderr })
    else
        gpa.dupe(u8, reason)) catch null;
    s.mutex.lockUncancelable(s.io);
    const current = s.link == link and !s.closing;
    s.mutex.unlock(s.io);
    if (!current) {
        if (text) |t| gpa.free(t);
        link.ready.set(s.io);
        return;
    }
    // This attempt's link, not whatever is current by the time stopping it
    // is done (a retry may have replaced it meanwhile).
    s.stopGiven(link);
    s.mutex.lockUncancelable(s.io);
    if (s.link != link or s.closing) {
        s.mutex.unlock(s.io);
        if (text) |t| gpa.free(t);
        link.ready.set(s.io);
        return;
    }
    s.state = state;
    if (s.problem) |p| gpa.free(p);
    s.problem = text;
    s.release();
    s.mutex.unlock(s.io);
    std.log.warn("mcp {s}: {s}", .{ s.spec.name, text orelse reason });
    link.ready.set(s.io);
}

fn stopLink(s: *Server) void {
    s.mutex.lockUncancelable(s.io);
    const link = s.link;
    s.mutex.unlock(s.io);
    if (link) |l| s.stopGiven(l);
}

fn stopGiven(s: *Server, link: *Link) void {
    s.mutex.lockUncancelable(s.io);
    const first = !link.stopped;
    link.stopped = true;
    const transport = link.transport;
    s.mutex.unlock(s.io);
    if (!first) return;
    // Waiting requests fail first, then the transport stops; it is freed
    // with the server, since a request may still be finishing with it.
    link.conn.close("stopped");
    stopTransport(transport);
}

fn stopTransport(transport: @FieldType(Link, "transport")) void {
    switch (transport) {
        .none => {},
        .stdio => |t| t.shutdown(),
        .http => |t| t.shutdown(),
    }
}

/// Whether `link` is the live attempt of a server still running; the
/// caller holds `mutex`.
pub fn live(link: *Link) bool {
    const s = link.server;
    return s.link == link and !s.closing and !link.stopped;
}
