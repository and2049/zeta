//! Signing in to a remote MCP server: a loopback redirect listener, the
//! authorization URL for the user to open, then the code exchanged for
//! tokens stored as `mcp:<server>` for the server's URL.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const oauth = @import("oauth.zig");
const wire = @import("../oauth_http.zig");
const callback = @import("../oauth_callback.zig");
const credentials = @import("platform").credentials.mcp;

pub const callback_path = "/callback";
/// How long the user has to finish signing in.
pub const timeout_ms = 10 * 60 * 1000;

pub const Flow = struct {
    arena: std.heap.ArenaAllocator,
    listener: Io.net.Server,
    data_dir: []const u8,
    key: []const u8,
    url: []const u8,
    endpoints: oauth.Endpoints,
    client: oauth.Client,
    pkce: wire.Pkce,
    redirect: []const u8,
    /// What the user opens.
    authorize: []const u8,

    /// Finds the authorization server, listens for the redirect and
    /// registers a client unless one is configured.
    pub fn start(gpa: Allocator, io: Io, data_dir: []const u8, name: []const u8, remote: config.Remote) !*Flow {
        const f = try gpa.create(Flow);
        errdefer gpa.destroy(f);
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        const a = f.arena.allocator();
        var headers: std.ArrayList(std.http.Header) = .empty;
        for (remote.headers) |h| try headers.append(a, .{ .name = h.name, .value = h.value });
        const hint = try oauth.probe(a, io, remote.url, headers.items);
        var endpoints = try oauth.discover(a, io, remote.url, hint);
        if (remote.oauth.scope) |scope| endpoints.scope = scope;
        const address = try Io.net.IpAddress.parse("127.0.0.1", remote.oauth.callback_port orelse 0);
        f.listener = try address.listen(io, .{});
        errdefer f.listener.deinit(io);
        const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ f.listener.socket.address.getPort(), callback_path });
        const client: oauth.Client = if (remote.oauth.client_id) |id|
            .{ .id = id, .secret = remote.oauth.client_secret }
        else
            try oauth.register(a, io, endpoints, redirect);
        const pkce = try wire.pkce(a, io);
        var buf: [256]u8 = undefined;
        f.* = .{
            .arena = f.arena,
            .listener = f.listener,
            .data_dir = try a.dupe(u8, data_dir),
            .key = try a.dupe(u8, try credentials.id(&buf, name)),
            .url = try a.dupe(u8, remote.url),
            .endpoints = endpoints,
            .client = client,
            .pkce = pkce,
            .redirect = redirect,
            .authorize = try oauth.authorizationUrl(a, endpoints, client, redirect, pkce),
        };
        return f;
    }

    /// Waits for the redirect, then stores the tokens. `error.Canceled`
    /// when canceled.
    pub fn finish(f: *Flow, io: Io) !void {
        const a = f.arena.allocator();
        const code = try callback.wait(&f.listener, a, io, callback_path, f.pkce.state, 10_000);
        const value = try oauth.exchange(a, io, f.url, f.endpoints, f.client, f.redirect, code, f.pkce.verifier);
        try Io.checkCancel(io);
        try credentials.put(a, io, f.data_dir, f.key, value);
    }

    pub fn destroy(f: *Flow, gpa: Allocator, io: Io) void {
        f.listener.deinit(io);
        f.arena.deinit();
        gpa.destroy(f);
    }
};

/// The sign-in in progress: starting another cancels it. Its task stores
/// the tokens and then connects the server again.
pub const Pending = struct {
    gpa: Allocator,
    io: Io,
    /// Connects the named server of a location again (the current one, if
    /// a reload replaced it meanwhile).
    reconnect: Reconnect,
    tasks: Io.Group = .init,
    mutex: Io.Mutex = .init,
    /// Which server the running sign-in is for (location, then name):
    /// a reload replaces the server but not these. Owned.
    target: ?[]u8 = null,
    /// The latest sign-in of each server (keys like `target`, owned),
    /// running or ended.
    outcomes: std.StringHashMapUnmanaged(Outcome) = .empty,
    serial: u64 = 0,

    pub const State = enum { running, done, failed };
    pub const Outcome = struct { id: u64, state: State };

    pub const Reconnect = struct {
        ctx: ?*anyopaque,
        retry: *const fn (ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool,
    };

    /// Starts signing in to `server`; the strings returned are in `arena`.
    /// Each step of discovery and registration has its own deadline.
    pub fn start(p: *Pending, arena: Allocator, server: *Server, data_dir: []const u8) !Started {
        // The earlier flow closes its listener before a new one binds.
        p.cancelFor(null);
        const target = try targetOf(p.gpa, server.location, server.spec.name);
        errdefer p.gpa.free(target);
        const flow = try Flow.start(p.gpa, p.io, data_dir, server.spec.name, server.spec.transport.remote);
        errdefer flow.destroy(p.gpa, p.io);
        const url = try arena.dupe(u8, flow.authorize);
        p.mutex.lockUncancelable(p.io);
        const slot = p.outcomes.getOrPut(p.gpa, target) catch |err| {
            p.mutex.unlock(p.io);
            return err;
        };
        if (!slot.found_existing) slot.key_ptr.* = p.gpa.dupe(u8, target) catch |err| {
            p.outcomes.removeByPtr(slot.key_ptr);
            p.mutex.unlock(p.io);
            return err;
        };
        p.serial += 1;
        const id = p.serial;
        slot.value_ptr.* = .{ .id = id, .state = .running };
        p.target = target;
        p.mutex.unlock(p.io);
        p.tasks.concurrent(p.io, run, .{ p, flow, target, id }) catch |err| {
            // Nothing runs it: take back what was published.
            p.mutex.lockUncancelable(p.io);
            p.target = null;
            if (p.outcomes.getPtr(target)) |outcome| outcome.state = .failed;
            p.mutex.unlock(p.io);
            return err;
        };
        return .{ .id = id, .url = url, .instructions = "Open the URL to sign in; the server connects once you have." };
    }

    fn targetOf(gpa: Allocator, location: []const u8, name: []const u8) ![]u8 {
        return std.mem.concat(gpa, u8, &.{ location, "\x00", name });
    }

    /// Cancels the running sign-in when it is for a server called `name`,
    /// in any project (any sign-in, if null): they share its credential.
    pub fn cancelFor(p: *Pending, name: ?[]const u8) void {
        p.mutex.lockUncancelable(p.io);
        const current = p.target;
        const hit = if (current) |t| name == null or std.mem.eql(u8, t[std.mem.indexOfScalar(u8, t, 0).? + 1 ..], name.?) else false;
        p.mutex.unlock(p.io);
        if (!hit) return;
        p.tasks.cancel(p.io);
    }

    /// The latest sign-in of the server `name` at `location`, if any.
    pub fn latestFor(p: *Pending, location: []const u8, name: []const u8) ?Outcome {
        var buf: [4096]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ location, name }) catch return null;
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.outcomes.get(key);
    }

    pub fn deinit(p: *Pending) void {
        p.tasks.cancel(p.io);
        var keys = p.outcomes.keyIterator();
        while (keys.next()) |k| p.gpa.free(k.*);
        p.outcomes.deinit(p.gpa);
    }

    fn run(p: *Pending, flow: *Flow, target: []u8, id: u64) Io.Cancelable!void {
        var ok = false;
        defer {
            flow.destroy(p.gpa, p.io);
            p.mutex.lockUncancelable(p.io);
            if (p.target) |current| if (current.ptr == target.ptr) {
                p.target = null;
            };
            // Recorded after the reconnect has begun, so a client that sees
            // `done` also sees the connection it started.
            if (p.outcomes.getPtr(target)) |outcome| if (outcome.id == id) {
                outcome.state = if (ok) .done else .failed;
            };
            p.mutex.unlock(p.io);
            p.gpa.free(target);
        }
        const split = std.mem.indexOfScalar(u8, target, 0).?;
        const location = target[0..split];
        const name = target[split + 1 ..];
        const Done = union(enum) { finished: anyerror!void, deadline: Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select: Io.Select(Done) = .init(p.io, &storage);
        defer select.cancelDiscard();
        select.concurrent(.finished, Flow.finish, .{ flow, p.io }) catch return;
        select.concurrent(.deadline, Io.sleep, .{ p.io, Io.Duration.fromMilliseconds(timeout_ms), Io.Clock.awake }) catch return;
        switch (try select.await()) {
            .finished => |result| result catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.log.warn("mcp {s}: sign-in failed: {s}", .{ name, @errorName(err) });
                return;
            },
            .deadline => |result| {
                try result;
                std.log.warn("mcp {s}: sign-in timed out", .{name});
                return;
            },
        }
        ok = true;
        _ = p.reconnect.retry(p.reconnect.ctx, p.io, location, name) catch |err|
            std.log.warn("mcp {s}: cannot connect after sign-in: {s}", .{ name, @errorName(err) });
    }
};

const Server = @import("Server.zig");

pub const Started = struct { id: u64, url: []const u8, instructions: []const u8 };
