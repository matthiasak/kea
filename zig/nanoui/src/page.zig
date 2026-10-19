//! The web page a window shows: a WKWebView with the bridge injected,
//! assets served from the `nanoui://` scheme, and the outbox of messages
//! batched into one evaluation per main-loop turn.
const std = @import("std");
const objc = @import("objc.zig");
const ipc = @import("ipc.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const bridge_js = @embedFile("bridge.js");

/// Events wait for dom-ready so listeners exist; bounded per page.
const max_held = 1024;

pub const Page = struct {
    window: *Window,
    gpa: std.mem.Allocator,
    options: window_mod.PageOptions,
    webview: objc.Object,
    handler: objc.Object,
    outbox: std.ArrayList(u8) = .empty,
    held: std.ArrayList([]u8) = .empty,
    dom_ready: bool = false,
    flush_scheduled: bool = false,
    dead: bool = false,
    last_mouse_down: ?objc.Object = null,

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        const gpa = window.app.gpa;
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);

        const handler_class = objc.defineClass(.{
            .name = "NanoUIPageHandler",
            .protocols = &.{ "WKScriptMessageHandler", "WKURLSchemeHandler" },
            .methods = &.{
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveScriptMessage, .types = "v@:@@" },
                .{ .name = "webView:startURLSchemeTask:", .imp = &startURLSchemeTask, .types = "v@:@@" },
                .{ .name = "webView:stopURLSchemeTask:", .imp = &stopURLSchemeTask, .types = "v@:@@" },
            },
        });
        const webview_class = objc.defineClass(.{
            .name = "NanoUIWebView",
            .superclass = "WKWebView",
            .methods = &.{
                .{ .name = "mouseDown:", .imp = &webViewMouseDown, .types = "v@:@" },
            },
        });

        const handler = objc.msg(objc.Object, handler_class, "new", .{});
        objc.setZig(handler, self);

        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);
        const ucc = objc.msg(objc.Object, config, "userContentController", .{});
        const script = objc.msg(objc.Object, objc.alloc("WKUserScript"), "initWithSource:injectionTime:forMainFrameOnly:", .{
            objc.nsString(bridge_js), @as(objc.NSInteger, 0), objc.YES,
        });
        defer objc.release(script);
        objc.msg(void, ucc, "addUserScript:", .{script});
        objc.msg(void, ucc, "addScriptMessageHandler:name:", .{ handler, objc.nsString("nanoui") });
        objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ handler, objc.nsString("nanoui") });
        if (options.inspectable) {
            const prefs = objc.msg(objc.Object, config, "preferences", .{});
            const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
            objc.msg(void, prefs, "setValue:forKey:", .{ yes, objc.nsString("developerExtrasEnabled") });
        }

        const content_view = objc.msg(objc.Object, window.nswindow, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content_view, "bounds", .{});
        const webview = objc.msg(objc.Object, objc.msg(objc.Object, webview_class, "alloc", .{}), "initWithFrame:configuration:", .{ bounds, config });
        objc.setZig(webview, self);
        objc.msg(void, webview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)}); // width | height sizable
        if (options.inspectable and objc.msg(objc.BOOL, webview, "respondsToSelector:", .{objc.sel("setInspectable:")}))
            objc.msg(void, webview, "setInspectable:", .{objc.YES});
        // The web view is not the content view: WebKit docks the inspector in its superview.
        objc.msg(void, content_view, "addSubview:", .{webview});

        self.* = .{ .window = window, .gpa = gpa, .options = options, .webview = webview, .handler = handler };
        self.load(options.url);
        return self;
    }

    pub fn destroy(self: *Page) void {
        const ucc = objc.msg(objc.Object, objc.msg(objc.Object, self.webview, "configuration", .{}), "userContentController", .{});
        objc.msg(void, ucc, "removeScriptMessageHandlerForName:", .{objc.nsString("nanoui")});
        objc.setZig(self.handler, null);
        objc.setZig(self.webview, null);
        objc.msg(void, self.webview, "removeFromSuperview", .{});
        objc.release(self.webview);
        objc.release(self.handler);
        if (self.last_mouse_down) |e| objc.release(e);
        const gpa = self.gpa;
        self.outbox.deinit(gpa);
        for (self.held.items) |m| gpa.free(m);
        self.held.deinit(gpa);
        // A scheduled flush frees the page when it runs.
        if (self.flush_scheduled) self.dead = true else gpa.destroy(self);
    }

    pub fn load(self: *Page, url: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        var buf: [2048]u8 = undefined;
        const full = if (std.mem.indexOf(u8, url, "://") != null)
            url
        else
            std.fmt.bufPrint(&buf, "nanoui://localhost{s}{s}", .{ if (url.len > 0 and url[0] == '/') "" else "/", url }) catch url;
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(full)}) orelse return;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        self.dom_ready = false;
        _ = objc.msg(?objc.Object, self.webview, "loadRequest:", .{req});
    }

    /// Queues a message for the page. Events (`hold`) wait for dom-ready.
    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        const gpa = self.gpa;
        if (hold and !self.dom_ready) {
            if (self.held.items.len >= max_held) return;
            const copy = gpa.dupe(u8, msg) catch return;
            self.held.append(gpa, copy) catch gpa.free(copy);
            return;
        }
        if (self.outbox.items.len > 0) self.outbox.append(gpa, ',') catch return;
        self.outbox.appendSlice(gpa, msg) catch return;
        if (!self.flush_scheduled) {
            self.flush_scheduled = true;
            objc.dispatchMain(self, flushJob);
        }
    }

    pub fn domReady(self: *Page) void {
        self.dom_ready = true;
        const gpa = self.gpa;
        for (self.held.items) |m| {
            self.enqueue(m, false);
            gpa.free(m);
        }
        self.held.clearRetainingCapacity();
        if (self.window.app.flags.eval) |js| {
            const pool = objc.Pool.push();
            defer pool.pop();
            objc.msg(void, self.webview, "evaluateJavaScript:completionHandler:", .{ objc.nsString(js), @as(?*anyopaque, null) });
        }
    }

    pub fn startDrag(self: *Page) void {
        const ev = self.last_mouse_down orelse return;
        objc.msg(void, self.window.nswindow, "performWindowDragWithEvent:", .{ev});
    }

    fn flush(self: *Page) void {
        self.flush_scheduled = false;
        if (self.outbox.items.len == 0) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const gpa = self.gpa;
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(gpa);
        script.appendSlice(gpa, "__nanoui.receive([") catch return;
        script.appendSlice(gpa, self.outbox.items) catch return;
        script.appendSlice(gpa, "])") catch return;
        self.outbox.clearRetainingCapacity();
        objc.msg(void, self.webview, "evaluateJavaScript:completionHandler:", .{ objc.nsString(script.items), @as(?*anyopaque, null) });
    }

    fn serve(self: *Page, task: objc.Object) void {
        const req = objc.msg(objc.Object, task, "request", .{});
        const url = objc.msg(objc.Object, req, "URL", .{});
        var path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
        if (path.len == 0 or std.mem.eql(u8, path, "/")) path = "/index.html";

        var data: ?[]const u8 = null;
        var mime: []const u8 = mimeType(path);
        if (std.mem.eql(u8, path, "/nanoui.js")) {
            data = self.window.app.clientJs() catch null;
        } else for (self.options.assets) |a| {
            if (std.mem.eql(u8, a.path, path)) {
                data = a.data;
                if (a.mime) |m| mime = m;
                break;
            }
        }
        const status: objc.NSInteger = if (data == null) 404 else 200;
        const body = data orelse "Not Found";
        if (data == null) mime = "text/plain";

        const keys = [_]objc.Object{ objc.nsString("Content-Type"), objc.nsString("Cache-Control") };
        const values = [_]objc.Object{ objc.nsString(mime), objc.nsString("no-cache") };
        const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
        const res = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{
            url, status, objc.nsString("HTTP/1.1"), headers,
        });
        defer objc.release(res);
        const nsdata = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, body.len });
        objc.msg(void, task, "didReceiveResponse:", .{res});
        objc.msg(void, task, "didReceiveData:", .{nsdata});
        objc.msg(void, task, "didFinish", .{});
    }
};

fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".woff2", "font/woff2" },
        .{ ".wasm", "application/wasm" },
    };
    inline for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}

fn flushJob(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    if (self.dead) {
        self.gpa.destroy(self);
        return;
    }
    self.flush();
}

fn didReceiveScriptMessage(self_obj: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const body = objc.msg(?objc.Object, message, "body", .{}) orelse return;
    if (!objc.msg(objc.BOOL, body, "isKindOfClass:", .{objc.class("NSString")})) return;
    ipc.handleMessage(page.window, objc.fromNSString(body));
}

fn startURLSchemeTask(self_obj: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    page.serve(task);
}

fn stopURLSchemeTask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {}

fn webViewMouseDown(self_obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.getZig(Page, self_obj)) |page| {
        if (page.last_mouse_down) |old| objc.release(old);
        page.last_mouse_down = objc.retain(event);
    }
    objc.msgSuper(void, self_obj, objc.class("WKWebView"), "mouseDown:", .{event});
}
