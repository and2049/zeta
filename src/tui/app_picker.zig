const std = @import("std");
const picker = @import("picker.zig");

/// Sessions labeled by title, with when they were created.
pub fn sessions(a: std.mem.Allocator, bytes: []const u8, clock: @import("clock.zig").Clock) ![]const picker.Item {
    const infos = try std.json.parseFromSliceLeaky([]const @import("client").session_api.Info, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const items = try a.alloc(picker.Item, infos.len);
    for (infos, items) |info, *item| {
        var buf: [32]u8 = undefined;
        item.* = .{ .id = info.id, .label = info.title orelse "Untitled", .detail = try a.dupe(u8, clock.dateTime(&buf, info.created)) };
    }
    return items;
}

pub fn models(a: std.mem.Allocator, bytes: []const u8) ![]const picker.Item {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    const providers = if (value == .object) value.object.get("providers") orelse return &.{} else return &.{};
    if (providers != .array) return &.{};
    var items: std.ArrayList(picker.Item) = .empty;
    for (providers.array.items) |provider| {
        if (provider != .object) continue;
        const id = str(provider, "id") orelse continue;
        const list = provider.object.get("models") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |model| {
            if (model != .object) continue;
            const model_id = str(model, "id") orelse continue;
            try items.append(a, .{ .id = try std.fmt.allocPrint(a, "{s}/{s}", .{ id, model_id }), .label = str(model, "name") orelse model_id, .detail = id });
        }
    }
    return items.items;
}

pub const ModelInfo = struct { context: u64 = 0, reasoning: bool = false };

/// Context window and reasoning support of `model` (`provider/id`) in a
/// model listing; zero values when it is not listed.
pub fn modelInfo(a: std.mem.Allocator, bytes: []const u8, model: []const u8) !ModelInfo {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    const slash = std.mem.indexOfScalar(u8, model, '/') orelse return .{};
    const providers = if (value == .object) value.object.get("providers") orelse return .{} else return .{};
    if (providers != .array) return .{};
    for (providers.array.items) |provider| {
        if (provider != .object or !std.mem.eql(u8, str(provider, "id") orelse "", model[0..slash])) continue;
        const list = provider.object.get("models") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |entry| {
            if (entry != .object or !std.mem.eql(u8, str(entry, "id") orelse "", model[slash + 1 ..])) continue;
            const context = entry.object.get("context") orelse .null;
            const reasoning = entry.object.get("reasoning") orelse .null;
            return .{
                .context = if (context == .integer and context.integer > 0) @intCast(context.integer) else 0,
                .reasoning = reasoning == .bool and reasoning.bool,
            };
        }
    }
    return .{};
}

test "model info comes from the listing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"providers":[{"id":"openai","models":[{"id":"gpt-6/luna","context":272000,"reasoning":true}]}]}
    ;
    const info = try modelInfo(arena.allocator(), body, "openai/gpt-6/luna");
    try std.testing.expectEqual(@as(u64, 272000), info.context);
    try std.testing.expect(info.reasoning);
    try std.testing.expectEqual(@as(u64, 0), (try modelInfo(arena.allocator(), body, "x/y")).context);
}

fn str(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
