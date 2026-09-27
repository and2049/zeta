//! Edits one config layer, never the merged effective configuration.
//! The caller must serialize read/modify/write operations with a mutex (and
//! coordinate other writers); atomic replacement alone prevents torn reads,
//! not lost concurrent updates. All returned view data borrows `arena`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const jsonc = @import("jsonc.zig");
const plugin = @import("plugin");
const plugin_config = @import("plugin_config.zig");
const Value = std.json.Value;
const max_file = 1024 * 1024;

pub const Target = enum { user, project };

/// `location` is the already-resolved project base directory, not a query
/// string. The server is responsible for authorization and path resolution.
pub fn pathFor(arena: Allocator, target: Target, config_dir: []const u8, location: []const u8) ![]const u8 {
    return switch (target) {
        .user => std.fs.path.join(arena, &.{ config_dir, config.file_name }),
        .project => std.fs.path.join(arena, &.{ location, ".zeta", config.file_name }),
    };
}

/// Patch object members recursively; arrays replace and null removes the
/// member from this layer, exposing lower-layer values on the next load.
/// Existing JSONC comments are intentionally lost on successful rewrite.
pub fn patchFile(arena: Allocator, io: Io, path: []const u8, patch: Value) !void {
    return patchFileFor(arena, io, path, patch, &.{});
}

/// Like `patchFile`, and checks the patched `plugin.<id>` entries against
/// the schemas those plugins declare.
pub fn patchFileFor(arena: Allocator, io: Io, path: []const u8, patch: Value, plugins: []const plugin.Registry.Plugin) !void {
    if (patch != .object) return error.InvalidPatch;
    try validateIncoming(patch);
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    var root: Value = .{ .object = .empty };
    if (bytes) |raw| {
        const plain = jsonc.strip(arena, raw) catch return error.InvalidConfig;
        root = std.json.parseFromSliceLeaky(Value, arena, plain, .{}) catch return error.InvalidConfig;
        if (root != .object) return error.InvalidConfig;
    }
    try merge(arena, &root, patch);
    try validate(root);
    if (patch.object.get("plugin")) |changed| if (changed == .object) {
        const current = root.object.get("plugin") orelse Value{ .object = .empty };
        for (changed.object.keys()) |id| {
            const owner = plugin_config.find(plugins, id) orelse continue;
            const value = current.object.get(id) orelse continue;
            if (try plugin_config.issue(arena, owner, value) != null) return error.InvalidPluginConfig;
        }
    };
    const rendered = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    if (rendered.len > max_file) return error.ConfigTooLarge;
    const parent = std.fs.path.dirname(path) orelse ".";
    _ = try cwd.createDirPathStatus(io, parent, .default_dir);
    var dir = try cwd.openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, std.fs.path.basename(path), .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, rendered);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn merge(arena: Allocator, dst: *Value, src: Value) !void {
    if (src != .object) {
        dst.* = src;
        return;
    }
    if (dst.* != .object) dst.* = .{ .object = .empty };
    var it = src.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value == .null) {
            _ = dst.object.swapRemove(key);
        } else {
            const slot = try dst.object.getOrPut(arena, key);
            if (!slot.found_existing) slot.value_ptr.* = .null;
            try merge(arena, slot.value_ptr, value);
        }
    }
}

/// Validate only fields supplied by the patch. Existing unrelated fields are
/// deliberately not rejected: they must round-trip through this editor.
fn validateIncoming(patch: Value) !void {
    var entries = patch.object.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "small_model") or std.mem.eql(u8, key, "tool_timeout_ms") or std.mem.eql(u8, key, "thinking")) continue;
        if (std.mem.eql(u8, key, "plugin")) {
            if (value != .null and value != .object) return error.InvalidConfig;
            continue;
        }
        if (std.mem.eql(u8, key, "compaction")) {
            if (value != .null and value != .object) return error.InvalidConfig;
            continue;
        }
        if (std.mem.eql(u8, key, "permission")) {
            if (value == .null) continue;
            if (value != .array) return error.InvalidConfig;
            for (value.array.items) |rule| {
                if (rule != .object) return error.InvalidConfig;
                var fields = rule.object.iterator();
                while (fields.next()) |field| {
                    const name = field.key_ptr.*;
                    if (!std.mem.eql(u8, name, "action") and !std.mem.eql(u8, name, "pattern") and !std.mem.eql(u8, name, "effect")) return error.InvalidPatch;
                }
            }
            continue;
        }
        if (!std.mem.eql(u8, key, "provider")) return error.InvalidPatch;
        if (value == .null) continue;
        if (value != .object) return error.InvalidConfig;
        var providers = value.object.iterator();
        while (providers.next()) |provider| {
            if (provider.value_ptr.* == .null) continue;
            if (provider.value_ptr.* != .object) return error.InvalidConfig;
            var fields = provider.value_ptr.object.iterator();
            while (fields.next()) |field| {
                const name = field.key_ptr.*;
                if (std.mem.eql(u8, name, "models")) continue; // Raw model overrides are open-ended.
                if (!std.mem.eql(u8, name, "options")) return error.InvalidPatch;
                if (field.value_ptr.* == .null) continue;
                if (field.value_ptr.* != .object) return error.InvalidConfig;
                var options = field.value_ptr.object.iterator();
                while (options.next()) |option| {
                    const option_name = option.key_ptr.*;
                    if (!std.mem.eql(u8, option_name, "baseURL") and !std.mem.eql(u8, option_name, "apiKey") and !std.mem.eql(u8, option_name, "setCacheKey")) return error.InvalidPatch;
                }
            }
        }
    }
}

fn deferredModel(ref: []const u8) bool {
    const prefix: []const u8 = if (std.mem.startsWith(u8, ref, "{env:")) "{env:" else if (std.mem.startsWith(u8, ref, "{file:")) "{file:" else return false;
    return ref.len > prefix.len + 1 and ref[ref.len - 1] == '}' and std.mem.indexOfScalar(u8, ref[prefix.len .. ref.len - 1], '}') == null;
}

fn validate(root: Value) !void {
    if (root != .object) return error.InvalidPatch;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, k, "model") or std.mem.eql(u8, k, "small_model")) {
            // Full substitutions cannot be resolved without the request's
            // environment/file base; loadWithOptions validates the expansion.
            if (v != .string or (config.splitModel(v.string) == null and !deferredModel(v.string))) return error.InvalidConfig;
        } else if (std.mem.eql(u8, k, "thinking")) {
            // A substitution is checked once it is expanded, at load.
            if (v != .string or (@import("proto").thinking.Level.parse(v.string) == null and !deferredModel(v.string))) return error.InvalidConfig;
        } else if (std.mem.eql(u8, k, "tool_timeout_ms")) {
            if (v != .integer or v.integer <= 0) return error.InvalidConfig;
        } else if (std.mem.eql(u8, k, "permission")) {
            if (v != .array) return error.InvalidConfig;
            for (v.array.items) |rule| {
                if (rule != .object) return error.InvalidConfig;
                const action = rule.object.get("action") orelse return error.InvalidConfig;
                const pattern = rule.object.get("pattern") orelse return error.InvalidConfig;
                const effect = rule.object.get("effect") orelse return error.InvalidConfig;
                if (action != .string or action.string.len == 0 or pattern != .string or pattern.string.len == 0 or effect != .string) return error.InvalidConfig;
                if (!std.mem.eql(u8, effect.string, "allow") and !std.mem.eql(u8, effect.string, "deny") and !std.mem.eql(u8, effect.string, "ask")) return error.InvalidConfig;
            }
        } else if (std.mem.eql(u8, k, "plugin")) {
            if (v != .object) return error.InvalidConfig;
            for (v.object.keys()) |id| if (id.len == 0) return error.InvalidConfig;
        } else if (std.mem.eql(u8, k, "compaction")) {
            _ = std.json.parseFromValueLeaky(config.Compaction, std.heap.page_allocator, v, .{}) catch return error.InvalidConfig;
        } else if (std.mem.eql(u8, k, "provider")) {
            if (v != .object) return error.InvalidConfig;
            var providers = v.object.iterator();
            while (providers.next()) |p| {
                if (p.key_ptr.len == 0 or p.value_ptr.* != .object) return error.InvalidConfig;
                const options = p.value_ptr.object.get("options");
                if (options) |o| {
                    if (o != .object) return error.InvalidConfig;
                    var fields = o.object.iterator();
                    while (fields.next()) |field| {
                        if ((std.mem.eql(u8, field.key_ptr.*, "baseURL") or std.mem.eql(u8, field.key_ptr.*, "apiKey")) and field.value_ptr.* != .string) return error.InvalidConfig;
                        if (std.mem.eql(u8, field.key_ptr.*, "setCacheKey") and field.value_ptr.* != .bool and field.value_ptr.* != .null) return error.InvalidConfig;
                    }
                }
                if (p.value_ptr.object.get("models")) |models| {
                    if (models != .object) return error.InvalidConfig;
                    for (models.object.values()) |model| if (model != .object) return error.InvalidConfig;
                }
            }
        }
        // Unknown keys belong to other compatible config consumers and must
        // survive rewrites. They are not interpreted by this core module.
    }
}

/// Effective, JSON-serializable config and provenance; credentials and any
/// secret-like model-override fields are replaced with `[REDACTED]`.
pub fn view(arena: Allocator, c: config.Config) !Value {
    var values: std.json.ObjectMap = .empty;
    if (c.model) |m| try values.put(arena, "model", .{ .string = m });
    if (c.small_model) |m| try values.put(arena, "small_model", .{ .string = m });
    if (c.thinking) |t| try values.put(arena, "thinking", .{ .string = t });
    try values.put(arena, "tool_timeout_ms", if (c.tool_timeout_ms <= std.math.maxInt(i64)) .{ .integer = @intCast(c.tool_timeout_ms) } else .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{c.tool_timeout_ms}) });
    const permissions = try std.json.Stringify.valueAlloc(arena, c.permission, .{});
    try values.put(arena, "permission", std.json.parseFromSliceLeaky(Value, arena, permissions, .{}) catch unreachable);
    var providers: std.json.ObjectMap = .empty;
    var it = c.provider.map.iterator();
    while (it.next()) |p| {
        var item: std.json.ObjectMap = .empty;
        var options: std.json.ObjectMap = .empty;
        if (p.value_ptr.options.baseURL) |url| try options.put(arena, "baseURL", .{ .string = if (std.mem.indexOfScalar(u8, url, '@') != null or std.mem.indexOfScalar(u8, url, '?') != null or std.mem.indexOfScalar(u8, url, '#') != null) "[REDACTED]" else url });
        if (p.value_ptr.options.apiKey != null) try options.put(arena, "apiKey", .{ .string = "[REDACTED]" });
        if (p.value_ptr.options.setCacheKey) |on| try options.put(arena, "setCacheKey", .{ .bool = on });
        try item.put(arena, "options", .{ .object = options });
        var models: std.json.ObjectMap = .empty;
        var mi = p.value_ptr.models.map.iterator();
        while (mi.next()) |m| try models.put(arena, m.key_ptr.*, try redact(arena, m.value_ptr.*, ""));
        try item.put(arena, "models", .{ .object = models });
        try providers.put(arena, p.key_ptr.*, .{ .object = item });
    }
    try values.put(arena, "provider", .{ .object = providers });
    var plugins: std.json.ObjectMap = .empty;
    var plugin_it = c.plugin.map.iterator();
    while (plugin_it.next()) |p| try plugins.put(arena, p.key_ptr.*, try redact(arena, p.value_ptr.*, ""));
    try values.put(arena, "plugin", .{ .object = plugins });
    try values.put(arena, "compaction", try std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, c.compaction, .{}), .{}));
    var sources: std.json.ObjectMap = .empty;
    var pi = c.provenance.iterator();
    while (pi.next()) |entry| try sources.put(arena, entry.key_ptr.*, .{ .string = @tagName(entry.value_ptr.*) });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "config", .{ .object = values });
    try result.put(arena, "provenance", .{ .object = sources });
    return .{ .object = result };
}

fn redact(arena: Allocator, v: Value, key: []const u8) anyerror!Value {
    const lower = try std.ascii.allocLowerString(arena, key);
    if (std.mem.indexOf(u8, lower, "key") != null or std.mem.indexOf(u8, lower, "secret") != null or std.mem.indexOf(u8, lower, "token") != null or std.mem.indexOf(u8, lower, "password") != null or std.mem.indexOf(u8, lower, "credential") != null or std.mem.indexOf(u8, lower, "authorization") != null) return .{ .string = "[REDACTED]" };
    if (v == .object) {
        var object: std.json.ObjectMap = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| try object.put(arena, e.key_ptr.*, try redact(arena, e.value_ptr.*, e.key_ptr.*));
        return .{ .object = object };
    }
    if (v == .array) {
        var array: std.array_list.Managed(Value) = .init(arena);
        for (v.array.items) |item| try array.append(try redact(arena, item, ""));
        return .{ .array = array };
    }
    return v;
}

test {
    _ = @import("config_edit_test.zig");
}
