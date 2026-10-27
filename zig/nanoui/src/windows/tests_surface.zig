const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;

const Page = struct {
    open: bool = false,

    fn view(p: *Page, c: *ui.Context) void {
        const root = ui.div(c).p(20);
        defer root.end();
        const f = ui.motion.frame(c, .{
            .target = .{
                .width = if (p.open) 280 else 180,
                .height = if (p.open) 150 else 96,
                .radius = if (p.open) 24 else 14,
                .background = if (p.open) c.theme.accent else c.theme.surface,
            },
            .press = .{ .scale = 0.96 },
            .transition = .{ .spring = ui.motion.Spring.bouncy },
        });
        const card = ui.div(c).column().p(16).border(c.theme.border).clip().control().motion(f);
        defer card.end();
        if (card.clicked()) p.open = !p.open;
        ui.text(c, if (p.open) "Open" else "Click me", .{ .weight = .semibold });
    }
};

test "a motion click and its animated frames draw through a hidden Windows surface" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var p: Page = .{};
    const win = try app.newWindow(.{
        .title = "hidden motion test",
        .width = 400,
        .height = 300,
        .visible = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const s = win.surface.?;
    var at: ui.Point = .{};
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| {
            if (std.mem.eql(u8, t.str, "Click me")) at = .{ .x = n.rect.x + n.rect.w / 2, .y = n.rect.y + n.rect.h / 2 };
        },
        else => {},
    };
    try testing.expect(at.x > 0);
    s.ctx.input.mouse = at;
    s.ctx.updateHot();
    s.ctx.pointerDown();
    s.frame();
    s.ctx.pointerUp();
    s.frame();
    try testing.expect(p.open);
    for (0..120) |_| {
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(16), .awake) catch {};
        s.frame();
        s.pixels.draw(gpa, .{
            .instances = s.instances.items,
            .text = &s.text,
            .clear = s.ctx.theme.background,
            .size = s.size,
            .scale = s.scale,
            .textures = s.ctx.textures.items,
        });
    }
}
