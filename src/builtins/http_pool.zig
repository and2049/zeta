//! Long-lived HTTP clients for provider transports. Each transport owns one
//! pool, shared by every session, so requests reuse open connections and the
//! system certificates are read once per client generation instead of per
//! request. A generation is replaced after `idle_ms` without requests (its
//! idle connections are dropped: servers close them on their own schedule)
//! or after `max_age_ms` (a client checks certificate dates against the time
//! it loaded the certificates).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http_cause = @import("http_cause.zig");

const Client = std.http.Client;

pub const Pool = struct {
    /// Must be thread-safe: connections are allocated and freed by whichever
    /// session uses them.
    gpa: Allocator,
    io: Io,
    idle_ms: i64 = 30_000,
    max_age_ms: i64 = 3_600_000,
    /// How long a finished response may take to end before its connection is
    /// closed instead of reused.
    drain_ms: i64 = 100,
    mutex: Io.Mutex = .init,
    current: ?*Gen = null,
    /// Awake-clock ms of the last request start or release.
    last_used: i64 = 0,

    pub fn init(gpa: Allocator, io: Io) Pool {
        return .{ .gpa = gpa, .io = io };
    }

    /// Asserts that no lease is outstanding.
    pub fn deinit(p: *Pool) void {
        if (p.current) |g| {
            std.debug.assert(g.refs == 0);
            g.destroy(p.gpa);
        }
        p.* = undefined;
    }

    fn now(p: *Pool) i64 {
        return Io.Clock.awake.now(p.io).toMilliseconds();
    }

    fn acquire(p: *Pool) !*Gen {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const t = p.now();
        if (p.current) |g| if (t - p.last_used > p.idle_ms or t - g.born > p.max_age_ms) p.retireLocked(g);
        const g = p.current orelse blk: {
            const g = try p.gpa.create(Gen);
            g.* = .{ .client = .{ .allocator = p.gpa, .io = p.io }, .born = t };
            p.current = g;
            break :blk g;
        };
        g.refs += 1;
        p.last_used = t;
        return g;
    }

    fn release(p: *Pool, g: *Gen) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        g.refs -= 1;
        p.last_used = p.now();
        if (g.retired and g.refs == 0) g.destroy(p.gpa);
    }

    /// Drops `g`'s idle connections by starting a new generation. The
    /// caller holds a reference to `g`.
    fn retire(p: *Pool, g: *Gen) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.current == g) p.retireLocked(g);
    }

    fn retireLocked(p: *Pool, g: *Gen) void {
        p.current = null;
        g.retired = true;
        if (g.refs == 0) g.destroy(p.gpa);
    }
};

const Gen = struct {
    client: Client,
    born: i64,
    refs: usize = 0,
    retired: bool = false,
    /// Guards the certificate load and `lingering`.
    mutex: Io.Mutex = .init,
    certificates: std.atomic.Value(bool) = .init(false),
    /// Endpoints (host and port hashes) whose finished responses did not end
    /// within `drain_ms`: they keep streams open, so their connections are
    /// closed rather than drained. Forgotten with the generation.
    lingering: [8]u64 = undefined,
    lingering_len: usize = 0,

    fn destroy(g: *Gen, gpa: Allocator) void {
        g.client.deinit();
        gpa.destroy(g);
    }

    /// Loads the system certificates once, before any request on this
    /// client needs them. The client would load them itself, but several
    /// first requests at once would each load them and race on the result.
    fn loadCertificates(g: *Gen, io: Io) !void {
        if (g.certificates.load(.acquire)) return;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        if (g.certificates.load(.monotonic)) return;
        const now = Io.Clock.real.now(io);
        g.client.ca_bundle.rescan(g.client.allocator, io, now) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.CertificateBundleLoadFailure,
        };
        g.client.now = now;
        g.certificates.store(true, .release);
    }

    fn isLingering(g: *Gen, io: Io, key: u64) bool {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        return std.mem.findScalar(u64, g.lingering[0..g.lingering_len], key) != null;
    }

    fn markLingering(g: *Gen, io: Io, key: u64) void {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        if (std.mem.findScalar(u64, g.lingering[0..g.lingering_len], key) != null) return;
        if (g.lingering_len == g.lingering.len) return;
        g.lingering[g.lingering_len] = key;
        g.lingering_len += 1;
    }
};

pub const Options = struct {
    headers: Client.Request.Headers = .{},
    extra_headers: []const std.http.Header = &.{},
};

/// One request on a pooled connection. Must not move after `post`.
pub const Lease = struct {
    pool: *Pool,
    gen: *Gen,
    req: Client.Request,
    /// Identifies the endpoint for `Gen.lingering`.
    endpoint: u64,
    reusable: bool = false,

    /// Closes the connection unless `finish` found the response complete.
    pub fn release(l: *Lease) void {
        if (!l.reusable) if (l.req.connection) |c| {
            c.closing = true;
        };
        l.req.deinit();
        l.pool.release(l.gen);
        l.* = undefined;
    }

    /// Call after the last event of a successful response. The connection is
    /// kept for reuse if the body ends within the pool's `drain_ms`.
    pub fn finish(l: *Lease, reader: *Io.Reader) void {
        const io = l.pool.io;
        if (l.gen.isLingering(io, l.endpoint)) return;
        const Done = union(enum) { drained: bool, deadline: Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select: Io.Select(Done) = .init(io, &storage);
        defer select.cancelDiscard();
        select.concurrent(.drained, drain, .{reader}) catch return;
        select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(l.pool.drain_ms), Io.Clock.awake }) catch return;
        const done = select.await() catch {
            io.recancel();
            return;
        };
        switch (done) {
            .drained => |ok| l.reusable = ok and l.req.reader.state == .ready,
            .deadline => l.gen.markLingering(io, l.endpoint),
        }
    }

    fn drain(reader: *Io.Reader) bool {
        _ = reader.discardRemaining() catch return false;
        return true;
    }
};

/// POSTs `body` and waits for the response head. On success the caller reads
/// the response through `lease`, calls `lease.finish` after the last event,
/// and always `lease.release()`. On error nothing is held, and std.http's
/// generic read/write errors are replaced by their cause.
///
/// A connection the server had closed (usually a pooled one it dropped while
/// idle) is retried once on a new one: only when writing the request failed,
/// or the connection closed before any byte of a response. Anything later (a
/// `100 Continue`, a truncated or invalid head) may follow a processed
/// request and is not retried here.
pub fn post(p: *Pool, lease: *Lease, uri: std.Uri, options: Options, body: []const u8) !Client.Response {
    var retried = false;
    while (true) {
        const gen = try p.acquire();
        start(p, gen, lease, uri, options) catch |err| {
            p.release(gen);
            return err;
        };
        if (write(&lease.req, body)) |_| {
            if (lease.req.receiveHead(&.{})) |response| return response else |err| {
                const cause = http_cause.of(&lease.req, err);
                const nothing_received = cause == error.HttpConnectionClosing and lease.req.reader.state == .ready;
                if (retried or !nothing_received) {
                    lease.release();
                    return cause;
                }
            }
        } else |err| {
            const cause = http_cause.of(&lease.req, err);
            if (retried or cause == error.Canceled) {
                lease.release();
                return cause;
            }
        }
        // Its other idle connections were likely dropped too. Retire first:
        // the lease's reference keeps `gen` alive until then.
        p.retire(gen);
        lease.release();
        retried = true;
    }
}

fn start(p: *Pool, gen: *Gen, lease: *Lease, uri: std.Uri, options: Options) !void {
    const protocol = Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    if (protocol == .tls) try gen.loadCertificates(p.io);
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&buf);
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    lease.* = .{
        .pool = p,
        .gen = gen,
        .endpoint = std.hash.Wyhash.hash(port, host.bytes),
        .req = try gen.client.request(.POST, uri, .{
            .headers = options.headers,
            .extra_headers = options.extra_headers,
        }),
    };
}

fn write(req: *Client.Request, body: []const u8) !void {
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
}

test {
    _ = @import("http_pool_test.zig");
}
