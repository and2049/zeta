//! Config (`zeta.jsonc`) shape:
//!
//!   {
//!     "model": "openai/gpt-4.1",
//!     "provider": {
//!       "openai": { "options": { "baseURL": "…", "apiKey": "{env:OPENAI_API_KEY}" } }
//!     }
//!   }
//!
//! Layers, low to high: defaults, global, project, global profile, project
//! profile, CLI, environment. Profiles are named JSONC files in `profiles/`.
//! Objects merge key by key; anything else is replaced by the higher layer.
//! String values support `{env:VAR}` and `{file:path}`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jsonc = @import("jsonc.zig");

pub const file_name = "zeta.jsonc";
const max_file = 1024 * 1024;

pub const ProviderOptions = struct {
    baseURL: ?[]const u8 = null,
    apiKey: ?[]const u8 = null,
    /// Send the session id as a prompt-cache key (OpenAI-compatible APIs).
    setCacheKey: ?bool = null,
};

pub const Provider = struct {
    options: ProviderOptions = .{},
    /// Raw model overrides, kept for the provider catalog to merge later.
    models: std.json.ArrayHashMap(std.json.Value) = .{},
};

/// `remembered` and `fallback` fill a model or thinking level no layer set
/// (see runtime_model.zig).
pub const Source = enum { defaults, user, project, user_profile, project_profile, cli, env, remembered, fallback };
pub const Environment = struct { profile: ?[]const u8 = null, model: ?[]const u8 = null };
pub const Options = struct {
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// A session's thinking level (a level name); above the model's and the
    /// config's default. Not a config layer.
    thinking: ?[]const u8 = null,
    /// Present even when both fields are null: the client environment replaces
    /// the server's old process environment for these selectors.
    environment: ?Environment = null,
};
/// `compaction`: when the history is summarized to fit the context window.
pub const Compaction = struct {
    enabled: bool = true,
    /// Tokens kept free for the reply; compaction starts above the context
    /// window minus this.
    reserveTokens: u64 = 16_384,
    /// Roughly how many recent tokens stay verbatim.
    keepRecentTokens: u64 = 20_000,
};

pub const PermissionRule = struct {
    action: []const u8,
    pattern: []const u8,
    effect: enum { allow, deny, ask },
};

pub const Config = struct {
    model: ?[]const u8 = null,
    small_model: ?[]const u8 = null,
    /// Default thinking level (a level name) for models that reason.
    thinking: ?[]const u8 = null,
    tool_timeout_ms: u64 = 120_000,
    inspect_tool: bool = false,
    permission: []const PermissionRule = &.{},
    provider: std.json.ArrayHashMap(Provider) = .{},
    /// `plugin.<id>`: each plugin's own config, checked against its schema
    /// when it declares one.
    plugin: std.json.ArrayHashMap(std.json.Value) = .{},
    /// `mcp`: MCP servers, read by the MCP client plugin (raw JSON).
    mcp: std.json.Value = .null,
    /// `extensions`: extension commands to run per project (raw JSON).
    extensions: std.json.Value = .null,
    compaction: Compaction = .{},
    /// Dot-separated config keys map to their winning layer; arena-owned.
    /// Only recognized top-level keys appear.
    provenance: std.StringHashMapUnmanaged(Source) = .empty,
    /// Top-level keys zeta doesn't recognize; kept in files but ignored.
    unknown: []const []const u8 = &.{},

    pub fn source(c: *const Config, key: []const u8) ?Source {
        return c.provenance.get(key);
    }

    pub fn pluginOptions(c: Config, id: []const u8) ?std.json.Value {
        return c.plugin.map.get(id);
    }

    pub fn providerOptions(c: Config, id: []const u8) ProviderOptions {
        const p = c.provider.map.get(id) orelse return .{};
        return p.options;
    }
};

const ParsedConfig = struct {
    model: ?[]const u8 = null,
    small_model: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    tool_timeout_ms: u64 = 120_000,
    inspect_tool: bool = false,
    permission: []const PermissionRule = &.{},
    provider: std.json.ArrayHashMap(Provider) = .{},
    plugin: std.json.ArrayHashMap(std.json.Value) = .{},
    mcp: std.json.Value = .null,
    extensions: std.json.Value = .null,
    compaction: Compaction = .{},
};

pub const known_keys = [_][]const u8{ "model", "small_model", "thinking", "tool_timeout_ms", "inspect_tool", "permission", "provider", "plugin", "mcp", "extensions", "compaction" };

pub fn isKnown(key: []const u8) bool {
    for (known_keys) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

/// Loads and merges the layers. Everything is allocated in `arena`.
pub fn load(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    config_dir: []const u8,
    location: []const u8,
) !Config {
    return loadWithOptions(arena, io, env, config_dir, location, .{});
}

/// Returned config and provenance keys, including raw provider model JSON,
/// borrow `arena`; caller must keep it alive while using the config.
pub fn loadWithOptions(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    config_dir: []const u8,
    location: []const u8,
    options: Options,
) !Config {
    var merged: std.json.Value = .{ .object = .empty };
    var provenance: std.StringHashMapUnmanaged(Source) = .empty;
    try provenance.put(arena, "tool_timeout_ms", .defaults);
    try provenance.put(arena, "inspect_tool", .defaults);
    try provenance.put(arena, "permission", .defaults);
    const layers = [_]struct { path: []const u8, source: Source }{
        .{ .path = try std.fs.path.join(arena, &.{ config_dir, file_name }), .source = .user },
        .{ .path = try std.fs.path.join(arena, &.{ location, ".zeta", file_name }), .source = .project },
    };
    for (layers) |layer| {
        _ = try applyFile(arena, io, env, layer.path, layer.source, &merged, &provenance);
    }
    const profile = (if (options.environment) |current| current.profile else env.get("ZETA_PROFILE")) orelse options.profile;
    if (profile) |name| {
        if (!validProfileName(name)) return error.InvalidProfile;
        const filename = try std.fmt.allocPrint(arena, "{s}.jsonc", .{name});
        const profiles = [_]struct { path: []const u8, source: Source }{
            .{ .path = try std.fs.path.join(arena, &.{ config_dir, "profiles", filename }), .source = .user_profile },
            .{ .path = try std.fs.path.join(arena, &.{ location, ".zeta", "profiles", filename }), .source = .project_profile },
        };
        var found = false;
        for (profiles) |layer| {
            if (try applyFile(arena, io, env, layer.path, layer.source, &merged, &provenance)) found = true;
        }
        if (!found) return error.ProfileNotFound;
    }
    if (options.model) |model| try setModel(arena, &merged, &provenance, model, .cli);
    if (if (options.environment) |current| current.model else env.get("ZETA_MODEL")) |model| try setModel(arena, &merged, &provenance, model, .env);
    const parsed = std.json.parseFromValueLeaky(ParsedConfig, arena, merged, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    if (parsed.tool_timeout_ms == 0) return error.InvalidConfig;
    if (parsed.thinking) |level| if (@import("proto").thinking.Level.parse(level) == null) return error.InvalidConfig;
    var unknown: std.ArrayList([]const u8) = .empty;
    for (merged.object.keys()) |key| if (!isKnown(key)) try unknown.append(arena, key);
    var stale: std.ArrayList([]const u8) = .empty;
    var sources = provenance.keyIterator();
    while (sources.next()) |key| {
        const top = key.*[0 .. std.mem.indexOfScalar(u8, key.*, '.') orelse key.len];
        if (!isKnown(top)) try stale.append(arena, key.*);
    }
    for (stale.items) |key| _ = provenance.remove(key);
    return .{ .model = parsed.model, .small_model = parsed.small_model, .thinking = parsed.thinking, .tool_timeout_ms = parsed.tool_timeout_ms, .inspect_tool = parsed.inspect_tool, .permission = parsed.permission, .provider = parsed.provider, .plugin = parsed.plugin, .mcp = parsed.mcp, .extensions = parsed.extensions, .compaction = parsed.compaction, .provenance = provenance, .unknown = unknown.items };
}

fn validProfileName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

fn applyFile(arena: Allocator, io: Io, env: *const std.process.Environ.Map, path: []const u8, source: Source, merged: *std.json.Value, provenance: *std.StringHashMapUnmanaged(Source)) !bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    const json = try jsonc.strip(arena, bytes);
    var layer = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidConfig;
    if (layer != .object) return error.InvalidConfig;
    try substitute(arena, io, env, &layer, std.fs.path.dirname(path) orelse ".");
    try mergeWithSources(arena, merged, layer, "", source, provenance);
    return true;
}

fn setModel(arena: Allocator, merged: *std.json.Value, provenance: *std.StringHashMapUnmanaged(Source), model: []const u8, source: Source) !void {
    const slot = try merged.object.getOrPut(arena, "model");
    slot.value_ptr.* = .{ .string = model };
    try provenance.put(arena, "model", source);
}

fn mergeWithSources(arena: Allocator, dst: *std.json.Value, src: std.json.Value, key: []const u8, source: Source, provenance: *std.StringHashMapUnmanaged(Source)) !void {
    if (dst.* == .object and src == .object) {
        var it = src.object.iterator();
        while (it.next()) |e| {
            const child = if (key.len == 0) e.key_ptr.* else try std.fmt.allocPrint(arena, "{s}.{s}", .{ key, e.key_ptr.* });
            const slot = try dst.object.getOrPut(arena, e.key_ptr.*);
            if (!slot.found_existing) slot.value_ptr.* = .null;
            try mergeWithSources(arena, slot.value_ptr, e.value_ptr.*, child, source, provenance);
        }
    } else {
        // A replacement removes provenance for every leaf it displaced.
        var stale: std.ArrayList([]const u8) = .empty;
        var it = provenance.iterator();
        while (it.next()) |entry| {
            const old = entry.key_ptr.*;
            if (old.len > key.len and std.mem.startsWith(u8, old, key) and old[key.len] == '.') {
                try stale.append(arena, old);
            }
        }
        for (stale.items) |old| _ = provenance.remove(old);
        dst.* = src;
        if (key.len > 0) try markSource(arena, src, key, source, provenance);
    }
}

fn markSource(arena: Allocator, value: std.json.Value, key: []const u8, source: Source, provenance: *std.StringHashMapUnmanaged(Source)) !void {
    try provenance.put(arena, key, source);
    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |e| {
            const child = try std.fmt.allocPrint(arena, "{s}.{s}", .{ key, e.key_ptr.* });
            try markSource(arena, e.value_ptr.*, child, source, provenance);
        }
    }
}

/// Replaces `{env:VAR}` and `{file:path}` inside string values. Relative
/// file paths resolve against the config file's directory.
fn substitute(arena: Allocator, io: Io, env: *const std.process.Environ.Map, v: *std.json.Value, base_dir: []const u8) !void {
    switch (v.*) {
        .string => |s| v.* = .{ .string = try expand(arena, io, env, s, base_dir) },
        .array => |a| for (a.items) |*item| try substitute(arena, io, env, item, base_dir),
        .object => |o| for (o.values()) |*item| try substitute(arena, io, env, item, base_dir),
        else => {},
    }
}

pub fn expand(arena: Allocator, io: Io, env: *const std.process.Environ.Map, s: []const u8, base_dir: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "{env:") == null and std.mem.indexOf(u8, s, "{file:") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const rest = s[i..];
        const is_env = std.mem.startsWith(u8, rest, "{env:");
        const is_file = std.mem.startsWith(u8, rest, "{file:");
        const close = std.mem.indexOfScalar(u8, rest, '}');
        if ((is_env or is_file) and close != null) {
            const arg = rest[(if (is_env) "{env:".len else "{file:".len)..close.?];
            if (is_env) {
                try out.appendSlice(arena, env.get(arg) orelse "");
            } else {
                const path = if (std.fs.path.isAbsolute(arg)) arg else try std.fs.path.join(arena, &.{ base_dir, arg });
                const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file));
                try out.appendSlice(arena, std.mem.trimEnd(u8, bytes, "\r\n"));
            }
            i += close.? + 1;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Splits `provider/model`. The model part may itself contain slashes.
pub fn splitModel(ref: []const u8) ?struct { provider: []const u8, model: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, ref, '/') orelse return null;
    if (slash == 0 or slash + 1 == ref.len) return null;
    return .{ .provider = ref[0..slash], .model = ref[slash + 1 ..] };
}

test {
    _ = @import("config_test.zig");
}
