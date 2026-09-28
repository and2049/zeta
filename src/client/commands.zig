//! Prompt-template commands: listing, running, and routing typed input
//! (`/name arguments`) to a command or an ordinary prompt.
const std = @import("std");
const proto = @import("proto");
const Client = @import("Client.zig");
const session_api = @import("session_api.zig");
const Allocator = std.mem.Allocator;

pub const Info = proto.commands.Info;

/// The session location's commands, sorted by name; owned by `a`.
pub fn list(c: *Client, a: Allocator, session: []const u8) ![]const Info {
    const response = try c.get(a, try std.fmt.allocPrint(a, "/commands?session={s}", .{try session_api.encode(a, session)}));
    try session_api.check(response);
    const body = try std.json.parseFromSliceLeaky(struct { commands: []const Info }, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return body.commands;
}

/// Expands command `name` server-side and admits it like a prompt.
pub fn run(c: *Client, a: Allocator, session: []const u8, name: []const u8, arguments: []const u8, delivery: session_api.Delivery, images: []const proto.attachment.Image) !session_api.Receipt {
    const checked = try a.alloc(proto.attachment.Image, images.len);
    for (images, checked) |image, *dest| dest.* = try proto.attachment.Image.init(a, image.mimeType, image.data);
    const response = try c.postJson(a, try std.fmt.allocPrint(a, "/sessions/{s}/command", .{session}), .{ .name = name, .arguments = arguments, .delivery = delivery, .images = checked });
    try session_api.check(response);
    return std.json.parseFromSliceLeaky(session_api.Receipt, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub const Invocation = struct { name: []const u8, arguments: []const u8 };

/// `/name arguments` when `text` starts with a slash and `name` is not a
/// built-in; null otherwise.
pub fn parse(text: []const u8) ?Invocation {
    if (text.len < 2 or text[0] != '/') return null;
    const end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    const name = text[1..end];
    if (proto.commands.isBuiltin(name)) return null;
    return .{ .name = name, .arguments = std.mem.trim(u8, text[end..], " \t\r\n") };
}

/// Sends typed input: `/name arguments` runs the session's command `name`
/// when there is one; anything else, including an unknown name, is sent as
/// an ordinary prompt.
pub fn submit(c: *Client, a: Allocator, session: []const u8, text: []const u8, delivery: session_api.Delivery, images: []const proto.attachment.Image) !session_api.Receipt {
    if (parse(text)) |invocation| {
        for (try list(c, a, session)) |command| {
            if (std.mem.eql(u8, command.name, invocation.name)) return run(c, a, session, invocation.name, invocation.arguments, delivery, images);
        }
    }
    return session_api.promptWithImages(c, a, session, text, delivery, images);
}

test "only slash input naming a non-built-in parses as a command" {
    const review = parse("/review src/a.zig  'two words'\n").?;
    try std.testing.expectEqualStrings("review", review.name);
    try std.testing.expectEqualStrings("src/a.zig  'two words'", review.arguments);
    try std.testing.expectEqualStrings("", parse("/plain").?.arguments);
    try std.testing.expect(parse("/model gpt") == null);
    try std.testing.expect(parse("plain text") == null);
    try std.testing.expect(parse("/") == null);
}
