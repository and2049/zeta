//! The model and thinking level a session runs with when nothing selects
//! them: config, else the last pick remembered in `<state>/model.json`,
//! else the first model a connected provider lists.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "model.json";
const max_file = 64 * 1024;

/// The last model and thinking level picked in any session.
pub const Remembered = struct {
    model: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
};

/// A missing or unreadable file remembers nothing. Strings live in `arena`.
pub fn read(arena: Allocator, io: Io, state_dir: []const u8) Remembered {
    const path = std.fs.path.join(arena, &.{ state_dir, file_name }) catch return .{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)) catch return .{};
    const value = std.json.parseFromSliceLeaky(Remembered, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{};
    if (value.model) |model| if (config.splitModel(model) == null) return .{ .thinking = value.thinking };
    return value;
}

/// Replaces the file atomically.
pub fn write(arena: Allocator, io: Io, state_dir: []const u8, value: Remembered) !void {
    const encoded = try std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
    const path = try std.fs.path.join(arena, &.{ state_dir, file_name });
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Records a pick: `model` and `thinking` replace what was remembered when
/// given; thinking `auto` forgets the level. Best effort: a failure only
/// loses the default for later sessions.
pub fn remember(rt: *Runtime, model: ?[]const u8, thinking: ?[]const u8) void {
    const dir = rt.state_dir orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value = read(arena, rt.io, dir);
    if (model) |m| value.model = m;
    if (thinking) |level| value.thinking = if (std.mem.eql(u8, level, "auto")) null else level;
    write(arena, rt.io, dir, value) catch |err| std.log.warn("could not remember the model: {s}", .{@errorName(err)});
}

/// Fills `cfg.model` and `cfg.thinking` when no layer set them. Uses the
/// providers already active for `location`; everything lives in `arena`.
pub fn fill(rt: *Runtime, arena: Allocator, location: []const u8, cfg: *config.Config) !void {
    const remembered: Remembered = if (rt.state_dir) |dir| read(arena, rt.io, dir) else .{};
    if (cfg.thinking == null) if (remembered.thinking) |level| if (@import("proto").thinking.Level.parse(level) != null) {
        cfg.thinking = level;
        try cfg.provenance.put(arena, "thinking", .remembered);
    };
    if (cfg.model != null) return;
    if (remembered.model) |model| {
        cfg.model = model;
        return cfg.provenance.put(arena, "model", .remembered);
    }
    const view = try rt.registry.view(arena, location);
    cfg.model = first(arena, try @import("runtime_route.zig").models(view, arena, rt.io, cfg.*)) orelse return;
    try cfg.provenance.put(arena, "model", .fallback);
}

/// Records the model (and thinking level, when given) a session runs with
/// as its own selection, without remembering it as a pick.
pub fn pin(rt: *Runtime, entry: *Runtime.Entry, model: []const u8, thinking: ?[]const u8) !void {
    rt.mutex.lockUncancelable(rt.io);
    defer rt.mutex.unlock(rt.io);
    const owned = try rt.gpa.dupe(u8, model);
    errdefer rt.gpa.free(owned);
    try entry.session.update(model, null, thinking);
    if (entry.overrides.model) |old| rt.gpa.free(old);
    entry.overrides.model = owned;
    rt.bus.publishValue(@import("proto").event.types.session_updated, entry.session.info.id, entry.session.info.location, .{ .session = entry.session.info, .model = entry.overrides.model, .thinking = entry.session.metadata.thinking }) catch {};
}

/// `provider/model` for the first model in a listing.
fn first(arena: Allocator, providers: []const std.json.Value) ?[]const u8 {
    for (providers) |provider| {
        if (provider != .object) continue;
        const id = provider.object.get("id") orelse continue;
        const models = provider.object.get("models") orelse continue;
        if (id != .string or models != .array) continue;
        for (models.array.items) |model| {
            if (model != .object) continue;
            const model_id = model.object.get("id") orelse continue;
            if (model_id != .string) continue;
            return std.fmt.allocPrint(arena, "{s}/{s}", .{ id.string, model_id.string }) catch null;
        }
    }
    return null;
}

test "remembered picks round-trip; a bad file remembers nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try std.testing.expect(read(arena, io, dir).model == null);
    try write(arena, io, dir, .{ .model = "p/m", .thinking = "high" });
    const back = read(arena, io, dir);
    try std.testing.expectEqualStrings("p/m", back.model.?);
    try std.testing.expectEqualStrings("high", back.thinking.?);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"model\":\"no-slash\",\"thinking\":\"low\"}" });
    const partial = read(arena, io, dir);
    try std.testing.expect(partial.model == null);
    try std.testing.expectEqualStrings("low", partial.thinking.?);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "not json" });
    try std.testing.expect(read(arena, io, dir).thinking == null);
}

test "the first listed model" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listing = try std.json.parseFromSliceLeaky([]const std.json.Value, arena,
        \\[{"id":"empty","models":[]},{"id":"p","models":[{"id":"a"},{"id":"b"}]}]
    , .{});
    try std.testing.expectEqualStrings("p/a", first(arena, listing).?);
    try std.testing.expect(first(arena, &.{}) == null);
}
