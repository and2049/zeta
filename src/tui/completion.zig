//! Completion list shown above the editor while the word at the cursor is a
//! `/command` (at the start of the input), an `@path`, or a directory
//! argument (`/cd …`). It opens by itself as the word is typed; Tab inserts
//! the highlighted entry.
const std = @import("std");
const picker = @import("picker.zig");
const width = @import("width.zig");

pub const Kind = enum { none, command, file, directory };

/// The word being completed: `start` is the byte offset of the `/` or `@`,
/// or of a directory argument's first byte.
pub const Token = struct { kind: Kind, start: usize, query: []const u8 };

pub const max_rows = 8;

pub const State = struct {
    /// Esc hides the list until the word changes.
    dismissed: ?Token = null,
    selected: usize = 0,
    /// Word shown last, to reset the highlight when it changes.
    last_query: [128]u8 = undefined,
    last_len: usize = 0,
    last_kind: Kind = .none,

    /// Updates the highlight for `token`. Returns true when the word
    /// changed since the last call (a file search is due).
    pub fn observe(s: *State, t: Token) bool {
        const query = t.query[0..@min(t.query.len, s.last_query.len)];
        if (t.kind == s.last_kind and std.mem.eql(u8, query, s.last_query[0..s.last_len])) return false;
        @memcpy(s.last_query[0..query.len], query);
        s.last_len = query.len;
        s.last_kind = t.kind;
        s.selected = 0;
        if (s.dismissed) |d| if (d.kind != t.kind or d.start != t.start) {
            s.dismissed = null;
        };
        return true;
    }

    pub fn open(s: *const State, t: Token) bool {
        if (t.kind == .none) return false;
        if (s.dismissed) |d| return d.kind != t.kind or d.start != t.start;
        return true;
    }

    pub fn move(s: *State, delta: i8, count: usize) void {
        if (count == 0) return;
        s.selected = if (delta < 0) (if (s.selected == 0) count - 1 else s.selected - 1) else (s.selected + 1) % count;
    }
};

/// The word before `cursor` that can be completed, if any.
pub fn token(text: []const u8, cursor: usize) Token {
    const before = text[0..cursor];
    // Stop at a space or newline: the word is over once one is typed.
    const word_start = if (std.mem.lastIndexOfAny(u8, before, " \t\n")) |i| i + 1 else 0;
    const word = before[word_start..];
    // The rest of the word after the cursor must be empty (typing at its end).
    if (cursor < text.len and !std.ascii.isWhitespace(text[cursor])) return .{ .kind = .none, .start = 0, .query = "" };
    if (word_start == 0 and word.len > 0 and word[0] == '/') return .{ .kind = .command, .start = 0, .query = word[1..] };
    if (word.len > 0 and word[0] == '@') return .{ .kind = .file, .start = word_start, .query = word[1..] };
    return .{ .kind = .none, .start = 0, .query = "" };
}

/// A directory argument: the text after `/<name> ` up to the cursor, when
/// that is all the input and on one line.
pub fn argument(text: []const u8, cursor: usize, command: []const u8) ?Token {
    if (cursor != text.len or text.len < command.len + 2 or text[0] != '/') return null;
    if (!std.mem.eql(u8, text[1 .. command.len + 1], command) or text[command.len + 1] != ' ') return null;
    const start = command.len + 2;
    if (std.mem.indexOfScalar(u8, text[start..], '\n') != null) return null;
    return .{ .kind = .directory, .start = start, .query = text[start..] };
}

/// Splits a typed path into the part naming the directory to list (up to
/// and including the last `/`) and the name prefix after it.
pub fn splitPath(query: []const u8) struct { parent: []const u8, prefix: []const u8 } {
    const slash = std.mem.lastIndexOfScalar(u8, query, '/') orelse return .{ .parent = "", .prefix = query };
    return .{ .parent = query[0 .. slash + 1], .prefix = query[slash + 1 ..] };
}

/// `typed` as an absolute path: `~` is `home`, a relative path starts at
/// `cwd`. Allocated in `a`.
pub fn absolutePath(a: std.mem.Allocator, cwd: []const u8, home: []const u8, typed: []const u8) ![]u8 {
    if (std.mem.eql(u8, typed, "~")) return std.fs.path.resolve(a, &.{home});
    if (std.mem.startsWith(u8, typed, "~/")) return std.fs.path.resolve(a, &.{ home, typed[2..] });
    return std.fs.path.resolve(a, &.{ cwd, typed });
}

/// Commands whose name starts with `query` first, then those containing it.
/// `items` ids are `/name`. Returns indices into `items`; caller frees.
pub fn filter(a: std.mem.Allocator, items: []const picker.Item, query: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(a);
    for (items, 0..) |item, i| if (std.ascii.startsWithIgnoreCase(name(item), query)) try out.append(a, i);
    for (items, 0..) |item, i| {
        const n = name(item);
        if (!std.ascii.startsWithIgnoreCase(n, query) and std.ascii.indexOfIgnoreCase(n, query) != null) try out.append(a, i);
    }
    return out.toOwnedSlice(a);
}

fn name(item: picker.Item) []const u8 {
    return if (item.id.len > 0 and item.id[0] == '/') item.id[1..] else item.id;
}

/// Width of the name column: the longest visible name, capped.
pub fn nameColumn(items: []const picker.Item, indices: []const usize) usize {
    var widest: usize = 0;
    for (indices) |i| widest = @max(widest, width.displayWidth(items[i].label));
    return @min(widest, 28);
}

test "tokens: commands only at the start, files after @" {
    try std.testing.expectEqual(Kind.command, token("/mo", 3).kind);
    try std.testing.expectEqualStrings("mo", token("/mo", 3).query);
    try std.testing.expectEqual(Kind.none, token("/model x", 8).kind);
    try std.testing.expectEqual(Kind.none, token("say /mo", 7).kind);
    const file = token("read @src/ma", 12);
    try std.testing.expectEqual(Kind.file, file.kind);
    try std.testing.expectEqual(@as(usize, 5), file.start);
    try std.testing.expectEqualStrings("src/ma", file.query);
    try std.testing.expectEqual(Kind.none, token("@abc", 2).kind);
}

test "directory arguments and path splitting" {
    const t = argument("/cd ../sr", 9, "cd").?;
    try std.testing.expectEqualStrings("../sr", t.query);
    try std.testing.expectEqual(@as(usize, 4), t.start);
    try std.testing.expect(argument("/cdx a", 6, "cd") == null);
    try std.testing.expect(argument("/cd a", 3, "cd") == null);
    const split = splitPath("~/dev/ze");
    try std.testing.expectEqualStrings("~/dev/", split.parent);
    try std.testing.expectEqualStrings("ze", split.prefix);
    try std.testing.expectEqualStrings("", splitPath("src").parent);
}

test "typed paths become absolute" {
    const a = std.testing.allocator;
    for ([_][3][]const u8{
        .{ "~", "/home/me", "" },
        .{ "~/dev/x/", "/home/me/dev/x", "" },
        .{ "../other", "/work/other", "" },
        .{ "/tmp/./y", "/tmp/y", "" },
    }) |case| {
        const got = try absolutePath(a, "/work/project", "/home/me", case[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "dismissal lasts until the word moves and the highlight resets on change" {
    var s: State = .{};
    const t = token("/mo", 3);
    try std.testing.expect(s.observe(t));
    s.move(1, 3);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expect(!s.observe(t));
    s.dismissed = t;
    try std.testing.expect(!s.open(token("/mod", 4)));
    try std.testing.expect(s.observe(token("/mod", 4)));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    try std.testing.expect(s.open(token("x @", 3)));
}

test "prefix matches come before substring matches" {
    const items = [_]picker.Item{ .{ .id = "/undo", .label = "/undo" }, .{ .id = "/new", .label = "/new" }, .{ .id = "/rename", .label = "/rename" } };
    const found = try filter(std.testing.allocator, &items, "n");
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, found);
}
