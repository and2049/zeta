//! Turn a local image path into a self-contained proto attachment.
const std = @import("std");
const proto = @import("proto");

pub fn load(a: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8) !proto.attachment.Image {
    const mime: []const u8 = if (ends(path, ".png")) "image/png" else if (ends(path, ".jpg") or ends(path, ".jpeg")) "image/jpeg" else if (ends(path, ".gif")) "image/gif" else if (ends(path, ".webp")) "image/webp" else return error.UnsupportedImage;
    const absolute = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(a, &.{ cwd, path });
    // Base64 expands 3 input bytes to 4; the server bounds the complete JSON
    // request to 8 MiB and reports RequestTooLarge for combined attachments.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, absolute, a, .limited(8 * 1024 * 1024 / 4 * 3));
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return proto.attachment.Image.init(a, mime, encoded);
}

fn ends(path: []const u8, extension: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, extension);
}

test "mime inferred strictly" {
    try std.testing.expect(ends("file.JPEG", ".jpeg"));
    try std.testing.expect(!ends("file.svg", ".png"));
}
