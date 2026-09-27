//! ChatGPT OAuth (browser PKCE or headless device authorization). Call `start`
//! before returning the URL/instructions to the user; `finish` may block and
//! should run in a cancelable Io task. A Flow must outlive that task.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const credentials = @import("platform").credentials;
const b64 = std.base64.url_safe_no_pad;
const wire = @import("openai_oauth_http.zig");
const callback_listener = @import("../oauth_callback.zig");
const post = wire.post;
const form = wire.form;
const json = wire.json;
const string = wire.string;
const tokens = wire.tokens;
const tokensWithFallback = wire.tokensWithFallback;

const issuer = "https://auth.openai.com";
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const Options = struct {
    issuer_url: []const u8 = issuer,
    callback_ports: []const u16 = &.{ 1455, 1457 },
    http_timeout_ms: i64 = 15_000,
    callback_timeout_ms: i64 = 5_000,
    polling_margin_ms: i64 = 3_000,
};

pub const Method = enum { browser, device };
pub const Flow = struct {
    arena: std.heap.ArenaAllocator,
    method: Method,
    url: []const u8,
    instructions: []const u8,
    listener: ?Io.net.Server = null,
    redirect: []const u8 = "",
    verifier: []const u8 = "",
    state: []const u8 = "",
    device_id: []const u8 = "",
    user_code: []const u8 = "",
    interval_ms: i64 = 8000,
    options: Options = .{},

    pub fn deinit(self: *Flow, io: Io) void {
        if (self.listener) |*listener| listener.deinit(io);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns slices allocated from `allocator` (free each non-null slice, or
    /// pass an arena allocator and release the arena). Persist with
    /// credentials.putOAuth; cancellation propagates through accept/HTTP/sleep.
    pub fn finish(self: *Flow, allocator: Allocator, io: Io) !credentials.OAuthValue {
        const a = self.arena.allocator();
        var code: []const u8 = undefined;
        var verifier = self.verifier;
        var redirect = self.redirect;
        if (self.method == .browser) {
            const listener = if (self.listener) |*l| l else return error.NoCallbackListener;
            code = try callback_listener.wait(listener, a, io, "/auth/callback", self.state, self.options.callback_timeout_ms);
        } else {
            const request_body = try std.json.Stringify.valueAlloc(a, .{ .device_auth_id = self.device_id, .user_code = self.user_code }, .{});
            while (true) {
                try io.sleep(.fromMilliseconds(self.interval_ms), .awake);
                var scratch: std.heap.ArenaAllocator = .init(a);
                defer scratch.deinit();
                const result = try post(scratch.allocator(), io, try std.fmt.allocPrint(scratch.allocator(), "{s}/api/accounts/deviceauth/token", .{self.options.issuer_url}), "application/json", request_body, true, self.options.http_timeout_ms);
                if (result.status == 403 or result.status == 404) continue;
                try wire.expectSuccess(result.status);
                const value = try json(scratch.allocator(), result.body);
                code = try a.dupe(u8, try string(value, "authorization_code"));
                verifier = try a.dupe(u8, try string(value, "code_verifier"));
                redirect = try std.fmt.allocPrint(a, "{s}/deviceauth/callback", .{self.options.issuer_url});
                break;
            }
        }
        var body: Io.Writer.Allocating = .init(a);
        try form(&body.writer, "grant_type", "authorization_code");
        try form(&body.writer, "code", code);
        try form(&body.writer, "redirect_uri", redirect);
        try form(&body.writer, "client_id", client_id);
        try form(&body.writer, "code_verifier", verifier);
        const result = try post(a, io, try std.fmt.allocPrint(a, "{s}/oauth/token", .{self.options.issuer_url}), "application/x-www-form-urlencoded", body.written(), false, self.options.http_timeout_ms);
        try wire.expectSuccess(result.status);
        const value = try json(a, result.body);
        const borrowed = try tokens(a, io, value);
        const access_token = try allocator.dupe(u8, borrowed.access);
        errdefer allocator.free(access_token);
        const refresh_token = try allocator.dupe(u8, borrowed.refresh);
        errdefer allocator.free(refresh_token);
        return .{
            .access = access_token,
            .refresh = refresh_token,
            .expires = borrowed.expires,
            .account_id = if (borrowed.account_id) |id| try allocator.dupe(u8, id) else null,
        };
    }
};

/// Browser bind tries only loopback 1455 then 1457. Never sends a cancellation
/// request to an existing listener (which may belong to another application).
pub fn start(allocator: Allocator, io: Io, method: Method) !Flow {
    return startWithOptions(allocator, io, method, .{});
}

// Fixture-only seam: not exported, so production credentials cannot be sent
// to a caller-selected issuer URL.
fn startWithOptions(allocator: Allocator, io: Io, method: Method, options: Options) !Flow {
    var flow: Flow = .{ .arena = .init(allocator), .method = method, .url = "", .instructions = "", .options = options };
    errdefer flow.deinit(io);
    const a = flow.arena.allocator();
    if (method == .device) {
        const body = try std.json.Stringify.valueAlloc(a, .{ .client_id = client_id }, .{});
        const response = try post(a, io, try std.fmt.allocPrint(a, "{s}/api/accounts/deviceauth/usercode", .{options.issuer_url}), "application/json", body, false, options.http_timeout_ms);
        try wire.expectSuccess(response.status);
        const value = try json(a, response.body);
        flow.device_id = try string(value, "device_auth_id");
        flow.user_code = try string(value, "user_code");
        const raw_interval = try string(value, "interval");
        const seconds = std.fmt.parseInt(i64, raw_interval, 10) catch 5;
        const interval: i64 = @min(@max(seconds, 1), 60);
        flow.interval_ms = interval * 1000 + options.polling_margin_ms;
        flow.url = try std.fmt.allocPrint(a, "{s}/codex/device", .{options.issuer_url});
        flow.instructions = try std.fmt.allocPrint(a, "Enter code: {s}", .{flow.user_code});
    } else {
        for (options.callback_ports) |port| {
            const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
            flow.listener = addr.listen(io, .{ .reuse_address = false }) catch |err| switch (err) {
                error.AddressInUse => continue,
                else => return err,
            };
            flow.redirect = try std.fmt.allocPrint(a, "http://localhost:{d}/auth/callback", .{flow.listener.?.socket.address.getPort()});
            break;
        }
        if (flow.listener == null) return error.CallbackPortsInUse;
        const auth = try wire.authorize(a, io, options.issuer_url, flow.redirect, client_id);
        flow.state = auth.state;
        flow.verifier = auth.verifier;
        flow.url = auth.url;
        flow.instructions = "Complete authorization in your browser.";
    }
    return flow;
}

/// Reads and automatically refreshes stored OpenAI credentials. Cross-process
/// rotation is serialized by credentials.getFreshOAuth's stable file lock.
pub fn access(allocator: Allocator, io: Io, data_dir: []const u8) !?credentials.OAuth {
    return accessWithOptions(allocator, io, data_dir, .{});
}

fn accessWithOptions(allocator: Allocator, io: Io, data_dir: []const u8, options: Options) !?credentials.OAuth {
    return credentials.getFreshOAuth(allocator, io, data_dir, "openai", options, refresh);
}

fn refresh(options: Options, a: Allocator, io: Io, old: credentials.OAuthValue) !credentials.OAuthValue {
    var body: Io.Writer.Allocating = .init(a);
    try form(&body.writer, "grant_type", "refresh_token");
    try form(&body.writer, "refresh_token", old.refresh);
    try form(&body.writer, "client_id", client_id);
    const result = try post(a, io, try std.fmt.allocPrint(a, "{s}/oauth/token", .{options.issuer_url}), "application/x-www-form-urlencoded", body.written(), false, options.http_timeout_ms);
    try wire.expectSuccess(result.status);
    return try tokensWithFallback(a, io, try json(a, result.body), old.refresh);
}

test "browser PKCE start binds loopback and returns URL before waiting" {
    const io = std.testing.io;
    var flow = try start(std.testing.allocator, io, .browser);
    defer flow.deinit(io);
    try std.testing.expect(std.mem.startsWith(u8, flow.url, issuer ++ "/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "?response_type=code&client_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "state=") != null);
    var pending = try io.concurrent(Flow.finish, .{ &flow, std.testing.allocator, io });
    try std.testing.expectError(error.Canceled, pending.cancel(io));
}

test "access returns persisted unexpired credential without HTTP" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = path[0..try tmp.dir.realPath(io, &path)];
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "token", .refresh = "refresh", .expires = std.math.maxInt(i64) });
    var result = (try access(a, io, data)).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("token", result.access);
}

const Fixture = @import("openai_oauth_fixture.zig").Fixture;

fn callback(io: Io, allocator: Allocator, flow: *Flow, query: []const u8) !std.http.Status {
    const url = try std.fmt.allocPrint(allocator, "{s}?{s}", .{ flow.redirect, query });
    defer allocator.free(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var req = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();
    const response = try req.receiveHead(&.{});
    return response.head.status;
}

test "browser callback validates state and PKCE before token exchange" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init(io);
    fixture.token_encoding = .gzip;
    defer fixture.listener.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &fixture, io });
    const url = try fixture.url(a);
    defer a.free(url);
    var flow = try startWithOptions(a, io, .browser, .{ .issuer_url = url, .callback_ports = &.{0} });
    defer flow.deinit(io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(flow.verifier, &digest, .{});
    var encoded: [b64.Encoder.calcSize(32)]u8 = undefined;
    const challenge = b64.Encoder.encode(&encoded, &digest);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, challenge) != null);
    var pending = try io.concurrent(Flow.finish, .{ &flow, a, io });
    defer _ = pending.cancel(io) catch {};
    // A malformed request on the callback port must not end the flow.
    const garbage = try (try Io.net.IpAddress.parse("127.0.0.1", flow.listener.?.socket.address.getPort())).connect(io, .{ .mode = .stream });
    var garbage_out = garbage.writer(io, &.{});
    try garbage_out.interface.writeAll("NOT HTTP\r\n\r\n");
    garbage.close(io);
    try std.testing.expectEqual(std.http.Status.bad_request, try callback(io, a, &flow, "state=wrong&code=bad"));
    const query = try std.fmt.allocPrint(a, "state={s}&code=real-code", .{flow.state});
    defer a.free(query);
    try std.testing.expectEqual(std.http.Status.ok, try callback(io, a, &flow, query));
    const credential = try pending.await(io);
    defer {
        a.free(credential.access);
        a.free(credential.refresh);
        if (credential.account_id) |id| a.free(id);
    }
    try std.testing.expectEqualStrings("acct", credential.account_id.?);
    const captured = try fixture.snapshot(io, a);
    defer a.free(captured.body);
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "code=real-code") != null);
    const expected_verifier = try std.fmt.allocPrint(a, "code_verifier={s}", .{flow.verifier});
    defer a.free(expected_verifier);
    try std.testing.expect(std.mem.indexOf(u8, captured.body, expected_verifier) != null);
}

test "matching provider denial finishes without token request; idle callback is bounded" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var flow = try startWithOptions(a, io, .browser, .{ .callback_ports = &.{0}, .callback_timeout_ms = 20 });
    defer flow.deinit(io);
    var pending = try io.concurrent(Flow.finish, .{ &flow, a, io });
    defer _ = pending.cancel(io) catch {};
    // A connected client that never sends request headers must not hold the
    // only callback accept loop forever.
    const addr = try Io.net.IpAddress.parse("127.0.0.1", flow.listener.?.socket.address.getPort());
    const slow = try addr.connect(io, .{ .mode = .stream });
    defer slow.close(io);
    try io.sleep(.fromMilliseconds(35), .awake);
    const query = try std.fmt.allocPrint(a, "state={s}&error=access_denied", .{flow.state});
    defer a.free(query);
    try std.testing.expectEqual(std.http.Status.bad_request, try callback(io, a, &flow, query));
    try std.testing.expectError(error.AuthorizationDenied, pending.await(io));
}

test "device polling pending then completion exchanges code" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init(io);
    defer fixture.listener.deinit(io);
    fixture.pending = 1;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &fixture, io });
    const url = try fixture.url(a);
    defer a.free(url);
    var flow = try startWithOptions(a, io, .device, .{ .issuer_url = url, .polling_margin_ms = -999 });
    defer flow.deinit(io);
    try std.testing.expectEqualStrings("Enter code: ABCD", flow.instructions);
    const credential = try flow.finish(a, io);
    defer {
        a.free(credential.access);
        a.free(credential.refresh);
        if (credential.account_id) |id| a.free(id);
    }
    const captured = try fixture.snapshot(io, a);
    defer a.free(captured.body);
    try std.testing.expectEqual(@as(usize, 4), captured.calls);
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "code=device-code") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "code_verifier=verifier") != null);
}

test "refresh retains old refresh token and account when issuer omits both; timeout and cancellation release lock" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init(io);
    defer fixture.listener.deinit(io);
    fixture.token_body = "{\"access_token\":\"updated\",\"expires_in\":3600}";
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &fixture, io });
    const url = try fixture.url(a);
    defer a.free(url);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = path[0..try tmp.dir.realPath(io, &path)];
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "expired", .refresh = "old-refresh", .expires = 0, .account_id = "old-account" });
    var updated = (try accessWithOptions(a, io, data, .{ .issuer_url = url })).?;
    defer updated.deinit();
    try std.testing.expectEqualStrings("updated", updated.access);
    try std.testing.expectEqualStrings("old-refresh", updated.refresh);
    try std.testing.expectEqualStrings("old-account", updated.account_id.?);
    const captured = try fixture.snapshot(io, a);
    defer a.free(captured.body);
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "refresh_token=old-refresh") != null);
    fixture.mutex.lockUncancelable(io);
    fixture.stalled = true;
    fixture.mutex.unlock(io);
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "expired", .refresh = "old-refresh", .expires = 0 });
    try std.testing.expectError(error.OAuthHttpTimeout, accessWithOptions(a, io, data, .{ .issuer_url = url, .http_timeout_ms = 20 }));
    // Refresh timeout must release the sidecar lock and retain old credentials.
    var old = (try credentials.readOAuth(a, io, data, "openai")).?;
    defer old.deinit();
    try std.testing.expectEqualStrings("old-refresh", old.refresh);
    try credentials.putApiKey(a, io, data, "other", "still-writable");
    var pending = try io.concurrent(accessWithOptions, .{ a, io, data, Options{ .issuer_url = url, .http_timeout_ms = 15_000 } });
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    try credentials.putApiKey(a, io, data, "another", "writable-after-cancel");
}

test "refresh rotates persisted token and account on issuer response" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init(io);
    defer fixture.listener.deinit(io);
    fixture.token_body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"id_token\":\"a.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0In0.b\"}";
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Fixture.serve, .{ &fixture, io });
    const url = try fixture.url(a);
    defer a.free(url);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [Io.Dir.max_path_bytes]u8 = undefined;
    const data = path[0..try tmp.dir.realPath(io, &path)];
    try credentials.putOAuth(a, io, data, "openai", .{ .access = "old-access", .refresh = "old-refresh", .expires = 0, .account_id = "old-account" });
    var task_one = try io.concurrent(accessWithOptions, .{ a, io, data, Options{ .issuer_url = url } });
    defer _ = task_one.cancel(io) catch {};
    var task_two = try io.concurrent(accessWithOptions, .{ a, io, data, Options{ .issuer_url = url } });
    defer _ = task_two.cancel(io) catch {};
    var first = (try task_one.await(io)).?;
    defer first.deinit();
    try std.testing.expectEqualStrings("new-refresh", first.refresh);
    try std.testing.expectEqualStrings("acct", first.account_id.?);
    var second = (try task_two.await(io)).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("new-access", second.access);
    const captured = try fixture.snapshot(io, a);
    defer a.free(captured.body);
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
}
