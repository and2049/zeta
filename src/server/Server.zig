//! The long-lived zeta server: TCP listener on loopback, Basic auth, the
//! discovery file, and the route table.

const Server = @This();

const std = @import("std");
const proto = @import("proto");
const core = @import("core");
const platform = @import("platform");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const conn = @import("conn.zig");
const conn_limits = @import("limits.zig");
const routes = @import("routes.zig");
const AuthFlow = @import("auth_flow.zig");

pub const first_port = 4096;
// Rapid restarts leave ports in TIME_WAIT because listeners deliberately do
// not use SO_REUSEADDR. Allow a full integration run to keep finding a port.
const port_attempts = 1024;
pub const heartbeat_seconds = 15;

gpa: Allocator,
io: Io,
bus: *core.Bus,
runtime: *core.Runtime,
version: []const u8,
password: [auth.password_len]u8,
listener: Io.net.Server,
port: u16,
event_listeners: std.atomic.Value(u32) = .init(0),
stop_requested: Io.Event = .unset,
data_dir: []const u8,
config_mutex: Io.Mutex = .init,
auth_flow: AuthFlow = .{},
limits: conn_limits.Limits,
url_buf: [64]u8 = undefined,
url_len: usize = 0,

pub const Options = struct {
    version: []const u8,
    hostname: []const u8 = "127.0.0.1",
    first_port: u16 = first_port,
    data_dir: []const u8,
    limits: conn_limits.Limits = .{},
};

/// Binds the first free port at or above `options.first_port`.
pub fn listen(gpa: Allocator, io: Io, runtime: *core.Runtime, options: Options) !Server {
    var port = options.first_port;
    const listener = while (true) : (port += 1) {
        const addr = try Io.net.IpAddress.parse(options.hostname, port);
        break addr.listen(io, .{ .reuse_address = false }) catch |err| switch (err) {
            error.AddressInUse => {
                if (port - options.first_port >= port_attempts or port == std.math.maxInt(u16)) return err;
                continue;
            },
            else => |e| return e,
        };
    };
    var s: Server = .{
        .gpa = gpa,
        .io = io,
        .bus = runtime.bus,
        .runtime = runtime,
        .version = options.version,
        .password = try auth.generatePassword(io),
        .listener = listener,
        .port = port,
        .data_dir = options.data_dir,
        .limits = options.limits,
    };
    // A wildcard bind is reached locally through loopback.
    const host = if (std.mem.eql(u8, options.hostname, "0.0.0.0")) "127.0.0.1" else options.hostname;
    s.url_len = (try std.fmt.bufPrint(&s.url_buf, "http://{s}:{d}", .{ host, port })).len;
    return s;
}

pub fn deinit(s: *Server) void {
    s.auth_flow.deinit(s.io);
    s.listener.deinit(s.io);
}

pub fn url(s: *const Server) []const u8 {
    return s.url_buf[0..s.url_len];
}

/// Hold for the server lifetime, including discovery cleanup. The stable lock
/// inode serializes startup across processes; closing releases it after a crash.
pub fn lockInstance(io: Io, runtime_dir: []const u8) !Io.File {
    _ = try Io.Dir.cwd().createDirPathStatus(io, runtime_dir, .fromMode(0o700));
    const dir = try Io.Dir.cwd().openDir(io, runtime_dir, .{});
    defer dir.close(io);
    return dir.createFile(io, "server.lock", .{
        .truncate = false,
        .permissions = .fromMode(0o600),
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
}

test "server lifetime lock excludes another startup and releases on close" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const directory = buf[0..try tmp.dir.realPath(io, &buf)];
    const first = try lockInstance(io, directory);
    {
        defer first.close(io);
        try std.testing.expectError(error.WouldBlock, lockInstance(io, directory));
    }
    const second = try lockInstance(io, directory);
    second.close(io);
}

/// Returns the URL of another live server published in `runtime_dir`, if
/// any: its pid is alive and its port accepts connections. Guards against a
/// second server replacing the discovery file of the first.
pub fn findRunning(gpa: Allocator, io: Io, runtime_dir: []const u8) !?[]u8 {
    const path = try std.fs.path.join(gpa, &.{ runtime_dir, proto.discovery.file_name });
    defer gpa.free(path);
    const bytes = (try platform.fs.readFileIfExists(io, gpa, path, 64 * 1024)) orelse return null;
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = proto.Discovery.decode(arena.allocator(), bytes) catch return null;
    if (d.pid == std.c.getpid() or !platform.process.isAlive(d.pid)) return null;

    const uri = std.Uri.parse(d.url) catch return null;
    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return null;
    const addr = Io.net.IpAddress.parse(host.bytes, uri.port orelse return null) catch return null;
    var stream = addr.connect(io, .{ .mode = .stream }) catch return null;
    stream.close(io);
    return try gpa.dupe(u8, d.url);
}

/// Writes `<runtime>/server.json` (0600). The composition root removes it
/// after graceful shutdown. Returns the file path, allocated with `gpa`.
pub fn publishDiscovery(s: *Server, runtime_dir: []const u8) ![]u8 {
    const pid: i64 = @intCast(std.c.getpid());
    const d: proto.Discovery = .{ .url = s.url(), .pid = pid, .version = s.version, .password = &s.password };
    const bytes = try d.encode(s.gpa);
    defer s.gpa.free(bytes);
    try platform.fs.writePrivateAtomic(s.io, runtime_dir, proto.discovery.file_name, bytes);
    const path = try std.fs.path.join(s.gpa, &.{ runtime_dir, proto.discovery.file_name });
    errdefer s.gpa.free(path);
    platform.signal.installTermination();
    return path;
}

/// Stops the server once process `pid` has gone (a standalone server's
/// client).
pub fn stopWhenGone(s: *Server, pid: i64) Io.Cancelable!void {
    while (platform.process.isAlive(pid)) try s.io.sleep(.fromMilliseconds(500), .awake);
    s.stop_requested.set(s.io);
}

pub fn serve(s: *Server) !void {
    const Done = union(enum) { listener: Io.Cancelable!void, stop: Io.Cancelable!void, signal: Io.Cancelable!void };
    var storage: [3]Done = undefined;
    var select: Io.Select(Done) = .init(s.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.listener, acceptLoop, .{s});
    try select.concurrent(.stop, Io.Event.wait, .{ &s.stop_requested, s.io });
    try select.concurrent(.signal, waitSignal, .{s});
    switch (try select.await()) {
        inline else => |result| try result,
    }
}

fn waitSignal(s: *Server) Io.Cancelable!void {
    while (!platform.signal.terminationRequested()) try s.io.sleep(.fromMilliseconds(50), .awake);
}

fn acceptLoop(s: *Server) Io.Cancelable!void {
    // Declared first so connection tasks and the watchdog end before it.
    var tracker: conn_limits.Tracker = undefined;
    tracker.init(s.io, s.limits);
    var watchdog = s.io.concurrent(conn_limits.Tracker.watchdog, .{&tracker}) catch null;
    defer if (watchdog) |*w| w.cancel(s.io) catch {};
    if (watchdog == null) std.log.err("connection deadlines unavailable: no concurrency", .{});

    var group: Io.Group = .init;
    defer group.cancel(s.io);

    var heartbeat = s.io.concurrent(heartbeatLoop, .{s}) catch null;
    defer if (heartbeat) |*h| h.cancel(s.io) catch {};

    while (true) {
        const stream = s.listener.accept(s.io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.ConnectionAborted => continue,
            else => {
                std.log.err("accept failed: {t}", .{err});
                return;
            },
        };
        const slot = tracker.admit(stream) orelse {
            refuse(s.io, stream);
            continue;
        };
        group.concurrent(s.io, conn.serve, .{ s.gpa, s.io, stream, slot, &s.password, @as(*anyopaque, s), handle }) catch {
            tracker.release(slot);
            var copy = stream;
            copy.close(s.io);
        };
    }
}

/// Every connection slot is taken: answer without reading the request.
fn refuse(io: Io, stream: Io.net.Stream) void {
    var writer = stream.writer(io, &.{});
    writer.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: 32\r\nconnection: close\r\n\r\n{\"error\":\"too many connections\"}") catch {};
    var copy = stream;
    copy.close(io);
}

fn heartbeatLoop(s: *Server) Io.Cancelable!void {
    while (true) {
        try s.io.sleep(.fromSeconds(heartbeat_seconds), .awake);
        _ = s.bus.publish(.{ .type = proto.event.types.server_heartbeat }) catch {};
    }
}

fn handle(userdata: *anyopaque, c: *conn.Ctx) anyerror!void {
    const s: *Server = @ptrCast(@alignCast(userdata));
    return routes.dispatch(s, c);
}
