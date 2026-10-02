//! Full-screen interactive client. Terminal and UI loop never perform HTTP.
const std = @import("std");
const platform = @import("platform");
const client = @import("client");
const proto = @import("proto");
const App = @import("App.zig");
const actions = @import("actions.zig");
const Worker = @import("app_network.zig").Worker;
const input = @import("input.zig");
const Screen = @import("screen.zig").Screen;
const view = @import("view.zig");
const plugin = @import("plugin.zig");
const Palette = @import("palette.zig").Palette;
const projection = @import("app_projection.zig");
const auth = @import("app_auth.zig");
const results = @import("app_results.zig");
const Controller = @import("app_controller.zig").Controller;
const dispatch = @import("app_dispatch.zig").dispatch;

pub const Options = struct {
    paths: platform.Paths,
    exe: []const u8,
    cwd: []const u8,
    /// Shown as `~` in the footer.
    home: ?[]const u8 = null,
    /// `COLORTERM`: `truecolor` or `24bit` allow 24-bit backgrounds, else
    /// the nearest of 256 colors is used.
    colorterm: ?[]const u8 = null,
    /// How to start the server when none answers (a standalone client's
    /// private one); the shared server by default.
    serve: []const []const u8 = &.{"serve"},
    log: ?[]const u8 = null,
    environment: ?struct { model: ?[]const u8 = null, profile: ?[]const u8 = null } = null,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Entry point for main: `try tui.run.run(gpa, io, .{ .paths = paths,
/// .exe = exe, .cwd = cwd, .environment = selectors });`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var terminal = try platform.tui_terminal.Terminal.init(io);
    defer terminal.deinit();
    platform.signal.installTermination();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input_arena: std.heap.ArenaAllocator = .init(gpa);
    defer input_arena.deinit();
    var registry = try plugin.Registry.init(gpa, &@import("builtins.zig").plugins);
    defer registry.deinit();
    var frame: view.Frame = .{ .registry = &registry, .palette = Palette.init(terminal.background, truecolor(options.colorterm)) };
    var app = App.init(gpa, options.cwd);
    defer app.deinit();
    const loaded = @import("settings.zig").load(arena, io, options.paths.config);
    app.show_reasoning = loaded.settings.thinking == .expanded;
    app.show_compaction = loaded.settings.compaction == .expanded;
    if (loaded.problem) |problem| app.say("{s}", .{problem});
    app.clock = @import("clock.zig").Clock.load(arena, io);
    app.home = options.home orelse "";
    app.branch = @import("git_branch.zig").read(arena, io, options.cwd) catch "";
    var screen = try Screen.init(gpa, terminal.size.columns, terminal.size.rows);
    defer screen.deinit();
    var render_cache = view.Cache.init(gpa);
    defer render_cache.deinit();
    var parser = input.Parser.init(gpa);
    defer parser.deinit();
    var state = client.state.State.init(gpa);
    defer state.deinit();
    var controller: Controller = .{};
    var connection = client.connection.Connection.init(gpa, io, .{ .paths = options.paths, .exe = options.exe, .serve = options.serve, .log = options.log });
    try connection.start();
    defer connection.deinit();
    var worker = Worker.init(gpa, io, options.paths, options.exe, options.cwd);
    worker.serve = options.serve;
    worker.log = options.log;
    worker.environment = if (options.environment) |env| .{ .model = env.model, .profile = env.profile } else null;
    worker.profile = options.profile;
    worker.model = options.model;
    try worker.start();
    // Replies to plugins' questions go on their own queue: a slash command
    // the main queue is waiting on may be what asked.
    var answers = Worker.init(gpa, io, options.paths, options.exe, options.cwd);
    answers.serve = options.serve;
    answers.log = options.log;
    try answers.start();
    defer answers.stop();
    defer {
        worker.stop();
        if (app.connect_flow) |flow| auth.cancelOnExit(gpa, io, options.paths, if (app.connect_provider) |p| p.id else "openai", flow.id);
    }
    var env: results.Env = .{ .gpa = gpa, .arena = arena, .app = &app, .worker = &worker, .state = &state, .controller = &controller, .registry = &registry, .io = io };
    var changed = false;
    var overflow_handled = false;
    var buf: [4096]u8 = undefined;
    var window_title: @import("window_title.zig").Title = .{};
    var title_buf: [300]u8 = undefined;
    while (!app.quit and !platform.signal.terminationRequested()) {
        const status = connection.status();
        app.connected = status.connected;
        if (!status.overflow) overflow_handled = false;
        if (status.generation != controller.generation or status.overflow and !overflow_handled) {
            overflow_handled = status.overflow;
            app.questions.clear();
            if (app.overlay == .question) app.overlay = .none;
            try state.reconnect();
            const fresh = controller.reconnect(status.generation) orelse if (app.session) |id| controller.select(id) else null;
            if (fresh) |token| {
                try env.load(token);
            } else if (!env.creating and status.connected) {
                try worker.submit(.{ .kind = .create });
                env.creating = true;
            }
        }
        while (answers.poll()) |result| {
            defer answers.release(result);
            if (result.err) |err| app.say("Question reply failed: {s}", .{@errorName(err)});
        }
        while (connection.poll()) |bytes| {
            defer gpa.free(bytes);
            try event(&app, &worker, &state, gpa, bytes);
            state.enqueue(bytes) catch {
                if (app.session) |id| {
                    app.questions.clear();
                    if (app.overlay == .question) app.overlay = .none;
                    try state.reconnect();
                    try env.load(controller.select(id));
                }
            };
            changed = true;
        }
        while (worker.poll()) |result| {
            defer worker.release(result);
            try results.apply(&env, result);
            _ = input_arena.reset(.retain_capacity);
            try results.confirmPending(&env, input_arena.allocator());
        }
        try auth.tick(&app, &worker);
        if (changed and state.hydrated and !controller.pending) try projection.sync(&app, &state);
        changed = false;
        if (terminal.pollResize()) |size| try screen.resize(size.columns, size.rows);
        frame.now_ms = std.Io.Clock.real.now(io).toMilliseconds();
        const rendered = try view.drawCached(&screen, &app, frame, &render_cache);
        defer gpa.free(rendered);
        try terminal.write(rendered);
        if (window_title.update(&app, &title_buf)) |sequence| try terminal.write(sequence);
        const n = try terminal.read(30, &buf);
        if (n) |count| {
            if (count == 0) break;
            try parser.feed(buf[0..count]);
            while (try parser.next()) |ev| {
                defer ev.deinit(gpa);
                try key(&env, &answers, input_arena.allocator(), &input_arena, ev);
            }
        } else if (parser.flushEscape()) |ev| try key(&env, &answers, input_arena.allocator(), &input_arena, ev);
    }
}

fn truecolor(colorterm: ?[]const u8) bool {
    const value = colorterm orelse return false;
    return std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit");
}

fn key(env: *results.Env, answers: *Worker, a: std.mem.Allocator, input_arena: *std.heap.ArenaAllocator, ev: input.Event) !void {
    _ = input_arena.reset(.retain_capacity);
    const app = env.app;
    const req = try actions.handle(app, env.registry, a, ev);
    if (req == .answer_question) {
        const answer = req.answer_question;
        const content = if (answer.content) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else "";
        try answers.submit(.{ .kind = .answer_question, .id = answer.id, .text = answer.action, .extra = content });
        app.resolve(answer.id);
        return;
    }
    try dispatch(app, env.registry, env.worker, req);
    switch (req) {
        .older => if (app.session) |id| if (env.state.snapshot) |snap| if (snap.nextBefore) |cursor| {
            try env.worker.submit(.{ .kind = .page, .id = id, .extra = cursor, .generation = env.controller.generation, .epoch = env.controller.epoch });
        },
        .select_session => |id| try env.open(id),
        else => {},
    }
}

/// Status lines and automatic replies for this session's events.
fn event(app: *App, worker: *Worker, state: *const client.state.State, gpa: std.mem.Allocator, bytes: []const u8) !void {
    var event_arena: std.heap.ArenaAllocator = .init(gpa);
    defer event_arena.deinit();
    const e = proto.event.Decoded.parse(event_arena.allocator(), bytes) catch return;
    const session = app.session orelse return;
    const types = proto.event.types;
    if (std.mem.eql(u8, e.type, types.question_asked)) return app.ask(e.data, e.session, e.location);
    if (std.mem.eql(u8, e.type, types.question_resolved)) {
        if (e.data == .object) if (e.data.object.get("id")) |id| if (id == .string) app.resolve(id.string);
        return;
    }
    const current = if (e.session) |id| std.mem.eql(u8, id, session) else e.location != null and std.mem.eql(u8, e.location.?, app.session_location);
    if (!current) return;
    if (std.mem.eql(u8, e.type, types.agent_end)) {
        if (!app.auto_title_attempted and state.snapshot != null and state.snapshot.?.info.title == null) {
            app.auto_title_attempted = true;
            try worker.submit(.{ .kind = .auto_title, .id = session });
        }
        return;
    }
    const data = if (e.data == .object) e.data.object else return;
    const text = struct {
        fn get(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const v = object.get(name) orelse return null;
            return if (v == .string) v.string else null;
        }
    }.get;
    if (std.mem.eql(u8, e.type, types.plugin_notice)) {
        const level = text(data, "level") orelse "info";
        if (std.mem.eql(u8, level, "info")) app.say("{s}: {s}", .{ text(data, "source") orelse "plugin", text(data, "message") orelse "" }) else app.say("{s} {s}: {s}", .{ level, text(data, "source") orelse "plugin", text(data, "message") orelse "" });
    } else if (std.mem.eql(u8, e.type, types.session_error)) {
        if (text(data, "error")) |detail| app.say("Error: {s}", .{detail});
    } else if (std.mem.eql(u8, e.type, types.compaction_start)) {
        app.compacting = true;
    } else if (std.mem.eql(u8, e.type, types.compaction_end)) {
        app.compacting = false;
    } else if (std.mem.eql(u8, e.type, types.compaction_failed)) {
        app.compacting = false;
        if (text(data, "error")) |detail| app.say("Compaction failed: {s}", .{detail});
    } else if (std.mem.eql(u8, e.type, types.prompt_blocked)) {
        if (text(data, "reason")) |reason| app.say("Prompt blocked: {s}", .{reason});
    }
}

test {
    std.testing.refAllDecls(@This());
}
