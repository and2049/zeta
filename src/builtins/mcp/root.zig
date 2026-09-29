//! MCP client: the servers in a location's `mcp` config connect in the
//! background when the location is first used, and their tools become
//! ordinary tools (`mcp__<server>__<tool>`). A run waits for servers still
//! connecting, up to the startup timeout, then takes what is connected.
//! Reload restarts a location's servers; `retry` restarts one.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const config = @import("config.zig");
const Server = @import("Server.zig");
const signin = @import("signin.zig");
const deferred = @import("deferred.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Mcp = struct {
    host: Server.Host,
    io: Io,
    config_dir: []const u8,
    mutex: Io.Mutex = .init,
    /// Location → its servers. Keys owned.
    locations: std.StringHashMapUnmanaged(std.ArrayList(*Server)) = .empty,
    /// Servers a reload replaced: stopped, freed at deinit.
    retired: std.ArrayList(*Server) = .empty,
    /// Stops replaced servers in the background, so a reload does not wait
    /// for their processes and sessions to end.
    cleanup: Io.Group = .init,
    /// Made by `register`, before any request can read it.
    sign_in: ?signin.Pending = null,
    /// Set by `shutdownAll`: nothing is loaded after it.
    closed: bool = false,
    /// Per location with deferred servers: the plugin holding `mcp_search`
    /// and `mcp_call`. Keys are those of `locations`.
    searchers: std.StringHashMapUnmanaged(plugin.Registry.Owner) = .empty,
    /// Serializes sign-ins.
    sign_in_mutex: Io.Mutex = .init,

    /// `self` must outlive the registry.
    pub fn register(self: *Mcp) !void {
        self.sign_in = .{ .gpa = self.host.gpa, .io = self.io, .reconnect = .{ .ctx = self, .retry = retry } };
        try self.host.registry.addLoader(.{ .name = "mcp", .ctx = self, .load = load, .settle = settle, .status = status, .retry = retry, .login = login, .logout = logout });
    }

    /// Stops every server and sign-in: nothing waits on the runtime after
    /// this. Before the runtime goes; `deinit` frees them later.
    pub fn shutdownAll(self: *Mcp) void {
        // Stopped here, freed by `deinit`.
        if (self.sign_in) |*p| p.tasks.cancel(self.io);
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        var it = self.locations.valueIterator();
        while (it.next()) |list| for (list.items) |server| server.shutdown();
        for (self.retired.items) |server| server.shutdown();
        self.mutex.unlock(self.io);
        // Replaced servers still being stopped in the background.
        self.cleanup.await(self.io) catch {};
    }

    pub fn deinit(self: *Mcp) void {
        const gpa = self.host.gpa;
        if (self.sign_in) |*p| p.deinit();
        self.cleanup.await(self.io) catch {};
        var it = self.locations.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |server| server.destroy();
            entry.value_ptr.deinit(gpa);
            gpa.free(entry.key_ptr.*);
        }
        self.locations.deinit(gpa);
        self.searchers.deinit(gpa);
        for (self.retired.items) |server| server.destroy();
        self.retired.deinit(gpa);
    }

    fn load(ctx: ?*anyopaque, arena: Allocator, io: Io, location: ?[]const u8) anyerror![]const plugin.Registry.Failure {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        const here = location orelse return &.{};
        const cfg = core.config.load(arena, io, self.host.env, self.config_dir, here) catch |err|
            return arena.dupe(plugin.Registry.Failure, &.{.{ .plugin = "mcp", .message = @errorName(err) }});
        const settings = try config.parse(arena, cfg.mcp);
        var failures: std.ArrayList(plugin.Registry.Failure) = .empty;
        for (settings.problems) |problem| try failures.append(arena, .{ .plugin = "mcp", .message = problem });
        const gpa = self.host.gpa;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return failures.items;
        const slot = try self.locations.getOrPut(gpa, here);
        if (slot.found_existing) {
            try self.retired.ensureUnusedCapacity(gpa, slot.value_ptr.items.len);
            const old = try gpa.dupe(*Server, slot.value_ptr.items);
            // Their tools go now, before replacements register the same
            // plugin ids; their connections end in the background.
            for (old) |server| server.detach();
            self.retired.appendSliceAssumeCapacity(old);
            slot.value_ptr.clearRetainingCapacity();
            // Without a task to spare they stop at deinit rather than here,
            // under the loader lock.
            self.cleanup.concurrent(io, stopAll, .{ gpa, old }) catch gpa.free(old);
        } else {
            slot.key_ptr.* = gpa.dupe(u8, here) catch |err| {
                self.locations.removeByPtr(slot.key_ptr);
                return err;
            };
            slot.value_ptr.* = .empty;
        }
        try self.offerSearch(slot.key_ptr.*, settings.servers);
        for (settings.servers) |spec| {
            const server = Server.create(&self.host, io, here, spec, settings.timeout_ms) catch |err| {
                try failures.append(arena, .{ .plugin = try std.fmt.allocPrint(arena, "mcp:{s}", .{spec.name}), .message = @errorName(err) });
                continue;
            };
            slot.value_ptr.append(gpa, server) catch |err| {
                server.destroy();
                return err;
            };
        }
        return failures.items;
    }

    /// Registers `mcp_search` and `mcp_call` at `here` (a key of
    /// `locations`, which outlives every registry view) when a server there
    /// is deferred, replacing what an earlier load registered. Caller holds
    /// `mutex`.
    fn offerSearch(self: *Mcp, here: []const u8, specs: []const config.Server) !void {
        const registry = self.host.registry;
        const wanted = for (specs) |spec| {
            if (spec.deferred and !spec.disabled) break true;
        } else false;
        const old = self.searchers.get(here);
        if (!wanted) {
            if (old) |owner| registry.dispose(owner);
            _ = self.searchers.remove(here);
            return;
        }
        try self.searchers.ensureUnusedCapacity(self.host.gpa, 1);
        const owner = try registry.stage(.{ .id = "mcp", .layer = .project, .location = here, .source = "mcp" }, old);
        errdefer registry.dispose(owner);
        try registry.addTool(owner, deferred.search);
        try registry.addTool(owner, deferred.call);
        registry.commit(owner);
        self.searchers.putAssumeCapacity(here, owner);
    }

    fn stopAll(gpa: Allocator, servers_: []const *Server) Io.Cancelable!void {
        defer gpa.free(servers_);
        for (servers_) |server| server.shutdown();
    }

    /// The location's servers, copied so waiting needs no lock; servers are
    /// only freed at deinit.
    fn servers(self: *Mcp, arena: Allocator, io: Io, location: []const u8) ![]const *Server {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const list = self.locations.get(location) orelse return &.{};
        return arena.dupe(*Server, list.items);
    }

    fn settle(ctx: ?*anyopaque, io: Io, location: []const u8) Io.Cancelable!void {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        var arena: std.heap.ArenaAllocator = .init(self.host.gpa);
        defer arena.deinit();
        const list = self.servers(arena.allocator(), io, location) catch return;
        if (list.len == 0) return;
        // They connect at once, so one shared deadline bounds the wait.
        const deadline = Io.Clock.awake.now(io).toMilliseconds() + @as(i64, @intCast(list[0].startup_ms));
        for (list) |server| {
            const left = deadline - Io.Clock.awake.now(io).toMilliseconds();
            if (left <= 0) return;
            try server.settle(@intCast(left));
        }
    }

    fn status(ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8) anyerror!std.json.Value {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.json.Array = .init(arena);
        if (self.locations.get(location)) |list| for (list.items) |server| {
            // The sign-in first: once it reads `done`, the connection it
            // started is already under way, so the status read next is it.
            const latest = self.sign_in.?.latestFor(location, server.spec.name);
            const s = try server.status(arena);
            var item = try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, s, .{}), .{});
            try item.object.put(arena, "signIn", if (latest) |l| try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, .{ .id = l.id, .state = @tagName(l.state) }, .{}), .{}) else .null);
            try out.append(item);
        };
        return .{ .array = out };
    }

    /// Servers are freed only at deinit, so using one needs no lock.
    fn find(self: *Mcp, io: Io, location: []const u8, name: []const u8) ?*Server {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const list = self.locations.get(location) orelse return null;
        for (list.items) |server| if (std.mem.eql(u8, server.spec.name, name)) return server;
        return null;
    }

    /// Servers called `name` in every project, copied into `arena`.
    fn named(self: *Mcp, arena: Allocator, io: Io, name: []const u8) ![]const *Server {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(*Server) = .empty;
        var it = self.locations.valueIterator();
        while (it.next()) |list| for (list.items) |server| if (std.mem.eql(u8, server.spec.name, name)) try out.append(arena, server);
        return out.items;
    }

    fn retry(ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        const found = self.find(io, location, name) orelse return false;
        return found.retry();
    }

    fn login(ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, name: []const u8) anyerror!?plugin.Registry.Loaders.SignIn {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        const found = self.find(io, location, name) orelse return null;
        if (!found.signsIn()) return error.McpSignInUnavailable;
        self.sign_in_mutex.lockUncancelable(io);
        defer self.sign_in_mutex.unlock(io);
        const started = try self.sign_in.?.start(arena, found, self.host.data_dir.?);
        return .{ .id = started.id, .url = started.url, .instructions = started.instructions };
    }

    fn logout(ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool {
        const self: *Mcp = @ptrCast(@alignCast(ctx.?));
        const found = self.find(io, location, name) orelse return false;
        if (!found.signsIn()) return error.McpSignInUnavailable;
        self.sign_in_mutex.lockUncancelable(io);
        defer self.sign_in_mutex.unlock(io);
        // The credential is shared by servers of that name in every
        // project: a sign-in still waiting for the browser would store it
        // again, and connected servers would keep using it.
        self.sign_in.?.cancelFor(name);
        var buf: [256]u8 = undefined;
        _ = try @import("platform").credentials.mcp.remove(self.host.gpa, io, self.host.data_dir.?, try @import("platform").credentials.mcp.id(&buf, name));
        var arena: std.heap.ArenaAllocator = .init(self.host.gpa);
        defer arena.deinit();
        for (try self.named(arena.allocator(), io, name)) |server| if (server.signsIn()) {
            _ = try server.retry();
        };
        return true;
    }
};

test {
    _ = config;
    _ = Server;
    _ = @import("rpc.zig");
    _ = @import("stdio.zig");
    _ = @import("names.zig");
    _ = @import("listing.zig");
    _ = @import("requests.zig");
    _ = @import("result.zig");
    _ = @import("oauth.zig");
    _ = @import("oauth_test.zig");
    _ = @import("auth.zig");
    _ = signin;
    _ = @import("tools.zig");
    _ = @import("prompts.zig");
    _ = deferred;
    _ = @import("elicit.zig");
}
