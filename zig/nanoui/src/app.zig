//! The application: lifecycle, the menu bar, tray icons, bound services, timers.
const std = @import("std");
const objc = @import("objc.zig");
const ipc = @import("ipc.zig");
const tsgen = @import("tsgen.zig");
const dev = @import("dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("menu.zig");
const tray_mod = @import("tray.zig");
const Window = window_mod.Window;

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Quit when the last window closes.
    quit_on_last_window_closed: bool = true,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    nsapp: objc.Object,
    delegate: objc.Object,
    windows: std.ArrayList(*Window) = .empty,
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    trays: std.ArrayList(*tray_mod.Tray) = .empty,
    /// The generated client, built once on first request.
    client_js: ?[]u8 = null,
    flags: dev.Flags = .{},
    running: bool = false,
    stopping: bool = false,
    /// `NANOUI_DEBUG=1`: log windows' ids and frames, for tools and tests.
    debug: bool = false,

    /// Creates the app. Call from `main`, on the main thread.
    pub fn create(init: std.process.Init, options: Options) !*App {
        if (!objc.isMainThread()) return error.NotMainThread;
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        const flags = try dev.Flags.parse(init);

        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const delegate_class = objc.defineClass(.{
            .name = "NanoUIAppDelegate",
            .protocols = &.{"NSApplicationDelegate"},
            .methods = &.{
                .{ .name = "applicationDidFinishLaunching:", .imp = &didFinishLaunching, .types = "v@:@" },
                .{ .name = "applicationShouldTerminate:", .imp = &shouldTerminate, .types = "Q@:@" },
                .{ .name = "applicationShouldHandleReopen:hasVisibleWindows:", .imp = &shouldReopen, .types = "c@:@c" },
            },
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);

        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .nsapp = nsapp,
            .delegate = delegate,
            .flags = flags,
            .debug = init.environ_map.get("NANOUI_DEBUG") != null,
        };
        // A plain binary (not an .app bundle) still gets a Dock icon and
        // menus; hidden runs (tests, snapshots) get neither, nor focus.
        const policy: objc.NSInteger = if (flags.hidden) 2 else 0;
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{policy});
        objc.msg(void, nsapp, "setDelegate:", .{delegate});
        try self.setMenu(&default_menu);
        return self;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) {
            const w = self.windows.items[self.windows.items.len - 1];
            w.close();
        }
        self.windows.deinit(self.gpa);
        self.services.deinit(self.gpa);
        self.events.deinit(self.gpa);
        for (self.trays.items) |t| t.destroy();
        self.trays.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        if (self.client_js) |js| self.gpa.free(js);
        objc.setZig(self.delegate, null);
        objc.msg(void, self.nsapp, "setDelegate:", .{@as(?objc.Object, null)});
        objc.release(self.delegate);
        self.gpa.destroy(self);
    }

    /// Binds a service: pages call its methods as `Name.method(...)`
    /// through the generated client (`nanoui.js`).
    pub fn bind(self: *App, service: anytype) !void {
        const T = @typeInfo(@TypeOf(service)).pointer.child;
        const svc = ipc.service(T, service);
        try self.services.put(self.gpa, svc.name, svc);
    }

    /// Declares a typed event (`nanoui.Event(...)`) for the generated client.
    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.events.append(self.gpa, E.client);
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        return w;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| {
            if (item == w) {
                _ = self.windows.orderedRemove(i);
                break;
            }
        }
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    /// Runs the event loop until the app quits. With
    /// `--nanoui-generate=<dir>` it writes the client instead and returns.
    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.writeClient(dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        // Quit before the loop started: nothing to run.
        if (self.stopping) return;
        self.running = true;
        objc.msg(void, self.nsapp, "run", .{});
        self.running = false;
    }

    /// Stops the event loop; `run` returns once the current event is handled.
    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (!self.running) return;
        objc.msg(void, self.nsapp, "stop:", .{@as(?objc.Object, null)});
        // `stop:` takes effect after the next event: post one.
        const ev = objc.msg(objc.Object, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(objc.NSUInteger, 15), objc.CGPoint{}, @as(objc.NSUInteger, 0), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), @as(i16, 0), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
        });
        objc.msg(void, self.nsapp, "postEvent:atStart:", .{ ev, objc.YES });
    }

    /// The generated JavaScript client, served to pages at `/nanoui.js`.
    pub fn clientJs(self: *App) ![]const u8 {
        if (self.client_js) |js| return js;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_js);
        var it = self.services.valueIterator();
        while (it.next()) |svc| try aw.writer.writeAll(svc.client.js);
        for (self.events.items) |e| try aw.writer.writeAll(e.js);
        self.client_js = try aw.toOwnedSlice();
        return self.client_js.?;
    }

    /// The generated declarations of the client (`nanoui.d.ts`).
    pub fn clientDts(self: *App, gpa: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_dts);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        var parts: std.ArrayList(tsgen.Service) = .empty;
        defer parts.deinit(gpa);
        // Services sorted by name, so the output is stable.
        var it = self.services.valueIterator();
        while (it.next()) |svc| try parts.append(gpa, svc.client);
        std.mem.sort(tsgen.Service, parts.items, {}, struct {
            fn lt(_: void, x: tsgen.Service, y: tsgen.Service) bool {
                return std.mem.lessThan(u8, x.dts, y.dts);
            }
        }.lt);
        try parts.appendSlice(gpa, self.events.items);
        for (parts.items) |p| {
            for (p.decls) |d| {
                if ((try seen.getOrPut(gpa, d.name)).found_existing) continue;
                try aw.writer.print("\n{s}\n", .{d.source});
            }
        }
        for (parts.items) |p| try aw.writer.print("\n{s}", .{p.dts});
        return aw.toOwnedSlice();
    }

    fn writeClient(self: *App, dir_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, dir_path);
        var dir = try cwd.openDir(self.io, dir_path, .{});
        defer dir.close(self.io);
        const dts = try self.clientDts(self.gpa);
        defer self.gpa.free(dts);
        try dir.writeFile(self.io, .{ .sub_path = "nanoui.d.ts", .data = dts });
        try dir.writeFile(self.io, .{ .sub_path = "nanoui.js", .data = try self.clientJs() });
        std.log.info("nanoui: wrote {s}/nanoui.js and nanoui.d.ts", .{dir_path});
    }

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        objc.dispatchAfter(ms * std.time.ns_per_ms, ctx, func);
    }

    /// Replaces the menu bar with one built from `template`.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, self.options.name, template);
        objc.msg(void, self.nsapp, "setMainMenu:", .{m.ns});
        if (m.windows_menu) |w| objc.msg(void, self.nsapp, "setWindowsMenu:", .{w});
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    /// The menu bar's item whose template had `id`.
    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// Adds an icon to the menu bar's status area; it lives until removed
    /// with `Tray.destroy` or the app ends.
    pub fn newTray(self: *App, opts: tray_mod.Options) !*tray_mod.Tray {
        const t = try tray_mod.Tray.create(self.gpa, self.options.name, opts);
        errdefer t.destroy();
        try self.trays.append(self.gpa, t);
        return t;
    }

    /// The menu every app starts with: the app menu, Edit, View, Window.
    pub const default_menu = [_]menu_mod.MenuItem{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .role = .view_menu },
        .{ .role = .window_menu },
    };
};

fn didFinishLaunching(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (objc.getZig(App, self_obj)) |app| if (app.flags.hidden) return;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

fn shouldTerminate(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSUInteger {
    // AppKit would call exit(); stop the loop instead so `App.run` returns.
    if (objc.getZig(App, self_obj)) |app| app.quit();
    return 0; // NSTerminateCancel
}

fn shouldReopen(self_obj: objc.Object, _: objc.SEL, _: objc.Object, visible: objc.BOOL) callconv(.c) objc.BOOL {
    _ = self_obj;
    return !visible;
}
