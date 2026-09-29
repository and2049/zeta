//! `elicitation/create` from an MCP server: the message and the form it
//! describes are put to the user through the host; the answer goes back
//! as `{action, content?}`. Only form elicitations are declared; another
//! mode is `error.UnsupportedMode` (JSON-RPC invalid params).
const std = @import("std");
const plugin = @import("plugin");
const Server = @import("Server.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Whose question it is, how long it may wait, and what withdraws it.
pub const Owner = struct {
    session: ?[]const u8 = null,
    timeout_ms: u64,
    withdrawn: ?*std.Io.Event = null,
};

/// The reply to send for request `params`, in `a`.
pub fn answer(s: *Server, a: Allocator, params: Value, owner: Owner) !Value {
    const asker = s.host.asker.?;
    if (params != .object) return decline(a);
    // Only form elicitation is declared; anything else is invalid params.
    if (params.object.get("mode")) |mode| if (mode != .string or !std.mem.eql(u8, mode.string, "form")) return error.UnsupportedMode;
    const message = switch (params.object.get("message") orelse .null) {
        .string => |m| m,
        else => return decline(a),
    };
    const schema = params.object.get("requestedSchema") orelse Value{ .object = .empty };
    if (schema != .object) return decline(a);
    const got = try asker.ask(asker.ctx, a, s.io, .{
        .location = s.location,
        .source = try std.fmt.allocPrint(a, "mcp:{s}", .{s.spec.name}),
        .message = message,
        .schema = try std.json.Stringify.valueAlloc(a, schema, .{}),
        .timeout_ms = owner.timeout_ms,
        .session = owner.session,
        .withdrawn = owner.withdrawn,
    });
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "action", .{ .string = @tagName(got.action) });
    if (got.action == .accept) {
        const content = std.json.parseFromSliceLeaky(Value, a, got.content orelse "{}", .{}) catch return decline(a);
        if (content != .object) return decline(a);
        try out.put(a, "content", content);
    }
    return .{ .object = out };
}

fn decline(a: Allocator) !Value {
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "action", .{ .string = "decline" });
    return .{ .object = out };
}

test "malformed questions decline without asking; another mode is refused" {
    const gpa = std.testing.allocator;
    const Stub = struct {
        var asked: usize = 0;
        fn ask(_: ?*anyopaque, _: Allocator, _: std.Io, q: plugin.ask.Question) anyerror!plugin.ask.Answer {
            asked += 1;
            std.debug.assert(std.mem.eql(u8, q.session.?, "ses_1") and q.timeout_ms == 5);
            return .{ .action = .accept, .content = "{\"x\":1}" };
        }
    };
    var host: Server.Host = .{ .gpa = gpa, .registry = undefined, .env = undefined, .version = "", .asker = .{ .ctx = null, .ask = Stub.ask } };
    var s: Server = .{ .host = &host, .io = std.testing.io, .arena = .init(gpa), .spec = undefined, .location = "/p", .startup_ms = 0 };
    defer s.arena.deinit();
    s.spec.name = "docs";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const owner: Owner = .{ .session = "ses_1", .timeout_ms = 5 };
    for ([_][]const u8{ "[]", "{}", "{\"message\":1}", "{\"message\":\"m\",\"requestedSchema\":[]}" }) |text| {
        const reply = try answer(&s, a, try std.json.parseFromSliceLeaky(Value, a, text, .{}), owner);
        try std.testing.expectEqualStrings("decline", reply.object.get("action").?.string);
    }
    try std.testing.expectError(error.UnsupportedMode, answer(&s, a, try std.json.parseFromSliceLeaky(Value, a, "{\"mode\":\"url\",\"message\":\"m\"}", .{}), owner));
    try std.testing.expectError(error.UnsupportedMode, answer(&s, a, try std.json.parseFromSliceLeaky(Value, a, "{\"mode\":7,\"message\":\"m\"}", .{}), owner));
    try std.testing.expectEqual(@as(usize, 0), Stub.asked);
    const ok = try answer(&s, a, try std.json.parseFromSliceLeaky(Value, a, "{\"message\":\"m\"}", .{}), owner);
    try std.testing.expectEqual(@as(i64, 1), ok.object.get("content").?.object.get("x").?.integer);
    try std.testing.expectEqual(@as(usize, 1), Stub.asked);
}
