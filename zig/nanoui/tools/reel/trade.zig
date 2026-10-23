//! nanotrade's market, made up: NVDA's candles for each range (a day, a
//! week, a month, a year), seeded so every render of the reel is the same,
//! live ticks that move the last candle, and a watchlist whose changes
//! reorder it. None of it is real data.
const std = @import("std");

pub const candles = 56;

pub const Candle = struct { open: f32, high: f32, low: f32, close: f32, volume: f32 };

pub const ranges = [_][]const u8{ "1D", "1W", "1M", "1Y" };

pub const Symbol = struct { ticker: []const u8, name: []const u8, price: f32, change: f32 };

pub const Market = struct {
    series: [ranges.len][candles]Candle = undefined,
    /// NVDA's last price, and where the day opened.
    price: f32 = 0,
    open: f32 = 0,
    watch: [6]Symbol = .{
        .{ .ticker = "NVDA", .name = "NVIDIA", .price = 0, .change = 0 },
        .{ .ticker = "AAPL", .name = "Apple", .price = 231.4, .change = 0.62 },
        .{ .ticker = "MSFT", .name = "Microsoft", .price = 438.9, .change = -0.31 },
        .{ .ticker = "AMD", .name = "AMD", .price = 162.7, .change = 1.84 },
        .{ .ticker = "TSLA", .name = "Tesla", .price = 248.2, .change = -1.12 },
        .{ .ticker = "META", .name = "Meta", .price = 591.3, .change = 0.27 },
    },
    rng: std.Random.DefaultPrng = .init(7),

    pub fn init() Market {
        var m: Market = .{};
        // Each range: a walk from its start to today's price, noisier the
        // longer it spans.
        const spans = [_][3]f32{ .{ 178.6, 0.55, 0.0 }, .{ 171.0, 1.6, 0.25 }, .{ 152.0, 3.2, 0.6 }, .{ 96.0, 5.5, 1.5 } };
        for (spans, 0..) |sp, r| {
            var prng = std.Random.DefaultPrng.init(100 + r);
            const rnd = prng.random();
            var p: f32 = sp[0];
            for (0..candles) |i| {
                const drift = (182.4 - p) / @as(f32, @floatFromInt(candles - i)) + sp[2] * 0.1;
                const o = p;
                const c = o + drift + (rnd.float(f32) - 0.5) * 2 * sp[1];
                const hi = @max(o, c) + rnd.float(f32) * sp[1] * 0.8;
                const lo = @min(o, c) - rnd.float(f32) * sp[1] * 0.8;
                m.series[r][i] = .{ .open = o, .high = hi, .low = lo, .close = c, .volume = 0.3 + rnd.float(f32) * 0.7 };
                p = c;
            }
        }
        m.price = m.series[0][candles - 1].close;
        // Every range ends at today's price.
        for (m.series[1..]) |*s| {
            const last = &s[candles - 1];
            last.close = m.price;
            last.high = @max(last.high, m.price);
            last.low = @min(last.low, m.price);
        }
        m.open = m.series[0][0].open;
        m.watch[0].price = m.price;
        m.watch[0].change = (m.price - m.open) / m.open * 100;
        return m;
    }

    /// A live tick: NVDA moves, the day's last candle with it, and the
    /// others drift. `bias` leans the move up or down.
    pub fn tick(m: *Market, bias: f32) void {
        const rnd = m.rng.random();
        m.price += (rnd.float(f32) - 0.5) * 0.9 + bias;
        for (&m.series) |*s| {
            const last = &s[candles - 1];
            last.close = m.price;
            last.high = @max(last.high, m.price);
            last.low = @min(last.low, m.price);
            last.volume = @min(1, last.volume + 0.02);
        }
        m.watch[0].price = m.price;
        m.watch[0].change = (m.price - m.open) / m.open * 100;
        for (m.watch[1..]) |*w| {
            const d = (rnd.float(f32) - 0.5) * 0.004;
            w.price *= 1 + d;
            w.change += d * 100;
        }
    }

    /// The watchlist's tickers, biggest gain first.
    pub fn byChange(m: *const Market, out: *[6]usize) void {
        for (out, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, out, m, struct {
            fn gt(mk: *const Market, a: usize, b: usize) bool {
                return mk.watch[a].change > mk.watch[b].change;
            }
        }.gt);
    }

    /// The low and high of range `r`, with some room.
    pub fn bounds(m: *const Market, r: usize) [2]f32 {
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (m.series[r]) |c| {
            lo = @min(lo, c.low);
            hi = @max(hi, c.high);
        }
        const pad = (hi - lo) * 0.08;
        return .{ lo - pad, hi + pad };
    }
};

test "the ranges end at today's price, and ticks move the last candle" {
    var m = Market.init();
    for (m.series) |s| try std.testing.expectApproxEqAbs(m.price, s[candles - 1].close, 1e-3);
    m.tick(1);
    try std.testing.expectEqual(m.price, m.series[2][candles - 1].close);
    var order: [6]usize = undefined;
    m.byChange(&order);
    try std.testing.expect(m.watch[order[0]].change >= m.watch[order[5]].change);
}
