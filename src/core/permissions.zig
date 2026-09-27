//! Ordered permission policy. The fail-closed approval broker lives in
//! `permission_broker.zig` and is re-exported here as `Broker`.
//! Runtime integration contract: export this module as `core.permissions`;
//! `Runtime.replyPermission(id, Reply) bool` delegates to Broker.reply;
//! `Runtime.disconnectPermissions() void` delegates to Broker.disconnect.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Rule = @import("config.zig").PermissionRule;
pub const Effect = @FieldType(Rule, "effect");
pub const Reply = enum { allow_once, allow_session, deny };
pub const Request = struct {
    session: []const u8,
    location: []const u8,
    action: []const u8,
    /// Tool name, file path, or other action-specific resource.
    pattern: []const u8,
    /// Optional correlation with the originating model tool call.
    tool_call_id: ?[]const u8 = null,
};

/// Later scopes and later matching entries override earlier rules.
pub fn decide(req: Request, agent: []const Rule, config: []const Rule, session: []const Rule) Effect {
    var effect: Effect = .allow;
    for ([_][]const Rule{ agent, config, session }) |rules| {
        for (rules) |rule| {
            if (glob(rule.action, req.action) and glob(rule.pattern, req.pattern)) effect = rule.effect;
        }
    }
    return effect;
}

/// '*' matches zero or more bytes and '?' exactly one character; every other
/// byte is literal. A trailing " *" may also match nothing, so `git *`
/// matches both `git` and `git status`.
pub fn glob(pattern: []const u8, text: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, " *") and std.mem.eql(u8, text, pattern[0 .. pattern.len - 2])) return true;
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '?') {
            p += 1;
            t += charLen(text, t);
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = t;
        } else if (star) |s| {
            retry += 1;
            t = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

/// Byte length of the UTF-8 character at `i`; invalid bytes count as one.
fn charLen(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    if (i + n > text.len) return 1;
    _ = std.unicode.utf8Decode(text[i .. i + n]) catch return 1;
    return n;
}

/// Canonicalizes existing ancestors (including symlinks) while allowing a
/// missing leaf for write tools. Caller owns a non-null result in `arena`.
/// Enforcement still requires the tool to use the same path without a TOCTOU
/// replacement; this is a policy check, not a filesystem sandbox.
pub fn externalDirectory(arena: Allocator, io: Io, location: []const u8, path: []const u8) !?[]const u8 {
    const root = try canonical(arena, io, location);
    defer arena.free(root);
    const absolute = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(arena, &.{ location, path });
    defer if (!std.fs.path.isAbsolute(path)) arena.free(absolute);
    const clean = try canonical(arena, io, absolute);
    if (std.mem.eql(u8, root, clean) or
        (std.mem.startsWith(u8, clean, root) and (root.len == 1 or (clean.len > root.len and clean[root.len] == '/'))))
    {
        arena.free(clean);
        return null;
    }
    return clean;
}

fn canonical(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    const clean = try std.fs.path.resolve(arena, &.{path});
    defer arena.free(clean);
    var parent: []const u8 = clean;
    while (true) {
        const resolved = Io.Dir.realPathFileAbsoluteAlloc(io, parent, arena) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                parent = std.fs.path.dirname(parent) orelse return error.InvalidPath;
                continue;
            },
            else => return err,
        };
        defer arena.free(resolved);
        const suffix = std.mem.trimStart(u8, clean[parent.len..], "/");
        return std.fs.path.resolve(arena, &.{ resolved, suffix });
    }
}

pub const Broker = @import("permission_broker.zig").Broker;

test "ordered matching and scope overlay" {
    const r: Request = .{ .session = "s", .location = "/repo", .action = "read", .pattern = "/repo/file" };
    const agent = [_]Rule{.{ .action = "*", .pattern = "*", .effect = .deny }};
    const cfg = [_]Rule{ .{ .action = "read", .pattern = "/repo/*", .effect = .ask }, .{ .action = "read", .pattern = "*/file", .effect = .allow } };
    try std.testing.expectEqual(Effect.allow, decide(r, &agent, &cfg, &.{}));
    const overlay = [_]Rule{.{ .action = "read", .pattern = "*/file", .effect = .deny }};
    try std.testing.expectEqual(Effect.deny, decide(r, &agent, &cfg, &overlay));
    try std.testing.expectEqual(Effect.allow, decide(r, &.{}, &.{}, &.{}));
    try std.testing.expect(glob("a*b*c", "axbyc"));
    try std.testing.expect(!glob("a*b", "abx"));
}

test "question mark and optional trailing argument wildcard" {
    try std.testing.expect(glob("a?c", "abc"));
    try std.testing.expect(glob("a?c", "a\u{e9}c"));
    try std.testing.expect(!glob("a?c", "ac"));
    try std.testing.expect(!glob("a?c", "abbc"));
    try std.testing.expect(glob("*.?s", "src/main.ts"));
    try std.testing.expect(glob("git *", "git"));
    try std.testing.expect(glob("git *", "git status"));
    try std.testing.expect(!glob("git *", "gitk"));
    try std.testing.expect(!glob("git*x", "git"));
}

test "external directory requires a path boundary" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect((try externalDirectory(a, io, "/repo", "/repo/src")) == null);
    const external = (try externalDirectory(a, io, "/repo", "/repo/../repo2/file")).?;
    defer a.free(external);
    try std.testing.expectEqualStrings("/repo2/file", external);
}

test "external directory resolves a symlinked ancestor of a new file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.symLink(io, "../outside", "repo/link", .{});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const repo = try std.fs.path.join(a, &.{ base, "repo" });
    defer a.free(repo);
    const path = try std.fs.path.join(a, &.{ repo, "link/new.txt" });
    defer a.free(path);
    const found = (try externalDirectory(a, io, repo, path)).?;
    defer a.free(found);
    const expected = try std.fs.path.join(a, &.{ base, "outside/new.txt" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, found);
}
