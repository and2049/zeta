//! Registration-time check for the JSON Schema subset implemented by core/schema.zig.
//! Unsupported keywords are errors, not silently ignored constraints. This file
//! has no dependency on core so Registry can call `check` before retaining a tool.
const std = @import("std");
const Value = std.json.Value;

/// Return `error.InvalidSchema` for malformed schemas or unsupported keywords.
/// Does not allocate or retain any part of `schema`.
pub fn check(schema: Value) error{InvalidSchema}!void {
    switch (schema) {
        .bool => return,
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                if (is(key, "type")) {
                    if (value == .string) {
                        try typeName(value);
                    } else if (value == .array and value.array.items.len > 0) {
                        for (value.array.items, 0..) |name, i| {
                            try typeName(name);
                            for (value.array.items[0..i]) |prior| {
                                if (std.mem.eql(u8, prior.string, name.string)) return error.InvalidSchema;
                            }
                        }
                    } else return error.InvalidSchema;
                } else if (is(key, "properties")) {
                    if (value != .object) return error.InvalidSchema;
                    var props = value.object.iterator();
                    while (props.next()) |prop| try check(prop.value_ptr.*);
                } else if (is(key, "required")) {
                    if (value != .array) return error.InvalidSchema;
                    for (value.array.items, 0..) |name, i| {
                        if (name != .string) return error.InvalidSchema;
                        for (value.array.items[0..i]) |prior| {
                            if (std.mem.eql(u8, prior.string, name.string)) return error.InvalidSchema;
                        }
                    }
                } else if (is(key, "additionalProperties") or is(key, "items")) {
                    try check(value);
                } else if (is(key, "enum")) {
                    if (value != .array or value.array.items.len == 0) return error.InvalidSchema;
                } else if (is(key, "const")) {
                    // Any JSON value is a valid constant.
                } else if (is(key, "anyOf") or is(key, "oneOf")) {
                    if (value != .array or value.array.items.len == 0) return error.InvalidSchema;
                    for (value.array.items) |sub| try check(sub);
                } else if (is(key, "minimum") or is(key, "maximum") or is(key, "exclusiveMinimum") or is(key, "exclusiveMaximum")) {
                    if (!finiteNumber(value)) return error.InvalidSchema;
                } else if (is(key, "minLength") or is(key, "maxLength") or
                    is(key, "minItems") or is(key, "maxItems"))
                {
                    if (!nonnegativeInteger(value)) return error.InvalidSchema;
                } else if (is(key, "title") or is(key, "description") or is(key, "$schema")) {
                    if (value != .string) return error.InvalidSchema;
                } else if (is(key, "default")) {
                    // Annotation only; no validation effect.
                } else if (is(key, "examples")) {
                    if (value != .array) return error.InvalidSchema;
                } else return error.InvalidSchema;
            }
        },
        else => return error.InvalidSchema,
    }
}

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn typeName(value: Value) error{InvalidSchema}!void {
    if (value != .string) return error.InvalidSchema;
    for ([_][]const u8{ "null", "boolean", "object", "array", "number", "integer", "string" }) |name| {
        if (is(value.string, name)) return;
    }
    return error.InvalidSchema;
}

fn finiteNumber(value: Value) bool {
    const n: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return false,
        else => return false,
    };
    return std.math.isFinite(n);
}

fn nonnegativeInteger(value: Value) bool {
    if (!finiteNumber(value)) return false;
    const n: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return false,
        else => unreachable,
    };
    return n >= 0 and @floor(n) == n;
}

fn parse(arena: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{});
}

test "supported recursive schema and annotations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try check(try parse(arena.allocator(),
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"input","description":"tool arguments","default":{},"examples":[{}],
        \\ "type":"object","required":["path"],"properties":{"path":{"type":["string","null"],"minLength":1},
        \\ "items":{"type":"array","minItems":0,"maxItems":2,"items":{"anyOf":[true,{"const":3},{"enum":["a"]}]}}},
        \\ "additionalProperties":{"oneOf":[{"type":"boolean"},false]},"minimum":0,"maximum":10}
    ));
}

test "unsupported validation keywords and malformed supported values fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "null",                                            "[]",                           "3",                            "{\"$ref\":\"#/foo\"}",   "{\"pattern\":\"x\"}",
        "{\"properties\":{\"x\":{\"format\":\"email\"}}}", "{\"items\":[{}]}",             "{\"additionalProperties\":1}", "{\"type\":\"mystery\"}", "{\"type\":[\"string\",\"string\"]}",
        "{\"type\":[]}",                                   "{\"required\":[\"a\",\"a\"]}", "{\"required\":[1]}",           "{\"enum\":[]}",          "{\"oneOf\":[]}",
        "{\"anyOf\":[{} ,42]}",                            "{\"minimum\":\"0\"}",          "{\"maximum\":null}",           "{\"minLength\":-1}",     "{\"maxLength\":1.5}",
        "{\"minItems\":\"2\"}",                            "{\"title\":1}",                "{\"examples\":{}}",
    };
    for (bad) |text| try std.testing.expectError(error.InvalidSchema, check(try parse(arena.allocator(), text)));
}
