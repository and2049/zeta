//! Embedded self-documentation. Caller owns the returned path (allocator.free).
const std = @import("std");
const manifest = @import("docs_manifest");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const files = manifest.files;

/// Hash includes relative names, lengths, and contents, so rearrangements and
/// bytes both invalidate the directory. Stable across machines and builds.
pub fn contentHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (files) |file| {
        hashField(&hasher, file.name);
        hashField(&hasher, file.content);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    hasher.update(&len);
    hasher.update(bytes);
}

/// Materializes below `data_dir/docs/<hash>`; returns an allocator-owned path.
/// The caller supplies an explicit I/O provider and data directory (normally
/// $XDG_DATA_HOME/zeta or ~/.local/share/zeta). A warm directory is read only.
pub fn materialize(allocator: Allocator, io: Io, data_dir: []const u8) ![]u8 {
    const hash = contentHash();
    const path = try std.fs.path.join(allocator, &.{ data_dir, "docs", &hash });
    errdefer allocator.free(path);
    const parent = try std.fs.path.join(allocator, &.{ data_dir, "docs" });
    defer allocator.free(parent);
    const cwd = Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, parent, .fromMode(0o700));
    var parent_dir = try cwd.openDir(io, parent, .{});
    defer parent_dir.close(io);
    switch (try published(parent_dir, io, &hash)) {
        .complete => return path,
        .missing => {},
        // Left by an interrupted or older writer: set it aside, then rebuild.
        .incomplete => {
            const stale = try uniqueName(allocator, io, &hash, "stale");
            defer allocator.free(stale);
            parent_dir.rename(&hash, parent_dir, stale, io) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            parent_dir.deleteTree(io, stale) catch {};
        },
    }

    const tmp_name = try uniqueName(allocator, io, &hash, "tmp");
    defer allocator.free(tmp_name);
    try parent_dir.createDir(io, tmp_name, .fromMode(0o700));
    var keep = false;
    defer if (!keep) parent_dir.deleteTree(io, tmp_name) catch {};
    var staging = try parent_dir.openDir(io, tmp_name, .{});
    defer staging.close(io);
    inline for (files) |file| {
        if (std.fs.path.dirname(file.name)) |subdir| {
            _ = try staging.createDirPathStatus(io, subdir, .fromMode(0o700));
        }
        try staging.writeFile(io, .{ .sub_path = file.name, .data = file.content });
    }
    // Written last: a directory with the marker holds every file.
    try staging.writeFile(io, .{ .sub_path = complete_marker, .data = "" });
    parent_dir.rename(tmp_name, parent_dir, &hash, io) catch |err| {
        // Directory rename collision errors vary by platform. Only accept a
        // winner that actually published a complete directory.
        if (try published(parent_dir, io, &hash) == .complete) return path;
        return err;
    };
    keep = true;
    return path;
}

const complete_marker = ".complete";

fn published(parent: Io.Dir, io: Io, hash: []const u8) !enum { missing, incomplete, complete } {
    var dir = parent.openDir(io, hash, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer dir.close(io);
    dir.access(io, complete_marker, .{}) catch |err| switch (err) {
        error.FileNotFound => return .incomplete,
        else => return err,
    };
    return .complete;
}

fn uniqueName(allocator: Allocator, io: Io, hash: []const u8, kind: []const u8) ![]u8 {
    var nonce: [16]u8 = undefined;
    Io.random(io, &nonce);
    return std.fmt.allocPrint(allocator, ".{s}.{s}-{x}", .{ hash, kind, std.fmt.bytesToHex(nonce, .lower) });
}

test "embedded content hash changes with names and contents" {
    const actual = contentHash();
    try std.testing.expect(actual.len == 64);
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&h1, "a");
    hashField(&h1, "bc");
    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&h2, "ab");
    hashField(&h2, "c");
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    h1.final(&a);
    h2.final(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectEqualSlices(u8, &actual, &contentHash());
}

test "materialization is complete and warm calls do not write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const first = try materialize(std.testing.allocator, io, base);
    defer std.testing.allocator.free(first);
    const doc = try std.fs.path.join(std.testing.allocator, &.{ first, "README.md" });
    defer std.testing.allocator.free(doc);
    const contents = try Io.Dir.cwd().readFileAlloc(io, doc, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(contents);
    const readme = comptime blk: {
        for (files) |file| {
            if (std.mem.eql(u8, file.name, "README.md")) break :blk file.content;
        }
        @compileError("README.md is missing from the embedded docs manifest");
    };
    try std.testing.expectEqualStrings(readme, contents);
    const example = try std.fs.path.join(std.testing.allocator, &.{ first, "examples", "zeta.jsonc" });
    defer std.testing.allocator.free(example);
    const example_contents = try Io.Dir.cwd().readFileAlloc(io, example, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(example_contents);
    try std.testing.expect(std.mem.indexOf(u8, example_contents, "OPENAI_API_KEY") != null);
    const generated = try std.fs.path.join(std.testing.allocator, &.{ first, "generated", "reference.md" });
    defer std.testing.allocator.free(generated);
    const generated_contents = try Io.Dir.cwd().readFileAlloc(io, generated, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(generated_contents);
    try std.testing.expect(std.mem.indexOf(u8, generated_contents, "### `webfetch`") != null);
    const before = try Io.Dir.cwd().statFile(io, first, .{});
    const file_before = try Io.Dir.cwd().statFile(io, doc, .{});
    const second = try materialize(std.testing.allocator, io, base);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    const after = try Io.Dir.cwd().statFile(io, first, .{});
    const file_after = try Io.Dir.cwd().statFile(io, doc, .{});
    try std.testing.expectEqual(before.mtime, after.mtime);
    try std.testing.expectEqual(file_before.mtime, file_after.mtime);
}

test "a directory without the completion marker is rebuilt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const hash = contentHash();
    const partial = try std.fs.path.join(std.testing.allocator, &.{ "docs", &hash });
    defer std.testing.allocator.free(partial);
    _ = try tmp.dir.createDirPathStatus(io, partial, .fromMode(0o700));
    const leftover = try std.fs.path.join(std.testing.allocator, &.{ partial, "README.md" });
    defer std.testing.allocator.free(leftover);
    try tmp.dir.writeFile(io, .{ .sub_path = leftover, .data = "trunc" });

    const path = try materialize(std.testing.allocator, io, base);
    defer std.testing.allocator.free(path);
    const readme = try std.fs.path.join(std.testing.allocator, &.{ path, "README.md" });
    defer std.testing.allocator.free(readme);
    const contents = try Io.Dir.cwd().readFileAlloc(io, readme, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(!std.mem.eql(u8, "trunc", contents));
    const marker = try std.fs.path.join(std.testing.allocator, &.{ path, complete_marker });
    defer std.testing.allocator.free(marker);
    try Io.Dir.cwd().access(io, marker, .{});

    // Nothing but the published directory is left behind.
    var docs = try tmp.dir.openDir(io, "docs", .{ .iterate = true });
    defer docs.close(io);
    var it = docs.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |_| entries += 1;
    try std.testing.expectEqual(@as(usize, 1), entries);
}
