//! MCP server sign-ins in the credential store, under `mcp:<server>`:
//! `{"type": "mcp", "url", "resource", "access", "refresh", "expires",
//! "client_id", "client_secret", "secret_post", "token_endpoint"}`. The tokens belong to
//! `url`: a server whose configured URL differs never gets them. `resource`
//! is what they were issued for, and is asked for again on refresh.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const store = @import("credentials.zig");

pub const Value = struct {
    url: []const u8,
    resource: []const u8,
    access: []const u8,
    refresh: ?[]const u8 = null,
    /// Unix milliseconds; 0 when the server did not say.
    expires: i64 = 0,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    /// The secret goes in the token request body instead of HTTP Basic.
    secret_post: bool = false,
    token_endpoint: []const u8,
};

/// A stored sign-in; every slice belongs to `arena`.
pub const Token = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(t: *Token) void {
        t.arena.deinit();
        t.* = undefined;
    }
};

/// The store key for `server`: `mcp:<server>` when the name has only
/// letters, digits, `.`, `_` and `-` and fits; otherwise the name made safe
/// and a hash of it, `mcp:<safe>:<hash>`, whose second `:` no plain key
/// has, so no two names share a key. `buf` needs 128 bytes.
pub fn id(buf: []u8, server: []const u8) ![]const u8 {
    const plain_chars = for (server) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') break false;
    } else server.len > 0;
    if (plain_chars and server.len <= 100) return std.fmt.bufPrint(buf, "mcp:{s}", .{server});
    var safe: [48]u8 = undefined;
    const n = @min(server.len, safe.len);
    for (server[0..n], safe[0..n]) |c, *out| out.* = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') c else '_';
    return std.fmt.bufPrint(buf, "mcp:{s}:{x:0>16}", .{ safe[0..n], std.hash.Wyhash.hash(0, server) });
}

test id {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("mcp:docs", try id(&buf, "docs"));
    const spaced = try id(&buf, "my server");
    try std.testing.expect(std.mem.startsWith(u8, spaced, "mcp:my_server:") and store.validId(spaced));
    var other: [128]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, spaced, try id(&other, "my_server")));
    // A plain name can never look like a made-safe one.
    try std.testing.expect(!std.mem.eql(u8, spaced, try id(&other, spaced["mcp:".len..])));
    try std.testing.expect(store.validId(try id(&buf, "x" ** 300)));
}

pub fn validEntry(o: std.json.ObjectMap) bool {
    if (o.count() != 10) return false;
    const post = o.get("secret_post") orelse return false;
    if (post != .bool) return false;
    for ([_][]const u8{ "url", "resource", "access", "client_id", "token_endpoint" }) |key| {
        const v = o.get(key) orelse return false;
        if (v != .string or !store.validKey(v.string)) return false;
    }
    for ([_][]const u8{ "refresh", "client_secret" }) |key| {
        const v = o.get(key) orelse return false;
        if (v != .null and (v != .string or !store.validKey(v.string))) return false;
    }
    const expires = o.get("expires") orelse return false;
    return expires == .integer;
}

fn valid(v: Value) bool {
    for ([_][]const u8{ v.url, v.resource, v.access, v.client_id, v.token_endpoint }) |text| if (!store.validKey(text)) return false;
    for ([_]?[]const u8{ v.refresh, v.client_secret }) |text| if (text) |t| if (!store.validKey(t)) return false;
    return true;
}

fn entry(a: Allocator, v: Value) !std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "type", .{ .string = "mcp" });
    try o.put(a, "url", .{ .string = v.url });
    try o.put(a, "resource", .{ .string = v.resource });
    try o.put(a, "access", .{ .string = v.access });
    try o.put(a, "refresh", if (v.refresh) |r| .{ .string = r } else .null);
    try o.put(a, "expires", .{ .integer = v.expires });
    try o.put(a, "client_id", .{ .string = v.client_id });
    try o.put(a, "client_secret", if (v.client_secret) |c| .{ .string = c } else .null);
    try o.put(a, "secret_post", .{ .bool = v.secret_post });
    try o.put(a, "token_endpoint", .{ .string = v.token_endpoint });
    return .{ .object = o };
}

fn fromEntry(allocator: Allocator, o: std.json.ObjectMap) !Token {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const optional = struct {
        fn get(al: Allocator, m: std.json.ObjectMap, key: []const u8) !?[]const u8 {
            const v = m.get(key).?;
            return if (v == .string) try al.dupe(u8, v.string) else null;
        }
    }.get;
    const value: Value = .{
        .url = try a.dupe(u8, o.get("url").?.string),
        .resource = try a.dupe(u8, o.get("resource").?.string),
        .access = try a.dupe(u8, o.get("access").?.string),
        .refresh = try optional(a, o, "refresh"),
        .expires = o.get("expires").?.integer,
        .client_id = try a.dupe(u8, o.get("client_id").?.string),
        .client_secret = try optional(a, o, "client_secret"),
        .secret_post = o.get("secret_post").?.bool,
        .token_endpoint = try a.dupe(u8, o.get("token_endpoint").?.string),
    };
    // After every allocation: the arena is copied into the result.
    return .{ .arena = arena, .value = value };
}

pub fn put(allocator: Allocator, io: Io, data_dir: []const u8, key: []const u8, v: Value) !void {
    if (!store.validId(key)) return error.InvalidProviderId;
    if (!valid(v)) return error.InvalidOAuthCredential;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try store.lockDir(io, data_dir);
    defer dir.close(io);
    const lock = try store.writerLock(io, dir);
    defer lock.close(io);
    var entries = try store.load(a, io, data_dir);
    try entries.put(a, try a.dupe(u8, key), try entry(a, v));
    try store.save(a, io, &dir, entries);
}

/// Removes `key` of any type; false when there was none.
pub fn remove(allocator: Allocator, io: Io, data_dir: []const u8, key: []const u8) !bool {
    if (!store.validId(key)) return error.InvalidProviderId;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try store.lockDir(io, data_dir);
    defer dir.close(io);
    const lock = try store.writerLock(io, dir);
    defer lock.close(io);
    var entries = try store.load(a, io, data_dir);
    if (!entries.orderedRemove(key)) return false;
    try store.save(a, io, &dir, entries);
    return true;
}

/// The sign-in stored for `key` if it belongs to `url`. It is refreshed
/// first (under the writers' lock, so concurrent refreshes do not both
/// spend a rotating refresh token) when it expires within a minute or when
/// `stale` is the access token a server just refused. Null when there is
/// none, it is for another URL, or it was refused or has expired and
/// cannot be refreshed.
pub fn fresh(allocator: Allocator, io: Io, data_dir: []const u8, key: []const u8, url: []const u8, stale: ?[]const u8, context: anytype, comptime refreshFn: fn (@TypeOf(context), Allocator, Io, Value) anyerror!Value) !?Token {
    if (!store.validId(key)) return error.InvalidProviderId;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Most calls need no refresh: the file is replaced atomically, so they
    // read it without the writers' lock.
    switch (try judge(a, io, try store.load(a, io, data_dir), key, url, stale)) {
        .none => return null,
        .keep => |o| return try fromEntry(allocator, o),
        .refresh => {},
    }
    var dir = try store.lockDir(io, data_dir);
    defer dir.close(io);
    const lock = try store.writerLock(io, dir);
    defer lock.close(io);
    var entries = try store.load(a, io, data_dir);
    const found = switch (try judge(a, io, entries, key, url, stale)) {
        .none => return null,
        .keep => |o| return try fromEntry(allocator, o),
        .refresh => |o| o,
    };
    const current = (try fromEntry(a, found)).value;
    const next = refreshFn(context, a, io, current) catch |err| {
        if (err == error.Canceled) return err;
        // A refresh that failed (a timeout, a busy server) leaves a token
        // that has not expired and was not refused usable.
        const refused = if (stale) |s| std.mem.eql(u8, s, current.access) else false;
        const expired = current.expires != 0 and current.expires <= Io.Clock.real.now(io).toMilliseconds();
        return if (refused or expired) null else try fromEntry(allocator, found);
    };
    if (!valid(next)) return error.InvalidOAuthCredential;
    const replaced = try entry(a, next);
    try entries.put(a, try a.dupe(u8, key), replaced);
    // The server may already have spent the old refresh token.
    try store.saveRefreshed(a, io, &dir, entries);
    return try fromEntry(allocator, replaced.object);
}

const Verdict = union(enum) { none, keep: std.json.ObjectMap, refresh: std.json.ObjectMap };

/// What `fresh` does with the stored entry for `key`.
fn judge(a: Allocator, io: Io, entries: std.json.ObjectMap, key: []const u8, url: []const u8, stale: ?[]const u8) !Verdict {
    const found = entries.get(key) orelse return .none;
    if (!std.mem.eql(u8, found.object.get("type").?.string, "mcp")) return .none;
    const current = (try fromEntry(a, found.object)).value;
    if (!std.mem.eql(u8, current.url, url)) return .none;
    const refused = if (stale) |s| std.mem.eql(u8, s, current.access) else false;
    const now = Io.Clock.real.now(io).toMilliseconds();
    const expiring = current.expires != 0 and current.expires <= now +| 60_000;
    if (!refused and !expiring) return .{ .keep = found.object };
    if (current.refresh == null) {
        // Nothing to renew it with: usable until it actually expires.
        const expired = current.expires != 0 and current.expires <= now;
        return if (refused or expired) .none else .{ .keep = found.object };
    }
    return .{ .refresh = found.object };
}

test "stored per URL, refreshed when refused or expiring, removed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const far = Io.Clock.real.now(io).toMilliseconds() + 3_600_000;
    try put(gpa, io, dir, "mcp:docs", .{ .url = "https://a/mcp", .resource = "https://a/mcp", .access = "one", .refresh = "r1", .expires = far, .client_id = "c", .token_endpoint = "https://a/token" });
    const Refresher = struct {
        calls: usize = 0,
        fn refresh(self: *@This(), a: Allocator, _: Io, old: Value) anyerror!Value {
            self.calls += 1;
            var next = old;
            next.access = try a.dupe(u8, "two");
            return next;
        }
    };
    var r: Refresher = .{};
    var kept = (try fresh(gpa, io, dir, "mcp:docs", "https://a/mcp", null, &r, Refresher.refresh)).?;
    try std.testing.expectEqualStrings("one", kept.value.access);
    kept.deinit();
    try std.testing.expect((try fresh(gpa, io, dir, "mcp:docs", "https://other/mcp", null, &r, Refresher.refresh)) == null);
    var renewed = (try fresh(gpa, io, dir, "mcp:docs", "https://a/mcp", "one", &r, Refresher.refresh)).?;
    defer renewed.deinit();
    try std.testing.expectEqualStrings("two", renewed.value.access);
    try std.testing.expectEqual(@as(usize, 1), r.calls);
    var listing = try store.list(gpa, io, dir);
    defer listing.deinit();
    try std.testing.expectEqualStrings("mcp", listing.items[0].type);
    try std.testing.expect(try remove(gpa, io, dir, "mcp:docs"));
    try std.testing.expect(!try remove(gpa, io, dir, "mcp:docs"));
}

test "a refresh that finishes while its task is cancelled is still saved" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try put(gpa, io, dir, "mcp:docs", .{ .url = "https://a/mcp", .resource = "https://a/mcp", .access = "old", .refresh = "r1", .expires = 1, .client_id = "c", .token_endpoint = "https://a/token" });
    const Rotating = struct {
        started: Io.Event = .unset,
        // The server answers after the cancellation was requested; it has
        // spent `r1` by then.
        fn refresh(self: *@This(), a: Allocator, io_: Io, old: Value) anyerror!Value {
            const previous = io_.swapCancelProtection(.blocked);
            defer _ = io_.swapCancelProtection(previous);
            self.started.set(io_);
            io_.sleep(.fromMilliseconds(50), .awake) catch {};
            var next = old;
            next.access = try a.dupe(u8, "new");
            next.refresh = try a.dupe(u8, "r2");
            next.expires = 0;
            return next;
        }
        fn run(self: *@This(), io_: Io, data_dir: []const u8) !?Token {
            return fresh(std.testing.allocator, io_, data_dir, "mcp:docs", "https://a/mcp", null, self, refresh);
        }
    };
    var r: Rotating = .{};
    var task = try io.concurrent(Rotating.run, .{ &r, io, dir });
    try r.started.wait(io);
    if (task.cancel(io)) |got| {
        if (got) |t| @constCast(&t).deinit();
    } else |_| {}
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const stored = (try store.load(arena.allocator(), io, dir)).get("mcp:docs").?;
    try std.testing.expectEqualStrings("r2", stored.object.get("refresh").?.string);
}

test "without a refresh token a sign-in lasts until it expires or is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const soon = Io.Clock.real.now(io).toMilliseconds() + 30_000;
    try put(gpa, io, dir, "mcp:x", .{ .url = "https://a/mcp", .resource = "https://a/mcp", .access = "short", .expires = soon, .client_id = "c", .token_endpoint = "https://a/token" });
    const Never = struct {
        fn refresh(_: void, _: Allocator, _: Io, _: Value) anyerror!Value {
            return error.NoRefresh;
        }
    };
    var kept = (try fresh(gpa, io, dir, "mcp:x", "https://a/mcp", null, {}, Never.refresh)).?;
    kept.deinit();
    try std.testing.expect((try fresh(gpa, io, dir, "mcp:x", "https://a/mcp", "short", {}, Never.refresh)) == null);
}
