//! Bounded, line-oriented text reads with offset and limit; an image file
//! (PNG, JPEG, GIF, WebP) comes back as an image for the model.
const std = @import("std");
const plugin = @import("plugin");
const attachment = @import("proto").attachment;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const tool: plugin.tool.Tool = .{
    .name = "read",
    .description = "Read a UTF-8 text file, or an image (PNG, JPEG, GIF, WebP) to look at. Paths are relative to the project or absolute. Output is limited to 2000 lines or 50 KB; use the suggested offset to continue.",
    .input_schema =
    \\{"type":"object","required":["path"],"additionalProperties":false,"properties":{
    \\"path":{"type":"string","minLength":1},"offset":{"type":"integer","minimum":1},
    \\"limit":{"type":"integer","minimum":1}}}
    ,
    .side_effect = .read,
    .execute = execute,
};

fn execute(_: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, args: std.json.Value, _: plugin.tool.ProgressSink) !plugin.tool.Result {
    const input = try std.json.parseFromValueLeaky(struct { path: []const u8, offset: usize = 1, limit: usize = 2000 }, arena, args, .{});
    const path = try std.fs.path.resolve(arena, &.{ location, input.path });
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (try image(arena, io, file, stat.size, path)) |result| return result;
    const buffer = try arena.alloc(u8, 50 * 1024 + 1);
    var reader = file.reader(io, buffer);
    const r = &reader.interface;
    var line_number: usize = 1;
    while (line_number < input.offset) : (line_number += 1) {
        _ = r.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return .{ .text = try std.fmt.allocPrint(arena, "Offset {d} is beyond the end of the file.", .{input.offset}), .isError = true },
            else => return reader.err orelse err,
        };
    }
    var out: Io.Writer.Allocating = .init(arena);
    // Leave space for the continuation notice within the shared result budget.
    const max_bytes = tool.result_budget.max_bytes - 256;
    const max_lines = @min(input.limit, tool.result_budget.max_lines - 2);
    var count: usize = 0;
    while (count < max_lines) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                if (count > 0) break;
                return .{ .text = try std.fmt.allocPrint(arena, "Line {d} exceeds the 50 KB read limit. Use bash to select a smaller byte range.", .{line_number}), .isError = true };
            },
            else => return reader.err orelse err,
        } orelse return .{ .text = out.written() };
        if (std.mem.indexOfScalar(u8, line, 0) != null or !std.unicode.utf8ValidateSlice(line)) return error.NotUtf8Text;
        if (line.len + out.written().len + 1 > max_bytes) {
            if (count == 0) return .{ .text = try std.fmt.allocPrint(arena, "Line {d} exceeds the read output budget. Use bash to select a smaller byte range.", .{line_number}), .isError = true };
            break;
        }
        if (count > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        count += 1;
        line_number += 1;
    }
    // At a line limit, distinguish an exact fit from a truncated file.
    if (count == max_lines) {
        _ = r.peekByte() catch |err| switch (err) {
            error.EndOfStream => return .{ .text = out.written() },
            else => return reader.err orelse err,
        };
    }
    try out.writer.print("\n\n[Output truncated. Use offset={d} to continue.]", .{line_number});
    return .{ .text = out.written() };
}

/// Images larger than this are refused.
const max_image_bytes = 4 * 1024 * 1024;

/// The file as an image result, or null when it is not one.
fn image(arena: Allocator, io: Io, file: Io.File, size: u64, path: []const u8) !?plugin.tool.Result {
    var head: [16]u8 = undefined;
    const n = try file.readPositionalAll(io, &head, 0);
    const mime = attachment.sniff(head[0..n]) orelse return null;
    if (size > max_image_bytes) return .{ .text = try std.fmt.allocPrint(arena, "{s} is a {s} image larger than 4 MB; it cannot be shown.", .{ path, mime }), .isError = true };
    const bytes = try arena.alloc(u8, @intCast(size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.FileChanged;
    const images = try arena.alloc(attachment.Image, 1);
    images[0] = try attachment.fromBytes(arena, mime, bytes);
    return .{ .text = try std.fmt.allocPrint(arena, "Read image {s} ({s}, {d} bytes).", .{ path, mime, size }), .images = images };
}

fn ignore(_: *anyopaque, _: []const u8) !void {}

test "read selects lines and reports a continuation offset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "one\ntwo\nthree\nfour" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const location = buf[0..try tmp.dir.realPath(io, &buf)];
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"input\",\"offset\":2,\"limit\":2}", .{});
    var ctx: u8 = 0;
    const result = try execute(null, a, io, location, args, .{ .ctx = &ctx, .onProgress = ignore });
    try std.testing.expectEqualStrings("two\nthree\n\n[Output truncated. Use offset=4 to continue.]", result.text);
}

test "read bounds long lines and rejects binary text" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 60 * 1024);
    @memset(long, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = long });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const location = buf[0..try tmp.dir.realPath(io, &buf)];
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"input\"}", .{});
    var ctx: u8 = 0;
    const sink: plugin.tool.ProgressSink = .{ .ctx = &ctx, .onProgress = ignore };
    const result = try execute(null, a, io, location, args, sink);
    try std.testing.expect(result.isError);
    try std.testing.expect(result.text.len < 256);
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "binary\x00text" });
    try std.testing.expectError(error.NotUtf8Text, execute(null, a, io, location, args, sink));
}
