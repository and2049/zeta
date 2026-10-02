//! `zeta update [<version>]`: replaces this executable with a GitHub release
//! (the latest, or the given tag), checked against the release's SHA256SUMS.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_base = "https://github.com/and2049/zeta";
const max_download = 64 * 1024 * 1024;

pub const Options = struct {
    /// The running version, e.g. `0.2.0`.
    current: []const u8,
    /// This executable; the release replaces it (a symlink keeps pointing
    /// at the replaced file).
    exe: []const u8,
    paths: platform.Paths,
    /// Where releases live; `ZETA_UPDATE_URL` overrides it.
    base: []const u8 = default_base,
};

/// Prints progress to `out`; the exit status.
pub fn run(gpa: Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8, o: Options) !u8 {
    if (args.len > 1 or (args.len == 1 and std.mem.startsWith(u8, args[0], "-"))) {
        try out.writeAll("usage: zeta update [<version>]\n");
        return 2;
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = asset() orelse {
        try out.writeAll("zeta: no release for this platform; build from source with Zig 0.16\n");
        return 1;
    };
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();
    const tag = if (args.len == 1) try normalize(a, args[0]) else latest(a, &http, o.base) catch |err| {
        try out.print("zeta: cannot find the latest release: {s}\n", .{@errorName(err)});
        return 1;
    };
    const version = tag[1..];
    if (std.mem.eql(u8, version, o.current)) {
        try out.print("zeta {s} is already installed\n", .{version});
        return 0;
    }
    try out.print("Downloading zeta {s} ({s})...\n", .{ version, name });
    try out.flush();
    const dir = try std.fmt.allocPrint(a, "{s}/releases/download/{s}", .{ o.base, tag });
    const archive = download(a, &http, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name })) catch |err| {
        try out.print("zeta: downloading {s} {s} failed: {s}\n", .{ tag, name, @errorName(err) });
        return 1;
    };
    const sums = download(a, &http, try std.fmt.allocPrint(a, "{s}/SHA256SUMS", .{dir})) catch |err| {
        try out.print("zeta: downloading {s} SHA256SUMS failed: {s}\n", .{ tag, @errorName(err) });
        return 1;
    };
    if (!verified(archive, sums, name)) {
        try out.print("zeta: checksum mismatch for {s}; nothing changed\n", .{name});
        return 1;
    }
    const binary = extract(a, archive) catch |err| {
        try out.print("zeta: unpacking {s} failed: {s}\n", .{ name, @errorName(err) });
        return 1;
    };
    try platform.fs.writeAtomic(io, a, o.exe, binary);
    try out.print("Updated zeta {s} -> {s} ({s})\n", .{ o.current, version, o.exe });
    if (try @import("admin.zig").running(a, io, o.paths)) |server| if (!std.mem.eql(u8, server.version, version)) {
        try out.print("The shared server still runs zeta {s}; `zeta server stop` lets the next client start the new one.\n", .{server.version});
    };
    return 0;
}

/// This platform's release archive, as the release workflow names it.
fn asset() ?[]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        else => return null,
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    return "zeta-" ++ os ++ "-" ++ arch ++ ".tar.gz";
}

/// `0.2.0` or `v0.2.0` as a tag.
fn normalize(a: Allocator, version: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, version, "v")) return version;
    return std.fmt.allocPrint(a, "v{s}", .{version});
}

/// The latest release's tag, from where `/releases/latest` redirects.
fn latest(a: Allocator, http: *std.http.Client, base: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(a, "{s}/releases/latest", .{base});
    var req = try http.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = .unhandled, .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();
    const response = try req.receiveHead(&.{});
    if (response.head.status.class() != .redirect) return error.NoRelease;
    return tagOf(a, response.head.location orelse return error.NoRelease);
}

/// The tag in a `…/releases/tag/<tag>` location.
fn tagOf(a: Allocator, location: []const u8) ![]const u8 {
    const marker = "/releases/tag/";
    const at = std.mem.lastIndexOf(u8, location, marker) orelse return error.NoRelease;
    const tag = location[at + marker.len ..];
    if (tag.len < 2 or tag[0] != 'v' or std.mem.indexOfAny(u8, tag, "/?#") != null) return error.NoRelease;
    return a.dupe(u8, tag);
}

fn download(a: Allocator, http: *std.http.Client, url: []const u8) ![]const u8 {
    var req = try http.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();
    // Release downloads redirect to a storage host.
    var redirects: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirects);
    if (response.head.status != .ok) return error.HttpStatus;
    var transfer: [16 * 1024]u8 = undefined;
    return response.reader(&transfer).allocRemaining(a, .limited(max_download)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
}

/// Whether `archive` has the SHA-256 `sums` lists for `name`.
fn verified(archive: []const u8, sums: []const u8, name: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var lines = std.mem.tokenizeScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t*");
        const sum = words.next() orelse continue;
        const file = words.next() orelse continue;
        if (std.mem.eql(u8, file, name)) return std.mem.eql(u8, sum, &hex);
    }
    return false;
}

/// The `zeta` executable inside a release archive (gzip-compressed tar).
fn extract(a: Allocator, archive: []const u8) ![]const u8 {
    var input: Io.Reader = .fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gzip.reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    while (try it.next()) |file| {
        if (file.kind != .file or !std.mem.eql(u8, std.fs.path.basename(file.name), "zeta")) continue;
        if (file.size > max_download) return error.TooLarge;
        var out: Io.Writer.Allocating = .init(a);
        try it.streamRemaining(file, &out.writer);
        return out.written();
    }
    return error.NoExecutable;
}

test "release names, tags and checksums" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) try std.testing.expectEqualStrings("zeta-linux-x86_64.tar.gz", asset().?);
    try std.testing.expectEqualStrings("v0.3.0", try normalize(a, "0.3.0"));
    try std.testing.expectEqualStrings("v0.3.0", try normalize(a, "v0.3.0"));
    try std.testing.expectEqualStrings("v0.2.0", try tagOf(a, "https://github.com/and2049/zeta/releases/tag/v0.2.0"));
    try std.testing.expectError(error.NoRelease, tagOf(a, "https://github.com/and2049/zeta/releases"));
    const sums = "abc  other.tar.gz\n" ++
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  zeta-linux-x86_64.tar.gz\n";
    try std.testing.expect(verified("abc", sums, "zeta-linux-x86_64.tar.gz"));
    try std.testing.expect(!verified("abd", sums, "zeta-linux-x86_64.tar.gz"));
    try std.testing.expect(!verified("abc", sums, "zeta-darwin-aarch64.tar.gz"));
}
