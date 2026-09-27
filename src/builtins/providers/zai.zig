//! Z.AI (GLM, global): OpenAI-compatible, API key.
pub const spec: @import("shared.zig").Spec = .{
    .id = "zai",
    .name = "Z.AI",
    .base_url = "https://api.z.ai/api/paas/v4",
    .env = &.{"ZHIPU_API_KEY"},
};
