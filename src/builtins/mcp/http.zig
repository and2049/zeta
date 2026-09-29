//! MCP over Streamable HTTP: every message is a POST to the server's URL.
//! The reply is empty (202, for notifications), one JSON message, or an SSE
//! stream of messages; each one goes to the connection. The server may hand
//! out a session id, which later requests carry and `shutdown` ends with a
//! DELETE (given two seconds). A 404 for a session means it expired: the
//! connection is closed. There is no standalone GET stream: server messages
//! arrive only on POST replies.
const std = @import("std");
const proto = @import("proto");
const rpc = @import("rpc.zig");
const config = @import("config.zig");
const http_cause = @import("../http_cause.zig");
const Bearer = @import("auth.zig").Bearer;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const protocol_version = "2025-11-25";

pub const Http = struct {
    gpa: Allocator,
    io: Io,
    conn: *rpc.Connection,
    /// Owned copies.
    url: []u8,
    headers: []std.http.Header,
    strings: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    /// Owned; set by the server's first reply that carries one.
    session: ?[]u8 = null,
    /// Negotiated version, sent on every request after initialization.
    version: ?[]const u8 = null,
    stopped: bool = false,
    /// The server's stored sign-in, when it uses one.
    bearer: ?Bearer = null,

    /// `conn` must outlive the transport; its `transport` is set here.
    /// `bearer` becomes the transport's.
    pub fn start(gpa: Allocator, io: Io, conn: *rpc.Connection, url: []const u8, headers: []const config.Pair, bearer: ?Bearer) !*Http {
        const self = try gpa.create(Http);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .conn = conn, .url = undefined, .headers = undefined, .strings = .init(gpa), .bearer = bearer };
        errdefer self.strings.deinit();
        const a = self.strings.allocator();
        self.url = try a.dupe(u8, url);
        self.headers = try a.alloc(std.http.Header, headers.len);
        for (headers, self.headers) |h, *out| out.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        conn.transport = .{ .ctx = self, .send = send };
        return self;
    }

    /// Records the protocol version the server agreed to.
    pub fn negotiated(self: *Http, version: []const u8) !void {
        const copy = try self.strings.allocator().dupe(u8, version);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.version = copy;
    }

    /// Ends the session (best effort, at most two seconds); later sends
    /// fail. Idempotent.
    pub fn shutdown(self: *Http) void {
        self.mutex.lockUncancelable(self.io);
        const again = self.stopped;
        self.stopped = true;
        self.mutex.unlock(self.io);
        if (again) return;
        const session = (self.sessionCopy(self.gpa) catch null) orelse return;
        defer self.gpa.free(session);
        const Done = union(enum) { deleted: anyerror!void, deadline: Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select: Io.Select(Done) = .init(self.io, &storage);
        defer select.cancelDiscard();
        select.concurrent(.deleted, delete, .{ self, session }) catch return;
        select.concurrent(.deadline, Io.sleep, .{ self.io, Io.Duration.fromMilliseconds(2000), Io.Clock.awake }) catch return;
        _ = select.await() catch {};
    }

    /// Frees the transport after `shutdown`, once nothing can use it.
    pub fn destroy(self: *Http) void {
        if (self.bearer) |*b| b.deinit();
        if (self.session) |s| self.gpa.free(s);
        self.strings.deinit();
        self.gpa.destroy(self);
    }

    fn sessionCopy(self: *Http, a: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.session) |s| try a.dupe(u8, s) else null;
    }

    fn delete(self: *Http, session: []const u8) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var client: std.http.Client = .{ .allocator = arena.allocator(), .io = self.io };
        defer client.deinit();
        const extra = try std.mem.concat(arena.allocator(), std.http.Header, &.{ self.headers, &.{.{ .name = "mcp-session-id", .value = session }} });
        const authorization = if (self.bearer) |*b| try b.cached(arena.allocator()) else null;
        var req = try client.request(.DELETE, try std.Uri.parse(self.url), .{
            .keep_alive = false,
            .headers = .{ .authorization = if (authorization) |value| .{ .override = value } else .default },
            .extra_headers = extra,
        });
        defer req.deinit();
        try req.sendBodiless();
        _ = try req.receiveHead(&.{});
    }

    fn send(ctx: *anyopaque, message: []const u8) anyerror!void {
        const self: *Http = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        const stopped = self.stopped;
        self.mutex.unlock(self.io);
        if (stopped) return error.McpDisconnected;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.appendSlice(arena, self.headers);
        try extra.append(arena, .{ .name = "accept", .value = "application/json, text/event-stream" });
        if (try self.sessionCopy(arena)) |session| try extra.append(arena, .{ .name = "mcp-session-id", .value = session });
        self.mutex.lockUncancelable(self.io);
        const version = self.version;
        self.mutex.unlock(self.io);
        if (version) |v| try extra.append(arena, .{ .name = "mcp-protocol-version", .value = v });

        const id = requestId(arena, message);
        var authorization = if (self.bearer) |*b| try b.header(arena) else null;
        var refreshed = false;
        while (true) {
            self.post(arena, extra.items, authorization, message, id) catch |err| {
                // A refused token gets one refresh; then the server needs
                // a new sign-in.
                if (err != error.McpUnauthorized or refreshed) return err;
                const sent = authorization orelse return err;
                refreshed = true;
                if (!try self.bearer.?.refused(sent)) return err;
                authorization = try self.bearer.?.header(arena);
                continue;
            };
            return;
        }
    }

    fn post(self: *Http, arena: Allocator, headers: []const std.http.Header, authorization: ?[]const u8, message: []const u8, id: ?i64) !void {
        var client: std.http.Client = .{ .allocator = arena, .io = self.io };
        defer client.deinit();
        var req = try client.request(.POST, try std.Uri.parse(self.url), .{
            .keep_alive = false,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
                .authorization = if (authorization) |value| .{ .override = value } else .default,
            },
            .extra_headers = headers,
        });
        defer req.deinit();
        self.exchange(arena, &req, message, id) catch |err| return http_cause.of(&req, err);
    }

    /// The id of an outgoing request; null for a notification or a reply.
    fn requestId(arena: Allocator, message: []const u8) ?i64 {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, message, .{}) catch return null;
        if (v != .object or v.object.get("method") == null) return null;
        return switch (v.object.get("id") orelse return null) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Whether `data` is the response to request `id`.
    fn answers(arena: Allocator, data: []const u8, id: i64) bool {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return false;
        if (v != .object or v.object.get("method") != null) return false;
        const got = v.object.get("id") orelse return false;
        return got == .integer and got.integer == id;
    }

    fn exchange(self: *Http, arena: Allocator, req: *std.http.Client.Request, message: []const u8, id: ?i64) !void {
        req.transfer_encoding = .{ .content_length = message.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(message);
        try body.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        var sse = false;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) try self.remember(h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) sse = std.mem.startsWith(u8, std.mem.trim(u8, h.value, " "), "text/event-stream");
        }
        if (status == .accepted) return;
        if (status == .unauthorized) return error.McpUnauthorized;
        if (status == .not_found and self.hasSession()) {
            self.conn.close("the server's session expired");
            return error.McpSessionExpired;
        }
        if (status.class() != .success) {
            std.log.warn("mcp: {s} answered HTTP {d}", .{ self.url, @intFromEnum(status) });
            return error.McpHttpError;
        }
        var transfer: [64 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        const reader = response.readerDecompressing(&transfer, &decompress, &window);
        if (!sse) {
            const bytes = try reader.allocRemaining(arena, .limited(rpc.max_message));
            if (std.mem.trim(u8, bytes, " \t\r\n").len > 0) self.conn.receive(bytes);
            return;
        }
        var decoder: proto.sse.Decoder = .init(arena);
        while (try decoder.next(reader)) |event| {
            const data = std.mem.trim(u8, event.data, " \t\r\n");
            if (data.len == 0) continue;
            self.conn.receive(data);
            // The stream may stay open after the answer; the request is done.
            if (id) |want| if (answers(arena, data, want)) return;
        }
    }

    fn remember(self: *Http, session: []const u8) !void {
        const copy = try self.gpa.dupe(u8, session);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.session) |old| self.gpa.free(old);
        self.session = copy;
    }

    fn hasSession(self: *Http) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.session != null;
    }
};
