//! OpenRouter: OpenAI-compatible, API key.
pub const spec: @import("shared.zig").Spec = .{
    .id = "openrouter",
    .name = "OpenRouter",
    .base_url = "https://openrouter.ai/api/v1",
    .env = &.{"OPENROUTER_API_KEY"},
};
