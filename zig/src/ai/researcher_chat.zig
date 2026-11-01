//! The Researcher overlay's actions (researcher_view.zig): a section shown
//! on the page, and the explanation carried into Ubi Chat as its first turn
//! — the same chat each time, kept in step while the explanation streams.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const Tab = @import("../web/tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const ai = @import("ai.zig");
const sse = @import("client_sse.zig");
const ubi = @import("ubi_chat.zig");
const assistant = @import("assistant.zig");
const Assistant = assistant.Assistant;
const researcher = @import("researcher.zig");
const Entry = researcher.Entry;
const Section = researcher.Section;
const A = std.mem.Allocator;

const Jump = struct { serial: u64, page: usize };
const JumpBlock = objc.Block(Jump, &.{objc.Object});

/// Section `s` brought into view: its heading on a web page; on a PDF the
/// heading found, or else its page.
pub fn jumpToSection(t: *Tab, e: *const Entry, s: Section) void {
    const idx = s.index -| 1;
    if (!e.is_pdf) {
        const js = std.fmt.allocPrint(t.gpa, "{s}('scrollTo', {d})", .{ researcher.script, idx }) catch return;
        defer t.gpa.free(js);
        return t.evaluate(js, .kea, null, 0);
    }
    const wv = t.web orelse return;
    const words = if (idx < e.inputs.len) e.inputs[idx].heading else e.heading(s);
    const sel = objc.sel("findString:withConfiguration:completionHandler:");
    if (words.len == 0 or !objc.msg(objc.BOOL, wv, "respondsToSelector:", .{sel})) return toPage(t, e.pageOf(s));
    const j = std.heap.c_allocator.create(Jump) catch return;
    j.* = .{ .serial = t.serial, .page = e.pageOf(s) };
    const pool = objc.Pool.push();
    defer pool.pop();
    const cfg = objc.msg(objc.Object, objc.class("WKFindConfiguration"), "new", .{});
    defer objc.release(cfg);
    objc.msg(void, cfg, "setWraps:", .{objc.YES});
    var block = JumpBlock.init(j, found);
    objc.msg(void, wv, "findString:withConfiguration:completionHandler:", .{ objc.nsString(words), cfg, @as(*anyopaque, @ptrCast(&block)) });
}

fn found(j: *Jump, result: objc.Object) void {
    defer std.heap.c_allocator.destroy(j);
    if (objc.msg(objc.BOOL, result, "matchFound", .{})) return;
    if (Tab.alive(j.serial)) |t| toPage(t, j.page);
}

fn toPage(t: *Tab, n: usize) void {
    if (n == 0) return;
    const u = t.url();
    const end = std.mem.indexOfScalar(u8, u, '#') orelse u.len;
    var buf: [4096]u8 = undefined;
    t.go(std.fmt.bufPrint(&buf, "{s}#page={d}", .{ u[0..end], n }) catch return);
}

/// Ubi Chat opened on the explanation, asked to go deeper into section `s`.
pub fn askSection(b: *Browser, e: *Entry, s: Section) void {
    const a = openInChat(b, e) orelse return;
    var buf: [1024]u8 = undefined;
    const q = std.fmt.bufPrint(&buf, "Explain section “{s}” in deeper detail from first principles, walking through every equation, data structure, or claim step by step.", .{sse.prefix(e.heading(s), 200)}) catch return;
    _ = a.ask(q);
}

/// The explanation as the chat's turn; its question on `buf`.
fn turnOf(e: *const Entry, buf: []u8) cs.Turn {
    const from = if (e.sections.items.len > 0) e.sections.items[0].line else 0;
    return .{
        .id = e.turn_id,
        .question = std.fmt.bufPrint(buf, "Explain each section of “{s}” from first principles.", .{sse.prefix(e.title, 200)}) catch "Explain each section from first principles.",
        .answer = std.mem.trim(u8, e.raw.items[from..], " \t\r\n"),
        .done = e.status == .done or e.status == .failed,
        .failed = if (e.status == .failed) e.error_msg orelse "Couldn't explain this page" else null,
        .place = e.place,
    };
}

const Put = struct { turn: cs.Turn, show_page: bool };

/// The turn replaced where it is, or first when the chat lost it.
fn put(x: Put, a: A, c: *cs.Chat) !void {
    if (x.show_page) c.pageHidden = false;
    for (c.turns, 0..) |t, i| if (t.id.eql(x.turn.id)) {
        const list = try a.dupe(cs.Turn, c.turns);
        list[i] = try json.clone(a, x.turn);
        c.turns = list;
        return;
    };
    const list = try a.alloc(cs.Turn, c.turns.len + 1);
    list[0] = try json.clone(a, x.turn);
    @memcpy(list[1..], c.turns);
    c.turns = list;
}

/// The explanation as Ubi Chat's first turn: the chat it went to before
/// when that is still there, else a new one.
pub fn openInChat(b: *Browser, e: *Entry) ?*Assistant {
    const a = @import("../model/browser_chat.zig").openChat(b) orelse return null;
    a.listing = false;
    var buf: [512]u8 = undefined;
    const turn = turnOf(e, &buf);
    if (e.chat_id) |cid| {
        if (!a.chat.id.eql(cid) and !a.shy and a.m.chats.chat(cid) != null) a.open(cid);
        if (a.chat.id.eql(cid)) {
            a.mutate(Put{ .turn = turn, .show_page = true }, put);
            a.keep();
            return a;
        }
    }
    const cid = e.chat_id orelse json.Uuid.random();
    e.chat_id = cid;
    a.adoptChat(.{
        .id = cid,
        .title = sse.prefix(std.mem.trim(u8, e.title, " \t\r\n"), 80),
        .touched = json.now(),
        .turns = &.{turn},
    });
    return a;
}

/// The explanation grown (`final`: ended) into the chat it went to: the
/// chat open in a panel, kept once it ends, or the one in the store.
pub fn syncChat(e: *const Entry, m: *ai.Ai, final: bool) void {
    const cid = e.chat_id orelse return;
    var buf: [512]u8 = undefined;
    const turn = turnOf(e, &buf);
    for (m.assistants.items) |a| if (a.chat.id.eql(cid)) {
        a.mutate(Put{ .turn = turn, .show_page = false }, put);
        if (!final) return;
        a.keep();
        const ts = a.chat.turns;
        if (turn.failed == null and ts.len > 0 and ts[ts.len - 1].id.eql(turn.id)) if (ubi.quiet(m)) |r| @import("followups.zig").afterAnswer(a, r.provider, r.model);
        return;
    };
    if (final) assistant.editStored(m, cid, Put{ .turn = turn, .show_page = false }, put);
}
