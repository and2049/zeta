//! The permission gate a run's tools pass through: rules first, then
//! permission hooks where rules would ask, then the user.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Runtime = @import("Runtime.zig");
const permissions = @import("permissions.zig");
const tool_pipeline = @import("tools.zig");
const tool_permissions = @import("tool_permissions.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Entry = Runtime.Entry;

pub const Gate = struct {
    rt: *Runtime,
    entry: *Entry,
    rules: []const permissions.Rule,
    timeout_ms: u64,
    hooks: @import("hooks.zig").Hooks,

    /// Rules decide first. Where they would ask, permission hooks may answer
    /// instead; otherwise the user is asked. Arguments a hook rewrote are
    /// checked again from the start: a deny rule still denies them, and the
    /// hook's approval stands for what would be asked.
    pub fn check(ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, tool: plugin.tool.Tool, args: *std.json.Value, call: proto.message.ToolCall) anyerror!tool_pipeline.Verdict {
        const gate: *Gate = @ptrCast(@alignCast(ctx.?));
        const first = try gate.evaluate(arena, io, location, tool, args, call, true);
        if (first != .rewritten) return first.verdict();
        const resource = try tool_permissions.resolve(arena, io, location, tool, args.*);
        const req: permissions.Request = .{ .session = gate.entry.session.info.id, .location = location, .action = resource.action, .pattern = resource.pattern, .tool_call_id = call.id };
        if (permissions.decide(req, &.{}, gate.rules, &.{}) == .deny) return .deny;
        if (resource.external) |outside| if (!try gate.ownData(arena, tool, location, outside)) {
            var external = req;
            external.action = "external_directory";
            external.pattern = outside;
            if (permissions.decide(external, &.{}, gate.rules, &.{}) == .deny) return .deny;
        };
        return .allow;
    }

    const Outcome = union(enum) {
        allow,
        deny,
        block: []const u8,
        /// A hook allowed with new arguments (now in `args`).
        rewritten,

        fn verdict(o: Outcome) tool_pipeline.Verdict {
            return switch (o) {
                .allow => .allow,
                .deny, .rewritten => .deny,
                .block => |reason| .{ .block = reason },
            };
        }
    };

    /// Reading this session's saved tool output is not a trip outside the
    /// project; other session data is.
    fn ownData(gate: *Gate, arena: Allocator, tool: plugin.tool.Tool, location: []const u8, path: []const u8) !bool {
        if (tool.side_effect != .read and tool.side_effect != .none) return false;
        const artifacts = @import("artifacts.zig");
        return artifacts.inside(path, try artifacts.dir(arena, gate.rt.sessions_dir, location, gate.entry.session.info.id));
    }

    fn evaluate(gate: *Gate, arena: Allocator, io: Io, location: []const u8, tool: plugin.tool.Tool, args: *std.json.Value, call: proto.message.ToolCall, hooks: bool) !Outcome {
        const resource = try tool_permissions.resolve(arena, io, location, tool, args.*);
        const req: permissions.Request = .{ .session = gate.entry.session.info.id, .location = location, .action = resource.action, .pattern = resource.pattern, .tool_call_id = call.id };
        var requests: [2]permissions.Request = .{ req, req };
        var count: usize = 0;
        if (resource.external) |outside| if (!try gate.ownData(arena, tool, location, outside)) {
            requests[0].action = "external_directory";
            requests[0].pattern = outside;
            count = 1;
        };
        requests[count] = req;
        count += 1;
        const broker = &gate.rt.broker.?;
        for (requests[0..count]) |r| {
            if (hooks and permissions.decide(r, &.{}, gate.rules, &.{}) == .ask and !broker.remembered(r)) {
                switch (try gate.hooks.permission(arena, io, .{ .call = .{ .id = call.id, .name = call.name, .args = args.* }, .action = r.action, .pattern = r.pattern })) {
                    .@"continue" => {},
                    .allow => |rewritten| if (rewritten) |value| {
                        args.* = value;
                        return .rewritten;
                    } else continue,
                    .deny => |reason| return .{ .block = reason },
                }
            }
            if (try broker.evaluate(r, &.{}, gate.rules, &.{}, tool.timeout_ms orelse gate.timeout_ms) != .allow) return .deny;
        }
        return .allow;
    }
};
