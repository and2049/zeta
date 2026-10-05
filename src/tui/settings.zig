//! Client settings from `<config>/tui.jsonc`, read once at startup. The
//! server never sees them. Comments (`//`, `/* */`) and trailing commas
//! are allowed.
const std = @import("std");

pub const Display = enum { collapsed, expanded };

pub const Settings = struct {
    /// How reasoning blocks start; Ctrl+T flips them.
    thinking: Display = .collapsed,
    /// How compaction summaries start; Ctrl+T flips them.
    compaction: Display = .collapsed,
    /// `select` copies dragged text when the button is released; with
    /// `manual` it stays selected until a right click copies it.
    copy: enum { select, manual } = .select,
};

pub const Loaded = struct {
    settings: Settings = .{},
    /// Why the file was not used, for the status line.
    problem: ?[]const u8 = null,
};

/// Reads `<config_dir>/tui.jsonc`; a missing file gives the defaults.
/// Allocations go to `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, config_dir: []const u8) Loaded {
    const path = std.fs.path.join(arena, &.{ config_dir, "tui.jsonc" }) catch return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => .{},
        else => .{ .problem = std.fmt.allocPrint(arena, "tui.jsonc: {s}", .{@errorName(err)}) catch null },
    };
    return parse(arena, bytes);
}

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Loaded {
    const json = strip(arena, bytes) catch return .{ .problem = "tui.jsonc: out of memory" };
    const settings = std.json.parseFromSliceLeaky(Settings, arena, json, .{}) catch |err|
        return .{ .problem = std.fmt.allocPrint(arena, "tui.jsonc ignored: {s}", .{@errorName(err)}) catch null };
    return .{ .settings = settings };
}

/// JSONC to JSON: drops comments and commas before `}` or `]`, leaving
/// strings alone.
fn strip(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < bytes.len and bytes[i] != '"') : (i += 1) {
                if (bytes[i] == '\\') i += 1;
            }
            i = @min(i + 1, bytes.len);
            try out.appendSlice(arena, bytes[start..i]);
        } else if (std.mem.startsWith(u8, bytes[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        } else if (std.mem.startsWith(u8, bytes[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, bytes, i + 2, "*/")) |end| end + 2 else bytes.len;
        } else if (c == ',') {
            const next = std.mem.indexOfNonePos(u8, bytes, i + 1, " \t\r\n") orelse bytes.len;
            if (next == bytes.len or bytes[next] == '}' or bytes[next] == ']') {
                i += 1;
            } else {
                try out.append(arena, c);
                i += 1;
            }
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

test "settings with comments, trailing commas and bad values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = parse(a,
        \\{
        \\  // expanded by default
        \\  "thinking": "expanded", /* note */
        \\  "compaction": "collapsed",
        \\}
    );
    try std.testing.expect(ok.problem == null);
    try std.testing.expectEqual(Display.expanded, ok.settings.thinking);
    try std.testing.expect(ok.settings.copy == .select);
    try std.testing.expect(parse(a, "{\"copy\": \"manual\"}").settings.copy == .manual);
    const bad = parse(a, "{\"thinking\": \"open\"}");
    try std.testing.expect(bad.problem != null);
    try std.testing.expectEqual(Display.collapsed, bad.settings.thinking);
    try std.testing.expect(parse(a, "{\"unknown\": 1}").problem != null);
    try std.testing.expectEqualStrings("{\"a\":\"//,}\"}", try strip(a, "{\"a\":\"//,}\"}"));
}
