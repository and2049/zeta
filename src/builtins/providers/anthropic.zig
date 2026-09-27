//! Anthropic: the Messages API with an API key.
pub const spec: @import("shared.zig").Spec = .{
    .id = "anthropic",
    .name = "Anthropic",
    .api = @import("../provider_anthropic/root.zig").api_id,
    .base_url = @import("../provider_anthropic/root.zig").default_base_url,
    .env = &.{"ANTHROPIC_API_KEY"},
};
