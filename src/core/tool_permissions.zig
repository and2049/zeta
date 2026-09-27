//! Maps validated tool arguments to permission resources. Path checks are
//! advisory policy (not a filesystem sandbox); tools must use the checked path.
const std = @import("std");
const plugin = @import("plugin");
const permissions = @import("permissions.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Resource = struct {
    action: []const u8,
    pattern: []const u8,
    /// Canonical target when a file tool crosses the location boundary.
    external: ?[]const u8 = null,
};

/// `args` already passed the tool schema, and a declared target names one
/// of its string properties. Returned strings live in `arena`.
pub fn resolve(arena: Allocator, io: Io, location: []const u8, tool: plugin.tool.Tool, args: std.json.Value) !Resource {
    const action = tool.permission.action orelse tool.name;
    if (tool.permission.target == .none) return .{ .action = action, .pattern = "*" };
    const value = field(args, tool.permission.arg) orelse return error.InvalidPermissionResource;
    if (tool.permission.target != .path) return .{ .action = action, .pattern = value };
    return .{
        .action = action,
        .pattern = try canonical(arena, io, location, value),
        .external = try permissions.externalDirectory(arena, io, location, value),
    };
}

fn field(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn canonical(arena: Allocator, io: Io, location: []const u8, path: []const u8) ![]const u8 {
    const absolute = try std.fs.path.resolve(arena, &.{ location, path });
    var parent: []const u8 = absolute;
    while (true) {
        const resolved = Io.Dir.realPathFileAbsoluteAlloc(io, parent, arena) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                parent = std.fs.path.dirname(parent) orelse return error.InvalidPermissionResource;
                continue;
            },
            else => return err,
        };
        const suffix = std.mem.trimStart(u8, absolute[parent.len..], "/");
        return std.fs.path.resolve(arena, &.{ resolved, suffix });
    }
}

test "path-specific deny and symlink external target including missing write leaf" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.symLink(io, "../outside", "project/link", .{});
    const project = try std.fs.path.join(arena, &.{ base, "project" });
    const outside = try std.fs.path.join(arena, &.{ base, "outside" });
    const stub = struct {
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            unreachable;
        }
    }.execute;
    const tool: plugin.tool.Tool = .{ .name = "write", .description = "", .input_schema = "{}", .permission = .{ .target = .path, .arg = "path" }, .execute = stub };
    var args: std.json.Value = .{ .object = .empty };
    try args.object.put(arena, "path", .{ .string = "link/new/file" });
    const resource = try resolve(arena, io, project, tool, args);
    const expected = try std.fs.path.join(arena, &.{ outside, "new", "file" });
    try std.testing.expectEqualStrings(expected, resource.pattern);
    try std.testing.expectEqualStrings(expected, resource.external.?);
    const deny = [_]permissions.Rule{.{ .action = "write", .pattern = expected, .effect = .deny }};
    const req: permissions.Request = .{ .session = "s", .location = project, .action = resource.action, .pattern = resource.pattern };
    try std.testing.expectEqual(permissions.Effect.deny, permissions.decide(req, &.{}, &deny, &.{}));
    const external_deny = [_]permissions.Rule{.{ .action = "external_directory", .pattern = try std.fmt.allocPrint(arena, "{s}/*", .{outside}), .effect = .deny }};
    var external_req = req;
    external_req.action = "external_directory";
    try std.testing.expectEqual(permissions.Effect.deny, permissions.decide(external_req, &.{}, &external_deny, &.{}));
}

test "declared targets pick their argument and undeclared tools match any pattern" {
    const stub = struct {
        fn execute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
            unreachable;
        }
    }.execute;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]struct { target: plugin.tool.Target, key: []const u8, value: []const u8 }{
        .{ .target = .command, .key = "command", .value = "ls -la" },
        .{ .target = .url, .key = "url", .value = "https://example.test" },
        .{ .target = .value, .key = "name", .value = "zig" },
    }) |case| {
        var args: std.json.Value = .{ .object = .empty };
        try args.object.put(a, case.key, .{ .string = case.value });
        const tool: plugin.tool.Tool = .{ .name = "t", .description = "", .input_schema = "{}", .permission = .{ .action = "act", .target = case.target, .arg = case.key }, .execute = stub };
        const resource = try resolve(a, std.testing.io, "/", tool, args);
        try std.testing.expectEqualStrings("act", resource.action);
        try std.testing.expectEqualStrings(case.value, resource.pattern);
        try std.testing.expect(resource.external == null);
    }
    const plain: plugin.tool.Tool = .{ .name = "plain_x", .description = "", .input_schema = "{}", .execute = stub };
    const resource = try resolve(a, std.testing.io, "/", plain, .{ .object = .empty });
    try std.testing.expectEqualStrings("plain_x", resource.action);
    try std.testing.expectEqualStrings("*", resource.pattern);
}
