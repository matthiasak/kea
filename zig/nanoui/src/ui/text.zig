//! Text, whichever system shapes it: CoreText on macOS (`text_mac.zig`),
//! nanoui's own TrueType reader elsewhere (`text_tt.zig`), or there too
//! when built with `-Dportable=true` (to test that path on a Mac). Both
//! give the same interface: fonts, shaped and wrapped layouts, carets, and
//! the glyph atlas.
const builtin = @import("builtin");
const options = @import("build_options");

/// nanoui's own text and CPU renderer, not CoreText and Metal.
pub const portable = options.portable or builtin.os.tag != .macos;
const impl = if (portable) @import("text_tt.zig") else @import("text_mac.zig");

pub const TextSystem = impl.TextSystem;
pub const Font = impl.Font;
pub const Glyph = impl.Glyph;
pub const Layout = impl.Layout;
pub const Line = impl.Line;
pub const Atlas = impl.Atlas;
pub const Sprite = impl.Sprite;
pub const subpixel_bins = impl.subpixel_bins;
pub const rich = impl.rich;
