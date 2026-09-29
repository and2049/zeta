//! The `mcp` config key:
//!
//! `{"timeout": 30000, "servers": {"git": {"type": "local", "command": ["git-mcp"], "cwd"?: "…", "environment"?: {…}},
//!                                  "docs": {"type": "remote", "url": "https://…", "headers"?: {…}}}}`
//!
//! Both kinds take `disabled`, `timeout` (milliseconds for that server's
//! tool calls), `disabled_tools`, `instructions` and `deferred` (also a
//! top-level default). A remote server may set `oauth`: `false`, or
//! `{client_id?, client_secret?, scope?, callback_port?}` for signing in. The top-level `timeout` bounds connecting and listing tools.
//! A server entry that does not fit is skipped with a problem.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_timeout_ms = 30_000;

pub const Pair = struct { name: []const u8, value: []const u8 };

/// `oauth` of a remote server: `false`, or settings for signing in.
pub const OAuth = struct {
    enabled: bool = true,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    /// Port of the loopback redirect; any free one when null.
    callback_port: ?u16 = null,
};

pub const Remote = struct { url: []const u8, headers: []const Pair = &.{}, oauth: OAuth = .{} };

pub const Server = struct {
    name: []const u8,
    transport: union(enum) {
        local: struct { command: []const []const u8, cwd: ?[]const u8 = null, environment: []const Pair = &.{} },
        remote: Remote,
    },
    disabled: bool = false,
    /// Tool-call timeout; null uses the tool timeout from config.
    timeout_ms: ?u64 = null,
    /// Tools not to offer, by the server's own tool name; `*` and `?` match
    /// any run or one character.
    disabled_tools: []const []const u8 = &.{},
    /// Whether the server's instructions join the system prompt.
    instructions: bool = true,
    /// The model finds the server's tools with `mcp_search` and calls them
    /// with `mcp_call` instead of being offered each one.
    deferred: bool = false,
    /// What its prompt commands start with: the name made fit for a
    /// command, unique among the project's servers (set by `parse`).
    command_prefix: []const u8 = "",
};

pub const Settings = struct {
    timeout_ms: u64 = default_timeout_ms,
    servers: []const Server = &.{},
    problems: []const []const u8 = &.{},
};

/// Everything returned lives in `arena` (or borrows `value`).
pub fn parse(arena: Allocator, value: Value) !Settings {
    if (value != .object) return .{};
    var out: Settings = .{};
    var problems: std.ArrayList([]const u8) = .empty;
    if (value.object.get("timeout")) |t| {
        if (positive(t)) |timeout| {
            out.timeout_ms = timeout;
        } else {
            try problems.append(arena, "mcp.timeout must be a positive integer");
        }
    }
    // `mcp.deferred` is every server's default.
    const deferred = switch (value.object.get("deferred") orelse Value{ .bool = false }) {
        .bool => |b| b,
        else => blk: {
            try problems.append(arena, "mcp.deferred must be a boolean");
            break :blk false;
        },
    };
    const servers = switch (value.object.get("servers") orelse {
        out.problems = problems.items;
        return out;
    }) {
        .object => |o| o,
        else => {
            try problems.append(arena, "mcp.servers must be an object");
            out.problems = problems.items;
            return out;
        },
    };
    var list: std.ArrayList(Server) = .empty;
    var it = servers.iterator();
    while (it.next()) |entry| {
        const server = one(arena, entry.key_ptr.*, entry.value_ptr.*, deferred) catch |err| {
            try problems.append(arena, try std.fmt.allocPrint(arena, "mcp server '{s}': {s}", .{ entry.key_ptr.*, switch (err) {
                error.MissingType => "type must be \"local\" or \"remote\"",
                error.MissingCommand => "a local server needs a non-empty command array",
                error.MissingUrl => "a remote server needs an http(s) url",
                error.InvalidField => "a field has the wrong type",
                else => @errorName(err),
            } }));
            continue;
        };
        try list.append(arena, server);
    }
    // In config order, so a name does not depend on which server connects
    // first.
    var prefixes: std.StringHashMapUnmanaged(void) = .empty;
    for (list.items) |*server| {
        // `:` separates the prefix from the prompt, so a prefix has none.
        const base = try commandSafe(arena, server.name);
        for (@constCast(base)) |*c| if (c.* == ':') {
            c.* = '_';
        };
        var candidate = base;
        var n: usize = 2;
        while (prefixes.contains(candidate)) : (n += 1) candidate = try std.fmt.allocPrint(arena, "{s}_{d}", .{ base, n });
        try prefixes.put(arena, candidate, {});
        server.command_prefix = candidate;
    }
    out.servers = list.items;
    out.problems = problems.items;
    return out;
}

/// `name` with whitespace and `/`, which command names cannot hold, as `_`.
pub fn commandSafe(a: Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    for (out) |*c| if (std.ascii.isWhitespace(c.*) or c.* == '/') {
        c.* = '_';
    };
    return out;
}

fn one(arena: Allocator, name: []const u8, v: Value, deferred: bool) !Server {
    if (v != .object) return error.InvalidField;
    const o = v.object;
    const kind = try string(o, "type") orelse return error.MissingType;
    var server: Server = .{ .name = name, .transport = undefined, .deferred = deferred };
    if (o.get("disabled")) |d| server.disabled = switch (d) {
        .bool => |b| b,
        else => return error.InvalidField,
    };
    if (o.get("timeout")) |t| server.timeout_ms = positive(t) orelse return error.InvalidField;
    if (o.get("deferred")) |d| server.deferred = switch (d) {
        .bool => |b| b,
        else => return error.InvalidField,
    };
    if (o.get("instructions")) |i| server.instructions = switch (i) {
        .bool => |b| b,
        else => return error.InvalidField,
    };
    if (o.get("disabled_tools")) |list| server.disabled_tools = switch (list) {
        .array => |items| blk: {
            const out = try arena.alloc([]const u8, items.items.len);
            for (items.items, out) |item, *tool| tool.* = switch (item) {
                .string => |t| t,
                else => return error.InvalidField,
            };
            break :blk out;
        },
        else => return error.InvalidField,
    };
    if (std.mem.eql(u8, kind, "local")) {
        const command = switch (o.get("command") orelse return error.MissingCommand) {
            .array => |a| a.items,
            else => return error.MissingCommand,
        };
        if (command.len == 0) return error.MissingCommand;
        const argv = try arena.alloc([]const u8, command.len);
        for (command, argv) |item, *arg| arg.* = switch (item) {
            .string => |s| s,
            else => return error.MissingCommand,
        };
        server.transport = .{ .local = .{ .command = argv, .cwd = try string(o, "cwd"), .environment = try pairs(arena, o.get("environment")) } };
    } else if (std.mem.eql(u8, kind, "remote")) {
        const url = try string(o, "url") orelse return error.MissingUrl;
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return error.MissingUrl;
        server.transport = .{ .remote = .{ .url = url, .headers = try pairs(arena, o.get("headers")), .oauth = try oauthOf(o.get("oauth")) } };
    } else return error.MissingType;
    return server;
}

fn oauthOf(v: ?Value) !OAuth {
    const o = switch (v orelse return .{}) {
        .bool => |on| return .{ .enabled = on },
        .null => return .{},
        .object => |o| o,
        else => return error.InvalidField,
    };
    return .{
        .client_id = try string(o, "client_id"),
        .client_secret = try string(o, "client_secret"),
        .scope = try string(o, "scope"),
        .callback_port = if (o.get("callback_port")) |p| switch (p) {
            .integer => |port| std.math.cast(u16, port) orelse return error.InvalidField,
            .null => null,
            else => return error.InvalidField,
        } else null,
    };
}

fn string(o: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        .null => null,
        else => error.InvalidField,
    };
}

fn pairs(arena: Allocator, v: ?Value) ![]const Pair {
    const o = switch (v orelse return &.{}) {
        .object => |o| o,
        .null => return &.{},
        else => return error.InvalidField,
    };
    const out = try arena.alloc(Pair, o.count());
    var it = o.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .name = e.key_ptr.*, .value = switch (e.value_ptr.*) {
        .string => |s| s,
        else => return error.InvalidField,
    } };
    return out;
}

fn positive(v: Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else null,
        else => null,
    };
}

/// A deep copy of `spec` in `a`.
pub fn clone(a: Allocator, spec: Server) !Server {
    var out = spec;
    out.name = try a.dupe(u8, spec.name);
    out.command_prefix = try a.dupe(u8, spec.command_prefix);
    const disabled = try a.alloc([]const u8, spec.disabled_tools.len);
    for (spec.disabled_tools, disabled) |name, *dst| dst.* = try a.dupe(u8, name);
    out.disabled_tools = disabled;
    switch (spec.transport) {
        .local => |local| {
            const argv = try a.alloc([]const u8, local.command.len);
            for (local.command, argv) |arg, *dst| dst.* = try a.dupe(u8, arg);
            out.transport = .{ .local = .{ .command = argv, .cwd = if (local.cwd) |d| try a.dupe(u8, d) else null, .environment = try copyPairs(a, local.environment) } };
        },
        .remote => |remote| out.transport = .{ .remote = .{ .url = try a.dupe(u8, remote.url), .headers = try copyPairs(a, remote.headers), .oauth = .{
            .enabled = remote.oauth.enabled,
            .client_id = try optional(a, remote.oauth.client_id),
            .client_secret = try optional(a, remote.oauth.client_secret),
            .scope = try optional(a, remote.oauth.scope),
            .callback_port = remote.oauth.callback_port,
        } } },
    }
    return out;
}

fn optional(a: Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |t| try a.dupe(u8, t) else null;
}

fn copyPairs(a: Allocator, list: []const Pair) ![]const Pair {
    const out = try a.alloc(Pair, list.len);
    for (list, out) |p, *dst| dst.* = .{ .name = try a.dupe(u8, p.name), .value = try a.dupe(u8, p.value) };
    return out;
}

test "local and remote servers, defaults, and problems for entries that do not fit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"timeout": 5000, "servers": {
        \\  "git": {"type": "local", "command": ["git-mcp", "--stdio"], "environment": {"TOKEN": "t"}, "timeout": 900, "disabled_tools": ["push*"], "instructions": false},
        \\  "docs": {"type": "remote", "url": "https://docs.test/mcp", "headers": {"Authorization": "Bearer x"}, "disabled": true, "oauth": false},
        \\  "wiki": {"type": "remote", "url": "https://wiki.test/mcp", "oauth": {"client_id": "zeta", "scope": "read", "callback_port": 8912}},
        \\  "bad": {"type": "local", "command": []},
        \\  "odd": {"type": "sse", "url": "https://x"}
        \\}}
    , .{});
    const s = try parse(a, v);
    try std.testing.expectEqual(@as(u64, 5000), s.timeout_ms);
    try std.testing.expectEqual(@as(usize, 3), s.servers.len);
    try std.testing.expectEqualStrings("--stdio", s.servers[0].transport.local.command[1]);
    try std.testing.expectEqualStrings("TOKEN", s.servers[0].transport.local.environment[0].name);
    try std.testing.expectEqual(@as(?u64, 900), s.servers[0].timeout_ms);
    try std.testing.expectEqualStrings("push*", s.servers[0].disabled_tools[0]);
    try std.testing.expect(!s.servers[0].instructions);
    try std.testing.expect(s.servers[1].disabled);
    try std.testing.expectEqualStrings("Bearer x", s.servers[1].transport.remote.headers[0].value);
    try std.testing.expect(!s.servers[1].transport.remote.oauth.enabled);
    const wiki = s.servers[2].transport.remote.oauth;
    try std.testing.expect(wiki.enabled and wiki.callback_port.? == 8912);
    try std.testing.expectEqualStrings("zeta", wiki.client_id.?);
    try std.testing.expectEqual(@as(usize, 2), s.problems.len);
    const clash = try parse(a, try std.json.parseFromSliceLeaky(Value, a,
        \\{"servers": {"a b": {"type": "local", "command": ["x"]}, "a_b": {"type": "local", "command": ["y"]}}}
    , .{}));
    try std.testing.expectEqualStrings("a_b", clash.servers[0].command_prefix);
    try std.testing.expectEqualStrings("a_b_2", clash.servers[1].command_prefix);
    const colon = try parse(a, try std.json.parseFromSliceLeaky(Value, a,
        \\{"servers": {"docs:api": {"type": "local", "command": ["x"]}}}
    , .{}));
    try std.testing.expectEqualStrings("docs_api", colon.servers[0].command_prefix);
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, .null)).servers.len);
}

test "deferred: a top-level default, a per-server override, and a wrong type" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try parse(a, try std.json.parseFromSliceLeaky(Value, a,
        \\{"deferred": true, "servers": {"a": {"type": "local", "command": ["x"]}, "b": {"type": "local", "command": ["y"], "deferred": false}}}
    , .{}));
    try std.testing.expect(s.servers[0].deferred and !s.servers[1].deferred);
    const bad = try parse(a, try std.json.parseFromSliceLeaky(Value, a,
        \\{"deferred": "true", "servers": {"a": {"type": "local", "command": ["x"]}, "b": {"type": "local", "command": ["y"], "deferred": 1}}}
    , .{}));
    try std.testing.expect(!bad.servers[0].deferred);
    try std.testing.expectEqual(@as(usize, 1), bad.servers.len);
    try std.testing.expectEqualStrings("mcp.deferred must be a boolean", bad.problems[0]);
    try std.testing.expectEqual(@as(usize, 2), bad.problems.len);
}

test "invalid top-level timeouts are reported even without servers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0", "-1", "1.5", "\"30000\"", "null" }) |bad| {
        const json = try std.fmt.allocPrint(a, "{{\"timeout\":{s}}}", .{bad});
        const result = try parse(a, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
        try std.testing.expectEqual(@as(u64, default_timeout_ms), result.timeout_ms);
        try std.testing.expectEqual(@as(usize, 1), result.problems.len);
        try std.testing.expectEqualStrings("mcp.timeout must be a positive integer", result.problems[0]);
    }
}
