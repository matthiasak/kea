//! The reel in Codegraff's colors, as nanoterm and nanomon wear them:
//! warm charcoal or cream, amber for what's chosen, rust, sage, slate,
//! violet and teal for the rest; Geist for words, JetBrains Mono for code.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Color = ui.Color;

/// The palette's hues, for what's colored without a meaning (cards, dots).
pub fn hues(dark: bool) [6]Color {
    return if (dark)
        .{ .hex(0xe8a33d), .hex(0xd2674f), .hex(0x7fa86b), .hex(0x8a9bb0), .hex(0xbd80e4), .hex(0x6fb0a8) }
    else
        .{ .hex(0xc77d20), .hex(0xb14228), .hex(0x5c7e47), .hex(0x3b6fb0), .hex(0x7a4ea3), .hex(0x2f8f9d) };
}

pub fn ui_(dark: bool) ui.Theme {
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    var t = if (dark) ui.Theme.dark_theme else ui.Theme.light;
    if (dark) {
        const bg = Color.hex(0x16140f);
        t.background = bg;
        t.surface = .hex(0x24211a);
        t.surface_hover = .hex(0x2e2a22);
        t.text = .hex(0xedeae2);
        t.muted = .hex(0x9a9384);
        t.border = bg.mix(white, 0.10);
        t.accent = .hex(0xe8a33d);
        t.accent_hover = t.accent.mix(white, 0.14);
        t.accent_text = bg;
        t.track = .hex(0x2c2820);
        t.danger = .hex(0xd2674f);
        t.success = .hex(0x7fa86b);
    } else {
        const bg = Color.hex(0xfaf8f3);
        t.background = bg;
        t.surface = .hex(0xfffdf8);
        t.surface_hover = .hex(0xf0ece3);
        t.text = .hex(0x1a1813);
        t.muted = .hex(0x6b6557);
        t.border = bg.mix(black, 0.10);
        t.accent = .hex(0xc77d20);
        t.accent_hover = t.accent.mix(black, 0.14);
        t.accent_text = .hex(0xfffdf8);
        t.track = .hex(0xe9e3d6);
        t.danger = .hex(0xb14228);
        t.success = .hex(0x5c7e47);
    }
    t.font = "Geist";
    t.mono_font = "JetBrains Mono";
    return t;
}
