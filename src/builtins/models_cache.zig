//! Lossy models.dev projection: only the kept providers and the fields
//! models.zig's snapshot parser uses survive on disk. Returned bytes are owned.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn kept(keep: []const []const u8, id: []const u8) bool {
    for (keep) |k| if (std.mem.eql(u8, k, id)) return true;
    return false;
}

fn copyFields(a: Allocator, dst: *std.json.ObjectMap, src: std.json.Value, keys: []const []const u8) !void {
    if (src != .object) return;
    for (keys) |key| if (src.object.get(key)) |value| try dst.put(a, key, value);
}

fn object(a: Allocator, src: std.json.Value, keys: []const []const u8) !std.json.Value {
    var dst: std.json.ObjectMap = .{};
    try copyFields(a, &dst, src, keys);
    return .{ .object = dst };
}

/// Validates the top-level shape and projects untrusted JSON. An arena scoped
/// to this call owns all intermediate values; caller owns only returned bytes.
pub fn compact(allocator: Allocator, bytes: []const u8, keep: []const []const u8) ![]u8 {
    var state: std.heap.ArenaAllocator = .init(allocator);
    defer state.deinit();
    const a = state.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidCatalog;
    var out: std.json.ObjectMap = .{};
    var providers = root.object.iterator();
    while (providers.next()) |entry| {
        if (!kept(keep, entry.key_ptr.*)) continue;
        const raw = entry.value_ptr.*;
        if (raw != .object) continue;
        var provider = try object(a, raw, &.{ "id", "name", "api", "env" });
        // A contradictory embedded ID must never turn official metadata into
        // an unsupported provider on a later snapshot.
        if (provider.object.get("id")) |id| {
            if (id != .string or !std.mem.eql(u8, id.string, entry.key_ptr.*)) continue;
        }
        var models: std.json.ObjectMap = .{};
        const raw_models = raw.object.get("models") orelse .null;
        if (raw_models == .object) {
            var it = raw_models.object.iterator();
            while (it.next()) |model| {
                if (model.value_ptr.* != .object) continue;
                var projected = try object(a, model.value_ptr.*, &.{ "id", "name", "attachment", "reasoning", "tool_call", "temperature" });
                inline for (.{ .{ "limit", &.{ "context", "input", "output" } }, .{ "cost", &.{ "input", "output", "cache_read", "cache_write" } }, .{ "modalities", &.{ "input", "output" } } }) |nested| {
                    if (model.value_ptr.object.get(nested[0])) |v| {
                        if (v == .object) try projected.object.put(a, nested[0], try object(a, v, nested[1]));
                    }
                }
                try models.put(a, model.key_ptr.*, projected);
            }
        }
        try provider.object.put(a, "models", .{ .object = models });
        try out.put(a, entry.key_ptr.*, provider);
    }
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = out }, .{});
}
