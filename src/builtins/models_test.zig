const std = @import("std");
const Io = std.Io;
const models = @import("models.zig");
const keep = @import("providers/root.zig").catalog_ids;

fn tempPath(tmp: *std.testing.TmpDir, io: Io, buf: *[Io.Dir.max_path_bytes]u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(io, buf)];
}

const cached =
    \\{"openai":{"id":"openai","name":"OpenAI","api":"https://api.test/v1","env":["TEST_TOKEN"],"models":{"small":{"id":"small","name":"Small","limit":{"context":100,"output":20},"cost":{"input":0.5},"reasoning":true,"tool_call":true,"modalities":{"input":["text","image"]}}}}}
;

test "cache boots offline; per-provider model overrides and custom providers own strings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = cached });
    const catalog = try models.Catalog.init(std.testing.allocator, io, .{ .keep = keep, .cache_dir = dir, .refresh = false });
    defer catalog.deinit();
    var overrides: std.json.ArrayHashMap(std.json.Value) = .{};
    defer overrides.deinit(std.testing.allocator);
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const cfg = try std.json.parseFromSliceLeaky(std.json.Value, state.allocator(),
        \\{"small":{"limit":{"context":200},"cost":{"output":2.5},"reasoning":false},"custom":{"name":"Custom","tool_call":true}}
    , .{});
    try overrides.map.put(std.testing.allocator, "openai", cfg);
    const extra = try std.json.parseFromSliceLeaky(std.json.Value, state.allocator(),
        \\{"new":{"name":"From config","modalities":{"input":["audio"]}}}
    , .{});
    try overrides.map.put(std.testing.allocator, "private", extra);
    var changed = (try catalog.snapshot(std.testing.allocator, &overrides)).?;
    defer changed.deinit();
    state.deinit(); // Snapshot cannot borrow override strings.
    const provider = changed.provider("openai").?;
    try std.testing.expectEqualStrings("https://api.test/v1", provider.baseURL.?);
    try std.testing.expectEqualStrings("TEST_TOKEN", provider.env[0]);
    try std.testing.expectEqual(@as(usize, 2), provider.models.len);
    try std.testing.expectEqual(@as(u64, 200), provider.models[0].context);
    try std.testing.expectEqual(@as(u64, 20), provider.models[0].output_limit);
    try std.testing.expectEqual(@as(f64, 0.5), provider.models[0].cost.input);
    try std.testing.expectEqual(@as(f64, 2.5), provider.models[0].cost.output);
    try std.testing.expect(!provider.models[0].reasoning);
    try std.testing.expect(provider.models[1].tool_call);
    try std.testing.expectEqualStrings("private", changed.provider("private").?.id);
    try std.testing.expectEqualStrings("audio", changed.provider("private").?.models[0].modalities_input[0]);
    var original = (try catalog.snapshot(std.testing.allocator, null)).?;
    defer original.deinit();
    try std.testing.expectEqual(@as(u64, 100), original.provider("openai").?.models[0].context);
    try std.testing.expect(original.provider("private") == null);
}

test "missing or invalid cache uses empty baseline only for overrides" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = "[invalid" });
    const catalog = try models.Catalog.init(std.testing.allocator, io, .{ .keep = keep, .cache_dir = dir, .refresh = false });
    defer catalog.deinit();
    try std.testing.expect((try catalog.snapshot(std.testing.allocator, null)) == null);
    var overrides: std.json.ArrayHashMap(std.json.Value) = .{};
    defer overrides.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"local":{"name":"Local","limit":{"context":4096}}}
    , .{});
    try overrides.map.put(std.testing.allocator, "private", cfg);
    var snapshot = (try catalog.snapshot(std.testing.allocator, &overrides)).?;
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 4096), snapshot.provider("private").?.models[0].context);
}

test "old full cache is compacted on load; unsupported metadata excluded but configured models survive" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &buf);
    const full =
        \\{"openai":{"name":"OpenAI","description":"unused verbose metadata","models":{"small":{"name":"Small","description":"unused model metadata","limit":{"context":99,"unused":7},"cost":{"input":0.5,"unused":9},"tool_call":true}}},"mistral":{"name":"Unsupported","models":{"x":{"name":"External"}}}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = full });
    const catalog = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .refresh = false });
    defer catalog.deinit();
    const compacted = try tmp.dir.readFileAlloc(io, "models.json", a, .limited(4096));
    defer a.free(compacted);
    try std.testing.expect(compacted.len < full.len);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "description") == null);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "mistral") == null);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "unused") == null);
    var snapshot = (try catalog.snapshot(a, null)).?;
    defer snapshot.deinit();
    try std.testing.expect(snapshot.provider("mistral") == null);
    try std.testing.expectEqual(@as(u64, 99), snapshot.provider("openai").?.models[0].context);
    var overrides: std.json.ArrayHashMap(std.json.Value) = .{};
    defer overrides.deinit(a);
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const cfg = try std.json.parseFromSliceLeaky(std.json.Value, state.allocator(),
        \\{"own":{"name":"Configured"}}
    , .{});
    try overrides.map.put(a, "mistral", cfg);
    var configured = (try catalog.snapshot(a, &overrides)).?;
    defer configured.deinit();
    try std.testing.expectEqualStrings("Configured", configured.provider("mistral").?.models[0].name);
}

const Fixture = struct {
    listener: Io.net.Server,
    response: []const u8,
    stall: bool = false,
    accepted: Io.Event = .unset,
    saw_etag: bool = false,

    fn serve(f: *Fixture, io: Io) Io.Cancelable!void {
        const stream = f.listener.accept(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        defer stream.close(io);
        f.accepted.set(io);
        if (f.stall) {
            // Deliberately withhold even response headers; cancel must interrupt
            // receiveHead, not wait for the remote endpoint to time out.
            try io.sleep(.fromSeconds(60), .awake);
        } else {
            var recv: [4096]u8 = undefined;
            var reader = stream.reader(io, &recv);
            while (true) {
                const line = (reader.interface.takeDelimiter('\n') catch break) orelse break;
                if (std.ascii.startsWithIgnoreCase(line, "if-none-match: \"fixture-v1\"")) f.saw_etag = true;
                if (std.mem.eql(u8, line, "\r")) break;
            }
            var buffer: [1024]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            writer.interface.writeAll(f.response) catch return Io.checkCancel(io);
            writer.interface.flush() catch return Io.checkCancel(io);
        }
    }
};

fn fixture(io: Io, response: []const u8, stall: bool) !Fixture {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    return .{ .listener = try addr.listen(io, .{}), .response = response, .stall = stall };
}

test "ETag survives restart; 304 preserves cache and never uses validator without matching cache" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &path);
    const data = "{\"openai\":{\"models\":{\"gpt\":{\"name\":\"GPT\"}}}}";
    const first_response = try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ data.len, data });
    defer a.free(first_response);
    var endpoint = try fixture(io, first_response, false);
    defer endpoint.listener.deinit(io);
    const address = try url(&endpoint, a);
    defer a.free(address);
    {
        const catalog = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
        defer catalog.deinit();
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
        try catalog.refreshNow();
        try group.await(io);
        try std.testing.expect(!endpoint.saw_etag);
    }
    endpoint.response = "HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    {
        const catalog = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
        defer catalog.deinit();
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
        try catalog.refreshNow();
        try group.await(io);
        try std.testing.expect(endpoint.saw_etag);
        var snapshot = (try catalog.snapshot(a, null)).?;
        defer snapshot.deinit();
        try std.testing.expectEqualStrings("GPT", snapshot.provider("openai").?.models[0].name);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = "broken" });
    endpoint.saw_etag = false;
    const invalid = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
    defer invalid.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
    try std.testing.expectError(error.CatalogHttpError, invalid.refreshNow());
    try group.await(io);
    try std.testing.expect(!endpoint.saw_etag);
}

fn url(f: *Fixture, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api.json", .{f.listener.socket.address.getPort()});
}

test "local HTTP refresh replaces cache; failed HTTP response preserves previous snapshot and file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = cached });
    const refreshed = "{\"deepseek\":{\"name\":\"New\",\"env\":[\"NEW_KEY\"],\"models\":{}}}";
    const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ refreshed.len, refreshed });
    defer std.testing.allocator.free(response);
    var endpoint = try fixture(io, response, false);
    defer endpoint.listener.deinit(io);
    const address = try url(&endpoint, std.testing.allocator);
    defer std.testing.allocator.free(address);
    const catalog = try models.Catalog.init(std.testing.allocator, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
    defer catalog.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
    try catalog.refreshNow();
    try group.await(io);
    var snapshot = (try catalog.snapshot(std.testing.allocator, null)).?;
    defer snapshot.deinit();
    try std.testing.expect(snapshot.provider("openai") == null);
    try std.testing.expectEqualStrings("NEW_KEY", snapshot.provider("deepseek").?.env[0]);
    const bytes = try tmp.dir.readFileAlloc(io, "models.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(refreshed, bytes);

    // A non-2xx local endpoint leaves both the in-memory and on-disk cache.
    var failed = try fixture(io, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", false);
    defer failed.listener.deinit(io);
    const failed_url = try url(&failed, std.testing.allocator);
    defer std.testing.allocator.free(failed_url);
    const offline = try models.Catalog.init(std.testing.allocator, io, .{ .keep = keep, .cache_dir = dir, .url = failed_url, .refresh = false });
    defer offline.deinit();
    var second: Io.Group = .init;
    defer second.cancel(io);
    try second.concurrent(io, Fixture.serve, .{ &failed, io });
    try std.testing.expectError(error.CatalogHttpError, offline.refreshNow());
    try second.await(io);
    var old = (try offline.snapshot(std.testing.allocator, null)).?;
    defer old.deinit();
    try std.testing.expect(old.provider("deepseek") != null);
}

test "deinit cancels stalled local HTTP response without losing offline cache" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "models.json", .data = cached });
    var endpoint = try fixture(io, "", true);
    defer endpoint.listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
    const address = try url(&endpoint, std.testing.allocator);
    defer std.testing.allocator.free(address);
    const catalog = try models.Catalog.init(std.testing.allocator, io, .{ .keep = keep, .cache_dir = dir, .url = address });
    const before = try tmp.dir.readFileAlloc(io, "models.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(before);
    try endpoint.accepted.wait(io);
    catalog.deinit(); // would wait a full minute if receiveHead ignored cancellation
    const bytes = try tmp.dir.readFileAlloc(io, "models.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(before, bytes);
}

test "compressed catalog refresh exposes new models and persists decoded JSON" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const data =
        \\{"openai":{"models":{"gpt-5.6-luna":{"name":"GPT-5.6 Luna"},"gpt-6-astra":{"name":"GPT-6 Astra"}}}}
    ;
    inline for (.{ .gzip, .zlib }) |container| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir = try tempPath(&tmp, io, &path);
        var compressed: [4096]u8 = undefined;
        var output = Io.Writer.fixed(&compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var encoder = try std.compress.flate.Compress.init(&output, &window, container, .default);
        try encoder.writer.writeAll(data);
        try encoder.finish();
        const response = try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Encoding: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            if (container == .gzip) "gzip" else "deflate", output.buffered().len, output.buffered(),
        });
        defer a.free(response);
        var endpoint = try fixture(io, response, false);
        defer endpoint.listener.deinit(io);
        const address = try url(&endpoint, a);
        defer a.free(address);
        const catalog = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
        defer catalog.deinit();
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
        try catalog.refreshNow();
        try group.await(io);
        var snapshot = (try catalog.snapshot(a, null)).?;
        defer snapshot.deinit();
        const available = snapshot.provider("openai").?.models;
        try std.testing.expectEqual(@as(usize, 2), available.len);
        try std.testing.expectEqualStrings("gpt-6-astra", available[1].id);
        const cached_bytes = try tmp.dir.readFileAlloc(io, "models.json", a, .limited(4096));
        defer a.free(cached_bytes);
        try std.testing.expectEqualStrings(data, cached_bytes);
    }
}

test "download stores only supported providers and consumed model metadata" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tempPath(&tmp, io, &path);
    const full =
        \\{"openai":{"api":"https://example.test","description":"unused","models":{"gpt":{"name":"GPT","description":"unused","limit":{"context":42,"extra":500},"tool_call":true}}},"fake":{"models":{"x":{"name":"X"}}}}
    ;
    const response = try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ full.len, full });
    defer a.free(response);
    var endpoint = try fixture(io, response, false);
    defer endpoint.listener.deinit(io);
    const address = try url(&endpoint, a);
    defer a.free(address);
    const catalog = try models.Catalog.init(a, io, .{ .keep = keep, .cache_dir = dir, .url = address, .refresh = false });
    defer catalog.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &endpoint, io });
    try catalog.refreshNow();
    try group.await(io);
    const slim = try tmp.dir.readFileAlloc(io, "models.json", a, .limited(4096));
    defer a.free(slim);
    try std.testing.expect(slim.len < full.len);
    try std.testing.expect(std.mem.indexOf(u8, slim, "fake") == null);
    try std.testing.expect(std.mem.indexOf(u8, slim, "description") == null);
    var snapshot = (try catalog.snapshot(a, null)).?;
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 42), snapshot.provider("openai").?.models[0].context);
}
