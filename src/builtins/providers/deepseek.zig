//! DeepSeek: OpenAI-compatible, API key.
pub const spec: @import("shared.zig").Spec = .{
    .id = "deepseek",
    .name = "DeepSeek",
    .base_url = "https://api.deepseek.com",
    .env = &.{"DEEPSEEK_API_KEY"},
};
