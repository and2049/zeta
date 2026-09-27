//! What plugins have registered. Every entry belongs to a plugin, and every
//! plugin sits in a layer: built-in, user or project. By name, an entry from
//! a narrower layer shadows one from a wider layer; two entries with the same
//! name in the same layer are rejected. Disposing a plugin removes its
//! entries, so whatever they shadowed shows again. A run works from a `View`
//! taken when it starts and never sees later changes.
//!
//! Plugins from outside the binary come from loaders (see Loaders.zig),
//! which build a scope the first time it is used and again on reload. Reload
//! builds a replacement beside the live plugin: `stage` it, register its
//! entries, then `commit` (the old one goes, the new one shows) or `dispose`
//! it (the old one stays).

const Registry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const provider_api = @import("provider.zig");
const tool_api = @import("tool.zig");
const hook_api = @import("hook.zig");
const command_api = @import("command.zig");
const section_api = @import("section.zig");
const proto = @import("proto");
const schema = @import("schema.zig");
pub const Loaders = @import("Loaders.zig");

/// Ordered from widest to narrowest.
pub const Layer = enum { builtin, user, project };

pub const Plugin = struct {
    id: []const u8,
    layer: Layer = .builtin,
    /// Required for the project layer: its entries apply only there.
    location: ?[]const u8 = null,
    /// "builtin", or the path the plugin was loaded from.
    source: []const u8 = "builtin",
    /// JSON Schema (the tool-schema subset) for `plugin.<id>` config. Null
    /// leaves that config unchecked.
    config_schema: ?[]const u8 = null,
};

pub const Owner = enum(u32) { _ };

const State = enum { staged, live, gone };

pub const Failure = Loaders.Failure;
pub const Loader = Loaders.Loader;
pub const Problem = Loaders.Problem;

fn Entry(comptime T: type) type {
    return struct { owner: Owner, value: T };
}

/// A registered value and the id of the plugin that provided it.
pub fn Resolved(comptime T: type) type {
    return struct { plugin: []const u8, value: T };
}

gpa: Allocator,
io: Io,
mutex: Io.Mutex = .init,
/// Registrations are shallow copies. A registrant keeps names, schemas,
/// descriptions and ctx alive until every view taken while it was
/// registered is gone; built-ins are static.
plugins: std.ArrayList(struct { plugin: Plugin, state: State, replaces: ?Owner = null }) = .empty,
tools: std.ArrayList(Entry(tool_api.Tool)) = .empty,
apis: std.ArrayList(Entry(provider_api.Api)) = .empty,
providers: std.ArrayList(Entry(provider_api.Provider)) = .empty,
/// Hooks have no name: all of them apply, none shadow.
hooks: std.ArrayList(Entry(hook_api.Hook)) = .empty,
commands: std.ArrayList(Entry(command_api.Command)) = .empty,
sections: std.ArrayList(Entry(section_api.Section)) = .empty,
loaders: Loaders,

pub fn init(gpa: Allocator, io: Io) Registry {
    return .{ .gpa = gpa, .io = io, .loaders = .{ .gpa = gpa } };
}

pub fn deinit(r: *Registry) void {
    r.plugins.deinit(r.gpa);
    r.tools.deinit(r.gpa);
    r.apis.deinit(r.gpa);
    r.providers.deinit(r.gpa);
    r.hooks.deinit(r.gpa);
    r.commands.deinit(r.gpa);
    r.sections.deinit(r.gpa);
    r.loaders.deinit();
}

/// Plugin ids are unique among live and staged plugins of one scope: the
/// built-in layer, the user layer, or one project location. The same
/// project plugin can run in many projects.
pub fn addPlugin(r: *Registry, new: Plugin) !Owner {
    return r.insert(new, .live, null);
}

/// A plugin that stays hidden until `commit`. With `replaces`, it may reuse
/// that plugin's id and names, and `commit` disposes the old one.
pub fn stage(r: *Registry, new: Plugin, replaces: ?Owner) !Owner {
    return r.insert(new, .staged, replaces);
}

fn insert(r: *Registry, new: Plugin, state: State, replaces: ?Owner) !Owner {
    if ((new.layer == .project) != (new.location != null)) return error.InvalidPlugin;
    if (new.config_schema) |text| try checkSchema(r.gpa, text);
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    for (r.plugins.items, 0..) |slot, i| {
        if (replaces != null and i == @intFromEnum(replaces.?)) continue;
        if (slot.state != .gone and sameScope(slot.plugin, new) and std.mem.eql(u8, slot.plugin.id, new.id)) return error.DuplicatePlugin;
    }
    try r.plugins.append(r.gpa, .{ .plugin = new, .state = state, .replaces = replaces });
    return @enumFromInt(r.plugins.items.len - 1);
}

/// Shows a staged plugin and disposes the one it replaces, in one step.
pub fn commit(r: *Registry, owner: Owner) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const slot = &r.plugins.items[@intFromEnum(owner)];
    std.debug.assert(slot.state == .staged);
    if (slot.replaces) |old| r.remove(old);
    slot.state = .live;
    slot.replaces = null;
}

/// Shows every staged plugin in `live` and disposes every plugin in `gone`,
/// in one step: no view sees part of the change. Entries of `live` keep
/// their order relative to each other.
pub fn swap(r: *Registry, live: []const Owner, gone: []const Owner) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    for (gone) |owner| r.remove(owner);
    for (live) |owner| {
        const slot = &r.plugins.items[@intFromEnum(owner)];
        std.debug.assert(slot.state == .staged);
        if (slot.replaces) |old| r.remove(old);
        slot.state = .live;
        slot.replaces = null;
    }
}

/// Removes the plugin and everything it registered.
pub fn dispose(r: *Registry, owner: Owner) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.remove(owner);
}

fn remove(r: *Registry, owner: Owner) void {
    r.plugins.items[@intFromEnum(owner)].state = .gone;
    inline for (.{ &r.tools, &r.apis, &r.providers, &r.hooks, &r.commands, &r.sections }) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].owner == owner) _ = list.orderedRemove(i) else i += 1;
        }
    }
}

/// `loader` and its ctx must outlive the registry.
pub fn addLoader(r: *Registry, loader: Loader) !void {
    try r.loaders.add(r.io, loader);
}

/// Loads the user layer and `location` if nothing has yet. Call before
/// `view` wherever loaded plugins should show; never under a lock a loader
/// could need. Failures of this call live in `arena`.
pub fn activate(r: *Registry, arena: Allocator, location: ?[]const u8) ![]const Failure {
    return r.loaders.activate(r.io, arena, location);
}

/// Waits until what loaders started for `location` has settled (bounded by
/// each loader). Call before taking a view for a run.
pub fn settle(r: *Registry, location: []const u8) Io.Cancelable!void {
    return r.loaders.settle(r.io, location);
}

/// Runs every loader for the user layer and `location` (null: every loaded
/// location), one reload at a time. A loader that fails as a whole is
/// reported under its own name. Failures live in `arena`.
pub fn reload(r: *Registry, arena: Allocator, location: ?[]const u8) ![]const Failure {
    return r.loaders.reload(r.io, arena, location);
}

pub fn addTool(r: *Registry, owner: Owner, new: tool_api.Tool) !void {
    // Validate before publishing so an unsupported schema can never reach
    // provider advertisement or execution.
    const parsed = try std.json.parseFromSlice(std.json.Value, r.gpa, new.input_schema, .{});
    defer parsed.deinit();
    try schema.check(parsed.value);
    try new.checkPermission(parsed.value);
    try r.add(tool_api.Tool, &r.tools, owner, new);
}

pub fn addApi(r: *Registry, owner: Owner, new: provider_api.Api) !void {
    try r.add(provider_api.Api, &r.apis, owner, new);
}

pub fn addProvider(r: *Registry, owner: Owner, new: provider_api.Provider) !void {
    try r.add(provider_api.Provider, &r.providers, owner, new);
}

pub fn addCommand(r: *Registry, owner: Owner, new: command_api.Command) !void {
    if (new.name.len == 0 or proto.commands.isBuiltin(new.name)) return error.ReservedCommand;
    for (new.name) |c| if (std.ascii.isWhitespace(c) or c == '/') return error.InvalidCommandName;
    try r.add(command_api.Command, &r.commands, owner, new);
}

/// A section of the system prompt, after the project's instructions.
pub fn addSection(r: *Registry, owner: Owner, new: section_api.Section) !void {
    try r.add(section_api.Section, &r.sections, owner, new);
}

pub fn addHook(r: *Registry, owner: Owner, new: hook_api.Hook) !void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.plugins.items[@intFromEnum(owner)].state == .gone) return error.PluginDisposed;
    try r.hooks.append(r.gpa, .{ .owner = owner, .value = new });
}

fn add(r: *Registry, comptime T: type, list: *std.ArrayList(Entry(T)), owner: Owner, new: T) !void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const slot = r.plugins.items[@intFromEnum(owner)];
    if (slot.state == .gone) return error.PluginDisposed;
    for (list.items) |existing| {
        if (!std.mem.eql(u8, key(existing.value), key(new))) continue;
        if (slot.replaces != null and existing.owner == slot.replaces.?) continue;
        if (sameScope(r.plugins.items[@intFromEnum(existing.owner)].plugin, slot.plugin)) return error.DuplicateRegistration;
    }
    try list.append(r.gpa, .{ .owner = owner, .value = new });
}

fn key(value: anytype) []const u8 {
    return switch (@TypeOf(value)) {
        tool_api.Tool, command_api.Command, section_api.Section => value.name,
        else => value.id,
    };
}

fn sameScope(a: Plugin, b: Plugin) bool {
    if (a.layer != b.layer) return false;
    if (a.layer != .project) return true;
    return std.mem.eql(u8, a.location.?, b.location.?);
}

fn checkSchema(gpa: Allocator, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    try schema.check(parsed.value);
}

/// What applies at one location, with shadowing resolved. Entries keep the
/// order in which their name was first registered.
pub const View = struct {
    plugins: []const Plugin,
    tools: []const Resolved(tool_api.Tool),
    apis: []const Resolved(provider_api.Api),
    providers: []const Resolved(provider_api.Provider),
    /// In load order: built-in, user, project; registration order within.
    hooks: []const Resolved(hook_api.Hook),
    /// What the loaders could not load for the user layer and this location.
    problems: []const Problem = &.{},
    commands: []const Resolved(command_api.Command) = &.{},
    sections: []const Resolved(section_api.Section) = &.{},

    pub fn tool(v: View, name: []const u8) ?tool_api.Tool {
        for (v.tools) |t| if (std.mem.eql(u8, t.value.name, name)) return t.value;
        return null;
    }

    pub fn api(v: View, id: []const u8) ?provider_api.Api {
        for (v.apis) |a| if (std.mem.eql(u8, a.value.id, id)) return a.value;
        return null;
    }

    /// The registration for `id`, else the fallback registered as `*`.
    pub fn provider(v: View, id: []const u8) ?Resolved(provider_api.Provider) {
        var fallback: ?Resolved(provider_api.Provider) = null;
        for (v.providers) |p| {
            if (std.mem.eql(u8, p.value.id, id)) return p;
            if (std.mem.eql(u8, p.value.id, "*")) fallback = p;
        }
        return fallback;
    }

    /// The tools alone, copied into `arena`.
    pub fn toolValues(v: View, arena: Allocator) ![]tool_api.Tool {
        const out = try arena.alloc(tool_api.Tool, v.tools.len);
        for (v.tools, out) |t, *o| o.* = t.value;
        return out;
    }
};

/// Null `location` sees only the built-in and user layers. Everything
/// returned is allocated in `arena`; the values are borrowed as described
/// on the lists above.
pub fn view(r: *Registry, arena: Allocator, location: ?[]const u8) !View {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    var plugins: std.ArrayList(Plugin) = .empty;
    for (r.plugins.items) |slot| {
        if (slot.state == .live and applies(slot.plugin, location)) try plugins.append(arena, slot.plugin);
    }
    return .{
        .plugins = plugins.items,
        .tools = try r.resolve(tool_api.Tool, arena, r.tools.items, location),
        .apis = try r.resolve(provider_api.Api, arena, r.apis.items, location),
        .providers = try r.resolve(provider_api.Provider, arena, r.providers.items, location),
        .hooks = try r.ordered(arena, location),
        .problems = try r.loaders.problemsAt(r.io, arena, location),
        .commands = try r.resolve(command_api.Command, arena, r.commands.items, location),
        .sections = try r.resolve(section_api.Section, arena, r.sections.items, location),
    };
}

fn applies(p: Plugin, location: ?[]const u8) bool {
    if (p.layer != .project) return true;
    const here = location orelse return false;
    return std.mem.eql(u8, p.location.?, here);
}

fn ordered(r: *Registry, arena: Allocator, location: ?[]const u8) ![]const Resolved(hook_api.Hook) {
    var out: std.ArrayList(Resolved(hook_api.Hook)) = .empty;
    for (std.enums.values(Layer)) |layer| for (r.hooks.items) |entry| {
        const slot = r.plugins.items[@intFromEnum(entry.owner)];
        const owner = slot.plugin;
        if (slot.state == .live and owner.layer == layer and applies(owner, location)) try out.append(arena, .{ .plugin = owner.id, .value = entry.value });
    };
    return out.items;
}

fn resolve(r: *Registry, comptime T: type, arena: Allocator, entries: []const Entry(T), location: ?[]const u8) ![]const Resolved(T) {
    var out: std.ArrayList(Resolved(T)) = .empty;
    var layers: std.ArrayList(Layer) = .empty;
    next: for (entries) |entry| {
        const slot = r.plugins.items[@intFromEnum(entry.owner)];
        const owner = slot.plugin;
        if (slot.state != .live or !applies(owner, location)) continue;
        for (out.items, layers.items) |*existing, *layer| {
            if (!std.mem.eql(u8, key(existing.value), key(entry.value))) continue;
            if (@intFromEnum(owner.layer) > @intFromEnum(layer.*)) {
                existing.* = .{ .plugin = owner.id, .value = entry.value };
                layer.* = owner.layer;
            }
            continue :next;
        }
        try out.append(arena, .{ .plugin = owner.id, .value = entry.value });
        try layers.append(arena, owner.layer);
    }
    return out.items;
}

test {
    _ = @import("Registry_test.zig");
    _ = @import("Loaders.zig");
}
