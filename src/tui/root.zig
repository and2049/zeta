//! Terminal UI client. Uses only the client protocol, never core.

const std = @import("std");

pub const input = @import("input.zig");
pub const screen = @import("screen.zig");
pub const width = @import("width.zig");
pub const editor = @import("editor.zig");
pub const markdown = @import("markdown.zig");
pub const transcript = @import("transcript.zig");
pub const picker = @import("picker.zig");
pub const plugin = @import("plugin.zig");
pub const builtins = @import("builtins.zig");
pub const palette = @import("palette.zig");
pub const completion = @import("completion.zig");
pub const terminal_style = @import("terminal_style.zig");
pub const run = @import("run.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("actions.zig");
    _ = @import("actions_overlay.zig");
    _ = @import("app_completion.zig");
    _ = @import("app_picker.zig");
    _ = @import("app_projection.zig");
    _ = @import("app_auth.zig");
    _ = @import("git_branch.zig");
    _ = @import("clock.zig");
    _ = @import("markdown_table.zig");
    _ = @import("settings.zig");
    _ = @import("view.zig");
    _ = @import("App.zig");
    _ = @import("window_title.zig");
}
