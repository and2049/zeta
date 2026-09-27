//! How much a model reasons before it answers: one scale for every
//! provider, which each transport turns into its own setting.
const std = @import("std");

pub const Level = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    /// A level name; null for anything else.
    pub fn parse(text: []const u8) ?Level {
        return std.meta.stringToEnum(Level, text);
    }
};

/// Selection text meaning "no selection": the configured or the provider's
/// default applies.
pub const auto = "auto";

/// A level name or `auto`.
pub fn validSelection(text: []const u8) bool {
    return std.mem.eql(u8, text, auto) or Level.parse(text) != null;
}

pub const Set = std.EnumSet(Level);

/// `level` if `supported` has it, else the next supported level up, else
/// the next one down; `off` when nothing is supported.
pub fn clamp(level: Level, supported: Set) Level {
    if (supported.contains(level)) return level;
    const all = std.enums.values(Level);
    const at = @intFromEnum(level);
    for (all[at..]) |l| if (supported.contains(l)) return l;
    var i = at;
    while (i > 0) {
        i -= 1;
        if (supported.contains(all[i])) return all[i];
    }
    return .off;
}

test clamp {
    const some: Set = .initMany(&.{ .low, .medium, .high });
    try std.testing.expectEqual(Level.high, clamp(.high, some));
    try std.testing.expectEqual(Level.low, clamp(.minimal, some));
    try std.testing.expectEqual(Level.high, clamp(.xhigh, some));
    try std.testing.expectEqual(Level.off, clamp(.medium, .initEmpty()));
    try std.testing.expect(validSelection("auto") and validSelection("xhigh") and !validSelection("max"));
}
