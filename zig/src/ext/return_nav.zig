//! `ExtensionReturnNavigation` (ExtensionReturnNavigation.swift): the
//! source of an extension return can't be read from the view's URL — during
//! a server redirect it already holds the destination. Native navigation
//! provenance is kept per tab (`Tab.ext_return`) for a redirect from a
//! still-blank tab.
const std = @import("std");
const objc = @import("nanoui").objc;

pub const ReturnNavigation = struct {
    /// The provisional navigation (retained), its server origin and the
    /// extension address a blank tab is heading for; strings on the tab's gpa.
    navigation: ?objc.Object = null,
    server_origin: ?[]u8 = null,
    candidate: ?[]u8 = null,
    revision: u64 = 0,

    pub fn deinit(self: *ReturnNavigation, gpa: std.mem.Allocator) void {
        self.setNavigation(null);
        set(gpa, &self.server_origin, null);
        set(gpa, &self.candidate, null);
    }

    /// The document's native HTTPS origin for ordinary navigations, on
    /// `gpa`. An opaque blank document needs a later server-redirect callback.
    pub fn source(self: *ReturnNavigation, gpa: std.mem.Allocator, action: objc.Object) ?[]u8 {
        const target_frame = objc.msg(?objc.Object, action, "targetFrame", .{}) orelse return null;
        if (!objc.msg(objc.BOOL, target_frame, "isMainFrame", .{})) return null;
        self.revision +%= 1;
        set(gpa, &self.candidate, null);
        const frame = objc.msg(objc.Object, action, "sourceFrame", .{});
        const request = objc.msg(objc.Object, action, "request", .{});
        const method = objc.fromNSString(objc.msg(?objc.Object, request, "HTTPMethod", .{}));
        if (!objc.msg(objc.BOOL, frame, "isMainFrame", .{}) or !(method.len == 0 or std.mem.eql(u8, method, "GET")) or
            objc.msg(?objc.Object, request, "HTTPBody", .{}) != null or objc.msg(?objc.Object, request, "HTTPBodyStream", .{}) != null) return null;

        const origin = objc.msg(objc.Object, frame, "securityOrigin", .{});
        const protocol = objc.fromNSString(objc.msg(?objc.Object, origin, "protocol", .{}));
        const host = objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{}));
        if (std.ascii.eqlIgnoreCase(protocol, "https") and host.len > 0) {
            const port = objc.msg(objc.NSInteger, origin, "port", .{});
            return originText(gpa, host, if (port > 0) port else null) catch null;
        }

        const document = objc.msg(?objc.Object, objc.msg(objc.Object, frame, "request", .{}), "URL", .{});
        const blank = if (document) |d| std.mem.eql(u8, absolute(d), "about:blank") else true;
        if (protocol.len == 0 and host.len == 0 and blank) if (objc.msg(?objc.Object, request, "URL", .{})) |target| {
            const scheme = objc.fromNSString(objc.msg(?objc.Object, target, "scheme", .{}));
            if (std.ascii.eqlIgnoreCase(scheme, "chrome-extension") or std.ascii.eqlIgnoreCase(scheme, "webkit-extension"))
                set(gpa, &self.candidate, absolute(target));
        };
        return null;
    }

    pub fn started(self: *ReturnNavigation, gpa: std.mem.Allocator, navigation: objc.Object, url: ?objc.Object) void {
        self.setNavigation(navigation);
        self.setServerOrigin(gpa, url);
        set(gpa, &self.candidate, null);
    }

    pub const Redirect = struct {
        target: []u8,
        source: []u8,
        pub fn deinit(r: Redirect, gpa: std.mem.Allocator) void {
            gpa.free(r.target);
            gpa.free(r.source);
        }
    };

    /// Called only by WebKit's main-frame server-redirect delegate, for the
    /// same provisional navigation. Never infer a redirect from an error,
    /// a Referer header, the address bar, or a previously visited page.
    pub fn redirected(self: *ReturnNavigation, gpa: std.mem.Allocator, navigation: objc.Object, url: ?objc.Object) ?Redirect {
        if (self.navigation != navigation) return null;
        const src = self.server_origin;
        self.server_origin = null;
        self.setServerOrigin(gpa, url);
        const candidate = self.candidate;
        self.candidate = null;
        const ok = url != null and candidate != null and src != null and std.mem.eql(u8, candidate.?, absolute(url.?));
        if (!ok) {
            if (src) |s| gpa.free(s);
            if (candidate) |c| gpa.free(c);
            return null;
        }
        return .{ .target = candidate.?, .source = src.? };
    }

    pub fn finished(self: *ReturnNavigation, gpa: std.mem.Allocator, navigation: ?objc.Object) void {
        if (self.navigation != navigation) return;
        self.setNavigation(null);
        set(gpa, &self.server_origin, null);
        set(gpa, &self.candidate, null);
    }

    fn setNavigation(self: *ReturnNavigation, navigation: ?objc.Object) void {
        if (navigation) |n| _ = objc.retain(n);
        if (self.navigation) |old| objc.release(old);
        self.navigation = navigation;
    }

    fn setServerOrigin(self: *ReturnNavigation, gpa: std.mem.Allocator, url: ?objc.Object) void {
        set(gpa, &self.server_origin, null);
        self.server_origin = httpsOrigin(gpa, url);
    }
};

fn set(gpa: std.mem.Allocator, field: *?[]u8, s: ?[]const u8) void {
    const copy = if (s) |v| gpa.dupe(u8, v) catch null else null;
    if (field.*) |old| gpa.free(old);
    field.* = copy;
}

fn absolute(url: objc.Object) []const u8 {
    return objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
}

/// https://host[:port]/
fn originText(gpa: std.mem.Allocator, host: []const u8, port: ?objc.NSInteger) ![]u8 {
    if (port) |p| return std.fmt.allocPrint(gpa, "https://{s}:{d}/", .{ host, p });
    return std.fmt.allocPrint(gpa, "https://{s}/", .{host});
}

fn httpsOrigin(gpa: std.mem.Allocator, url: ?objc.Object) ?[]u8 {
    const u = url orelse return null;
    if (!std.ascii.eqlIgnoreCase(objc.fromNSString(objc.msg(?objc.Object, u, "scheme", .{})), "https")) return null;
    const host = objc.fromNSString(objc.msg(?objc.Object, u, "host", .{}));
    if (host.len == 0 or objc.msg(?objc.Object, u, "user", .{}) != null or objc.msg(?objc.Object, u, "password", .{}) != null) return null;
    const port: ?objc.NSInteger = if (objc.msg(?objc.Object, u, "port", .{})) |p| objc.msg(objc.NSInteger, p, "integerValue", .{}) else null;
    return originText(gpa, host, port) catch null;
}
