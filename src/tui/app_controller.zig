//! Snapshot replies are valid only for the subscription and selection that
//! requested them. A restored server may restart sequence numbers at zero.
const std = @import("std");

pub const Token = struct { generation: u64, epoch: u64, session: []const u8 };

pub const Controller = struct {
    generation: u64 = 0,
    epoch: u64 = 0,
    selected: ?[]const u8 = null,
    pending: bool = false,

    pub fn reconnect(self: *Controller, generation: u64) ?Token {
        if (self.generation == generation) return null;
        self.generation = generation;
        self.epoch += 1;
        self.pending = self.selected != null;
        return self.current();
    }

    pub fn select(self: *Controller, session: []const u8) Token {
        self.selected = session;
        self.epoch += 1;
        self.pending = true;
        return self.current().?;
    }

    pub fn current(self: Controller) ?Token {
        return if (self.selected) |id| .{ .generation = self.generation, .epoch = self.epoch, .session = id } else null;
    }

    pub fn accepts(self: *Controller, token: Token) bool {
        const active = self.current() orelse return false;
        if (token.generation != active.generation or token.epoch != active.epoch or !std.mem.eql(u8, token.session, active.session)) return false;
        self.pending = false;
        return true;
    }
};

test "old server GET cannot hydrate after reconnect with same session id" {
    var c: Controller = .{};
    _ = c.reconnect(1);
    const old = c.select("ses_same");
    const fresh = c.reconnect(2).?;
    try std.testing.expect(c.pending);
    try std.testing.expect(!c.accepts(old)); // old snapshot revision could be 1000
    try std.testing.expect(c.pending);
    try std.testing.expect(c.accepts(fresh)); // new revision can start at zero
    try std.testing.expect(!c.pending);
    const previous_selection = c.select("ses_same");
    _ = c.select("ses_other");
    _ = c.select("ses_same");
    try std.testing.expect(!c.accepts(previous_selection));
}
