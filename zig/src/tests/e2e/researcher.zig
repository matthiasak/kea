//! Automatic Researcher Mode over real WebKit: a paper page and a PDF that
//! finish loading are explained section by section by the provider (a
//! stand-in answering at once), and the overlay draws over the page.
const std = @import("std");
const app = @import("kea");
const client = app.ai_client;
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "researcher explains a paper page by section", .run = paper },
    .{ .name = "researcher explains a pdf by section", .run = pdf },
};

/// What the page was asked about, for the case to look into.
var asked: std.ArrayList(u8) = .empty;

fn stream(_: ?*anyopaque, _: *app.ai_core.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
    asked.appendSlice(std.heap.c_allocator, q.system) catch {};
    for (q.messages) |m| asked.appendSlice(std.heap.c_allocator, m.text) catch {};
    sink.piece(sink.ctx, "## [1] Abstract\nWarmth is kept by still air.\n## [2] Me");
    sink.piece(sink.ctx, "thodology\nHeat flows through the down like water through a sponge.\n");
    sink.done(sink.ctx, null);
    return null;
}

fn explained(t: *app.Tab) bool {
    const e = app.researcher.entryFor(t) orelse return false;
    return e.status == .done or e.status == .failed;
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

fn run(h: *Harness, path: []const u8, want: []const u8) !void {
    asked = .empty;
    defer asked.deinit(std.heap.c_allocator);
    const b = try h.start();
    const m = b.kea.ai;
    m.client = .{ .stream = stream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");
    m.prefs.set("ai_researcher", true);
    var buf: [128]u8 = undefined;
    const t = try web.open(h, b, try std.fmt.bufPrint(&buf, "{s}{s}", .{ h.http, path }));
    try h.waitFor(t, explained, 10, "the sections explained");
    const e = app.researcher.entryFor(t).?;
    try h.expect(e.status == .done, "failed: {s}", .{e.error_msg orelse ""});
    try h.expect(e.sections.items.len == 2, "{d} sections", .{e.sections.items.len});
    try h.expect(std.mem.eql(u8, e.heading(e.sections.items[1]), "Methodology"), "heading '{s}'", .{e.heading(e.sections.items[1])});
    try h.expect(std.mem.indexOf(u8, asked.items, want) != null, "the page's words weren't asked about", .{});
    try h.expect(std.mem.indexOf(u8, asked.items, "## [N]") != null, "not asked for numbered sections", .{});
    h.frame();
    try h.expect(drew(b, "Feynman Researcher"), "the overlay wasn't drawn", .{});
    try h.expect(drew(b, "Methodology"), "the sections weren't drawn", .{});
}

fn paper(h: *Harness) !void {
    try run(h, "/research-paper.html", "trapping air in their down");
}

fn pdf(h: *Harness) !void {
    try run(h, "/paper.pdf", "Alpine Kea Thermodynamics");
}
