const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("core");
const plugin = @import("plugin");
const builtins = @import("builtins");
const platform = @import("platform");
const server = @import("server");

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.mode == .Debug) init.gpa else std.heap.c_allocator;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cmd: []const u8 = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, cmd, "--version")) {
        return out(io, "zeta {s}\n", .{build_options.version});
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        const paths = try platform.Paths.resolve(arena, init.environ_map);
        var options: ServeOptions = .{};
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 2) {
            if (std.mem.eql(u8, args[i], "--hostname")) {
                options.hostname = args[i + 1];
            } else break;
        }
        if (i != args.len) usageError(io, "usage: zeta serve [--hostname <address>]\n");
        if (std.mem.eql(u8, options.hostname, "localhost")) options.hostname = "127.0.0.1";
        _ = std.Io.net.Ip4Address.parse(options.hostname, 0) catch usageError(io, "error: --hostname takes an IPv4 address\n");
        return serve(gpa, arena, io, init.environ_map, paths, options);
    }
    try out(io, usage, .{});
}

const ServeOptions = struct {
    /// Address to listen on; anything but loopback reaches other machines.
    hostname: []const u8 = "127.0.0.1",
};

fn serve(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, paths: platform.Paths, options: ServeOptions) !void {
    const instance_lock = server.Server.lockInstance(io, paths.runtime) catch |err| switch (err) {
        error.WouldBlock => {
            std.log.err("a zeta server is already running", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer instance_lock.close(io);
    platform.process.resetLog(io, try paths.serverLog(arena));
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
    try builtins.register(&registry, &transports);

    const catalog = try builtins.models.Catalog.init(gpa, io, .{ .cache_dir = paths.cache, .keep = builtins.providers.catalog_ids });
    defer catalog.deinit();
    var providers: builtins.providers.Context = .{ .env = env, .catalog = catalog, .data_dir = paths.data };
    try builtins.providers.register(&providers, &registry);
    const sessions_dir = try std.fs.path.join(arena, &.{ paths.data, "sessions" });
    var bus: core.Bus = .init(gpa, io);
    defer bus.deinit();
    var runtime: core.Runtime = .init(gpa, io, &bus, &registry, env, .{
        .config_dir = paths.config,
        .sessions_dir = sessions_dir,
        .state_dir = paths.state,
    });
    defer runtime.deinit();
    _ = try runtime.restore();

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

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const usage =
    \\usage: zeta <command>
    \\
    \\  serve [--hostname <address>]
    \\               run the server in the foreground; --hostname listens on
    \\               another address (e.g. 0.0.0.0) for other machines
    \\  --version    print version
    \\
;
