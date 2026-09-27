//! ChatGPT Codex Responses SSE transport. No credential storage or refresh here.
const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const request = @import("request.zig");
const chunk = @import("chunk.zig");
const http_cause = @import("../http_cause.zig");
const http_pool = @import("../http_pool.zig");
const provider_error = @import("../provider_error.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const api_id = "openai-codex";
pub const default_base_url = "https://chatgpt.com/backend-api/codex";
/// `pool` must outlive every request.
pub fn api(pool: *http_pool.Pool) plugin.provider.Api {
    return .{ .id = api_id, .ctx = pool, .stream = stream };
}

fn stream(
    ctx: ?*anyopaque,
    arena: Allocator,
    io: Io,
    options: plugin.provider.Options,
    req: plugin.provider.Request,
    sink: plugin.provider.Sink,
) anyerror!void {
    // The callback is invoked for every model request, not cached for a turn.
    const credentials: plugin.provider.Credentials = if (options.authentication) |auth|
        auth.resolve(auth.ctx, arena, io) catch |err| {
            if (err == error.Canceled) return err;
            try sink.emit(.{ .failure = .{ .message = "Could not load or refresh ChatGPT authentication. Retry or sign in again." } });
            return err;
        }
    else
        .{ .apiKey = options.apiKey orelse "", .account_id = options.account_id };
    if (credentials.apiKey.len == 0) {
        try sink.emit(.{ .failure = .{ .message = "ChatGPT authentication required. Sign in to continue." } });
        return error.MissingCredentials;
    }
    const base = std.mem.trimEnd(u8, options.baseURL orelse default_base_url, "/");
    const uri = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/responses", .{base}));
    var body: Io.Writer.Allocating = .init(arena);
    try request.encode(&body.writer, req);
    const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{credentials.apiKey});
    const pool: *http_pool.Pool = @ptrCast(@alignCast(ctx.?));
    var lease: http_pool.Lease = undefined;
    var response = http_pool.post(pool, &lease, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = authorization },
            // Compressed SSE can stall behind the decompressor's window;
            // the reader below still decodes a server that compresses anyway.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = if (credentials.account_id) |id| &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "originator", .value = "zeta" },
            .{ .name = "chatgpt-account-id", .value = id },
        } else &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "originator", .value = "zeta" },
        },
    }, body.written()) catch |err| return provider_error.report(sink, err);
    defer lease.release();
    exchange(arena, &lease, &response, credentials.apiKey, sink) catch |err|
        return provider_error.report(sink, http_cause.of(&lease.req, err));
}

fn exchange(arena: Allocator, lease: *http_pool.Lease, response: *std.http.Client.Response, secret: []const u8, sink: plugin.provider.Sink) !void {
    // Head bytes are invalidated once the body reader starts.
    const retry_after = provider_error.retryAfter(response.head);
    var transfer_buf: [64 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &window);
    if (response.head.status.class() != .success) {
        const detail = try http_cause.errorBody(arena, &lease.req, reader, 64 * 1024);
        try sink.emit(.{ .failure = try provider_error.http(arena, @intFromEnum(response.head.status), detail, secret, retry_after) });
        return error.ProviderHttpError;
    }
    var decoder: proto.sse.Decoder = .init(arena);
    defer decoder.deinit();
    var state: chunk.State = .{};
    defer state.deinit(arena);
    while (try decoder.next(reader)) |event| {
        const data = std.mem.trim(u8, event.data, " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        try chunk.handle(scratch.allocator(), arena, &state, data, sink);
        if (state.finish != null) break;
    }
    const finish = state.finish orelse {
        try sink.emit(.{ .failure = .{ .message = "Codex response stream ended before completion", .retryable = true } });
        return error.IncompleteStream;
    };
    try sink.emit(.{ .done = finish });
    lease.finish(reader);
}

test {
    _ = request;
    _ = chunk;
    _ = @import("transport_test.zig");
}
