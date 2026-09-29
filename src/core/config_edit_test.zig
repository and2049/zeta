const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const edit = @import("config_edit.zig");
const Value = std.json.Value;
const pathFor = edit.pathFor;
const patchFile = edit.patchFile;
const view = edit.view;
const max_file = 1024 * 1024;

test "patch validates before atomic replacement, removes layer overrides, and keeps unrelated keys" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "user");
    try tmp.dir.createDirPath(io, "project/.zeta");
    try tmp.dir.writeFile(io, .{ .sub_path = "user/zeta.jsonc", .data = "{\"model\":\"p/low\"}" });
    const original = "{ // comment\n \"model\":\"p/high\",\"other\":{\"nested\":42},\"provider\":{\"p\":{\"options\":{\"apiKey\":\"secret\"}}},}";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/.zeta/zeta.jsonc", .data = original });
    const path = try pathFor(a, .project, base, try std.fs.path.join(a, &.{ base, "project" }));
    for ([_][]const u8{
        "{\"tool_timeout_ms\":0}",
        "{\"model\":\"bad\"}",
        "{\"permission\":[{\"action\":\"read\",\"pattern\":\"*\",\"effect\":\"oops\"}]}",
        "{\"provider\":{\"p\":{\"options\":{\"apiKey\":42}}}}",
    }) |bad| {
        const parsed = try std.json.parseFromSliceLeaky(Value, a, bad, .{});
        try std.testing.expectError(error.InvalidConfig, patchFile(a, io, path, parsed));
        const unchanged = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file));
        try std.testing.expectEqualStrings(original, unchanged);
    }
    const patch = try std.json.parseFromSliceLeaky(Value, a, "{\"model\":null,\"provider\":{\"p\":{\"options\":{\"baseURL\":\"https://example.org\"}}}}", .{});
    try patchFile(a, io, path, patch);
    const saved = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file));
    const parsed = try std.json.parseFromSliceLeaky(Value, a, saved, .{});
    try std.testing.expect(parsed.object.get("model") == null);
    try std.testing.expectEqual(@as(i64, 42), parsed.object.get("other").?.object.get("nested").?.integer);
    try std.testing.expectEqualStrings("secret", parsed.object.get("provider").?.object.get("p").?.object.get("options").?.object.get("apiKey").?.string);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const c = try config.load(a, io, &env, try std.fs.path.join(a, &.{ base, "user" }), try std.fs.path.join(a, &.{ base, "project" }));
    try std.testing.expectEqualStrings("p/low", c.model.?);
    try std.testing.expectEqual(config.Source.user, c.source("model").?);
}

test "effective view redacts credentials in provider options and nested model overrides" {
    const a = std.testing.allocator;
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const arena = state.allocator();
    var c: config.Config = .{};
    var provider: config.Provider = .{};
    provider.options = .{ .apiKey = "secret", .baseURL = "https://user:password@host/path" };
    const raw = try std.json.parseFromSliceLeaky(Value, arena, "{\"name\":\"safe\",\"headers\":{\"Authorization\":\"Bearer secret\"},\"nested\":[{\"apiToken\":\"secret\",\"password\":\"secret\"}]}", .{});
    try provider.models.map.put(arena, "model", raw);
    try c.provider.map.put(arena, "p", provider);
    try c.provenance.put(arena, "provider.p.models.model.headers.Authorization", .user);
    const result = try view(arena, c);
    const bytes = try std.json.Stringify.valueAlloc(arena, result, .{});
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "password@host") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[REDACTED]") != null);
    try std.testing.expectEqualStrings("user", result.object.get("provenance").?.object.get("provider.p.models.model.headers.Authorization").?.string);
}

test "new nested objects discard nulls and arrays replace, not merge" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try pathFor(a, .user, base, base);
    const patch = try std.json.parseFromSliceLeaky(Value, a, "{\"provider\":{\"new\":{\"models\":{\"m\":{\"name\":\"ok\",\"token\":null}},\"options\":{\"apiKey\":null,\"baseURL\":\"https://example.org\"}}},\"permission\":[{\"action\":\"read\",\"pattern\":\"*\",\"effect\":\"deny\"}]}", .{});
    try patchFile(a, io, path, patch);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file));
    const saved = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    const provider = saved.object.get("provider").?.object.get("new").?.object;
    try std.testing.expect(provider.get("options").?.object.get("apiKey") == null);
    try std.testing.expect(provider.get("models").?.object.get("m").?.object.get("token") == null);
    const replacement = try std.json.parseFromSliceLeaky(Value, a, "{\"permission\":[]}", .{});
    try patchFile(a, io, path, replacement);
    const next = try std.json.parseFromSliceLeaky(Value, a, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file)), .{});
    try std.testing.expectEqual(@as(usize, 0), next.object.get("permission").?.array.items.len);
}

test "unsupported incoming nested fields fail without changing existing compatible fields" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try pathFor(a, .user, base, base);
    const original = "{\"model\":\"{env:MODEL}\",\"provider\":{\"p\":{\"options\":{\"baseURL\":\"https://example.org\",\"futureOption\":12},\"futureProvider\":true}},\"unrelated\":42}";
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = original });
    for ([_][]const u8{
        "{\"permission\":[{\"action\":\"read\",\"pattern\":\"*\",\"effect\":\"allow\",\"future\":1}]}",
        "{\"provider\":{\"p\":{\"options\":{\"futureOption\":true}}}}",
        "{\"provider\":{\"p\":{\"futureProvider\":true}}}",
    }) |text| {
        const patch = try std.json.parseFromSliceLeaky(Value, a, text, .{});
        try std.testing.expectError(error.InvalidPatch, patchFile(a, io, path, patch));
        try std.testing.expectEqualStrings(original, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file)));
    }
    const valid = try std.json.parseFromSliceLeaky(Value, a, "{\"tool_timeout_ms\":1000}", .{});
    try patchFile(a, io, path, valid);
    const saved = try std.json.parseFromSliceLeaky(Value, a, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file)), .{});
    try std.testing.expectEqualStrings("{env:MODEL}", saved.object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 42), saved.object.get("unrelated").?.integer);
    try std.testing.expectEqual(@as(i64, 12), saved.object.get("provider").?.object.get("p").?.object.get("options").?.object.get("futureOption").?.integer);
}

test "view serializes full u64 timeout without signed overflow" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const result = try view(a, .{ .tool_timeout_ms = std.math.maxInt(u64) });
    const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
    try std.testing.expect(std.mem.indexOf(u8, bytes, "18446744073709551615") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"18446744073709551615\"") == null);
}

test "a substituted thinking level is left for load to check" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.jsonc", .data = "{\"thinking\":\"{env:LEVEL}\"}" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ buf[0..try tmp.dir.realPath(io, &buf)], "zeta.jsonc" });
    try patchFile(a, io, path, try std.json.parseFromSliceLeaky(Value, a, "{\"small_model\":\"p/m\"}", .{}));
    try std.testing.expectError(error.InvalidConfig, patchFile(a, io, path, try std.json.parseFromSliceLeaky(Value, a, "{\"thinking\":\"max\"}", .{})));
}

test "extension env must contain only string values before replacement" {
    const io = std.testing.io;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try pathFor(a, .user, base, base);
    const original = "{\"extensions\":[{\"command\":[\"echo\"],\"env\":{\"KEY\":\"ok\"}}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = original });
    for ([_][]const u8{
        "{\"extensions\":[{\"command\":[\"echo\"],\"env\":{\"KEY\":42}}]}",
        "{\"extensions\":[{\"command\":[\"echo\"],\"env\":null}]}",
        "{\"extensions\":[{\"command\":[],\"env\":{}}]}",
    }) |text| {
        const patch = try std.json.parseFromSliceLeaky(Value, a, text, .{});
        try std.testing.expectError(error.InvalidConfig, patchFile(a, io, path, patch));
        try std.testing.expectEqualStrings(original, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file)));
    }
    const valid = try std.json.parseFromSliceLeaky(Value, a, "{\"extensions\":[{\"command\":[\"echo\"],\"env\":{\"KEY\":\"value\"}}]}", .{});
    try patchFile(a, io, path, valid);
}
