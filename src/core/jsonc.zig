//! JSONC → JSON: strips `//` and `/* */` comments and trailing commas,
//! leaving string contents untouched.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn strip(gpa: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, src.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < src.len and src[i] != '"') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i = @min(i + 1, src.len);
            out.appendSliceAssumeCapacity(src[start..i]);
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return error.UnterminatedComment;
            i = end + 2;
        } else if (c == '}' or c == ']') {
            var j = out.items.len;
            while (j > 0 and std.ascii.isWhitespace(out.items[j - 1])) j -= 1;
            if (j > 0 and out.items[j - 1] == ',') {
                std.mem.copyForwards(u8, out.items[j - 1 ..], out.items[j..]);
                out.items.len -= 1;
            }
            out.appendAssumeCapacity(c);
            i += 1;
        } else {
            out.appendAssumeCapacity(c);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test strip {
    const src =
        \\{
        \\  // line comment
        \\  "a": "http://x", /* block */
        \\  "b": ["q\"//", 2,],
        \\}
    ;
    const got = try strip(std.testing.allocator, src);
    defer std.testing.allocator.free(got);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, got, .{});
    defer v.deinit();
    try std.testing.expectEqualStrings("http://x", v.value.object.get("a").?.string);
    try std.testing.expectEqualStrings("q\"//", v.value.object.get("b").?.array.items[0].string);
}
