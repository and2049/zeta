//! API-key and OAuth credentials at `<data_dir>/credentials.json`.
//! Writers lock a stable sidecar inode across read-modify-write; the lock is
//! released by closing the descriptor even after a crash. Never unlink it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const file_name = "credentials.json";
const max_file_size = 1024 * 1024;

pub const Metadata = struct {
    id: []const u8,
    type: []const u8,
};

/// All slices are owned by the returned value's arena. Never serialize this in
/// admin responses: access, refresh and account ID are private credential data.
pub const OAuth = struct {
    arena: std.heap.ArenaAllocator,
    access: []const u8,
    refresh: []const u8,
    expires: i64, // Unix milliseconds
    account_id: ?[]const u8,

    pub fn deinit(self: *OAuth) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OAuthValue = struct {
    access: []const u8,
    refresh: []const u8,
    expires: i64,
    account_id: ?[]const u8 = null,
};

/// Owns all metadata strings and the items slice; call `deinit` when done.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Metadata,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Ids are provider ids, or `mcp:<server>` for an MCP server's sign-in.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return false;
    }
    return true;
}

/// A provider's id: never `:`, so a provider credential cannot replace an
/// MCP server's sign-in.
fn validProviderId(id: []const u8) bool {
    return validId(id) and std.mem.indexOfScalar(u8, id, ':') == null;
}

pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_file_size) return false;
    for (key) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(key);
}

fn validate(root: std.json.Value) !std.json.ObjectMap {
    if (root != .object) return error.InvalidCredentials;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        if (!validId(entry.key_ptr.*)) return error.InvalidCredentials;
        const value = entry.value_ptr.*;
        if (value != .object) return error.InvalidCredentials;
        const kind = value.object.get("type") orelse return error.InvalidCredentials;
        if (kind != .string) return error.InvalidCredentials;
        if (std.mem.eql(u8, kind.string, "api")) {
            const key = value.object.get("key") orelse return error.InvalidCredentials;
            if (value.object.count() != 2 or key != .string or !validKey(key.string)) return error.InvalidCredentials;
        } else if (std.mem.eql(u8, kind.string, "oauth")) {
            const access = value.object.get("access") orelse return error.InvalidCredentials;
            const refresh = value.object.get("refresh") orelse return error.InvalidCredentials;
            const expires = value.object.get("expires") orelse return error.InvalidCredentials;
            const account = value.object.get("account_id") orelse return error.InvalidCredentials;
            if (value.object.count() != 5 or access != .string or !validKey(access.string) or
                refresh != .string or !validKey(refresh.string) or expires != .integer or
                (account != .null and (account != .string or !validKey(account.string)))) return error.InvalidCredentials;
        } else if (std.mem.eql(u8, kind.string, "mcp")) {
            if (!mcp.validEntry(value.object)) return error.InvalidCredentials;
        } else return error.InvalidCredentials;
    }
    return root.object;
}

pub const mcp = @import("credentials_mcp.zig");

pub fn load(arena: Allocator, io: Io, data_dir: []const u8) !std.json.ObjectMap {
    const path = try std.fs.path.join(arena, &.{ data_dir, file_name });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        error.StreamTooLong => return error.InvalidCredentials,
        else => |e| return e,
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidCredentials;
    return validate(parsed);
}

/// Returns a newly allocated key (caller frees with `allocator.free`), or null.
/// Parsing failures never include stored secret text in their error names.
pub fn readKey(allocator: Allocator, io: Io, data_dir: []const u8, provider_id: []const u8) !?[]u8 {
    if (!validId(provider_id)) return error.InvalidProviderId;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const entries = try load(arena.allocator(), io, data_dir);
    const entry = entries.get(provider_id) orelse return null;
    if (!std.mem.eql(u8, entry.object.get("type").?.string, "api")) return null;
    return try allocator.dupe(u8, entry.object.get("key").?.string);
}

fn oauthFromEntry(allocator: Allocator, entry: std.json.Value) !OAuth {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const account = entry.object.get("account_id").?;
    const access = try a.dupe(u8, entry.object.get("access").?.string);
    const refresh = try a.dupe(u8, entry.object.get("refresh").?.string);
    const account_id = if (account == .string) try a.dupe(u8, account.string) else null;
    return .{
        .arena = arena,
        .access = access,
        .refresh = refresh,
        .expires = entry.object.get("expires").?.integer,
        .account_id = account_id,
    };
}

/// Null for absent or API-key entries; caller owns and deinitializes the result.
pub fn readOAuth(allocator: Allocator, io: Io, data_dir: []const u8, provider_id: []const u8) !?OAuth {
    if (!validId(provider_id)) return error.InvalidProviderId;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const entries = try load(arena.allocator(), io, data_dir);
    const entry = entries.get(provider_id) orelse return null;
    if (!std.mem.eql(u8, entry.object.get("type").?.string, "oauth")) return null;
    return try oauthFromEntry(allocator, entry);
}

/// Lists provider IDs and types only. The returned listing owns its contents.
pub fn list(allocator: Allocator, io: Io, data_dir: []const u8) !Listing {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const entries = try load(a, io, data_dir);
    const items = try a.alloc(Metadata, entries.count());
    var it = entries.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        items[i] = .{ .id = entry.key_ptr.*, .type = entry.value_ptr.object.get("type").?.string };
    }
    return .{ .arena = arena, .items = items };
}

/// Replaces or inserts one API key. Inputs are borrowed, never retained.
/// Concurrent writers (including other processes) serialize on a sidecar lock.
pub fn putApiKey(allocator: Allocator, io: Io, data_dir: []const u8, provider_id: []const u8, key: []const u8) !void {
    if (!validProviderId(provider_id)) return error.InvalidProviderId;
    if (!validKey(key)) return error.InvalidApiKey;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try lockDir(io, data_dir);
    defer dir.close(io);
    // Lock the stable inode, not credentials.json (which is renamed on write).
    // Do not unlink: a waiter may already have the old inode open.
    const lock = try dir.createFile(io, "credentials.lock", .{
        .truncate = false,
        .permissions = .fromMode(0o600),
        .lock = .exclusive,
    });
    defer lock.close(io);
    try lock.setPermissions(io, .fromMode(0o600));
    var entries = try load(a, io, data_dir);
    var credential: std.json.ObjectMap = .empty;
    try credential.put(a, "type", .{ .string = "api" });
    try credential.put(a, "key", .{ .string = key });
    try entries.put(a, try a.dupe(u8, provider_id), .{ .object = credential });
    try save(a, io, &dir, entries);
}

pub fn lockDir(io: Io, data_dir: []const u8) !Io.Dir {
    const cwd = Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, data_dir, .fromMode(0o700));
    var dir = try cwd.openDir(io, data_dir, .{ .iterate = true });
    errdefer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
    return dir;
}

/// The writers' lock: a stable sidecar inode in `dir` (from `lockDir`).
/// Close it to release.
pub fn writerLock(io: Io, dir: Io.Dir) !Io.File {
    const file = try dir.createFile(io, "credentials.lock", .{ .truncate = false, .permissions = .fromMode(0o600), .lock = .exclusive });
    errdefer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    return file;
}

/// `save` for a refresh's result: finishes even when the task is cancelled
/// meanwhile, since the server may already have spent the old refresh token.
/// The cancellation is seen at the caller's next cancellation point.
pub fn saveRefreshed(a: Allocator, io: Io, dir: *Io.Dir, entries: std.json.ObjectMap) !void {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    try save(a, io, dir, entries);
}

pub fn save(a: Allocator, io: Io, dir: *Io.Dir, entries: std.json.ObjectMap) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = entries }, .{});
    if (bytes.len > max_file_size) return error.CredentialsTooLarge;

    var atomic = try dir.createFileAtomic(io, file_name, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn insertOAuth(a: Allocator, entries: *std.json.ObjectMap, provider_id: []const u8, value: OAuthValue) !void {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = "oauth" });
    try obj.put(a, "access", .{ .string = value.access });
    try obj.put(a, "refresh", .{ .string = value.refresh });
    try obj.put(a, "expires", .{ .integer = value.expires });
    try obj.put(a, "account_id", if (value.account_id) |id| .{ .string = id } else .null);
    try entries.put(a, try a.dupe(u8, provider_id), .{ .object = obj });
}

fn validOAuth(value: OAuthValue) bool {
    return validKey(value.access) and validKey(value.refresh) and
        (value.account_id == null or validKey(value.account_id.?));
}

/// Atomically persists OAuth tokens, with the same cross-process writer lock as API keys.
pub fn putOAuth(allocator: Allocator, io: Io, data_dir: []const u8, provider_id: []const u8, value: OAuthValue) !void {
    if (!validProviderId(provider_id)) return error.InvalidProviderId;
    if (!validOAuth(value)) return error.InvalidOAuthCredential;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try lockDir(io, data_dir);
    defer dir.close(io);
    const lock = try dir.createFile(io, "credentials.lock", .{ .truncate = false, .permissions = .fromMode(0o600), .lock = .exclusive });
    defer lock.close(io);
    try lock.setPermissions(io, .fromMode(0o600));
    var entries = try load(a, io, data_dir);
    try insertOAuth(a, &entries, provider_id, value);
    try save(a, io, &dir, entries);
}

/// Refreshes under the persistent cross-process lock, preventing simultaneous
/// refresh-token rotation. Callback receives borrowed old tokens and returns
/// borrowed replacement tokens (typically allocated from `arena`). Rechecks
/// expiration after acquiring the lock; only OAuth entries are accepted.
pub fn getFreshOAuth(allocator: Allocator, io: Io, data_dir: []const u8, provider_id: []const u8, context: anytype, comptime refreshFn: fn (@TypeOf(context), Allocator, Io, OAuthValue) anyerror!OAuthValue) !?OAuth {
    if (!validId(provider_id)) return error.InvalidProviderId;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try lockDir(io, data_dir);
    defer dir.close(io);
    const lock = try dir.createFile(io, "credentials.lock", .{ .truncate = false, .permissions = .fromMode(0o600), .lock = .exclusive });
    defer lock.close(io);
    try lock.setPermissions(io, .fromMode(0o600));
    var entries = try load(a, io, data_dir);
    const entry = entries.get(provider_id) orelse return null;
    if (!std.mem.eql(u8, entry.object.get("type").?.string, "oauth")) return null;
    var old = try oauthFromEntry(a, entry);
    defer old.deinit();
    if (old.expires > Io.Clock.real.now(io).toMilliseconds() +| 60_000) return try oauthFromEntry(allocator, entry);
    var next = try refreshFn(context, a, io, .{ .access = old.access, .refresh = old.refresh, .expires = old.expires, .account_id = old.account_id });
    if (next.account_id == null) next.account_id = old.account_id;
    if (!validOAuth(next)) return error.InvalidOAuthCredential;
    try insertOAuth(a, &entries, provider_id, next);
    try saveRefreshed(a, io, &dir, entries);
    return try oauthFromEntry(allocator, entries.get(provider_id).?);
}

test "round trip, listing excludes keys, replacement is atomic and private" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    const data = try std.fs.path.join(a, &.{ base, "data" });
    defer a.free(data);
    try std.testing.expect((try readKey(a, io, data, "openai")) == null);
    try putApiKey(a, io, data, "openai", "old-secret");
    const path = try std.fs.path.join(a, &.{ data, file_name });
    defer a.free(path);
    // An open reader continues to see the old inode after atomic replacement.
    const old = try Io.Dir.cwd().openFile(io, path, .{});
    defer old.close(io);
    try putApiKey(a, io, data, "anthropic", "other-secret");
    try putApiKey(a, io, data, "openai", "new-secret");
    const old_stat = try old.stat(io);
    const new_stat = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expect(old_stat.inode != new_stat.inode);
    var read_buf: [4096]u8 = undefined;
    var reader = old.readerStreaming(io, &read_buf);
    const old_bytes = try reader.interface.allocRemaining(a, .limited(max_file_size));
    defer a.free(old_bytes);
    try std.testing.expect(std.mem.indexOf(u8, old_bytes, "old-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, old_bytes, "new-secret") == null);
    const key = (try readKey(a, io, data, "openai")).?;
    defer a.free(key);
    try std.testing.expectEqualStrings("new-secret", key);
    var listing = try list(a, io, data);
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 2), listing.items.len);
    for (listing.items) |item| {
        try std.testing.expectEqualStrings("api", item.type);
        try std.testing.expect(std.mem.eql(u8, item.id, "openai") or std.mem.eql(u8, item.id, "anthropic"));
        try std.testing.expect(std.mem.indexOf(u8, item.id, "secret") == null);
    }
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try Io.Dir.cwd().statFile(io, data, .{})).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), new_stat.permissions.toMode() & 0o777);
    const lock_path = try std.fs.path.join(a, &.{ data, "credentials.lock" });
    defer a.free(lock_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try Io.Dir.cwd().statFile(io, lock_path, .{})).permissions.toMode() & 0o777);
}

test "invalid input and malformed on-disk credentials never overwrite" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = buf[0..try tmp.dir.realPath(io, &buf)];
    try std.testing.expectError(error.InvalidProviderId, putApiKey(a, io, data, "a/b", "key"));
    try std.testing.expectError(error.InvalidProviderId, putApiKey(a, io, data, "mcp:docs", "key"));
    try std.testing.expectError(error.InvalidApiKey, putApiKey(a, io, data, "a", "bad\nkey"));
    const path = try std.fs.path.join(a, &.{ data, file_name });
    defer a.free(path);
    const malformed = "{\"a\":{\"type\":\"oauth\",\"key\":\"secret\"}}";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = malformed });
    try std.testing.expectError(error.InvalidCredentials, list(a, io, data));
    try std.testing.expectError(error.InvalidCredentials, putApiKey(a, io, data, "b", "key"));
    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    defer a.free(after);
    try std.testing.expectEqualStrings(malformed, after);
}

test "writer waits on persistent lock before loading existing credentials" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = buf[0..try tmp.dir.realPath(io, &buf)];
    try putApiKey(a, io, data, "first", "one");
    var dir = try Io.Dir.cwd().openDir(io, data, .{});
    defer dir.close(io);
    const lock = try dir.createFile(io, "credentials.lock", .{ .truncate = false, .lock = .exclusive });
    var locked = true;
    defer if (locked) lock.close(io);
    var pending = try io.concurrent(putApiKey, .{ a, io, data, "second", "two" });
    defer _ = pending.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expect((try readKey(a, io, data, "second")) == null);
    lock.close(io);
    locked = false;
    try pending.await(io);
    const result = (try readKey(a, io, data, "second")).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("two", result);
}

test {
    _ = @import("credentials_test.zig");
}
