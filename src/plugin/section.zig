//! The `section` capability: text a plugin adds to the system prompt of
//! runs where it applies, after the project's instructions.

pub const Section = struct {
    /// Unique within a layer, like a tool name; also its label in listings.
    name: []const u8,
    text: []const u8,
};
