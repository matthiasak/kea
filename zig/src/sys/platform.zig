//! Compile-time macOS (AppKit) vs iOS/iPadOS (UIKit) platform seam for Kea.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

pub const is_ios = builtin.os.tag == .ios;
pub const is_macos = builtin.os.tag == .macos;

extern "c" fn NSHomeDirectory() objc.Object;

/// Native window handle (`NSWindow *` on macOS, `UIWindow *` on iOS when realized).
pub fn nativeWindow(w: ?*nanoui.Window) ?objc.Object {
    const win = w orelse return null;
    return if (comptime is_ios) win.app.uiwindow else win.nswindow;
}

/// Native surface view (`NSView *` on macOS, `UIView *` on iOS).
pub fn nativeView(s: ?*nanoui.Surface) ?objc.Object {
    const surf = s orelse return null;
    return if (comptime is_ios) surf.uiview else surf.nsview;
}

/// Native application singleton (`NSApplication *` on macOS, `UIApplication *` on iOS).
pub fn nativeApp(a: ?*nanoui.App) ?objc.Object {
    if (comptime is_ios) {
        if (a == null) return null;
        return objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
    }
    return if (a) |app| app.nsapp else null;
}

/// Topmost `UIViewController` on iOS for presenting alerts, sheets, and popovers.
pub fn topViewController() ?objc.Object {
    if (comptime !is_ios) return null;
    const app = nanoui.App.shared() orelse return null;
    return app.topController();
}

pub fn homeDir() []const u8 {
    return objc.fromNSString(NSHomeDirectory());
}

pub fn readPasteboardString() []const u8 {
    if (comptime is_ios) {
        const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
        return objc.fromNSString(objc.msg(?objc.Object, pb, "string", .{}));
    }
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    return objc.fromNSString(objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}));
}

pub fn writePasteboardString(text: []const u8) void {
    if (comptime is_ios) {
        const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
        objc.msg(void, pb, "setString:", .{objc.nsString(text)});
        return;
    }
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(text), objc.nsString("public.utf8-plain-text") });
}

pub fn readPasteboardImagePng() ?objc.Object {
    if (comptime is_ios) {
        const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
        const img = objc.msg(?objc.Object, pb, "image", .{}) orelse return null;
        return pngDataOfImage(img);
    }
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    for ([_][]const u8{ "public.png", "public.tiff", "public.jpeg" }) |uti| {
        if (objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString(uti)})) |d| return d;
    }
    return null;
}

pub fn openExternalURL(nsurl: objc.Object) bool {
    if (comptime is_ios) {
        const app = objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
        const opts = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
        objc.msg(void, app, "openURL:options:completionHandler:", .{ nsurl, opts, @as(?*anyopaque, null) });
        return true;
    }
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, ws, "openURL:", .{nsurl});
}

pub fn canOpenExternalURL(nsurl: objc.Object) bool {
    if (comptime is_ios) {
        const app = objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
        return objc.msg(objc.BOOL, app, "canOpenURL:", .{nsurl});
    }
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(?objc.Object, ws, "URLForApplicationToOpenURL:", .{nsurl}) != null;
}

pub fn isSystemDark() bool {
    if (comptime is_ios) {
        const traits = objc.msg(objc.Object, objc.class("UITraitCollection"), "currentTraitCollection", .{});
        return objc.msg(objc.NSInteger, traits, "userInterfaceStyle", .{}) == 2;
    }
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const look = objc.msg(?objc.Object, app, "effectiveAppearance", .{}) orelse return false;
    const name = objc.fromNSString(objc.msg(?objc.Object, look, "name", .{}));
    return std.mem.indexOf(u8, name, "Dark") != null;
}

pub fn deviceName(gpa: std.mem.Allocator) ?[]u8 {
    if (comptime is_ios) {
        const dev = objc.msg(objc.Object, objc.class("UIDevice"), "currentDevice", .{});
        const s = objc.fromNSString(objc.msg(?objc.Object, dev, "name", .{}));
        return if (s.len > 0) gpa.dupe(u8, s) catch null else null;
    }
    const M = struct {
        extern "c" fn SCDynamicStoreCopyComputerName(store: ?*anyopaque, encoding: ?*u32) ?objc.Object;
        extern "c" fn CFRelease(cf: *const anyopaque) void;
    };
    const cf = M.SCDynamicStoreCopyComputerName(null, null) orelse return null;
    defer M.CFRelease(cf);
    const s = objc.fromNSString(cf);
    return if (s.len > 0) gpa.dupe(u8, s) catch null else null;
}

pub fn isOnPower() bool {
    if (comptime is_ios) {
        const dev = objc.msg(objc.Object, objc.class("UIDevice"), "currentDevice", .{});
        objc.msg(void, dev, "setBatteryMonitoringEnabled:", .{objc.YES});
        const st = objc.msg(objc.NSInteger, dev, "batteryState", .{});
        // UIDeviceBatteryStateCharging = 2, Full = 3, Unknown = 0 (Simulator)
        return st == 0 or st == 2 or st == 3;
    }
    const M = struct {
        extern "c" fn IOPSCopyPowerSourcesInfo() ?*const anyopaque;
        extern "c" fn IOPSGetProvidingPowerSourceType(snapshot: ?*const anyopaque) ?objc.Object;
        extern "c" fn CFRelease(cf: *const anyopaque) void;
    };
    const blob = M.IOPSCopyPowerSourcesInfo() orelse return true;
    defer M.CFRelease(blob);
    const kind = M.IOPSGetProvidingPowerSourceType(blob) orelse return true;
    return std.mem.eql(u8, objc.fromNSString(kind), "AC Power");
}

/// Physical footprint in MiB (`proc_pid_rusage` on macOS, Mach `task_info` for own process on iOS).
pub fn processFootprintMb(pid: c_int) ?f64 {
    if (pid <= 0) return null;
    if (comptime is_ios) {
        if (pid != std.c.getpid()) return null;
        const M = struct {
            const TASK_VM_INFO: c_int = 22;
            const TaskVmInfo = extern struct {
                virtual_size: u64 = 0,
                region_count: i32 = 0,
                page_size: i32 = 0,
                resident_size: u64 = 0,
                resident_size_peak: u64 = 0,
                device: u64 = 0,
                device_peak: u64 = 0,
                internal: u64 = 0,
                internal_peak: u64 = 0,
                external: u64 = 0,
                external_peak: u64 = 0,
                reusable: u64 = 0,
                reusable_peak: u64 = 0,
                purgeable_volatile_pmap: u64 = 0,
                purgeable_volatile_resident: u64 = 0,
                purgeable_volatile_virtual: u64 = 0,
                compressed: u64 = 0,
                compressed_peak: u64 = 0,
                compressed_lifetime: u64 = 0,
                phys_footprint: u64 = 0,
                pad: [32]u64 = @splat(0),
            };
            extern "c" var mach_task_self_: c_uint;
            extern "c" fn task_info(target_task: c_uint, flavor: c_int, task_info_out: *anyopaque, task_info_outCnt: *c_uint) c_int;
        };
        var info: M.TaskVmInfo = .{};
        var count: c_uint = @sizeOf(M.TaskVmInfo) / @sizeOf(u32);
        if (M.task_info(M.mach_task_self_, M.TASK_VM_INFO, &info, &count) != 0) return null;
        return @as(f64, @floatFromInt(info.phys_footprint)) / (1024.0 * 1024.0);
    }
    const M = struct {
        const RUSAGE_INFO_V4: c_int = 4;
        const RusageInfoV4 = extern struct {
            ri_uuid: [16]u8 = @splat(0),
            ri_user_time: u64 = 0,
            ri_system_time: u64 = 0,
            ri_pkg_idle_wkups: u64 = 0,
            ri_interrupt_wkups: u64 = 0,
            ri_pageins: u64 = 0,
            ri_wired_size: u64 = 0,
            ri_resident_size: u64 = 0,
            ri_phys_footprint: u64 = 0,
            rest: [27]u64 = @splat(0),
        };
        extern "c" fn proc_pid_rusage(p: c_int, flavor: c_int, buffer: *anyopaque) c_int;
    };
    var info: M.RusageInfoV4 = .{};
    if (M.proc_pid_rusage(pid, M.RUSAGE_INFO_V4, &info) != 0) return null;
    return @as(f64, @floatFromInt(info.ri_phys_footprint)) / (1024.0 * 1024.0);
}

/// Borrowed `CGImageRef` from `UIImage *` (iOS) or `NSImage *` (macOS).
pub fn cgImageOf(image: objc.Object) ?*anyopaque {
    if (comptime is_ios) return objc.msg(?*anyopaque, image, "CGImage", .{});
    return objc.msg(?*anyopaque, image, "CGImageForProposedRect:context:hints:", .{
        @as(?*objc.CGRect, null), @as(?objc.Object, null), @as(?objc.Object, null),
    });
}

/// Encodes `UIImage *` (iOS) or `NSImage *` (macOS) as PNG `NSData *`.
pub fn pngDataOfImage(image: objc.Object) ?objc.Object {
    if (comptime is_ios) {
        const M = struct {
            extern "c" fn UIImagePNGRepresentation(img: objc.Object) ?objc.Object;
        };
        return M.UIImagePNGRepresentation(image);
    }
    const tiff = objc.msg(?objc.Object, image, "TIFFRepresentation", .{}) orelse return null;
    const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{tiff}) orelse return null;
    return objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{
        @as(objc.NSUInteger, 4), // NSPNGFileType
        objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}),
    });
}

test "platform homeDir is non-empty" {
    try std.testing.expect(homeDir().len > 0);
}
