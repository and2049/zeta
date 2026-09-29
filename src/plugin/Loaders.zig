//! Plugins from outside the binary (files, processes) are built by loaders,
//! one scope at a time: the user layer, and each project location the first
//! time something asks for it. Reload rebuilds them. What failed to load
//! stays listed as a problem of its scope until that scope loads again.

const Loaders = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A plugin that could not be loaded; on reload it keeps its previous version.
pub const Failure = struct { plugin: []const u8, message: []const u8 };

pub const Loader = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    /// Builds or rebuilds this loader's plugins for one scope: the user
    /// layer (`location` null) or one project location, swapping each with
    /// `Registry.stage`/`commit`. Failures live in `arena`; the others swap in.
    load: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, location: ?[]const u8) anyerror![]const Failure,
    /// Waits until what `load` started for `location` in the background
    /// (connections, processes) is ready or has failed, bounded by the
    /// loader's own timeout. A run calls this before it takes its view.
    /// Returns `error.Canceled` when the waiting task is canceled.
    settle: ?*const fn (ctx: ?*anyopaque, io: Io, location: []const u8) Io.Cancelable!void = null,
    /// Live state of what it loaded for `location`, as JSON in `arena`.
    status: ?*const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8) anyerror!std.json.Value = null,
    /// Starts one named thing for `location` again; false if it has no such
    /// thing.
    retry: ?*const fn (ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool = null,
    /// Starts signing in to one named thing for `location` (an MCP server):
    /// what the user opens, in `arena`. Null if it has no such thing. The
    /// sign-in finishes in the background and connects the thing again.
    login: ?*const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, name: []const u8) anyerror!?SignIn = null,
    /// Forgets the named thing's sign-in and connects it again; false if it
    /// has no such thing.
    logout: ?*const fn (ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool = null,
};

/// `id` names this sign-in in status listings.
pub const SignIn = struct { id: u64 = 0, url: []const u8, instructions: []const u8 };

/// A failure recorded for a scope (`location` null: the user layer).
pub const Problem = struct { loader: []const u8, location: ?[]const u8, plugin: []const u8, message: []const u8 };

gpa: Allocator,
/// Serializes loads; loaders call back into the registry, so this is never
/// held together with the registry's own lock.
mutex: Io.Mutex = .init,
list: std.ArrayList(Loader) = .empty,
user_loaded: bool = false,
/// Locations loaded so far, owned.
locations: std.ArrayList([]u8) = .empty,
/// Guards `problems`, whose strings are owned.
problems_mutex: Io.Mutex = .init,
problems: std.ArrayList(Problem) = .empty,

pub fn deinit(l: *Loaders) void {
    for (l.locations.items) |location| l.gpa.free(location);
    l.locations.deinit(l.gpa);
    for (l.problems.items) |p| l.freeProblem(p);
    l.problems.deinit(l.gpa);
    l.list.deinit(l.gpa);
}

/// `loader` and its ctx must outlive the registry.
pub fn add(l: *Loaders, io: Io, loader: Loader) !void {
    l.mutex.lockUncancelable(io);
    defer l.mutex.unlock(io);
    try l.list.append(l.gpa, loader);
}

/// Loads the user layer and `location` the first time each is asked for.
/// Returns what failed in this call only.
pub fn activate(l: *Loaders, io: Io, arena: Allocator, location: ?[]const u8) ![]const Failure {
    l.mutex.lockUncancelable(io);
    defer l.mutex.unlock(io);
    var failures: std.ArrayList(Failure) = .empty;
    if (!l.user_loaded) {
        try l.loadScope(io, arena, null, &failures);
        l.user_loaded = true;
    }
    if (location) |here| if (!l.loaded(here)) {
        try l.remember(here);
        try l.loadScope(io, arena, here, &failures);
    };
    return failures.items;
}

/// Rebuilds the user layer and `location` (null: every loaded location).
pub fn reload(l: *Loaders, io: Io, arena: Allocator, location: ?[]const u8) ![]const Failure {
    l.mutex.lockUncancelable(io);
    defer l.mutex.unlock(io);
    var failures: std.ArrayList(Failure) = .empty;
    try l.loadScope(io, arena, null, &failures);
    l.user_loaded = true;
    if (location) |here| {
        if (!l.loaded(here)) try l.remember(here);
        try l.loadScope(io, arena, here, &failures);
    } else for (l.locations.items) |here| try l.loadScope(io, arena, here, &failures);
    return failures.items;
}

/// Runs every loader's `settle` for `location`. Loads are not serialized
/// against it; each loader guards its own state.
pub fn settle(l: *Loaders, io: Io, location: []const u8) Io.Cancelable!void {
    for (l.snapshot(io)) |loader| if (loader.settle) |wait| try wait(loader.ctx, io, location);
}

/// The named loader's status for `location`; null when there is no such
/// loader or it reports none.
pub fn status(l: *Loaders, io: Io, arena: Allocator, name: []const u8, location: []const u8) !?std.json.Value {
    const loader = l.find(io, name) orelse return null;
    const read = loader.status orelse return null;
    return try read(loader.ctx, arena, io, location);
}

/// Every loader's status for `location`, keyed by loader name.
pub fn statuses(l: *Loaders, io: Io, arena: Allocator, location: []const u8) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    for (l.snapshot(io)) |loader| if (loader.status) |read| {
        try out.put(arena, loader.name, try read(loader.ctx, arena, io, location));
    };
    return out;
}

/// Null when there is no such loader or it cannot retry.
pub fn retry(l: *Loaders, io: Io, loader_name: []const u8, location: []const u8, name: []const u8) !?bool {
    const loader = l.find(io, loader_name) orelse return null;
    const again = loader.retry orelse return null;
    return try again(loader.ctx, io, location, name);
}

pub fn login(l: *Loaders, io: Io, arena: Allocator, loader_name: []const u8, location: []const u8, name: []const u8) !?SignIn {
    const loader = l.find(io, loader_name) orelse return null;
    const start = loader.login orelse return null;
    return try start(loader.ctx, arena, io, location, name);
}

pub fn logout(l: *Loaders, io: Io, loader_name: []const u8, location: []const u8, name: []const u8) !?bool {
    const loader = l.find(io, loader_name) orelse return null;
    const forget = loader.logout orelse return null;
    return try forget(loader.ctx, io, location, name);
}

/// Loaders are only ever added, before serving, so a copy of the slice
/// header stays valid.
fn snapshot(l: *Loaders, io: Io) []const Loader {
    l.mutex.lockUncancelable(io);
    defer l.mutex.unlock(io);
    return l.list.items;
}

fn find(l: *Loaders, io: Io, name: []const u8) ?Loader {
    for (l.snapshot(io)) |loader| if (std.mem.eql(u8, loader.name, name)) return loader;
    return null;
}

/// Problems of the user layer and of `location`, copied into `arena`.
pub fn problemsAt(l: *Loaders, io: Io, arena: Allocator, location: ?[]const u8) ![]const Problem {
    l.problems_mutex.lockUncancelable(io);
    defer l.problems_mutex.unlock(io);
    var out: std.ArrayList(Problem) = .empty;
    for (l.problems.items) |p| {
        const applies = if (p.location) |at| location != null and std.mem.eql(u8, at, location.?) else true;
        if (!applies) continue;
        try out.append(arena, .{
            .loader = p.loader,
            .location = if (p.location) |at| try arena.dupe(u8, at) else null,
            .plugin = try arena.dupe(u8, p.plugin),
            .message = try arena.dupe(u8, p.message),
        });
    }
    return out.items;
}

fn loaded(l: *Loaders, location: []const u8) bool {
    for (l.locations.items) |here| if (std.mem.eql(u8, here, location)) return true;
    return false;
}

fn remember(l: *Loaders, location: []const u8) !void {
    const owned = try l.gpa.dupe(u8, location);
    errdefer l.gpa.free(owned);
    try l.locations.append(l.gpa, owned);
}

fn loadScope(l: *Loaders, io: Io, arena: Allocator, location: ?[]const u8, failures: *std.ArrayList(Failure)) !void {
    for (l.list.items) |loader| {
        const found = loader.load(loader.ctx, arena, io, location) catch |err| blk: {
            if (err == error.Canceled) return err;
            break :blk try arena.dupe(Failure, &.{.{ .plugin = loader.name, .message = @errorName(err) }});
        };
        for (found) |f| std.log.warn("{s}: {s}: {s}", .{ location orelse "user", f.plugin, f.message });
        try l.record(io, loader.name, location, found);
        try failures.appendSlice(arena, found);
    }
}

/// Replaces the problems `loader` recorded for this scope.
fn record(l: *Loaders, io: Io, loader: []const u8, location: ?[]const u8, found: []const Failure) !void {
    l.problems_mutex.lockUncancelable(io);
    defer l.problems_mutex.unlock(io);
    var i: usize = 0;
    while (i < l.problems.items.len) {
        const p = l.problems.items[i];
        if (std.mem.eql(u8, p.loader, loader) and sameScope(p.location, location)) {
            l.freeProblem(p);
            _ = l.problems.orderedRemove(i);
        } else i += 1;
    }
    for (found) |f| {
        const at = if (location) |here| try l.gpa.dupe(u8, here) else null;
        errdefer if (at) |owned| l.gpa.free(owned);
        const plugin = try l.gpa.dupe(u8, f.plugin);
        errdefer l.gpa.free(plugin);
        const message = try l.gpa.dupe(u8, f.message);
        errdefer l.gpa.free(message);
        try l.problems.append(l.gpa, .{ .loader = loader, .location = at, .plugin = plugin, .message = message });
    }
}

fn sameScope(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn freeProblem(l: *Loaders, p: Problem) void {
    if (p.location) |at| l.gpa.free(at);
    l.gpa.free(p.plugin);
    l.gpa.free(p.message);
}

const testing = std.testing;

test "activate loads each scope once; reload loads again and replaces problems" {
    var l: Loaders = .{ .gpa = testing.allocator };
    defer l.deinit();
    const Counter = struct {
        user: usize = 0,
        project: usize = 0,
        fn load(ctx: ?*anyopaque, arena: Allocator, _: Io, location: ?[]const u8) anyerror![]const Failure {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (location == null) {
                self.user += 1;
                return &.{};
            }
            self.project += 1;
            if (self.project == 1) return arena.dupe(Failure, &.{.{ .plugin = "hooks", .message = "bad file" }});
            return &.{};
        }
    };
    var counter: Counter = .{};
    try l.add(testing.io, .{ .name = "files", .ctx = &counter, .load = Counter.load });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 1), (try l.activate(testing.io, a, "/p")).len);
    try testing.expectEqual(@as(usize, 0), (try l.activate(testing.io, a, "/p")).len);
    try testing.expectEqual(@as(usize, 1), counter.user);
    try testing.expectEqual(@as(usize, 1), counter.project);
    try testing.expectEqualStrings("bad file", (try l.problemsAt(testing.io, a, "/p"))[0].message);
    try testing.expectEqual(@as(usize, 0), (try l.problemsAt(testing.io, a, "/q")).len);

    _ = try l.reload(testing.io, a, null);
    try testing.expectEqual(@as(usize, 2), counter.user);
    try testing.expectEqual(@as(usize, 2), counter.project);
    try testing.expectEqual(@as(usize, 0), (try l.problemsAt(testing.io, a, "/p")).len);
}

test "settle, status and retry reach the named loader" {
    var l: Loaders = .{ .gpa = testing.allocator };
    defer l.deinit();
    const Fake = struct {
        settled: usize = 0,
        fn load(_: ?*anyopaque, _: Allocator, _: Io, _: ?[]const u8) anyerror![]const Failure {
            return &.{};
        }
        fn settle(ctx: ?*anyopaque, _: Io, _: []const u8) Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.settled += 1;
        }
        fn status(_: ?*anyopaque, _: Allocator, _: Io, location: []const u8) anyerror!std.json.Value {
            return .{ .string = location };
        }
        fn retry(_: ?*anyopaque, _: Io, _: []const u8, name: []const u8) anyerror!bool {
            return std.mem.eql(u8, name, "known");
        }
    };
    var fake: Fake = .{};
    try l.add(testing.io, .{ .name = "servers", .ctx = &fake, .load = Fake.load, .settle = Fake.settle, .status = Fake.status, .retry = Fake.retry });
    try l.add(testing.io, .{ .name = "files", .load = Fake.load });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try l.settle(testing.io, "/p");
    try testing.expectEqual(@as(usize, 1), fake.settled);
    try testing.expectEqualStrings("/p", (try l.status(testing.io, arena.allocator(), "servers", "/p")).?.string);
    try testing.expect(try l.status(testing.io, arena.allocator(), "files", "/p") == null);
    try testing.expectEqual(@as(usize, 1), (try l.statuses(testing.io, arena.allocator(), "/p")).count());
    try testing.expect((try l.retry(testing.io, "servers", "/p", "known")).?);
    try testing.expect(!(try l.retry(testing.io, "servers", "/p", "other")).?);
    try testing.expect(try l.retry(testing.io, "files", "/p", "known") == null);
}
