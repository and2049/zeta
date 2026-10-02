//! Apply non-overlapping exact replacements, all matched against the original
//! file before any bytes are written. No fuzzy or incremental matching.
const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const Io = std.Io;
const diff = @import("diff.zig");

pub const tool: plugin.tool.Tool = .{
    .name = "edit",
    .description = "Replace one or more unique, non-overlapping oldText blocks in an existing file. All edits match the original content.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","minLength":1},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"oldText":{"type":"string","minLength":1},"newText":{"type":"string"}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
    ,
    .side_effect = .workspace,
    .execution_mode = .sequential,
    .execute = execute,
};

test "edit declaration uses supported schema and sequential workspace policy" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema, .{});
    defer parsed.deinit();
    try plugin.schema.check(parsed.value);
    try std.testing.expectEqual(plugin.tool.ExecutionMode.sequential, tool.execution_mode);
    try std.testing.expectEqual(plugin.tool.SideEffect.workspace, tool.side_effect);
}

const Replacement = struct { start: usize, old_len: usize, new_text: []const u8 };

fn before(_: void, a: Replacement, b: Replacement) bool {
    return a.start < b.start;
}

fn execute(_: ?*anyopaque, arena: std.mem.Allocator, io: Io, location: []const u8, args: std.json.Value, sink: plugin.tool.ProgressSink) !plugin.tool.Result {
    if (args != .object) return error.InvalidArguments;
    const path_value = args.object.get("path") orelse return error.InvalidArguments;
    const edits = args.object.get("edits") orelse return error.InvalidArguments;
    if (path_value != .string or path_value.string.len == 0 or edits != .array or edits.array.items.len == 0) return error.InvalidArguments;
    const path = try std.fs.path.resolve(arena, &.{ location, path_value.string });
    // Edit never creates a missing file. File contents and all output belong
    // to the caller's invocation arena.
    const original = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const replacements = try arena.alloc(Replacement, edits.array.items.len);
    for (edits.array.items, replacements) |item, *replacement| {
        if (item != .object) return error.InvalidArguments;
        const old_value = item.object.get("oldText") orelse return error.InvalidArguments;
        const new_value = item.object.get("newText") orelse return error.InvalidArguments;
        if (old_value != .string or old_value.string.len == 0 or new_value != .string) return error.InvalidArguments;
        const start = std.mem.indexOf(u8, original, old_value.string) orelse return error.MatchNotFound;
        if (std.mem.indexOfPos(u8, original, start + 1, old_value.string) != null) return error.AmbiguousMatch;
        replacement.* = .{ .start = start, .old_len = old_value.string.len, .new_text = new_value.string };
    }
    std.mem.sort(Replacement, replacements, {}, before);
    for (replacements[1..], replacements[0 .. replacements.len - 1]) |next, previous| {
        if (next.start < previous.start + previous.old_len) return error.OverlappingEdits;
    }

    var output: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (replacements) |replacement| {
        try output.appendSlice(arena, original[cursor..replacement.start]);
        try output.appendSlice(arena, replacement.new_text);
        cursor = replacement.start + replacement.old_len;
    }
    try output.appendSlice(arena, original[cursor..]);
    const changes = try arena.alloc(@import("proto").message.FileChange, replacements.len);
    // Shared metadata budget across every replacement in this result.
    var remaining = diff.max_bytes;
    for (replacements, changes) |replacement, *change| {
        const old = original[replacement.start..][0..replacement.old_len];
        const before_limit = remaining / 2;
        const preview_before = diff.prefix(old, before_limit);
        remaining -= preview_before.len;
        const after = diff.prefix(replacement.new_text, remaining);
        remaining -= after.len;
        change.* = .{ .path = path_value.string, .before = preview_before, .after = after, .truncated = preview_before.len < old.len or after.len < replacement.new_text.len };
    }
    const text = try std.fmt.allocPrint(arena, "Successfully replaced {d} block(s) in {s}", .{ replacements.len, path_value.string });
    // All validation and allocation, including the result, complete before
    // mutation: an invalid later edit cannot leave earlier edits applied, and
    // a replaced file is never reported as a failure.
    try sink.backup(path);
    try platform.fs.writeAtomic(io, arena, path, output.items);
    return .{ .text = text, .changes = changes };
}

test "multiple disjoint edits match original even if replacement contains another oldText" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "first middle last\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"path":"file.txt","edits":[{"oldText":"last","newText":"done"},{"oldText":"first","newText":"last"}]}
    , .{});
    const sink: plugin.tool.ProgressSink = .{ .ctx = undefined, .onProgress = struct {
        fn emit(_: *anyopaque, _: []const u8) anyerror!void {}
    }.emit };
    const result = try tool.execute(tool.ctx, arena, io, base, input, sink);
    try std.testing.expect(!result.isError);
    try std.testing.expectEqual(@as(usize, 2), result.changes.len);
    try std.testing.expectEqualStrings("first", result.changes[0].before);
    try std.testing.expectEqualStrings("last", result.changes[0].after);
    const content = try tmp.dir.readFileAlloc(io, "file.txt", arena, .unlimited);
    try std.testing.expectEqualStrings("last middle done\n", content);
}

test "edit previews share the existing tool result byte budget" {
    const preview = @import("diff.zig").prefix("ééé", 3);
    try std.testing.expectEqualStrings("é", preview);
}

test "missing, ambiguous, overlap, and invalid later edits leave file unchanged" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "alpha beta alpha\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = original });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const sink: plugin.tool.ProgressSink = .{ .ctx = undefined, .onProgress = struct {
        fn emit(_: *anyopaque, _: []const u8) anyerror!void {}
    }.emit };
    const cases = .{
        .{ "{\"path\":\"file.txt\",\"edits\":[{\"oldText\":\"beta\",\"newText\":\"X\"},{\"oldText\":\"absent\",\"newText\":\"Y\"}]}", error.MatchNotFound },
        .{ "{\"path\":\"file.txt\",\"edits\":[{\"oldText\":\"alpha\",\"newText\":\"X\"}]}", error.AmbiguousMatch },
        .{ "{\"path\":\"file.txt\",\"edits\":[{\"oldText\":\"alpha beta\",\"newText\":\"X\"},{\"oldText\":\"beta alpha\",\"newText\":\"Y\"}]}", error.OverlappingEdits },
        .{ "{\"path\":\"file.txt\",\"edits\":[{\"oldText\":\"beta\",\"newText\":\"X\"},{\"oldText\":\"\",\"newText\":\"Y\"}]}", error.InvalidArguments },
        .{ "{\"path\":\"file.txt\",\"edits\":[]}", error.InvalidArguments },
    };
    inline for (cases) |case| {
        const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, case[0], .{});
        try std.testing.expectError(case[1], tool.execute(tool.ctx, arena, io, base, input, sink));
        const content = try tmp.dir.readFileAlloc(io, "file.txt", arena, .unlimited);
        try std.testing.expectEqualStrings(original, content);
    }
    const absent = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"missing.txt\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}", .{});
    try std.testing.expectError(error.FileNotFound, tool.execute(tool.ctx, arena, io, base, absent, sink));
}
