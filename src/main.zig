const std = @import("std");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cmd: []const u8 = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, cmd, "--version")) {
        return out(io, "zeta {s}\n", .{build_options.version});
    }
    try out(io, usage, .{});
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const usage =
    \\usage: zeta <command>
    \\
    \\  --version    print version
    \\
;
