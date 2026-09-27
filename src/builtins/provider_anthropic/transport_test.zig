//! Loopback transport test: the actual HTTP request and SSE response.
const std = @import("std");
const Io = std.Io;
const plugin = @import("plugin");
const anthropic = @import("root.zig");
const http_pool = @import("../http_pool.zig");

const Fixture = struct {
    listener: Io.net.Server,
    replies: []const Reply,
    issue: ?anyerror = null,
    const Reply = struct { status: []const u8 = "200 OK", body: []const u8 };

    fn serve(self: *Fixture, io: Io) Io.Cancelable!void {
        self.serveChecked(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.issue = err;
        };
    }

    fn serveChecked(self: *Fixture, io: Io) !void {
        for (self.replies) |reply| {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            var input: [16 * 1024]u8 = undefined;
            var output: [16 * 1024]u8 = undefined;
            var reader = stream.reader(io, &input);
            var writer = stream.writer(io, &output);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var req = try server.receiveHead();
            try std.testing.expectEqualStrings("/v1/messages", req.head.target);
            var key: ?[]const u8 = null;
            var version: ?[]const u8 = null;
            var headers = req.iterateHeaders();
            while (headers.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) key = h.value;
                if (std.ascii.eqlIgnoreCase(h.name, "anthropic-version")) version = h.value;
                try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "authorization"));
            }
            try std.testing.expectEqualStrings("sk-ant-test", key.?);
            try std.testing.expectEqualStrings("2023-06-01", version.?);
            var body_buf: [16 * 1024]u8 = undefined;
            const body = try req.readerExpectNone(&body_buf).allocRemaining(std.testing.allocator, .limited(16 * 1024));
            defer std.testing.allocator.free(body);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("claude-test", parsed.value.object.get("model").?.string);
            try std.testing.expectEqual(@as(i64, 4096), parsed.value.object.get("max_tokens").?.integer);
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
        const a = std.testing.allocator;
        switch (ev) {
            .text_delta => |x| try self.out.print(a, "text:{s};", .{x}),
            .thinking_delta => |x| try self.out.print(a, "think:{s};", .{x}),
            .thinking_signature => |x| try self.out.print(a, "sig:{s};", .{x}),
            .tool_call_start => |x| try self.out.print(a, "call:{s}:{s};", .{ x.id, x.name }),
            .tool_call_delta => |x| try self.out.print(a, "args:{s};", .{x.arguments}),
            .usage => |x| try self.out.print(a, "usage:{d}/{d}/{d}/{d};", .{ x.input, x.output, x.cacheRead, x.cacheWrite }),
            .done => |x| try self.out.print(a, "done:{t};", .{x}),
            .failure => |x| try self.out.print(a, "fail:{s}:{?d}:{};", .{ x.message, x.status, x.retryable }),
        }
    }
};

test "streams a reply over HTTP, reports HTTP errors and cut-off streams" {
    const io = std.testing.io;
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var f: Fixture = .{ .listener = try addr.listen(io, .{}), .replies = &.{
        .{ .body = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" ++
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" },
        .{ .status = "529 Overloaded", .body = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}" },
        .{ .body = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n" },
    } };
    defer f.listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &f, io });
    const base = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/", .{f.listener.socket.address.getPort()});
    defer std.testing.allocator.free(base);
    const options: plugin.provider.Options = .{ .baseURL = base, .apiKey = "sk-ant-test", .max_output = 4096 };
    var pool: http_pool.Pool = .init(std.testing.allocator, io);
    defer pool.deinit();
    const api = anthropic.api(&pool);
    var rec: Recorder = .{};
    defer rec.out.deinit(std.testing.allocator);
    const sink: plugin.provider.Sink = .{ .ctx = &rec, .onEvent = Recorder.on };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const req: plugin.provider.Request = .{ .model = "claude-test", .system = "be brief", .messages = &.{
        .{ .id = "u", .role = .user, .timestamp = 0, .content = &.{.{ .text = "hi" }} },
    } };
    try api.stream(api.ctx, arena.allocator(), io, options, req, sink);
    try std.testing.expectEqualStrings("text:hello;usage:7/3/0/0;done:stop;", rec.out.items);
    rec.out.clearRetainingCapacity();
    try std.testing.expectError(error.ProviderHttpError, api.stream(api.ctx, arena.allocator(), io, options, req, sink));
    try std.testing.expectEqualStrings("fail:HTTP 529: Overloaded:529:true;", rec.out.items);
    rec.out.clearRetainingCapacity();
    try std.testing.expectError(error.IncompleteStream, api.stream(api.ctx, arena.allocator(), io, options, req, sink));
    try std.testing.expectEqualStrings("fail:Anthropic response stream ended before completion:null:true;", rec.out.items);
    rec.out.clearRetainingCapacity();
    try std.testing.expectError(error.MissingCredentials, api.stream(api.ctx, arena.allocator(), io, .{ .baseURL = base }, req, sink));
    try group.await(io);
    if (f.issue) |err| return err;
}
