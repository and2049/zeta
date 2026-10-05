const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("core");
const plugin = @import("plugin");
const builtins = @import("builtins");
const platform = @import("platform");
const server = @import("server");
const client = @import("client");
const tui = @import("tui");

/// A panic skips defers: give the terminal back before reporting it.
pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        platform.tui_terminal.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.mode == .Debug) init.gpa else std.heap.c_allocator;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cmd: []const u8 = if (args.len > 1) args[1] else "";

    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, cmd, "--standalone"))) {
        var paths = try platform.Paths.resolve(arena, init.environ_map);
        const exe = try std.process.executablePathAlloc(io, arena);
        const private = if (args.len == 2) try client.standalone.start(gpa, arena, io, paths, exe) else null;
        defer if (private) |p| p.stop(gpa, io);
        if (private) |p| paths = p.paths;
        return tui.run.run(gpa, io, .{
            .serve = if (private) |p| p.serve else &.{"serve"},
            .log = if (private) |p| p.log else null,
            .paths = paths,
            .exe = try std.process.executablePathAlloc(io, arena),
            .cwd = try std.process.currentPathAlloc(io, arena),
            .home = init.environ_map.get("HOME"),
            .colorterm = init.environ_map.get("COLORTERM"),
            .clipboard = .{ .wayland = init.environ_map.get("WAYLAND_DISPLAY") != null, .x11 = init.environ_map.get("DISPLAY") != null },
            .environment = .{ .model = init.environ_map.get("ZETA_MODEL"), .profile = init.environ_map.get("ZETA_PROFILE") },
        });
    }

    if (std.mem.eql(u8, cmd, "--version")) {
        return out(io, "zeta {s}\n", .{build_options.version});
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        var paths = try platform.Paths.resolve(arena, init.environ_map);
        var options: ServeOptions = .{};
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 2) {
            if (std.mem.eql(u8, args[i], "--hostname")) {
                options.hostname = args[i + 1];
            } else if (std.mem.eql(u8, args[i], "--runtime-dir")) {
                paths.runtime = args[i + 1];
            } else if (std.mem.eql(u8, args[i], "--parent")) {
                options.parent = std.fmt.parseInt(i64, args[i + 1], 10) catch usageError(io, "error: --parent needs a pid\n");
            } else break;
        }
        if (i != args.len) usageError(io, "usage: zeta serve [--hostname <address>]\n");
        if (std.mem.eql(u8, options.hostname, "localhost")) options.hostname = "127.0.0.1";
        // Clients cannot reach bracketed IPv6 URLs yet.
        _ = std.Io.net.Ip4Address.parse(options.hostname, 0) catch usageError(io, "error: --hostname takes an IPv4 address\n");
        return serve(gpa, arena, io, init.environ_map, paths, options);
    }
    if (std.mem.eql(u8, cmd, "run")) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        return run(gpa, arena, io, init.environ_map, paths, args[2..]);
    }
    if (std.mem.eql(u8, cmd, "server") and args.len == 3 and std.mem.eql(u8, args[2], "stop")) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        const result = try client.admin.stop(gpa, io, paths);
        return out(io, "{s}\n", .{if (result == .stopped) "server stopped" else "server is not running"});
    }
    if (std.mem.eql(u8, cmd, "reload") and args.len == 2) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        const failures = try client.admin.reload(gpa, arena, io, paths, try std.process.currentPathAlloc(io, arena)) orelse
            return out(io, "server is not running\n", .{});
        for (failures) |failure| try out(io, "not reloaded: {s}: {s}\n", .{ failure.plugin, failure.message });
        if (failures.len > 0) std.process.exit(1);
        return out(io, "reloaded\n", .{});
    }
    if (std.mem.eql(u8, cmd, "usage")) return cli(gpa, arena, io, init.environ_map, client.usage_cli.run, args[2..]);
    if (std.mem.eql(u8, cmd, "undo")) return cli(gpa, arena, io, init.environ_map, client.sessions_cli.undo, args[2..]);
    if (std.mem.eql(u8, cmd, "sessions")) return cli(gpa, arena, io, init.environ_map, client.sessions_cli.run, args[2..]);
    if (std.mem.eql(u8, cmd, "mcp")) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        const code = try client.mcp_cli.run(gpa, io, &stdout.interface, args[2..], .{
            .paths = paths,
            .exe = try std.process.executablePathAlloc(io, arena),
            .cwd = try std.process.currentPathAlloc(io, arena),
        });
        try stdout.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.eql(u8, cmd, "update")) {
        var buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        const code = try client.update.run(gpa, io, &stdout.interface, args[2..], .{
            .current = build_options.version,
            .exe = try std.process.executablePathAlloc(io, arena),
            .paths = try platform.Paths.resolve(arena, init.environ_map),
            .base = init.environ_map.get("ZETA_UPDATE_URL") orelse client.update.default_base,
        });
        try stdout.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.eql(u8, cmd, "auth") and args.len == 4 and std.mem.eql(u8, args[2], "login")) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        try client.admin.authLogin(gpa, io, paths, args[3]);
        return out(io, "credential saved\n", .{});
    }
    try out(io, usage, .{});
}

fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, paths: platform.Paths, args: []const [:0]const u8) !void {
    var json = false;
    var profile: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var thinking: ?[]const u8 = null;
    var standalone = false;
    var session: ?[]const u8 = null;
    var latest = false;
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var flags = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (flags and std.mem.eql(u8, a, "--")) {
            flags = false;
        } else if (flags and std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (flags and std.mem.eql(u8, a, "--standalone")) {
            standalone = true;
        } else if (flags and (std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c"))) {
            latest = true;
        } else if (flags and (std.mem.eql(u8, a, "--profile") or std.mem.eql(u8, a, "--model") or std.mem.eql(u8, a, "--thinking") or std.mem.eql(u8, a, "--session"))) {
            i += 1;
            if (i == args.len) {
                try out(io, "error: {s} requires a value\n", .{a});
                std.process.exit(2);
            }
            if (std.mem.eql(u8, a, "--profile")) {
                profile = args[i];
            } else if (std.mem.eql(u8, a, "--model")) {
                model = args[i];
            } else if (std.mem.eql(u8, a, "--session")) {
                session = args[i];
            } else thinking = args[i];
        } else try words.append(arena, a);
    }
    if (latest and session != null) usageError(io, "error: --continue and --session cannot be used together\n");
    const cwd = try std.process.currentPathAlloc(io, arena);
    const piped = client.run_input.readStdin(arena, io) catch |err| {
        try err_out(io, "error: reading stdin: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (words.items.len == 0 and piped == null) {
        try out(io, "usage: zeta run [--json] [--standalone] [--continue | --session <id>] [--profile <name>] [--model <provider/model>] [--thinking <level>] <prompt | @file>...\n", .{});
        std.process.exit(2);
    }
    var problem: client.run_input.Problem = .{};
    const input = client.run_input.build(arena, io, cwd, words.items, piped, &problem) catch |err| switch (err) {
        error.BadFileArgument => {
            try err_out(io, "error: {s}: {s}\n", .{ problem.path, problem.reason });
            std.process.exit(1);
        },
        else => |e| return e,
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);

    const exe = try std.process.executablePathAlloc(io, arena);
    const private = if (standalone) try client.standalone.start(gpa, arena, io, paths, exe) else null;
    defer if (private) |p| p.stop(gpa, io);
    const outcome = client.run.run(gpa, io, &stdout.interface, &stderr.interface, .{
        .paths = if (private) |p| p.paths else paths,
        .serve = if (private) |p| p.serve else &.{"serve"},
        .log = if (private) |p| p.log else null,
        .exe = exe,
        .cwd = cwd,
        .text = input.text,
        .images = input.images,
        .json = json,
        .session = session,
        .latest = latest,
        .profile = profile,
        .model = model,
        .thinking = thinking,
        .environment = .{ .model = env.get("ZETA_MODEL"), .profile = env.get("ZETA_PROFILE") },
    }) catch |err| switch (err) {
        // stdout closed early (e.g. piped into `head`).
        error.WriteFailed => std.process.exit(1),
        else => |e| return e,
    };
    if (outcome == .failed) {
        if (private) |p| p.stop(gpa, io);
        std.process.exit(1);
    }
}

const ServeOptions = struct {
    /// Address to listen on; anything but loopback reaches other machines.
    hostname: []const u8 = "127.0.0.1",
    /// A standalone server's client: it stops when that process is gone,
    /// and loads no earlier sessions.
    parent: ?i64 = null,
};

fn serve(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, paths: platform.Paths, options: ServeOptions) !void {
    // A standalone server's directory (`standalone-<client pid>`) is its
    // own: removed last, after the lock is released, even when its client
    // died without cleaning up. Nothing else is ever removed.
    var own_buf: [32]u8 = undefined;
    const own = if (options.parent) |pid| std.fmt.bufPrint(&own_buf, "standalone-{d}", .{pid}) catch "" else "";
    defer if (own.len > 0 and std.mem.eql(u8, std.fs.path.basename(paths.runtime), own)) std.Io.Dir.cwd().deleteTree(io, paths.runtime) catch {};
    const instance_lock = server.Server.lockInstance(io, paths.runtime) catch |err| switch (err) {
        error.WouldBlock => {
            std.log.err("a zeta server is already running", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer instance_lock.close(io);
    if (options.parent == null) platform.process.resetLog(io, try paths.serverLog(arena));
    var discovery_path: ?[]u8 = null;
    defer if (discovery_path) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        gpa.free(path);
    };
    if (try server.Server.findRunning(gpa, io, paths.runtime)) |url| {
        defer gpa.free(url);
        std.log.err("a zeta server is already running at {s}", .{url});
        std.process.exit(1);
    }

    // Deinitialized after the runtime has joined every run.
    var transports: builtins.Transports = .init(gpa, io);
    defer transports.deinit();
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    var inspector: builtins.tool_inspect.Inspector = .{};
    try builtins.register(&registry, &inspector, &transports);

    const catalog = try builtins.models.Catalog.init(gpa, io, .{ .cache_dir = paths.cache, .keep = builtins.providers.catalog_ids });
    defer catalog.deinit();
    var providers: builtins.providers.Context = .{ .env = env, .catalog = catalog, .data_dir = paths.data };
    try builtins.providers.register(&providers, &registry);
    const home = env.get("HOME") orelse return error.NoHomeDir;
    const sessions_dir = try std.fs.path.join(arena, &.{ paths.data, "sessions" });
    var resources: builtins.resources.Resources = .{
        .home = home,
        .config_dir = paths.config,
        .docs_dir = try builtins.docs.materialize(arena, io, paths.data),
    };
    var command_hooks: builtins.hooks_cmd.Hooks = .{ .gpa = gpa, .registry = &registry, .env = env, .home = home, .config_dir = paths.config, .sessions_dir = sessions_dir };
    defer command_hooks.deinit();
    try command_hooks.register();
    var mcp: builtins.mcp.Mcp = .{ .host = .{ .gpa = gpa, .registry = &registry, .env = env, .version = build_options.version, .data_dir = paths.data }, .io = io, .config_dir = paths.config };
    defer mcp.deinit();
    try mcp.register();
    var extensions: builtins.extensions.Extensions = .{
        .io = io,
        .host = .{
            .gpa = gpa,
            .registry = &registry,
            .env = env,
            .config_dir = paths.config,
            .home = home,
            .data_dir = paths.data,
            // A standalone server's extension logs stay beside it.
            .log_dir = try std.fs.path.join(arena, &.{ if (options.parent != null) paths.runtime else paths.state, "extensions" }),
        },
    };
    defer extensions.deinit();
    try extensions.register();

    var bus: core.Bus = .init(gpa, io);
    defer bus.deinit();
    var runtime: core.Runtime = .init(gpa, io, &bus, &registry, env, .{
        .config_dir = paths.config,
        .sessions_dir = sessions_dir,
        .state_dir = paths.state,
        .resources = resources.resources(),
    });
    defer runtime.deinit();
    // Run before runtime.deinit: extensions and MCP servers stop calling
    // into the runtime.
    defer extensions.shutdownAll();
    defer mcp.shutdownAll();
    inspector.runtime = &runtime;
    extensions.host.runtime = &runtime;
    mcp.host.asker = runtime.asker();
    // A standalone server leaves the sessions to the shared one.
    if (options.parent == null) _ = try runtime.restore();

    var srv = try server.Server.listen(gpa, io, &runtime, .{
        .version = build_options.version,
        .data_dir = paths.data,
        .hostname = options.hostname,
    });
    defer srv.deinit();
    discovery_path = try srv.publishDiscovery(paths.runtime);

    std.log.info("zeta server listening on {s}", .{srv.url()});
    if (!std.mem.eql(u8, options.hostname, "127.0.0.1"))
        std.log.warn("listening on {s}: other machines can connect; they need user zeta and the password in {s}", .{ options.hostname, discovery_path.? });
    var watch = if (options.parent) |pid| io.concurrent(server.Server.stopWhenGone, .{ &srv, pid }) catch null else null;
    defer if (watch) |*w| w.cancel(io) catch {};
    try srv.serve();
}

/// Says what is wrong on stderr and exits with status 2.
fn usageError(io: std.Io, message: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(message) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

/// A client command that prints to stdout and returns an exit status.
fn cli(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, comptime runFn: anytype, rest: []const [:0]const u8) !void {
    const paths = try platform.Paths.resolve(arena, env);
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const code = try runFn(gpa, io, &stdout.interface, rest, .{
        .paths = paths,
        .exe = try std.process.executablePathAlloc(io, arena),
        .cwd = try std.process.currentPathAlloc(io, arena),
    });
    try stdout.interface.flush();
    if (code != 0) std.process.exit(code);
}

fn err_out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const usage =
    \\usage: zeta <command>
    \\
    \\  (no command) open the full-screen terminal client
    \\               Ctrl+C clears input; Ctrl+Q exits
    \\  --standalone the terminal client with a private server that ends with it
    \\  run [--json] [--standalone] [--continue | --session <id>] [--profile <name>]
    \\      [--model <provider/model>] [--thinking <level>] <prompt | @file>...
    \\               send one prompt and print the reply, in a new session, the
    \\               project's latest (--continue, -c) or a given one; levels:
    \\               off, minimal, low, medium, high, xhigh; piped stdin and
    \\               @file arguments (text, or images) join the prompt
    \\  serve [--hostname <address>]
    \\               run the server in the foreground; --hostname listens on
    \\               another address (e.g. 0.0.0.0) for other machines
    \\  server stop  stop the shared server and join its workers
    \\  reload       reload plugins for this project and the user config
    \\  sessions [--all] [<text>] | sessions export <id>
    \\               list this project's sessions (or all), those mentioning
    \\               <text>; or print one as JSONL
    \\  undo [--session <id>]
    \\               undo the file changes of the latest reply (newest session)
    \\  usage [--all | --session <id>]
    \\               tokens and cost of this project's sessions (or all, or one)
    \\  mcp [auth <server> | logout <server>]
    \\               list this project's MCP servers, sign in to one, or sign out
    \\  auth login <provider>
    \\               save an API key from a hidden prompt or stdin
    \\  update [<version>]
    \\               replace this zeta with the latest release (or the given
    \\               one), checked against the release's checksums
    \\  --version    print version
    \\
;
