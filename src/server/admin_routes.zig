const std = @import("std");
const core = @import("core");
const Server = @import("Server.zig");
const Ctx = @import("conn.zig").Ctx;
const query = @import("query.zig");

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
