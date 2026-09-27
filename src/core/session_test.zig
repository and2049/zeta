const std = @import("std");
const Io = std.Io;
const Session = @import("session.zig").Session;
const proto = @import("proto");
const storage = @import("session_storage.zig");

fn basePath(tmp: *std.testing.TmpDir, buf: *[Io.Dir.max_path_bytes]u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

test "reopen retains metadata and owned history; snapshots outlive session" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    var profile = [_]u8{ 'd', 'e', 'v' };
    const s = try Session.createWithMetadata(gpa, io, base, "ses_roundtrip", "/proj", .{
        .profile = &profile,
        .model = "p/model",
        .environment_present = true,
    });
    profile[0] = 'X';
    var text = [_]u8{ 'h', 'i' };
    try s.append(.{ .id = "msg_1", .role = .user, .content = &.{.{ .text = &text }}, .timestamp = 1 });
    text[0] = 'X';
    var snapshot = try s.snapshot(gpa);
    defer snapshot.deinit();
    s.destroy(gpa, io);
    try std.testing.expectEqualStrings("hi", snapshot.messages[0].content[0].text);
    try std.testing.expectEqualStrings("dev", snapshot.metadata.profile.?);
    const reopened = try Session.load(gpa, io, base, "ses_roundtrip", "/proj");
    defer reopened.destroy(gpa, io);
    try std.testing.expectEqualStrings("hi", reopened.messages.items[0].content[0].text);
    try std.testing.expect(reopened.metadata.environment_present);
    try std.testing.expectEqualStrings("p/model", reopened.metadata.model.?);
    try reopened.append(.{ .id = "msg_2", .role = .user, .content = &.{.{ .text = "later" }}, .timestamp = 2 });
    try std.testing.expectEqual(@as(usize, 1), snapshot.messages.len);
}

test "incomplete tail is truncated before append; complete corruption is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_tail", "/proj");
    try s.append(.{ .id = "msg_initial", .role = .user, .content = &.{}, .timestamp = 0 });
    s.destroy(gpa, io);
    const path = try storage.logPath(gpa, base, "/proj", "ses_tail");
    defer gpa.free(path);
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    const length = (try file.stat(io)).size;
    var w = file.writerStreaming(io, &.{});
    try w.seekTo(length);
    try w.interface.writeAll("{\"type\":\"message\",\"message\":");
    try w.interface.flush();
    file.close(io);
    const reopened = try Session.load(gpa, io, base, "ses_tail", "/proj");
    try reopened.append(.{ .id = "msg_new", .role = .user, .content = &.{.{ .text = "yes" }}, .timestamp = 1 });
    reopened.destroy(gpa, io);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10240));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"msg_new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"message\":\n") == null);
    const corrupt = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    var cw = corrupt.writerStreaming(io, &.{});
    try cw.seekTo(bytes.len);
    try cw.interface.writeAll("not-json\n");
    try cw.interface.flush();
    corrupt.close(io);
    try std.testing.expectError(error.CorruptSessionLog, Session.load(gpa, io, base, "ses_tail", "/proj"));
}

test "orphaned tool calls acquire one durable interruption result" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_orphan", "/p");
    try s.append(.{ .id = "msg_call", .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "call_1", .name = "bash", .arguments = "{\"cmd\":\"true\"}" } }}, .timestamp = 3, .stopReason = .tool_use });
    s.destroy(gpa, io);
    const once = try Session.load(gpa, io, base, "ses_orphan", "/p");
    try std.testing.expectEqual(@as(usize, 2), once.messages.items.len);
    try std.testing.expect(once.messages.items[1].isError);
    try std.testing.expectEqualStrings("call_1", once.messages.items[1].toolCallId.?);
    try std.testing.expect(proto.id.hasKind(once.messages.items[1].id, .message));
    once.destroy(gpa, io);
    const twice = try Session.load(gpa, io, base, "ses_orphan", "/p");
    defer twice.destroy(gpa, io);
    try std.testing.expectEqual(@as(usize, 2), twice.messages.items.len);
    var listing = try storage.list(gpa, io, base, "/p");
    defer listing.deinit();
    try std.testing.expectEqualStrings("ses_orphan", listing.ids[0]);
    try std.testing.expectEqual(@as(usize, 1), listing.ids.len);
}

test "unsupported version and entry fail without changing the log" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_future", "/p");
    try s.append(.{ .id = "msg_initial", .role = .user, .content = &.{}, .timestamp = 0 });
    s.destroy(gpa, io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = try storage.logPath(a, base, "/p", "ses_future");
    const original = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    const changed = try a.dupe(u8, original);
    const version = std.mem.indexOf(u8, changed, "\"version\":1").? + "\"version\":".len;
    changed[version] = '2';
    try writeLog(io, path, changed);
    try std.testing.expectError(error.UnsupportedSessionVersion, Session.load(gpa, io, base, "ses_future", "/p"));
    try writeLog(io, path, original);
    const with_entry = try std.fmt.allocPrint(a, "{s}{{\"type\":\"future\"}}\n", .{original});
    try writeLog(io, path, with_entry);
    try std.testing.expectError(error.UnsupportedSessionEntry, Session.load(gpa, io, base, "ses_future", "/p"));
    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try std.testing.expectEqualStrings(with_entry, after);
}

test "duplicate message IDs are refused on append and reopen" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_duplicate", "/p");
    const message: proto.Message = .{ .id = "msg_same", .role = .user, .content = &.{.{ .text = "first" }}, .timestamp = 1 };
    try s.append(message);
    try std.testing.expectError(error.DuplicateMessageId, s.append(message));
    s.destroy(gpa, io);
    var a_state: std.heap.ArenaAllocator = .init(gpa);
    defer a_state.deinit();
    const a = a_state.allocator();
    const path = try storage.logPath(a, base, "/p", "ses_duplicate");
    const original = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    const message_start = std.mem.indexOf(u8, original, "{\"type\":\"message\"").?;
    const doubled = try std.mem.concat(a, u8, &.{ original, original[message_start..] });
    try writeLog(io, path, doubled);
    try std.testing.expectError(error.DuplicateMessageId, Session.load(gpa, io, base, "ses_duplicate", "/p"));
}

test "legacy header title survives reopen and snapshots" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_title", "/p");
    try s.append(.{ .id = "msg_initial", .role = .user, .content = &.{}, .timestamp = 0 });
    s.destroy(gpa, io);
    var a_state: std.heap.ArenaAllocator = .init(gpa);
    defer a_state.deinit();
    const a = a_state.allocator();
    const path = try storage.logPath(a, base, "/p", "ses_title");
    const original = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    const needle = "\"title\":null";
    const pos = std.mem.indexOf(u8, original, needle).?;
    const titled = try std.mem.concat(a, u8, &.{ original[0..pos], "\"title\":\"from disk\"", original[pos + needle.len ..] });
    try writeLog(io, path, titled);
    const reopened = try Session.load(gpa, io, base, "ses_title", "/p");
    defer reopened.destroy(gpa, io);
    try std.testing.expectEqualStrings("from disk", reopened.info.title.?);
    var snap = try reopened.snapshot(gpa);
    defer snap.deinit();
    try std.testing.expectEqualStrings("from disk", snap.info.title.?);
}

test "recovery closes many calls across message-array growth and stays idempotent" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_many", "/p");
    for (0..40) |i| {
        var mid: [32]u8 = undefined;
        var cid: [32]u8 = undefined;
        try s.append(.{ .id = try std.fmt.bufPrint(&mid, "msg_{d}", .{i}), .role = .assistant, .content = &.{.{ .tool_call = .{ .id = try std.fmt.bufPrint(&cid, "call_{d}", .{i}), .name = "read", .arguments = "{}" } }}, .timestamp = 1 });
    }
    s.destroy(gpa, io);
    const once = try Session.load(gpa, io, base, "ses_many", "/p");
    try std.testing.expectEqual(@as(usize, 80), once.messages.items.len);
    for (once.messages.items[40..]) |m| {
        try std.testing.expect(m.isError and m.role == .tool_result);
        try std.testing.expect(proto.id.hasKind(m.id, .message));
    }
    once.destroy(gpa, io);
    const twice = try Session.load(gpa, io, base, "ses_many", "/p");
    defer twice.destroy(gpa, io);
    try std.testing.expectEqual(@as(usize, 80), twice.messages.items.len);
}

test "reopen streams a record larger than its read chunk" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_large", "/p");
    const text = try gpa.alloc(u8, 100_000);
    defer gpa.free(text);
    @memset(text, 'a');
    try s.append(.{ .id = "msg_large", .role = .user, .content = &.{.{ .text = text }}, .timestamp = 1 });
    s.destroy(gpa, io);
    const reopened = try Session.load(gpa, io, base, "ses_large", "/p");
    defer reopened.destroy(gpa, io);
    try std.testing.expectEqualStrings(text, reopened.messages.items[0].content[0].text);
}

test "oversized complete and incomplete records fail without modifying the log" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    const s = try Session.create(gpa, io, base, "ses_oversize", "/p");
    try s.append(.{ .id = "msg_initial", .role = .user, .content = &.{}, .timestamp = 0 });
    s.destroy(gpa, io);
    const path = try storage.logPath(gpa, base, "/p", "ses_oversize");
    defer gpa.free(path);
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    const header_size = (try file.stat(io)).size;
    var writer = file.writerStreaming(io, &.{});
    try writer.seekTo(header_size);
    var chunk: [64 * 1024]u8 = @splat(' ');
    for (0..Session.max_record_size / chunk.len + 1) |_| try writer.interface.writeAll(&chunk);
    try writer.interface.flush();
    file.close(io);
    const incomplete_size = (try Io.Dir.cwd().statFile(io, path, .{})).size;
    try std.testing.expectError(error.CorruptSessionLog, Session.load(gpa, io, base, "ses_oversize", "/p"));
    try std.testing.expectEqual(incomplete_size, (try Io.Dir.cwd().statFile(io, path, .{})).size);
    const complete = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    var end_writer = complete.writerStreaming(io, &.{});
    try end_writer.seekTo(incomplete_size);
    try end_writer.interface.writeByte('\n');
    try end_writer.interface.flush();
    complete.close(io);
    try std.testing.expectError(error.CorruptSessionLog, Session.load(gpa, io, base, "ses_oversize", "/p"));
    try std.testing.expectEqual(incomplete_size + 1, (try Io.Dir.cwd().statFile(io, path, .{})).size);
}

fn writeLog(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = file.writerStreaming(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "the system entry is logged only when prompt or tools change and survives reopen" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = try basePath(&tmp, &buf);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const tools = [_]@import("plugin").provider.ToolDecl{.{ .name = "read", .description = "Read", .parameters = "{}" }};
    const s = try Session.create(gpa, io, base, "ses_system", "/proj");
    const first = try a.dupe(u8, try s.recordSystem(a, "prompt", &tools, 1));
    try std.testing.expectEqual(@as(usize, 64), first.len);
    try std.testing.expectEqualStrings(first, try s.recordSystem(a, "prompt", &tools, 2));
    const other = try a.dupe(u8, try s.recordSystem(a, "prompt", &.{}, 3));
    try std.testing.expect(!std.mem.eql(u8, first, other));
    try s.append(.{ .id = "msg_initial", .role = .user, .content = &.{}, .timestamp = 0 });
    s.destroy(gpa, io);

    const log = try Io.Dir.cwd().readFileAlloc(io, try storage.logPath(a, base, "/proj", "ses_system"), a, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, log, "\"type\":\"system\""));
    const reopened = try Session.load(gpa, io, base, "ses_system", "/proj");
    defer reopened.destroy(gpa, io);
    try std.testing.expectEqualStrings(other, reopened.system_hash.?);
    try std.testing.expectEqualStrings(other, try reopened.recordSystem(a, "prompt", &.{}, 4));
}
