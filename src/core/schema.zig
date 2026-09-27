//! Validates tool arguments against the tool's JSON Schema.
//!
//! Supported keywords: `type` (a name or a list), `properties`, `required`,
//! `additionalProperties` (bool or schema), `items`, `enum`, `const`,
//! `anyOf`, `oneOf`, inclusive/exclusive minimum/maximum, `minLength`, `maxLength`,
//! `minItems`, `maxItems`. Tool schemas are checked at registration by
//! plugin/schema.zig; unsupported constraints are rejected there. `title`,
//! `description`, `default`, `examples`, and `$schema` are annotations only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Issue = struct {
    /// Where the problem is, e.g. `edits.0.oldText`; empty for the root.
    path: []const u8,
    message: []const u8,
};

/// Every issue found; empty means valid. All memory is in `arena`.
pub fn validate(arena: Allocator, schema: Value, value: Value) Allocator.Error![]const Issue {
    var v: Validator = .{ .arena = arena };
    try v.check(schema, value, "");
    return v.issues.items;
}

const Validator = struct {
    arena: Allocator,
    issues: std.ArrayList(Issue) = .empty,

    fn fail(v: *Validator, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try v.issues.append(v.arena, .{ .path = path, .message = try std.fmt.allocPrint(v.arena, fmt, args) });
    }

    fn check(v: *Validator, schema: Value, value: Value, path: []const u8) Allocator.Error!void {
        const s = switch (schema) {
            .object => |o| o,
            .bool => |b| return if (!b) v.fail(path, "no value is allowed here", .{}),
            else => return,
        };

        if (s.get("type")) |t| if (!matchesType(t, value)) {
            return v.fail(path, "must be {s}", .{try typeName(v.arena, t)});
        };
        if (s.get("const")) |c| if (!equal(c, value)) {
            try v.fail(path, "must be {f}", .{std.json.fmt(c, .{})});
        };
        if (s.get("enum")) |e| if (e == .array) {
            for (e.array.items) |option| {
                if (equal(option, value)) break;
            } else try v.fail(path, "must be one of {f}", .{std.json.fmt(e, .{})});
        };
        if (s.get("anyOf")) |alts| if (alts == .array and try v.countMatches(alts.array.items, value) == 0) {
            try v.fail(path, "must match a schema in anyOf", .{});
        };
        if (s.get("oneOf")) |alts| if (alts == .array and try v.countMatches(alts.array.items, value) != 1) {
            try v.fail(path, "must match exactly one schema in oneOf", .{});
        };

        switch (value) {
            .string => |str| {
                const len = std.unicode.utf8CountCodepoints(str) catch str.len;
                if (number(s.get("minLength"))) |n| if (@as(f128, @floatFromInt(len)) < n) {
                    try v.fail(path, "must have at least {d} characters", .{n});
                };
                if (number(s.get("maxLength"))) |n| if (@as(f128, @floatFromInt(len)) > n) {
                    try v.fail(path, "must have at most {d} characters", .{n});
                };
            },
            .integer, .float, .number_string => if (number(value)) |x| {
                if (number(s.get("minimum"))) |n| if (x < n) try v.fail(path, "must be >= {d}", .{n});
                if (number(s.get("maximum"))) |n| if (x > n) try v.fail(path, "must be <= {d}", .{n});
                if (number(s.get("exclusiveMinimum"))) |n| if (x <= n) try v.fail(path, "must be > {d}", .{n});
                if (number(s.get("exclusiveMaximum"))) |n| if (x >= n) try v.fail(path, "must be < {d}", .{n});
            },
            .array => |a| {
                if (number(s.get("minItems"))) |n| if (@as(f128, @floatFromInt(a.items.len)) < n) {
                    try v.fail(path, "must have at least {d} items", .{n});
                };
                if (number(s.get("maxItems"))) |n| if (@as(f128, @floatFromInt(a.items.len)) > n) {
                    try v.fail(path, "must have at most {d} items", .{n});
                };
                if (s.get("items")) |item_schema| for (a.items, 0..) |item, i| {
                    try v.check(item_schema, item, try join(v.arena, path, "{d}", .{i}));
                };
            },
            .object => |o| try v.checkObject(s, o, path),
            else => {},
        }
    }

    fn checkObject(v: *Validator, s: std.json.ObjectMap, o: std.json.ObjectMap, path: []const u8) Allocator.Error!void {
        if (s.get("required")) |req| if (req == .array) for (req.array.items) |name| {
            if (name != .string) continue;
            if (!o.contains(name.string)) try v.fail(path, "must have required property '{s}'", .{name.string});
        };
        const props: ?std.json.ObjectMap = if (s.get("properties")) |p| (if (p == .object) p.object else null) else null;
        var it = o.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const child = try join(v.arena, path, "{s}", .{key});
            if (props) |p| if (p.get(key)) |prop_schema| {
                try v.check(prop_schema, e.value_ptr.*, child);
                continue;
            };
            if (s.get("additionalProperties")) |extra| switch (extra) {
                .bool => |allowed| if (!allowed) try v.fail(path, "must not have additional property '{s}'", .{key}),
                else => try v.check(extra, e.value_ptr.*, child),
            };
        }
    }

    /// Runs each alternative in a scratch validator so its issues don't leak.
    fn countMatches(v: *Validator, alts: []const Value, value: Value) Allocator.Error!usize {
        var n: usize = 0;
        for (alts) |alt| {
            var scratch: Validator = .{ .arena = v.arena };
            try scratch.check(alt, value, "");
            if (scratch.issues.items.len == 0) n += 1;
        }
        return n;
    }
};

fn join(arena: Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    const leaf = try std.fmt.allocPrint(arena, fmt, args);
    if (path.len == 0) return leaf;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ path, leaf });
}

fn matchesType(t: Value, value: Value) bool {
    switch (t) {
        .string => |name| return isType(name, value),
        .array => |names| {
            for (names.items) |n| if (n == .string and isType(n.string, value)) return true;
            return false;
        },
        else => return true,
    }
}

fn isType(name: []const u8, value: Value) bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "string")) return value == .string;
    if (eq(u8, name, "boolean")) return value == .bool;
    if (eq(u8, name, "null")) return value == .null;
    if (eq(u8, name, "object")) return value == .object;
    if (eq(u8, name, "array")) return value == .array;
    if (eq(u8, name, "number")) return number(value) != null;
    if (eq(u8, name, "integer")) {
        const x = number(value) orelse return false;
        return @floor(x) == x;
    }
    return true;
}

fn typeName(arena: Allocator, t: Value) Allocator.Error![]const u8 {
    switch (t) {
        .string => |s| return s,
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            for (a.items, 0..) |n, i| {
                if (n != .string) continue;
                if (i > 0) try out.appendSlice(arena, " or ");
                try out.appendSlice(arena, n.string);
            }
            return out.items;
        },
        else => return "valid",
    }
}

fn number(value: ?Value) ?f128 {
    return switch (value orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f128, s) catch null,
        else => null,
    };
}

fn equal(a: Value, b: Value) bool {
    // f64 cannot distinguish neighboring integers above 2^53. f128 holds
    // every i64 and f64 exactly, including cross-representation comparisons.
    if (preciseNumber(a)) |x| return if (preciseNumber(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |l, r| if (!equal(l, r)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!equal(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn preciseNumber(value: Value) ?f128 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f128, s) catch null,
        else => null,
    };
}

fn parse(arena: Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{});
}

test "valid arguments have no issues" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const schema = try parse(a,
        \\{"type":"object","required":["path"],"additionalProperties":false,
        \\ "properties":{"path":{"type":"string","minLength":1},"offset":{"type":"integer","minimum":1},
        \\  "mode":{"enum":["a","b"]}}}
    );
    const issues = try validate(a, schema, try parse(a,
        \\{"path":"x","offset":2.0,"mode":"b"}
    ));
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "issues carry paths and pi-style messages" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const schema = try parse(a,
        \\{"type":"object","required":["path","edits"],"additionalProperties":false,
        \\ "properties":{"path":{"type":"string"},
        \\  "edits":{"type":"array","minItems":1,"items":{"type":"object","required":["oldText"],
        \\   "properties":{"oldText":{"type":"string"}}}}}}
    );
    const issues = try validate(a, schema, try parse(a,
        \\{"edits":[{"oldText":3},{}],"extra":true}
    ));
    try std.testing.expectEqual(@as(usize, 4), issues.len);
    try std.testing.expectEqualStrings("must have required property 'path'", issues[0].message);
    try std.testing.expectEqualStrings("edits.0.oldText", issues[1].path);
    try std.testing.expectEqualStrings("must be string", issues[1].message);
    try std.testing.expectEqualStrings("edits.1", issues[2].path);
    try std.testing.expectEqualStrings("must not have additional property 'extra'", issues[3].message);
}

test "type lists, anyOf and oneOf" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const schema = try parse(a,
        \\{"type":["string","null"],"anyOf":[{"type":"null"},{"maxLength":2}]}
    );
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, schema, .null)).len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, schema, .{ .string = "ab" })).len);
    try std.testing.expectEqual(@as(usize, 1), (try validate(a, schema, .{ .string = "abc" })).len);
    const bad = try validate(a, schema, .{ .integer = 1 });
    try std.testing.expectEqualStrings("must be string or null", bad[0].message);

    const one = try parse(a,
        \\{"oneOf":[{"type":"integer"},{"type":"number"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), (try validate(a, one, .{ .integer = 1 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, one, .{ .float = 1.5 })).len);
}

test "enum and const preserve large integer precision" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const schema = try parse(a, "{\"enum\":[9007199254740992],\"const\":9007199254740992}");
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, schema, .{ .integer = 9007199254740992 })).len);
    try std.testing.expectEqual(@as(usize, 2), (try validate(a, schema, .{ .integer = 9007199254740993 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, schema, .{ .float = 9007199254740992.0 })).len);
}

test "exclusive numeric bounds reject endpoints" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const s = try parse(a, "{\"exclusiveMinimum\":0,\"exclusiveMaximum\":2}");
    try std.testing.expectEqual(@as(usize, 1), (try validate(a, s, .{ .integer = 0 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, s, .{ .integer = 1 })).len);
    try std.testing.expectEqual(@as(usize, 1), (try validate(a, s, .{ .integer = 2 })).len);
}

test "numeric bounds distinguish adjacent large integers" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const s = try parse(a, "{\"maximum\":9007199254740992}");
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, s, .{ .integer = 9007199254740992 })).len);
    try std.testing.expectEqual(@as(usize, 1), (try validate(a, s, .{ .integer = 9007199254740993 })).len);
}
