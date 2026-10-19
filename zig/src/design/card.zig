//! Shadows as SwiftUI writes them, and the page's card edge (`CardEdge`).
const ui = @import("nanoui").ui;
const palette = @import("palette.zig");
const metrics = @import("metrics.zig");

/// `.shadow(color: .black.opacity(alpha), radius:, y:)`: SwiftUI's radius
/// is half the CSS blur nanoui takes.
pub fn swiftShadow(alpha: f32, radius: f32, y: f32) ui.Shadow {
    return .{ .color = ui.Color.black.alpha(alpha), .blur = 2 * radius, .y = y };
}

/// `CardEdge.shadow` and `CardEdge.edge`.
pub const shadow_alpha: f32 = 0.07;
pub const edge_alpha: f32 = 0.08;

/// Styles box `index` (a stage hole) as Kea's card: round corners, a
/// hairline edge and a soft shadow outside it only, so the page shows.
pub fn cardEdge(c: *ui.Context, index: u32) void {
    const p = palette.get(c.theme.dark);
    const s = &c.node(index).style;
    s.radius = metrics.card_radius;
    s.border = p.ink.alpha(edge_alpha);
    s.border_width = 1;
    var sh = swiftShadow(shadow_alpha, 6, 1);
    sh.knockout = true;
    s.shadow = sh;
}
