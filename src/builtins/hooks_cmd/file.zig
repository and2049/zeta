//! Parses one `hooks.json`:
//!
//! `{"hooks": {"PreToolUse": [{"matcher": "bash|edit", "hooks": [{"type": "command", "command": "…", "timeout": 30}]}]}}`
//!
//! Entries that cannot run (unknown event, another hook type, a regular
//! expression matcher) are skipped with a warning; a file that is not valid
//! JSON of this shape fails as a whole.
const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub const Event = enum {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PermissionRequest,
    PostToolUse,
    PostToolUseFailure,
    Stop,
};

pub const Command = struct {
    event: Event,
    /// Empty matches everything.
    matcher: []const u8,
    command: []const u8,
    timeout_ms: u64,
};

pub const Parsed = struct {
    commands: []const Command,
    warnings: []const []const u8,
};

pub const default_timeout_ms = 60_000;

/// Everything returned lives in `arena`.
pub fn parse(arena: Allocator, text: []const u8) !Parsed {
    const stripped = try core.jsonc.strip(arena, text);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch return error.InvalidHooksFile;
    if (root != .object) return error.InvalidHooksFile;
    const events = root.object.get("hooks") orelse return .{ .commands = &.{}, .warnings = &.{} };
    if (events != .object) return error.InvalidHooksFile;
    var commands: std.ArrayList(Command) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var it = events.object.iterator();
    while (it.next()) |entry| {
        const event = std.meta.stringToEnum(Event, entry.key_ptr.*) orelse {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "unknown event '{s}' skipped", .{entry.key_ptr.*}));
            continue;
        };
        if (entry.value_ptr.* != .array) return error.InvalidHooksFile;
        for (entry.value_ptr.array.items) |group| {
            if (group != .object) return error.InvalidHooksFile;
            const matcher = switch (group.object.get("matcher") orelse .null) {
                .null => "",
                .string => |s| s,
                else => return error.InvalidHooksFile,
            };
            if (!supported(matcher)) {
                try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} matcher '{s}' looks like a regular expression; use names separated by | with * and ? wildcards", .{ @tagName(event), matcher }));
                continue;
            }
            const list = group.object.get("hooks") orelse return error.InvalidHooksFile;
            if (list != .array) return error.InvalidHooksFile;
            for (list.array.items) |item| {
                if (item != .object) return error.InvalidHooksFile;
                const kind = item.object.get("type") orelse return error.InvalidHooksFile;
                if (kind != .string) return error.InvalidHooksFile;
                if (!std.mem.eql(u8, kind.string, "command")) {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} hook of type '{s}' skipped; only command hooks run", .{ @tagName(event), kind.string }));
                    continue;
                }
                const command = item.object.get("command") orelse return error.InvalidHooksFile;
                if (command != .string or command.string.len == 0) return error.InvalidHooksFile;
                const timeout_ms: u64 = switch (item.object.get("timeout") orelse .null) {
                    .null => default_timeout_ms,
                    .integer => |s| if (s > 0) @as(u64, @intCast(s)) *| 1000 else return error.InvalidHooksFile,
                    .float => |s| if (s > 0) @intFromFloat(@min(s * 1000, 1e15)) else return error.InvalidHooksFile,
                    else => return error.InvalidHooksFile,
                };
                try commands.append(arena, .{ .event = event, .matcher = matcher, .command = command.string, .timeout_ms = timeout_ms });
            }
        }
    }
    return .{ .commands = commands.items, .warnings = warnings.items };
}

/// Names separated by `|`, each with `*` and `?` wildcards.
fn supported(matcher: []const u8) bool {
    return std.mem.indexOfAny(u8, matcher, ".^$()[]{}+\\") == null;
}

/// Whether `matcher` selects `value`. Tool names also match by their
/// capitalised alias (`Bash` for `bash`, `WebFetch` for `webfetch`).
pub fn matches(matcher: []const u8, value: []const u8) bool {
    const trimmed = std.mem.trim(u8, matcher, " ");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "*")) return true;
    const other = alias(value);
    var alternatives = std.mem.splitScalar(u8, trimmed, '|');
    while (alternatives.next()) |raw| {
        const alt = std.mem.trim(u8, raw, " ");
        if (alt.len == 0) continue;
        if (core.permissions.glob(alt, value)) return true;
        if (other) |name| if (core.permissions.glob(alt, name)) return true;
    }
    return false;
}

fn alias(name: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "read", "Read" }, .{ "write", "Write" },       .{ "edit", "Edit" },
        .{ "bash", "Bash" }, .{ "webfetch", "WebFetch" }, .{ "skill", "Skill" },
    };
    for (pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
    return null;
}

const testing = std.testing;

test "commands, timeouts and warnings for what cannot run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(),
        \\{"hooks": {
        \\  "PreToolUse": [{"matcher": "Bash|edit", "hooks": [{"type": "command", "command": "check.sh", "timeout": 5}]},
        \\                 {"matcher": "mcp__.*", "hooks": [{"type": "command", "command": "x"}]}],
        \\  "Stop": [{"hooks": [{"type": "prompt", "prompt": "?"}, {"type": "command", "command": "done.sh"}]}],
        \\  "Notification": [],
        \\}}
    );
    try testing.expectEqual(@as(usize, 2), parsed.commands.len);
    try testing.expectEqual(Event.PreToolUse, parsed.commands[0].event);
    try testing.expectEqual(@as(u64, 5000), parsed.commands[0].timeout_ms);
    try testing.expectEqual(@as(u64, default_timeout_ms), parsed.commands[1].timeout_ms);
    try testing.expectEqual(@as(usize, 3), parsed.warnings.len);
    try testing.expectError(error.InvalidHooksFile, parse(arena.allocator(), "{\"hooks\": []}"));
    try testing.expectError(error.InvalidHooksFile, parse(arena.allocator(), "not json"));
}

test "matchers take names, aliases and wildcards" {
    try testing.expect(matches("", "bash"));
    try testing.expect(matches("*", "anything"));
    try testing.expect(matches("Bash", "bash"));
    try testing.expect(matches("Write | Edit", "edit"));
    try testing.expect(matches("mcp__*", "mcp__git__status"));
    try testing.expect(!matches("Bash", "read"));
    try testing.expect(matches("startup", "startup"));
    try testing.expect(!matches("resume", "startup"));
}
