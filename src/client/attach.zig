const std = @import("std");
const proto = @import("proto");
const platform = @import("platform");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");

pub const Options = struct {
    paths: platform.Paths,
    exe: []const u8,
    timeout_ms: i64 = 5000,
    /// Arguments that start the server, and where its output goes (the
    /// shared server's log when null).
    serve: []const []const u8 = &.{"serve"},
    log: ?[]const u8 = null,
};

/// Returns a live server's discovery record, spawning `zeta serve` if none is
/// running. Strings are allocated in `arena`.
pub fn attach(gpa: Allocator, arena: Allocator, io: Io, options: Options) !proto.Discovery {
    const path = try std.fs.path.join(arena, &.{ options.paths.runtime, proto.discovery.file_name });
    if (try probe(gpa, arena, io, path)) |d| return d;

    const log_path = options.log orelse try options.paths.serverLog(arena);
    try platform.process.spawnDetached(io, try std.mem.concat(arena, []const u8, &.{ &.{options.exe}, options.serve }), log_path);

    const deadline = Io.Clock.awake.now(io).toMilliseconds() + options.timeout_ms;
    while (Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        try io.sleep(.fromMilliseconds(20), .awake);
        if (try probe(gpa, arena, io, path)) |d| return d;
    }
    return error.ServerStartTimeout;
}

/// The live server's discovery record, without starting one.
pub fn find(gpa: Allocator, arena: Allocator, io: Io, options: Options) !?proto.Discovery {
    const path = try std.fs.path.join(arena, &.{ options.paths.runtime, proto.discovery.file_name });
    return probe(gpa, arena, io, path);
}

/// A discovery record counts only if its pid is alive and `/health` answers.
fn probe(gpa: Allocator, arena: Allocator, io: Io, path: []const u8) !?proto.Discovery {
    const bytes = (try platform.fs.readFileIfExists(io, arena, path, 64 * 1024)) orelse return null;
    const d = proto.Discovery.decode(arena, bytes) catch return null;
    if (!platform.process.isAlive(d.pid)) return null;

    var c = try Client.init(gpa, io, d.url, d.password);
    defer c.deinit();
    const res = c.get(arena, "/health") catch return null;
    return if (res.ok()) d else null;
}
