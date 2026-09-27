//! `--standalone`: a private server for this client alone, instead of the
//! shared one. It keeps its discovery record, lock and log in a directory of
//! its own, does not load the sessions other servers serve, and stops when
//! this process ends (or asks it to); it removes that directory itself.
const std = @import("std");
const platform = @import("platform");
const attach = @import("attach.zig");
const admin = @import("admin.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Private = struct {
    /// `runtime` is the private directory; the rest are the caller's.
    paths: platform.Paths,
    /// How attach starts it again, if it has to.
    serve: []const []const u8,
    log: []const u8,

    /// Stops the server (which removes its directory; so does this, for a
    /// server that never got going).
    pub fn stop(p: Private, gpa: Allocator, io: Io) void {
        _ = admin.stop(gpa, io, p.paths) catch {};
        Io.Dir.cwd().deleteTree(io, p.paths.runtime) catch {};
    }
};

/// Starts the private server and waits until it answers. Strings are in
/// `arena`.
pub fn start(gpa: Allocator, arena: Allocator, io: Io, paths: platform.Paths, exe: []const u8) !Private {
    const pid: i64 = @intCast(std.c.getpid());
    var private = paths;
    private.runtime = try std.fmt.allocPrint(arena, "{s}/standalone-{d}", .{ paths.runtime, pid });
    const out: Private = .{
        .paths = private,
        .serve = try arena.dupe([]const u8, &.{ "serve", "--runtime-dir", private.runtime, "--parent", try std.fmt.allocPrint(arena, "{d}", .{pid}) }),
        .log = try std.fs.path.join(arena, &.{ private.runtime, "server.log" }),
    };
    errdefer out.stop(gpa, io);
    _ = try attach.attach(gpa, arena, io, .{ .paths = private, .exe = exe, .serve = out.serve, .log = out.log });
    return out;
}
