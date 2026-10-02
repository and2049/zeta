//! Dispatches calls from an extension into its host.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const providers = @import("providers.zig");
const Extension = @import("Extension.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

/// Calls from the extension.
pub fn answer(ctx: ?*anyopaque, arena: Allocator, io: Io, method: []const u8, params: Value) anyerror![]const u8 {
    const e: *Extension = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, method, "log")) {
        const message = field(params, "message") orelse return error.InvalidParams;
        const level = field(params, "level") orelse "info";
        const name = e.name orelse "?";
        if (std.mem.eql(u8, level, "error")) std.log.err("extension {s}: {s}", .{ name, message }) else if (std.mem.eql(u8, level, "warn")) std.log.warn("extension {s}: {s}", .{ name, message }) else std.log.info("extension {s}: {s}", .{ name, message });
        return "null";
    }
    const rt = e.host.runtime orelse return error.Unavailable;
    if (std.mem.eql(u8, method, "registry")) {
        const location = field(params, "location") orelse e.location orelse return error.InvalidParams;
        const cfg = try core.config.load(arena, io, e.host.env, e.host.config_dir, location);
        return std.json.Stringify.valueAlloc(arena, try core.inspect.registry(rt, arena, location, cfg), .{});
    }
    if (std.mem.eql(u8, method, "messages")) {
        const session = field(params, "session") orelse return error.InvalidParams;
        const page = try rt.messages(arena, session, null, 200);
        return std.json.Stringify.valueAlloc(arena, .{ .messages = page.messages, .nextBefore = page.nextBefore }, .{});
    }
    if (std.mem.eql(u8, method, "ask")) return ask(e, arena, io, params);
    if (std.mem.eql(u8, method, "notify")) {
        const asker = rt.asker();
        try asker.notify(asker.ctx, .{
            .location = field(params, "location") orelse e.location orelse return error.InvalidParams,
            .source = e.name orelse "?",
            .message = field(params, "message") orelse return error.InvalidParams,
            .level = if (field(params, "level")) |l| std.meta.stringToEnum(plugin.ask.Level, l) orelse return error.InvalidParams else .info,
            .session = field(params, "session"),
        });
        return "null";
    }
    if (std.mem.eql(u8, method, "credential")) {
        const id = field(params, "provider") orelse return error.InvalidParams;
        return std.json.Stringify.valueAlloc(arena, .{ .apiKey = try providers.credential(e, arena, io, id) }, .{});
    }
    return error.UnknownMethod;
}

/// How long a question waits for the user unless the call says otherwise.
const ask_ms = 5 * 60 * 1000;

/// Puts a question to the user and answers with `{action, content?}`. A
/// question for one of zeta's requests (`request`) keeps that request
/// waiting while it is open and is withdrawn when the request ends.
fn ask(e: *Extension, arena: Allocator, io: Io, params: Value) ![]const u8 {
    const rt = e.host.runtime orelse return error.Unavailable;
    if (params != .object) return error.InvalidParams;
    const kind_name = field(params, "kind") orelse return error.InvalidParams;
    const kind: plugin.ask.Kind = if (std.mem.eql(u8, kind_name, "confirm"))
        .{ .confirm = .{ .detail = field(params, "detail") } }
    else if (std.mem.eql(u8, kind_name, "select"))
        .{ .select = .{ .options = try options(arena, params) } }
    else if (std.mem.eql(u8, kind_name, "input"))
        .{ .input = .{ .placeholder = field(params, "placeholder"), .secret = flag(params, "secret") } }
    else if (std.mem.eql(u8, kind_name, "form"))
        .{ .form = .{ .schema = try std.json.Stringify.valueAlloc(arena, if (params.object.get("schema")) |s| if (s == .object) s else return error.InvalidParams else return error.InvalidParams, .{}) } }
    else
        return error.InvalidParams;
    const process = try e.current();
    const waiter = if (field(params, "request")) |id| process.pin(id) else null;
    defer if (waiter) |w| process.unpin(w);
    const timeout: u64 = switch (params.object.get("timeoutMs") orelse Value{ .integer = ask_ms }) {
        .integer => |ms| if (ms > 0) @intCast(ms) else return error.InvalidParams,
        else => return error.InvalidParams,
    };
    const asker = rt.asker();
    const got = try asker.ask(asker.ctx, arena, io, .{
        .location = field(params, "location") orelse e.location orelse return error.InvalidParams,
        .source = e.name orelse "?",
        .message = field(params, "message") orelse return error.InvalidParams,
        .kind = kind,
        .timeout_ms = timeout,
        .session = field(params, "session"),
        .withdrawn = if (waiter) |w| &w.ended else null,
    });
    const content: ?Value = if (got.content) |c| try std.json.parseFromSliceLeaky(Value, arena, c, .{}) else null;
    return std.json.Stringify.valueAlloc(arena, .{ .action = @tagName(got.action), .content = content }, .{ .emit_null_optional_fields = false });
}

fn options(arena: Allocator, params: Value) ![]const plugin.ask.Option {
    const list = switch (params.object.get("options") orelse return error.InvalidParams) {
        .array => |a| a.items,
        else => return error.InvalidParams,
    };
    const out = try arena.alloc(plugin.ask.Option, list.len);
    for (list, out) |item, *o| o.* = switch (item) {
        .string => |s| .{ .value = s },
        .object => .{ .value = field(item, "value") orelse return error.InvalidParams, .label = field(item, "label") orelse "", .description = field(item, "description") orelse "" },
        else => return error.InvalidParams,
    };
    return out;
}

fn flag(v: Value, name: []const u8) bool {
    const b = v.object.get(name) orelse return false;
    return b == .bool and b.bool;
}

fn field(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
