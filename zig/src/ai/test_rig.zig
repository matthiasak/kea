//! A throwaway AI add-on for tests: a temp folder and defaults suite, its
//! store and prefs, and an `Ai` in test mode (keys in memory, nothing fetched).
const std = @import("std");
const Temp = @import("../tests/temp.zig").Temp;
const Store = @import("../data/store.zig").Store;
const Prefs = @import("../data/prefs.zig").Prefs;
const ai = @import("ai.zig");

pub const Rig = struct {
    gpa: std.mem.Allocator,
    temp: Temp,
    store: Store,
    prefs: Prefs,
    ai: *ai.Ai,

    /// In place: `prefs` and `ai` point at `store`.
    pub fn init(self: *Rig, gpa: std.mem.Allocator) !void {
        self.gpa = gpa;
        self.temp = try Temp.init(gpa);
        self.store = try Store.init(gpa, self.temp.root, self.temp.suite);
        self.prefs = Prefs.init(gpa, &self.store, .{ .testing = true });
        self.ai = try ai.Ai.create(gpa, &self.store, &self.prefs, true);
    }

    /// The `Ai` again from what is on disk, as at the next launch.
    pub fn relaunch(self: *Rig) !void {
        self.store.disk.drain();
        self.ai.destroy();
        self.ai = try ai.Ai.create(self.gpa, &self.store, &self.prefs, true);
    }

    pub fn deinit(self: *Rig) void {
        self.ai.destroy();
        self.prefs.deinit();
        self.store.deinit();
        self.temp.deinit(self.gpa);
    }
};
