//! Prompt-template discovery: `prompts/*.md` (not recursive) at user and
//! project scope, read fresh on every call. The file name is the command
//! name; frontmatter may set `description` and `argument-hint`.
const std = @import("std");
const core = @import("core");
const proto = @import("proto");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Command = core.commands.Command;

const max_file = 1024 * 1024;
/// Templates read from one directory; the rest are skipped with a diagnostic.
const max_per_root = 512;
const description_chars = 60;

/// Later roots replace earlier ones by name. Everything returned belongs to
/// `arena`.
pub fn discover(arena: Allocator, io: Io, home: []const u8, config_dir: []const u8, location: []const u8) !core.commands.Listing {
    const roots = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = try std.fs.path.join(arena, &.{ home, ".agents", "prompts" }), .source = "user" },
        .{ .path = try std.fs.path.join(arena, &.{ config_dir, "prompts" }), .source = "user" },
        .{ .path = try std.fs.path.join(arena, &.{ location, ".agents", "prompts" }), .source = "project" },
        .{ .path = try std.fs.path.join(arena, &.{ location, ".zeta", "prompts" }), .source = "project" },
    };
    var found: std.StringArrayHashMapUnmanaged(Command) = .empty;
    var diagnostics: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try scan(arena, io, root.path, root.source, &found, &diagnostics);
    const commands = try arena.dupe(Command, found.values());
    std.mem.sort(Command, commands, {}, struct {
        fn less(_: void, a: Command, b: Command) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return .{ .commands = commands, .diagnostics = diagnostics.items };
}

fn scan(arena: Allocator, io: Io, root: []const u8, source: []const u8, found: *std.StringArrayHashMapUnmanaged(Command), diagnostics: *std.ArrayList([]const u8)) !void {
    const dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var read: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.name });
        if (read == max_per_root) {
            try diagnostics.append(arena, try std.fmt.allocPrint(arena, "prompts: {s}: more than {d} templates; the rest were skipped", .{ root, max_per_root }));
            return;
        }
        read += 1;
        const name = entry.name[0 .. entry.name.len - ".md".len];
        const problem: ?[]const u8 = if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null)
            "the name contains whitespace"
        else if (proto.commands.isBuiltin(name))
            "the name is a built-in command"
        else
            null;
        if (problem) |reason| {
            try diagnostics.append(arena, try std.fmt.allocPrint(arena, "prompts: {s}: {s}", .{ path, reason }));
            continue;
        }
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(max_file)) catch |err| {
            const reason = switch (err) {
                error.FileTooBig, error.StreamTooLong => "larger than 1 MiB",
                error.IsDir, error.FileNotFound => continue,
                else => @errorName(err),
            };
            try diagnostics.append(arena, try std.fmt.allocPrint(arena, "prompts: {s}: {s}", .{ path, reason }));
            continue;
        };
        const command = parse(arena, try arena.dupe(u8, name), text, path, source) catch |err| switch (err) {
            error.InvalidFrontmatter => {
                try diagnostics.append(arena, try std.fmt.allocPrint(arena, "prompts: {s}: invalid frontmatter", .{path}));
                continue;
            },
            else => |e| return e,
        };
        try found.put(arena, command.name, command);
    }
}

/// Without frontmatter (or without its closing `---`) the whole file is the
/// template. The description falls back to the first nonblank line.
pub fn parse(arena: Allocator, name: []const u8, raw: []const u8, path: []const u8, source: []const u8) !Command {
    var text = if (std.mem.startsWith(u8, raw, "\u{feff}")) raw[3..] else raw;
    if (std.mem.indexOfScalar(u8, text, '\r') != null) text = try std.mem.replaceOwned(u8, arena, text, "\r\n", "\n");
    var body = text;
    var description: ?[]const u8 = null;
    var hint: ?[]const u8 = null;
    if (std.mem.startsWith(u8, text, "---\n")) if (std.mem.indexOf(u8, text[3..], "\n---")) |end| {
        const front = if (end + 3 > 4) text[4 .. end + 3] else "";
        body = text[end + 3 + "\n---".len ..];
        var lines = std.mem.splitScalar(u8, front, '\n');
        var block: ?struct { style: u8, key: []const u8, text: std.ArrayList(u8) } = null;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (block) |*b| {
                if (line.len > 0 and (line[0] == ' ' or line[0] == '\t') or trimmed.len == 0) {
                    if (trimmed.len > 0) {
                        if (b.text.items.len > 0) try b.text.append(arena, if (b.style == '|') '\n' else ' ');
                        try b.text.appendSlice(arena, trimmed);
                    }
                    continue;
                }
                set(b.key, b.text.items, &description, &hint);
                block = null;
            }
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidFrontmatter;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            if (key.len == 0) return error.InvalidFrontmatter;
            if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, "|")) {
                block = .{ .style = value[0], .key = key, .text = .empty };
                continue;
            }
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
                if (value[value.len - 1] != value[0]) return error.InvalidFrontmatter;
                value = value[1 .. value.len - 1];
            }
            set(key, value, &description, &hint);
        }
        if (block) |b| set(b.key, b.text.items, &description, &hint);
    };
    body = std.mem.trim(u8, body, " \t\n");
    return .{
        .name = name,
        .description = if (description) |d| if (d.len > 0) d else try fallback(arena, body) else try fallback(arena, body),
        .argument_hint = if (hint) |h| if (h.len > 0) h else null else null,
        .source = source,
        .path = path,
        .template = body,
    };
}

fn set(key: []const u8, value: []const u8, description: *?[]const u8, hint: *?[]const u8) void {
    if (std.mem.eql(u8, key, "description")) description.* = value;
    if (std.mem.eql(u8, key, "argument-hint")) hint.* = value;
}

/// The first nonblank line, cut to 60 characters with `...` when longer.
fn fallback(arena: Allocator, body: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var end: usize = 0;
        var count: usize = 0;
        while (end < line.len and count < description_chars) : (count += 1) {
            end += std.unicode.utf8ByteSequenceLength(line[end]) catch 1;
        }
        if (end >= line.len) return line;
        return std.fmt.allocPrint(arena, "{s}...", .{line[0..@min(end, line.len)]});
    }
    return "";
}

test "frontmatter sets the description and hint; the body is the template" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const full = try parse(arena, "review", "---\r\ndescription: \"Review a file\"\r\nargument-hint: <path>\r\nmodel: ignored\r\n---\r\n\r\nReview $1.\r\n", "p", "user");
    try std.testing.expectEqualStrings("Review a file", full.description);
    try std.testing.expectEqualStrings("<path>", full.argument_hint.?);
    try std.testing.expectEqualStrings("Review $1.", full.template);
    const folded = try parse(arena, "x", "---\ndescription: >\n  two\n  lines\n---\nbody", "p", "user");
    try std.testing.expectEqualStrings("two lines", folded.description);
    const plain = try parse(arena, "x", "\n\n  First line here\nsecond", "p", "project");
    try std.testing.expectEqualStrings("First line here", plain.description);
    try std.testing.expect(plain.argument_hint == null);
    const long = try parse(arena, "x", "a" ** 61 ++ "\n", "p", "user");
    try std.testing.expectEqualStrings("a" ** 60 ++ "...", long.description);
    const unclosed = try parse(arena, "x", "---\ndescription: no end\nbody", "p", "user");
    try std.testing.expectEqualStrings("---", unclosed.description);
    try std.testing.expectError(error.InvalidFrontmatter, parse(arena, "x", "---\njust words\n---\nbody", "p", "user"));
}

test "project .zeta templates replace wider ones; bad files are diagnosed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_][2][]const u8{
        .{ "home/.agents/prompts/review.md", "user agents" },
        .{ "config/prompts/review.md", "user zeta" },
        .{ "project/.agents/prompts/review.md", "project agents" },
        .{ "project/.zeta/prompts/review.md", "project zeta" },
        .{ "config/prompts/only.md", "---\nargument-hint: <x>\n---\nOnly $1" },
        .{ "config/prompts/model.md", "reserved" },
        .{ "config/prompts/two words.md", "spaced" },
        .{ "config/prompts/bad.md", "---\nnot yaml\n---\n" },
        .{ "config/prompts/notes.txt", "ignored" },
        .{ "config/prompts/nested/deep.md", "not recursive" },
    };
    for (files) |file| {
        _ = try tmp.dir.createDirPathStatus(io, std.fs.path.dirname(file[0]).?, .default_dir);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const at = struct {
        fn f(a: Allocator, b: []const u8, sub: []const u8) ![]const u8 {
            return std.fs.path.join(a, &.{ b, sub });
        }
    }.f;
    const listing = try discover(arena, io, try at(arena, base, "home"), try at(arena, base, "config"), try at(arena, base, "project"));
    try std.testing.expectEqual(@as(usize, 2), listing.commands.len);
    try std.testing.expectEqualStrings("only", listing.commands[0].name);
    try std.testing.expectEqualStrings("<x>", listing.commands[0].argument_hint.?);
    try std.testing.expectEqualStrings("review", listing.commands[1].name);
    try std.testing.expectEqualStrings("project zeta", listing.commands[1].template);
    try std.testing.expectEqualStrings("project", listing.commands[1].source);
    try std.testing.expectEqual(@as(usize, 3), listing.diagnostics.len);
}
