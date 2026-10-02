const std = @import("std");
const core = @import("core");
const proto = @import("proto");
const platform = @import("platform");
const Server = @import("Server.zig");
const Ctx = @import("conn.zig").Ctx;
const query = @import("query.zig");

pub fn credentials(s: *Server, c: *Ctx, provider: ?[]const u8) !void {
    if (provider) |id| {
        if (c.method != .PUT) return c.fail(.method_not_allowed, "method not allowed");
        const body = try c.bodyJson(struct { type: []const u8 = "api", key: []const u8 });
        if (!std.mem.eql(u8, body.type, "api")) return c.fail(.bad_request, "only API keys are supported");
        try platform.credentials.putApiKey(c.arena, c.io, s.data_dir, id, body.key);
        return c.json(.ok, .{ .id = id, .type = "api" });
    }
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    var listing = try platform.credentials.list(c.arena, c.io, s.data_dir);
    defer listing.deinit();
    return c.json(.ok, .{ .providers = listing.items });
}

pub fn stop(s: *Server, c: *Ctx) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    // Flush the receipt before canceling connection tasks.
    try c.json(.ok, .{ .ok = true });
    s.stop_requested.set(c.io);
}

const Context = struct { location: []const u8, options: core.config.Options = .{} };

fn context(s: *Server, c: *Ctx) !Context {
    const session = try query.get(c.arena, c.query, "session");
    const location = try query.get(c.arena, c.query, "location");
    if (session != null and location != null) return error.InvalidQuery;
    if (session) |id| {
        const value = try s.runtime.context(c.arena, id);
        return .{ .location = value.location, .options = value.options };
    }
    return .{ .location = try core.location.resolve(c.arena, c.io, location orelse return error.InvalidQuery) };
}

pub fn read(s: *Server, c: *Ctx, kind: []const u8) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const ctx = try context(s, c);
    var cfg = try core.config.loadWithOptions(c.arena, c.io, s.runtime.env, s.runtime.config_dir, ctx.location, ctx.options);
    // What a new or unpinned session would run with.
    _ = try s.runtime.registry.activate(c.arena, ctx.location);
    try core.runtime_model.fill(s.runtime, c.arena, ctx.location, &cfg);
    if (std.mem.eql(u8, kind, "config")) return c.json(.ok, try core.inspect.configView(s.runtime, c.arena, ctx.location, cfg));
    if (std.mem.eql(u8, kind, "models")) {
        _ = try s.runtime.registry.activate(c.arena, ctx.location);
        const view = try s.runtime.registry.view(c.arena, ctx.location);
        return c.json(.ok, .{ .providers = try core.runtime_route.models(view, c.arena, c.io, cfg) });
    }
    return c.json(.ok, try core.inspect.registry(s.runtime, c.arena, ctx.location, cfg));
}

/// `?location=` or `?session=` → `{"commands": [{name, description,
/// argumentHint?, source}]}`, sorted by name.
pub fn commands(s: *Server, c: *Ctx) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const ctx = try context(s, c);
    const listing = try core.commands.list(s.runtime, c.arena, ctx.location);
    const out = try c.arena.alloc(proto.commands.Info, listing.commands.len);
    for (listing.commands, out) |command, *info| info.* = .{
        .name = command.name,
        .description = command.description,
        .argumentHint = command.argument_hint,
        .source = command.source,
    };
    return c.json(.ok, .{ .commands = out });
}

/// `{"location"?: "/abs/dir"}` → `{"failures": [{plugin, message}]}`.
/// Rebuilds plugins loaded from outside the binary for the user layer and
/// that location (every loaded location when omitted). Running work keeps
/// its snapshot; a plugin that fails keeps its previous version.
pub fn reload(s: *Server, c: *Ctx) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { location: ?[]const u8 = null });
    const location = if (body.location) |loc| try core.location.resolve(c.arena, c.io, loc) else null;
    const failures = try s.runtime.registry.reload(c.arena, location);
    for (failures) |failure| std.log.warn("reload: {s}: {s}", .{ failure.plugin, failure.message });
    return c.json(.ok, .{ .failures = failures });
}

/// `?location=` or `?session=` → `{"<key>": [...]}`: the named loader's
/// status (MCP servers, extensions). Asking loads the location if nothing
/// has yet.
pub fn loaderStatus(s: *Server, c: *Ctx, loader: []const u8, comptime key: []const u8) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const ctx = try context(s, c);
    _ = try s.runtime.registry.activate(c.arena, ctx.location);
    const list = (try s.runtime.registry.loaders.status(c.io, c.arena, loader, ctx.location)) orelse std.json.Value{ .array = .init(c.arena) };
    var result: std.json.ObjectMap = .empty;
    try result.put(c.arena, key, list);
    return c.json(.ok, std.json.Value{ .object = result });
}

/// `{"location": "/abs/project"}`: starts the named thing of that loader
/// again (connects an MCP server, restarts an extension).
pub fn loaderRetry(s: *Server, c: *Ctx, loader: []const u8, name: []const u8, missing: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { location: []const u8 });
    const location = try core.location.resolve(c.arena, c.io, body.location);
    _ = try s.runtime.registry.activate(c.arena, location);
    const found = (try s.runtime.registry.loaders.retry(c.io, loader, location, name)) orelse false;
    if (!found) return c.fail(.not_found, missing);
    return c.json(.ok, .{ .ok = true });
}

/// `POST {"location"}` starts signing in to the named thing of that loader
/// (an MCP server) → `{url, instructions}`; `DELETE ?location=` forgets
/// its sign-in. Either way it connects again.
pub fn loaderAuth(s: *Server, c: *Ctx, loader: []const u8, name: []const u8, missing: []const u8) !void {
    const location = switch (c.method) {
        .POST => try core.location.resolve(c.arena, c.io, (try c.bodyJson(struct { location: []const u8 })).location),
        .DELETE => try core.location.resolve(c.arena, c.io, (try query.get(c.arena, c.query, "location")) orelse return c.fail(.bad_request, "missing location")),
        else => return c.fail(.method_not_allowed, "method not allowed"),
    };
    _ = try s.runtime.registry.activate(c.arena, location);
    const loaders = &s.runtime.registry.loaders;
    if (c.method == .DELETE) {
        const found = loaders.logout(c.io, loader, location, name) catch |err| switch (err) {
            error.McpSignInUnavailable => return c.fail(.bad_request, "this server does not sign in"),
            else => |e| return e,
        };
        if (!(found orelse false)) return c.fail(.not_found, missing);
        return c.json(.ok, .{ .ok = true });
    }
    const started = loaders.login(c.io, c.arena, loader, location, name) catch |err| switch (err) {
        error.McpSignInUnavailable => return c.fail(.bad_request, "this server does not sign in"),
        else => |e| return e,
    };
    const sign_in = started orelse return c.fail(.not_found, missing);
    return c.json(.ok, sign_in);
}

/// `GET ?location=`: the questions plugins have open for the project.
pub fn questions(s: *Server, c: *Ctx) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const raw = (try query.get(c.arena, c.query, "location")) orelse return c.fail(.bad_request, "missing location");
    const location = try core.location.resolve(c.arena, c.io, raw);
    return c.json(.ok, .{ .questions = try s.runtime.questions(c.arena, location) });
}

/// `POST {"action": "accept"|"decline"|"cancel", "content"?: …}`; what
/// `content` holds depends on the question's kind.
pub fn questionReply(s: *Server, c: *Ctx, id: []const u8) !void {
    if (c.method != .POST) return c.fail(.method_not_allowed, "method not allowed");
    const body = try c.bodyJson(struct { action: []const u8, content: ?std.json.Value = null });
    const action = std.meta.stringToEnum(@import("plugin").ask.Action, body.action) orelse return c.fail(.bad_request, "invalid action");
    const content = if (body.content) |v| try std.json.Stringify.valueAlloc(c.arena, v, .{}) else null;
    var problem: []const u8 = "";
    const found = s.runtime.replyQuestion(c.arena, id, action, content, &problem) catch |err| switch (err) {
        error.InvalidContent => return c.fail(.bad_request, problem),
        else => |e| return e,
    };
    if (!found) return c.fail(.not_found, "question not pending");
    return c.json(.ok, .{ .ok = true });
}

pub fn patchConfig(s: *Server, c: *Ctx) !void {
    const body = try c.bodyJson(struct {
        target: core.config_edit.Target,
        location: ?[]const u8 = null,
        patch: std.json.Value,
    });
    const location = if (body.location) |loc| try core.location.resolve(c.arena, c.io, loc) else if (body.target == .project) return error.InvalidQuery else "";
    const path = try core.config_edit.pathFor(c.arena, body.target, s.runtime.config_dir, location);
    s.config_mutex.lockUncancelable(c.io);
    defer s.config_mutex.unlock(c.io);
    const scope: ?[]const u8 = if (body.target == .project) location else null;
    _ = try s.runtime.registry.activate(c.arena, scope);
    const view = try s.runtime.registry.view(c.arena, scope);
    try core.config_edit.patchFileFor(c.arena, c.io, path, body.patch, view.plugins);
    return c.json(.ok, .{ .ok = true });
}
