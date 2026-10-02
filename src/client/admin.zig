//! Local administrative CLI actions. `stop` never starts a server.
const std = @import("std");
const proto = @import("proto");
const platform = @import("platform");
const Client = @import("Client.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads a hidden TTY key or one piped stdin line and persists it locally.
/// On success the caller can print a generic confirmation; never print a key.
pub fn authLogin(gpa: Allocator, io: Io, paths: platform.Paths, provider: []const u8) !void {
    const key = try platform.terminal.readSecret(gpa, io);
    defer {
        @memset(key, 0);
        gpa.free(key);
    }
    try platform.credentials.putApiKey(gpa, io, paths.data, provider, key);
}

pub const StopResult = enum { stopped, not_running };

/// Authenticated shutdown using the published discovery token, without
/// autospawn. Returns `not_running` if no live discovered server exists.
/// Bounds the request and discovery-removal wait together to five seconds.
pub fn stop(gpa: Allocator, io: Io, paths: platform.Paths) !StopResult {
    const Result = union(enum) { stopped: anyerror!StopResult, timeout: Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.stopped, stopWithin, .{ gpa, io, paths });
    try select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromSeconds(5), .awake });
    switch (try select.await()) {
        .stopped => |result| return result,
        .timeout => |result| {
            try result;
            return error.ServerStopTimeout;
        },
    }
}

/// The live server's discovery record, or null; never starts a server.
pub fn running(arena: Allocator, io: Io, paths: platform.Paths) !?proto.Discovery {
    const path = try std.fs.path.join(arena, &.{ paths.runtime, proto.discovery.file_name });
    const bytes = (try platform.fs.readFileIfExists(io, arena, path, 64 * 1024)) orelse return null;
    const discovery = proto.Discovery.decode(arena, bytes) catch return error.InvalidDiscovery;
    if (!platform.process.isAlive(discovery.pid)) return null;
    return discovery;
}

/// Asks a running server to reload plugins for the user layer and
/// `location`. Null when no server is running (nothing is loaded). The
/// failures live in `arena`.
pub fn reload(gpa: Allocator, arena: Allocator, io: Io, paths: platform.Paths, location: []const u8) !?[]const @import("session_api.zig").ReloadFailure {
    const discovery = try running(arena, io, paths) orelse return null;
    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    return try @import("session_api.zig").reload(&client, arena, location);
}

fn stopWithin(gpa: Allocator, io: Io, paths: platform.Paths) !StopResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fs.path.join(arena, &.{ paths.runtime, proto.discovery.file_name });
    const discovery = try running(arena, io, paths) orelse return .not_running;

    var client = try Client.init(gpa, io, discovery.url, discovery.password);
    defer client.deinit();
    const response = try client.postJson(arena, "/server/stop", .{});
    if (!response.ok()) return error.ServerStopRejected;

    const deadline = Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        const current = try platform.fs.readFileIfExists(io, arena, path, 64 * 1024);
        if (current == null) return .stopped;
        // A replacement discovery record belongs to a different server; don't
        // mistake it for a still-running instance of the one just stopped.
        const latest = proto.Discovery.decode(arena, current.?) catch return error.InvalidDiscovery;
        if (latest.pid != discovery.pid or !std.mem.eql(u8, latest.password, discovery.password)) return .stopped;
        try io.sleep(.fromMilliseconds(25), .awake);
    }
    return error.ServerStopTimeout;
}

test "stop never autospawns when no discovery exists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const paths: platform.Paths = .{
        .config = base,
        .data = base,
        .state = base,
        .cache = base,
        .runtime = base,
    };
    try std.testing.expectEqual(StopResult.not_running, try stop(std.testing.allocator, io, paths));
}
