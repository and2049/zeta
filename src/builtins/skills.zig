//! Skill metadata discovery. The SKILL.md body is deliberately not retained.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const max_skill_file = 1024 * 1024;

/// Bounds on what discovery reads and what reaches the prompt, so a huge or
/// hostile skills tree cannot stall a run or crowd out the context.
pub const Limits = struct {
    /// Directories opened across all roots.
    directories: usize = 4096,
    /// Distinct skill names kept. Overrides of a kept name still apply.
    skills: usize = 256,
    /// Total size of the prompt's skill list.
    prompt_bytes: usize = 32 * 1024,
};

const Scan = struct {
    arena: Allocator,
    io: Io,
    limits: Limits,
    found: std.StringHashMapUnmanaged(Skill) = .empty,
    directories: usize = 0,
    truncated: bool = false,
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

/// Returned strings and slice belong to arena. Later roots override earlier roots.
pub fn discover(arena: Allocator, io: Io, home: []const u8, config_dir: []const u8, location: []const u8) ![]Skill {
    return discoverLimited(arena, io, home, config_dir, location, .{});
}

pub fn discoverLimited(arena: Allocator, io: Io, home: []const u8, config_dir: []const u8, location: []const u8, limits: Limits) ![]Skill {
    var s: Scan = .{ .arena = arena, .io = io, .limits = limits };
    const roots = [_][]const u8{
        try std.fs.path.join(arena, &.{ home, ".agents", "skills" }),
        try std.fs.path.join(arena, &.{ config_dir, "skills" }),
        try std.fs.path.join(arena, &.{ location, ".agents", "skills" }),
        try std.fs.path.join(arena, &.{ location, ".zeta", "skills" }),
    };
    for (roots) |root| try scan(&s, root, 0);
    if (s.truncated) std.log.warn("skill discovery stopped at {d} directories or {d} skills; some skills were skipped", .{ limits.directories, limits.skills });
    var list: std.ArrayList(Skill) = .empty;
    var it = s.found.valueIterator();
    while (it.next()) |skill| try list.append(arena, skill.*);
    std.mem.sort(Skill, list.items, {}, struct {
        fn less(_: void, a: Skill, b: Skill) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return list.toOwnedSlice(arena);
}

fn scan(s: *Scan, root: []const u8, depth: usize) !void {
    if (depth > 8) return;
    const arena = s.arena;
    const io = s.io;
    if (s.directories >= s.limits.directories) {
        s.truncated = true;
        return;
    }
    const dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    s.directories += 1;
    if (depth > 0) {
        var scratch_state = std.heap.ArenaAllocator.init(arena);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const data = dir.readFileAlloc(io, "SKILL.md", scratch, .limited(max_skill_file)) catch |err| switch (err) {
            error.FileNotFound, error.FileTooBig, error.StreamTooLong => null,
            else => |e| return e,
        };
        if (data) |text| {
            if (try parse(scratch, text, root)) |skill| add: {
                if (s.found.count() >= s.limits.skills and !s.found.contains(skill.name)) {
                    s.truncated = true;
                    break :add;
                }
                const owned: Skill = .{
                    .name = try arena.dupe(u8, skill.name),
                    .description = try arena.dupe(u8, skill.description),
                    .path = try std.fs.path.join(arena, &.{ root, "SKILL.md" }),
                };
                try s.found.put(arena, owned.name, owned);
            }
        }
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child = try std.fs.path.join(arena, &.{ root, entry.name });
        try scan(s, child, depth + 1);
    }
}

/// Frontmatter `name` and `description`; null when missing or invalid.
/// `path` is stored as given.
pub fn parse(arena: Allocator, text: []const u8, path: []const u8) !?Skill {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var block: ?u8 = null;
    var block_text: std.ArrayList(u8) = .empty;
    var closed = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            closed = true;
            break;
        }
        if (block) |style| {
            if (raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t')) {
                if (line.len > 0) {
                    if (block_text.items.len > 0) try block_text.append(arena, if (style == '|') '\n' else ' ');
                    try block_text.appendSlice(arena, line);
                }
                if (block_text.items.len > 1024) return null;
                continue;
            }
            description = block_text.items;
            block = null;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
        if (std.mem.eql(u8, key, "name")) name = value;
        if (std.mem.eql(u8, key, "description")) {
            if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, "|")) {
                block = value[0];
                block_text = .empty;
            } else description = value;
        }
    }
    if (block != null) description = block_text.items;
    if (!closed or name == null or description == null or description.?.len == 0 or description.?.len > 1024) return null;
    const n = name.?;
    if (n.len == 0 or n.len > 64 or n[0] == '-' or n[n.len - 1] == '-') return null;
    var last_hyphen = false;
    for (n) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return null;
        if (c == '-' and last_hyphen) return null;
        last_hyphen = c == '-';
    }
    return .{ .name = n, .description = description.?, .path = path };
}

/// Metadata only; no skill body enters the prompt until the skill tool is invoked.
/// Skills past `max_bytes` of listing are left out and logged once.
pub fn promptMetadata(arena: Allocator, discovered: []const Skill) ![]const u8 {
    return promptMetadataLimited(arena, discovered, (Limits{}).prompt_bytes);
}

fn promptMetadataLimited(arena: Allocator, discovered: []const Skill, max_bytes: usize) ![]const u8 {
    var writer: Io.Writer.Allocating = .init(arena);
    for (discovered, 0..) |skill, i| {
        const line = 4 + skill.name.len + skill.description.len;
        if (writer.written().len + line > max_bytes) {
            std.log.warn("skill list exceeds {d} bytes; {d} skills left out of the prompt", .{ max_bytes, discovered.len - i });
            break;
        }
        try writer.writer.print("- {s}: {s}\n", .{ skill.name, skill.description });
    }
    return writer.written();
}

test "malformed frontmatter is ignored" {
    const arena = std.testing.allocator;
    try std.testing.expect((try parse(arena, "# no frontmatter", "x")) == null);
    try std.testing.expect((try parse(arena, "---\nname: foo\n---\nbody", "x")) == null);
    try std.testing.expect((try parse(arena, "---\nname: BAD\ndescription: yes\n---\n", "x")) == null);
    try std.testing.expect((try parse(arena, "---\nname: okay\ndescription: valid\nbody", "x")) == null);
    const valid = (try parse(arena, "---\nname: okay\ndescription: valid\n---\nSECRET", "x")).?;
    try std.testing.expectEqualStrings("valid", valid.description);
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const multiline = (try parse(state.allocator(), "---\nname: okay\ndescription: >\n  two lines\n  joined\n---\nbody", "x")).?;
    try std.testing.expectEqualStrings("two lines joined", multiline.description);
}

test "project zeta overrides agents and user resources" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = [_][]const u8{
        "home/.agents/skills/demo",
        "config/skills/demo",
        "project/.agents/skills/demo",
        "project/.zeta/skills/demo",
    };
    for (names, 0..) |dir, idx| {
        _ = try tmp.dir.createDirPathStatus(io, dir, .default_dir);
        const file = try std.fs.path.join(arena, &.{ dir, "SKILL.md" });
        const text = try std.fmt.allocPrint(arena, "---\nname: demo\ndescription: source {d}\n---\nSECRET BODY", .{idx});
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = text });
    }
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const found = try discover(arena, io, try std.fs.path.join(arena, &.{ base, "home" }), try std.fs.path.join(arena, &.{ base, "config" }), try std.fs.path.join(arena, &.{ base, "project" }));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("source 3", found[0].description);
    const metadata = try promptMetadata(arena, found);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "SECRET BODY") == null);
}

test "discovery and the prompt listing are bounded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..6) |i| {
        const dir = try std.fmt.allocPrint(arena, "project/.zeta/skills/s{d}", .{i});
        _ = try tmp.dir.createDirPathStatus(io, dir, .default_dir);
        const text = try std.fmt.allocPrint(arena, "---\nname: s{d}\ndescription: skill {d}\n---\n", .{ i, i });
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "SKILL.md" }), .data = text });
    }
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const home = try std.fs.path.join(arena, &.{ base, "home" });
    const project = try std.fs.path.join(arena, &.{ base, "project" });

    const all = try discoverLimited(arena, io, home, home, project, .{});
    try std.testing.expectEqual(@as(usize, 6), all.len);
    const few = try discoverLimited(arena, io, home, home, project, .{ .skills = 2 });
    try std.testing.expectEqual(@as(usize, 2), few.len);
    // The root plus two skill directories.
    const shallow = try discoverLimited(arena, io, home, home, project, .{ .directories = 3 });
    try std.testing.expectEqual(@as(usize, 2), shallow.len);

    const listing = try promptMetadataLimited(arena, all, 40);
    try std.testing.expectEqualStrings("- s0: skill 0\n- s1: skill 1\n", listing);
}
