//! Create or replace a file, including missing parent directories.
const std = @import("std");
const plugin = @import("plugin");
const platform = @import("platform");
const Io = std.Io;
const diff = @import("diff.zig");

pub const tool: plugin.tool.Tool = .{
    .name = "write",
    .description = "Create or overwrite a file with the supplied content; create missing parent directories.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","minLength":1},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
    ,
    .side_effect = .workspace,
    .permission = .{ .target = .path, .arg = "path" },
    .execution_mode = .sequential,
    .execute = execute,
};

test "write declaration uses supported schema and sequential workspace policy" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tool.input_schema, .{});
    defer parsed.deinit();
    try plugin.schema.check(parsed.value);
    try std.testing.expectEqual(plugin.tool.ExecutionMode.sequential, tool.execution_mode);
    try std.testing.expectEqual(plugin.tool.SideEffect.workspace, tool.side_effect);
    try tool.checkPermission(parsed.value);
}

fn execute(_: ?*anyopaque, arena: std.mem.Allocator, io: Io, location: []const u8, args: std.json.Value, sink: plugin.tool.ProgressSink) !plugin.tool.Result {
    if (args != .object) return error.InvalidArguments;
    const path_value = args.object.get("path") orelse return error.InvalidArguments;
    const content = args.object.get("content") orelse return error.InvalidArguments;
    if (path_value != .string or path_value.string.len == 0 or content != .string) return error.InvalidArguments;
    // std.fs.path.resolve respects absolute input paths and resolves relative
    // paths against location. Permission checks for external paths belong to
    // the dispatcher, before this callback is invoked.
    const path = try std.fs.path.resolve(arena, &.{ location, path_value.string });
    const before = try diff.previous(arena, io, path);
    // The result is fully built first: once the file is replaced, nothing
    // may fail and report an error for a write that happened.
    const changes = try arena.alloc(@import("proto").message.FileChange, 1);
    changes[0] = diff.change(path_value.string, before.text, content.string);
    changes[0].truncated = changes[0].truncated or before.truncated;
    const text = try std.fmt.allocPrint(arena, "Successfully wrote to {s}", .{path_value.string});
    try sink.backup(path);
    try platform.fs.writeAtomic(io, arena, path, content.string);
    return .{ .text = text, .changes = changes };
}

test "write creates parents and overwrites, resolving relative and absolute paths" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const sink: plugin.tool.ProgressSink = .{ .ctx = undefined, .onProgress = struct {
        fn emit(_: *anyopaque, _: []const u8) anyerror!void {}
    }.emit };

    const first = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"nested/file.txt\",\"content\":\"first\\n\"}", .{});
    const result = try tool.execute(tool.ctx, arena, io, base, first, sink);
    try std.testing.expect(!result.isError);
    try std.testing.expectEqualStrings("Successfully wrote to nested/file.txt", result.text);
    try std.testing.expectEqualStrings("", result.changes[0].before);
    try std.testing.expectEqualStrings("first\n", result.changes[0].after);
    const absolute = try std.fs.path.join(arena, &.{ base, "nested/file.txt" });
    const next_json = try std.json.Stringify.valueAlloc(arena, .{ .path = absolute, .content = "second" }, .{});
    const second = try std.json.parseFromSliceLeaky(std.json.Value, arena, next_json, .{});
    const overwritten = try tool.execute(tool.ctx, arena, io, "/not/the/location", second, sink);
    try std.testing.expectEqualStrings("first\n", overwritten.changes[0].before);
    try std.testing.expectEqualStrings("second", overwritten.changes[0].after);
    const contents = try Io.Dir.cwd().readFileAlloc(io, absolute, arena, .unlimited);
    try std.testing.expectEqualStrings("second", contents);
}

test "write rejects invalid input before modifying files" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const sink: plugin.tool.ProgressSink = .{ .ctx = undefined, .onProgress = struct {
        fn emit(_: *anyopaque, _: []const u8) anyerror!void {}
    }.emit };
    const invalid = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"new/file\"}", .{});
    try std.testing.expectError(error.InvalidArguments, tool.execute(tool.ctx, arena, io, base, invalid, sink));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "new", .{}));
}
