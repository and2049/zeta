const std = @import("std");
const plugin = @import("plugin");
const html = @import("html.zig");

const max_download = 1024 * 1024;
const max_redirects = 3;
const max_location = 8 * 1024;

pub const tool: plugin.tool.Tool = .{
    .name = "webfetch",
    .description = "Fetch an HTTP(S) URL and return readable text (HTML converted to Markdown).",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"],\"additionalProperties\":false}",
    .side_effect = .network,
    .permission = .{ .target = .url, .arg = "url" },
    .execute = execute,
};

fn execute(_: ?*anyopaque, arena: std.mem.Allocator, io: std.Io, _: []const u8, args: std.json.Value, host: plugin.tool.ProgressSink) anyerror!plugin.tool.Result {
    if (args != .object) return .{ .text = "Expected URL", .isError = true };
    const url = args.object.get("url") orelse return .{ .text = "Expected URL", .isError = true };
    if (url != .string or !isHttp(url.string)) return .{ .text = "Only HTTP(S) URLs are supported", .isError = true };
    var uri = std.Uri.parse(url.string) catch return .{ .text = "Invalid URL", .isError = true };
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    // Redirects are followed here rather than by std.http, so that every hop
    // passes the same permission check as the requested URL.
    var hops: usize = 0;
    while (true) {
        var req = try client.request(.GET, uri, .{ .keep_alive = false, .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            if (hops == max_redirects) return .{ .text = "Too many redirects", .isError = true };
            hops += 1;
            const location = response.head.location orelse return .{ .text = "Invalid redirect location", .isError = true };
            if (location.len > max_location) return .{ .text = "Invalid redirect location", .isError = true };
            const next = redirect(arena, uri, location) catch return .{ .text = "Invalid redirect location", .isError = true };
            const target = try std.fmt.allocPrint(arena, "{f}", .{next.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })});
            if (!isHttp(target)) return .{ .text = "Only HTTP(S) URLs are supported", .isError = true };
            var hop_args: std.json.ObjectMap = .empty;
            try hop_args.put(arena, "url", .{ .string = target });
            if (!try host.permit(.{ .object = hop_args })) return error.PermissionDenied;
            uri = next;
            continue;
        }
        return read(arena, &response);
    }
}

fn isHttp(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

/// Resolves `location` against `base`; the result borrows `arena`, which
/// outlives the response head that `location` points into.
fn redirect(arena: std.mem.Allocator, base: std.Uri, location: []const u8) !std.Uri {
    var aux = try arena.alloc(u8, location.len + max_location);
    @memcpy(aux[0..location.len], location);
    return base.resolveInPlace(location.len, &aux);
}

fn read(arena: std.mem.Allocator, response: *std.http.Client.Response) !plugin.tool.Result {
    // Header slices borrow the request's receive buffer, which body reads
    // overwrite. Decide this before consuming the body.
    const html_content_type = if (response.head.content_type) |content_type|
        std.ascii.startsWithIgnoreCase(content_type, "text/html")
    else
        false;
    var transfer: [16 * 1024]u8 = undefined;
    // std.http advertises gzip/deflate; the download cap applies to decoded bytes.
    var decompress: std.http.Decompress = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, &window);
    if (response.head.status.class() != .success) return .{ .text = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(response.head.status)}), .isError = true };
    const bytes = reader.allocRemaining(arena, .limited(max_download)) catch |err| switch (err) {
        error.StreamTooLong => return .{ .text = "Response exceeds 1 MiB download limit", .isError = true },
        else => |e| return e,
    };
    const is_html = html_content_type or
        std.mem.indexOf(u8, bytes, "<html") != null or
        std.mem.indexOf(u8, bytes, "<!DOCTYPE html") != null or
        std.mem.indexOf(u8, bytes, "<body") != null;
    return .{ .text = if (is_html) try html.markdown(arena, bytes) else bytes };
}

test "rejects non-HTTP schemes" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "url", .{ .string = "file:///secret" });
    const result = try tool.execute(null, std.testing.allocator, std.testing.io, ".", .{ .object = args }, undefined);
    try std.testing.expect(result.isError);
}

test "relative and absolute redirect locations resolve against the current URL" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.Uri.parse("http://a.test/dir/page?q=1");
    const flags: std.Uri.Format.Flags = .{ .scheme = true, .authority = true, .path = true, .query = true };
    const relative = try redirect(a, base, "../moved");
    try std.testing.expectEqualStrings("http://a.test/moved", try std.fmt.allocPrint(a, "{f}", .{relative.fmt(flags)}));
    const absolute = try redirect(a, base, "https://b.test/x");
    try std.testing.expectEqualStrings("https://b.test/x", try std.fmt.allocPrint(a, "{f}", .{absolute.fmt(flags)}));
}
