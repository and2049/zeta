//! Client library for talking to a zeta server over HTTP + SSE.

const std = @import("std");

pub const Client = @import("Client.zig");
pub const attach = @import("attach.zig");
pub const run = @import("run.zig");
pub const run_input = @import("run_input.zig");
pub const usage_cli = @import("usage_cli.zig");
pub const sessions_cli = @import("sessions_cli.zig");
pub const admin = @import("admin.zig");
pub const session_api = @import("session_api.zig");
pub const files = @import("files.zig");
pub const commands = @import("commands.zig");
pub const auth = @import("auth.zig");
pub const standalone = @import("standalone.zig");
pub const state = @import("state.zig");
pub const connection = @import("connection.zig");

test {
    std.testing.refAllDecls(@This());
}
