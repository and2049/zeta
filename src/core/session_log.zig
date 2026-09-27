//! Parses complete session log records and closes orphaned calls on recovery.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const Message = proto.Message;
const thinking = proto.thinking;
const config = @import("config.zig");
const session = @import("session.zig");
const Session = session.Session;
const Metadata = session.Metadata;
const format_version = session.format_version;
const copyMetadata = session.copyMetadata;

/// A logged thinking selection; `auto` is none.
pub fn selection(text: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, text, thinking.auto)) null else text;
}

/// Read bounded chunks, accumulating at most one bounded record. The
/// parsed message tree remains in the session arena; raw log bytes do not.
pub fn parseLog(s: *Session, gpa: Allocator, id: []const u8, location: []const u8) !u64 {
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var complete_end: u64 = 0;
    var header = false;
    while (true) {
        const len = try s.file.?.readPositional(s.io, &.{&chunk}, offset);
        if (len == 0) break;
        var rest = chunk[0..len];
        while (rest.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
                if (record.items.len > Session.max_record_size -| end) return error.CorruptSessionLog;
                try record.appendSlice(gpa, rest[0..end]);
                if (header) {
                    try parseEntry(s, record.items);
                } else {
                    try parseHeader(s, record.items, id, location);
                    header = true;
                }
                complete_end = offset + (len - rest.len) + end + 1;
                record.clearRetainingCapacity();
                rest = rest[end + 1 ..];
            } else {
                if (record.items.len > Session.max_record_size -| rest.len) return error.CorruptSessionLog;
                try record.appendSlice(gpa, rest);
                break;
            }
        }
        offset += len;
    }
    if (!header) return error.CorruptSessionLog;
    return complete_end;
}

fn parseHeader(s: *Session, first: []const u8, id: []const u8, location: []const u8) !void {
    const a = s.arena.allocator();
    const h = parseObject(a, first) catch return error.CorruptSessionLog;
    if (!fieldEquals(h, "type", "session")) return error.CorruptSessionLog;
    const version = h.get("version") orelse return error.CorruptSessionLog;
    if (version != .integer or version.integer != format_version) return error.UnsupportedSessionVersion;
    if (!fieldEquals(h, "id", id)) return error.CorruptSessionLog;
    const header_location = h.get("location") orelse return error.CorruptSessionLog;
    if (header_location != .string or !std.fs.path.isAbsolute(header_location.string)) return error.CorruptSessionLog;
    const timestamp = h.get("timestamp") orelse return error.CorruptSessionLog;
    if (timestamp != .integer) return error.CorruptSessionLog;
    const title: ?[]const u8 = if (h.get("title")) |raw| switch (raw) {
        .null => null,
        .string => |value| value,
        else => return error.CorruptSessionLog,
    } else null;
    _ = location;
    s.info = .{ .id = try a.dupe(u8, id), .location = header_location.string, .created = timestamp.integer, .title = title };
    inline for (.{ "forkedFrom", "forkedAt" }) |name| if (h.get(name)) |raw| switch (raw) {
        .string => |value| @field(s.info, name) = value,
        .null => {},
        else => return error.CorruptSessionLog,
    };
    if (h.get("metadata")) |raw| {
        const parsed = std.json.parseFromValueLeaky(Metadata, a, raw, .{ .ignore_unknown_fields = false }) catch return error.CorruptSessionLog;
        s.metadata = try copyMetadata(a, parsed);
    }
}

fn parseEntry(s: *Session, line: []const u8) !void {
    const a = s.arena.allocator();
    const obj = parseObject(a, line) catch return error.CorruptSessionLog;
    if (fieldEquals(obj, "type", "session.update")) {
        if (obj.get("model")) |raw| {
            if (raw != .string or config.splitModel(raw.string) == null) return error.CorruptSessionLog;
            s.metadata.model = raw.string;
            s.model_selected = true;
        }
        if (obj.get("title")) |raw| {
            if (raw != .string or std.mem.trim(u8, raw.string, " \t\r\n").len == 0) return error.CorruptSessionLog;
            s.info.title = raw.string;
        }
        if (obj.get("thinking")) |raw| {
            if (raw != .string or !thinking.validSelection(raw.string)) return error.CorruptSessionLog;
            s.metadata.thinking = selection(raw.string);
        }
        if (obj.get("location")) |raw| {
            if (raw != .string or !std.fs.path.isAbsolute(raw.string)) return error.CorruptSessionLog;
            s.info.location = raw.string;
        }
        if (obj.get("model") == null and obj.get("title") == null and obj.get("thinking") == null and obj.get("location") == null) return error.CorruptSessionLog;
        return;
    }
    if (fieldEquals(obj, "type", "system")) {
        const hash = obj.get("hash") orelse return error.CorruptSessionLog;
        if (hash != .string or hash.string.len == 0) return error.CorruptSessionLog;
        s.system_hash = hash.string;
        return;
    }
    if (!fieldEquals(obj, "type", "message")) return error.UnsupportedSessionEntry;
    const raw = obj.get("message") orelse return error.CorruptSessionLog;
    const m = Message.parse(a, raw) catch return error.CorruptSessionLog;
    if (m.id.len == 0) return error.CorruptSessionLog;
    if (s.message_ids.contains(m.id)) return error.DuplicateMessageId;
    try s.message_ids.put(a, m.id, {});
    try s.messages.append(a, m);
}

pub fn closeOrphans(s: *Session) !void {
    // A result can appear anywhere later in the log, so collect all ids first.
    const a = s.arena.allocator();
    var resolved: std.StringHashMapUnmanaged(void) = .empty;
    for (s.messages.items) |m| if (m.role == .tool_result) {
        if (m.toolCallId) |id| try resolved.put(a, id, {});
    };
    const original_len = s.messages.items.len;
    var generator: proto.id.Generator = .{};
    for (0..original_len) |index| {
        // Fetch each message anew; append can reallocate messages.items.
        const m = s.messages.items[index];
        if (m.role != .assistant) continue;
        for (m.content) |part| if (part == .tool_call) {
            const call = part.tool_call;
            if (resolved.contains(call.id)) continue;
            var id = generator.next(s.io, .message);
            while (s.message_ids.contains(id.slice())) id = generator.next(s.io, .message);
            try s.append(.{ .id = id.slice(), .role = .tool_result, .content = &.{.{ .text = "Tool execution interrupted by restart; not re-executed." }}, .timestamp = Io.Clock.real.now(s.io).toMilliseconds(), .toolCallId = call.id, .toolName = call.name, .isError = true });
            try resolved.put(a, call.id, {});
        };
    }
}

fn parseObject(a: Allocator, line: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    return switch (parsed) {
        .object => |o| o,
        else => error.InvalidLogEntry,
    };
}

fn fieldEquals(obj: std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const value = obj.get(name) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}
