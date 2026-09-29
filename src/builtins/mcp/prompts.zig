//! An MCP server's prompts as slash commands `<server>:<prompt>`. The
//! words typed after the name fill the prompt's arguments in the order it
//! declares them (quotes group words; the last argument takes the rest);
//! the prompt's messages, joined, become the session's prompt.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const Server = @import("Server.zig");
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

const Ref = struct { server: *Server, remote: []const u8, arguments: []const []const u8 };

/// Commands for the `prompts/list` entries in `listed`, in `a`.
pub fn build(a: Allocator, s: *Server, listed: []const Value) ![]const plugin.command.Command {
    var out: std.ArrayList(plugin.command.Command) = .empty;
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (listed) |item| {
        if (item != .object) continue;
        const remote = switch (item.object.get("name") orelse .null) {
            .string => |n| n,
            else => continue,
        };
        var names: std.ArrayList([]const u8) = .empty;
        var hint: std.ArrayList(u8) = .empty;
        if (item.object.get("arguments")) |list| if (list == .array) for (list.array.items) |arg| {
            if (arg != .object) continue;
            const name = switch (arg.object.get("name") orelse .null) {
                .string => |n| n,
                else => continue,
            };
            try names.append(a, name);
            const required = if (arg.object.get("required")) |r| r == .bool and r.bool else false;
            if (hint.items.len > 0) try hint.append(a, ' ');
            try hint.print(a, "{s}{s}{s}", .{ if (required) "<" else "[", name, if (required) ">" else "]" });
        };
        const ref = try a.create(Ref);
        ref.* = .{ .server = s, .remote = remote, .arguments = names.items };
        try out.append(a, .{
            .name = try unique(a, &taken, try std.fmt.allocPrint(a, "{s}:{s}", .{ s.spec.command_prefix, try config.commandSafe(a, remote) })),
            .description = switch (item.object.get("description") orelse .null) {
                .string => |d| d,
                else => "",
            },
            .argument_hint = if (hint.items.len > 0) hint.items else null,
            .ctx = ref,
            .run = run,
        });
    }
    return out.items;
}

/// `base`, or with `_2`, `_3`… when an earlier prompt got that name.
fn unique(a: Allocator, taken: *std.StringHashMapUnmanaged(void), base: []const u8) ![]const u8 {
    var candidate = base;
    var n: usize = 2;
    while (taken.contains(candidate)) : (n += 1) candidate = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, n });
    try taken.put(a, candidate, {});
    return candidate;
}

fn run(ctx: ?*anyopaque, arena: Allocator, _: Io, _: []const u8, text: []const u8, problem: *plugin.command.Problem) anyerror![]const u8 {
    const ref: *Ref = @ptrCast(@alignCast(ctx.?));
    const s = ref.server;
    const args = try fill(arena, ref.arguments, text);
    s.mutex.lockUncancelable(s.io);
    const link = s.link;
    const connected = s.state == .connected;
    s.mutex.unlock(s.io);
    if (!connected or link == null) return error.McpServerUnavailable;
    var remote: rpc.Remote = undefined;
    const result = link.?.conn.request(arena, "prompts/get", .{ .name = ref.remote, .arguments = Value{ .object = args } }, s.startup_ms, &remote) catch |err| {
        if (err == error.McpUnauthorized and s.signsIn()) s.refused(link.?);
        // The server's own words reach the user.
        if (err == error.McpRemoteError) return problem.fail("MCP error {d}: {s}", .{ remote.code, remote.message });
        return err;
    };
    return messages(arena, result);
}

/// The prompt's arguments from the words typed: one word each, in order,
/// and the rest of the text as typed for the last one.
fn fill(arena: Allocator, names: []const []const u8, text: []const u8) !std.json.ObjectMap {
    const words = try core.commands.split(arena, text);
    var args: std.json.ObjectMap = .empty;
    for (names, 0..) |name, i| {
        const value = if (i + 1 == names.len and words.len > i)
            unquoted(after(text, i))
        else if (i < words.len) words[i] else "";
        try args.put(arena, name, .{ .string = value });
    }
    return args;
}

/// `text` without the quotes around it, when they group all of it.
fn unquoted(text: []const u8) []const u8 {
    if (text.len < 2 or (text[0] != '"' and text[0] != '\'')) return text;
    const inner = text[1 .. text.len - 1];
    return if (text[text.len - 1] == text[0] and std.mem.indexOfScalar(u8, inner, text[0]) == null) inner else text;
}

/// `text` from its word `n` on (words split like `core.commands.split`).
fn after(text: []const u8, n: usize) []const u8 {
    var quote: ?u8 = null;
    var in_word = false;
    var count: usize = 0;
    for (text, 0..) |c, i| {
        const space = quote == null and std.ascii.isWhitespace(c);
        if (!space and !in_word) {
            if (count == n) return std.mem.trimEnd(u8, text[i..], &std.ascii.whitespace);
            count += 1;
        }
        in_word = !space;
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') quote = c;
    }
    return "";
}

test fill {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try fill(a, &.{"q"}, "what's wrong  with\nthis?");
    try std.testing.expectEqualStrings("what's wrong  with\nthis?", one.get("q").?.string);
    const quoted = try fill(a, &.{"q"}, "\"one word\"");
    try std.testing.expectEqualStrings("one word", quoted.get("q").?.string);
    const two = try fill(a, &.{ "file", "note" }, "\"a b.zig\"  keep  it\n");
    try std.testing.expectEqualStrings("a b.zig", two.get("file").?.string);
    try std.testing.expectEqualStrings("keep  it", two.get("note").?.string);
    const none = try fill(a, &.{ "file", "note" }, "");
    try std.testing.expectEqualStrings("", none.get("note").?.string);
}

/// The text of each message, joined by blank lines. Embedded resources
/// give their text; other content becomes a short placeholder.
fn messages(arena: Allocator, result: Value) ![]const u8 {
    if (result != .object) return error.McpInvalidPrompt;
    const list = result.object.get("messages") orelse return error.McpInvalidPrompt;
    if (list != .array) return error.McpInvalidPrompt;
    var out: std.ArrayList(u8) = .empty;
    for (list.array.items) |m| {
        if (m != .object) continue;
        const content = m.object.get("content") orelse continue;
        const parts: []const Value = switch (content) {
            .array => |items| items.items,
            .object => &.{content},
            else => continue,
        };
        for (parts) |part| {
            const piece = try @import("result.zig").part(arena, part) orelse continue;
            if (out.items.len > 0) try out.appendSlice(arena, "\n\n");
            try out.appendSlice(arena, piece);
        }
    }
    return out.items;
}

test "prompt names that become alike are told apart" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    try std.testing.expectEqualStrings("s:review_file", try unique(a, &taken, "s:" ++ "review_file"));
    try std.testing.expectEqualStrings("s:review_file_2", try unique(a, &taken, try std.fmt.allocPrint(a, "s:{s}", .{try config.commandSafe(a, "review/file")})));
}

test messages {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"messages":[{"role":"user","content":{"type":"text","text":"Review this:"}},
        \\ {"role":"user","content":{"type":"resource","resource":{"uri":"file:///a","text":"code"}}}]}
    , .{});
    try std.testing.expectEqualStrings("Review this:\n\ncode", try messages(a, v));
}
