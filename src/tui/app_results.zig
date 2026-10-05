//! Applies finished background requests to the UI state.
const std = @import("std");
const client = @import("client");
const proto = @import("proto");
const App = @import("App.zig");
const actions = @import("actions.zig");
const plugin = @import("plugin.zig");
const picker = @import("picker.zig");
const network = @import("app_network.zig");
const pick = @import("app_picker.zig");
const auth = @import("app_auth.zig");
const projection = @import("app_projection.zig");
const completion = @import("completion.zig");
const Controller = @import("app_controller.zig").Controller;
const Token = @import("app_controller.zig").Token;
const dispatch = @import("app_dispatch.zig").dispatch;

/// The run loop's state that results change.
pub const Env = struct {
    gpa: std.mem.Allocator,
    /// Owns session ids for the client's lifetime.
    arena: std.mem.Allocator,
    app: *App,
    worker: *network.Worker,
    state: *client.state.State,
    controller: *Controller,
    registry: *const plugin.Registry,
    io: std.Io,
    /// A `create` request is in flight.
    creating: bool = false,

    /// Shows session `id` and loads it.
    pub fn open(env: *Env, id_source: []const u8) !void {
        const id = try env.arena.dupe(u8, id_source);
        try env.app.switchSession(id);
        try env.state.select(id);
        try env.load(env.controller.select(id));
    }

    pub fn load(env: *Env, token: Token) !void {
        try env.worker.submit(.{ .kind = .get, .id = token.session, .generation = token.generation, .epoch = token.epoch });
        try env.worker.submit(.{ .kind = .config, .id = token.session, .generation = token.generation, .epoch = token.epoch });
    }
};

pub fn apply(env: *Env, result: network.Result) !void {
    const app = env.app;
    const job = result.job;
    const controller = env.controller;
    if ((job.kind == .get or job.kind == .config or job.kind == .page or job.kind == .list_questions) and
        (job.generation != controller.generation or job.epoch != controller.epoch or
            controller.selected == null or !std.mem.eql(u8, job.id, controller.selected.?))) return;
    if (result.err) |err| return failed(env, job, err);
    var response_arena: std.heap.ArenaAllocator = .init(env.gpa);
    defer response_arena.deinit();
    const scratch = response_arena.allocator();
    const mine = app.session != null and std.mem.eql(u8, app.session.?, job.id);
    switch (job.kind) {
        .list_providers, .save_key, .start_oauth, .status_oauth => try auth.result(app, env.worker, env.gpa, result),
        .open_link => app.say("Opened {s}", .{@import("links.zig").host(job.text)}),
        .create, .fork => {
            if (job.kind == .create) env.creating = false;
            const info = try std.json.parseFromSliceLeaky(client.session_api.Info, scratch, result.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            try env.open(info.id);
            if (app.deferred_send) |deferred| {
                app.deferred_send = null;
                defer env.gpa.free(deferred.draft);
                const draft = try std.json.parseFromSliceLeaky(App.Draft, scratch, deferred.draft, .{});
                try env.worker.submit(.{ .kind = .prompt, .id = app.session.?, .text = draft.text, .extra = @tagName(deferred.delivery), .images = draft.paths, .image_data = draft.images });
                app.submitting = app.session.?;
            }
        },
        .get => {
            if (!controller.accepts(.{ .generation = job.generation, .epoch = job.epoch, .session = job.id })) return;
            env.state.hydrate(result.body) catch return app.say("Could not load session", .{});
            try projection.sync(app, env.state);
            try env.worker.submit(.{ .kind = .list_questions, .id = job.id, .text = app.session_location, .generation = job.generation, .epoch = job.epoch });
            app.status = "";
        },
        .list_questions => {
            if (!std.mem.eql(u8, job.text, app.session_location)) return;
            const list = try std.json.parseFromSliceLeaky([]const std.json.Value, scratch, result.body, .{});
            for (list) |q| {
                const s = if (q == .object) q.object.get("session") else null;
                const target: ?[]const u8 = if (s) |v| if (v == .string) v.string else null else null;
                try app.ask(q, target, job.text);
            }
        },
        .config => {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, scratch, result.body, .{});
            if (parsed == .object) if (parsed.object.get("config")) |cfg| if (cfg == .object) if (cfg.object.get("model")) |model| if (model == .string) try app.setEffectiveModel(model.string);
            // The model listing says the context window.
            try env.worker.submit(.{ .kind = .list_models, .id = job.id });
        },
        .page => {
            const page = try decodePage(scratch, result.body);
            try env.state.mergePage(page);
            app.history_prepend = true;
            try projection.sync(app, env.state);
        },
        .prompt => {
            app.submitted(job.id);
            if (mine and std.mem.eql(u8, std.mem.trim(u8, app.editor.text(), " \t\r\n"), job.text) and sameAttachments(app, job)) app.clearInput();
        },
        .edit_inbox => {
            const item = try std.json.parseFromSliceLeaky(client.session_api.Inbox, scratch, result.body, .{});
            try app.restorePending(job.id, item.text, item.images);
        },
        .list_sessions => {
            if (app.overlay != .sessions) return;
            _ = app.picker_arena.reset(.retain_capacity);
            app.picker_items = try pick.sessions(app.picker_arena.allocator(), result.body, app.clock);
            app.picker_waiting = false;
        },
        .list_models => {
            if (!mine) return;
            const info = try pick.modelInfo(scratch, result.body, app.model);
            app.context_window = info.context;
            app.reasoning = info.reasoning;
            if (app.overlay != .models) return;
            _ = app.picker_arena.reset(.retain_capacity);
            app.picker_items = try pick.models(app.picker_arena.allocator(), result.body);
            app.picker_waiting = false;
            if (app.picker_items.len == 0) app.say("No models available. Use /connect or check provider config.", .{});
        },
        .list_commands => {
            _ = app.template_arena.reset(.retain_capacity);
            const a = app.template_arena.allocator();
            const templates = try std.json.parseFromSliceLeaky([]const client.commands.Info, a, result.body, .{ .allocate = .alloc_always });
            const items = try a.alloc(picker.Item, templates.len);
            for (templates, items) |t, *item| item.* = .{
                .id = try std.fmt.allocPrint(a, "/{s}", .{t.name}),
                .label = if (t.argumentHint) |hint| try std.fmt.allocPrint(a, "/{s} {s}", .{ t.name, hint }) else try std.fmt.allocPrint(a, "/{s}", .{t.name}),
                .detail = try std.fmt.allocPrint(a, "{s} ({s})", .{ t.description, t.source }),
            };
            app.templates = items;
        },
        .files => {
            // Only the answer for the word being typed now.
            const token = completion.token(app.editor.text(), app.editor.cursor);
            if (token.kind != .file or !std.mem.eql(u8, token.query, job.text)) return;
            _ = app.file_arena.reset(.retain_capacity);
            const a = app.file_arena.allocator();
            const matches = try std.json.parseFromSliceLeaky([]const client.files.Match, a, result.body, .{ .allocate = .alloc_always });
            const items = try a.alloc(picker.Item, matches.len);
            for (matches, items) |match, *item| item.* = .{ .id = match.path, .label = match.path };
            app.files = items;
            app.file_query = try a.dupe(u8, job.text);
        },
        .directories => {
            const token = @import("app_completion.zig").tokenAt(app, env.registry);
            if (token.kind != .directory or !std.mem.eql(u8, completion.splitPath(token.query).parent, job.extra)) return;
            _ = app.directory_arena.reset(.retain_capacity);
            const a = app.directory_arena.allocator();
            const entries = try std.json.parseFromSliceLeaky([]const client.files.Directory, a, result.body, .{ .allocate = .alloc_always });
            const items = try a.alloc(picker.Item, entries.len);
            for (entries, items) |entry, *item| item.* = .{
                .id = try std.fmt.allocPrint(a, "{s}{s}/", .{ job.extra, entry.name }),
                .label = try std.fmt.allocPrint(a, "{s}/", .{entry.name}),
            };
            app.directories = items;
            app.directory_parent = try a.dupe(u8, job.extra);
        },
        .move => if (mine) {
            const moved = try std.json.parseFromSliceLeaky(client.session_api.Moved, scratch, result.body, .{ .ignore_unknown_fields = true });
            if (!moved.moved) return app.say("Already in {s}", .{moved.location});
            // The directory as typed, not the project root it belongs to.
            try app.setCwd(job.text);
            try app.setSessionLocation(moved.location);
            try env.worker.setCwd(job.text);
            app.questions.clear();
            if (app.overlay == .question) app.overlay = .none;
            try env.worker.submit(.{ .kind = .list_questions, .id = job.id, .text = moved.location, .generation = controller.generation, .epoch = controller.epoch });
            app.branch = @import("git_branch.zig").read(env.arena, env.io, job.text) catch "";
            app.say("Moved to {s}", .{moved.location});
            // The new project may configure another model.
            try env.worker.submit(.{ .kind = .config, .id = job.id, .generation = controller.generation, .epoch = controller.epoch });
        },
        .abort => if (mine) {
            app.running = false;
        },
        .model => if (mine) {
            try app.setEffectiveModel(job.text);
            try env.worker.submit(.{ .kind = .list_models, .id = job.id });
        },
        .reload => {
            const failures = try std.json.parseFromSliceLeaky([]const client.session_api.ReloadFailure, scratch, result.body, .{ .allocate = .alloc_always });
            if (failures.len == 0) app.say("Reloaded.", .{}) else app.say("Reload: {d} not reloaded; {s}: {s}", .{ failures.len, failures[0].plugin, failures[0].message });
        },
        .mcp => {
            const servers = try std.json.parseFromSliceLeaky([]const client.mcp.Status, scratch, result.body, .{ .allocate = .alloc_always });
            app.status = client.mcp.summary(&app.status_buffer, servers);
        },
        .undo => {
            const done = try std.json.parseFromSliceLeaky(?client.session_api.Undone, scratch, result.body, .{ .allocate = .alloc_always });
            app.status = client.session_api.undoSummary(&app.status_buffer, done);
        },
        .extensions => {
            const list = try std.json.parseFromSliceLeaky([]const client.extensions.Status, scratch, result.body, .{ .allocate = .alloc_always });
            app.status = client.extensions.summary(&app.status_buffer, list);
        },
        .delete_session => {
            if (!mine) return;
            // Session ids are owned by the run arena; only the draft saved
            // for the deleted session is released here.
            app.forgetDraft(job.id);
            app.session = null;
            controller.selected = null;
            controller.epoch +%= 1;
            controller.pending = true;
            try env.worker.submit(.{ .kind = .create });
            env.creating = true;
        },
        else => {},
    }
}

fn failed(env: *Env, job: network.Job, err: anyerror) !void {
    const app = env.app;
    if (auth.stale(app, job)) return;
    switch (job.kind) {
        .status_oauth => app.connect_polling = false,
        .cancel_oauth => return,
        .open_url => return app.say("Could not open browser; use URL shown (Enter to retry).", .{}),
        .open_link => return app.say("Could not open {s}", .{job.text}),
        // `extra` is set when the terminal was given the text as well.
        .copy => return if (job.extra.len == 0) app.say("Could not copy: {s}", .{@errorName(err)}),
        .move => return switch (err) {
            error.SessionBusy => app.say("Stop the running turn first (Esc), then /cd again.", .{}),
            error.NotFound => app.say("No such directory: {s}", .{job.text}),
            else => app.say("Could not move: {s}", .{@errorName(err)}),
        },
        .directories => return,
        .prompt => app.submitted(job.id),
        .create => env.creating = false,
        .get => if (env.controller.accepts(.{ .generation = job.generation, .epoch = job.epoch, .session = job.id })) {
            env.controller.pending = false;
        },
        // Completion data is best effort.
        .files, .list_commands, .list_models => if (job.kind != .list_models or env.app.overlay != .models) return,
        else => {},
    }
    app.say("Request failed: {s}", .{@errorName(err)});
}

/// A picker choice that waited for its items: pick now.
pub fn confirmPending(env: *Env, input_arena: std.mem.Allocator) !void {
    const app = env.app;
    if (!app.picker_confirm_pending or app.picker_waiting) return;
    app.picker_confirm_pending = false;
    const req = try actions.handle(app, env.registry, input_arena, .{ .key = .enter });
    try dispatch(app, env.registry, env.worker, req);
    if (req == .select_session) try env.open(req.select_session);
}

fn sameAttachments(app: *const App, job: network.Job) bool {
    if (app.attachments.items.len != job.images.len or app.embedded_images.items.len != job.image_data.len) return false;
    for (app.attachments.items, job.images) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    for (app.embedded_images.items, job.image_data) |a, b| {
        if (!std.mem.eql(u8, a.mimeType, b.mimeType) or !std.mem.eql(u8, a.data, b.data)) return false;
    }
    return true;
}

fn decodePage(a: std.mem.Allocator, body: []const u8) !client.session_api.Page {
    const raw = try std.json.parseFromSliceLeaky(struct { messages: []const std.json.Value, nextBefore: ?[]const u8 }, a, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    const messages = try a.alloc(proto.Message, raw.messages.len);
    for (raw.messages, messages) |item, *message| message.* = try proto.Message.parse(a, item);
    return .{ .messages = messages, .nextBefore = raw.nextBefore };
}
