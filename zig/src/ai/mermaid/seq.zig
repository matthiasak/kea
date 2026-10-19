//! Sequence diagrams: participants, messages, notes and block labels, laid
//! out as lifelines with one row per statement.
const std = @import("std");
const m = @import("mermaid.zig");
const text = @import("text.zig");

const ascii = std.ascii;
const mem = std.mem;

const Row = union(enum) {
    message: struct { from: usize, to: usize, text: []const u8, dashed: bool, head: m.Head },
    note: struct { place: Place, indices: []const usize, lines: text.Lines },
    block: []const u8,
};
const Place = enum { left, right, over };

const Arrow = struct { tok: []const u8, dashed: bool, head: m.Head };
const arrows = [_]Arrow{
    .{ .tok = "-->>", .dashed = true, .head = .arrow },
    .{ .tok = "->>", .dashed = false, .head = .arrow },
    .{ .tok = "--x", .dashed = true, .head = .cross },
    .{ .tok = "-x", .dashed = false, .head = .cross },
    .{ .tok = "--)", .dashed = true, .head = .arrow },
    .{ .tok = "-)", .dashed = false, .head = .arrow },
    .{ .tok = "-->", .dashed = true, .head = .none },
    .{ .tok = "->", .dashed = false, .head = .none },
};
const block_words = [_][]const u8{ "loop", "alt", "else", "opt", "par", "and", "critical", "break" };

const Parts = struct {
    a: mem.Allocator,
    ids: std.ArrayList([]const u8) = .empty,
    labels: std.ArrayList(text.Lines) = .empty,
    lookup: std.StringHashMapUnmanaged(usize) = .empty,

    fn ensure(p: *Parts, raw: []const u8, label: ?text.Lines) !?usize {
        const id = text.trim(raw);
        if (id.len == 0) return null;
        if (p.lookup.get(id)) |idx| {
            if (label) |l| p.labels.items[idx] = l;
            return idx;
        }
        if (p.ids.items.len >= m.max_participants) return null;
        const idx = p.ids.items.len;
        try p.lookup.put(p.a, id, idx);
        try p.ids.append(p.a, id);
        try p.labels.append(p.a, label orelse try text.cleanLabel(p.a, id));
        return idx;
    }
};

pub fn parseSequence(a: mem.Allocator, stmts: []const []const u8) !?m.Diagram {
    var parts: Parts = .{ .a = a };
    var rows: std.ArrayList(Row) = .empty;
    var auto_num: ?usize = null;

    stmts: for (stmts) |stmt| {
        const t = text.trim(stmt);
        if (ascii.eqlIgnoreCase(t, "autonumber")) {
            auto_num = 1;
            continue;
        }
        if (ascii.eqlIgnoreCase(t, "end")) continue;
        for ([_][]const u8{ "rect ", "activate ", "deactivate ", "title ", "create ", "destroy " }) |skip| {
            if (ascii.startsWithIgnoreCase(t, skip)) continue :stmts;
        }
        if (ascii.startsWithIgnoreCase(t, "participant ") or ascii.startsWithIgnoreCase(t, "actor ")) {
            const after = text.trim(text.dropWord(t));
            if (ascii.findIgnoreCase(after, " as ")) |as| {
                const id = text.trim(after[0..as]);
                const lbl = text.trim(after[as + 4 ..]);
                _ = try parts.ensure(id, try text.cleanLabel(a, lbl)) orelse return null;
            } else {
                _ = try parts.ensure(after, null) orelse return null;
            }
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "note ")) {
            const colon = mem.indexOfScalar(u8, t, ':') orelse continue;
            const head = text.trim(t[5..colon]);
            const note_text = text.trim(t[colon + 1 ..]);
            var place: Place = .over;
            var who: []const u8 = "";
            if (ascii.startsWithIgnoreCase(head, "left of ")) {
                place = .left;
                who = head[8..];
            } else if (ascii.startsWithIgnoreCase(head, "right of ")) {
                place = .right;
                who = head[9..];
            } else if (ascii.startsWithIgnoreCase(head, "over ")) {
                who = head[5..];
            }
            var indices: std.ArrayList(usize) = .empty;
            var names = mem.tokenizeScalar(u8, who, ',');
            while (names.next()) |raw| {
                const name = text.trim(raw);
                if (name.len == 0) continue;
                try indices.append(a, try parts.ensure(name, null) orelse return null);
            }
            if (indices.items.len > 0) {
                if (rows.items.len >= m.max_sequence_rows) return null;
                try rows.append(a, .{ .note = .{ .place = place, .indices = indices.items, .lines = try text.cleanLabel(a, note_text) } });
            }
            continue;
        }
        const first = text.firstWord(t) orelse "";
        for (block_words) |w| if (ascii.eqlIgnoreCase(first, w)) {
            if (rows.items.len >= m.max_sequence_rows) return null;
            try rows.append(a, .{ .block = t });
            continue :stmts;
        };

        // Message: From ARROW To: text
        for (arrows) |arrow| {
            const r = mem.indexOf(u8, t, arrow.tok) orelse continue;
            const after = r + arrow.tok.len;
            const colon = mem.indexOfScalarPos(u8, t, after, ':') orelse continue;
            const from_name = text.trim(t[0..r]);
            var to_name = text.trim(t[after..colon]);
            if (mem.startsWith(u8, to_name, "+") or mem.startsWith(u8, to_name, "-")) to_name = text.trim(to_name[1..]);
            if (mem.endsWith(u8, to_name, "+") or mem.endsWith(u8, to_name, "-")) to_name = text.trim(to_name[0 .. to_name.len - 1]);
            var msg = text.trim(t[colon + 1 ..]);
            if (auto_num) |n| {
                msg = try std.fmt.allocPrint(a, "{d}. {s}", .{ n, msg });
                auto_num = n + 1;
            }
            if (from_name.len == 0 or to_name.len == 0) return null;
            const fi = try parts.ensure(from_name, null) orelse return null;
            const ti = try parts.ensure(to_name, null) orelse return null;
            if (rows.items.len >= m.max_sequence_rows) return null;
            try rows.append(a, .{ .message = .{ .from = fi, .to = ti, .text = try text.cleanJoined(a, msg), .dashed = arrow.dashed, .head = arrow.head } });
            break;
        }
    }

    const labels = parts.labels.items;
    const count = labels.len;
    if (count == 0 or count > m.max_participants) return null;
    return try layout(a, labels, rows.items);
}

fn layout(a: mem.Allocator, labels: []const text.Lines, rows: []const Row) !m.Diagram {
    const count = labels.len;
    const box_widths = try a.alloc(f64, count);
    for (labels, box_widths) |lines, *w| w.* = @max(text.maxWidth(lines, false, 12) + 24, 72);
    const centers = try a.alloc(f64, count);
    centers[0] = box_widths[0] / 2 + 8;
    for (1..count) |i| {
        var max_adj: f64 = 0;
        for (rows) |row| switch (row) {
            .message => |msg| if ((msg.from == i - 1 and msg.to == i) or (msg.from == i and msg.to == i - 1)) {
                max_adj = @max(max_adj, text.textWidth(msg.text, false, 11));
            },
            else => {},
        };
        centers[i] = centers[i - 1] + @max((box_widths[i - 1] + box_widths[i]) / 2 + 36, max_adj + 24);
    }

    var y: f64 = 56;
    var row_items: std.ArrayList(m.Item) = .empty;
    var msg_count: usize = 0;
    var extra_right = false;

    for (rows) |row| switch (row) {
        .message => |msg| {
            msg_count += 1;
            if (msg.from == msg.to) {
                const cx = centers[msg.from];
                if (msg.from == count - 1) extra_right = true;
                const points = try a.dupe(m.Point, &.{ .{ .x = cx, .y = y }, .{ .x = cx + 28, .y = y }, .{ .x = cx + 28, .y = y + 20 }, .{ .x = cx, .y = y + 20 } });
                try row_items.append(a, .{ .edge = .{ .points = points, .dashed = msg.dashed, .thick = false, .head = msg.head, .label = null } });
                if (msg.text.len > 0) try row_items.append(a, .{ .text = .{
                    .str = msg.text,
                    .at = .{ .x = cx + 14 + text.textWidth(msg.text, false, 11) / 2, .y = y - 8 },
                    .bold = false,
                    .muted = true,
                } });
                y += 44;
            } else {
                const x1 = centers[msg.from];
                const x2 = centers[msg.to];
                const line_y = y + 12;
                const points = try a.dupe(m.Point, &.{ .{ .x = x1, .y = line_y }, .{ .x = x2, .y = line_y } });
                try row_items.append(a, .{ .edge = .{ .points = points, .dashed = msg.dashed, .thick = false, .head = msg.head, .label = null } });
                if (msg.text.len > 0) try row_items.append(a, .{ .text = .{ .str = msg.text, .at = .{ .x = (x1 + x2) / 2, .y = line_y - 8 }, .bold = false, .muted = true } });
                y += 34;
            }
        },
        .note => |note| {
            const nh: f64 = @floatFromInt(16 * @max(1, note.lines.len) + 16);
            const nw = @max(80, text.maxWidth(note.lines, false, 12) + 20);
            const lo = mem.min(usize, note.indices);
            const hi = mem.max(usize, note.indices);
            const span_min = centers[lo] - box_widths[lo] / 2;
            const span_max = centers[hi] + box_widths[hi] / 2;
            var nx: f64 = undefined;
            var w = nw;
            switch (note.place) {
                .left => nx = @max(4, span_min - nw - 8),
                .right => {
                    nx = span_max + 8;
                    if (hi == count - 1) extra_right = true;
                },
                .over => {
                    w = @max(nw, span_max - span_min);
                    nx = (span_min + span_max - w) / 2;
                },
            }
            try row_items.append(a, .{ .note = .{ .rect = .{ .x = nx, .y = y, .w = w, .h = nh }, .lines = note.lines } });
            y += nh + 8;
        },
        .block => |str| {
            const w = text.textWidth(str, true, 11);
            try row_items.append(a, .{ .text = .{ .str = str, .at = .{ .x = 8 + w / 2, .y = y + 10 }, .bold = true, .muted = true } });
            y += 24;
        },
    };

    var items: std.ArrayList(m.Item) = .empty;
    for (centers) |cx| {
        const points = try a.dupe(m.Point, &.{ .{ .x = cx, .y = 32 }, .{ .x = cx, .y = y + 12 } });
        try items.append(a, .{ .edge = .{ .points = points, .dashed = true, .thick = false, .head = .none, .label = null } });
    }
    for (centers, box_widths, labels) |cx, bw, lines| {
        try items.append(a, .{ .node = .{ .rect = .{ .x = cx - bw / 2, .y = 4, .w = bw, .h = 32 }, .shape = .rect, .lines = lines, .titled = false } });
    }
    try items.appendSlice(a, row_items.items);

    const total_w = centers[count - 1] + box_widths[count - 1] / 2 + 8 + @as(f64, if (extra_right) 40 else 0);
    return .{ .kind = "sequence", .width = @ceil(total_w), .height = @ceil(y + 20), .items = items.items, .nodes = count, .edges = msg_count };
}
