//! Extension host: runs extensions found in `extensions/` directories and
//! the `extensions` config list, one process per server for user
//! extensions and one per project for project ones (started when the
//! project is first used). A run waits for extensions still registering.
//! Reload restarts a scope's extensions; `retry` restarts one.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const Extension = @import("Extension.zig");
const discover = @import("discover.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Host = Extension.Host;

pub const Extensions = struct {
    host: Host,
    io: Io,
    mutex: Io.Mutex = .init,
    user: std.ArrayList(*Extension) = .empty,
    /// Location → its extensions. Keys owned.
    locations: std.StringHashMapUnmanaged(std.ArrayList(*Extension)) = .empty,
    /// Replaced by a reload: stopped, freed at deinit.
    retired: std.ArrayList(*Extension) = .empty,
    /// Stops replaced extensions in the background, so a reload does not
    /// wait for their processes to end.
    cleanup: Io.Group = .init,
    /// Set by `shutdownAll`: nothing new starts.
    closing: bool = false,

    /// `self` must outlive the registry.
    pub fn register(self: *Extensions) !void {
        try self.host.registry.addLoader(.{ .name = "extensions", .ctx = self, .load = load, .settle = settle, .status = status, .retry = retry });
    }

    /// First teardown step, before the runtime goes: stops every extension
    /// and waits for calls into the host still being answered. Memory stays
    /// until `deinit`, after the runtime's workers are gone.
    pub fn shutdownAll(self: *Extensions) void {
        // Once closing is set, no list changes, so walking them unlocked is
        // safe (and an extension's call into the host can take the lock).
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.mutex.unlock(self.io);
        self.cleanup.await(self.io) catch {};
        for (self.user.items) |e| e.shutdown();
        var it = self.locations.valueIterator();
        while (it.next()) |list| for (list.items) |e| e.shutdown();
        for (self.retired.items) |e| e.shutdown();
        for (self.user.items) |e| e.quiesce();
        it = self.locations.valueIterator();
        while (it.next()) |list| for (list.items) |e| e.quiesce();
        for (self.retired.items) |e| e.quiesce();
    }

    pub fn deinit(self: *Extensions) void {
        const gpa = self.host.gpa;
        self.cleanup.await(self.io) catch {};
        for (self.user.items) |e| e.destroy();
        self.user.deinit(gpa);
        var it = self.locations.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |e| e.destroy();
            entry.value_ptr.deinit(gpa);
            gpa.free(entry.key_ptr.*);
        }
        self.locations.deinit(gpa);
        for (self.retired.items) |e| e.destroy();
        self.retired.deinit(gpa);
    }

    fn load(ctx: ?*anyopaque, arena: Allocator, io: Io, location: ?[]const u8) anyerror![]const plugin.Registry.Failure {
        const self: *Extensions = @ptrCast(@alignCast(ctx.?));
        var problems: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList(Extension.Source) = .empty;
        if (location) |here| {
            for ([_][]const u8{ ".agents", ".zeta" }) |dir| {
                try sources.appendSlice(arena, try discover.directory(arena, io, try std.fs.path.join(arena, &.{ here, dir, "extensions" }), &problems));
            }
            const cfg = core.config.load(arena, io, self.host.env, self.host.config_dir, here) catch |err| blk: {
                try problems.append(arena, try std.fmt.allocPrint(arena, "extensions: config: {s}", .{@errorName(err)}));
                break :blk core.config.Config{};
            };
            try sources.appendSlice(arena, try discover.configured(arena, cfg.extensions, here, &problems));
        } else {
            try sources.appendSlice(arena, try discover.directory(arena, io, try std.fs.path.join(arena, &.{ self.host.home, ".agents", "extensions" }), &problems));
            try sources.appendSlice(arena, try discover.directory(arena, io, try std.fs.path.join(arena, &.{ self.host.config_dir, "extensions" }), &problems));
        }
        var failures: std.ArrayList(plugin.Registry.Failure) = .empty;
        for (problems.items) |p| try failures.append(arena, .{ .plugin = "extensions", .message = p });

        const gpa = self.host.gpa;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return failures.items;
        const list = if (location) |here| blk: {
            const slot = try self.locations.getOrPut(gpa, here);
            if (!slot.found_existing) {
                slot.key_ptr.* = gpa.dupe(u8, here) catch |err| {
                    self.locations.removeByPtr(slot.key_ptr);
                    return err;
                };
                slot.value_ptr.* = .empty;
            }
            break :blk slot.value_ptr;
        } else &self.user;
        if (list.items.len > 0) {
            try self.retired.ensureUnusedCapacity(gpa, list.items.len);
            const old = try gpa.dupe(*Extension, list.items);
            // Their registrations go now, before replacements register the
            // same names; their processes end in the background.
            for (old) |e| e.detach();
            self.retired.appendSliceAssumeCapacity(old);
            list.clearRetainingCapacity();
            // Without a task to spare they stop at shutdown rather than
            // here, under the loader lock.
            self.cleanup.concurrent(io, stopAll, .{ gpa, old }) catch gpa.free(old);
        }
        for (sources.items) |source| {
            const e = Extension.create(&self.host, io, source, location) catch |err| {
                try failures.append(arena, .{ .plugin = source.name orelse source.origin, .message = @errorName(err) });
                continue;
            };
            list.append(gpa, e) catch |err| {
                e.destroy();
                return err;
            };
        }
        return failures.items;
    }

    fn stopAll(gpa: Allocator, list: []const *Extension) Io.Cancelable!void {
        defer gpa.free(list);
        for (list) |e| e.shutdown();
    }

    /// The extensions that apply at `location`, copied; freed only at deinit.
    fn applying(self: *Extensions, arena: Allocator, io: Io, location: []const u8) ![]const *Extension {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(*Extension) = .empty;
        try out.appendSlice(arena, self.user.items);
        if (self.locations.get(location)) |list| try out.appendSlice(arena, list.items);
        return out.items;
    }

    fn settle(ctx: ?*anyopaque, io: Io, location: []const u8) Io.Cancelable!void {
        const self: *Extensions = @ptrCast(@alignCast(ctx.?));
        var arena: std.heap.ArenaAllocator = .init(self.host.gpa);
        defer arena.deinit();
        const list = self.applying(arena.allocator(), io, location) catch return;
        const deadline = Io.Clock.awake.now(io).toMilliseconds() + Extension.register_timeout_ms;
        for (list) |e| {
            const left = deadline - Io.Clock.awake.now(io).toMilliseconds();
            if (left <= 0) return;
            try e.settle(@intCast(left));
        }
    }

    fn status(ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8) anyerror!std.json.Value {
        const self: *Extensions = @ptrCast(@alignCast(ctx.?));
        var out: std.json.Array = .init(arena);
        for (try self.applying(arena, io, location)) |e| {
            const s = try e.status(arena);
            try out.append(try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, s, .{}), .{}));
        }
        return .{ .array = out };
    }

    fn retry(ctx: ?*anyopaque, io: Io, location: []const u8, name: []const u8) anyerror!bool {
        const self: *Extensions = @ptrCast(@alignCast(ctx.?));
        var arena: std.heap.ArenaAllocator = .init(self.host.gpa);
        defer arena.deinit();
        // Extensions are freed only at deinit, so retrying needs no lock.
        for (try self.applying(arena.allocator(), io, location)) |e| {
            const s = try e.status(arena.allocator());
            if (std.mem.eql(u8, s.name, name)) return e.retry();
        }
        return false;
    }
};

test {
    _ = @import("register.zig");
    _ = @import("discover.zig");
    _ = @import("Process.zig");
    _ = @import("adapters.zig");
    _ = @import("providers.zig");
}
