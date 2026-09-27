//! OpenAI-compatible chat completions provider (OpenAI, DeepSeek, GLM,
//! OpenRouter, llama.cpp, vLLM, …). Streams over SSE.

const std = @import("std");
const proto = @import("proto");
const plugin = @import("plugin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const request = @import("request.zig");
const chunk = @import("chunk.zig");
const http_cause = @import("../http_cause.zig");
const http_pool = @import("../http_pool.zig");
const provider_error = @import("../provider_error.zig");

pub const api_id = "openai-compatible";
pub const default_base_url = "https://api.openai.com/v1";
const max_error_body = 64 * 1024;

/// `pool` must outlive every request.
pub fn api(pool: *http_pool.Pool) plugin.provider.Api {
    return .{ .id = api_id, .ctx = pool, .stream = stream };
}

fn stream(
    ctx: ?*anyopaque,
    arena: Allocator,
    _: Io,
    options: plugin.provider.Options,
    req: plugin.provider.Request,
    sink: plugin.provider.Sink,
) anyerror!void {
    const base = std.mem.trimEnd(u8, options.baseURL orelse default_base_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{base});
    const uri = try std.Uri.parse(url);

    var body: Io.Writer.Allocating = .init(arena);
    try request.encode(&body.writer, req, if (options.cache_key) req.session_id else null);

    const auth: ?[]const u8 = if (options.apiKey) |k|
        if (k.len > 0) try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) else null
    else
        null;

    const pool: *http_pool.Pool = @ptrCast(@alignCast(ctx.?));
    var lease: http_pool.Lease = undefined;
    var response = http_pool.post(pool, &lease, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (auth) |a| .{ .override = a } else .omit,
            // Compressed SSE can stall behind the decompressor's window;
            // the reader below still decodes a server that compresses anyway.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    }, body.written()) catch |err| return provider_error.report(sink, err);
    defer lease.release();
    exchange(arena, &lease, &response, options.apiKey, sink) catch |err|
        return provider_error.report(sink, http_cause.of(&lease.req, err));
}

fn exchange(arena: Allocator, lease: *http_pool.Lease, response: *std.http.Client.Response, secret: ?[]const u8, sink: plugin.provider.Sink) !void {
    // Head bytes are invalidated once the body reader starts.
    const retry_after = provider_error.retryAfter(response.head);
    var transfer_buf: [64 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &window);

    if (response.head.status.class() != .success) {
        const detail = try http_cause.errorBody(arena, &lease.req, reader, max_error_body);
        try sink.emit(.{ .failure = try provider_error.http(arena, @intFromEnum(response.head.status), detail, secret, retry_after) });
        return error.ProviderHttpError;
    }

    var decoder: proto.sse.Decoder = .init(arena);
    var state: chunk.State = .{};
    var saw_done = false;
    while (try decoder.next(reader)) |ev| {
        const data = std.mem.trim(u8, ev.data, " ");
        if (std.mem.eql(u8, data, "[DONE]")) {
            saw_done = true;
            break;
        }
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        try chunk.handle(scratch.allocator(), &state, data, secret, sink);
    }
    // A reply without finish_reason is incomplete, [DONE] or not.
    const finish = state.finish orelse {
        try sink.emit(.{ .failure = .{
            .message = if (saw_done) "stream finished without a finish_reason" else "stream ended before completion",
            .retryable = true,
        } });
        return error.IncompleteStream;
    };
    try sink.emit(.{ .done = finish });
    lease.finish(reader);
}

test {
    _ = request;
    _ = chunk;
}
