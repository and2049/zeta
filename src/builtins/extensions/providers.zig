//! Model providers an extension declares. Each is a provider registration
//! plus a transport (`ext:<extension>:<provider>`) whose stream is a
//! `stream` request; the reply comes back as events.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const platform = @import("platform");
const Extension = @import("Extension.zig");
const Process = @import("Process.zig");
const register = @import("register.zig");
const models = @import("../models.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

const api_key = [_]plugin.provider.AuthMethod{.{ .id = "api", .label = "API key", .type = "api" }};

const Ref = struct {
    ext: *Extension,
    decl: register.Provider,
    api: []const u8,
};

/// Registers the declared providers and their transports for `owner`.
pub fn add(e: *Extension, v: Allocator, owner: plugin.Registry.Owner, reg: register.Registration) !void {
    const r = e.host.registry;
    for (reg.providers) |decl| {
        const ref = try v.create(Ref);
        ref.* = .{ .ext = e, .decl = decl, .api = try std.fmt.allocPrint(v, "ext:{s}:{s}", .{ reg.name, decl.id }) };
        try r.addApi(owner, .{ .id = ref.api, .ctx = ref, .stream = stream });
        try r.addProvider(owner, .{ .id = decl.id, .name = decl.name, .auth_methods = &api_key, .ctx = ref, .resolve = resolve, .models = listing });
    }
}

/// The key for provider `id`: config, then a saved key, then its variables.
fn key(e: *Extension, arena: Allocator, io: Io, decl: register.Provider, configured: ?[]const u8) !?[]const u8 {
    if (configured) |k| return k;
    if (e.host.data_dir) |dir| if (try platform.credentials.readKey(arena, io, dir, decl.id)) |k| return k;
    for (decl.env) |name| if (e.host.env.get(name)) |k| return k;
    return null;
}

/// The `credential` call: only for this extension's own providers.
pub fn credential(e: *Extension, arena: Allocator, io: Io, id: []const u8) !?[]const u8 {
    const decl = blk: {
        const v = try e.host.registry.view(arena, e.location);
        for (v.providers) |p| if (std.mem.eql(u8, p.value.id, id) and std.mem.eql(u8, p.plugin, e.name orelse "")) {
            const ref: *Ref = @ptrCast(@alignCast(p.value.ctx.?));
            break :blk ref.decl;
        };
        return error.NotYourProvider;
    };
    const cfg = try core.config.load(arena, io, e.host.env, e.host.config_dir, e.location orelse e.host.home);
    return key(e, arena, io, decl, cfg.providerOptions(id).apiKey);
}

fn resolve(ctx: ?*anyopaque, arena: Allocator, io: Io, q: plugin.provider.Query) anyerror!plugin.provider.Route {
    const ref: *Ref = @ptrCast(@alignCast(ctx.?));
    const configured = q.options(ref.decl.id);
    const model: register.Model = for (ref.decl.models) |m| {
        if (std.mem.eql(u8, m.id, q.model)) break m;
    } else .{ .id = q.model, .name = q.model };
    var route: plugin.provider.Route = .{ .api = ref.api, .options = .{
        .baseURL = configured.baseURL,
        .apiKey = try key(ref.ext, arena, io, ref.decl, configured.apiKey),
        .accepts_images = model.images,
        .context_window = model.context,
        .reasoning = model.reasoning,
    } };
    if (configured.models == .object) if (configured.models.object.get(q.model)) |override|
        @import("../providers/shared.zig").thinkingOverride(&route.options, override);
    return route;
}

fn listing(ctx: ?*anyopaque, arena: Allocator, _: Io, _: plugin.provider.Query) anyerror![]const Value {
    const ref: *Ref = @ptrCast(@alignCast(ctx.?));
    const list = try arena.alloc(models.Model, ref.decl.models.len);
    for (ref.decl.models, list) |m, *out| out.* = .{
        .id = m.id,
        .name = m.name,
        .context = m.context,
        .output_limit = m.output,
        .attachment = m.images,
        .tool_call = true,
        .modalities_input = if (m.images) &.{ "text", "image" } else &.{"text"},
    };
    const entry: models.Provider = .{ .id = ref.decl.id, .name = ref.decl.name, .env = ref.decl.env, .models = list };
    return arena.dupe(Value, &.{try std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, entry, .{}), .{})});
}

const Relay = struct {
    sink: plugin.provider.Sink,

    fn event(ctx: ?*anyopaque, v: Value) anyerror!void {
        const self: *Relay = @ptrCast(@alignCast(ctx.?));
        if (v != .object) return;
        const o = v.object;
        if (o.get("text")) |t| if (t == .string) try self.sink.emit(.{ .text_delta = t.string });
        if (o.get("thinking")) |t| if (t == .string) try self.sink.emit(.{ .thinking_delta = t.string });
        if (o.get("toolCall")) |call| if (call == .object) {
            const index: u32 = switch (call.object.get("index") orelse .null) {
                .integer => |i| std.math.cast(u32, i) orelse return error.InvalidToolCallIndex,
                else => 0,
            };
            const id = str(call, "id");
            const name = str(call, "name");
            if (id != null or name != null) try self.sink.emit(.{ .tool_call_start = .{ .index = index, .id = id orelse "", .name = name orelse "" } });
            if (str(call, "arguments")) |args| try self.sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments = args } });
        };
        if (o.get("usage")) |u| if (u == .object) try self.sink.emit(.{ .usage = .{
            .input = count(u, "input"),
            .output = count(u, "output"),
            .cacheRead = count(u, "cacheRead"),
            .cacheWrite = count(u, "cacheWrite"),
        } });
    }
};

fn stream(ctx: ?*anyopaque, arena: Allocator, _: Io, options: plugin.provider.Options, req: plugin.provider.Request, sink: plugin.provider.Sink) anyerror!void {
    const ref: *Ref = @ptrCast(@alignCast(ctx.?));
    const process = ref.ext.current() catch |err| {
        try sink.emit(.{ .failure = .{ .message = "the extension providing this model is not running" } });
        return err;
    };
    var relay: Relay = .{ .sink = sink };
    var failure: Process.Failure = .{};
    // Tool parameters go out as schema objects, not as their JSON text.
    const tools = try arena.alloc(struct { name: []const u8, description: []const u8, parameters: Value }, req.tools.len);
    for (req.tools, tools) |t, *out| out.* = .{
        .name = t.name,
        .description = t.description,
        .parameters = try std.json.parseFromSliceLeaky(Value, arena, t.parameters, .{}),
    };
    const params = .{
        .provider = ref.decl.id,
        .model = req.model,
        .system = req.system,
        .messages = req.messages,
        .tools = tools,
        .options = .{ .apiKey = options.apiKey, .baseURL = options.baseURL },
        .location = req.location,
        .session = req.session_id,
        .thinking = if (req.thinking) |level| @tagName(level) else null,
    };
    // A silent minute between messages ends the reply; the loop retries it.
    const result = process.request(arena, "stream", params, 60_000, .{ .ctx = &relay, .event = Relay.event }, &failure) catch |err| {
        switch (err) {
            error.ExtensionError => try sink.emit(.{ .failure = .{ .message = failure.message, .retryable = failure.retryable and !failure.overflow, .overflow = failure.overflow } }),
            error.ExtensionTimeout => try sink.emit(.{ .failure = .{ .message = "the extension stopped streaming", .retryable = true } }),
            error.Canceled => {},
            else => try sink.emit(.{ .failure = .{ .message = @errorName(err) } }),
        }
        return err;
    };
    const stop = std.meta.stringToEnum(@import("proto").message.StopReason, str(result, "stop") orelse "stop") orelse .stop;
    try sink.emit(.{ .done = stop });
}

fn str(v: Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn count(v: Value, name: []const u8) u64 {
    return switch (v.object.get(name) orelse return 0) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}
