//! Durable append-only session log at `<sessions>/<location-hash>/<id>.jsonl`.
//! The complete newline-terminated records are authoritative. An incomplete
//! final record is discarded on reopen; corruption in a complete record fails.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const Message = proto.Message;
const config = @import("config.zig");
const storage = @import("session_storage.zig");
const plugin = @import("plugin");
const thinking = proto.thinking;
const log = @import("session_log.zig");

pub const format_version = 1;

pub const Info = struct {
    id: []const u8,
    location: []const u8,
    created: i64,
    title: ?[]const u8 = null,
    /// Set for a fork: the session it was copied from, and the last message
    /// copied.
    forkedFrom: ?[]const u8 = null,
    forkedAt: ?[]const u8 = null,
};

/// Where a forked session came from.
pub const Fork = struct { session: []const u8, message: []const u8 };

/// Selectors retained across restarts. `environment_present` distinguishes an
/// explicit empty client environment from using the server's own environment.
pub const Metadata = struct {
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// The session's thinking level selection.
    thinking: ?[]const u8 = null,
    environment_present: bool = false,
    environment_profile: ?[]const u8 = null,
    environment_model: ?[]const u8 = null,

    /// Borrowed strings; the session/snapshot must outlive the returned options.
    pub fn options(m: Metadata) config.Options {
        return .{
            .profile = m.profile,
            .model = m.model,
            .thinking = m.thinking,
            .environment = if (m.environment_present) .{
                .profile = m.environment_profile,
                .model = m.environment_model,
            } else null,
        };
    }
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    info: Info,
    metadata: Metadata,
    messages: []const Message,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Session = struct {
    pub const max_record_size = 64 * 1024 * 1024;
    /// Owns info, metadata, message contents, log read buffers, and writer buffer.
    arena: std.heap.ArenaAllocator,
    info: Info,
    metadata: Metadata = .{},
    model_selected: bool = false,
    messages: std.ArrayList(Message) = .empty,
    message_ids: std.StringHashMapUnmanaged(void) = .empty,
    file: ?Io.File = null,
    writer: ?Io.File.Writer = null,
    /// Owned by the arena until the first message opens the log.
    path: []const u8,
    pending: std.ArrayList([]const u8) = .empty,
    io: Io,
    mutex: Io.Mutex = .init,
    poisoned: bool = false,
    /// Hash of the last logged `system` entry; session-arena owned.
    system_hash: ?[]const u8 = null,

    pub fn create(gpa: Allocator, io: Io, sessions_dir: []const u8, id: []const u8, location: []const u8) !*Session {
        return createWithMetadata(gpa, io, sessions_dir, id, location, .{});
    }

    pub fn createWithMetadata(gpa: Allocator, io: Io, sessions_dir: []const u8, id: []const u8, location: []const u8, metadata: Metadata) !*Session {
        return createFrom(gpa, io, sessions_dir, id, location, metadata, null);
    }

    /// Like `createWithMetadata`, recording that it is a fork of `fork`.
    pub fn createFrom(gpa: Allocator, io: Io, sessions_dir: []const u8, id: []const u8, location: []const u8, metadata: Metadata, fork: ?Fork) !*Session {
        if (!storage.validId(id)) return error.InvalidSessionId;
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.arena = .init(gpa);
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        s.info = .{ .id = try a.dupe(u8, id), .location = try a.dupe(u8, location), .created = Io.Clock.real.now(io).toMilliseconds() };
        if (fork) |f| {
            s.info.forkedFrom = try a.dupe(u8, f.session);
            s.info.forkedAt = try a.dupe(u8, f.message);
        }
        s.metadata = try copyMetadata(a, metadata);
        s.messages = .empty;
        s.message_ids = .empty;
        s.file = null;
        s.writer = null;
        s.pending = .empty;
        s.io = io;
        s.mutex = .init;
        s.poisoned = false;
        s.model_selected = false;
        s.path = try storage.logPath(a, sessions_dir, location, id);
        if (fork != null) {
            try s.writeLine(.{ .type = "session", .version = format_version, .id = s.info.id, .location = s.info.location, .timestamp = s.info.created, .title = s.info.title, .metadata = s.metadata, .forkedFrom = s.info.forkedFrom, .forkedAt = s.info.forkedAt });
        } else try s.writeLine(.{ .type = "session", .version = format_version, .id = s.info.id, .location = s.info.location, .timestamp = s.info.created, .title = s.info.title, .metadata = s.metadata });
        return s;
    }

    /// Reopens only the explicitly identified session. Does not resume a turn.
    /// An unfinished tool call gets a durable error result, never re-executes.
    pub fn load(gpa: Allocator, io: Io, sessions_dir: []const u8, id: []const u8, location: []const u8) !*Session {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const s = try loadAtPath(gpa, io, try storage.logPath(scratch.allocator(), sessions_dir, location, id), id, location);
        if (!std.mem.eql(u8, s.info.location, location)) {
            s.destroy(gpa, io);
            return error.CorruptSessionLog;
        }
        return s;
    }

    /// Opens the physical log path even when a move changed its effective
    /// location without yet changing its original header.
    pub fn loadAtPath(gpa: Allocator, io: Io, physical_path: []const u8, id: []const u8, location: []const u8) !*Session {
        if (!storage.validId(id)) return error.InvalidSessionId;
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.arena = .init(gpa);
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        s.messages = .empty;
        s.message_ids = .empty;
        s.file = null;
        s.writer = null;
        s.pending = .empty;
        s.metadata = .{};
        s.io = io;
        s.mutex = .init;
        s.poisoned = false;
        s.model_selected = false;
        const path = try a.dupe(u8, physical_path);
        // Another server holding it serves the session: `error.WouldBlock`.
        s.path = path;
        s.file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
        errdefer s.file.?.close(io);
        const complete_end = try log.parseLog(s, gpa, id, location);
        // Parsing precedes mutation: corrupt complete records never get truncated.
        if (complete_end != (try s.file.?.stat(io)).size) try s.file.?.setLength(io, complete_end);
        s.writer = s.file.?.writerStreaming(io, try a.alloc(u8, 4096));
        try s.writer.?.seekTo(complete_end);
        try log.closeOrphans(s);
        return s;
    }

    /// All snapshots own their data and remain valid after append or destroy.
    pub fn snapshot(s: *Session, gpa: Allocator) !Snapshot {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var result: Snapshot = .{ .arena = .init(gpa), .info = undefined, .metadata = undefined, .messages = undefined };
        errdefer result.deinit();
        const a = result.arena.allocator();
        result.info = .{
            .id = try a.dupe(u8, s.info.id),
            .location = try a.dupe(u8, s.info.location),
            .created = s.info.created,
            .title = if (s.info.title) |v| try a.dupe(u8, v) else null,
            .forkedFrom = if (s.info.forkedFrom) |v| try a.dupe(u8, v) else null,
            .forkedAt = if (s.info.forkedAt) |v| try a.dupe(u8, v) else null,
        };
        result.metadata = try copyMetadata(a, s.metadata);
        const msgs = try a.alloc(Message, s.messages.items.len);
        for (s.messages.items, msgs) |m, *dest| dest.* = try dupeMessage(a, m);
        result.messages = msgs;
        return result;
    }

    pub fn destroy(s: *Session, gpa: Allocator, io: Io) void {
        // Caller must first join any writer worker and release snapshots.
        if (s.file) |file| file.close(io);
        s.arena.deinit();
        gpa.destroy(s);
    }

    /// Deeply copies `m`; the caller retains ownership of its buffers.
    pub fn append(s: *Session, m: Message) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.poisoned) return error.SessionLogWriteFailed;
        if (m.id.len == 0) return error.InvalidMessageId;
        if (s.message_ids.contains(m.id)) return error.DuplicateMessageId;
        const owned = try dupeMessage(s.arena.allocator(), m);
        try s.messages.ensureUnusedCapacity(s.arena.allocator(), 1);
        try s.message_ids.ensureUnusedCapacity(s.arena.allocator(), 1);
        s.flushFirstMessage(owned) catch |err| {
            s.poisoned = true;
            return err;
        };
        s.messages.appendAssumeCapacity(owned);
        s.message_ids.putAssumeCapacityNoClobber(owned.id, {});
    }

    fn flushFirstMessage(s: *Session, message: Message) !void {
        if (s.file == null) {
            const a = s.arena.allocator();
            _ = try Io.Dir.cwd().createDirPathStatus(s.io, std.fs.path.dirname(s.path).?, .fromMode(0o700));
            const file = try Io.Dir.cwd().createFile(s.io, s.path, .{ .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true });
            s.file = file;
            s.writer = file.writerStreaming(s.io, try a.alloc(u8, 4096));
            for (s.pending.items) |line| {
                try s.writer.?.interface.writeAll(line);
                try s.writer.?.interface.writeByte('\n');
            }
            try s.writer.?.interface.flush();
            try file.sync(s.io);
            s.pending = .empty;
        }
        try s.writeLine(.{ .type = "message", .message = message });
    }

    /// Logs the system prompt and tool declarations a request sends, unless
    /// the last logged entry already has them. Returns their hash, which
    /// assistant messages carry as `systemHash`; it lives in the session.
    /// `scratch` holds the hashed encoding.
    pub fn recordSystem(s: *Session, scratch: Allocator, prompt: []const u8, tools: []const plugin.provider.ToolDecl, timestamp: i64) ![]const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.poisoned) return error.SessionLogWriteFailed;
        const a = s.arena.allocator();
        const body = try std.json.Stringify.valueAlloc(scratch, .{ .prompt = prompt, .tools = tools }, .{});
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (s.system_hash) |last| if (std.mem.eql(u8, last, &hex)) return last;
        const hash = try a.dupe(u8, &hex);
        s.writeLine(.{ .type = "system", .hash = hash, .prompt = prompt, .tools = tools, .timestamp = timestamp }) catch |err| {
            s.poisoned = true;
            return err;
        };
        s.system_hash = hash;
        return hash;
    }

    /// Persist first, then expose the changes together. Caller holds the
    /// runtime state lock; the bytes live in the session arena. `thinking`
    /// is a level name, or `auto` to drop the selection.
    pub fn update(s: *Session, model: ?[]const u8, title: ?[]const u8, thinking_level: ?[]const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.poisoned) return error.SessionLogWriteFailed;
        const a = s.arena.allocator();
        const owned_model = if (model) |v| try a.dupe(u8, v) else null;
        const owned_title = if (title) |v| try a.dupe(u8, v) else null;
        const owned_thinking = if (thinking_level) |v| try a.dupe(u8, v) else null;
        s.writeLineOmitNull(.{ .type = "session.update", .model = owned_model, .title = owned_title, .thinking = owned_thinking }) catch |err| {
            s.poisoned = true;
            return err;
        };
        if (owned_model) |v| {
            s.metadata.model = v;
            s.model_selected = true;
        }
        if (owned_title) |v| s.info.title = v;
        if (owned_thinking) |v| s.metadata.thinking = log.selection(v);
    }

    /// The caller holds the runtime lock. The log update is synced before any
    /// filesystem rename; on restart restore relocates an interrupted move.
    pub fn moveLocation(s: *Session, sessions_dir: []const u8, location: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.poisoned) return error.SessionLogWriteFailed;
        const a = s.arena.allocator();
        const owned = try a.dupe(u8, location);
        const new_path = try storage.logPath(a, sessions_dir, owned, s.info.id);
        if (s.file != null) {
            s.writeLine(.{ .type = "session.update", .location = owned }) catch |err| {
                s.poisoned = true;
                return err;
            };
            s.info.location = owned;
            try s.relocate(new_path);
        } else {
            s.info.location = owned;
            s.path = new_path;
            // Replace the unsaved header, preserving any earlier metadata updates.
            s.pending.items[0] = try std.json.Stringify.valueAlloc(a, .{
                .type = "session",
                .version = format_version,
                .id = s.info.id,
                .location = owned,
                .timestamp = s.info.created,
                .title = s.info.title,
                .metadata = s.metadata,
            }, .{});
        }
    }

    /// Also used at startup if a crash occurred after the update but before
    /// either rename. Keep the open log handle; its writer follows the inode.
    pub fn recoverLocation(s: *Session, sessions_dir: []const u8) !void {
        const target = try storage.logPath(s.arena.allocator(), sessions_dir, s.info.location, s.info.id);
        try s.relocate(target);
    }

    fn relocate(s: *Session, target: []const u8) !void {
        const a = s.arena.allocator();
        _ = try Io.Dir.cwd().createDirPathStatus(s.io, std.fs.path.dirname(target).?, .fromMode(0o700));
        const old_art = try std.fmt.allocPrint(a, "{s}/{s}.artifacts", .{ std.fs.path.dirname(s.path).?, s.info.id });
        const new_art = try std.fmt.allocPrint(a, "{s}/{s}.artifacts", .{ std.fs.path.dirname(target).?, s.info.id });
        if (!std.mem.eql(u8, old_art, new_art)) {
            Io.Dir.renameAbsolute(old_art, new_art, s.io) catch |err| if (err != error.FileNotFound) return err;
        }
        if (!std.mem.eql(u8, s.path, target)) {
            try Io.Dir.renameAbsolute(s.path, target, s.io);
            s.path = target;
        }
    }

    fn writeLine(s: *Session, value: anytype) !void {
        return s.writeLineWithOptions(value, .{});
    }

    fn writeLineOmitNull(s: *Session, value: anytype) !void {
        return s.writeLineWithOptions(value, .{ .emit_null_optional_fields = false });
    }

    fn writeLineWithOptions(s: *Session, value: anytype, options: std.json.Stringify.Options) !void {
        if (s.writer == null) {
            const line = try std.json.Stringify.valueAlloc(s.arena.allocator(), value, options);
            try s.pending.append(s.arena.allocator(), line);
            return;
        }
        const w = &s.writer.?.interface;
        try std.json.Stringify.value(value, options, w);
        try w.writeByte('\n');
        try w.flush();
        // Flush reaches the OS; sync ensures acknowledged records survive a crash.
        try s.file.?.sync(s.io);
    }
};

pub fn locationHash(location: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(location, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8], .lower);
}

pub fn copyMetadata(a: Allocator, m: Metadata) !Metadata {
    return .{
        .profile = if (m.profile) |v| try a.dupe(u8, v) else null,
        .model = if (m.model) |v| try a.dupe(u8, v) else null,
        .thinking = if (m.thinking) |v| try a.dupe(u8, v) else null,
        .environment_present = m.environment_present,
        .environment_profile = if (m.environment_profile) |v| try a.dupe(u8, v) else null,
        .environment_model = if (m.environment_model) |v| try a.dupe(u8, v) else null,
    };
}

fn dupeMessage(arena: Allocator, m: Message) !Message {
    const json = try std.json.Stringify.valueAlloc(arena, m, .{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return Message.parse(arena, v);
}

test {
    _ = @import("session_test.zig");
}
