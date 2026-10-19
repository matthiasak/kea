//! `zig build ui-test`: headless chrome suites on `ui.Tester` (one file per area).
test {
    _ = @import("groundwork.zig");
    _ = @import("layout.zig");
    _ = @import("tabs_model.zig");
    _ = @import("strip.zig");
    _ = @import("column.zig");
    _ = @import("handoff.zig");
    _ = @import("site_card.zig");
    _ = @import("omnibox.zig");
    _ = @import("link_bubble.zig");
}
