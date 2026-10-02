//! Questions plugins ask the user (`question.asked`): what one asks for, the
//! fields of a form, and answering. Strings are request-arena owned.
const std = @import("std");
const Client = @import("Client.zig");
const api = @import("session_api.zig");
const check = api.check;
const A = std.mem.Allocator;
const Value = std.json.Value;

pub const Kind = enum { confirm, select, input, form };

pub const Option = struct {
    value: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",

    /// What the user sees.
    pub fn text(o: Option) []const u8 {
        return if (o.label.len > 0) o.label else o.value;
    }
};

pub const Question = struct {
    id: []const u8,
    session: ?[]const u8 = null,
    source: []const u8 = "",
    message: []const u8 = "",
    kind: Kind,
    /// `confirm`: what is being confirmed, e.g. a command.
    detail: ?[]const u8 = null,
    /// `select`: the choices, at least one.
    options: []const Option = &.{},
    /// `input`.
    placeholder: ?[]const u8 = null,
    secret: bool = false,
    /// `form`: a JSON Schema object of simple properties.
    schema: ?Value = null,
    expiresAt: i64 = 0,

    /// From `question.asked` data or a `GET /questions` entry; null when it
    /// is not a question this client can show.
    pub fn parse(a: A, data: Value) ?Question {
        var q = std.json.parseFromValueLeaky(Question, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
        if (q.kind == .select and q.options.len == 0) return null;
        if (q.kind == .form) {
            const schema = q.schema orelse return null;
            if (schema != .object) return null;
        }
        q.secret = q.secret and q.kind == .input;
        return q;
    }
};

/// One property of a form.
pub const Field = struct {
    name: []const u8,
    /// What the user sees: the title, else the name.
    label: []const u8,
    description: []const u8 = "",
    type: enum { string, number, integer, boolean },
    /// Allowed strings (`enum`); empty means any.
    choices: []const []const u8 = &.{},
    required: bool = false,
};

/// The form's properties in schema order. Properties of another type are
/// asked for as strings; the server checks the answer against the schema.
pub fn fields(a: A, schema: Value) ![]const Field {
    if (schema != .object) return &.{};
    const properties = switch (schema.object.get("properties") orelse return &.{}) {
        .object => |o| o,
        else => return &.{},
    };
    var required: []const Value = &.{};
    if (schema.object.get("required")) |r| if (r == .array) {
        required = r.array.items;
    };
    var out: std.ArrayList(Field) = .empty;
    var it = properties.iterator();
    while (it.next()) |p| {
        const name = p.key_ptr.*;
        const shape = if (p.value_ptr.* == .object) p.value_ptr.object else std.json.ObjectMap.empty;
        var f: Field = .{ .name = name, .label = str(shape, "title") orelse name, .description = str(shape, "description") orelse "", .type = .string };
        if (str(shape, "type")) |t| {
            if (std.mem.eql(u8, t, "number")) f.type = .number;
            if (std.mem.eql(u8, t, "integer")) f.type = .integer;
            if (std.mem.eql(u8, t, "boolean")) f.type = .boolean;
        }
        if (shape.get("enum")) |e| if (e == .array) {
            var choices: std.ArrayList([]const u8) = .empty;
            for (e.array.items) |c| if (c == .string) try choices.append(a, c.string);
            f.choices = choices.items;
        };
        for (required) |r| if (r == .string and std.mem.eql(u8, r.string, name)) {
            f.required = true;
        };
        try out.append(a, f);
    }
    return out.items;
}

/// The JSON value for `text` typed into `f`: null to leave it out (empty
/// text), or `error.Invalid` when it is not a value of the field's type.
pub fn fieldValue(a: A, f: Field, text: []const u8) !?Value {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return if (f.required) error.Invalid else null;
    return switch (f.type) {
        .string => blk: {
            if (f.choices.len > 0) {
                for (f.choices) |c| if (std.mem.eql(u8, c, t)) break :blk .{ .string = try a.dupe(u8, t) };
                return error.Invalid;
            }
            break :blk .{ .string = try a.dupe(u8, t) };
        },
        .integer => .{ .integer = std.fmt.parseInt(i64, t, 10) catch return error.Invalid },
        .number => .{ .float = std.fmt.parseFloat(f64, t) catch return error.Invalid },
        .boolean => if (yes(t)) .{ .bool = true } else if (no(t)) .{ .bool = false } else error.Invalid,
    };
}

pub fn yes(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes") or std.ascii.eqlIgnoreCase(t, "true");
}

pub fn no(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "n") or std.ascii.eqlIgnoreCase(t, "no") or std.ascii.eqlIgnoreCase(t, "false");
}

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The questions plugins have open for the project at `location`.
pub fn list(c: *Client, a: A, location: []const u8) ![]const Question {
    const response = try c.get(a, try std.fmt.allocPrint(a, "/questions?location={s}", .{try api.encode(a, location)}));
    try check(response);
    const body = try std.json.parseFromSliceLeaky(struct { questions: []const Value }, a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    var out: std.ArrayList(Question) = .empty;
    for (body.questions) |v| if (Question.parse(a, v)) |q| try out.append(a, q);
    return out.items;
}

/// Answers a question: `accept` with `content` (see `Kind`), `decline` or
/// `cancel`. A question that is no longer open is not an error.
pub fn answer(c: *Client, a: A, id: []const u8, action: []const u8, content: ?Value) !void {
    const p = try std.fmt.allocPrint(a, "/questions/{s}/reply", .{try api.encode(a, id)});
    const response = if (content) |v| try c.postJson(a, p, .{ .action = action, .content = v }) else try c.postJson(a, p, .{ .action = action });
    if (response.status == .not_found) return;
    try check(response);
}

/// Declines the questions open for `session` at `location` (a client that
/// cannot answer, after it missed events), leaving other sessions'
/// questions to clients that may answer them; how many it declined.
pub fn declineOpen(c: *Client, a: A, location: []const u8, session: []const u8) !usize {
    var declined: usize = 0;
    for (try list(c, a, location)) |q| {
        const theirs = q.session orelse continue;
        if (!std.mem.eql(u8, theirs, session)) continue;
        answer(c, a, q.id, "decline", null) catch continue;
        declined += 1;
    }
    return declined;
}

test "questions parse per kind and forms list their fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pick = try std.json.parseFromSliceLeaky(Value, a,
        \\{"id":"que_1","session":"ses_1","source":"guard","message":"Run it?","kind":"select","options":[{"value":"once","label":"Allow once"},{"value":"no"}],"expiresAt":5}
    , .{});
    const q = Question.parse(a, pick).?;
    try std.testing.expectEqual(Kind.select, q.kind);
    try std.testing.expectEqualStrings("Allow once", q.options[0].text());
    try std.testing.expectEqualStrings("no", q.options[1].text());
    try std.testing.expect(Question.parse(a, try std.json.parseFromSliceLeaky(Value, a, "{\"id\":\"q\",\"kind\":\"select\",\"options\":[]}", .{})) == null);
    try std.testing.expect(Question.parse(a, try std.json.parseFromSliceLeaky(Value, a, "{\"id\":\"q\",\"kind\":\"poll\"}", .{})) == null);

    const schema = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"branch":{"type":"string","title":"Branch"},"depth":{"type":"integer"},"force":{"type":"boolean"},"mode":{"type":"string","enum":["fast","safe"]}},"required":["branch"]}
    , .{});
    const fs = try fields(a, schema);
    try std.testing.expectEqual(@as(usize, 4), fs.len);
    try std.testing.expectEqualStrings("Branch", fs[0].label);
    try std.testing.expect(fs[0].required and !fs[1].required);
    try std.testing.expectError(error.Invalid, fieldValue(a, fs[0], ""));
    try std.testing.expect(try fieldValue(a, fs[1], " ") == null);
    try std.testing.expectEqual(@as(i64, 3), (try fieldValue(a, fs[1], "3")).?.integer);
    try std.testing.expectError(error.Invalid, fieldValue(a, fs[1], "three"));
    try std.testing.expect((try fieldValue(a, fs[2], "yes")).?.bool);
    try std.testing.expectError(error.Invalid, fieldValue(a, fs[3], "slow"));
}
