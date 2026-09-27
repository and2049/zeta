const std = @import("std");
const Registry = @import("Registry.zig");
const provider_api = @import("provider.zig");
const tool_api = @import("tool.zig");
const hook_api = @import("hook.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Owner = Registry.Owner;
const Failure = Registry.Failure;
const testing = std.testing;

fn stubStream(_: ?*anyopaque, _: Allocator, _: Io, _: provider_api.Options, _: provider_api.Request, _: provider_api.Sink) anyerror!void {}

fn stubExecute(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: std.json.Value, _: tool_api.ProgressSink) anyerror!tool_api.Result {
    return .{ .text = "ok" };
}

test "duplicate plugin ids and duplicate names in one layer are rejected" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const owner = try r.addPlugin(.{ .id = "x" });
    try testing.expectError(error.DuplicatePlugin, r.addPlugin(.{ .id = "x" }));
    const other = try r.addPlugin(.{ .id = "y" });
    try r.addApi(owner, .{ .id = "api", .stream = stubStream });
    try testing.expectError(error.DuplicateRegistration, r.addApi(other, .{ .id = "api", .stream = stubStream }));
    try testing.expectError(error.InvalidPlugin, r.addPlugin(.{ .id = "p", .layer = .project }));
    // One id per scope: the same project plugin may run in two projects.
    _ = try r.addPlugin(.{ .id = "srv", .layer = .project, .location = "/a" });
    _ = try r.addPlugin(.{ .id = "srv", .layer = .project, .location = "/b" });
    try testing.expectError(error.DuplicatePlugin, r.addPlugin(.{ .id = "srv", .layer = .project, .location = "/a" }));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try r.view(arena.allocator(), null);
    try testing.expect(v.api("api") != null);
    try testing.expect(v.api("missing") == null);
    try testing.expectEqual(@as(usize, 2), v.plugins.len);
}

test "narrower layers shadow by name and disposal shows the wider entry again" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try r.addPlugin(.{ .id = "read" });
    try r.addTool(base, .{ .name = "read", .description = "built-in", .input_schema = "{}", .execute = stubExecute });
    try r.addTool(base, .{ .name = "other", .description = "other", .input_schema = "{}", .execute = stubExecute });
    const user = try r.addPlugin(.{ .id = "mine", .layer = .user, .source = "/u/mine" });
    try r.addTool(user, .{ .name = "read", .description = "user", .input_schema = "{}", .execute = stubExecute });
    const project = try r.addPlugin(.{ .id = "proj", .layer = .project, .location = "/p", .source = "/p/.zeta/x" });
    try r.addTool(project, .{ .name = "read", .description = "project", .input_schema = "{}", .execute = stubExecute });

    const here = try r.view(a, "/p");
    try testing.expectEqual(@as(usize, 2), here.tools.len);
    try testing.expectEqualStrings("read", here.tools[0].value.name);
    try testing.expectEqualStrings("project", here.tools[0].value.description);
    try testing.expectEqualStrings("proj", here.tools[0].plugin);
    try testing.expectEqualStrings("user", (try r.view(a, "/elsewhere")).tool("read").?.description);

    r.dispose(user);
    try testing.expectEqualStrings("built-in", (try r.view(a, "/elsewhere")).tool("read").?.description);
    try testing.expectEqualStrings("project", (try r.view(a, "/p")).tool("read").?.description);
    r.dispose(project);
    try testing.expectEqualStrings("built-in", (try r.view(a, "/p")).tool("read").?.description);
    try testing.expectError(error.PluginDisposed, r.addTool(project, .{ .name = "late", .description = "", .input_schema = "{}", .execute = stubExecute }));
    // The id is free again once its plugin is gone.
    _ = try r.addPlugin(.{ .id = "mine", .layer = .user });
}

test "a provider id falls back to the `*` registration" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const stub = struct {
        fn resolve(_: ?*anyopaque, _: Allocator, _: Io, _: provider_api.Query) anyerror!provider_api.Route {
            return .{ .api = "x", .options = .{} };
        }
    }.resolve;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try r.view(arena.allocator(), null)).provider("openai") == null);
    try r.addProvider(try r.addPlugin(.{ .id = "custom" }), .{ .id = "*", .name = "Custom", .resolve = stub });
    try r.addProvider(try r.addPlugin(.{ .id = "openai" }), .{ .id = "openai", .name = "OpenAI", .resolve = stub });
    const v = try r.view(arena.allocator(), null);
    try testing.expectEqualStrings("openai", v.provider("openai").?.plugin);
    try testing.expectEqualStrings("custom", v.provider("local").?.plugin);
}

test "hooks all apply, in layer order and then registration order" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const stub = struct {
        fn stop(_: ?*anyopaque, _: Allocator, _: Io, _: hook_api.Scope, _: hook_api.Stop) anyerror!hook_api.TurnStop {
            return .stop;
        }
    }.stop;
    const project = try r.addPlugin(.{ .id = "p", .layer = .project, .location = "/p" });
    const user = try r.addPlugin(.{ .id = "u", .layer = .user });
    const base = try r.addPlugin(.{ .id = "b" });
    for ([_]Owner{ project, user, base, user }) |owner| try r.addHook(owner, .{ .point = .{ .turn_stop = stub } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try r.view(arena.allocator(), "/p");
    try testing.expectEqual(@as(usize, 4), v.hooks.len);
    for ([_][]const u8{ "b", "u", "u", "p" }, v.hooks) |id, h| try testing.expectEqualStrings(id, h.plugin);
    try testing.expectEqual(@as(usize, 3), (try r.view(arena.allocator(), null)).hooks.len);
    r.dispose(user);
    try testing.expectEqual(@as(usize, 2), (try r.view(arena.allocator(), "/p")).hooks.len);
}

test "a staged replacement stays hidden until commit, and discarding it keeps the old one" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try r.addPlugin(.{ .id = "ext", .layer = .user });
    try r.addTool(old, .{ .name = "t", .description = "old", .input_schema = "{}", .execute = stubExecute });
    try testing.expectError(error.DuplicatePlugin, r.stage(.{ .id = "ext", .layer = .user }, null));

    const failed = try r.stage(.{ .id = "ext", .layer = .user }, old);
    try r.addTool(failed, .{ .name = "t", .description = "broken", .input_schema = "{}", .execute = stubExecute });
    try testing.expectEqualStrings("old", (try r.view(a, null)).tool("t").?.description);
    r.dispose(failed);
    try testing.expectEqualStrings("old", (try r.view(a, null)).tool("t").?.description);

    const next = try r.stage(.{ .id = "ext", .layer = .user }, old);
    try r.addTool(next, .{ .name = "t", .description = "new", .input_schema = "{}", .execute = stubExecute });
    r.commit(next);
    const v = try r.view(a, null);
    try testing.expectEqual(@as(usize, 1), v.plugins.len);
    try testing.expectEqualStrings("new", v.tool("t").?.description);
}

test "reload runs every loader and reports a failing one by name" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const Fake = struct {
        fn ok(_: ?*anyopaque, arena: Allocator, _: Io, location: ?[]const u8) anyerror![]const Failure {
            if (location == null) return &.{};
            try testing.expectEqualStrings("/p", location.?);
            return arena.dupe(Failure, &.{.{ .plugin = "one", .message = "bad manifest" }});
        }
        fn broken(_: ?*anyopaque, _: Allocator, _: Io, location: ?[]const u8) anyerror![]const Failure {
            if (location == null) return &.{};
            return error.Unreadable;
        }
    };
    try r.addLoader(.{ .name = "first", .load = Fake.ok });
    try r.addLoader(.{ .name = "second", .load = Fake.broken });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const failures = try r.reload(arena.allocator(), "/p");
    try testing.expectEqual(@as(usize, 2), failures.len);
    try testing.expectEqualStrings("one", failures[0].plugin);
    try testing.expectEqualStrings("second", failures[1].plugin);
    try testing.expectEqualStrings("Unreadable", failures[1].message);
    const problems = (try r.view(arena.allocator(), "/p")).problems;
    try testing.expectEqual(@as(usize, 2), problems.len);
    try testing.expectEqual(@as(usize, 0), (try r.view(arena.allocator(), "/q")).problems.len);
}

test "tool registration rejects malformed and unsupported schema" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const owner = try r.addPlugin(.{ .id = "x" });
    try testing.expectError(error.SyntaxError, r.addTool(owner, .{ .name = "x", .description = "x", .input_schema = "not JSON", .execute = stubExecute }));
    try testing.expectError(error.InvalidSchema, r.addTool(owner, .{ .name = "x", .description = "x", .input_schema = "{\"$ref\":\"#/foo\"}", .execute = stubExecute }));
    try testing.expectError(error.InvalidSchema, r.addPlugin(.{ .id = "y", .config_schema = "{\"$ref\":\"#/foo\"}" }));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try r.view(arena.allocator(), null)).tool("x") == null);
}

test "swap shows staged replacements and removes others in one step, in staging order" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Fns = struct {
        fn pre(_: ?*anyopaque, _: Allocator, _: Io, _: hook_api.Scope, _: hook_api.Call) anyerror!hook_api.ToolPre {
            return .@"continue";
        }
    };
    const hook: hook_api.Hook = .{ .point = .{ .tool_pre = Fns.pre } };
    const a = try r.addPlugin(.{ .id = "a", .layer = .user });
    try r.addHook(a, hook);
    const b = try r.addPlugin(.{ .id = "b", .layer = .user });
    try r.addHook(b, hook);
    const c = try r.addPlugin(.{ .id = "c", .layer = .user });
    try r.addHook(c, hook);
    const a2 = try r.stage(.{ .id = "a", .layer = .user }, a);
    try r.addHook(a2, hook);
    const b2 = try r.stage(.{ .id = "b", .layer = .user }, b);
    try r.addHook(b2, hook);
    try testing.expectEqual(@as(usize, 3), (try r.view(arena.allocator(), null)).hooks.len);
    r.swap(&.{ a2, b2 }, &.{c});
    const hooks = (try r.view(arena.allocator(), null)).hooks;
    try testing.expectEqual(@as(usize, 2), hooks.len);
    try testing.expectEqualStrings("a", hooks[0].plugin);
    try testing.expectEqualStrings("b", hooks[1].plugin);
}

test "prompt sections apply where their plugin does and go with it" {
    var r: Registry = .init(testing.allocator, testing.io);
    defer r.deinit();
    const owner = try r.addPlugin(.{ .id = "project:docs", .layer = .project, .location = "/p" });
    try r.addSection(owner, .{ .name = "project:docs", .text = "Use the docs tools for API questions." });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try r.view(arena.allocator(), "/elsewhere")).sections.len);
    const here = try r.view(arena.allocator(), "/p");
    try testing.expectEqualStrings("Use the docs tools for API questions.", here.sections[0].value.text);
    r.dispose(owner);
    try testing.expectEqual(@as(usize, 0), (try r.view(arena.allocator(), "/p")).sections.len);
}
