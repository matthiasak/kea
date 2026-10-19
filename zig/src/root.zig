//! KeaZig's modules as one import (`@import("kea")`) for the test harnesses:
//! `zig build ui-test`, `perf`, `e2e` and `snapshots`.
pub const kea = @import("app/kea.zig");
pub const Kea = kea.Kea;
pub const browsers = @import("app/browsers.zig");
pub const windows_file = @import("data/windows_file.zig");
pub const Browser = @import("model/browser.zig").Browser;
pub const Tab = @import("web/tab.zig").Tab;
pub const StageHost = @import("web/stage_host.zig").StageHost;
pub const window_view = @import("chrome/window_view.zig");
pub const tab_menu = @import("chrome/tab_menu.zig");
pub const fold = @import("chrome/fold.zig");
pub const spaces_view = @import("chrome/spaces_view.zig");
pub const store = @import("data/store.zig");
pub const disk = @import("data/disk.zig");
pub const json = @import("data/json.zig");
pub const session = @import("data/session.zig");
pub const Temp = @import("tests/temp.zig").Temp;
