//! Serial command worker. UI enqueues and polls, never waits for HTTP.
const std = @import("std");
const client = @import("client");
const platform = @import("platform");
const Io = std.Io;
const A = std.mem.Allocator;
const attachments = @import("app_attach.zig");

pub const Kind = enum { create, move, directories, list_sessions, list_models, list_providers, save_key, start_oauth, status_oauth, cancel_oauth, open_url, open_link, copy, shell, stop_shell, files, get, config, page, prompt, abort, rename, auto_title, model, thinking, delete_session, reload, mcp, extensions, compact, fork, remove_inbox, edit_inbox, list_commands, answer_question, list_questions, undo };
pub const Job = struct {
    kind: Kind,
    id: []const u8 = "",
    text: []const u8 = "",
    extra: []const u8 = "",
    images: []const []const u8 = &.{},
    image_data: []const @import("proto").attachment.Image = &.{},
    generation: u64 = 0,
    epoch: u64 = 0,
};
pub const Result = struct { job: Job, body: []const u8 = "", err: ?anyerror = null };

pub const Worker = struct {
    a: A,
    io: Io,
    paths: platform.Paths,
    exe: []const u8,
    serve: []const []const u8 = &.{"serve"},
    log: ?[]const u8 = null,
    /// The client's directory; read and changed under `mutex`.
    cwd: []const u8,
    cwd_owned: ?[]u8 = null,
    environment: ?struct { model: ?[]const u8 = null, profile: ?[]const u8 = null } = null,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    clipboard: platform.clipboard.Hosts = .{},
    mutex: Io.Mutex = .init,
    ready: Io.Event = .unset,
    group: Io.Group = .init,
    queue: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    closed: bool = false,

    pub fn init(a: A, io: Io, paths: platform.Paths, exe: []const u8, cwd: []const u8) Worker {
        return .{ .a = a, .io = io, .paths = paths, .exe = exe, .cwd = cwd };
    }
    pub fn start(w: *Worker) !void {
        try w.group.concurrent(w.io, loop, .{w});
    }
    /// Later jobs run for `path` (e.g. after the session moved).
    pub fn setCwd(w: *Worker, path: []const u8) !void {
        const owned = try w.a.dupe(u8, path);
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        if (w.cwd_owned) |old| w.a.free(old);
        w.cwd_owned = owned;
        w.cwd = owned;
    }

    fn currentCwd(w: *Worker, arena: A) ![]const u8 {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        return arena.dupe(u8, w.cwd);
    }

    pub fn stop(w: *Worker) void {
        w.mutex.lockUncancelable(w.io);
        w.closed = true;
        w.ready.set(w.io);
        w.mutex.unlock(w.io);
        w.group.cancel(w.io);
        for (w.queue.items) |j| w.freeJob(j);
        for (w.results.items) |r| w.release(r);
        w.queue.deinit(w.a);
        w.results.deinit(w.a);
        if (w.cwd_owned) |owned| w.a.free(owned);
    }
    fn freeJob(w: *Worker, j: Job) void {
        w.a.free(j.id);
        if (j.kind == .save_key) @memset(@constCast(j.text), 0);
        w.a.free(j.text);
        w.a.free(j.extra);
        for (j.images) |path| w.a.free(path);
        w.a.free(j.images);
        for (j.image_data) |image| {
            w.a.free(image.mimeType);
            w.a.free(image.data);
        }
        w.a.free(j.image_data);
    }
    pub fn submit(w: *Worker, j: Job) !void {
        const images = try w.a.alloc([]const u8, j.images.len);
        var image_count: usize = 0;
        errdefer {
            for (images[0..image_count]) |path| w.a.free(path);
            w.a.free(images);
        }
        for (j.images, 0..) |path, i| {
            images[i] = try w.a.dupe(u8, path);
            image_count += 1;
        }
        const image_data = try w.a.alloc(@import("proto").attachment.Image, j.image_data.len);
        var data_count: usize = 0;
        errdefer {
            for (image_data[0..data_count]) |image| {
                w.a.free(image.mimeType);
                w.a.free(image.data);
            }
            w.a.free(image_data);
        }
        for (j.image_data, image_data) |image, *copy| {
            copy.* = try @import("proto").attachment.Image.init(w.a, image.mimeType, image.data);
            data_count += 1;
        }
        const id = try w.a.dupe(u8, j.id);
        errdefer w.a.free(id);
        const text = try w.a.dupe(u8, j.text);
        errdefer w.a.free(text);
        const extra = try w.a.dupe(u8, j.extra);
        errdefer w.a.free(extra);
        const copy: Job = .{ .kind = j.kind, .id = id, .text = text, .extra = extra, .images = images, .image_data = image_data, .generation = j.generation, .epoch = j.epoch };
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        try w.queue.append(w.a, copy);
        w.ready.set(w.io);
    }
    pub fn poll(w: *Worker) ?Result {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        if (w.results.items.len == 0) return null;
        return w.results.orderedRemove(0);
    }
    pub fn release(w: *Worker, r: Result) void {
        w.freeJob(r.job);
        if (r.body.len > 0) w.a.free(r.body);
    }
    fn loop(w: *Worker) Io.Cancelable!void {
        while (true) {
            w.mutex.lockUncancelable(w.io);
            if (w.closed) {
                w.mutex.unlock(w.io);
                return;
            }
            const j = if (w.queue.items.len > 0) w.queue.orderedRemove(0) else null;
            if (w.queue.items.len == 0) w.ready.reset();
            w.mutex.unlock(w.io);
            if (j == null) {
                try w.ready.wait(w.io);
                continue;
            }
            var arena: std.heap.ArenaAllocator = .init(w.a);
            const result = w.execute(arena.allocator(), j.?) catch |err| blk: {
                if (err == error.Canceled) {
                    arena.deinit();
                    w.freeJob(j.?);
                    return error.Canceled;
                }
                break :blk Result{ .job = j.?, .err = err };
            };
            arena.deinit();
            w.mutex.lockUncancelable(w.io);
            w.results.append(w.a, result) catch {
                w.freeJob(result.job);
                if (result.body.len > 0) w.a.free(result.body);
            };
            w.mutex.unlock(w.io);
        }
    }
    fn execute(w: *Worker, arena: A, j: Job) !Result {
        if (j.kind == .open_url or j.kind == .open_link) {
            try @import("platform").browser.open(w.io, j.text);
            return .{ .job = j };
        }
        if (j.kind == .copy) {
            try platform.clipboard.copy(w.io, w.clipboard, j.text);
            return .{ .job = j };
        }
        const d = try client.attach.attach(w.a, arena, w.io, .{ .paths = w.paths, .exe = w.exe, .serve = w.serve, .log = w.log });
        var c = try client.Client.init(w.a, w.io, d.url, d.password);
        defer c.deinit();
        const api = client.session_api;
        const cwd = try w.currentCwd(arena);
        const value = switch (j.kind) {
            .move => try std.json.Stringify.valueAlloc(arena, try api.move(&c, arena, j.id, j.text), .{}),
            .directories => try std.json.Stringify.valueAlloc(arena, try client.files.directories(&c, arena, j.text), .{}),
            .files => try std.json.Stringify.valueAlloc(arena, try client.files.find(&c, arena, cwd, j.text, 30), .{}),
            .list_providers => try std.json.Stringify.valueAlloc(arena, try client.auth.providers(&c, arena, cwd), .{}),
            .open_url, .open_link, .copy => unreachable,
            .save_key => blk: {
                try client.auth.apiKey(&c, arena, j.id, j.text);
                break :blk "{}";
            },
            .start_oauth => try std.json.Stringify.valueAlloc(arena, try client.auth.start(&c, arena, j.extra, j.text, cwd), .{}),
            .status_oauth => try std.json.Stringify.valueAlloc(arena, try client.auth.status(&c, arena, j.extra, j.id), .{}),
            .cancel_oauth => blk: {
                try client.auth.cancel(&c, arena, j.extra, j.id);
                break :blk "{}";
            },
            .create => try std.json.Stringify.valueAlloc(arena, try api.create(&c, arena, cwd, .{ .profile = w.profile, .model = w.model, .environment = if (w.environment) |env| .{ .model = env.model, .profile = env.profile } else null }), .{}),
            .list_sessions => try std.json.Stringify.valueAlloc(arena, try api.list(&c, arena, cwd), .{}),
            .list_models => try std.json.Stringify.valueAlloc(arena, try api.models(&c, arena, j.id), .{}),
            .get => blk: {
                const res = try c.get(arena, try std.fmt.allocPrint(arena, "/sessions/{s}", .{j.id}));
                if (!res.ok()) return error.HttpFailure;
                break :blk res.body;
            },
            .config => try std.json.Stringify.valueAlloc(arena, try api.config(&c, arena, j.id), .{}),
            .page => try std.json.Stringify.valueAlloc(arena, try api.page(&c, arena, j.id, if (j.extra.len == 0) null else j.extra, 50), .{}),
            .prompt => blk: {
                const images = try arena.alloc(@import("proto").attachment.Image, j.images.len + j.image_data.len);
                @memcpy(images[j.images.len..], j.image_data);
                for (j.images, images[0..j.images.len]) |path, *image| {
                    image.* = try attachments.load(arena, w.io, cwd, path);
                }
                break :blk try std.json.Stringify.valueAlloc(arena, try client.commands.submit(&c, arena, j.id, j.text, if (std.mem.eql(u8, j.extra, "steer")) .steer else .queue, images), .{});
            },
            .abort => blk: {
                try api.abort(&c, arena, j.id);
                break :blk "{}";
            },
            .shell => blk: {
                _ = try api.shell(&c, arena, j.id, j.text);
                break :blk "{}";
            },
            .stop_shell => blk: {
                try api.stopShell(&c, arena, j.id);
                break :blk "{}";
            },
            .rename => try std.json.Stringify.valueAlloc(arena, try api.update(&c, arena, j.id, j.text, null), .{}),
            .auto_title => blk: {
                try api.generateTitle(&c, arena, j.id);
                break :blk "{}";
            },
            .model => try std.json.Stringify.valueAlloc(arena, try api.update(&c, arena, j.id, null, j.text), .{}),
            .thinking => try std.json.Stringify.valueAlloc(arena, try api.setThinking(&c, arena, j.id, j.text), .{}),
            .delete_session => blk: {
                try api.remove(&c, arena, j.id);
                break :blk "{}";
            },
            .reload => try std.json.Stringify.valueAlloc(arena, try api.reload(&c, arena, cwd), .{}),
            .mcp => blk: {
                if (j.text.len > 0) try client.mcp.connect(&c, arena, cwd, j.text);
                break :blk try std.json.Stringify.valueAlloc(arena, try client.mcp.list(&c, arena, cwd), .{});
            },
            .fork => try std.json.Stringify.valueAlloc(arena, try api.fork(&c, arena, j.id, null), .{}),
            .compact => try std.json.Stringify.valueAlloc(arena, try api.compact(&c, arena, j.id, j.text), .{}),
            .undo => try std.json.Stringify.valueAlloc(arena, try api.undo(&c, arena, j.id), .{}),
            .extensions => blk: {
                if (j.text.len > 0) try client.extensions.restart(&c, arena, cwd, j.text);
                break :blk try std.json.Stringify.valueAlloc(arena, try client.extensions.list(&c, arena, cwd), .{});
            },
            .list_commands => try std.json.Stringify.valueAlloc(arena, try client.commands.list(&c, arena, j.id), .{}),
            .remove_inbox => blk: {
                try api.removeInbox(&c, arena, j.id, j.extra);
                break :blk "{}";
            },
            .edit_inbox => try std.json.Stringify.valueAlloc(arena, try api.removeInboxItem(&c, arena, j.id, j.extra), .{}),
            .list_questions => try std.json.Stringify.valueAlloc(arena, try client.questions.list(&c, arena, j.text), .{}),
            .answer_question => blk: {
                const content: ?std.json.Value = if (j.extra.len == 0) null else try std.json.parseFromSliceLeaky(std.json.Value, arena, j.extra, .{});
                try client.questions.answer(&c, arena, j.id, j.text, content);
                break :blk "{}";
            },
        };
        return .{ .job = j, .body = try w.a.dupe(u8, value) };
    }
};
