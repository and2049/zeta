//! What `zeta run` sends: text piped on stdin, then `@file` arguments (a
//! text file's contents in a `<file name="…">` block, an image as an
//! attachment with an empty block naming it), then the prompt words.
const std = @import("std");
const proto = @import("proto");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Input = struct {
    text: []const u8,
    images: []const proto.attachment.Image,
};

/// Larger files and piped input are refused.
pub const max_bytes = 4 * 1024 * 1024;

/// Piped stdin, trimmed; null when stdin is a terminal or has nothing.
pub fn readStdin(arena: Allocator, io: Io) !?[]const u8 {
    const stdin = Io.File.stdin();
    if (try stdin.isTty(io)) return null;
    var buf: [4096]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    const all = reader.interface.allocRemaining(arena, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.StdinTooLarge,
        else => |e| return e,
    };
    const trimmed = std.mem.trim(u8, all, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Why building failed, for the user, when `build` returns
/// `error.BadFileArgument`.
pub const Problem = struct { path: []const u8 = "", reason: []const u8 = "" };

/// `words` are the arguments after the flags; those starting with `@` name
/// files (relative to `cwd`).
pub fn build(arena: Allocator, io: Io, cwd: []const u8, words: []const []const u8, stdin: ?[]const u8, problem: *Problem) !Input {
    var files: std.ArrayList(u8) = .empty;
    var images: std.ArrayList(proto.attachment.Image) = .empty;
    var prompt: std.ArrayList([]const u8) = .empty;
    for (words) |word| {
        if (word.len < 2 or word[0] != '@') {
            try prompt.append(arena, word);
            continue;
        }
        const path = try std.fs.path.resolve(arena, &.{ cwd, word[1..] });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| {
            problem.* = .{ .path = path, .reason = switch (err) {
                error.FileNotFound => "not found",
                error.StreamTooLong => "larger than 4 MiB",
                error.IsDir => "a directory",
                else => @errorName(err),
            } };
            return error.BadFileArgument;
        };
        if (proto.attachment.sniff(bytes)) |mime| {
            try images.append(arena, try proto.attachment.fromBytes(arena, mime, bytes));
            try files.print(arena, "<file name=\"{s}\"></file>\n", .{path});
        } else if (std.unicode.utf8ValidateSlice(bytes)) {
            try files.print(arena, "<file name=\"{s}\">\n{s}\n</file>\n", .{ path, bytes });
        } else {
            problem.* = .{ .path = path, .reason = "neither text nor a supported image" };
            return error.BadFileArgument;
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    if (stdin) |text| try parts.append(arena, text);
    if (files.items.len > 0) try parts.append(arena, std.mem.trimEnd(u8, files.items, "\n"));
    if (prompt.items.len > 0) try parts.append(arena, try std.mem.join(arena, " ", prompt.items));
    return .{ .text = try std.mem.join(arena, "\n\n", parts.items), .images = images.items };
}

test build {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "shot.png", .data = "\x89PNG\r\n\x1a\nxx" });
    var problem: Problem = .{};
    const input = try build(a, io, dir, &.{ "look", "@notes.txt", "@shot.png", "now" }, "piped", &problem);
    const want = try std.fmt.allocPrint(a, "piped\n\n<file name=\"{s}/notes.txt\">\nhello\n</file>\n<file name=\"{s}/shot.png\"></file>\n\nlook now", .{ dir, dir });
    try std.testing.expectEqualStrings(want, input.text);
    try std.testing.expectEqualStrings("image/png", input.images[0].mimeType);
    try std.testing.expectError(error.BadFileArgument, build(a, io, dir, &.{"@missing"}, null, &problem));
    try std.testing.expectEqualStrings("not found", problem.reason);
    // A lone `@` is a word.
    try std.testing.expectEqualStrings("@", (try build(a, io, dir, &.{"@"}, null, &problem)).text);
}
