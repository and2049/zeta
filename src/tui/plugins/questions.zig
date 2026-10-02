//! The four built-in question dock renderers.
const std = @import("std");
const plugin = @import("../plugin.zig");
const Entry = @import("../questions.zig").Entry;
const Answer = @import("../questions.zig").Answer;
const Screen = @import("../screen.zig").Screen;
const Cursor = @import("../editor_view.zig").Cursor;
const Event = @import("../input.zig").Event;
const Q = @import("client").questions;
const width = @import("../width.zig");

pub const plugin_entry: plugin.Plugin = .{ .id = "questions", .setup = setup };
fn setup(r: *plugin.Registry) !void {
    try r.addQuestionRenderer(.{ .kind = .confirm, .rows = rows, .draw = drawConfirm, .handle = confirm });
    try r.addQuestionRenderer(.{ .kind = .select, .rows = rows, .draw = drawSelect, .handle = select });
    try r.addQuestionRenderer(.{ .kind = .input, .rows = rows, .draw = drawInput, .handle = input });
    try r.addQuestionRenderer(.{ .kind = .form, .rows = rows, .draw = drawForm, .handle = form });
}

fn rows(e: *const Entry) usize {
    return switch (e.question.kind) {
        .confirm => 4,
        .select => 3 + @min(e.question.options.len, 9),
        .input => 4,
        .form => 6,
    };
}

fn header(s: *Screen, e: *const Entry, y: usize) void {
    s.drawStyledText(1, y, e.question.source, .{ .bold = true });
    s.drawText(1, y + 1, e.question.message);
}
fn drawConfirm(s: *Screen, e: *const Entry, y: usize, _: usize) ?Cursor {
    header(s, e, y);
    if (e.question.detail) |detail| s.drawStyledText(1, y + 2, detail, .{ .dim = true });
    s.drawStyledText(1, y + 3, "1 / y / Enter yes · 2 / n no · Esc decline", .{ .dim = true });
    return null;
}
fn confirm(_: *Entry, ev: Event) anyerror!?Answer {
    if (ev == .key and ev.key == .enter) return .{ .action = "accept" };
    if (ev != .text) return null;
    return switch (ev.text) {
        'y', 'Y', '1' => .{ .action = "accept" },
        'n', 'N', '2' => .{ .action = "decline" },
        else => null,
    };
}
fn drawSelect(s: *Screen, e: *const Entry, y: usize, content: usize) ?Cursor {
    header(s, e, y);
    const max = @min(e.question.options.len, content -| 3);
    const start = if (e.selected >= max) e.selected - max + 1 else 0;
    for (e.question.options[start..@min(start + max, e.question.options.len)], 0..) |option, i| {
        var buf: [24]u8 = undefined;
        const at = start + i;
        s.drawStyledText(1, y + 2 + i, std.fmt.bufPrint(&buf, "{d} {s} ", .{ at + 1, if (at == e.selected) ">" else " " }) catch "", .{ .bold = at == e.selected });
        s.drawText(6, y + 2 + i, option.text());
        if (option.description.len > 0) s.drawStyledText(@min(7 + width.displayWidth(option.text()), s.cols), y + 2 + i, option.description, .{ .dim = true });
    }
    s.drawStyledText(1, y + 2 + max, "↑/↓ choose · Enter select · 1-9 direct · Esc decline", .{ .dim = true });
    return null;
}
fn select(e: *Entry, ev: Event) anyerror!?Answer {
    if (ev == .key) switch (ev.key) {
        .up => e.selected -|= 1,
        .down => if (e.selected + 1 < e.question.options.len) {
            e.selected += 1;
        },
        .enter => return .{ .action = "accept", .content = .{ .string = e.question.options[e.selected].value } },
        else => {},
    } else if (ev == .text and ev.text >= '1' and ev.text <= '9') {
        const at: usize = ev.text - '1';
        if (at < e.question.options.len) return .{ .action = "accept", .content = .{ .string = e.question.options[at].value } };
    }
    return null;
}
fn typed(s: *Screen, e: *const Entry, y: usize, secret: bool) Cursor {
    if (e.text.items.len == 0) {
        if (e.question.placeholder) |placeholder| s.drawStyledText(1, y, placeholder, .{ .dim = true });
    } else if (secret) {
        var it: width.Iterator = .{ .input = e.text.items };
        var x: usize = 1;
        while (it.next()) |_| {
            s.drawText(x, y, "•");
            x += 1;
        }
        return .{ .x = @min(x, s.cols - 1), .y = y };
    } else s.drawText(1, y, e.text.items);
    return .{ .x = @min(1 + width.displayWidth(e.text.items), s.cols - 1), .y = y };
}
fn drawInput(s: *Screen, e: *const Entry, y: usize, _: usize) ?Cursor {
    header(s, e, y);
    s.drawStyledText(1, y + 2, "Type an answer · Enter send · Esc decline", .{ .dim = true });
    return typed(s, e, y + 3, e.question.secret);
}
fn input(e: *Entry, ev: Event) anyerror!?Answer {
    if (ev == .key and ev.key == .enter) return .{ .action = "accept", .content = .{ .string = try e.allocator().dupe(u8, e.text.items) } };
    try e.append(ev);
    return null;
}
fn drawForm(s: *Screen, e: *const Entry, y: usize, _: usize) ?Cursor {
    header(s, e, y);
    if (e.fields.len == 0) {
        s.drawText(1, y + 2, "Enter to submit empty form");
        return null;
    }
    const field = e.fields[e.field_index];
    var buf: [256]u8 = undefined;
    s.drawStyledText(1, y + 2, std.fmt.bufPrint(&buf, "{s} ({d}/{d}){s}", .{ field.label, e.field_index + 1, e.fields.len, if (field.required) @as([]const u8, " *") else "" }) catch field.label, .{ .bold = true });
    s.drawStyledText(1, y + 3, field.description, .{ .dim = true });
    if (field.choices.len > 0) {
        var x: usize = 1;
        for (field.choices, 0..) |choice, i| {
            if (i > 0) {
                s.drawText(x, y + 4, " / ");
                x += 3;
            }
            s.drawStyledText(x, y + 4, choice, .{ .dim = true });
            x += width.displayWidth(choice);
        }
    } else s.drawStyledText(1, y + 4, if (field.type == .boolean) "[y/n]" else if (e.invalid) "Invalid value; try again" else "Enter next · Esc decline", .{ .dim = true });
    if (e.invalid) s.drawStyledText(1, y + 4, "Invalid value; try again", .{ .foreground = @import("../screen.zig").Color.red });
    return typed(s, e, y + 5, false);
}
fn form(e: *Entry, ev: Event) anyerror!?Answer {
    if (ev == .key and ev.key == .enter) {
        if (e.fields.len > 0) {
            const f = e.fields[e.field_index];
            const value = Q.fieldValue(e.allocator(), f, e.text.items) catch |err| {
                if (err != error.Invalid) return err;
                e.invalid = true;
                return null;
            };
            if (value) |v| try e.values.put(e.allocator(), f.name, v);
            e.field_index += 1;
            e.text.clearRetainingCapacity();
            e.invalid = false;
            if (e.field_index < e.fields.len) return null;
        }
        return .{ .action = "accept", .content = .{ .object = e.values } };
    }
    try e.append(ev);
    return null;
}
