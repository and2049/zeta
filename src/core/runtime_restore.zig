//! Startup scan and validation of persisted session logs.
const std = @import("std");
const Io = std.Io;
const Runtime = @import("Runtime.zig");
const Session = @import("session.zig").Session;
const session_storage = @import("session_storage.zig");
const config = @import("config.zig");
const types = @import("proto").event.types;
const Entry = Runtime.Entry;
const freeOverrides = @import("runtime_state.zig").freeOverrides;

pub const RestoreReport = struct { loaded: usize = 0, skipped: usize = 0 };

/// Discover every location directory and reopen valid logs without resuming
/// any turn. Corrupt candidates emit session.error and are left untouched.
/// Call during startup before exposing Runtime to concurrent requests.
pub fn restore(rt: *Runtime) !RestoreReport {
    const root = Io.Dir.cwd().openDir(rt.io, rt.sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer root.close(rt.io);
    var report: RestoreReport = .{};
    var dirs = root.iterate();
    while (try dirs.next(rt.io)) |directory| {
        if (directory.kind != .directory) continue;
        const child = root.openDir(rt.io, directory.name, .{ .iterate = true }) catch continue;
        defer child.close(rt.io);
        var files = child.iterate();
        while (try files.next(rt.io)) |candidate| {
            if (candidate.kind != .file or !std.mem.endsWith(u8, candidate.name, ".jsonl")) continue;
            const id = candidate.name[0 .. candidate.name.len - ".jsonl".len];
            if (!session_storage.validId(id)) continue;
            var scratch: std.heap.ArenaAllocator = .init(rt.gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const path = try std.fs.path.join(a, &.{ rt.sessions_dir, directory.name, candidate.name });
            const file = Io.Dir.cwd().openFile(rt.io, path, .{}) catch |err| {
                reportCorrupt(rt, id, err);
                report.skipped += 1;
                continue;
            };
            defer file.close(rt.io);
            // Stream only the first line; selectors can make a header much
            // larger than a single reader buffer. Session.load validates the
            // entire log after this location lookup.
            var read_buf: [4096]u8 = undefined;
            var reader = file.readerStreaming(rt.io, &read_buf);
            var header_writer: Io.Writer.Allocating = .init(a);
            _ = reader.interface.streamDelimiter(&header_writer.writer, '\n') catch |err| {
                reportCorrupt(rt, id, err);
                report.skipped += 1;
                continue;
            };
            const header = std.json.parseFromSliceLeaky(std.json.Value, a, header_writer.written(), .{}) catch {
                reportCorrupt(rt, id, error.CorruptSessionLog);
                report.skipped += 1;
                continue;
            };
            const location_value = if (header == .object) header.object.get("location") else null;
            const location = if (location_value) |value| (if (value == .string) value.string else null) else null;
            if (location == null) {
                reportCorrupt(rt, id, error.CorruptSessionLog);
                report.skipped += 1;
                continue;
            }
            const session = Session.loadAtPath(rt.gpa, rt.io, path, id, location.?) catch |err| {
                if (err == error.WouldBlock) {
                    // Open in another runtime.
                    std.log.info("session {s} is open in another runtime; not loaded", .{id});
                    report.skipped += 1;
                    continue;
                }
                reportCorrupt(rt, id, err);
                report.skipped += 1;
                continue;
            };
            errdefer session.destroy(rt.gpa, rt.io);
            if (!std.mem.eql(u8, directory.name, &@import("session.zig").locationHash(location.?)) and
                !std.mem.eql(u8, directory.name, &@import("session.zig").locationHash(session.info.location)))
            {
                session.destroy(rt.gpa, rt.io);
                reportCorrupt(rt, id, error.CorruptSessionLog);
                report.skipped += 1;
                continue;
            }
            // A synced location update can precede the log/artifact renames.
            // Repair it while the log is locked, before making it discoverable.
            session.recoverLocation(rt.sessions_dir) catch |err| {
                reportCorrupt(rt, id, err);
                session.destroy(rt.gpa, rt.io);
                report.skipped += 1;
                continue;
            };
            const entry = try rt.gpa.create(Entry);
            errdefer rt.gpa.destroy(entry);
            const meta = session.metadata;
            const overrides: config.Options = .{
                .profile = if (meta.profile) |v| try rt.gpa.dupe(u8, v) else null,
                .model = if (meta.model) |v| try rt.gpa.dupe(u8, v) else null,
                .environment = if (meta.environment_present) .{
                    .profile = if (meta.environment_profile) |v| try rt.gpa.dupe(u8, v) else null,
                    .model = if (meta.environment_model) |v| try rt.gpa.dupe(u8, v) else null,
                } else null,
            };
            errdefer freeOverrides(rt, overrides);
            entry.* = .{ .session = session, .inbox = .init(rt.gpa, rt.io), .overrides = overrides };
            if (rt.sessions.contains(session.info.id)) {
                entry.inbox.deinit();
                freeOverrides(rt, overrides);
                rt.gpa.destroy(entry);
                session.destroy(rt.gpa, rt.io);
                reportCorrupt(rt, id, error.DuplicateSessionId);
                report.skipped += 1;
                continue;
            }
            try rt.sessions.put(rt.gpa, session.info.id, entry);
            report.loaded += 1;
        }
    }
    return report;
}

fn reportCorrupt(rt: *Runtime, id: []const u8, err: anyerror) void {
    std.log.warn("skipping session {s}: {s}", .{ id, @errorName(err) });
    rt.bus.publishValue(types.session_error, id, null, .{ .@"error" = @errorName(err) }) catch {};
}
