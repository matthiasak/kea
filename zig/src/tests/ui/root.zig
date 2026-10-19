//! `zig build ui-test`: headless chrome suites on `ui.Tester` (one file per area).
test {
    _ = @import("groundwork.zig");
    _ = @import("layout.zig");
}
