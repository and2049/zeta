//! Model view for ChatGPT-plan accounts.
//! The public API catalog also includes models unavailable to ChatGPT tokens.
const std = @import("std");
const models = @import("../models.zig");

pub fn eligible(id: []const u8) bool {
    for ([_][]const u8{ "gpt-5.5", "gpt-5.3-codex-spark" }) |name| {
        if (std.mem.eql(u8, id, name)) return true;
    }
    for ([_][]const u8{ "gpt-5.5-pro", "gpt-5.6" }) |name| {
        if (std.mem.eql(u8, id, name)) return false;
    }
    if (!std.mem.startsWith(u8, id, "gpt-")) return false;
    const version = id[4..];
    const major_end = for (version, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) break i;
    } else version.len;
    const major = std.fmt.parseInt(u32, version[0..major_end], 10) catch return false;
    if (major > 5) return true;
    if (major != 5 or major_end >= version.len or version[major_end] != '.') return false;
    const rest = version[major_end + 1 ..];
    const minor_end = for (rest, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) break i;
    } else rest.len;
    const minor = std.fmt.parseInt(u32, rest[0..minor_end], 10) catch return false;
    return minor > 4;
}

/// Returned list is arena-owned; strings borrow the supplied catalog snapshot.
pub fn view(arena: std.mem.Allocator, source: []const models.Model) ![]const models.Model {
    var out: std.ArrayList(models.Model) = .empty;
    for (source) |model| {
        if (!eligible(model.id)) continue;
        var copy = model;
        copy.cost = .{};
        copy.context = 400_000;
        copy.input_limit = 272_000;
        try out.append(arena, copy);
    }
    // Keep login usable before the catalog's background refresh completes.
    if (out.items.len == 0) try out.append(arena, .{
        .id = "gpt-5.5",
        .name = "GPT-5.5 (ChatGPT)",
        .context = 400_000,
        .input_limit = 272_000,
        .tool_call = true,
        .reasoning = true,
        .attachment = true,
        .modalities_input = &.{ "text", "image" },
    });
    return out.items;
}

test "ChatGPT model view excludes API-only models and clears API pricing" {
    try std.testing.expect(!eligible("gpt-4.1"));
    try std.testing.expect(!eligible("gpt-5.4"));
    try std.testing.expect(!eligible("gpt-5.5-pro"));
    try std.testing.expect(!eligible("gpt-5.6"));
    try std.testing.expect(eligible("gpt-5.5"));
    try std.testing.expect(eligible("gpt-5.3-codex-spark"));
    try std.testing.expect(eligible("gpt-5.6-terra"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try view(arena.allocator(), &.{
        .{ .id = "gpt-4.1", .name = "API-only" },
        .{ .id = "gpt-5.5", .name = "Codex", .cost = .{ .input = 5 } },
    });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(f64, 0), result[0].cost.input);
    try std.testing.expectEqualStrings("gpt-5.5", (try view(arena.allocator(), &.{}))[0].id);
}

test "ChatGPT view retains catalog GPT-5.6 and GPT-6 variants" {
    const ids = [_][]const u8{ "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-luna", "gpt-6-sol", "gpt-6-astra" };
    var source: [ids.len]models.Model = undefined;
    for (ids, &source) |id, *model| model.* = .{ .id = id, .name = id };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try view(arena.allocator(), &source);
    try std.testing.expectEqual(ids.len, result.len);
    for (ids, result) |id, model| try std.testing.expectEqualStrings(id, model.id);
}
