const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const load = config.load;
const loadWithOptions = config.loadWithOptions;
const splitModel = config.splitModel;
const Source = config.Source;

test "layers merge and substitute" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    try tmp.dir.createDirPath(io, "cfg");
    try tmp.dir.createDirPath(io, "proj/.zeta");
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/zeta.jsonc", .data =
        \\{ // global
        \\  "model": "a/one",
        \\  "provider": { "a": { "options": { "baseURL": "http://g", "apiKey": "{env:KEY}" } } },
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/key.txt", .data = "from-file\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/zeta.jsonc", .data =
        \\{ "model": "a/two", "provider": { "b": { "options": { "apiKey": "{file:/nonexistent}" } } } }
    });

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("KEY", "sekrit");

    const cfg_dir = try std.fs.path.join(arena, &.{ base, "cfg" });
    const proj = try std.fs.path.join(arena, &.{ base, "proj" });
    try std.testing.expectError(error.FileNotFound, load(arena, io, &env, cfg_dir, proj));

    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/zeta.jsonc", .data =
        \\{ "model": "a/two", "provider": { "b": { "options": { "apiKey": "{file:../../cfg/key.txt}" } } } }
    });
    const c = try load(arena, io, &env, cfg_dir, proj);
    try std.testing.expectEqualStrings("a/two", c.model.?);
    try std.testing.expectEqualStrings("http://g", c.providerOptions("a").baseURL.?);
    try std.testing.expectEqualStrings("sekrit", c.providerOptions("a").apiKey.?);
    try std.testing.expectEqualStrings("from-file", c.providerOptions("b").apiKey.?);
}

test splitModel {
    const m = splitModel("openrouter/meta/llama").?;
    try std.testing.expectEqualStrings("openrouter", m.provider);
    try std.testing.expectEqualStrings("meta/llama", m.model);
    try std.testing.expect(splitModel("nope") == null);
}

test "profiles, CLI, environment precedence and source of nested keys" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "cfg/profiles");
    try tmp.dir.createDirPath(io, "proj/.zeta/profiles");
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/zeta.jsonc", .data =
        \\{"model":"user/one","small_model":"user/small","provider":{"p":{"options":{"apiKey":"secret"},"models":{"m":{"name":"custom","limit":{"context":100}}}}}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/zeta.jsonc", .data =
        \\{"model":"project/two","tool_timeout_ms":300,"inspect_tool":true,"provider":{"p":{"models":{"m":{"limit":{"output":20}}}}}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/profiles/dev.jsonc", .data =
        \\{"model":"user-profile/three","provider":{"p":{"models":{"m":{"name":"profile"}}}}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/profiles/dev.jsonc", .data =
        \\{"model":"project-profile/four","tool_timeout_ms":400}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/profiles/env.jsonc", .data =
        \\{"model":"env-profile/five"}
    });
    const cfg = try std.fs.path.join(arena, &.{ base, "cfg" });
    const proj = try std.fs.path.join(arena, &.{ base, "proj" });
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const profile = try loadWithOptions(arena, io, &env, cfg, proj, .{ .profile = "dev" });
    try std.testing.expectEqualStrings("project-profile/four", profile.model.?);
    try std.testing.expectEqual(Source.project_profile, profile.source("model").?);
    try std.testing.expectEqual(Source.project_profile, profile.source("tool_timeout_ms").?);
    try std.testing.expectEqual(Source.user, profile.source("small_model").?);
    try std.testing.expectEqual(Source.project, profile.source("inspect_tool").?);
    try std.testing.expectEqual(@as(u64, 400), profile.tool_timeout_ms);
    try std.testing.expectEqualStrings("user/small", profile.small_model.?);
    try std.testing.expect(profile.inspect_tool);
    try std.testing.expectEqualStrings("secret", profile.providerOptions("p").apiKey.?);
    const model = profile.provider.map.get("p").?.models.map.get("m").?.object;
    try std.testing.expectEqualStrings("profile", model.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 100), model.get("limit").?.object.get("context").?.integer);
    try std.testing.expectEqual(@as(i64, 20), model.get("limit").?.object.get("output").?.integer);
    try std.testing.expectEqual(Source.user_profile, profile.source("provider.p.models.m.name").?);
    try std.testing.expectEqual(Source.project, profile.source("provider.p.models.m.limit.output").?);
    const cli = try loadWithOptions(arena, io, &env, cfg, proj, .{ .profile = "dev", .model = "cli/six" });
    try std.testing.expectEqualStrings("cli/six", cli.model.?);
    try std.testing.expectEqual(Source.cli, cli.source("model").?);
    try env.put("ZETA_MODEL", "env/seven");
    try env.put("ZETA_PROFILE", "env");
    const chosen = try loadWithOptions(arena, io, &env, cfg, proj, .{ .profile = "dev", .model = "cli/six" });
    try std.testing.expectEqualStrings("env/seven", chosen.model.?);
    try std.testing.expectEqual(Source.env, chosen.source("model").?);
    try std.testing.expectEqual(Source.project, chosen.source("tool_timeout_ms").?);
}

test "profile names cannot escape profile directory and missing profiles fail" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const defaults = try load(arena, io, &env, base, base);
    try std.testing.expectEqual(@as(u64, 120_000), defaults.tool_timeout_ms);
    try std.testing.expectEqual(Source.defaults, defaults.source("tool_timeout_ms").?);
    for ([_][]const u8{ "", "..", "../evil", "a/b", "a.b", "\\bad" }) |name| {
        try std.testing.expectError(error.InvalidProfile, loadWithOptions(arena, io, &env, base, base, .{ .profile = name }));
    }
    try std.testing.expectError(error.ProfileNotFound, loadWithOptions(arena, io, &env, base, base, .{ .profile = "missing" }));
    try env.put("ZETA_PROFILE", "../evil");
    try std.testing.expectError(error.InvalidProfile, loadWithOptions(arena, io, &env, base, base, .{ .profile = "missing" }));
}

test "tool timeout loaded from a file must be positive" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = "{\"tool_timeout_ms\":0}" });
    try std.testing.expectError(error.InvalidConfig, load(a, io, &env, base, base));
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = "{\"tool_timeout_ms\":1}" });
    try std.testing.expectEqual(@as(u64, 1), (try load(a, io, &env, base, base)).tool_timeout_ms);
}

test "request environment supersedes stale daemon selectors, including absent values" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "profiles");
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"model\":\"base/model\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "profiles/new.jsonc", .data = "{\"model\":\"profile/model\"}" });
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZETA_MODEL", "stale/model");
    try env.put("ZETA_PROFILE", "missing");
    const current = try loadWithOptions(arena, io, &env, base, base, .{ .profile = "new", .environment = .{} });
    try std.testing.expectEqualStrings("profile/model", current.model.?);
    try std.testing.expectEqual(Source.user_profile, current.source("model").?);
    const chosen = try loadWithOptions(arena, io, &env, base, base, .{ .profile = "missing", .model = "cli/model", .environment = .{ .profile = "new", .model = "fresh/model" } });
    try std.testing.expectEqualStrings("fresh/model", chosen.model.?);
    try std.testing.expectEqual(Source.env, chosen.source("model").?);
}

test "mcp servers merge across layers and their headers and environment are redacted in the view" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    try tmp.dir.createDirPath(io, "cfg");
    try tmp.dir.createDirPath(io, "proj/.zeta");
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/zeta.jsonc", .data =
        \\{ "mcp": { "servers": { "git": { "type": "local", "command": ["git-mcp"], "environment": { "TOKEN": "{env:KEY}" } } } } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zeta/zeta.jsonc", .data =
        \\{ "mcp": { "servers": { "docs": { "type": "remote", "url": "https://docs.test/mcp", "headers": { "Authorization": "Bearer x" } } } } }
    });
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("KEY", "sekrit");
    const cfg = try load(arena, io, &env, try std.fs.path.join(arena, &.{ base, "cfg" }), try std.fs.path.join(arena, &.{ base, "proj" }));
    const servers = cfg.mcp.object.get("servers").?.object;
    try std.testing.expectEqualStrings("sekrit", servers.get("git").?.object.get("environment").?.object.get("TOKEN").?.string);
    try std.testing.expect(servers.get("docs") != null);
    try std.testing.expectEqual(Source.project, cfg.source("mcp.servers.docs.url").?);
    const shown = try std.json.Stringify.valueAlloc(arena, try @import("config_edit.zig").view(arena, cfg), .{});
    try std.testing.expect(std.mem.indexOf(u8, shown, "sekrit") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Bearer") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "https://docs.test/mcp") != null);
}
