//! Zhipu AI (GLM, China): OpenAI-compatible, API key.
pub const spec: @import("shared.zig").Spec = .{
    .id = "zhipuai",
    .name = "Zhipu AI",
    .base_url = "https://open.bigmodel.cn/api/paas/v4",
    .env = &.{"ZHIPU_API_KEY"},
};
