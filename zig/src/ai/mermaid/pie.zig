//! Pie charts: wedges from -π/2 clockwise, legend to the right.
const std = @import("std");
const m = @import("mermaid.zig");
const text = @import("text.zig");

const ascii = std.ascii;
const mem = std.mem;

const Slice = struct { label: []const u8, value: f64 };

pub fn parsePie(a: mem.Allocator, header: []const u8, lines: []const []const u8) !?m.Diagram {
    var show_data = false;
    var title: []const u8 = "";
    var rem = text.trim(header[3..]);
    if (ascii.startsWithIgnoreCase(rem, "showdata")) {
        show_data = true;
        rem = text.trim(rem[8..]);
    }
    if (ascii.startsWithIgnoreCase(rem, "title ")) title = text.trim(rem[6..]);

    var slices: std.ArrayList(Slice) = .empty;
    for (lines) |line| {
        const t = text.trim(line);
        if (ascii.eqlIgnoreCase(t, "showdata")) {
            show_data = true;
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "title ")) {
            title = text.trim(t[6..]);
            continue;
        }
        const colon = mem.lastIndexOfScalar(u8, t, ':') orelse continue;
        const val = parseDouble(text.trim(t[colon + 1 ..])) orelse continue;
        if (!(val >= 0)) continue;
        const lbl = try text.cleanJoined(a, text.trim(t[0..colon]));
        if (lbl.len == 0 or slices.items.len >= m.max_nodes) return null;
        try slices.append(a, .{ .label = lbl, .value = val });
    }

    var sum: f64 = 0;
    for (slices.items) |s| sum += s.value;
    if (slices.items.len == 0 or !(sum > 0)) return null;

    const top: f64 = if (title.len == 0) 8 else 28;
    const center: m.Point = .{ .x = 100, .y = top + 100 };
    var items: std.ArrayList(m.Item) = .empty;

    if (title.len > 0) {
        try items.append(a, .{ .text = .{ .str = try text.cleanJoined(a, title), .at = .{ .x = 100, .y = 14 }, .bold = true, .muted = false } });
    }

    var angle: f64 = -std.math.pi / 2.0;
    for (slices.items, 0..) |s, i| {
        const sweep = (s.value / sum) * (2 * std.math.pi);
        try items.append(a, .{ .wedge = .{ .center = center, .radius = 90, .from = angle, .to = angle + sweep, .color = @intCast(i % 8) } });
        angle += sweep;
    }

    const rows_height: f64 = @floatFromInt(slices.items.len * 20);
    const legend_y = center.y - rows_height / 2;
    var max_legend: f64 = 0;
    for (slices.items, 0..) |s, i| {
        const pct = @round(s.value / sum * 100);
        const pct_int: i64 = if (std.math.isFinite(pct)) @intFromFloat(pct) else 0;
        const v = s.value;
        // ponytail: Swift traps converting whole values past Int.max; those print with one decimal here.
        const val_str = if (@rem(v, 1) == 0 and v < 9.0e18)
            try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(v))})
        else
            try oneDecimal(a, v);
        const str = if (show_data)
            try std.fmt.allocPrint(a, "{s}  {s} ({d}%)", .{ s.label, val_str, pct_int })
        else
            try std.fmt.allocPrint(a, "{s}  {d}%", .{ s.label, pct_int });
        const tw = text.textWidth(str, false, 12);
        max_legend = @max(max_legend, tw);
        const row_y = legend_y + @as(f64, @floatFromInt(i * 20));
        const color: i64 = @intCast(i % 8);
        try items.append(a, .{ .swatch = .{ .rect = .{ .x = 216, .y = row_y + 5, .w = 10, .h = 10 }, .color = color } });
        try items.append(a, .{ .text = .{ .str = str, .at = .{ .x = 232 + tw / 2, .y = row_y + 10 }, .bold = false, .muted = false } });
    }

    return .{
        .kind = "pie",
        .width = @ceil(216 + max_legend + 22),
        .height = @ceil(@max(200, rows_height) + top + 8),
        .items = items.items,
        .nodes = slices.items.len,
        .edges = 0,
    };
}

/// Swift's `Double(String)`: the whole string must be a number; Zig's parser
/// also takes `_` digit separators, which Swift rejects.
fn parseDouble(s: []const u8) ?f64 {
    if (mem.indexOfScalar(u8, s, '_') != null) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// `String(format: "%.1f", v)` for `v ≥ 0`: printf rounds the exact binary
/// value half-to-even (2.25 → "2.2"), where Zig's `{d:.1}` rounds half up.
fn oneDecimal(a: mem.Allocator, v: f64) ![]u8 {
    if (!(v < 0x1p53)) return std.fmt.allocPrint(a, "{d:.1}", .{v}); // whole numbers: nothing to round
    const bits: u64 = @bitCast(v);
    const biased: u64 = (bits >> 52) & 0x7FF;
    const frac: u128 = bits & ((1 << 52) - 1);
    // v = mant · 2^-shift, shift ≥ 0 below 2^53
    const mant = if (biased == 0) frac else frac | (1 << 52);
    const shift: u64 = 1075 - @max(biased, 1);
    const scaled = mant * 10;
    var tenths: u128 = 0;
    if (shift < 120) {
        tenths = scaled >> @intCast(shift);
        if (shift > 0) {
            const rem = scaled & ((@as(u128, 1) << @intCast(shift)) - 1);
            const half = @as(u128, 1) << @intCast(shift - 1);
            if (rem > half or (rem == half and tenths & 1 == 1)) tenths += 1;
        }
    }
    return std.fmt.allocPrint(a, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

test "one decimal rounds like printf" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Expected strings are Swift's `String(format: "%.1f", v)` output.
    const cases = [_][2][]const u8{
        .{ "2.2", "2.25" }, .{ "0.1", "0.15" }, .{ "0.3", "0.35" }, .{ "0.2", "0.25" }, .{ "0.5", "0.45" },
        .{ "1.1", "1.05" }, .{ "2.7", "2.675" }, .{ "42.5", "42.5" }, .{ "0.0", "0.04" }, .{ "1.0", "0.96" },
        .{ "0.0", "1e-300" }, .{ "4503599627370495.5", "4503599627370495.5" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[0], try oneDecimal(a, try std.fmt.parseFloat(f64, c[1])));
    }
}
