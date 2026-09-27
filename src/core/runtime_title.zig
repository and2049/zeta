//! Explicit, nonblocking title generation. This worker never shares the turn
//! worker or its cancellation group, history, tools, or prompt instructions.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const plugin = @import("plugin");
const proto = @import("proto");
const freeOverrides = @import("runtime_state.zig").freeOverrides;

pub const system = "Generate a short session title. Return only a concise title on one line, with no quotation marks or commentary.";

/// A receipt only: provider errors and cancellation do not fail the turn.
/// An already titled session is a no-op; duplicate in-flight requests conflict.
pub fn requestTitle(rt: *Runtime, id: []const u8) !void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const entry = rt.sessions.get(id) orelse return error.SessionNotFound;
    if (entry.stopping) return error.SessionBusy;
    if (entry.session.info.title != null) return;
    if (entry.title_running) return error.SessionBusy;

    entry.session.mutex.lockUncancelable(rt.io);
    const first_text = firstUserText(entry.session.messages.items) orelse {
        entry.session.mutex.unlock(rt.io);
        return error.NoUserText;
    };
    const text = rt.gpa.dupe(u8, first_text) catch |err| {
        entry.session.mutex.unlock(rt.io);
        return err;
    };
    entry.session.mutex.unlock(rt.io);
    errdefer rt.gpa.free(text);
    const options = try @import("runtime_state.zig").copyOptions(rt.gpa, entry.overrides);
    errdefer freeOverrides(rt, options);
    // A completed previous title worker can be reaped before reusing its group.
    entry.title_worker.await(rt.io) catch {};
    entry.title_running = true;
    entry.title_worker.concurrent(rt.io, generate, .{ rt, entry, text, options, entry.session.model_selected }) catch |err| {
        entry.title_running = false;
        return err;
    };
}

fn firstUserText(messages: []const proto.Message) ?[]const u8 {
    for (messages) |message| {
        if (message.role != .user) continue;
        for (message.content) |part| if (part == .text and std.mem.trim(u8, part.text, " \t\r\n").len != 0) return part.text;
    }
    return null;
}

fn generate(rt: *Runtime, entry: *Runtime.Entry, text: []const u8, options: config.Options, selected: bool) Io.Cancelable!void {
    defer rt.gpa.free(text);
    defer freeOverrides(rt, options);
    defer {
        rt.mutex.lockUncancelable(rt.io);
        entry.title_running = false;
        rt.mutex.unlock(rt.io);
    }
    generateInner(rt, entry, text, options, selected) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        std.log.warn("title generation for {s} failed: {s}", .{ entry.session.info.id, @errorName(err) });
    };
}

fn generateInner(rt: *Runtime, entry: *Runtime.Entry, text: []const u8, options: config.Options, selected: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cfg = try config.loadWithOptions(a, rt.io, rt.env, rt.config_dir, entry.session.info.location, options);
    if (selected) cfg.model = options.model;
    try @import("runtime_model.zig").fill(rt, a, entry.session.info.location, &cfg);
    const model = cfg.small_model orelse cfg.model orelse return error.NoModelConfigured;
    const ref = config.splitModel(model) orelse return error.InvalidModelRef;
    const view = try rt.registry.view(a, entry.session.info.location);
    const routed = try @import("runtime_route.zig").resolve(view, a, rt.io, cfg, ref.provider, ref.model);
    const user: proto.Message = .{
        .id = "title_input",
        .role = .user,
        .content = &.{.{ .text = text }},
        .timestamp = 0,
    };
    var output: Output = .{ .arena = a };
    try routed.api.stream(routed.api.ctx, a, rt.io, routed.options, .{
        .model = ref.model,
        .location = entry.session.info.location,
        .system = system,
        .messages = &.{user},
        .tools = &.{},
    }, .{ .ctx = &output, .onEvent = Output.onEvent });
    const title = normalize(output.bytes.items) orelse return;
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    // A manual rename, abort, or delete while the provider was pending wins.
    if (entry.stopping or entry.session.info.title != null) return;
    try entry.session.update(null, title, null);
    rt.bus.publishValue(proto.event.types.session_updated, entry.session.info.id, entry.session.info.location, .{
        .session = entry.session.info,
        .model = entry.overrides.model,
        .thinking = entry.session.metadata.thinking,
    }) catch {};
}

const Output = struct {
    arena: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn onEvent(ctx: *anyopaque, event: plugin.provider.Event) !void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        if (event == .text_delta and self.bytes.items.len < 512) {
            try self.bytes.appendSlice(self.arena, event.text_delta[0..@min(event.text_delta.len, 512 - self.bytes.items.len)]);
        }
    }
};

fn normalize(raw: []const u8) ?[]const u8 {
    const first = raw[0 .. std.mem.indexOfAny(u8, raw, "\r\n") orelse raw.len];
    const line = std.mem.trim(u8, first, " \t\"'`#");
    if (line.len == 0) return null;
    const bound = @min(line.len, 200);
    var end = bound;
    while (end > 0 and !std.unicode.utf8ValidateSlice(line[0..end])) end -= 1;
    return if (end == 0) null else line[0..end];
}

test "title normalization uses first line and bounded UTF-8" {
    try std.testing.expectEqualStrings("Compact title", normalize("  \"Compact title\"\nsecond").?);
    try std.testing.expect(normalize(" \nnone") == null);
}
