//! Runs registered hooks at each interception point. The chain rules and
//! error policy are described in plugin/hook.zig.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hook = plugin.hook;

pub const Hooks = struct {
    /// In load order, from the run's registry view.
    list: []const plugin.Registry.Resolved(hook.Hook) = &.{},
    scope: hook.Scope = .{ .session = "", .location = "", .provider = "", .model = "" },

    pub const Pre = struct {
        args: std.json.Value,
        rewritten: bool = false,
        /// Set when a hook blocked the call: the reason for the model.
        blocked: ?[]const u8 = null,
    };

    pub fn toolPre(h: Hooks, arena: Allocator, io: Io, call: hook.Call) !Pre {
        var out: Pre = .{ .args = call.args };
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .tool_pre => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, .{ .id = call.id, .name = call.name, .args = out.args }) catch |err| {
                if (err == error.Canceled) return err;
                out.blocked = try std.fmt.allocPrint(arena, "Tool call blocked: a hook from plugin '{s}' failed ({s}).", .{ entry.plugin, @errorName(err) });
                return out;
            };
            switch (action) {
                .@"continue" => {},
                .rewrite => |args| {
                    out.args = args;
                    out.rewritten = true;
                },
                .block => |reason| {
                    out.blocked = reason;
                    return out;
                },
            }
        }
        return out;
    }

    pub fn toolPost(h: Hooks, arena: Allocator, io: Io, call: hook.Call, result: plugin.tool.Result) !plugin.tool.Result {
        var out = result;
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .tool_post => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, call, out) catch |err| {
                try skipped(err, entry.plugin, "tool.post");
                continue;
            };
            if (action == .replace) out = action.replace;
        }
        return out;
    }

    pub fn providerRequest(h: Hooks, arena: Allocator, io: Io, request: plugin.provider.Request) !plugin.provider.Request {
        var out = request;
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .provider_request => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, out) catch |err| {
                try skipped(err, entry.plugin, "provider.request");
                continue;
            };
            if (action == .replace) out = action.replace;
        }
        return out;
    }

    pub fn contextBuild(h: Hooks, arena: Allocator, io: Io, messages: []const proto.Message) ![]const proto.Message {
        var out = messages;
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .context_build => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, out) catch |err| {
                try skipped(err, entry.plugin, "context.build");
                continue;
            };
            if (action == .replace) out = action.replace;
        }
        return out;
    }

    /// Context text from every session_start hook, joined; null if none.
    pub fn sessionStart(h: Hooks, arena: Allocator, io: Io, source: hook.SessionSource) !?[]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .session_start => |f| f,
                else => continue,
            };
            const text = run(entry.value.ctx, arena, io, h.scope, source) catch |err| {
                try skipped(err, entry.plugin, "session.start");
                continue;
            };
            if (text) |t| if (t.len > 0) try parts.append(arena, t);
        }
        return join(arena, parts.items);
    }

    pub const Submitted = struct {
        /// Set when a hook blocked the prompt.
        blocked: ?[]const u8 = null,
        /// Context from every hook before the block, joined.
        context: ?[]const u8 = null,
    };

    pub fn promptSubmit(h: Hooks, arena: Allocator, io: Io, prompt: hook.Prompt) !Submitted {
        var parts: std.ArrayList([]const u8) = .empty;
        var out: Submitted = .{};
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .prompt_submit => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, prompt) catch |err| {
                try skipped(err, entry.plugin, "prompt.submit");
                continue;
            };
            switch (action) {
                .@"continue" => {},
                .context => |text| if (text.len > 0) try parts.append(arena, text),
                .block => |reason| {
                    out.blocked = reason;
                    break;
                },
            }
        }
        out.context = try join(arena, parts.items);
        return out;
    }

    /// The first hook that allows or denies decides; a failing hook denies.
    pub fn permission(h: Hooks, arena: Allocator, io: Io, ask: hook.Ask) !hook.Permission {
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .permission => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, ask) catch |err| {
                if (err == error.Canceled) return err;
                return .{ .deny = try std.fmt.allocPrint(arena, "Permission denied: a hook from plugin '{s}' failed ({s}).", .{ entry.plugin, @errorName(err) }) };
            };
            if (action != .@"continue") return action;
        }
        return .@"continue";
    }

    /// Text for one more step, or null to stop. Only honoured when the
    /// previous stop was not itself continued.
    pub fn turnStop(h: Hooks, arena: Allocator, io: Io, stop: hook.Stop) !?[]const u8 {
        for (h.list) |entry| {
            const run = switch (entry.value.point) {
                .turn_stop => |f| f,
                else => continue,
            };
            const action = run(entry.value.ctx, arena, io, h.scope, stop) catch |err| {
                try skipped(err, entry.plugin, "turn.stop");
                continue;
            };
            if (action == .@"continue" and !stop.continued) return action.@"continue";
        }
        return null;
    }
};

fn join(arena: Allocator, parts: []const []const u8) !?[]const u8 {
    if (parts.len == 0) return null;
    return try std.mem.join(arena, "\n\n", parts);
}

fn skipped(err: anyerror, plugin_id: []const u8, point: []const u8) !void {
    if (err == error.Canceled) return err;
    std.log.warn("{s} hook from plugin '{s}' failed: {s}", .{ point, plugin_id, @errorName(err) });
}

const testing = std.testing;

fn only(comptime point: hook.Point) []const plugin.Registry.Resolved(hook.Hook) {
    return &.{.{ .plugin = "test", .value = .{ .point = point } }};
}

test "tool.pre rewrites chain, the first block wins, and a failure blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fns = struct {
        fn rewrite(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, call: hook.Call) anyerror!hook.ToolPre {
            return .{ .rewrite = .{ .integer = call.args.integer + 1 } };
        }
        fn block(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, call: hook.Call) anyerror!hook.ToolPre {
            return if (call.args.integer >= 2) .{ .block = "too big" } else .@"continue";
        }
        fn fail(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, _: hook.Call) anyerror!hook.ToolPre {
            return error.Broken;
        }
    };
    const chain: []const plugin.Registry.Resolved(hook.Hook) = &.{
        .{ .plugin = "a", .value = .{ .point = .{ .tool_pre = Fns.rewrite } } },
        .{ .plugin = "b", .value = .{ .point = .{ .tool_pre = Fns.block } } },
        .{ .plugin = "c", .value = .{ .point = .{ .tool_pre = Fns.rewrite } } },
    };
    const h: Hooks = .{ .list = chain };
    const once = try h.toolPre(a, testing.io, .{ .id = "1", .name = "t", .args = .{ .integer = 0 } });
    try testing.expect(once.blocked == null and once.rewritten);
    try testing.expectEqual(@as(i64, 2), once.args.integer);
    try testing.expectEqualStrings("too big", (try h.toolPre(a, testing.io, .{ .id = "1", .name = "t", .args = .{ .integer = 1 } })).blocked.?);
    const failing: Hooks = .{ .list = only(.{ .tool_pre = Fns.fail }) };
    const blocked = (try failing.toolPre(a, testing.io, .{ .id = "1", .name = "t", .args = .null })).blocked.?;
    try testing.expect(std.mem.indexOf(u8, blocked, "Broken") != null);
}

test "turn.stop continues once and a failing hook lets the turn stop" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Fns = struct {
        fn again(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, _: hook.Stop) anyerror!hook.TurnStop {
            return .{ .@"continue" = "keep going" };
        }
        fn fail(_: ?*anyopaque, _: Allocator, _: Io, _: hook.Scope, _: hook.Stop) anyerror!hook.TurnStop {
            return error.Broken;
        }
    };
    const reply: proto.Message = .{ .id = "m", .role = .assistant, .content = &.{}, .timestamp = 0 };
    const h: Hooks = .{ .list = only(.{ .turn_stop = Fns.again }) };
    try testing.expectEqualStrings("keep going", (try h.turnStop(arena.allocator(), testing.io, .{ .reply = reply, .continued = false })).?);
    try testing.expect(try h.turnStop(arena.allocator(), testing.io, .{ .reply = reply, .continued = true }) == null);
    const failing: Hooks = .{ .list = only(.{ .turn_stop = Fns.fail }) };
    try testing.expect(try failing.turnStop(arena.allocator(), testing.io, .{ .reply = reply, .continued = false }) == null);
}

test {
    _ = @import("hooks_test.zig");
}
