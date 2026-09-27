//! The `command` capability: a slash command that turns its arguments into
//! the prompt a session gets. Reserved names (`proto.commands.builtin`)
//! cannot be registered.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    argument_hint: ?[]const u8 = null,
    ctx: ?*anyopaque = null,
    /// The prompt text for `arguments` (as typed after the name) at
    /// `location`, allocated in `arena`. A failure the user should read
    /// goes through `problem.fail`.
    run: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, location: []const u8, arguments: []const u8, problem: *Problem) anyerror![]const u8,
};

/// Why a command failed, in words for the user (cut to fit).
pub const Problem = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn fail(p: *Problem, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
        var w: Io.Writer = .fixed(&p.buf);
        w.print(fmt, args) catch {};
        p.len = w.end;
        return error.CommandFailed;
    }

    pub fn text(p: *const Problem) []const u8 {
        return p.buf[0..p.len];
    }
};
