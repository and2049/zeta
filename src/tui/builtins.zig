//! The built-in TUI plugins, registered in this order.
const plugin = @import("plugin.zig");

pub const plugins = [_]plugin.Plugin{
    @import("plugins/session.zig").plugin_entry,
    @import("plugins/app.zig").plugin_entry,
    @import("plugins/bars.zig").plugin_entry,
    @import("plugins/tools.zig").plugin_entry,
    @import("plugins/welcome.zig").plugin_entry,
    @import("plugins/questions.zig").plugin_entry,
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("plugins/session.zig");
    _ = @import("plugins/app.zig");
    _ = @import("plugins/bars.zig");
    _ = @import("plugins/tools.zig");
    _ = @import("plugins/welcome.zig");
    _ = @import("plugins/questions.zig");
}
