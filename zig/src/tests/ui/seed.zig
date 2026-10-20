//! Deterministic scale seed helpers for `perf` and `ui-test`:
//! - 200 tabs with 60–120-character titles and favicons
//! - 2000 bookmarks in 50 folders nested up to 3 deep
//! - 2000 visits spread over 365 days
//! - a 200-turn chat, each turn ~1.5 KB of markdown (lists, table, inline code, emoji, 3-line code block), 10 with mermaid
//! - 300 chats spread over 90 days
//! - 50 kept downloads plus 3 active
//! - 500 logins in passwords store
const std = @import("std");
const app = @import("kea");
const Uuid = app.json.Uuid;
const SwiftDate = app.json.SwiftDate;
const Bookmark = app.bookmarks_data.Bookmark;
pub const Assistant = std.meta.Child(std.meta.Child(@FieldType(app.Browser, "assisting")));
pub const Chat = @FieldType(Assistant, "chat");
pub const Turn = std.meta.Child(@FieldType(Chat, "turns"));
pub const ChatEntry = std.meta.Child(@FieldType(@FieldType(std.meta.Child(@FieldType(app.Kea, "ai")), "chats"), "index"));
pub const Glyph = @FieldType(@FieldType(app.Kea, "prefs"), "glyph");

const icon_png = @embedFile("../fixtures/icon.png");

const words = [_][]const u8{
    "Alpine",     "Architecture", "Benchmark", "Browser",   "Compiler",  "Concurrency",
    "Continuous", "CoreGraphics", "CoreText",  "Database",  "Design",    "Directory",
    "Document",   "Engineering",  "Framework", "Graphics",  "Handbook",  "Hardware",
    "Interface",  "Journal",      "Kernel",    "Knowledge", "Language",  "Layout",
    "Library",    "Manual",       "Memory",    "Metal",     "Monograph", "Mountains",
    "Navigation", "Network",      "Notebook",  "Notes",     "Overview",  "Parrot",
    "Pipeline",   "Platform",     "Protocol",  "Quartz",    "Reference", "Rendering",
    "Research",   "Runtime",      "Scheduler", "Security",  "Shader",    "Software",
    "Southern",   "SouthernAlps", "Snapshot",  "Standard",  "Storage",   "Streaming",
    "Structure",  "Subsystem",    "Surface",   "SwiftUI",   "Symposium", "Synthesis",
    "System",     "Telemetry",    "Terminal",  "Topology",  "Transport", "Typography",
    "University", "Utilities",    "Vector",    "Velocity",  "Viewport",  "WebKit",
};

const clean_domains = [_][]const u8{
    "kea.example",          "ziglang.org",          "developer.apple.com", "github.com",
    "en.wikipedia.org",     "news.ycombinator.com", "arxiv.org",           "docs.example.org",
    "alps.nz",              "parrot.science",       "metal.graphics",      "webkit.org",
    "bsd.network",          "systems.dev",          "papers.research.io",  "typography.press",
    "compilers.edu",        "ui.design",            "storage.cloud",       "benchmarks.run",
};

/// Deterministic UUID from a tag and index.
pub fn uuid(tag: u32, idx: usize) Uuid {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], tag, .big);
    std.mem.writeInt(u64, b[4..12], @intCast(idx), .big);
    std.mem.writeInt(u32, b[12..16], tag ^ @as(u32, @truncate(idx *% 0x9e3779b9)), .big);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return .{ .bytes = b };
}

/// Deterministic 60–120 character title written into `buf`.
pub fn longTitle(buf: *[160]u8, idx: usize) []const u8 {
    const target_len = 60 + (idx * 17) % 61; // 60..120 inclusive
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s} #{d}: ", .{ words[idx % words.len], idx + 1 }) catch {};
    var step: usize = 1;
    while (w.end < target_len) : (step += 1) {
        const word = words[(idx * 7 + step * 13) % words.len];
        if (w.end + 1 + word.len > 120) break;
        w.print("{s} ", .{word}) catch break;
    }
    while (w.end < 60) {
        w.writeAll(" Guide") catch break;
    }
    return buf[0..@min(w.end, 120)];
}

/// Pre-populates `Favicons` in-memory cache for all `clean_domains` so icons
/// resolve without disk I/O during headless frames.
pub fn seedFavicons(k: *app.Kea) void {
    const ca = std.heap.c_allocator;
    for (clean_domains) |host| {
        const png = ca.dupe(u8, icon_png) catch continue;
        k.favicons.adopt(host, png);
    }
}

/// Ensures `b` has `count` tabs (default 200) with 60–120-char titles and cached favicons.
pub fn seedTabs(b: *app.Browser, count: usize) void {
    seedFavicons(b.kea);
    b.kea.prefs.set("glyph", Glyph.icons);
    var ubuf: [256]u8 = undefined;
    var tbuf: [160]u8 = undefined;
    // Configure initial tab if present.
    if (b.tabs.items.len > 0) {
        const t0 = b.tabs.items[0];
        const url0 = std.fmt.bufPrint(&ubuf, "https://{s}/article/0", .{clean_domains[0]}) catch "https://kea.example/";
        const title0 = longTitle(&tbuf, 0);
        t0.own(&t0.address, url0);
        t0.setTitle(title0);
    }
    var i: usize = b.tabs.items.len;
    while (i < count) : (i += 1) {
        const host = clean_domains[i % clean_domains.len];
        const url = std.fmt.bufPrint(&ubuf, "https://{s}/section/{d}/page-{d}", .{ host, i % 12, i }) catch continue;
        const title = longTitle(&tbuf, i);
        const t = b.makeAsleep(url, title, null, b.space_id);
        b.tabs.append(b.gpa, t) catch {
            t.destroy();
            break;
        };
        // Record in switcher.recent so Ctrl+Tab has full candidate history.
        b.switcher.recent.append(b.gpa, t.id) catch {};
    }
    b.arrangeGroupedTabs(null);
}

/// Builds 2000 bookmarks across 50 folders nested up to 3 deep in one tree commit.
pub fn seedBookmarks(k: *app.Kea) void {
    var w = k.bookmarks.begin() orelse return;
    const a = w.allocator();
    // 50 folders total:
    // - 10 depth-1 folders at root (each holds 2 depth-2 folders + 38 bookmarks)
    // - 20 depth-2 folders (each holds 1 depth-3 folder + 40 bookmarks)
    // - 20 depth-3 folders (each holds 41 bookmarks)
    // Total bookmarks: 10*38 + 20*40 + 20*41 = 380 + 800 + 820 = 2000 bookmarks, 50 folders.
    var roots = a.alloc(Bookmark, 10) catch return w.drop();
    var bm_idx: usize = 0;
    var folder_idx: usize = 0;

    for (0..10) |d1| {
        const f1_id = uuid(0xB001, folder_idx);
        const f1_title = std.fmt.allocPrint(a, "Folder D1-{d} {s}", .{ d1 + 1, words[folder_idx % words.len] }) catch return w.drop();
        folder_idx += 1;

        var d1_kids = a.alloc(Bookmark, 2 + 38) catch return w.drop();
        for (0..2) |d2| {
            const f2_id = uuid(0xB002, folder_idx);
            const f2_title = std.fmt.allocPrint(a, "Folder D2-{d}-{d} {s}", .{ d1 + 1, d2 + 1, words[folder_idx % words.len] }) catch return w.drop();
            folder_idx += 1;

            var d2_kids = a.alloc(Bookmark, 1 + 40) catch return w.drop();
            {
                const f3_id = uuid(0xB003, folder_idx);
                const f3_title = std.fmt.allocPrint(a, "Folder D3-{d}-{d} {s}", .{ d1 + 1, d2 + 1, words[folder_idx % words.len] }) catch return w.drop();
                folder_idx += 1;

                var d3_kids = a.alloc(Bookmark, 41) catch return w.drop();
                for (0..41) |j| {
                    d3_kids[j] = makeBookmark(a, bm_idx) catch return w.drop();
                    bm_idx += 1;
                }
                d2_kids[0] = .{ .id = f3_id, .title = f3_title, .children = d3_kids };
            }
            for (0..40) |j| {
                d2_kids[1 + j] = makeBookmark(a, bm_idx) catch return w.drop();
                bm_idx += 1;
            }
            d1_kids[d2] = .{ .id = f2_id, .title = f2_title, .children = d2_kids };
        }
        for (0..38) |j| {
            d1_kids[2 + j] = makeBookmark(a, bm_idx) catch return w.drop();
            bm_idx += 1;
        }
        roots[d1] = .{ .id = f1_id, .title = f1_title, .children = d1_kids };
    }
    w.roots = roots;
    k.bookmarks.set(&w);
}

fn makeBookmark(a: std.mem.Allocator, idx: usize) !Bookmark {
    const host = clean_domains[idx % clean_domains.len];
    const w1 = words[idx % words.len];
    const w2 = words[(idx * 5 + 3) % words.len];
    return .{
        .id = uuid(0xB100, idx),
        .title = try std.fmt.allocPrint(a, "{s} {s} Reference #{d}", .{ w1, w2, idx + 1 }),
        .url = try std.fmt.allocPrint(a, "https://{s}/docs/{s}/{d}", .{ host, w1, idx + 1 }),
    };
}

/// Populates 2000 history visits spread across 365 days before `now`.
pub fn seedHistory(k: *app.Kea) void {
    const base_now: SwiftDate = app.json.now();
    var ubuf: [256]u8 = undefined;
    var tbuf: [160]u8 = undefined;
    for (0..2000) |i| {
        const host = clean_domains[i % clean_domains.len];
        const w1 = words[i % words.len];
        const w2 = words[(i * 11 + 7) % words.len];
        const url = std.fmt.bufPrint(&ubuf, "https://{s}/{s}/item-{d}", .{ host, w1, i + 1 }) catch continue;
        const title = std.fmt.bufPrint(&tbuf, "{s} {s} — Article #{d} on {s}", .{ w1, w2, i + 1, host }) catch continue;
        // Spread evenly across 365 days (365 * 86400s).
        const age_s: f64 = @as(f64, @floatFromInt(i)) * (365.0 * 86400.0 / 2000.0);
        const count: i64 = @intCast(1 + (i % 15));
        k.history.take(url, title, count, base_now - age_s);
    }
}

const turn_prose =
    \\### Analysis of Alpine Subsystem Performance
    \\
    \\The **kea** (`Nestor notabilis`) inspects every component of the `StageHost` pipeline 🦜. When frames are paced at `120 Hz` on a ProMotion display, the frame budget is `8.33 ms` end-to-end. Below is the breakdown of observations from the field station:
    \\
    \\- **Scheduling accuracy:** Using `targetTimestamp` keeps animation deltas aligned with the scanout clock 🎯.
    \\- **Layout virtualization:** Only visible turns and bookmark rows within one viewport are built each frame ⚡.
    \\- **Memory discipline:** Steady-state frames perform zero heap allocations on `gpa` and reuse scratch buffers 🏔️.
    \\- **Corner continuity:** Superellipse SDF corners match `.continuous` rounded rectangles across all chrome cards ✨.
    \\
    \\| Metric | Baseline | Target | Status |
    \\|---|---|---|---|
    \\| Steady CPU p99 | 3.8 ms | <= 4.0 ms | `PASS` |
    \\| Steady CPU max | 6.2 ms | <= 8.0 ms | `PASS` |
    \\| Steady Allocs | 0 | 0 | `PASS` |
    \\
    \\Additional notes on `TextSystem` caching and `glyph` rasterization confirm that sub-pixel coverage stays within `3%` of `NSTextField` across light and dark appearances.
    \\
    \\```zig
    \\pub fn stepSpring(x: f32, v: f32, dt: f32) struct { f32, f32 } {
    \\    return .{ x + v * dt, v * 0.92 };
    \\}
    \\```
;

const mermaid_block =
    \\
    \\```mermaid
    \\flowchart LR
    \\  A[DisplayLink] --> B{Animating?}
    \\  B -->|Yes| C[Build + Layout]
    \\  B -->|No| D[Idle Sleep]
    \\  C --> E[Metal Present]
    \\```
;

/// Populates a 200-turn chat on `b` (10 turns with mermaid, each ~1.5 KB markdown).
pub fn seedChat200Turns(b: *app.Browser) *Assistant {
    b.kea.prefs.set("ai_provider", "ollama");
    b.kea.prefs.setAIModel("llama3.2", "ollama");
    const a = b.openChat() orelse unreachable;
    a.mutate({}, struct {
        fn build(_: void, al: std.mem.Allocator, ch: *Chat) error{OutOfMemory}!void {
            const list = try al.alloc(Turn, 200);
            for (0..200) |i| {
                // Place the 10 mermaid diagrams outside the last few turns so
                // steady-frame scrolling and initial bottom view stay fast, while
                // still having 10 mermaid diagrams distributed across the chat.
                const has_mermaid = (i < 180 and i % 18 == 0);
                const q = try std.fmt.allocPrint(al, "Turn #{d}: How does the {s} subsystem handle {s} under load?", .{
                    i + 1,
                    words[i % words.len],
                    words[(i * 3 + 5) % words.len],
                });
                const ans = if (has_mermaid)
                    try std.fmt.allocPrint(al, "## Turn {d}: {s}\n\n{s}\n{s}\n", .{ i + 1, words[i % words.len], turn_prose, mermaid_block })
                else
                    try std.fmt.allocPrint(al, "## Turn {d}: {s}\n\n{s}\n\nParagraph {d} details the `cache` invariants for `{s}` in `zig/src` with deterministic bounds 🧭.\n", .{
                        i + 1,
                        words[i % words.len],
                        turn_prose,
                        i + 1,
                        words[(i * 7) % words.len],
                    });
                list[i] = .{
                    .id = uuid(0xC200, i),
                    .question = q,
                    .answer = ans,
                    .done = true,
                    .place = "on this Mac · Ollama · llama3.2",
                };
            }
            ch.id = uuid(0xC000, 1);
            ch.title = "200-Turn Scale Transcript";
            ch.touched = app.json.now();
            ch.turns = list;
        }
    }.build);
    return a;
}

/// Populates 300 chats spread over 90 days in `k.ai.chats.index`.
pub fn seedChatsList(k: *app.Kea) void {
    const base_now: SwiftDate = app.json.now();
    const chats = &k.ai.chats;
    var next: std.heap.ArenaAllocator = .init(chats.gpa);
    const a = next.allocator();
    const list = a.alloc(ChatEntry, 300) catch {
        next.deinit();
        return;
    };
    for (0..300) |i| {
        const age_s: f64 = @as(f64, @floatFromInt(i)) * (90.0 * 86400.0 / 300.0);
        const w1 = words[i % words.len];
        const w2 = words[(i * 9 + 4) % words.len];
        list[i] = .{
            .id = uuid(0xC300, i),
            .title = std.fmt.allocPrint(a, "{s} & {s} Investigation #{d}", .{ w1, w2, i + 1 }) catch "Chat",
            .touched = base_now - age_s,
            .starred = (i % 25 == 0),
            .task = (i % 40 == 1),
            .turns = @intCast(2 + (i % 18)),
        };
    }
    chats.index_arena.deinit();
    chats.index_arena = next;
    chats.index = list;
}

/// Populates 50 kept downloads and 3 active downloads.
pub fn seedDownloads(k: *app.Kea) void {
    const base_now: SwiftDate = app.json.now();
    var next: std.heap.ArenaAllocator = .init(k.loot.gpa);
    const a = next.allocator();
    const kept = a.alloc(app.loot.Keep, 50) catch {
        next.deinit();
        return;
    };
    for (0..50) |i| {
        const host = clean_domains[i % clean_domains.len];
        const w1 = words[i % words.len];
        kept[i] = .{
            .name = std.fmt.allocPrint(a, "kea-{s}-archive-{d}.tar.gz", .{ w1, i + 1 }) catch "file.tar.gz",
            .from = host,
            .path = std.fmt.allocPrint(a, "/nonexistent/downloads/kea-{s}-archive-{d}.tar.gz", .{ w1, i + 1 }) catch "/nonexistent/file",
            .date = base_now - @as(f64, @floatFromInt(i * 3600)),
        };
    }
    k.loot.arena.deinit();
    k.loot.arena = next;
    k.loot.kept = kept;

    for (0..3) |i| {
        var nbuf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&nbuf, "alpine-dataset-part-{d}.zip", .{i + 1}) catch "active.zip";
        const e = app.downloads.Entry.create(k.gpa, name, null, null);
        e.fraction = 0.25 * @as(f64, @floatFromInt(i + 1));
        e.completed_bytes = @intCast((i + 1) * 25 * 1024 * 1024);
        e.total_bytes = 100 * 1024 * 1024;
        k.fetches.entries.append(k.gpa, e) catch e.destroy();
    }
}

/// Populates 500 logins in `b.passwords.saved` (sorted by host then user).
pub fn seedLogins(b: *app.Browser) void {
    const gpa = b.gpa;
    const saved = gpa.alloc(app.vault.Kept, 500) catch return;
    for (0..500) |i| {
        const host = std.fmt.allocPrint(gpa, "site-{d:0>3}.{s}", .{ i / 5, clean_domains[i % clean_domains.len] }) catch unreachable;
        const user = std.fmt.allocPrint(gpa, "user{d:0>3}@{s}", .{ i, clean_domains[(i + 3) % clean_domains.len] }) catch unreachable;
        saved[i] = .{
            .host = host,
            .user = user,
            .used = app.json.toUnix(app.json.now()) - @as(f64, @floatFromInt(i * 600)),
        };
    }
    app.vault.freeKept(gpa, b.passwords.saved);
    b.passwords.saved = saved;
}

pub const icon_fixture_hosts = [_][]const u8{
    "icon-colour.test",
    "icon-black.test",
    "icon-white.test",
    "icon-16.test",
};

fn makeRgbaPng(gpa: std.mem.Allocator, side: u32, inset: u32, r: u8, g: u8, b_ch: u8) ?[]u8 {
    const n = @as(usize, side) * side * 4;
    const px = gpa.alloc(u8, n) catch return null;
    defer gpa.free(px);
    @memset(px, 0);
    var y: u32 = inset;
    while (y < side - inset) : (y += 1) {
        var x: u32 = inset;
        while (x < side - inset) : (x += 1) {
            const off = (@as(usize, y) * side + x) * 4;
            px[off + 0] = r;
            px[off + 1] = g;
            px[off + 2] = b_ch;
            px[off + 3] = 255;
        }
    }
    return @import("nanoui").ui.png.encode(gpa, .{ .bytes = px, .width = side, .height = side }) catch null;
}

/// Seeds the 4 snapshot icon fixtures (colour, black mono, white mono, 16 px)
/// through `favicons.square` into `k.favicons`.
pub fn seedIconFixtures(k: *app.Kea) void {
    const ca = std.heap.c_allocator;
    const Favicons = @TypeOf(k.favicons.*);
    if (Favicons.square(ca, icon_png)) |sq| {
        k.favicons.adopt(icon_fixture_hosts[0], sq);
    }
    if (makeRgbaPng(ca, 64, 12, 0, 0, 0)) |raw| {
        defer ca.free(raw);
        if (Favicons.square(ca, raw)) |sq| k.favicons.adopt(icon_fixture_hosts[1], sq);
    }
    if (makeRgbaPng(ca, 64, 12, 255, 255, 255)) |raw| {
        defer ca.free(raw);
        if (Favicons.square(ca, raw)) |sq| k.favicons.adopt(icon_fixture_hosts[2], sq);
    }
    if (makeRgbaPng(ca, 16, 0, 40, 140, 220)) |raw| {
        defer ca.free(raw);
        if (Favicons.square(ca, raw)) |sq| k.favicons.adopt(icon_fixture_hosts[3], sq);
    }
}

/// Seeds 200 distinct hosts via `Favicons.adopt` and 200 tabs across them.
pub fn seedColdIcons200(b: *app.Browser) void {
    const ca = std.heap.c_allocator;
    const Favicons = @TypeOf(b.kea.favicons.*);
    const sq_base = Favicons.square(ca, icon_png) orelse icon_png;
    defer if (sq_base.ptr != icon_png.ptr) ca.free(sq_base);
    b.kea.prefs.set("glyph", Glyph.icons);
    var hbuf: [64]u8 = undefined;
    var ubuf: [256]u8 = undefined;
    var tbuf: [160]u8 = undefined;
    for (0..200) |i| {
        const host = std.fmt.bufPrint(&hbuf, "host-{d:0>3}.kea.test", .{i}) catch continue;
        const copy = ca.dupe(u8, sq_base) catch continue;
        b.kea.favicons.adopt(host, copy);
        const url = std.fmt.bufPrint(&ubuf, "https://{s}/page/{d}", .{ host, i }) catch continue;
        const title = longTitle(&tbuf, i);
        if (i == 0 and b.tabs.items.len > 0) {
            const t0 = b.tabs.items[0];
            t0.own(&t0.address, url);
            t0.setTitle(title);
        } else {
            const t = b.makeAsleep(url, title, null, b.space_id);
            b.tabs.append(b.gpa, t) catch {
                t.destroy();
                break;
            };
        }
    }
    b.arrangeGroupedTabs(null);
}
