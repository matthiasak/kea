//! A task board, for the reel: three columns of cards. A card picked up
//! lifts (a spring to a larger scale, a deeper shadow), glides to its new
//! column when moved, and the cards around it close up or make room, all
//! by springing to their new places; the columns' counts ease too.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

const Card = struct { title: []const u8, tag: []const u8, status: kit.Status, who: []const u8 };

const cards = [_]Card{
    .{ .title = "Ship ui.motion", .tag = "Motion", .status = .info, .who = "Maya Chen" },
    .{ .title = "Write the kit docs", .tag = "Docs", .status = .neutral, .who = "Leo Park" },
    .{ .title = "Glass toasts", .tag = "Kit", .status = .success, .who = "Rach Pradhan" },
    .{ .title = "Layout animation", .tag = "Motion", .status = .info, .who = "Maya Chen" },
    .{ .title = "Reel in Codegraff colors", .tag = "Video", .status = .warning, .who = "Rach Pradhan" },
    .{ .title = "Fix wrapped text", .tag = "Bug", .status = .danger, .who = "Leo Park" },
    .{ .title = "Release 0.4", .tag = "Release", .status = .success, .who = "Maya Chen" },
};

const columns = [_][]const u8{ "To do", "In progress", "Done" };

pub const State = struct {
    cols: [3][8]u8 = .{ .{ 6, 1, 5, 0, 0, 0, 0, 0 }, .{ 0, 2, 0, 0, 0, 0, 0, 0 }, .{ 3, 4, 0, 0, 0, 0, 0, 0 } },
    lens: [3]usize = .{ 3, 2, 2 },
    lifted: ?u8 = null,

    /// Takes card `id` from its column into `to` at `at`.
    pub fn move(s: *State, id: u8, to: usize, at: usize) void {
        for (&s.cols, &s.lens) |*col, *len| {
            for (col[0..len.*], 0..) |x, i| if (x == id) {
                std.mem.copyForwards(u8, col[i .. len.* - 1], col[i + 1 .. len.*]);
                len.* -= 1;
                break;
            };
        }
        const n = s.lens[to];
        const i = @min(at, n);
        std.mem.copyBackwards(u8, s.cols[to][i + 1 .. n + 1], s.cols[to][i..n]);
        s.cols[to][i] = id;
        s.lens[to] = n + 1;
    }
};

const col_w: f32 = 336;
const card_h: f32 = 84;

pub fn view(c: *ui.Context, s: *State, w: f32) void {
    const th = c.theme;
    const gap = (w - 3 * col_w) / 4;
    const board = ui.div(c).sizeFull();
    defer board.end();
    for (columns, 0..) |name, ci| {
        const x = gap + @as(f32, @floatFromInt(ci)) * (col_w + gap);
        const col = ui.div(c).absolute().offset(x, 20).w(col_w).h(510).column().p(14).gap(8).rounded(14).bg(th.surface_hover.alpha(0.7));
        defer col.end();
        const head = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer head.end();
        ui.text(c, name, .{ .size = 15, .weight = .bold });
        const n = motion.number(c, "count", @floatFromInt(s.lens[ci]), .{ .tween = .{ .duration = 0.3 } });
        const pill = ui.div(c).px(8).py(1).roundedFull().bg(th.border.alpha(0.6));
        defer pill.end();
        ui.text(c, c.print("{d:.0}", .{n}), .{ .size = 12, .weight = .semibold, .mono = true, .color = th.muted });
    }
    // Every card where its column and place put it, springing there.
    for (s.cols, 0..) |col, ci| for (col[0..s.lens[ci]], 0..) |id, i| {
        const cd = cards[id];
        const lifted = s.lifted == id;
        const x = gap + @as(f32, @floatFromInt(ci)) * (col_w + gap) + 14;
        const y = 20 + 52 + @as(f32, @floatFromInt(i)) * (card_h + 10);
        ui.key(c, c.print("card-{d}", .{id}));
        const f = motion.frame(c, .{ .target = .{ .x = x, .y = y, .scale = if (lifted) 1.05 else 1 }, .initial = .{ .x = x, .y = y + 20, .opacity = 0 }, .transition = .{ .spring = .{ .stiffness = 230, .damping = 22 } } });
        const card = ui.div(c).absolute().w(col_w - 28).h(card_h).column().p(14).gap(8).rounded(12).bg(th.surface).border(th.border).layer(if (lifted) 5 else 0).shadow(.{ .color = th.shadow.alpha(if (lifted) 1 else 0.35), .blur = if (lifted) 28 else 6, .y = if (lifted) 12 else 2 }).motion(f);
        defer card.end();
        ui.text(c, cd.title, .{ .size = 14.5, .weight = .semibold });
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        kit.tag(c, cd.tag, .{ .status = cd.status, .size = .xs });
        ui.spacer(c);
        kit.avatar(c, .{ .name = cd.who, .size = 22 });
    };
}
