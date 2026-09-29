//! Command hooks: each `hooks.json` is a plugin in its layer. User files are
//! `~/.agents/hooks.json` then `<config dir>/hooks.json`; project files are
//! `<project>/.agents/hooks.json` then `<project>/.zeta/hooks.json`. Every file
//! runs; later files run later. A file is read when its scope is first used
//! and again on reload; one that no longer parses keeps its previous version
//! (and its place in the order).
//!
//! Events map onto hook points: SessionStart → session_start,
//! UserPromptSubmit → prompt_submit, PreToolUse → tool_pre,
//! PermissionRequest → permission, PostToolUse/PostToolUseFailure →
//! tool_post, Stop → turn_stop.
const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const file = @import("file.zig");
const run_mod = @import("run.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hook = plugin.hook;
const Value = std.json.Value;

const max_file = 1024 * 1024;

pub const Hooks = struct {
    gpa: Allocator,
    registry: *plugin.Registry,
    env: *const std.process.Environ.Map,
    home: []const u8,
    config_dir: []const u8,
    sessions_dir: []const u8,
    /// Path → the plugin loaded from it and its commands. Keys owned.
    files: std.StringHashMapUnmanaged(Loaded) = .empty,
    /// Memory of every file version ever loaded: a run that took its view
    /// earlier may still call into an old one, so versions live until deinit.
    versions: std.ArrayList(*std.heap.ArenaAllocator) = .empty,

    /// `self` must outlive the registry.
    pub fn register(self: *Hooks) !void {
        try self.registry.addLoader(.{ .name = "hooks", .ctx = self, .load = load });
    }

    pub fn deinit(self: *Hooks) void {
        var keys = self.files.keyIterator();
        while (keys.next()) |key| self.gpa.free(key.*);
        self.files.deinit(self.gpa);
        for (self.versions.items) |version| {
            version.deinit();
            self.gpa.destroy(version);
        }
        self.versions.deinit(self.gpa);
    }

    fn load(ctx: ?*anyopaque, arena: Allocator, io: Io, location: ?[]const u8) anyerror![]const plugin.Registry.Failure {
        const self: *Hooks = @ptrCast(@alignCast(ctx.?));
        const user: [2][]const u8 = .{
            try std.fs.path.join(arena, &.{ self.home, ".agents", "hooks.json" }),
            try std.fs.path.join(arena, &.{ self.config_dir, "hooks.json" }),
        };
        const paths: [2][]const u8 = if (location) |here| .{
            try std.fs.path.join(arena, &.{ here, ".agents", "hooks.json" }),
            try std.fs.path.join(arena, &.{ here, ".zeta", "hooks.json" }),
        } else user;
        var failures: std.ArrayList(plugin.Registry.Failure) = .empty;
        // Every present file is staged again, in file order, and the scope
        // swaps at once: the order holds even when a file keeps an older
        // version, and no run sees half a reload.
        var live: std.ArrayList(plugin.Registry.Owner) = try .initCapacity(arena, paths.len);
        var gone: std.ArrayList(plugin.Registry.Owner) = try .initCapacity(arena, paths.len);
        var updates: std.ArrayList(struct { path: []const u8, loaded: ?Loaded }) = try .initCapacity(arena, paths.len);
        // Nothing is published unless every file stages: a file that fails
        // keeps the whole scope as it was, order included.
        errdefer for (live.items) |owner| self.registry.dispose(owner);
        for (paths) |path| {
            // A project at the home directory: that file already applies
            // everywhere as a user file.
            if (location != null and (std.mem.eql(u8, path, user[0]) or std.mem.eql(u8, path, user[1]))) continue;
            const old = self.files.get(path);
            const set = try self.read(arena, io, path, &failures) orelse {
                if (old) |loaded| {
                    gone.appendAssumeCapacity(loaded.owner);
                    updates.appendAssumeCapacity(.{ .path = path, .loaded = null });
                }
                continue;
            };
            const owner = try self.registry.stage(.{
                .id = set.id,
                .layer = if (location == null) .user else .project,
                .location = if (location) |here| try self.keep(here) else null,
                .source = set.path,
            }, if (old) |loaded| loaded.owner else null);
            live.appendAssumeCapacity(owner);
            set.addHooks(self.registry, owner) catch |err| {
                for (live.items) |staged| self.registry.dispose(staged);
                try failures.append(arena, .{ .plugin = set.id, .message = @errorName(err) });
                return failures.items;
            };
            updates.appendAssumeCapacity(.{ .path = path, .loaded = .{ .owner = owner, .set = set } });
        }
        // Everything that can fail happens before the swap.
        try self.files.ensureUnusedCapacity(self.gpa, @intCast(updates.items.len));
        const keys = try arena.alloc(?[]u8, updates.items.len);
        @memset(keys, null);
        errdefer for (keys) |key| if (key) |k| self.gpa.free(k);
        for (updates.items, keys) |u, *key| {
            if (u.loaded != null and !self.files.contains(u.path)) key.* = try self.gpa.dupe(u8, u.path);
        }
        self.registry.swap(live.items, gone.items);
        live.clearRetainingCapacity();
        for (updates.items, keys) |u, key| {
            if (u.loaded) |loaded| {
                if (key) |k| {
                    self.files.putAssumeCapacity(k, loaded);
                } else self.files.getPtr(u.path).?.* = loaded;
            } else if (self.files.fetchRemove(u.path)) |removed| self.gpa.free(removed.key);
        }
        return failures.items;
    }

    /// The commands to register for `path`: freshly parsed, else the last
    /// good version (with a failure), else null when there is nothing.
    fn read(self: *Hooks, arena: Allocator, io: Io, path: []const u8, failures: *std.ArrayList(plugin.Registry.Failure)) !?*Set {
        const id = try std.fmt.allocPrint(arena, "hooks:{s}", .{path});
        const previous: ?*Set = if (self.files.get(path)) |loaded| loaded.set else null;
        const version = try self.gpa.create(std.heap.ArenaAllocator);
        version.* = .init(self.gpa);
        var kept = false;
        defer if (!kept) {
            version.deinit();
            self.gpa.destroy(version);
        };
        const a = version.allocator();
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => {
                try failures.append(arena, .{ .plugin = id, .message = @errorName(err) });
                return previous;
            },
        };
        const parsed = file.parse(a, text) catch |err| {
            try failures.append(arena, .{ .plugin = id, .message = @errorName(err) });
            return previous;
        };
        for (parsed.warnings) |warning| try failures.append(arena, .{ .plugin = id, .message = try arena.dupe(u8, warning) });
        const set = try a.create(Set);
        set.* = .{ .hooks = self, .commands = parsed.commands, .id = try a.dupe(u8, id), .path = try a.dupe(u8, path) };
        try self.versions.append(self.gpa, version);
        kept = true;
        return set;
    }

    /// A copy of `text` that lives until deinit.
    fn keep(self: *Hooks, text: []const u8) ![]const u8 {
        const version = try self.gpa.create(std.heap.ArenaAllocator);
        version.* = .init(self.gpa);
        errdefer {
            version.deinit();
            self.gpa.destroy(version);
        }
        const copy = try version.allocator().dupe(u8, text);
        try self.versions.append(self.gpa, version);
        return copy;
    }
};

const Loaded = struct { owner: plugin.Registry.Owner, set: *Set };

/// One loaded version of a file.
const Set = struct {
    hooks: *Hooks,
    commands: []const file.Command,
    id: []const u8,
    path: []const u8,

    fn has(s: *const Set, event: file.Event) bool {
        for (s.commands) |c| if (c.event == event) return true;
        return false;
    }

    fn addHooks(s: *Set, r: *plugin.Registry, owner: plugin.Registry.Owner) !void {
        if (s.has(.SessionStart)) try r.addHook(owner, .{ .ctx = s, .point = .{ .session_start = sessionStart } });
        if (s.has(.UserPromptSubmit)) try r.addHook(owner, .{ .ctx = s, .point = .{ .prompt_submit = promptSubmit } });
        if (s.has(.PreToolUse)) try r.addHook(owner, .{ .ctx = s, .point = .{ .tool_pre = toolPre } });
        if (s.has(.PermissionRequest)) try r.addHook(owner, .{ .ctx = s, .point = .{ .permission = permission } });
        if (s.has(.PostToolUse) or s.has(.PostToolUseFailure)) try r.addHook(owner, .{ .ctx = s, .point = .{ .tool_post = toolPost } });
        if (s.has(.Stop)) try r.addHook(owner, .{ .ctx = s, .point = .{ .turn_stop = turnStop } });
    }

    /// Runs one command. A failure fails the whole event where failing
    /// closed matters (`strict`); elsewhere it is logged and the next
    /// command runs (null).
    fn invoke(s: *const Set, arena: Allocator, io: Io, command: file.Command, scope: hook.Scope, fields: []const run_mod.Field, strict: bool) !?run_mod.Reply {
        const transcript = core.session_storage.logPath(arena, s.hooks.sessions_dir, scope.location, scope.session) catch "";
        return run_mod.run(arena, io, .{ .command = command, .scope = scope, .transcript_path = transcript, .fields = fields, .env = s.hooks.env }) catch |err| {
            if (strict or err == error.Canceled) return err;
            std.log.warn("{s} hook '{s}' from {s} failed: {s}", .{ @tagName(command.event), command.command, s.path, @errorName(err) });
            return null;
        };
    }
};

fn toolFields(arena: Allocator, call: hook.Call, extra: []const run_mod.Field) ![]const run_mod.Field {
    const base = [_]run_mod.Field{
        .{ .name = "toolName", .alias = "tool_name", .value = .{ .string = call.name } },
        .{ .name = "toolInput", .alias = "tool_input", .value = call.args },
        .{ .name = "toolCallId", .alias = "tool_use_id", .value = .{ .string = call.id } },
    };
    return std.mem.concat(arena, run_mod.Field, &.{ &base, extra });
}

fn joined(arena: Allocator, parts: []const []const u8) !?[]const u8 {
    if (parts.len == 0) return null;
    return try std.mem.join(arena, "\n\n", parts);
}

fn sessionStart(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, source: hook.SessionSource) anyerror!?[]const u8 {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    var parts: std.ArrayList([]const u8) = .empty;
    for (s.commands) |c| {
        if (c.event != .SessionStart or !file.matches(c.matcher, @tagName(source))) continue;
        const reply = try s.invoke(arena, io, c, scope, &.{.{ .name = "source", .value = .{ .string = @tagName(source) } }}, false) orelse continue;
        if (reply.context) |text| try parts.append(arena, text);
    }
    return joined(arena, parts.items);
}

fn promptSubmit(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, prompt: hook.Prompt) anyerror!hook.PromptSubmit {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    var parts: std.ArrayList([]const u8) = .empty;
    for (s.commands) |c| {
        if (c.event != .UserPromptSubmit) continue;
        const reply = try s.invoke(arena, io, c, scope, &.{.{ .name = "prompt", .value = .{ .string = prompt.text } }}, false) orelse continue;
        if (reply.block) |reason| return .{ .block = reason };
        if (reply.context) |text| try parts.append(arena, text);
    }
    return if (try joined(arena, parts.items)) |text| .{ .context = text } else .@"continue";
}

fn toolPre(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, call: hook.Call) anyerror!hook.ToolPre {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    var current = call;
    var rewritten = false;
    for (s.commands) |c| {
        if (c.event != .PreToolUse or !file.matches(c.matcher, call.name)) continue;
        const reply = (try s.invoke(arena, io, c, scope, try toolFields(arena, current, &.{}), true)).?;
        if (reply.block) |reason| return .{ .block = reason };
        if (reply.updated_input) |args| {
            current.args = args;
            rewritten = true;
        }
    }
    return if (rewritten) .{ .rewrite = current.args } else .@"continue";
}

fn permission(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, ask: hook.Ask) anyerror!hook.Permission {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    for (s.commands) |c| {
        if (c.event != .PermissionRequest or !file.matches(c.matcher, ask.call.name)) continue;
        const reply = (try s.invoke(arena, io, c, scope, try toolFields(arena, ask.call, &.{
            .{ .name = "action", .value = .{ .string = ask.action } },
            .{ .name = "pattern", .value = .{ .string = ask.pattern } },
        }), true)).?;
        if (reply.block) |reason| return .{ .deny = reason };
        if (reply.allow) return .{ .allow = reply.updated_input };
    }
    return .@"continue";
}

fn toolPost(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, call: hook.Call, result: plugin.tool.Result) anyerror!hook.ToolPost {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    const event: file.Event = if (result.isError) .PostToolUseFailure else .PostToolUse;
    var response: std.json.ObjectMap = .empty;
    try response.put(arena, "text", .{ .string = result.text });
    try response.put(arena, "isError", .{ .bool = result.isError });
    var parts: std.ArrayList([]const u8) = .empty;
    for (s.commands) |c| {
        if (c.event != event or !file.matches(c.matcher, call.name)) continue;
        const reply = try s.invoke(arena, io, c, scope, try toolFields(arena, call, &.{
            .{ .name = "toolResponse", .alias = "tool_response", .value = .{ .object = response } },
            .{ .name = "error", .value = if (result.isError) .{ .string = result.text } else .null },
        }), false) orelse continue;
        if (reply.block) |reason| try parts.append(arena, reason);
        if (reply.context) |text| try parts.append(arena, text);
    }
    if (parts.items.len == 0) return .@"continue";
    var out = result;
    out.text = try std.mem.join(arena, "\n\n", try std.mem.concat(arena, []const u8, &.{ &.{result.text}, parts.items }));
    return .{ .replace = out };
}

fn turnStop(ctx: ?*anyopaque, arena: Allocator, io: Io, scope: hook.Scope, stop: hook.Stop) anyerror!hook.TurnStop {
    const s: *const Set = @ptrCast(@alignCast(ctx.?));
    const last = try stop.reply.text(arena);
    for (s.commands) |c| {
        if (c.event != .Stop) continue;
        const reply = try s.invoke(arena, io, c, scope, &.{
            .{ .name = "lastAssistantMessage", .alias = "last_assistant_message", .value = .{ .string = last } },
            .{ .name = "stopHookActive", .alias = "stop_hook_active", .value = .{ .bool = stop.continued } },
        }, false) orelse continue;
        if (reply.block) |reason| return .{ .@"continue" = reason };
    }
    return .stop;
}

test {
    _ = file;
    _ = run_mod;
    _ = @import("root_test.zig");
}
