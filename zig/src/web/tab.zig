//! WebKit Tab (`WKWebView` + `KeaZigWebDelegate`): navigation, crash-loop
//! protection (max 3 auto-reloads in 20 s), per-pane JS `alert`/`confirm`/`prompt`
//! dialog cards, OpenSearch `<link rel="search">` discovery, and JS evaluation.
//! Headless tabs (`Kea.Options.headless`) never build a webview: `web` is null.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Options = @import("../app/kea.zig").Options;

pub const DialogKind = enum { alert, confirm, prompt };

pub const DialogQuestion = struct {
    kind: DialogKind = .alert,
    message: [256]u8 = undefined,
    msg_len: usize = 0,
    default_text: [256]u8 = undefined,
    def_len: usize = 0,
    input_buf: ui.TextBuffer = .{},
    completion: ?objc.Object = null,

    pub fn text(self: *const DialogQuestion) []const u8 {
        return self.message[0..self.msg_len];
    }
};

const opensearch_js =
    \\(function() {
    \\  function check() {
    \\    var el = document.querySelector('link[rel="search"][type="application/opensearchdescription+xml"][href]');
    \\    if (el && el.href && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.keaZig) {
    \\      window.webkit.messageHandlers.keaZig.postMessage({ kind: "opensearch", href: el.href, title: el.title || document.title || location.hostname, host: location.hostname });
    \\    }
    \\  }
    \\  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", check, { once: true });
    \\  else check();
    \\})();
;

pub const Tab = struct {
    gpa: std.mem.Allocator,
    id: u64,
    browser_ctx: ?*anyopaque = null,
    on_change: ?*const fn (ctx: ?*anyopaque, tab: *Tab) void = null,
    on_new_tab: ?*const fn (ctx: ?*anyopaque, url: []const u8) void = null,
    on_opensearch: ?*const fn (ctx: ?*anyopaque, host: []const u8, title: []const u8, href: []const u8) void = null,

    web: ?objc.Object = null,
    delegate: ?objc.Object = null,

    url_buf: [2048]u8 = undefined,
    url_len: usize = 0,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    failure_buf: [256]u8 = undefined,
    failure_len: usize = 0,

    loading: bool = false,
    stopped: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    pinned: bool = false,
    muted: bool = false,
    shy: bool = false,
    progress: f32 = 0,

    /// Crash-loop protection: timestamps of recent WebContent terminations.
    crash_times: [3]f64 = @splat(0),
    crash_count: usize = 0,

    question: ?DialogQuestion = null,

    pub fn create(gpa: std.mem.Allocator, id: u64, initial_url: []const u8, shy: bool, opts: *const Options) !*Tab {
        const self = try gpa.create(Tab);
        self.* = .{ .gpa = gpa, .id = id, .shy = shy };
        if (!opts.headless) self.buildWeb(opts);
        self.setTitle("New Tab");
        if (initial_url.len > 0) self.load(initial_url);
        return self;
    }

    fn buildWeb(self: *Tab, opts: *const Options) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const del_class = objc.defineClass(.{
            .name = "KeaZigWebDelegate",
            .protocols = &.{ "WKNavigationDelegate", "WKUIDelegate", "WKScriptMessageHandler" },
            .methods = &.{
                .{ .name = "webView:didStartProvisionalNavigation:", .imp = &didStartNav, .types = "v@:@@" },
                .{ .name = "webView:didCommitNavigation:", .imp = &didCommitNav, .types = "v@:@@" },
                .{ .name = "webView:didFinishNavigation:", .imp = &didFinishNav, .types = "v@:@@" },
                .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFailNav, .types = "v@:@@@" },
                .{ .name = "webView:didFailNavigation:withError:", .imp = &didFailNav, .types = "v@:@@@" },
                .{ .name = "webViewWebContentProcessDidTerminate:", .imp = &didTerminate, .types = "v@:@" },
                .{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &createWebView, .types = "@@:@@@@" },
                .{ .name = "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:", .imp = &runAlert, .types = "v@:@@@?" },
                .{ .name = "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:", .imp = &runConfirm, .types = "v@:@@@?" },
                .{ .name = "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:", .imp = &runPrompt, .types = "v@:@@@@?" },
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveMessage, .types = "v@:@@" },
            },
        });

        const delegate = objc.msg(objc.Object, del_class, "new", .{});
        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);
        // Private tabs, and every tab under tests, keep nothing on disk.
        if (shyOrTest(self.shy, opts)) {
            const store = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "nonPersistentDataStore", .{});
            objc.msg(void, config, "setWebsiteDataStore:", .{store});
        }
        if (opts.scheme_handler) |h| objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ h, objc.nsString("kea-test") });
        const ucc = objc.msg(objc.Object, config, "userContentController", .{});
        const script = objc.msg(objc.Object, objc.alloc("WKUserScript"), "initWithSource:injectionTime:forMainFrameOnly:", .{
            objc.nsString(opensearch_js), @as(objc.NSInteger, 1), objc.YES,
        });
        defer objc.release(script);
        objc.msg(void, ucc, "addUserScript:", .{script});
        objc.msg(void, ucc, "addScriptMessageHandler:name:", .{ delegate, objc.nsString("keaZig") });

        const prefs = objc.msg(objc.Object, config, "preferences", .{});
        const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
        objc.msg(void, prefs, "setValue:forKey:", .{ yes, objc.nsString("developerExtrasEnabled") });

        const rect: objc.CGRect = .{ .size = .{ .width = 800, .height = 600 } };
        const webview = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ rect, config });
        objc.msg(void, webview, "setNavigationDelegate:", .{delegate});
        objc.msg(void, webview, "setUIDelegate:", .{delegate});
        if (objc.msg(objc.BOOL, webview, "respondsToSelector:", .{objc.sel("setInspectable:")}))
            objc.msg(void, webview, "setInspectable:", .{objc.YES});

        self.web = webview;
        self.delegate = delegate;
        objc.setZig(delegate, self);
    }

    fn shyOrTest(shy: bool, opts: *const Options) bool {
        return shy or opts.root != null;
    }

    pub fn destroy(self: *Tab) void {
        if (self.question) |_| self.answerDialog(false, null);
        if (self.web) |wv| {
            const ucc = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "userContentController", .{});
            objc.msg(void, ucc, "removeScriptMessageHandlerForName:", .{objc.nsString("keaZig")});
            objc.msg(void, wv, "setNavigationDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, wv, "setUIDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, wv, "removeFromSuperview", .{});
            objc.release(wv);
        }
        if (self.delegate) |d| {
            objc.setZig(d, null);
            objc.release(d);
        }
        self.gpa.destroy(self);
    }

    pub fn url(self: *const Tab) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn title(self: *const Tab) []const u8 {
        if (self.title_len > 0) return self.title_buf[0..self.title_len];
        if (self.url_len > 0) return self.url_buf[0..self.url_len];
        return "New Tab";
    }

    pub fn failure(self: *const Tab) ?[]const u8 {
        if (self.failure_len == 0) return null;
        return self.failure_buf[0..self.failure_len];
    }

    pub fn setUrl(self: *Tab, s: []const u8) void {
        self.url_len = @min(s.len, self.url_buf.len);
        @memcpy(self.url_buf[0..self.url_len], s[0..self.url_len]);
    }

    pub fn setTitle(self: *Tab, s: []const u8) void {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (trimmed.len == 0) return;
        self.title_len = @min(trimmed.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], trimmed[0..self.title_len]);
    }

    pub fn setFailure(self: *Tab, s: ?[]const u8) void {
        const msg = s orelse {
            self.failure_len = 0;
            return;
        };
        self.failure_len = @min(msg.len, self.failure_buf.len);
        @memcpy(self.failure_buf[0..self.failure_len], msg[0..self.failure_len]);
    }

    pub fn load(self: *Tab, target: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.setFailure(null);
        self.stopped = false;
        self.setUrl(target);
        if (target.len == 0 or std.mem.eql(u8, target, "about:blank")) {
            self.loading = false;
            self.setTitle("New Tab");
            self.notify();
            return;
        }
        const wv = self.web orelse {
            self.notify();
            return;
        };
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(target)}) orelse return;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        self.loading = true;
        self.progress = 0.15;
        _ = objc.msg(?objc.Object, wv, "loadRequest:", .{req});
        self.notify();
    }

    pub fn reload(self: *Tab) void {
        self.setFailure(null);
        self.stopped = false;
        const wv = self.web orelse return;
        if (self.url().len > 0 and objc.msg(?objc.Object, wv, "URL", .{}) == null) {
            self.load(self.url());
            return;
        }
        _ = objc.msg(?objc.Object, wv, "reload", .{});
        self.syncState();
    }

    /// Stops loading (`⌘.` / Esc): matches Kea's `stopLoading()`.
    pub fn stopLoading(self: *Tab) void {
        if (self.web) |wv| objc.msg(void, wv, "stopLoading", .{});
        self.stopped = true;
        self.loading = false;
        self.progress = 0;
        self.notify();
    }

    pub fn goBack(self: *Tab) void {
        const wv = self.web orelse return;
        if (objc.msg(objc.BOOL, wv, "canGoBack", .{})) {
            _ = objc.msg(?objc.Object, wv, "goBack", .{});
            self.syncState();
        }
    }

    pub fn goForward(self: *Tab) void {
        const wv = self.web orelse return;
        if (objc.msg(objc.BOOL, wv, "canGoForward", .{})) {
            _ = objc.msg(?objc.Object, wv, "goForward", .{});
            self.syncState();
        }
    }

    pub fn syncState(self: *Tab) void {
        const wv = self.web orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        self.loading = if (self.stopped) false else objc.msg(objc.BOOL, wv, "isLoading", .{});
        self.can_go_back = objc.msg(objc.BOOL, wv, "canGoBack", .{});
        self.can_go_forward = objc.msg(objc.BOOL, wv, "canGoForward", .{});
        self.progress = @floatCast(objc.msg(f64, wv, "estimatedProgress", .{}));
        if (objc.msg(?objc.Object, wv, "URL", .{})) |u| {
            const abs = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
            if (abs.len > 0 and !std.mem.eql(u8, abs, "about:blank")) self.setUrl(abs);
        }
        if (objc.msg(?objc.Object, wv, "title", .{})) |t| {
            const ts = objc.fromNSString(t);
            if (ts.len > 0) self.setTitle(ts);
        }
        self.notify();
    }

    pub fn recoverFromCrash(self: *Tab, now_s: f64) void {
        var recent: usize = 0;
        for (self.crash_times[0..self.crash_count]) |t| {
            if (now_s - t < 20.0) {
                self.crash_times[recent] = t;
                recent += 1;
            }
        }
        self.crash_count = recent;
        if (self.crash_count >= 3) {
            self.loading = false;
            self.setFailure("This page kept crashing and was stopped so it doesn't loop.");
            self.notify();
            return;
        }
        self.crash_times[self.crash_count] = now_s;
        self.crash_count += 1;
        self.reload();
    }

    pub fn answerDialog(self: *Tab, ok: bool, text_override: ?[]const u8) void {
        var q = self.question orelse return;
        self.question = null;
        if (q.completion) |blk| {
            const InvokeAlert = *const fn (*anyopaque) callconv(.c) void;
            const InvokeConfirm = *const fn (*anyopaque, objc.BOOL) callconv(.c) void;
            const InvokePrompt = *const fn (*anyopaque, ?objc.Object) callconv(.c) void;
            const raw: [*]const *const anyopaque = @ptrCast(@alignCast(blk));
            const invoke_ptr = raw[2];
            switch (q.kind) {
                .alert => @as(InvokeAlert, @ptrCast(@alignCast(invoke_ptr)))(blk),
                .confirm => @as(InvokeConfirm, @ptrCast(@alignCast(invoke_ptr)))(blk, if (ok) objc.YES else objc.NO),
                .prompt => {
                    const ans = if (!ok) null else objc.nsString(text_override orelse q.input_buf.text());
                    @as(InvokePrompt, @ptrCast(@alignCast(invoke_ptr)))(blk, ans);
                },
            }
            _Block_release(blk);
        }
        self.notify();
    }

    fn notify(self: *Tab) void {
        if (self.on_change) |cb| cb(self.browser_ctx, self);
    }
};

extern "c" fn _Block_copy(block: ?*const anyopaque) ?objc.Object;
extern "c" fn _Block_release(block: ?objc.Object) void;

fn tabOf(obj: objc.Object) ?*Tab {
    return objc.getZig(Tab, obj);
}

fn didStartNav(obj: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    t.stopped = false;
    t.setFailure(null);
    t.syncState();
}

fn didCommitNav(obj: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    t.syncState();
}

fn didFinishNav(obj: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    t.loading = false;
    t.progress = 1.0;
    t.syncState();
}

fn didFailNav(obj: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    t.loading = false;
    const code = objc.msg(objc.NSInteger, err, "code", .{});
    // NSURLErrorCancelled (-999) is a stopped load or redirect, not an error card.
    if (code == -999 or code == 102) {
        t.syncState();
        return;
    }
    const desc = objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{}));
    t.setFailure(if (desc.len > 0) desc else "Can't open this page.");
    t.syncState();
}

fn didTerminate(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    t.recoverFromCrash(ui.clock.now());
}

fn createWebView(obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, action: objc.Object, _: objc.Object) callconv(.c) ?objc.Object {
    const t = tabOf(obj) orelse return null;
    const req = objc.msg(?objc.Object, action, "request", .{}) orelse return null;
    const u = objc.msg(?objc.Object, req, "URL", .{}) orelse return null;
    const s = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    if (s.len > 0) if (t.on_new_tab) |cb| cb(t.browser_ctx, s);
    return null;
}

fn setupQuestion(t: *Tab, kind: DialogKind, message: ?objc.Object, def_text: ?objc.Object, completion: ?*const anyopaque) void {
    if (t.question) |_| t.answerDialog(false, null);
    var q: DialogQuestion = .{ .kind = kind, .completion = _Block_copy(completion) };
    const m = objc.fromNSString(message);
    q.msg_len = @min(m.len, q.message.len);
    @memcpy(q.message[0..q.msg_len], m[0..q.msg_len]);
    if (def_text) |d| {
        const ds = objc.fromNSString(d);
        q.def_len = @min(ds.len, q.default_text.len);
        @memcpy(q.default_text[0..q.def_len], ds[0..q.def_len]);
        q.input_buf.set(ds);
    }
    t.question = q;
    t.notify();
}

fn runAlert(obj: objc.Object, _: objc.SEL, _: objc.Object, msg: ?objc.Object, _: objc.Object, comp: ?*const anyopaque) callconv(.c) void {
    if (tabOf(obj)) |t| setupQuestion(t, .alert, msg, null, comp);
}

fn runConfirm(obj: objc.Object, _: objc.SEL, _: objc.Object, msg: ?objc.Object, _: objc.Object, comp: ?*const anyopaque) callconv(.c) void {
    if (tabOf(obj)) |t| setupQuestion(t, .confirm, msg, null, comp);
}

fn runPrompt(obj: objc.Object, _: objc.SEL, _: objc.Object, prompt: ?objc.Object, def: ?objc.Object, _: objc.Object, comp: ?*const anyopaque) callconv(.c) void {
    if (tabOf(obj)) |t| setupQuestion(t, .prompt, prompt, def, comp);
}

fn didReceiveMessage(obj: objc.Object, _: objc.SEL, _: objc.Object, msg: objc.Object) callconv(.c) void {
    const t = tabOf(obj) orelse return;
    const body = objc.msg(?objc.Object, msg, "body", .{}) orelse return;
    if (!objc.msg(objc.BOOL, body, "isKindOfClass:", .{objc.class("NSDictionary")})) return;
    const kind = objc.fromNSString(objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("kind")}));
    if (std.mem.eql(u8, kind, "opensearch")) {
        const host = objc.fromNSString(objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("host")}));
        const title = objc.fromNSString(objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("title")}));
        const href = objc.fromNSString(objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("href")}));
        if (t.on_opensearch) |cb| cb(t.browser_ctx, host, title, href);
    }
}
