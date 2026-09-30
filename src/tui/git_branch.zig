//! The git branch of a directory, for the footer: read from `.git/HEAD`
//! (following a worktree's `gitdir:` file); no git process.
const std = @import("std");
const platform = @import("platform");

/// The branch name, a short commit id when detached, or "" outside a
/// repository. Allocated in `a`.
pub fn read(a: std.mem.Allocator, io: std.Io, dir: []const u8) ![]const u8 {
    var at: []const u8 = dir;
    while (true) {
        const dot_git = try std.fs.path.join(a, &.{ at, ".git" });
        if (platform.fs.readFileIfExists(io, a, try std.fs.path.join(a, &.{ dot_git, "HEAD" }), 4096) catch null) |head| return parse(head);
        // A linked worktree's `.git` is a file naming the real directory.
        if (platform.fs.readFileIfExists(io, a, dot_git, 4096) catch null) |link| {
            const trimmed = std.mem.trim(u8, link, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                const target = trimmed["gitdir: ".len..];
                const git_dir = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(a, &.{ at, target });
                const head = (try platform.fs.readFileIfExists(io, a, try std.fs.path.join(a, &.{ git_dir, "HEAD" }), 4096)) orelse return "";
                return parse(head);
            }
        }
        at = std.fs.path.dirname(at) orelse return "";
    }
}

fn parse(head: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) return trimmed["ref: refs/heads/".len..];
    return trimmed[0..@min(7, trimmed.len)];
}

test "branch names and detached heads" {
    try std.testing.expectEqualStrings("main", parse("ref: refs/heads/main\n"));
    try std.testing.expectEqualStrings("feat/x", parse("ref: refs/heads/feat/x"));
    try std.testing.expectEqualStrings("4d06e41", parse("4d06e41f00d\n"));
}
