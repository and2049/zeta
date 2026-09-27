//! Loopback listener for a browser sign-in redirect.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const queryParam = @import("oauth_http.zig").queryParam;

/// Accepts connections until a GET of `path` carries an authorization code
/// for `state`, returning the code allocated in `a`. Each connection gets
/// `timeout_ms` to send its request; stray or malformed requests never end
/// the wait.
pub fn wait(listener: *Io.net.Server, a: Allocator, io: Io, path: []const u8, state: []const u8, timeout_ms: i64) ![]const u8 {
    while (true) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        const Event = union(enum) { request: anyerror!?[]const u8, deadline: Io.Cancelable!void };
        var storage: [2]Event = undefined;
        var select: Io.Select(Event) = .init(io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.request, read, .{ a, io, stream, path, state });
        try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(timeout_ms), Io.Clock.awake });
        switch (try select.await()) {
            .request => |value| {
                const code = value catch |err| switch (err) {
                    error.Canceled, error.AuthorizationDenied, error.OutOfMemory => return err,
                    // A malformed or broken request on the callback port
                    // (a scanner, a closed tab) cannot end the flow.
                    else => null,
                };
                if (code) |found| return found;
            },
            .deadline => |result| {
                try result;
                // Close only this accepted stream, not the listener.
            },
        }
    }
}

fn read(a: Allocator, io: Io, stream: Io.net.Stream, expected_path: []const u8, expected_state: []const u8) !?[]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var recv: [8192]u8 = undefined;
    var send: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv);
    var writer = stream.writer(io, &send);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch |err| {
        try Io.checkCancel(io);
        return err;
    };
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (request.head.method != .GET or !std.mem.eql(u8, path, expected_path)) {
        try request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
        return null;
    }
    const query = if (path.len < target.len) target[path.len + 1 ..] else "";
    const state = try queryParam(temp, query, "state");
    const code = try queryParam(temp, query, "code");
    if (state != null and std.mem.eql(u8, state.?, expected_state) and
        (try queryParam(temp, query, "error") != null or try queryParam(temp, query, "error_description") != null))
    {
        try request.respond("Authorization was denied.", .{ .status = .bad_request, .keep_alive = false });
        return error.AuthorizationDenied;
    }
    if (state == null or !std.mem.eql(u8, state.?, expected_state) or code == null or code.?.len == 0) {
        try request.respond("Invalid authorization response. Please retry.", .{ .status = .bad_request, .keep_alive = false });
        // A foreign or malformed request cannot consume this flow.
        return null;
    }
    try request.respond("Authorization received. Return to zeta to check that sign-in completes. You can close this window.", .{ .keep_alive = false });
    return try a.dupe(u8, code.?);
}
