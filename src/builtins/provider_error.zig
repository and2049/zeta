//! Classified, sanitized provider failures. Raw response bodies never leave
//! this file: only a short message extracted from them, with control bytes
//! removed and the request's credential redacted. Retry classification
//! retries 429/5xx and transient network errors; quota exhaustion is
//! terminal even as a 429). A request too long for the model's context is
//! marked `overflow` from the wording services use for it.
const std = @import("std");
const plugin = @import("plugin");
const Allocator = std.mem.Allocator;
const Failure = plugin.provider.Failure;

pub const max_message = 512;

/// A non-success HTTP response. `body` is at most the caller's read limit.
pub fn http(arena: Allocator, status: u16, body: []const u8, secret: ?[]const u8, retry_after_ms: ?u64) !Failure {
    const detail = try clean(arena, extract(arena, body), secret);
    // The raw body can carry a code (`context_length_exceeded`) that the
    // message leaves out.
    const too_long = status >= 400 and status < 500 and status != 429 and !rateLimited(body) and (overflow(detail) or overflow(body));
    return .{
        .message = if (detail.len > 0)
            try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, detail })
        else
            try std.fmt.allocPrint(arena, "HTTP {d}", .{status}),
        .status = status,
        .retryable = !too_long and retryableStatus(status, detail),
        .retry_after_ms = retry_after_ms,
        .overflow = too_long,
    };
}

/// An error event inside a stream (`{"error":…}` chunk, `response.failed`).
/// `event` is the whole event, whose type or code may mark a rate limit.
pub fn stream(arena: Allocator, detail: []const u8, event: []const u8, secret: ?[]const u8) !Failure {
    const text = try clean(arena, detail, secret);
    if (!rateLimited(event) and overflow(detail)) return .{ .message = text, .overflow = true };
    return .{ .message = text, .retryable = transient(text) and !terminal(text) };
}

/// Wording of context-overflow errors across services. Rate limits that
/// mention tokens are not overflow. A bare 413 is not either: it can be a
/// request-size limit that compacting would not fix.
pub fn overflow(text: []const u8) bool {
    if (rateLimited(text)) return false;
    if (containsAny(text, &.{
        "prompt is too long",                             "prompt too long",                    "request_too_large",                 "input is too long for requested model",
        "exceeds the context window",                     "maximum context length",             "context_length_exceeded",           "context length exceeded",
        "context length is only",                         "maximum prompt length is",           "reduce the length of the messages", "maximum allowed input length",
        "is longer than the model",                       "exceeds the available context size", "greater than the context length",   "context window exceeds limit",
        "exceeded model token limit",                     "model_context_window_exceeded",      "the configured context size is",    "range of input length should be",
        "tokens in request more than max tokens allowed", "too many tokens",                    "token limit exceeded",
    })) return true;
    return containsAny(text, &.{"input token count"}) and containsAny(text, &.{"exceeds the maximum"});
}

/// A transport error with no response to describe it, or null when `err`
/// is not a network condition (the loop then records its name).
pub fn transport(err: anyerror) ?Failure {
    const transient_errors = [_]anyerror{
        error.ConnectionRefused,     error.ConnectionResetByPeer, error.ConnectionTimedOut,
        error.NetworkUnreachable,    error.HostUnreachable,       error.TemporaryNameServerFailure,
        error.NameServerFailure,     error.BrokenPipe,            error.EndOfStream,
        error.HttpConnectionClosing,
    };
    for (transient_errors) |candidate| if (err == candidate) return .{ .message = @errorName(err), .retryable = true };
    return null;
}

/// Records a transport error as a retryable failure, then returns it for the
/// provider to return. Other errors pass through untouched.
pub fn report(sink: plugin.provider.Sink, err: anyerror) anyerror {
    if (transport(err)) |failure| sink.emit(.{ .failure = failure }) catch {};
    return err;
}

/// `retry-after-ms` (milliseconds) or `retry-after` (delta seconds). An
/// HTTP-date is ignored and the loop's backoff applies.
pub fn retryAfter(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    var seconds: ?u64 = null;
    while (it.next()) |h| {
        const value = std.mem.trim(u8, h.value, " ");
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms")) {
            return std.fmt.parseInt(u64, value, 10) catch continue;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            seconds = std.fmt.parseInt(u64, value, 10) catch continue;
        }
    }
    return if (seconds) |s| s *| std.time.ms_per_s else null;
}

pub fn rateLimited(text: []const u8) bool {
    return containsAny(text, &.{ "rate limit", "rate_limit", "too many requests", "throttl" });
}

fn retryableStatus(status: u16, detail: []const u8) bool {
    return switch (status) {
        429 => !terminal(detail),
        408, 500, 502, 503, 504, 529 => true,
        else => transient(detail),
    };
}

fn transient(text: []const u8) bool {
    return containsAny(text, &.{ "rate limit", "rate_limit", "overloaded", "service unavailable", "server_error", "try again" });
}

fn terminal(text: []const u8) bool {
    return containsAny(text, &.{ "insufficient_quota", "quota exceeded", "usage limit", "billing", "available balance" });
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    return false;
}

/// The API's own message when the body is a JSON error, else the body text.
fn extract(arena: Allocator, body: []const u8) []const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return body;
    if (value != .object) return body;
    const root = value.object;
    if (root.get("error")) |e| switch (e) {
        .string => |s| return s,
        .object => |o| if (o.get("message")) |m| if (m == .string) return m.string,
        else => {},
    };
    for ([_][]const u8{ "message", "detail" }) |key| if (root.get(key)) |m| if (m == .string) return m.string;
    return body;
}

/// Single line, bounded, credential redacted.
fn clean(arena: Allocator, text: []const u8, secret: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (rest.len > 0 and out.items.len < max_message) {
        if (secret) |key| if (key.len >= 8 and std.mem.startsWith(u8, rest, key)) {
            try out.appendSlice(arena, "[redacted]");
            rest = rest[key.len..];
            continue;
        };
        const byte = rest[0];
        try out.append(arena, if (byte < 0x20 or byte == 0x7f) ' ' else byte);
        rest = rest[1..];
    }
    var end = @min(out.items.len, max_message);
    while (end > 0 and end < out.items.len and (out.items[end] & 0xc0) == 0x80) end -= 1;
    return std.mem.trim(u8, out.items[0..end], " ");
}

test "HTTP failures keep the API message, redact the key, and classify retries" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const key = "sk-secret-123456";
    const invalid = try http(a, 401, "{\"error\":{\"message\":\"Incorrect API key provided: sk-secret-123456.\\nSee docs.\",\"type\":\"invalid_request_error\"}}", key, null);
    try std.testing.expectEqualStrings("HTTP 401: Incorrect API key provided: [redacted]. See docs.", invalid.message);
    try std.testing.expect(!invalid.retryable);
    try std.testing.expectEqual(@as(?u16, 401), invalid.status);

    const limited = try http(a, 429, "{\"error\":{\"message\":\"Rate limit reached\"}}", key, 2000);
    try std.testing.expect(limited.retryable);
    try std.testing.expectEqual(@as(?u64, 2000), limited.retry_after_ms);
    try std.testing.expect(!(try http(a, 429, "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota, check billing\"}}", key, null)).retryable);
    try std.testing.expect((try http(a, 503, "<html>upstream down</html>", null, null)).retryable);
    try std.testing.expect(!(try http(a, 400, "{\"error\":\"bad request\"}", null, null)).retryable);

    const huge = try a.alloc(u8, 10_000);
    @memset(huge, 'x');
    try std.testing.expect((try http(a, 500, huge, null, null)).message.len <= max_message + "HTTP 500: ".len);
}

test "stream errors and transport errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try stream(a, "The server is overloaded, try again", "", null)).retryable);
    try std.testing.expect(!(try stream(a, "Invalid tool schema", "", null)).retryable);
    try std.testing.expect(transport(error.ConnectionResetByPeer).?.retryable);
    try std.testing.expect(transport(error.OutOfMemory) == null);
}

test "context overflow is recognized from messages and codes, not from rate limits or a bare 413" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const anthropic = try http(a, 400, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 213462 tokens > 200000 maximum\"}}", null, null);
    try std.testing.expect(anthropic.overflow and !anthropic.retryable);
    // The code is in the body, not in the message.
    try std.testing.expect((try http(a, 400, "{\"error\":{\"message\":\"Invalid request\",\"code\":\"context_length_exceeded\"}}", null, null)).overflow);
    try std.testing.expect((try http(a, 400, "the request exceeds the available context size, try increasing it", null, null)).overflow);
    try std.testing.expect(!(try http(a, 413, "", null, null)).overflow);
    try std.testing.expect(!(try http(a, 429, "{\"error\":{\"message\":\"Rate limit: too many tokens per minute\"}}", null, null)).overflow);
    try std.testing.expect(!(try http(a, 500, "maximum context length exceeded", null, null)).overflow);
    const streamed = try stream(a, "Your input exceeds the context window of this model.", "", null);
    try std.testing.expect(streamed.overflow and !streamed.retryable);
    try std.testing.expect(!(try stream(a, "Too many tokens", "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Too many tokens\"}}", null)).overflow);
    try std.testing.expect(overflow("The input token count (1196265) exceeds the maximum number of tokens allowed"));
    try std.testing.expect(!overflow("Invalid tool schema"));
    // A rate limit named only in the error's type, and limits compaction cannot fix.
    try std.testing.expect(!(try http(a, 400, "{\"error\":{\"message\":\"Too many tokens\",\"type\":\"rate_limit_error\"}}", null, null)).overflow);
    try std.testing.expect(!(try http(a, 400, "{\"error\":{\"message\":\"The number of tools exceeds the limit of 128\"}}", null, null)).overflow);
    try std.testing.expect(!(try http(a, 400, "{\"error\":{\"message\":\"max_tokens is too large: 200000\"}}", null, null)).overflow);
}
