const std = @import("std");
const plugin = @import("plugin");
const Hooks = @import("root.zig").Hooks;
const Io = std.Io;
const testing = std.testing;

const blocking =
    \\{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo \"no $(cat | grep -o rm | head -n 1)\" >&2; exit 2"}]}]}}
;

test "a project hooks.json loads on first use, keeps its last good version, and goes when deleted" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    _ = try tmp.dir.createDirPathStatus(io, "proj/.zeta", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/hooks.json", .data = blocking });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project = try std.fs.path.join(arena, &.{ base, "proj" });

    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var hooks: Hooks = .{ .gpa = gpa, .registry = &registry, .env = &env, .home = base, .config_dir = base, .sessions_dir = base };
    defer hooks.deinit();
    try hooks.register();

    try testing.expectEqual(@as(usize, 0), (try registry.activate(arena, project)).len);
    const view = try registry.view(arena, project);
    try testing.expectEqual(@as(usize, 1), view.hooks.len);
    try testing.expect(std.mem.endsWith(u8, view.hooks[0].plugin, "proj/.zeta/hooks.json"));
    try testing.expectEqual(@as(usize, 0), (try registry.view(arena, base)).hooks.len);

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "command", .{ .string = "rm -rf /" });
    const scope: plugin.hook.Scope = .{ .session = "ses_x", .location = project, .provider = "p", .model = "m" };
    const hook = view.hooks[0].value;
    const blocked = try hook.point.tool_pre(hook.ctx, arena, io, scope, .{ .id = "c", .name = "bash", .args = .{ .object = args } });
    try testing.expectEqualStrings("no rm", blocked.block);
    try testing.expect(try hook.point.tool_pre(hook.ctx, arena, io, scope, .{ .id = "c", .name = "read", .args = .{ .object = args } }) == .@"continue");

    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/hooks.json", .data = "{broken" });
    try testing.expectEqual(@as(usize, 1), (try registry.reload(arena, project)).len);
    const kept = try registry.view(arena, project);
    try testing.expectEqual(@as(usize, 1), kept.hooks.len);
    try testing.expectEqual(@as(usize, 1), kept.problems.len);

    try tmp.dir.deleteFile(io, "proj/.zeta/hooks.json");
    try testing.expectEqual(@as(usize, 0), (try registry.reload(arena, project)).len);
    const gone = try registry.view(arena, project);
    try testing.expectEqual(@as(usize, 0), gone.hooks.len);
    try testing.expectEqual(@as(usize, 0), gone.problems.len);
}

test "file order holds when the later file keeps an old version; a failing command does not skip the next" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    _ = try tmp.dir.createDirPathStatus(io, "p/.zeta", .default_dir);
    _ = try tmp.dir.createDirPathStatus(io, "p/.agents", .default_dir);
    const submit =
        \\{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "exit 1"}, {"type": "command", "command": "echo nope >&2; exit 2"}]}]}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.agents/hooks.json", .data = submit });
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.zeta/hooks.json", .data = blocking });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project = try std.fs.path.join(arena, &.{ base, "p" });
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var hooks: Hooks = .{ .gpa = gpa, .registry = &registry, .env = &env, .home = base, .config_dir = base, .sessions_dir = base };
    defer hooks.deinit();
    try hooks.register();
    _ = try registry.activate(arena, project);

    try tmp.dir.writeFile(io, .{ .sub_path = "p/.zeta/hooks.json", .data = "{broken" });
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.agents/hooks.json", .data = submit ++ " " });
    _ = try registry.reload(arena, project);
    const view = try registry.view(arena, project);
    try testing.expectEqual(@as(usize, 2), view.hooks.len);
    try testing.expect(std.mem.endsWith(u8, view.hooks[0].plugin, ".agents/hooks.json"));
    try testing.expect(std.mem.endsWith(u8, view.hooks[1].plugin, ".zeta/hooks.json"));

    const scope: plugin.hook.Scope = .{ .session = "ses_x", .location = project, .provider = "p", .model = "m" };
    const hook = view.hooks[0].value;
    const result = try hook.point.prompt_submit(hook.ctx, arena, io, scope, .{ .id = "msg_1", .text = "hi" });
    try testing.expectEqualStrings("nope", result.block);
}

test "using the home directory as a project keeps user hooks for every project" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    _ = try tmp.dir.createDirPathStatus(io, ".agents", .default_dir);
    _ = try tmp.dir.createDirPathStatus(io, "elsewhere", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".agents/hooks.json", .data = blocking });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const elsewhere = try std.fs.path.join(arena, &.{ home, "elsewhere" });
    var registry: plugin.Registry = .init(gpa, io);
    defer registry.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var hooks: Hooks = .{ .gpa = gpa, .registry = &registry, .env = &env, .home = home, .config_dir = elsewhere, .sessions_dir = home };
    defer hooks.deinit();
    try hooks.register();
    _ = try registry.activate(arena, home);
    _ = try registry.activate(arena, elsewhere);
    try testing.expectEqual(@as(usize, 1), (try registry.view(arena, home)).hooks.len);
    const other = try registry.view(arena, elsewhere);
    try testing.expectEqual(@as(usize, 1), other.hooks.len);
    _ = try registry.reload(arena, null);
    try testing.expectEqual(@as(usize, 1), (try registry.view(arena, elsewhere)).hooks.len);
}
