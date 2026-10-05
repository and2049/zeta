//! Reaches built-ins only through the plugin API.

const std = @import("std");

pub const bus = @import("bus.zig");
pub const Bus = bus.Bus;
pub const session = @import("session.zig");
pub const Session = session.Session;
pub const inbox = @import("inbox.zig");
pub const Inbox = inbox.Inbox;
pub const assemble = @import("assemble.zig");
pub const loop = @import("loop.zig");
pub const projection = @import("projection.zig");
pub const jsonc = @import("jsonc.zig");
pub const schema = @import("schema.zig");
pub const config = @import("config.zig");
pub const config_edit = @import("config_edit.zig");
pub const plugin_config = @import("plugin_config.zig");
pub const instructions = @import("instructions.zig");
pub const glob = @import("glob.zig");
pub const prompt = @import("prompt.zig");
pub const location = @import("location.zig");
pub const workspace_files = @import("workspace_files.zig");
pub const Runtime = @import("Runtime.zig");
pub const runtime_route = @import("runtime_route.zig");
pub const runtime_model = @import("runtime_model.zig");
pub const inspect = @import("inspect.zig");
pub const commands = @import("commands.zig");
pub const compaction = @import("compaction.zig");
pub const questions = @import("questions.zig");
pub const usage = @import("usage.zig");
pub const session_search = @import("session_search.zig");
pub const undo = @import("undo.zig");
pub const shell = @import("shell.zig");
pub const session_move = @import("session_move.zig");
pub const session_storage = @import("session_storage.zig");
pub const Loop = loop.Loop;

test {
    std.testing.refAllDecls(@This());
}
