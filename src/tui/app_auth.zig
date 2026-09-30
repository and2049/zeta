//! /connect flow orchestration; HTTP stays in the serial worker.
const std = @import("std");
const client = @import("client");
const platform = @import("platform");
const proto = @import("proto");
const App = @import("App.zig");
const Worker = @import("app_network.zig").Worker;
const Result = @import("app_network.zig").Result;
const Request = @import("actions.zig").Request;
const picker = @import("picker.zig");

pub fn dispatch(app: *App, worker: *Worker, req: Request) !void {
    switch (req) {
        .list_providers => {
            app.connect_generation +%= 1;
            app.overlay = .connect_providers;
            app.connect_flow = null;
            app.picker_items = &.{};
            app.picker_waiting = true;
            app.picker_selected = 0;
            app.picker_query.clearRetainingCapacity();
            try worker.submit(.{ .kind = .list_providers, .generation = app.connect_generation });
        },
        .select_provider => |id| for (app.connect_providers) |provider| {
            if (!std.mem.eql(u8, id, provider.id)) continue;
            app.connect_provider = provider;
            app.overlay = .connect_methods;
            _ = app.picker_arena.reset(.retain_capacity);
            const items = try app.picker_arena.allocator().alloc(picker.Item, provider.methods.len);
            for (provider.methods, items) |method, *item| item.* = .{ .id = method.id, .label = method.label };
            app.picker_items = items;
            app.picker_selected = 0;
            app.picker_query.clearRetainingCapacity();
            break;
        },
        .select_method => |id| {
            const provider = app.connect_provider orelse return;
            for (provider.methods) |method| {
                if (!std.mem.eql(u8, id, method.id)) continue;
                if (method.type == .api) {
                    app.clearSecret();
                    app.overlay = .connect_key;
                } else {
                    app.connect_flow = null;
                    app.connect_browser = std.mem.eql(u8, method.id, "browser");
                    app.overlay = .connect_oauth;
                    try worker.submit(.{ .kind = .start_oauth, .text = method.id, .extra = provider.id, .generation = app.connect_generation });
                }
                break;
            }
        },
        .save_key => {
            const provider = app.connect_provider orelse return;
            try worker.submit(.{ .kind = .save_key, .id = provider.id, .text = app.connect_secret.items, .generation = app.connect_generation });
            app.clearSecret();
            app.overlay = .none;
            app.status = "Saving credential…";
        },
        .cancel_flow => |id| {
            app.connect_generation +%= 1;
            app.connect_flow = null;
            try worker.submit(.{ .kind = .cancel_oauth, .id = id, .extra = if (app.connect_provider) |p| p.id else "openai" });
        },
        .open_auth_url => |url| if (app.connect_flow) |flow| {
            try worker.submit(.{ .kind = .open_url, .id = flow.id, .text = url, .generation = app.connect_generation });
        },
        else => unreachable,
    }
}

pub fn result(app: *App, worker: *Worker, gpa: std.mem.Allocator, response: Result) !void {
    switch (response.job.kind) {
        .list_providers => {
            if (stale(app, response.job)) return;
            _ = app.connect_arena.reset(.free_all);
            const parsed = try std.json.parseFromSliceLeaky(client.auth.Providers, app.connect_arena.allocator(), response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            app.connect_providers = parsed.providers;
            _ = app.picker_arena.reset(.retain_capacity);
            const items = try app.picker_arena.allocator().alloc(picker.Item, parsed.providers.len);
            for (parsed.providers, items) |provider, *item| item.* = .{ .id = provider.id, .label = provider.name };
            app.picker_items = items;
            app.picker_waiting = false;
        },
        .save_key => if (!stale(app, response.job)) try connected(app, worker),
        .start_oauth => {
            if (app.overlay != .connect_oauth or app.connect_generation != response.job.generation) {
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                const flow = try std.json.parseFromSliceLeaky(client.auth.Flow, scratch.allocator(), response.body, .{ .ignore_unknown_fields = true });
                try worker.submit(.{ .kind = .cancel_oauth, .id = flow.id, .extra = response.job.extra });
                return;
            }
            app.connect_flow = try std.json.parseFromSliceLeaky(client.auth.Flow, app.connect_arena.allocator(), response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            app.connect_poll_ticks = 0;
            app.connect_url_offset = 0;
            app.connect_instructions_offset = 0;
            if (app.connect_browser) try worker.submit(.{ .kind = .open_url, .id = app.connect_flow.?.id, .text = app.connect_flow.?.url, .generation = app.connect_generation });
        },
        .status_oauth => {
            if (stale(app, response.job)) return;
            app.connect_polling = false;
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const status = try std.json.parseFromSliceLeaky(client.auth.Status, scratch.allocator(), response.body, .{ .ignore_unknown_fields = true });
            switch (status.status) {
                .pending => {},
                .complete => {
                    app.overlay = .none;
                    app.connect_flow = null;
                    try connected(app, worker);
                },
                .@"error" => {
                    app.overlay = .none;
                    app.connect_flow = null;
                    app.status = std.fmt.bufPrint(&app.status_buffer, "Login failed: {s}. Retry /connect.", .{status.@"error" orelse "unknown error"}) catch "Login failed; retry /connect.";
                },
            }
        },
        else => unreachable,
    }
}

/// Ignore errors from obsolete requests; a late start success still needs a
/// cancellation request, handled by `result` above.
pub fn stale(app: *const App, job: @import("app_network.zig").Job) bool {
    return switch (job.kind) {
        .list_providers => app.overlay != .connect_providers or app.connect_generation != job.generation,
        .save_key => app.connect_generation != job.generation,
        .start_oauth => app.overlay != .connect_oauth or app.connect_generation != job.generation,
        .status_oauth => app.overlay != .connect_oauth or app.connect_flow == null or !std.mem.eql(u8, app.connect_flow.?.id, job.id),
        .open_url => app.overlay != .connect_oauth or app.connect_flow == null or !std.mem.eql(u8, app.connect_flow.?.id, job.id),
        else => false,
    };
}

/// Never attaches or spawns a server. On exit, cancel only a known flow ID,
/// bounded so a stopped/unresponsive server cannot hold the terminal open.
pub fn cancelOnExit(gpa: std.mem.Allocator, io: std.Io, paths: platform.Paths, provider: []const u8, id: []const u8) void {
    const Done = union(enum) { canceled: anyerror!void, timeout: std.Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: std.Io.Select(Done) = .init(io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.canceled, cancelKnown, .{ gpa, io, paths, provider, id }) catch return;
    select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(500), std.Io.Clock.awake }) catch return;
    _ = select.await() catch {}; // Best effort. Never reveal response or credentials.
}

fn cancelKnown(gpa: std.mem.Allocator, io: std.Io, paths: platform.Paths, provider: []const u8, id: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = try std.fs.path.join(a, &.{ paths.runtime, proto.discovery.file_name });
    const bytes = (try platform.fs.readFileIfExists(io, a, path, 64 * 1024)) orelse return;
    const discovery = try proto.Discovery.decode(a, bytes);
    if (!platform.process.isAlive(discovery.pid)) return;
    var c = try client.Client.init(gpa, io, discovery.url, discovery.password);
    defer c.deinit();
    try client.auth.cancel(&c, a, provider, id);
}

test "old authentication results are stale" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    app.overlay = .connect_oauth;
    app.connect_generation = 2;
    app.connect_flow = .{ .id = "new", .url = "", .instructions = "" };
    try std.testing.expect(stale(&app, .{ .kind = .start_oauth, .generation = 1 }));
    try std.testing.expect(stale(&app, .{ .kind = .status_oauth, .id = "old" }));
    try std.testing.expect(!stale(&app, .{ .kind = .status_oauth, .id = "new" }));
}

fn connected(app: *App, worker: *Worker) !void {
    app.status = "Connected. Choose a model.";
    if (app.session) |id| {
        app.openPicker(.models, true);
        try worker.submit(.{ .kind = .list_models, .id = id });
    }
}

pub fn tick(app: *App, worker: *Worker) !void {
    if (app.overlay != .connect_oauth or app.connect_flow == null or app.connect_polling) return;
    app.connect_poll_ticks += 1;
    if (app.connect_poll_ticks < 65) return;
    app.connect_poll_ticks = 0;
    app.connect_polling = true;
    try worker.submit(.{ .kind = .status_oauth, .id = app.connect_flow.?.id, .extra = if (app.connect_provider) |p| p.id else "openai" });
}
