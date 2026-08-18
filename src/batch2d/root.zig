//! batch2d — textured-quad 2D batching for DVUI / SDL_Renderer.
//!
//! Soft sprites share one atlas; per-instance scale and PMA tint stay in one draw call.
//! No graph/SQLite types — only points, sizes, colors, textures.

const std = @import("std");

pub const SoftAtlas = @import("SoftAtlas.zig");
pub const SpriteBatch = @import("SpriteBatch.zig");
pub const LineBatch = @import("LineBatch.zig");
pub const Camera = @import("Camera.zig");
pub const HitIndex = @import("HitIndex.zig");

pub const SpriteKind = SoftAtlas.Kind;
pub const UvRect = SoftAtlas.UvRect;

test {
    std.testing.refAllDecls(@This());
}
