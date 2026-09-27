const std = @import("std");
const proto = @import("proto");

const b64 = std.base64.url_safe_no_pad;

pub const password_len = b64.Encoder.calcSize(24);

pub fn generatePassword(io: std.Io) ![password_len]u8 {
    var raw: [24]u8 = undefined;
    try io.randomSecure(&raw);
    var out: [password_len]u8 = undefined;
    _ = b64.Encoder.encode(&out, &raw);
    return out;
}

/// Checks an `Authorization` header value in constant time relative to the password.
pub fn check(header: ?[]const u8, password: []const u8) bool {
    const value = header orelse return false;
    const prefix = "Basic ";
    if (value.len <= prefix.len or !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return false;
    const encoded = std.mem.trim(u8, value[prefix.len..], " ");

    var buf: [256]u8 = undefined;
    const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
    if (n > buf.len) return false;
    std.base64.standard.Decoder.decode(buf[0..n], encoded) catch return false;
    const creds = buf[0..n];

    const user = proto.discovery.auth_user;
    if (creds.len != user.len + 1 + password.len) return false;
    if (!std.mem.eql(u8, creds[0..user.len], user) or creds[user.len] != ':') return false;
    var diff: u8 = 0;
    for (creds[user.len + 1 ..], password) |a, b| diff |= a ^ b;
    return diff == 0;
}

test "check accepts the right credentials only" {
    var buf: [128]u8 = undefined;
    const good = try proto.discovery.authHeader(&buf, "s3cret");
    try std.testing.expect(check(good, "s3cret"));
    try std.testing.expect(!check(good, "s3creT"));
    try std.testing.expect(!check(null, "s3cret"));
    try std.testing.expect(!check("Bearer s3cret", "s3cret"));
    try std.testing.expect(!check("Basic b3RoZXI6czNjcmV0", "s3cret"));
    try std.testing.expect(!check("Basic !!!", "s3cret"));
}

test "generated passwords differ" {
    const a = try generatePassword(std.testing.io);
    const b = try generatePassword(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
