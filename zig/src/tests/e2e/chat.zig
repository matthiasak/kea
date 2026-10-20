//! P9: Summarize Page over a real page — the page's text goes to the
//! provider (a stand-in streaming from the run loop) and the answer comes
//! into Ubi Chat's transcript piece by piece.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const client = app.ai_client;
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "summarize page streams into transcript", .run = summarize },
};

const pieces = [_][]const u8{ "Kea are ", "alpine parrots ", "of New Zealand, ", "known for their curiosity." };
const answer = pieces[0] ++ pieces[1] ++ pieces[2] ++ pieces[3];
/// The loopback page whose body is `body`: words only its text has.
const path = "/words/kea-parrots-of-the-alps";
const body = "kea parrots of the alps";

/// Answers each question with `pieces`, one every 20 ms from the run loop;
/// a chat's name at once. Notes what each question carried.
const Stub = struct {
    sink: ?client.Sink = null,
    step: usize = 0,
    stopped: bool = false,
    asked: std.ArrayList(u8) = .empty,
};

var stub: Stub = .{};

fn stream(_: ?*anyopaque, _: *app.ai_core.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
    if (std.mem.startsWith(u8, q.system, "Name this chat")) {
        sink.piece(sink.ctx, "Kea");
        sink.done(sink.ctx, null);
        return null;
    }
    for (q.messages) |m| stub.asked.appendSlice(std.heap.c_allocator, m.text) catch {};
    stub.sink = sink;
    stub.step = 0;
    stub.stopped = false;
    objc.dispatchAfter(20_000_000, null, tick);
    return .{ .ctx = &stub, .stop = stop };
}

fn tick(_: ?*anyopaque) callconv(.c) void {
    if (stub.stopped) return;
    const s = stub.sink orelse return;
    if (stub.step < pieces.len) {
        s.piece(s.ctx, pieces[stub.step]);
        stub.step += 1;
        objc.dispatchAfter(20_000_000, null, tick);
    } else {
        stub.sink = null;
        s.done(s.ctx, null);
    }
}

fn stop(_: *anyopaque) void {
    stub.stopped = true;
    stub.sink = null;
}

fn streaming(b: *app.Browser) bool {
    const a = b.assisting orelse return false;
    const l = a.live orelse return false;
    return l.answer.items.len > 0 and l.answer.items.len < answer.len;
}

fn answered(b: *app.Browser) bool {
    const a = b.assisting orelse return false;
    return a.live == null and a.chat.turns.len == 1;
}

/// Whether the window's last frame drew a text holding `said`.
fn drew(b: *app.Browser, said: []const u8) bool {
    const w = b.window orelse return false;
    const s = w.surface orelse return false;
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.indexOf(u8, tx.str, said) != null) return true,
        else => {},
    };
    return false;
}

fn summarize(h: *Harness) !void {
    stub = .{};
    defer stub.asked.deinit(std.heap.c_allocator);
    const b = try h.start();
    const m = b.kea.ai;
    m.client = .{ .stream = stream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");
    var buf: [128]u8 = undefined;
    _ = try web.open(h, b, try std.fmt.bufPrint(&buf, "{s}{s}", .{ h.http, path }));
    b.summarizePage();
    try h.waitFor(b, streaming, 10, "the first pieces");
    try h.waitFor(b, answered, 10, "the whole answer");
    const a = b.assisting.?;
    const turn = a.chat.turns[0];
    try h.expect(turn.failed == null, "failed: {s}", .{turn.failed orelse ""});
    try h.expect(std.mem.eql(u8, turn.answer, answer), "answer '{s}'", .{turn.answer});
    try h.expect(std.mem.startsWith(u8, turn.question, "Summarize this page"), "question '{s}'", .{turn.question});
    try h.expect(std.mem.indexOf(u8, stub.asked.items, body) != null, "the page's text wasn't asked about", .{});
    h.frame();
    try h.expect(drew(b, "alpine parrots"), "the transcript didn't draw the answer", .{});
}
