//! Server-owned sign-in state for any provider that offers a login flow.
//! Only one flow is retained at a time; starting a new one cancels a pending
//! one. This prevents a client that exits mid-sign-in from blocking the next
//! login. A finished flow's tokens are stored as the provider's credential.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("platform");
const Login = @import("plugin").provider.Login;

pub const Receipt = struct { id: []const u8, url: []const u8, instructions: []const u8 };
pub const Status = struct { status: []const u8, @"error": ?[]const u8 = null };

const Flow = struct {
    arena: std.heap.ArenaAllocator,
    id: [32]u8,
    /// Owned by `arena`'s child allocator, freed with the flow.
    provider: []u8,
    login: Login,
    state: ?*anyopaque,
    status: Status = .{ .status = "pending" },
    canceled: Io.Event = .unset,
};

gate: Io.Mutex = .init,
mutex: Io.Mutex = .init,
flow: ?*Flow = null,
tasks: Io.Group = .init,

/// `login` and its ctx must outlive the flow (registry plugins do).
pub fn start(self: *@This(), gpa: Allocator, receipt_allocator: Allocator, io: Io, data_dir: []const u8, provider: []const u8, login: Login, method: []const u8) !Receipt {
    self.gate.lockUncancelable(io);
    defer self.gate.unlock(io);
    self.mutex.lockUncancelable(io);
    if (self.flow) |flow| if (std.mem.eql(u8, flow.status.status, "pending")) flow.canceled.set(io);
    self.mutex.unlock(io);
    // Joins the superseded flow: its listener is closed before a new bind.
    try self.tasks.await(io);
    if (self.flow) |previous| {
        self.mutex.lockUncancelable(io);
        self.flow = null;
        self.mutex.unlock(io);
        gpa.free(previous.provider);
        gpa.destroy(previous);
    }
    const flow = try gpa.create(Flow);
    errdefer gpa.destroy(flow);
    const owned_provider = try gpa.dupe(u8, provider);
    errdefer gpa.free(owned_provider);
    flow.* = .{ .arena = .init(gpa), .id = undefined, .provider = owned_provider, .login = login, .state = undefined };
    errdefer flow.arena.deinit();
    const started = try login.start(login.ctx, flow.arena.allocator(), io, method);
    flow.state = started.state;
    errdefer login.close(login.ctx, flow.state.?, io);
    var random: [16]u8 = undefined;
    io.random(&random);
    flow.id = std.fmt.bytesToHex(random, .lower);
    const id = try receipt_allocator.dupe(u8, &flow.id);
    errdefer receipt_allocator.free(id);
    const url = try receipt_allocator.dupe(u8, started.url);
    errdefer receipt_allocator.free(url);
    const instructions = try receipt_allocator.dupe(u8, started.instructions);
    errdefer receipt_allocator.free(instructions);
    const receipt: Receipt = .{ .id = id, .url = url, .instructions = instructions };
    try self.tasks.concurrent(io, run, .{ self, flow, io, data_dir });
    self.mutex.lockUncancelable(io);
    self.flow = flow;
    self.mutex.unlock(io);
    return receipt;
}

fn run(self: *@This(), flow: *Flow, io: Io, data_dir: []const u8) Io.Cancelable!void {
    const Choice = union(enum) { finish: anyerror!void, cancel: Io.Cancelable!void, timeout: Io.Cancelable!void };
    const result: ?Choice = blk: {
        var storage: [3]Choice = undefined;
        var select: Io.Select(Choice) = .init(io, &storage);
        // The losing finish task MUST be canceled and joined before closing its
        // callback listener or discarding token buffers.
        defer select.cancelDiscard();
        select.concurrent(.finish, finishTask, .{ flow, io, data_dir }) catch break :blk null;
        select.concurrent(.cancel, Io.Event.wait, .{ &flow.canceled, io }) catch break :blk null;
        select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromSeconds(600), Io.Clock.awake }) catch break :blk null;
        break :blk select.await() catch null;
    };
    flow.login.close(flow.login.ctx, flow.state.?, io);
    flow.arena.deinit();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    flow.state = null;
    flow.status = if (result) |choice| switch (choice) {
        // Error names are static strings, safe after arena cleanup and contain
        // no authorization codes, tokens, or provider response bodies.
        .finish => |finished| if (finished) |_| .{ .status = "complete" } else |err| .{ .status = "error", .@"error" = @errorName(err) },
        .cancel => .{ .status = "error", .@"error" = "authentication canceled" },
        .timeout => .{ .status = "error", .@"error" = "authentication timed out" },
    } else .{ .status = "error", .@"error" = "authentication canceled" };
}

fn finishTask(flow: *Flow, io: Io, data_dir: []const u8) anyerror!void {
    const a = flow.arena.allocator();
    const tokens = try flow.login.finish(flow.login.ctx, flow.state.?, a, io);
    try platform.credentials.putOAuth(a, io, data_dir, flow.provider, .{
        .access = tokens.access,
        .refresh = tokens.refresh,
        .expires = tokens.expires,
        .account_id = tokens.account_id,
    });
}

/// The flow `id`, if it is `provider`'s.
pub fn status(self: *@This(), io: Io, provider: []const u8, id: []const u8) ?Status {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const flow = self.flow orelse return null;
    if (!std.mem.eql(u8, id, &flow.id) or !std.mem.eql(u8, provider, flow.provider)) return null;
    return flow.status;
}

pub fn cancel(self: *@This(), io: Io, provider: []const u8, id: []const u8) Io.Cancelable!bool {
    self.gate.lockUncancelable(io);
    defer self.gate.unlock(io);
    self.mutex.lockUncancelable(io);
    const flow = self.flow orelse {
        self.mutex.unlock(io);
        return false;
    };
    if (!std.mem.eql(u8, id, &flow.id) or !std.mem.eql(u8, provider, flow.provider)) {
        self.mutex.unlock(io);
        return false;
    }
    if (std.mem.eql(u8, flow.status.status, "pending")) {
        flow.canceled.set(io);
    }
    self.mutex.unlock(io);
    // No persistence or listener use may continue after the DELETE receipt.
    try self.tasks.await(io);
    return true;
}

pub fn deinit(self: *@This(), io: Io) void {
    self.tasks.cancel(io);
    if (self.flow) |flow| {
        const gpa = flow.arena.child_allocator;
        std.debug.assert(flow.state == null);
        gpa.free(flow.provider);
        gpa.destroy(flow);
    }
    self.flow = null;
}

const Tokens = @import("plugin").provider.Tokens;
const Started = @import("plugin").provider.Started;

test "one retained flow, cancel, and a new start supersedes a pending one" {
    const Fake = struct {
        var closed: std.atomic.Value(u32) = .init(0);
        var persisted: std.atomic.Value(u32) = .init(0);
        fn start(_: ?*anyopaque, a: Allocator, _: Io, _: []const u8) !Started {
            const state = try a.create(u8);
            state.* = 1;
            return .{ .url = "https://example.invalid/authorize", .instructions = "Open browser", .state = state };
        }
        fn finish(_: ?*anyopaque, _: *anyopaque, _: Allocator, io: Io) !Tokens {
            try io.sleep(.fromSeconds(60), .awake);
            _ = persisted.fetchAdd(1, .acq_rel);
            return .{ .access = "", .refresh = "", .expires = 0 };
        }
        fn close(_: ?*anyopaque, _: *anyopaque, _: Io) void {
            _ = closed.fetchAdd(1, .acq_rel);
        }
    };
    Fake.closed.store(0, .release);
    Fake.persisted.store(0, .release);
    const io = std.testing.io;
    const a = std.testing.allocator;
    const login: Login = .{ .start = Fake.start, .finish = Fake.finish, .close = Fake.close };
    var manager: @This() = .{};
    defer manager.deinit(io);
    const first = try manager.start(a, a, io, "unused", "acme", login, "browser");
    defer a.free(first.id);
    defer a.free(first.url);
    defer a.free(first.instructions);
    try std.testing.expectEqualStrings("pending", manager.status(io, "acme", first.id).?.status);
    try std.testing.expect(manager.status(io, "other", first.id) == null);
    try std.testing.expect(!try manager.cancel(io, "acme", "not-this-flow"));
    try std.testing.expect(try manager.cancel(io, "acme", first.id));
    try std.testing.expectEqualStrings("error", manager.status(io, "acme", first.id).?.status);
    try std.testing.expectEqual(@as(u32, 1), Fake.closed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Fake.persisted.load(.acquire));
    const second = try manager.start(a, a, io, "unused", "acme", login, "browser");
    defer a.free(second.id);
    defer a.free(second.url);
    defer a.free(second.instructions);
    try std.testing.expect(manager.status(io, "acme", first.id) == null);
    try std.testing.expectEqualStrings("pending", manager.status(io, "acme", second.id).?.status);
    // An abandoned pending flow is closed by the next start.
    const third = try manager.start(a, a, io, "unused", "acme", login, "device");
    defer a.free(third.id);
    defer a.free(third.url);
    defer a.free(third.instructions);
    try std.testing.expectEqual(@as(u32, 2), Fake.closed.load(.acquire));
    try std.testing.expect(manager.status(io, "acme", second.id) == null);
    try std.testing.expectEqualStrings("pending", manager.status(io, "acme", third.id).?.status);
    try std.testing.expect(try manager.cancel(io, "acme", third.id));
    try std.testing.expectEqual(@as(u32, 3), Fake.closed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Fake.persisted.load(.acquire));
}

test "a finished flow stores the provider's tokens; a failed one reports why; both close first" {
    const Fake = struct {
        var closed: std.atomic.Value(u32) = .init(0);
        fn start(_: ?*anyopaque, a: Allocator, _: Io, method: []const u8) !Started {
            const state = try a.create(bool);
            state.* = std.mem.eql(u8, method, "device");
            return .{ .url = "url", .instructions = "instructions", .state = state };
        }
        fn finish(_: ?*anyopaque, state: *anyopaque, _: Allocator, _: Io) !Tokens {
            const fails: *bool = @ptrCast(@alignCast(state));
            if (fails.*) return error.FakeExchangeFailure;
            return .{ .access = "access-token", .refresh = "refresh-token", .expires = 1 };
        }
        fn close(_: ?*anyopaque, _: *anyopaque, _: Io) void {
            _ = closed.fetchAdd(1, .acq_rel);
        }
    };
    Fake.closed.store(0, .release);
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var manager: @This() = .{};
    defer manager.deinit(io);
    for ([_][]const u8{ "browser", "device" }, 0..) |method, i| {
        const receipt = try manager.start(a, a, io, dir, "acme", .{ .start = Fake.start, .finish = Fake.finish, .close = Fake.close }, method);
        defer a.free(receipt.id);
        defer a.free(receipt.url);
        defer a.free(receipt.instructions);
        try manager.tasks.await(io);
        const observed = manager.status(io, "acme", receipt.id).?;
        const ok = i == 0;
        try std.testing.expectEqualStrings(if (ok) "complete" else "error", observed.status);
        if (!ok) try std.testing.expectEqualStrings("FakeExchangeFailure", observed.@"error".?);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), Fake.closed.load(.acquire));
        try std.testing.expect(manager.flow.?.state == null);
    }
    var stored = (try platform.credentials.readOAuth(a, io, dir, "acme")).?;
    defer stored.deinit();
    try std.testing.expectEqualStrings("access-token", stored.access);
}
