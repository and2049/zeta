//! Self-contained image data for messages persisted in the conversation log.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {
    mimeType: []const u8,
    data: []const u8, // Standard padded base64, never a URL or a file path.

    /// Validates before an image is admitted to a message. Returned slices
    /// belong to `arena`; callers retain the arena for the message lifetime.
    pub fn init(arena: Allocator, mime: []const u8, encoded: []const u8) !Image {
        if (!supportedMime(mime)) return error.InvalidImageMime;
        const decoder = std.base64.standard.Decoder;
        const len = decoder.calcSizeForSlice(encoded) catch return error.InvalidImageData;
        if (len == 0) return error.InvalidImageData;
        const bytes = try arena.alloc(u8, len);
        defer arena.free(bytes);
        decoder.decode(bytes, encoded) catch return error.InvalidImageData;
        // Reject noncanonical padding and unused trailing bits too.
        const canonical = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(len));
        defer arena.free(canonical);
        if (!std.mem.eql(u8, std.base64.standard.Encoder.encode(canonical, bytes), encoded)) return error.InvalidImageData;
        const owned_mime = try arena.dupe(u8, mime);
        errdefer arena.free(owned_mime);
        return .{ .mimeType = owned_mime, .data = try arena.dupe(u8, encoded) };
    }

    /// Caller frees the returned URL with `arena`.
    pub fn dataUrl(self: Image, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ self.mimeType, self.data });
    }
};

/// The image type `bytes` start like, among the supported ones.
pub fn sniff(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

/// An image from raw file bytes; caller frees `data` with `arena`, while `mimeType` borrows `mime`.
pub fn fromBytes(arena: Allocator, mime: []const u8, bytes: []const u8) !Image {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return .{ .mimeType = mime, .data = std.base64.standard.Encoder.encode(encoded, bytes) };
}

test sniff {
    try std.testing.expectEqualStrings("image/png", sniff("\x89PNG\r\n\x1a\nrest").?);
    try std.testing.expectEqualStrings("image/webp", sniff("RIFF\x00\x00\x00\x00WEBPVP8").?);
    try std.testing.expect(sniff("plain text") == null);
}

pub fn supportedMime(mime: []const u8) bool {
    for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" }) |allowed| {
        if (std.mem.eql(u8, mime, allowed)) return true;
    }
    return false;
}

test "image validation and self-contained data URL" {
    const a = std.testing.allocator;
    const image = try Image.init(a, "image/png", "YWJj");
    defer a.free(image.mimeType);
    defer a.free(image.data);
    const url = try image.dataUrl(a);
    defer a.free(url);
    try std.testing.expectEqualStrings("data:image/png;base64,YWJj", url);
    try std.testing.expectError(error.InvalidImageMime, Image.init(a, "image/svg+xml", "YWJj"));
    try std.testing.expectError(error.InvalidImageData, Image.init(a, "image/png", "YQ==junk"));
    try std.testing.expectError(error.InvalidImageData, Image.init(a, "image/png", ""));
}
