//! Finds extensions: executables and `zeta.json` directories inside
//! `extensions/` directories, and the `extensions` config list.
const std = @import("std");
const Extension = @import("Extension.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

const max_manifest = 64 * 1024;
const max_entries = 256;

/// Everything found in `root`, in name order; `problems` gets entries that
/// were skipped. All in `arena`.
pub fn directory(arena: Allocator, io: Io, root: []const u8, problems: *std.ArrayList([]const u8)) ![]const Extension.Source {
    const dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (names.items.len == max_entries) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "extensions: {s}: more than {d} entries; the rest were skipped", .{ root, max_entries }));
            break;
        }
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.ArrayList(Extension.Source) = .empty;
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ root, name });
        const stat = dir.statFile(io, name, .{}) catch continue;
        if (stat.kind == .directory) {
            const source = manifest(arena, io, path) catch |err| {
                try problems.append(arena, try std.fmt.allocPrint(arena, "extensions: {s}: {s}", .{ path, @errorName(err) }));
                continue;
            } orelse continue;
            try out.append(arena, source);
        } else if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) {
            try out.append(arena, .{ .name = name, .argv = try arena.dupe([]const u8, &.{path}), .cwd = root, .origin = path });
        }
    }
    return out.items;
}

/// A directory's `zeta.json`: `{"name", "command": [argv], "description"?}`.
/// Null when there is none. A relative program path with a `/` is taken
/// from the directory.
fn manifest(arena: Allocator, io: Io, dir: []const u8) !?Extension.Source {
    const path = try std.fs.path.join(arena, &.{ dir, "zeta.json" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_manifest)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return error.InvalidManifest;
    if (root != .object) return error.InvalidManifest;
    const name = switch (root.object.get("name") orelse return error.ManifestWithoutName) {
        .string => |s| s,
        else => return error.InvalidManifest,
    };
    const argv = try command(arena, root.object.get("command") orelse return error.ManifestWithoutCommand);
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null and !std.fs.path.isAbsolute(argv[0])) {
        argv[0] = try std.fs.path.resolve(arena, &.{ dir, argv[0] });
    }
    return .{ .name = name, .argv = argv, .cwd = dir, .origin = path };
}

fn command(arena: Allocator, v: Value) ![][]const u8 {
    const items = switch (v) {
        .array => |a| a.items,
        else => return error.InvalidCommand,
    };
    if (items.len == 0) return error.InvalidCommand;
    const argv = try arena.alloc([]const u8, items.len);
    for (items, argv) |item, *arg| arg.* = switch (item) {
        .string => |s| s,
        else => return error.InvalidCommand,
    };
    return argv;
}

/// The `extensions` config list: `[{"command": [argv], "env"?: {…}}]`.
/// These run in `location`.
pub fn configured(arena: Allocator, value: Value, location: []const u8, problems: *std.ArrayList([]const u8)) ![]const Extension.Source {
    const items = switch (value) {
        .array => |a| a.items,
        .null => return &.{},
        else => {
            try problems.append(arena, "extensions: the config value must be a list");
            return &.{};
        },
    };
    var out: std.ArrayList(Extension.Source) = .empty;
    for (items, 0..) |item, i| {
        const entry = one(arena, item, location) catch |err| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "extensions[{d}]: {s}", .{ i, @errorName(err) }));
            continue;
        };
        try out.append(arena, entry);
    }
    return out.items;
}

fn one(arena: Allocator, item: Value, location: []const u8) !Extension.Source {
    if (item != .object) return error.InvalidEntry;
    const argv = try command(arena, item.object.get("command") orelse return error.InvalidCommand);
    var env: std.ArrayList([2][]const u8) = .empty;
    if (item.object.get("env")) |e| switch (e) {
        .object => |o| for (o.keys(), o.values()) |k, v| try env.append(arena, .{ k, switch (v) {
            .string => |s| s,
            else => return error.InvalidEnv,
        } }),
        .null => {},
        else => return error.InvalidEnv,
    };
    return .{ .name = null, .argv = argv, .cwd = location, .env = env.items, .origin = "config" };
}

test "executables and manifests are found; broken manifests are reported" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "tool.sh", .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "not an extension" });
    _ = try tmp.dir.createDirPathStatus(io, "hello", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "hello/zeta.json", .data = "{\"name\":\"hello\",\"command\":[\"python3\",\"hello.py\"]}" });
    _ = try tmp.dir.createDirPathStatus(io, "local", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "local/zeta.json", .data = "{\"name\":\"local\",\"command\":[\"./run\"]}" });
    _ = try tmp.dir.createDirPathStatus(io, "broken", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/zeta.json", .data = "{\"command\":[]}" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var problems: std.ArrayList([]const u8) = .empty;
    const found = try directory(a, io, root, &problems);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("hello", found[0].name.?);
    try std.testing.expectEqualStrings("python3", found[0].argv[0]);
    try std.testing.expect(std.mem.endsWith(u8, found[1].argv[0], "local/run"));
    try std.testing.expectEqualStrings("tool.sh", found[2].name.?);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);

    const listed = try std.json.parseFromSliceLeaky(Value, a, "[{\"command\":[\"ext\",\"-v\"],\"env\":{\"K\":\"v\"}},{\"command\":\"x\"}]", .{});
    const entries = try configured(a, listed, "/p", &problems);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("K", entries[0].env[0][0]);
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);
}
