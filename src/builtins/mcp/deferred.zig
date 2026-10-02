//! Tools of `deferred` servers are not offered to the model one by one:
//! `mcp_search` finds them by words among the run's deferred tools and
//! returns their input schemas, and `mcp_call` runs one by name. The
//! offered tool list stays the same as servers come and go, and schemas
//! cost tokens only when looked up.
const std = @import("std");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// Results a search returns unless it asks for up to `max_results`.
const default_results = 5;
const max_results = 20;

pub const search: plugin.tool.Tool = .{
    .name = "mcp_search",
    .description = "Find MCP tools that are not in your tool list by keywords. Returns matching tool names with their descriptions and input schemas; run one with mcp_call.",
    .input_schema =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Words to match against tool names and descriptions"},"limit":{"type":"integer","minimum":1,"maximum":20}},"required":["query"]}
    ,
    .side_effect = .read,
    .execute = run,
};

pub const call: plugin.tool.Tool = .{
    .name = "mcp_call",
    .description = "Run a tool that mcp_search found, with arguments matching its input schema.",
    .input_schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"The tool's name, e.g. mcp__server__tool"},"arguments":{"type":"object","description":"Arguments for the tool"}},"required":["name"]}
    ,
    .dispatch = true,
    .execute = unused,
};

fn unused(_: ?*anyopaque, _: Allocator, _: Io, _: []const u8, _: Value, _: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    return error.DispatchToolRunDirectly;
}

const Hit = struct { score: usize, tool: plugin.tool.Tool };

fn run(_: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, args: Value, sink: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    const query = args.object.get("query").?.string;
    const limit: usize = if (args.object.get("limit")) |l| if (l == .integer) @intCast(std.math.clamp(l.integer, 1, max_results)) else default_results else default_results;
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n,_-");
    while (it.next()) |word| try words.append(arena, try std.ascii.allocLowerString(arena, word));
    // The run's own tools: what is found here is what mcp_call can run.
    var hits: std.ArrayList(Hit) = .empty;
    for (sink.tools) |tool| {
        if (!tool.deferred) continue;
        const score = try rank(arena, words.items, tool);
        if (score > 0 or words.items.len == 0) try hits.append(arena, .{ .score = score, .tool = tool });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn more(_: void, x: Hit, y: Hit) bool {
            return x.score > y.score or (x.score == y.score and std.mem.lessThan(u8, x.tool.name, y.tool.name));
        }
    }.more);
    const shown = hits.items[0..@min(limit, hits.items.len)];
    var out: std.ArrayList(Value) = .empty;
    for (shown) |hit| {
        var o: std.json.ObjectMap = .empty;
        try o.put(arena, "name", .{ .string = hit.tool.name });
        try o.put(arena, "description", .{ .string = hit.tool.description });
        try o.put(arena, "inputSchema", std.json.parseFromSliceLeaky(Value, arena, hit.tool.input_schema, .{}) catch .{ .object = .empty });
        try out.append(arena, .{ .object = o });
    }
    const text = try std.json.Stringify.valueAlloc(arena, .{ .tools = out.items, .more = hits.items.len - shown.len }, .{});
    return .{ .text = text };
}

/// Words found in the name count three times as much as in the description.
fn rank(arena: Allocator, words: []const []const u8, tool: plugin.tool.Tool) !usize {
    const name = try std.ascii.allocLowerString(arena, tool.name);
    const description = try std.ascii.allocLowerString(arena, tool.description);
    var score: usize = 0;
    for (words) |word| {
        if (std.mem.indexOf(u8, name, word) != null) score += 3;
        if (std.mem.indexOf(u8, description, word) != null) score += 1;
    }
    return score;
}

test rank {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tool: plugin.tool.Tool = .{ .name = "mcp__git__log", .description = "Show the commit history", .input_schema = "{}", .execute = unused };
    try std.testing.expectEqual(@as(usize, 4), try rank(arena.allocator(), &.{ "log", "history" }, tool));
    try std.testing.expectEqual(@as(usize, 0), try rank(arena.allocator(), &.{"weather"}, tool));
}

test "search finds the run's deferred tools only" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools: []const plugin.tool.Tool = &.{
        .{ .name = "mcp__git__log", .description = "Show the commit history", .input_schema = "{\"type\":\"object\"}", .deferred = true, .execute = unused },
        .{ .name = "mcp__git__status", .description = "Working tree state", .input_schema = "{}", .deferred = true, .execute = unused },
        .{ .name = "read", .description = "Read a file's history", .input_schema = "{}", .execute = unused },
    };
    const Sink = struct {
        fn progress(_: *anyopaque, _: []const u8) anyerror!void {}
    };
    var dummy: u8 = 0;
    const result = try run(null, a, std.testing.io, "/p", try std.json.parseFromSliceLeaky(Value, a, "{\"query\":\"history\"}", .{}), .{ .ctx = &dummy, .onProgress = Sink.progress, .tools = tools });
    try std.testing.expectEqualStrings("{\"tools\":[{\"name\":\"mcp__git__log\",\"description\":\"Show the commit history\",\"inputSchema\":{\"type\":\"object\"}}],\"more\":0}", result.text);
}
