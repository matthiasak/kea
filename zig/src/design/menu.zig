//! A menu's measurements and colours (`MenuMetrics`, SiteCard.swift
//! 575-610), as macOS lays out an NSMenu, so a card drawn by Kea (the site
//! card) sits beside a right-click menu as one of its own.
const ui = @import("nanoui").ui;

/// `NSFont.menuFont(ofSize: 0)`.
pub const font: f32 = 13;
/// One item.
pub const row: f32 = 24;
/// A separator's band.
pub const separator: f32 = 11;
/// Above the first item and under the last.
pub const pad: f32 = 5;
/// Where the highlight starts, from the menu's edge.
pub const inset: f32 = 5;
/// Where an item's text starts, from the menu's edge (no checkmark column).
pub const text: f32 = 17;
/// From the end of the text, or of its key equivalent, to the menu's edge.
pub const trailing: f32 = 17;
/// A separator's line, in from either edge.
pub const rule: f32 = 16;
pub const highlight: f32 = 6;
pub const corner: f32 = 12;

/// Kea's sunset, which a menu's highlight is blended from.
const accent: ui.Color = .{ .r = 0.788, .g = 0.271, .b = 0.184 };

/// The line under the pointer: the accent as a menu shows it over its
/// glass — blended 42 % toward white in light, 15 % toward black in dark.
pub fn selection(dark: bool) ui.Color {
    if (dark) return .{ .r = accent.r * 0.85, .g = accent.g * 0.85, .b = accent.b * 0.85 };
    return .{ .r = accent.r + (1 - accent.r) * 0.42, .g = accent.g + (1 - accent.g) * 0.42, .b = accent.b + (1 - accent.b) * 0.42 };
}

/// The panel's hairline edge.
pub fn edge(dark: bool) ui.Color {
    return if (dark) ui.Color.white.alpha(0.18) else ui.Color.black.alpha(0.26);
}

/// `NSColor.labelColor`.
pub fn label(dark: bool) ui.Color {
    return (if (dark) ui.Color.white else ui.Color.black).alpha(0.85);
}

/// `NSColor.secondaryLabelColor`.
pub fn secondary(dark: bool) ui.Color {
    return if (dark) ui.Color.white.alpha(0.55) else ui.Color.black.alpha(0.5);
}

/// `NSColor.separatorColor`.
pub fn separatorColor(dark: bool) ui.Color {
    return (if (dark) ui.Color.white else ui.Color.black).alpha(0.1);
}
