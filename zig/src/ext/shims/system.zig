//! fontSettings, management, i18n.detectLanguage, idle, power and system.*
//! (ExtensionShims.swift 3628-3660, 3943-3969, 4024-4044).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");

const Value = ans.Value;
const no_values = [_]Value{};

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (std.mem.startsWith(u8, api, "fontSettings.")) return fonts(c, api["fontSettings.".len..]);
    if (eql(api, "management.getSelf") or eql(api, "management.get")) return management(c);
    if (eql(api, "management.getAll") or eql(api, "system.storage.getInfo")) return .{ .value = .{ .array = .init(c.a) } };
    if (eql(api, "management.setEnabled") or eql(api, "management.uninstallSelf"))
        return c.fail("Extensions are turned on and off in Settings \u{203A} Extensions", .{});
    if (eql(api, "i18n.detectLanguage")) return detectLanguage(c);
    if (eql(api, "idle.queryState")) return .{ .value = .{ .string = idleState(ans.num(c.first()) orelse 60) } };
    if (eql(api, "idle.getAutoLockDelay")) return .{ .value = .{ .integer = 0 } };
    if (eql(api, "power.requestKeepAwake")) return keepAwake(c);
    if (eql(api, "power.releaseKeepAwake")) {
        ans.releaseAwake(c.owner, c.id);
        return ans.none;
    }
    if (eql(api, "power.reportActivity")) {
        var assertion: u32 = 0;
        // kIOPMUserActiveLocal; Swift keeps no hold on it either.
        _ = IOPMAssertionDeclareUserActivity(objc.nsString(assertion_name), 0, &assertion);
        return ans.none;
    }
    if (eql(api, "system.cpu.getInfo")) return cpu(c);
    if (eql(api, "system.memory.getInfo")) {
        const bytes: f64 = @floatFromInt(objc.msg(u64, processInfo(), "physicalMemory", .{}));
        return try c.give(.{ .capacity = bytes, .availableCapacity = bytes / 2 });
    }
    if (eql(api, "system.display.getInfo")) return displays(c);
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// MARK: fonts — what the Mac has; the page's own fonts stay the page's

fn fonts(c: *ans.Call, name: []const u8) ans.Error!?ans.Out {
    if (eql(name, "getFontList")) {
        const families = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSFontManager"), "sharedFontManager", .{}), "availableFontFamilies", .{});
        const Font = struct { fontId: []const u8, displayName: []const u8 };
        const n = objc.msg(objc.NSUInteger, families, "count", .{});
        const out = try c.a.alloc(Font, n);
        for (out, 0..) |*f, i| {
            const family = objc.fromNSString(objc.msg(objc.Object, families, "objectAtIndex:", .{i}));
            f.* = .{ .fontId = family, .displayName = family };
        }
        return try c.give(out);
    }
    if (eql(name, "getFont")) return try c.give(.{ .fontId = "", .levelOfControl = "not_controllable" });
    const sizes = .{ .{ "getDefaultFontSize", 16 }, .{ "getDefaultFixedFontSize", 13 }, .{ "getMinimumFontSize", 0 } };
    inline for (sizes) |s| if (eql(name, s[0])) return try c.give(.{ .pixelSize = @as(i64, s[1]), .levelOfControl = "not_controllable" });
    if (std.mem.startsWith(u8, name, "set") or std.mem.startsWith(u8, name, "clear")) return ans.none;
    return null;
}

// MARK: management — only itself

fn management(c: *ans.Call) ans.Error!?ans.Out {
    const found = c.webExtension();
    const from_folder = if (c.owner.row(c.id)) |r| !r.fromStore else false;
    return try c.give(.{
        .id = c.id,
        .name = text(found, "displayName"),
        .shortName = text(found, "displayShortName"),
        .version = text(found, "version"),
        .description = text(found, "displayDescription"),
        .enabled = true,
        .type = "extension",
        .installType = if (from_folder) "development" else "normal",
        .mayDisable = true,
        .offlineEnabled = true,
        .isApp = false,
        .hostPermissions = no_values,
        .permissions = no_values,
    });
}

fn text(obj: objc.Object, comptime key: [:0]const u8) []const u8 {
    return objc.fromNSString(objc.msg(?objc.Object, obj, key, .{}));
}

// MARK: language

fn detectLanguage(c: *ans.Call) ans.Error!?ans.Out {
    const recognizer = objc.new("NLLanguageRecognizer");
    defer objc.release(recognizer);
    objc.msg(void, recognizer, "processString:", .{objc.nsString(ans.str(c.first()) orelse "")});
    const guesses = objc.msg(objc.Object, recognizer, "languageHypothesesWithMaximum:", .{@as(objc.NSUInteger, 3)});
    const keys = objc.msg(objc.Object, guesses, "allKeys", .{});
    const Guess = struct { language: []const u8, p: f64 };
    const all = try c.a.alloc(Guess, objc.msg(objc.NSUInteger, keys, "count", .{}));
    var best: f64 = 0;
    for (all, 0..) |*g, i| {
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        g.* = .{ .language = objc.fromNSString(k), .p = objc.msg(f64, objc.msg(objc.Object, guesses, "objectForKey:", .{k}), "doubleValue", .{}) };
        best = @max(best, g.p);
    }
    std.mem.sort(Guess, all, {}, struct {
        fn gt(_: void, x: Guess, y: Guess) bool {
            return x.p > y.p;
        }
    }.gt);
    const Language = struct { language: []const u8, percentage: i64 };
    const languages = try c.a.alloc(Language, all.len);
    for (languages, all) |*l, g| l.* = .{ .language = g.language, .percentage = @intFromFloat(g.p * 100) };
    return try c.give(.{ .isReliable = best > 0.6, .languages = languages });
}

// MARK: idle

extern "c" fn CGSessionCopyCurrentDictionary() ?objc.Object;
extern "c" fn CGEventSourceSecondsSinceLastEventType(state: i32, event: u32) f64;
extern "c" fn CFRelease(cf: *anyopaque) void;

fn idleState(threshold: f64) []const u8 {
    if (CGSessionCopyCurrentDictionary()) |session| {
        defer CFRelease(session);
        const locked = objc.msg(?objc.Object, session, "objectForKey:", .{objc.nsString("CGSSessionScreenIsLocked")});
        if (locked) |l| if (objc.msg(objc.BOOL, l, "isKindOfClass:", .{objc.class("NSNumber")}) and objc.msg(objc.BOOL, l, "boolValue", .{})) return "locked";
    }
    // kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType.
    const quiet = CGEventSourceSecondsSinceLastEventType(0, ~@as(u32, 0));
    return if (quiet >= threshold) "idle" else "active";
}

// MARK: power

const assertion_name = "An extension in " ++ ans.app_name;

extern "c" fn IOPMAssertionCreateWithName(kind: objc.Object, level: u32, name: objc.Object, id: *u32) i32;
extern "c" fn IOPMAssertionRelease(id: u32) i32;
extern "c" fn IOPMAssertionDeclareUserActivity(name: objc.Object, kind: u32, id: *u32) i32;

/// An assertion let go: the Mac may sleep again.
pub fn release(id: u32) void {
    _ = IOPMAssertionRelease(id);
}

fn keepAwake(c: *ans.Call) ans.Error!?ans.Out {
    const display = eql(ans.str(c.first()) orelse "", "display");
    ans.releaseAwake(c.owner, c.id);
    const kind = if (display) "PreventUserIdleDisplaySleep" else "PreventUserIdleSystemSleep";
    var assertion: u32 = 0;
    // kIOPMAssertionLevelOn; kIOReturnSuccess.
    if (IOPMAssertionCreateWithName(objc.nsString(kind), 255, objc.nsString(assertion_name), &assertion) != 0) return ans.none;
    const key = try c.owner.gpa.dupe(u8, c.id);
    c.owner.answer.awake.put(c.owner.gpa, key, assertion) catch {
        c.owner.gpa.free(key);
        release(assertion);
        return error.OutOfMemory;
    };
    return ans.none;
}

// MARK: system

fn processInfo() objc.Object {
    return objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
}

fn cpu(c: *ans.Call) ans.Error!?ans.Out {
    const intel = builtin.cpu.arch == .x86_64;
    return try c.give(.{
        .numOfProcessors = objc.msg(objc.NSUInteger, processInfo(), "processorCount", .{}),
        .archName = if (intel) "x86_64" else "arm64",
        .modelName = if (intel) "Intel" else "Apple silicon",
        .features = no_values,
        .processors = no_values,
        .temperatures = no_values,
    });
}

const Box = struct { left: f64, top: f64, width: f64, height: f64 };

fn box(r: objc.CGRect) Box {
    return .{ .left = r.origin.x, .top = r.origin.y, .width = r.size.width, .height = r.size.height };
}

fn displays(c: *ans.Call) ans.Error!?ans.Out {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const Display = struct {
        id: []const u8,
        name: []const u8,
        isPrimary: bool,
        isInternal: bool,
        isEnabled: bool = true,
        dpiX: f64,
        dpiY: f64,
        rotation: i64 = 0,
        bounds: Box,
        workArea: Box,
    };
    const out = try c.a.alloc(Display, objc.msg(objc.NSUInteger, screens, "count", .{}));
    for (out, 0..) |*d, i| {
        const screen = objc.msg(objc.Object, screens, "objectAtIndex:", .{i});
        const dpi = 96 * objc.msg(objc.CGFloat, screen, "backingScaleFactor", .{});
        d.* = .{
            .id = try std.fmt.allocPrint(c.a, "{d}", .{i}),
            .name = text(screen, "localizedName"),
            .isPrimary = i == 0,
            .isInternal = i == 0,
            .dpiX = dpi,
            .dpiY = dpi,
            .bounds = box(objc.msg(objc.CGRect, screen, "frame", .{})),
            .workArea = box(objc.msg(objc.CGRect, screen, "visibleFrame", .{})),
        };
    }
    return try c.give(out);
}
