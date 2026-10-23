//! `ExtensionOffscreen` (ExtensionOffscreen.swift): a DOM owned by an
//! extension, never a browser tab. Creation, discovery and teardown use the
//! same record, including while its first page is loading. Its view is made
//! with the extension context's `webViewConfiguration` and is never put on
//! screen (only lent to the recording pill, `capture.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const value = @import("value.zig");
const Extensions = @import("controller.zig").Extensions;
const config = @import("../web/config.zig");
const dialogs = @import("../web/dialogs.zig");
const capture = @import("capture.zig");

pub const Closed = "The offscreen document was closed.";

/// Live documents by extension id (the document owns the key).
var documents: std.StringArrayHashMapUnmanaged(*Document) = .empty;
var serials: u64 = 0;

const Result = union(enum) { ok: ?objc.Object, err: []u8 };

const Delivery = struct {
    reply: ?Result = null,
    waiters: std.ArrayList(value.Reply) = .empty,
};

/// A relay that arrived before the document was ready: it waits for it.
const Send = struct {
    message: ?objc.Object,
    sender: objc.Object,
    token: []u8,
    reply: value.Reply,
};

pub const Document = struct {
    serial: u64,
    owner: *Extensions,
    gpa: std.mem.Allocator,
    id: []u8,
    context: objc.Object,
    url: objc.Object,
    context_id: []u8,
    document_id: []u8,
    web: objc.Object,
    delegate: objc.Object,
    reasons: [][]u8,
    loading: ?value.Reply = null,
    deadline: bool = false,
    closed: bool = false,
    ready: bool = false,
    readiness: std.ArrayList(Send) = .empty,
    tab_id: ?objc.NSInteger = null,
    deliveries: std.StringHashMapUnmanaged(Delivery) = .empty,
    order: std.ArrayList([]const u8) = .empty,

    /// Made to record: the microphone, the camera or the screen.
    pub fn records(self: *const Document) bool {
        return recordsFor(self.reasons);
    }
};

fn recordsFor(list: []const []const u8) bool {
    for (list) |r| if (std.mem.eql(u8, r, "USER_MEDIA") or std.mem.eql(u8, r, "DISPLAY_MEDIA")) return true;
    return false;
}

pub fn alive(serial: u64) ?*Document {
    for (documents.values()) |d| if (d.serial == serial) return d;
    return null;
}

fn str(o: ?objc.Object) []const u8 {
    return objc.fromNSString(o);
}

pub fn nsField(obj: objc.Object, comptime sel: [:0]const u8) []const u8 {
    return str(objc.msg(?objc.Object, obj, sel, .{}));
}

fn isKind(o: ?objc.Object, comptime cls: [:0]const u8) bool {
    const x = o orelse return false;
    return objc.msg(objc.BOOL, x, "isKindOfClass:", .{objc.class(cls)});
}

fn uuid(gpa: std.mem.Allocator) ![]u8 {
    const u = objc.msg(objc.Object, objc.class("NSUUID"), "UUID", .{});
    return gpa.dupe(u8, nsField(u, "UUIDString"));
}

/// `ExtensionShims.page(_:in:)`: one of the extension's own pages, from the
/// path it gave — resolved rather than appended, since a path can carry a
/// query; never anywhere but inside the extension. Autoreleased.
pub fn page(path: []const u8, context: objc.Object) ?objc.Object {
    const base = objc.msg(objc.Object, context, "baseURL", .{});
    const trimmed = std.mem.trim(u8, path, "/");
    const rel = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:relativeToURL:", .{ objc.nsString(trimmed), base }) orelse return null;
    const abs = objc.msg(?objc.Object, rel, "absoluteURL", .{}) orelse return null;
    if (!std.mem.eql(u8, nsField(abs, "scheme"), nsField(base, "scheme"))) return null;
    if (!std.mem.eql(u8, nsField(abs, "host"), nsField(base, "host"))) return null;
    return abs;
}

/// `create(_:reasons:for:)`: `reply.ok(nil)` once its first page is there,
/// else `fail` with why.
pub fn create(owner: *Extensions, path: []const u8, why: []const []const u8, context: objc.Object, reply: value.Reply) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = nsField(context, "uniqueIdentifier");
    if (documents.contains(id)) return reply.fail("Only a single offscreen document may be created.");
    const refused = "The offscreen document must belong to this extension.";
    const to = page(path, context) orelse return reply.fail(refused);
    if (objc.msg(?objc.Object, to, "user", .{}) != null or objc.msg(?objc.Object, to, "password", .{}) != null) return reply.fail(refused);
    const configuration = objc.msg(?objc.Object, context, "webViewConfiguration", .{}) orelse return reply.fail(refused);
    const prefs = objc.msg(?objc.Object, objc.msg(objc.Object, configuration, "preferences", .{}), "copy", .{}) orelse return reply.fail(refused);
    defer objc.release(prefs);
    // This page has no window by design. Let its DOM and message replies
    // keep working, with WebKit's background CPU throttling still in place
    // (WKInactiveSchedulingPolicyThrottle).
    objc.msg(void, prefs, "setInactiveSchedulingPolicy:", .{@as(objc.NSInteger, 1)});
    // One made to record from the microphone may start while nobody sees it,
    // as in Chrome; Kea still asks first, and the pill says it is listening.
    for (why) |r| if (std.mem.eql(u8, r, "USER_MEDIA")) capture.set("_setGetUserMediaRequiresFocus:", false, prefs);
    objc.msg(void, configuration, "setPreferences:", .{prefs});

    const doc = make(owner, id, to, why, context, configuration) catch return reply.fail(refused);
    // Reserve the slot before yielding, so simultaneous creates cannot leave
    // two pages alive for one extension.
    documents.put(owner.gpa, doc.id, doc) catch {
        destroy(doc);
        return reply.fail(refused);
    };
    // WebKit needs a tab adapter to identify content scripts in this page's
    // iframes; it is never inserted into a browser's tabs.
    objc.msg(void, context, "didOpenTab:", .{doc.delegate});
    load(doc, reply);
}

fn make(owner: *Extensions, id: []const u8, to: objc.Object, why: []const []const u8, context: objc.Object, configuration: objc.Object) !*Document {
    const gpa = owner.gpa;
    const doc = try gpa.create(Document);
    errdefer gpa.destroy(doc);
    const kept = try gpa.alloc([]u8, why.len);
    for (why, 0..) |r, i| kept[i] = try gpa.dupe(u8, r);
    serials += 1;
    const web = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{
        objc.CGRect{ .size = .{ .width = 800, .height = 600 } }, configuration,
    });
    const delegate = objc.msg(objc.Object, @import("offscreen_page.zig").class(), "new", .{});
    doc.* = .{
        .serial = serials,
        .owner = owner,
        .gpa = gpa,
        .id = try gpa.dupe(u8, id),
        .context = objc.retain(context),
        .url = objc.retain(to),
        .context_id = try uuid(gpa),
        .document_id = try uuid(gpa),
        .web = web,
        .delegate = delegate,
        .reasons = kept,
    };
    objc.setZig(delegate, doc);
    objc.msg(void, web, "setNavigationDelegate:", .{delegate});
    objc.msg(void, web, "setUIDelegate:", .{delegate});
    return doc;
}

fn destroy(doc: *Document) void {
    defer destroyRest(doc);
    objc.setZig(doc.delegate, null);
    // Let go on the next turn: a close can come from inside the view's own
    // delegate call, under pools that drain before it returns.
    objc.dispatchMain(doc.web, releaseLater);
    objc.dispatchMain(doc.delegate, releaseLater);
}

fn releaseLater(o: ?*anyopaque) callconv(.c) void {
    objc.release(@ptrCast(o.?));
}

fn destroyRest(doc: *Document) void {
    const gpa = doc.gpa;
    objc.release(doc.context);
    objc.release(doc.url);
    for (doc.reasons) |r| gpa.free(r);
    gpa.free(doc.reasons);
    gpa.free(doc.context_id);
    gpa.free(doc.document_id);
    doc.readiness.deinit(gpa);
    doc.deliveries.deinit(gpa);
    doc.order.deinit(gpa);
    gpa.free(doc.id);
    gpa.destroy(doc);
}

/// `close(for:)`.
pub fn close(id: []const u8) void {
    const doc = documents.get(id) orelse return;
    closeWith(doc, Closed);
}

/// `hasDocument(for:)`.
pub fn hasDocument(id: []const u8) bool {
    return documents.contains(id);
}

/// `reasons(of:)`: why the document showing in this view was made — null
/// for any other view.
pub fn reasons(web: objc.Object) ?[]const []const u8 {
    for (documents.values()) |d| if (d.web == web) return d.reasons;
    return null;
}

/// Whether `web` is an offscreen document made to record; null when it is
/// no offscreen document at all.
pub fn records(web: objc.Object) ?bool {
    return if (reasons(web)) |r| recordsFor(r) else null;
}

/// `url(for:)`: where it is now, for the extension's list of its own pages
/// (unretained).
pub fn url(id: []const u8) ?objc.Object {
    const d = documents.get(id) orelse return null;
    return if (d.ready) objc.msg(?objc.Object, d.web, "URL", .{}) else null;
}

// MARK: loading

const Timer = struct { serial: u64 };

fn load(doc: *Document, reply: value.Reply) void {
    doc.loading = reply;
    doc.deadline = true;
    if (std.heap.c_allocator.create(Timer)) |t| {
        t.* = .{ .serial = doc.serial };
        objc.dispatchAfter(30 * std.time.ns_per_s, t, deadline);
    } else |_| {}
    const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{doc.url});
    _ = objc.msg(?objc.Object, doc.web, "loadRequest:", .{req});
}

fn deadline(ctx: ?*anyopaque) callconv(.c) void {
    const t: *Timer = @ptrCast(@alignCast(ctx orelse return));
    defer std.heap.c_allocator.destroy(t);
    const doc = alive(t.serial) orelse return;
    if (doc.deadline) closeWith(doc, "The offscreen document did not finish loading.");
}

/// `finish(.success)`: the waiting relays go on, the creator is answered.
pub fn ready(doc: *Document) void {
    doc.deadline = false;
    var waiting = doc.readiness;
    doc.readiness = .empty;
    defer waiting.deinit(doc.gpa);
    if (doc.loading) |r| {
        doc.loading = null;
        r.ok(null);
    }
    const serial = doc.serial;
    for (waiting.items) |s| {
        defer dropSend(doc.gpa, s);
        // A relay's own reply may close it; the rest are then unheard.
        const d = alive(serial) orelse {
            unhandled(s.reply);
            continue;
        };
        deliver(d, s);
    }
}

fn dropSend(gpa: std.mem.Allocator, s: Send) void {
    if (s.message) |m| objc.release(m);
    objc.release(s.sender);
    gpa.free(s.token);
}

pub fn closeWith(doc: *Document, why: []const u8) void {
    if (doc.closed) return;
    doc.closed = true;
    const gpa = doc.gpa;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (documents.get(doc.id) == doc) _ = documents.swapRemove(doc.id);
    objc.msg(void, doc.context, "didCloseTab:windowIsClosing:", .{ doc.delegate, objc.NO });
    @import("capture_watch.zig").unwatch(doc.web);
    @import("../web/config.zig").teardownWebView(doc.web);
    var it = doc.deliveries.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.waiters.items) |w| w.fail(why);
        e.value_ptr.waiters.deinit(gpa);
        if (e.value_ptr.reply) |r| dropResult(gpa, r);
        gpa.free(e.key_ptr.*);
    }
    doc.deliveries.clearRetainingCapacity();
    doc.order.clearRetainingCapacity();
    // `whenReady` throws: a waiting relay goes unheard.
    for (doc.readiness.items) |s| {
        unhandled(s.reply);
        dropSend(gpa, s);
    }
    doc.readiness.clearRetainingCapacity();
    doc.deadline = false;
    if (doc.loading) |r| {
        doc.loading = null;
        r.fail(why);
    }
    destroy(doc);
}

fn dropResult(gpa: std.mem.Allocator, r: Result) void {
    switch (r) {
        .ok => |o| if (o) |x| objc.release(x),
        .err => |e| gpa.free(e),
    }
}

// MARK: messages

fn unhandled(reply: value.Reply) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    reply.ok(value.objectOf(.{ .handled = false }));
}

/// `send(_:sender:token:for:)`: a relay from the extension to its own
/// frames in the document, answered once per token however many pages hear
/// it. `{handled: false}` when it isn't the document's.
pub fn send(owner: *Extensions, message: ?objc.Object, sender: objc.Object, token: []const u8, id: []const u8, reply: value.Reply) void {
    const doc = documents.get(id) orelse return unhandled(reply);
    const n = std.unicode.utf8CountCodepoints(token) catch token.len;
    if (n == 0 or n > 128) return unhandled(reply);
    const s: Send = .{
        .message = if (message) |m| objc.retain(m) else null,
        .sender = objc.retain(sender),
        .token = owner.gpa.dupe(u8, token) catch return unhandled(reply),
        .reply = reply,
    };
    // Its own frames speak before it has finished: they wait for it.
    if (!doc.ready) {
        doc.readiness.append(doc.gpa, s) catch {
            dropSend(owner.gpa, s);
            return unhandled(reply);
        };
        return;
    }
    defer dropSend(owner.gpa, s);
    deliver(doc, s);
}

pub fn int(o: ?objc.Object) ?objc.NSInteger {
    if (!isKind(o, "NSNumber")) return null;
    return objc.msg(objc.NSInteger, o.?, "integerValue", .{});
}

fn get(dict: objc.Object, key: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)});
}

/// Whether the relay comes from one of the document's own frames, where the
/// document is now.
fn fromFrame(doc: *Document, sender: objc.Object) bool {
    if (!isKind(sender, "NSDictionary")) return false;
    const frame = int(get(sender, "frameId")) orelse return false;
    if (frame <= 0) return false;
    const tab = get(sender, "tab") orelse return false;
    if (!isKind(tab, "NSDictionary")) return false;
    const mine = doc.tab_id orelse return false;
    if ((int(get(tab, "id")) orelse return false) != mine) return false;
    // A hash or a move inside the extension doesn't make its frames anyone
    // else's.
    const at = objc.msg(?objc.Object, doc.web, "URL", .{}) orelse return false;
    if (!std.mem.eql(u8, nsField(at, "scheme"), nsField(doc.url, "scheme"))) return false;
    if (!std.mem.eql(u8, nsField(at, "host"), nsField(doc.url, "host"))) return false;
    const said = get(tab, "url") orelse return false;
    return isKind(said, "NSString") and std.mem.eql(u8, str(said), nsField(at, "absoluteString"));
}

fn deliver(doc: *Document, s: Send) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!fromFrame(doc, s.sender)) return unhandled(s.reply);
    const gpa = doc.gpa;
    // A worker and several extension pages may hear the same relay: they
    // share one delivery and one reply, never repeat its side effects.
    if (doc.deliveries.getPtr(s.token)) |existing| {
        if (existing.reply) |r| return answer(s.reply, r);
        existing.waiters.append(gpa, s.reply) catch s.reply.fail(Closed);
        return;
    }
    const key = gpa.dupe(u8, s.token) catch return s.reply.fail(Closed);
    var waiters: std.ArrayList(value.Reply) = .empty;
    waiters.append(gpa, s.reply) catch {
        gpa.free(key);
        return s.reply.fail(Closed);
    };
    doc.deliveries.put(gpa, key, .{ .waiters = waiters }) catch {
        gpa.free(key);
        waiters.deinit(gpa);
        return s.reply.fail(Closed);
    };
    const ctx = std.heap.c_allocator.create(Relay) catch return;
    ctx.* = .{ .serial = doc.serial, .token = std.heap.c_allocator.dupe(u8, s.token) catch {
        std.heap.c_allocator.destroy(ctx);
        return;
    } };
    const args = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, args, "setObject:forKey:", .{ s.message orelse objc.msg(objc.Object, objc.class("NSNull"), "null", .{}), objc.nsString("message") });
    objc.msg(void, args, "setObject:forKey:", .{ s.sender, objc.nsString("sender") });
    var block = RelayBlock.init(ctx, relayed);
    objc.msg(void, doc.web, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString("return await globalThis.__keaOffscreenDispatch(message, sender);"),
        args,
        @as(?objc.Object, null),
        config.pageWorld(),
        @as(*anyopaque, @ptrCast(&block)),
    });
}

fn answer(reply: value.Reply, r: Result) void {
    switch (r) {
        .ok => |o| reply.ok(o),
        .err => |e| reply.fail(e),
    }
}

const Relay = struct { serial: u64, token: []u8 };
const RelayBlock = objc.Block(Relay, &.{ ?objc.Object, ?objc.Object });

/// The page answered a relay. A closed document has already rejected all
/// its callers.
fn relayed(ctx: *Relay, result: ?objc.Object, err: ?objc.Object) void {
    defer {
        std.heap.c_allocator.free(ctx.token);
        std.heap.c_allocator.destroy(ctx);
    }
    const doc = alive(ctx.serial) orelse return;
    const gpa = doc.gpa;
    const entry = doc.deliveries.getEntry(ctx.token) orelse return;
    if (entry.value_ptr.reply != null) return;
    const r: Result = if (err) |e|
        .{ .err = gpa.dupe(u8, nsField(e, "localizedDescription")) catch return }
    else
        .{ .ok = if (result) |o| objc.retain(o) else null };
    var waiters = entry.value_ptr.waiters;
    entry.value_ptr.* = .{ .reply = r };
    defer waiters.deinit(gpa);
    doc.order.append(gpa, entry.key_ptr.*) catch {};
    // Pending deliveries stay indexed until settled; settled ones are kept
    // for the last 128.
    if (doc.order.items.len > 128) {
        const oldest = doc.order.orderedRemove(0);
        if (doc.deliveries.fetchRemove(oldest)) |kv| {
            if (kv.value.reply) |old| dropResult(gpa, old);
            var settled = kv.value.waiters;
            settled.deinit(gpa);
            gpa.free(kv.key);
        }
    }
    const serial = doc.serial;
    for (waiters.items) |w| {
        // A reply could close the document; answer from a copy either way.
        if (alive(serial) == null) {
            w.fail(Closed);
            continue;
        }
        answer(w, r);
    }
}

/// `contexts(for:matching:)`: the document as `runtime.getContexts` lists
/// it, if it matches `filter`. An autoreleased NSArray (0 or 1 entries).
pub fn contexts(id: []const u8, filter: ?objc.Object) objc.Object {
    const none = objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    const doc = documents.get(id) orelse return none;
    if (!doc.ready) return none;
    const u = doc.url;
    const port = objc.msg(?objc.Object, u, "port", .{});
    var origin_buf: [512]u8 = undefined;
    const origin = if (port) |p|
        std.fmt.bufPrint(&origin_buf, "{s}://{s}:{d}", .{ nsField(u, "scheme"), nsField(u, "host"), objc.msg(objc.NSInteger, p, "integerValue", .{}) }) catch return none
    else
        std.fmt.bufPrint(&origin_buf, "{s}://{s}", .{ nsField(u, "scheme"), nsField(u, "host") }) catch return none;
    const v = value.objectOf(.{
        .contextId = doc.context_id,
        .contextType = "OFFSCREEN_DOCUMENT",
        .documentId = doc.document_id,
        .documentUrl = nsField(u, "absoluteString"),
        .documentOrigin = origin,
        .frameId = @as(i64, 0),
        .tabId = @as(i64, -1),
        .windowId = @as(i64, -1),
        .incognito = false,
    }) orelse return none;
    if (filter) |f| if (isKind(f, "NSDictionary")) {
        const fields = [_][2][]const u8{
            .{ "contextIds", "contextId" },       .{ "contextTypes", "contextType" },
            .{ "documentIds", "documentId" },     .{ "documentOrigins", "documentOrigin" },
            .{ "documentUrls", "documentUrl" },   .{ "frameIds", "frameId" },
            .{ "tabIds", "tabId" },               .{ "windowIds", "windowId" },
        };
        for (fields) |pair| {
            const asked = get(f, pair[0]) orelse continue;
            if (!isKind(asked, "NSArray")) return none;
            const actual = get(v, pair[1]) orelse return none;
            if (!objc.msg(objc.BOOL, asked, "containsObject:", .{actual})) return none;
        }
        const incognito = get(f, "incognito");
        if (isKind(incognito, "NSNumber") and objc.msg(objc.BOOL, incognito.?, "boolValue", .{})) return none;
    };
    return objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{v});
}

test "offscreen records only for media reasons" {
    try std.testing.expect(recordsFor(&.{ "DOM_PARSER", "USER_MEDIA" }));
    try std.testing.expect(recordsFor(&.{"DISPLAY_MEDIA"}));
    try std.testing.expect(!recordsFor(&.{ "CLIPBOARD", "AUDIO_PLAYBACK" }));
}
