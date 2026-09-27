const std = @import("std");
const core = @import("core");
const Ctx = @import("conn.zig").Ctx;
const query = @import("query.zig");

/// Arbitrary absolute directories for the project picker (including hidden).
pub fn directories(c: *Ctx) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const path = (try query.get(c.arena, c.query, "path")) orelse return c.fail(.bad_request, "path required");
    if (!std.fs.path.isAbsolute(path)) return c.fail(.bad_request, "path must be absolute");
    const dir = std.Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return c.fail(.not_found, "directory not found"),
        error.NotDir => return c.fail(.bad_request, "not a directory"),
        else => return err,
    };
    defer dir.close(c.io);
    const Directory = struct { name: []const u8 };
    var entries: std.ArrayList(Directory) = .empty;
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory) continue;
        try entries.append(c.arena, .{ .name = try c.arena.dupe(u8, entry.name) });
    }
    std.mem.sort(Directory, entries.items, {}, struct {
        fn less(_: void, a: Directory, b: Directory) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return c.json(.ok, .{ .entries = entries.items[0..@min(entries.items.len, 500)] });
}

pub fn dispatch(c: *Ctx, action: []const u8) !void {
    if (c.method != .GET) return c.fail(.method_not_allowed, "method not allowed");
    const raw = (try query.get(c.arena, c.query, "location")) orelse return c.fail(.bad_request, "location required");
    const location = core.location.resolve(c.arena, c.io, raw) catch return c.fail(.bad_request, "invalid location");
    const path = (try query.get(c.arena, c.query, "path")) orelse "";
    if (std.mem.eql(u8, action, "list")) {
        const entries = core.workspace_files.list(c.arena, c.io, location, path) catch |err| return fileError(c, err);
        return c.json(.ok, .{ .entries = entries });
    }
    if (std.mem.eql(u8, action, "find")) {
        const q = (try query.get(c.arena, c.query, "q")) orelse return c.fail(.bad_request, "q required");
        const text = (try query.get(c.arena, c.query, "limit")) orelse "50";
        const limit = std.fmt.parseInt(usize, text, 10) catch return c.fail(.bad_request, "invalid limit");
        if (limit == 0) return c.fail(.bad_request, "invalid limit");
        const matches = core.workspace_files.find(c.arena, c.io, location, q, @min(limit, 100)) catch |err| return fileError(c, err);
        return c.json(.ok, .{ .matches = matches });
    }
    const offset_text = (try query.get(c.arena, c.query, "offset")) orelse "0";
    const limit_text = (try query.get(c.arena, c.query, "limit")) orelse "65536";
    const offset = std.fmt.parseInt(usize, offset_text, 10) catch return c.fail(.bad_request, "invalid offset");
    const limit = std.fmt.parseInt(usize, limit_text, 10) catch return c.fail(.bad_request, "invalid limit");
    if (limit == 0 or limit > 65536) return c.fail(.bad_request, "invalid limit");
    const value = core.workspace_files.read(c.arena, c.io, location, path, offset, limit) catch |err| return fileError(c, err);
    return c.json(.ok, value);
}

fn fileError(c: *Ctx, err: anyerror) !void {
    return switch (err) {
        error.InvalidPath, error.OutsideLocation => c.fail(.bad_request, "invalid path"),
        error.FileNotFound, error.NotDir => c.fail(.not_found, "file not found"),
        error.FileTooLarge, error.StreamTooLong => c.fail(.payload_too_large, "file too large"),
        error.BinaryFile => c.fail(.unprocessable_entity, "binary file"),
        error.InvalidOffset => c.fail(.bad_request, "invalid offset or limit"),
        else => err,
    };
}
