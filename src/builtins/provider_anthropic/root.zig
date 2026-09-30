//! Anthropic Messages SSE transport (`POST <baseURL>/messages`) with an API
//! key. No credential storage here.
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

pub const api_id = "anthropic-messages";
pub const default_base_url = "https://api.anthropic.com/v1";
const version = "2023-06-01";

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
    const key = options.apiKey orelse "";
    if (key.len == 0) {
        try sink.emit(.{ .failure = .{ .message = "Anthropic API key required. Set ANTHROPIC_API_KEY or use /connect." } });
        return error.MissingCredentials;
    }
    const base = std.mem.trimEnd(u8, options.baseURL orelse default_base_url, "/");
    const uri = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/messages", .{base}));
    var body: Io.Writer.Allocating = .init(arena);
    try request.encode(arena, &body.writer, req, options.max_output);
    const pool: *http_pool.Pool = @ptrCast(@alignCast(ctx.?));
    var lease: http_pool.Lease = undefined;
    var response = http_pool.post(pool, &lease, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            // Compressed SSE can stall behind the decompressor's window;
            // the reader below still decodes a server that compresses anyway.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "x-api-key", .value = key },
            .{ .name = "anthropic-version", .value = version },
        },
    }, body.written()) catch |err| return provider_error.report(sink, err);
    defer lease.release();
    exchange(arena, &lease, &response, key, sink) catch |err|
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
        if (data.len == 0) continue;
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        try chunk.handle(scratch.allocator(), arena, &state, data, secret, sink);
        if (state.finished) break;
    }
    if (!state.finished) {
        try sink.emit(.{ .failure = .{ .message = "Anthropic response stream ended before completion", .retryable = true } });
        return error.IncompleteStream;
    }
    try sink.emit(.{ .done = state.stop orelse .stop });
    lease.finish(reader);
}

test {
    _ = request;
    _ = chunk;
    _ = @import("transport_test.zig");
}
