//! Loopback transport test: verifies the actual HTTP request and SSE response.
const std = @import("std");
const Io = std.Io;
const plugin = @import("plugin");
const codex = @import("root.zig");
const http_pool = @import("../http_pool.zig");

const Fixture = struct {
    listener: Io.net.Server,
    replies: []const Reply,
    issue: ?anyerror = null,
    validate_continuation: bool = true,
    const Reply = struct { status: []const u8 = "200 OK", body: []const u8 };

    fn serve(self: *Fixture, io: Io) Io.Cancelable!void {
        self.serveChecked(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.issue = err;
        };
    }

    fn serveChecked(self: *Fixture, io: Io) !void {
        for (self.replies, 0..) |reply, round| {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            var input: [16 * 1024]u8 = undefined;
            var output: [16 * 1024]u8 = undefined;
            var reader = stream.reader(io, &input);
            var writer = stream.writer(io, &output);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var req = try server.receiveHead();
            try std.testing.expectEqual(std.http.Method.POST, req.head.method);
            try std.testing.expectEqualStrings("/codex/responses", req.head.target);
            try std.testing.expectEqualStrings("application/json", req.head.content_type.?);
            var auth: ?[]const u8 = null;
            var account: ?[]const u8 = null;
            var accept: ?[]const u8 = null;
            var origin: ?[]const u8 = null;
            var headers = req.iterateHeaders();
            while (headers.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = h.value;
                if (std.ascii.eqlIgnoreCase(h.name, "chatgpt-account-id")) account = h.value;
                if (std.ascii.eqlIgnoreCase(h.name, "accept")) accept = h.value;
                if (std.ascii.eqlIgnoreCase(h.name, "originator")) origin = h.value;
            }
            const expected_key = try std.fmt.allocPrint(std.testing.allocator, "Bearer fresh-{d}", .{round + 1});
            defer std.testing.allocator.free(expected_key);
            try std.testing.expectEqualStrings(expected_key, auth.?);
            try std.testing.expectEqualStrings("account", account.?);
            try std.testing.expectEqualStrings("text/event-stream", accept.?);
            try std.testing.expectEqualStrings("zeta", origin.?);
            var body_buf: [16 * 1024]u8 = undefined;
            const body = try req.readerExpectNone(&body_buf).allocRemaining(std.testing.allocator, .limited(16 * 1024));
            defer std.testing.allocator.free(body);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expectEqualStrings("gpt-5.5", obj.get("model").?.string);
            try std.testing.expect(!obj.get("store").?.bool);
            try std.testing.expect(obj.get("stream").?.bool);
            try std.testing.expectEqualStrings("be helpful", obj.get("instructions").?.string);
            try std.testing.expectEqualStrings("read", obj.get("tools").?.array.items[0].object.get("name").?.string);
            const input_items = obj.get("input").?.array.items;
            try std.testing.expectEqualStrings("input_image", input_items[0].object.get("content").?.array.items[1].object.get("type").?.string);
            try std.testing.expectEqualStrings("data:image/png;base64,YWJj", input_items[0].object.get("content").?.array.items[1].object.get("image_url").?.string);
            try std.testing.expectEqualStrings("reasoning.encrypted_content", obj.get("include").?.array.items[0].string);
            if (self.validate_continuation and round == 1) {
                try std.testing.expectEqualStrings("reasoning", input_items[1].object.get("type").?.string);
                try std.testing.expectEqualStrings("enc", input_items[1].object.get("encrypted_content").?.string);
                try std.testing.expectEqualStrings("function_call", input_items[2].object.get("type").?.string);
                try std.testing.expectEqualStrings("call-1", input_items[2].object.get("call_id").?.string);
                try std.testing.expectEqualStrings("function_call_output", input_items[3].object.get("type").?.string);
                try std.testing.expectEqualStrings("ok", input_items[3].object.get("output").?.string);
            }
            const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 {s}\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ reply.status, reply.body.len, reply.body });
            defer std.testing.allocator.free(response);
            try writer.interface.writeAll(response);
            try writer.interface.flush();
        }
    }
};

const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    fn on(ctx: *anyopaque, ev: plugin.provider.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const text = switch (ev) {
            .text_delta => |x| try std.fmt.allocPrint(std.testing.allocator, "text:{s};", .{x}),
            .thinking_delta => |x| try std.fmt.allocPrint(std.testing.allocator, "think:{s};", .{x}),
            .thinking_signature => |x| try std.fmt.allocPrint(std.testing.allocator, "sig:{s};", .{x}),
            .tool_call_start => |x| try std.fmt.allocPrint(std.testing.allocator, "call:{s}:{s};", .{ x.id, x.name }),
            .tool_call_delta => |x| try std.fmt.allocPrint(std.testing.allocator, "args:{s};", .{x.arguments}),
            .usage => |x| try std.fmt.allocPrint(std.testing.allocator, "usage:{d}/{d}/{d};", .{ x.input, x.output, x.cacheRead }),
            .done => |x| try std.fmt.allocPrint(std.testing.allocator, "done:{t};", .{x}),
            .failure => |x| try std.fmt.allocPrint(std.testing.allocator, "fail:{s};", .{x.message}),
        };
        defer std.testing.allocator.free(text);
        try self.out.appendSlice(std.testing.allocator, text);
    }
};

const Authentication = struct {
    calls: usize = 0,
    fn resolve(ctx: ?*anyopaque, _: std.mem.Allocator, _: Io) anyerror!plugin.provider.Credentials {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return .{ .apiKey = switch (self.calls) {
            1 => "fresh-1",
            2 => "fresh-2",
            else => "fresh-3",
        }, .account_id = "account" };
    }
};

fn endpoint(f: *Fixture, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/codex", .{f.listener.socket.address.getPort()});
}

const user: @import("proto").Message = .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{
    .{ .text = "look" }, .{ .image = .{ .mimeType = "image/png", .data = "YWJj" } },
} };

test "local HTTP SSE refreshes auth for tool continuation and stops at terminal event" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var f: Fixture = .{ .listener = try addr.listen(io, .{}), .replies = &.{
        .{ .body = "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"hmm\"}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[],\"encrypted_content\":\"enc\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"read\"}}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n" ++
            "data: {invalid json}\n\n" },
        .{ .body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{}}\n\n" },
    } };
    defer f.listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &f, io });
    const base = try endpoint(&f, std.testing.allocator);
    defer std.testing.allocator.free(base);
    var auth: Authentication = .{};
    const options: plugin.provider.Options = .{ .baseURL = base, .apiKey = "stale", .authentication = .{ .ctx = &auth, .resolve = Authentication.resolve } };
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    const api = codex.api(&pool);
    var rec: Recorder = .{};
    defer rec.out.deinit(std.testing.allocator);
    const tools: []const plugin.provider.ToolDecl = &.{.{ .name = "read", .description = "Read", .parameters = "{\"type\":\"object\"}" }};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sink: plugin.provider.Sink = .{ .ctx = &rec, .onEvent = Recorder.on };
    try api.stream(api.ctx, arena.allocator(), io, options, .{ .model = "gpt-5.5", .system = "be helpful", .messages = &.{user}, .tools = tools }, sink);
    try std.testing.expectEqualStrings("think:hmm;sig:{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[],\"encrypted_content\":\"enc\"};call:call-1:read;args:{};usage:7/3/2;done:tool_use;", rec.out.items);
    rec.out.clearRetainingCapacity();
    const call: @import("proto").Message = .{ .id = "a", .role = .assistant, .timestamp = 0, .content = &.{
        .{ .thinking = .{ .text = "hmm", .signature = "{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[],\"encrypted_content\":\"enc\"}" } },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = "{}" } },
    } };
    const result: @import("proto").Message = .{ .id = "t", .role = .tool_result, .timestamp = 0, .toolCallId = "call-1", .content = &.{.{ .text = "ok" }} };
    try api.stream(api.ctx, arena.allocator(), io, options, .{ .model = "gpt-5.5", .system = "be helpful", .messages = &.{ user, call, result }, .tools = tools }, sink);
    try std.testing.expectEqualStrings("text:done;done:stop;", rec.out.items);
    try std.testing.expectEqual(@as(usize, 2), auth.calls);
    try group.await(io);
    if (f.issue) |err| return err;
}

test "local HTTP SSE distinguishes length from incomplete failure and failed event" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var f: Fixture = .{ .listener = try addr.listen(io, .{}), .validate_continuation = false, .replies = &.{
        .{ .body = "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n" },
        .{ .body = "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"content_filter\"}}}\n\n" },
        .{ .body = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"quota\"}}}\n\n" },
    } };
    defer f.listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &f, io });
    const base = try endpoint(&f, std.testing.allocator);
    defer std.testing.allocator.free(base);
    var auth: Authentication = .{};
    const options: plugin.provider.Options = .{ .baseURL = base, .authentication = .{ .ctx = &auth, .resolve = Authentication.resolve } };
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    const api = codex.api(&pool);
    var rec: Recorder = .{};
    defer rec.out.deinit(std.testing.allocator);
    const sink: plugin.provider.Sink = .{ .ctx = &rec, .onEvent = Recorder.on };
    const req: plugin.provider.Request = .{ .model = "gpt-5.5", .system = "be helpful", .messages = &.{user}, .tools = &.{.{ .name = "read", .description = "Read", .parameters = "{\"type\":\"object\"}" }} };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try api.stream(api.ctx, arena.allocator(), io, options, req, sink);
    try std.testing.expectEqualStrings("done:length;", rec.out.items);
    rec.out.clearRetainingCapacity();
    try std.testing.expectError(error.IncompleteResponse, api.stream(api.ctx, arena.allocator(), io, options, req, sink));
    try std.testing.expectEqualStrings("fail:content_filter;", rec.out.items);
    rec.out.clearRetainingCapacity();
    try std.testing.expectError(error.ProviderError, api.stream(api.ctx, arena.allocator(), io, options, req, sink));
    try std.testing.expectEqualStrings("fail:quota;", rec.out.items);
    try std.testing.expectEqual(@as(usize, 3), auth.calls);
    try group.await(io);
    if (f.issue) |err| return err;
}
