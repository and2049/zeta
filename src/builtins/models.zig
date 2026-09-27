//! models.dev catalog. Cache is the boot-time floor; a best-effort refresh runs
//! on a worker. Catalog owns its URL/cache path and bytes; snapshots own copies.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("models_cache.zig");

pub const default_url = "https://models.dev/api.json";
pub const max_catalog_bytes = 32 * 1024 * 1024;

pub const Options = struct {
    /// Pass the XDG cache directory (`Paths.cache`), not the cache filename.
    cache_dir: []const u8,
    /// Provider ids whose metadata is kept; the rest of the catalog is
    /// dropped. Must outlive the catalog.
    keep: []const []const u8,
    url: []const u8 = default_url,
    /// Disable refresh for offline/fixture tests.
    refresh: bool = true,
};

pub const Cost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    context: u64 = 0,
    input_limit: u64 = 0,
    output_limit: u64 = 0,
    cost: Cost = .{},
    attachment: bool = false,
    reasoning: bool = false,
    tool_call: bool = false,
    temperature: bool = false,
    modalities_input: []const []const u8 = &.{},
    modalities_output: []const []const u8 = &.{},
    /// Config only: thinking levels the model takes (all when empty) and
    /// its default level.
    thinking_levels: []const []const u8 = &.{},
    thinking: ?[]const u8 = null,
};
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    baseURL: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    models: []const Model = &.{},
};

/// Owns every referenced string/list; call deinit when finished. A snapshot
/// never borrows catalog bytes and remains valid across background refreshes.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    providers: []const Provider,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn provider(self: *const Snapshot, id: []const u8) ?*const Provider {
        for (self.providers) |*p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }
};

pub const Catalog = struct {
    allocator: Allocator,
    io: Io,
    cache_path: []const u8,
    etag_path: []const u8,
    url: []const u8,
    keep: []const []const u8,
    mutex: Io.Mutex = .init,
    bytes: ?[]u8 = null,
    worker: Io.Group = .init,

    /// Stable heap pointer is required while the worker is running. The
    /// caller's Io must remain alive through deinit. Cache failure is benign.
    pub fn init(allocator: Allocator, io: Io, options: Options) !*Catalog {
        const self = try allocator.create(Catalog);
        errdefer allocator.destroy(self);
        const path = try std.fs.path.join(allocator, &.{ options.cache_dir, "models.json" });
        errdefer allocator.free(path);
        const etag_path = try std.fmt.allocPrint(allocator, "{s}.etag", .{path});
        errdefer allocator.free(etag_path);
        const url = try allocator.dupe(u8, options.url);
        errdefer allocator.free(url);
        self.* = .{ .allocator = allocator, .io = io, .cache_path = path, .etag_path = etag_path, .url = url, .keep = options.keep };
        const cached = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_catalog_bytes)) catch null;
        if (cached) |body| {
            defer allocator.free(body);
            if (cache.compact(allocator, body, options.keep)) |slim| {
                self.bytes = slim;
                if (!std.mem.eql(u8, body, slim)) persist(self, slim) catch {};
            } else |_| {}
        }
        if (options.refresh) self.worker.concurrent(io, refreshWorker, .{self}) catch |err| {
            if (self.bytes) |body| allocator.free(body);
            return err;
        };
        return self;
    }

    /// Whether the catalog keeps metadata for provider `id`.
    pub fn keeps(self: *const Catalog, id: []const u8) bool {
        return cache.kept(self.keep, id);
    }

    /// Cancels the in-flight request and waits for its resources to be released.
    pub fn deinit(self: *Catalog) void {
        self.worker.cancel(self.io);
        if (self.bytes) |body| self.allocator.free(body);
        self.allocator.free(self.cache_path);
        self.allocator.free(self.etag_path);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }

    /// `overrides` maps provider ID to a JSON *models object* (model ID ->
    /// model fields). Build it from Config.provider entries' `.models.map`;
    /// passing one Provider.models directly is NOT the expected shape. With
    /// overrides and no cache, an empty catalog is used so custom providers
    /// remain available. Pass null for an unmodified snapshot (null if offline
    /// with no cache). Caller retains ownership of overrides and its strings.
    pub fn snapshot(self: *Catalog, allocator: Allocator, overrides: ?*const std.json.ArrayHashMap(std.json.Value)) !?Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const body = self.bytes orelse if (overrides != null) "{}" else return null;
        return try parseSnapshot(allocator, body, overrides, self.keep);
    }

    fn refreshWorker(self: *Catalog) Io.Cancelable!void {
        self.refreshNow() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try Io.checkCancel(self.io);
            std.log.warn("model catalog refresh failed: {s}; retaining cached models", .{@errorName(err)});
        };
    }

    /// Useful for a controlled synchronous refresh (including local HTTP
    /// fixtures); don't call concurrently with the initial worker.
    pub fn refreshNow(self: *Catalog) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var client: std.http.Client = .{ .allocator = arena, .io = self.io };
        defer client.deinit();
        const uri = try std.Uri.parse(self.url);
        const validator = readValidator(self, arena) catch null;
        const headers: []const std.http.Header = if (validator) |tag| &.{.{ .name = "if-none-match", .value = tag }} else &.{};
        var req = try client.request(.GET, uri, .{ .keep_alive = false, .extra_headers = headers });
        defer {
            if (req.connection) |connection| connection.closing = true;
            req.deinit();
        }
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status == .not_modified and validator != null) return;
        if (response.head.status.class() != .success) return error.CatalogHttpError;
        // Head bytes are invalidated once the body reader starts.
        const etag = if (responseEtag(response.head.bytes)) |tag| try arena.dupe(u8, tag) else null;
        var transfer: [64 * 1024]u8 = undefined;
        // std.http advertises gzip/deflate by default. Cache decoded JSON and
        // enforce the catalog limit on decoded bytes, not compressed size.
        var decompress: std.http.Decompress = undefined;
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        const body = response.readerDecompressing(&transfer, &decompress, &window).allocRemaining(arena, .limited(max_catalog_bytes)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        };
        const owned = try cache.compact(self.allocator, body, self.keep);
        errdefer self.allocator.free(owned);
        // Cache failure is non-fatal, but cancellation must escape rather than
        // accidentally publishing a response after group.cancel().
        var persisted = true;
        persist(self, owned) catch |err| {
            if (err == error.Canceled) return err;
            persisted = false;
        };
        if (persisted) {
            if (etag) |tag| {
                writeValidator(self, owned, tag) catch |err| {
                    if (err == error.Canceled) return err;
                    // A failed validator update must not validate a newly
                    // written cache against a prior ETag.
                    Io.Dir.cwd().deleteFile(self.io, self.etag_path) catch {};
                };
            } else {
                Io.Dir.cwd().deleteFile(self.io, self.etag_path) catch {};
            }
        }
        try Io.checkCancel(self.io);
        self.mutex.lockUncancelable(self.io);
        const old = self.bytes;
        self.bytes = owned;
        self.mutex.unlock(self.io);
        if (old) |previous| self.allocator.free(previous);
    }
};

const Validator = struct { url: []const u8, hash: u64, etag: []const u8 };

fn readValidator(self: *Catalog, arena: Allocator) !?[]const u8 {
    const body = self.bytes orelse return null;
    const bytes = try Io.Dir.cwd().readFileAlloc(self.io, self.etag_path, arena, .limited(2048));
    const parsed = try std.json.parseFromSliceLeaky(Validator, arena, bytes, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, parsed.url, self.url) or parsed.hash != std.hash.Wyhash.hash(0, body)) return null;
    if (!safeEtag(parsed.etag)) return null;
    return parsed.etag;
}

fn safeEtag(tag: []const u8) bool {
    if (tag.len < 2 or tag.len > 256) return false;
    for (tag) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn responseEtag(head: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "etag")) continue;
        const tag = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return if (safeEtag(tag)) tag else null;
    }
    return null;
}

fn writeValidator(self: *Catalog, body: []const u8, tag: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(self.allocator, Validator{
        .url = self.url,
        .hash = std.hash.Wyhash.hash(0, body),
        .etag = tag,
    }, .{});
    defer self.allocator.free(encoded);
    var atomic = try Io.Dir.cwd().createFileAtomic(self.io, self.etag_path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, encoded);
    try atomic.file.sync(self.io);
    try Io.checkCancel(self.io);
    try atomic.replace(self.io);
}

fn persist(self: *Catalog, body: []const u8) !void {
    // Atomic replacement ensures a failed/canceled write leaves the old cache.
    var atomic = try Io.Dir.cwd().createFileAtomic(self.io, self.cache_path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, body);
    try atomic.file.sync(self.io);
    try Io.checkCancel(self.io);
    try atomic.replace(self.io);
}

fn field(v: std.json.Value, name: []const u8) std.json.Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}
fn text(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}
fn number(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => 0,
    };
}
fn unsigned(v: std.json.Value) u64 {
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}
fn flag(v: std.json.Value) bool {
    return v == .bool and v.bool;
}
fn stringList(arena: Allocator, v: std.json.Value) ![]const []const u8 {
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| if (text(item)) |s| try out.append(arena, try arena.dupe(u8, s));
    return out.items;
}

fn parseSnapshot(allocator: Allocator, bytes: []const u8, overrides: ?*const std.json.ArrayHashMap(std.json.Value), keep: []const []const u8) !Snapshot {
    var state: std.heap.ArenaAllocator = .init(allocator);
    errdefer state.deinit();
    const arena = state.allocator();
    // alloc_always ensures no snapshot string aliases the catalog's bytes.
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always }));
    if (root != .object) return error.InvalidCatalog;
    var providers: std.ArrayList(Provider) = .empty;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr.*;
        if (p != .object) continue;
        const id = text(field(p, "id")) orelse entry.key_ptr.*;
        if (!cache.kept(keep, entry.key_ptr.*) or !std.mem.eql(u8, id, entry.key_ptr.*)) continue;
        var models: std.ArrayList(Model) = .empty;
        const raw_models = field(p, "models");
        const configured = if (overrides) |map| map.map.get(id) else null;
        if (raw_models == .object) {
            var mit = raw_models.object.iterator();
            while (mit.next()) |m_entry| {
                const raw = m_entry.value_ptr.*;
                if (raw != .object) continue;
                const override = if (configured) |cfg| field(cfg, m_entry.key_ptr.*) else .null;
                try models.append(arena, try modelFrom(arena, m_entry.key_ptr.*, raw, override));
            }
        }
        // Config may introduce models absent from the upstream catalog.
        if (configured) |cfg| if (cfg == .object) {
            var cit = cfg.object.iterator();
            while (cit.next()) |c| {
                if (raw_models == .object and raw_models.object.contains(c.key_ptr.*)) continue;
                if (c.value_ptr.* == .object) try models.append(arena, try modelFrom(arena, c.key_ptr.*, .null, c.value_ptr.*));
            }
        };
        try providers.append(arena, .{
            .id = id,
            .name = text(field(p, "name")) orelse id,
            .baseURL = text(field(p, "api")),
            .env = try stringList(arena, field(p, "env")),
            .models = models.items,
        });
    }
    if (overrides) |map| {
        var oit = map.map.iterator();
        while (oit.next()) |entry| {
            if (root.object.contains(entry.key_ptr.*)) continue;
            const cfg = entry.value_ptr.*;
            if (cfg != .object) continue;
            var models: std.ArrayList(Model) = .empty;
            var mit = cfg.object.iterator();
            while (mit.next()) |m| {
                if (m.value_ptr.* == .object) try models.append(arena, try modelFrom(arena, m.key_ptr.*, .null, m.value_ptr.*));
            }
            const id = try arena.dupe(u8, entry.key_ptr.*);
            try providers.append(arena, .{ .id = id, .name = id, .models = models.items });
        }
    }
    return .{ .arena = state, .providers = providers.items };
}

fn choose(raw: std.json.Value, override: std.json.Value, key: []const u8) std.json.Value {
    const changed = field(override, key);
    return if (changed != .null) changed else field(raw, key);
}
fn modelFrom(arena: Allocator, key: []const u8, raw: std.json.Value, override: std.json.Value) !Model {
    const limit = field(raw, "limit");
    const limit_override = field(override, "limit");
    const price = field(raw, "cost");
    const price_override = field(override, "cost");
    const modalities = choose(raw, override, "modalities");
    return .{
        .id = try arena.dupe(u8, text(choose(raw, override, "id")) orelse key),
        .name = try arena.dupe(u8, text(choose(raw, override, "name")) orelse key),
        .context = unsigned(choose(limit, limit_override, "context")),
        .input_limit = unsigned(choose(limit, limit_override, "input")),
        .output_limit = unsigned(choose(limit, limit_override, "output")),
        .cost = .{
            .input = number(choose(price, price_override, "input")),
            .output = number(choose(price, price_override, "output")),
            .cache_read = number(choose(price, price_override, "cache_read")),
            .cache_write = number(choose(price, price_override, "cache_write")),
        },
        .attachment = flag(choose(raw, override, "attachment")),
        .reasoning = flag(choose(raw, override, "reasoning")),
        .tool_call = flag(choose(raw, override, "tool_call")),
        .temperature = flag(choose(raw, override, "temperature")),
        .modalities_input = try stringList(arena, field(modalities, "input")),
        .modalities_output = try stringList(arena, field(modalities, "output")),
        .thinking_levels = try stringList(arena, field(override, "thinkingLevels")),
        .thinking = if (text(field(override, "thinking"))) |t| try arena.dupe(u8, t) else null,
    };
}

test {
    _ = @import("models_test.zig");
}
