//! UIKit `UIApplicationDelegate` and `UIWindowSceneDelegate` callbacks for
//! `ios/app.zig`: scene attachment, foreground/background transitions, URL
//! contexts (Default Browser links), Handoff user activities, and termination.
const std = @import("std");
const objc = @import("../objc.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub fn defineClasses() objc.Class {
    _ = objc.defineClass(.{
        .name = "NanoUISceneDelegate",
        .superclass = "UIResponder",
        .protocols = &.{"UIWindowSceneDelegate"},
        .methods = &.{
            .{ .name = "scene:willConnectToSession:options:", .imp = &sceneConnect, .types = "v@:@@@" },
            .{ .name = "sceneDidBecomeActive:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "sceneWillEnterForeground:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "sceneDidEnterBackground:", .imp = &enteredBackground, .types = "v@:@" },
            .{ .name = "sceneDidDisconnect:", .imp = &sceneDisconnect, .types = "v@:@" },
            .{ .name = "scene:openURLContexts:", .imp = &sceneOpenURLContexts, .types = "v@:@@" },
            .{ .name = "scene:continueUserActivity:", .imp = &sceneContinueActivity, .types = "v@:@@" },
            .{ .name = "window", .imp = &windowGetter, .types = "@@:" },
            .{ .name = "setWindow:", .imp = &windowSetter, .types = "v@:@" },
        },
    });
    return objc.defineClass(.{
        .name = "NanoUIAppDelegate",
        .superclass = "UIResponder",
        .protocols = &.{"UIApplicationDelegate"},
        .methods = &.{
            .{ .name = "application:didFinishLaunchingWithOptions:", .imp = &didFinishLaunching, .types = "B@:@@" },
            .{ .name = "application:configurationForConnectingSceneSession:options:", .imp = &sceneConfiguration, .types = "@@:@@@" },
            .{ .name = "applicationDidBecomeActive:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "applicationWillEnterForeground:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "applicationDidEnterBackground:", .imp = &enteredBackground, .types = "v@:@" },
            .{ .name = "applicationWillTerminate:", .imp = &willTerminate, .types = "v@:@" },
            .{ .name = "application:openURL:options:", .imp = &appOpenURL, .types = "B@:@@@" },
            .{ .name = "application:continueUserActivity:restorationHandler:", .imp = &appContinueActivity, .types = "B@:@@@?" },
            .{ .name = "window", .imp = &windowGetter, .types = "@@:" },
            .{ .name = "setWindow:", .imp = &windowSetter, .types = "v@:@" },
        },
    });
}

fn usesScenes() bool {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, bundle, "objectForInfoDictionaryKey:", .{objc.nsString("UIApplicationSceneManifest")}) != null;
}

fn didFinishLaunching(_: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) objc.BOOL {
    const app = App.shared() orelse return objc.YES;
    if (usesScenes()) return objc.YES;
    const screen = objc.msg(objc.Object, objc.class("UIScreen"), "mainScreen", .{});
    const bounds = objc.msg(objc.CGRect, screen, "bounds", .{});
    const win = objc.msg(objc.Object, objc.alloc("UIWindow"), "initWithFrame:", .{bounds});
    defer objc.release(win);
    app.attach(win);
    return objc.YES;
}

fn sceneConfiguration(_: objc.Object, _: objc.SEL, _: objc.Object, session: objc.Object, _: objc.Object) callconv(.c) objc.Object {
    const role = objc.msg(objc.Object, session, "role", .{});
    const config = objc.msg(objc.Object, objc.class("UISceneConfiguration"), "configurationWithName:sessionRole:", .{ @as(?objc.Object, null), role });
    objc.msg(void, config, "setDelegateClass:", .{objc.class("NanoUISceneDelegate")});
    return config;
}

fn sceneConnect(_: objc.Object, _: objc.SEL, scene: objc.Object, _: objc.Object, conn_opts: objc.Object) callconv(.c) void {
    const app = App.shared() orelse return;
    if (app.uiwindow != null) return;
    if (objc.msg(objc.NSInteger, scene, "activationState", .{}) == 2) app.active = false;
    const win = objc.msg(objc.Object, objc.alloc("UIWindow"), "initWithWindowScene:", .{scene});
    defer objc.release(win);
    app.attach(win);
    if (objc.msg(?objc.Object, conn_opts, "URLContexts", .{})) |ctxs| deliverURLContexts(app, ctxs);
    if (objc.msg(?objc.Object, conn_opts, "userActivities", .{})) |acts| {
        const all = objc.msg(objc.Object, acts, "allObjects", .{});
        const n = objc.msg(objc.NSUInteger, all, "count", .{});
        var i: objc.NSUInteger = 0;
        while (i < n) : (i += 1) deliverActivity(app, objc.msg(objc.Object, all, "objectAtIndex:", .{i}));
    }
}

fn sceneDisconnect(_: objc.Object, _: objc.SEL, scene: objc.Object) callconv(.c) void {
    const app = App.shared() orelse return;
    const win = app.uiwindow orelse return;
    if (objc.msg(?objc.Object, win, "windowScene", .{}) == scene) app.detach();
}

fn sceneOpenURLContexts(_: objc.Object, _: objc.SEL, _: objc.Object, contexts: objc.Object) callconv(.c) void {
    if (App.shared()) |app| deliverURLContexts(app, contexts);
}

fn appOpenURL(_: objc.Object, _: objc.SEL, _: objc.Object, url: objc.Object, _: ?objc.Object) callconv(.c) objc.BOOL {
    const app = App.shared() orelse return objc.NO;
    const hook = app.options.on_open_urls orelse return objc.NO;
    const s = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    if (s.len == 0) return objc.NO;
    const one = [_][]const u8{s};
    hook(app.options.ctx, &one);
    return objc.YES;
}

fn deliverURLContexts(app: *App, contexts: objc.Object) void {
    const hook = app.options.on_open_urls orelse return;
    const all = objc.msg(objc.Object, contexts, "allObjects", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    if (n == 0) return;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(app.gpa);
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const ctx = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        const u = objc.msg(?objc.Object, ctx, "URL", .{}) orelse continue;
        const s = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
        if (s.len > 0) list.append(app.gpa, s) catch {};
    }
    if (list.items.len > 0) hook(app.options.ctx, list.items);
}

fn sceneContinueActivity(_: objc.Object, _: objc.SEL, _: objc.Object, activity: objc.Object) callconv(.c) void {
    if (App.shared()) |app| deliverActivity(app, activity);
}

fn appContinueActivity(_: objc.Object, _: objc.SEL, _: objc.Object, activity: objc.Object, _: ?*anyopaque) callconv(.c) objc.BOOL {
    const app = App.shared() orelse return objc.NO;
    return if (deliverActivityBool(app, activity)) objc.YES else objc.NO;
}

fn deliverActivity(app: *App, activity: objc.Object) void {
    _ = deliverActivityBool(app, activity);
}

fn deliverActivityBool(app: *App, activity: objc.Object) bool {
    const hook = app.options.on_continue_activity orelse return false;
    const u = objc.msg(?objc.Object, activity, "webpageURL", .{}) orelse return false;
    const s = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    if (s.len == 0) return false;
    hook(app.options.ctx, s);
    return true;
}

fn becameActive(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (App.shared()) |app| app.setActive(true);
}

fn enteredBackground(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (App.shared()) |app| app.setActive(false);
}

fn willTerminate(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (App.shared()) |app| if (app.options.on_terminate) |f| f(app.options.ctx);
}

fn windowGetter(_: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const app = App.shared() orelse return null;
    return app.uiwindow;
}

fn windowSetter(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {}
