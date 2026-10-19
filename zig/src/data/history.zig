//! History engine: canonical URL identity (`strip("www.")`, credential removal,
//! root query/fragment normalization), `log1p(count) * exp(-days/30)` standing,
//! boundary-aware ranking (`rank`), autocomplete `offer`, `suggestions`,
//! `retitle`, `forgetHost`, `flush`, and the full HistoryRegression suite.
const std = @import("std");
const Store = @import("store.zig").Store;

pub const Visit = struct {
    url: []u8,
    key: []u8,
    title: []u8,
    count: i64,
    last: f64,
};

pub const Suggestion = struct {
    title: []const u8,
    url: []const u8,
    score: f64,
};

pub const History = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    visits: std.ArrayList(Visit) = .empty,
    indexed: bool = false,

    pub fn init(gpa: std.mem.Allocator, store: *const Store) History {
        return .{ .gpa = gpa, .store = store };
    }

    pub fn deinit(self: *History) void {
        self.clearMem();
        self.visits.deinit(self.gpa);
    }

    fn clearMem(self: *History) void {
        for (self.visits.items) |v| {
            self.gpa.free(v.url);
            self.gpa.free(v.key);
            self.gpa.free(v.title);
        }
        self.visits.clearRetainingCapacity();
    }

    pub fn ensureIndexed(self: *History) void {
        if (self.indexed) return;
        self.indexed = true;
        const data = self.store.read("history.json") orelse return;
        defer self.gpa.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch {
            self.store.quarantine("history.json");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .array) {
            self.store.quarantine("history.json");
            return;
        }
        var dirty = false;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const url_v = obj.get("url") orelse continue;
            if (url_v != .string) continue;
            const title_v = obj.get("title");
            const title_s = if (title_v != null and title_v.? == .string) title_v.?.string else "";
            const count_v = obj.get("count");
            const raw_count: i64 = if (count_v != null and count_v.? == .integer) count_v.?.integer else 1;
            const count: i64 = @min(@max(0, raw_count), 1_000_000);
            if (count != raw_count) dirty = true;
            const last_v = obj.get("last");
            const last: f64 = if (last_v != null and last_v.? == .float) last_v.?.float else if (last_v != null and last_v.? == .integer) @floatFromInt(last_v.?.integer) else 0;

            const clean_url = sanitizeUrl(self.gpa, url_v.string) orelse continue;
            defer self.gpa.free(clean_url);
            if (!std.mem.eql(u8, clean_url, url_v.string)) dirty = true;
            const canon_key = identity(self.gpa, clean_url) orelse continue;
            defer self.gpa.free(canon_key);
            if (obj.get("key")) |kv| {
                if (kv == .string and !std.mem.eql(u8, kv.string, canon_key)) dirty = true;
            }
            self.upsert(clean_url, canon_key, title_s, count, last, true);
        }
        if (dirty) self.flush();
    }

    fn upsert(self: *History, url: []const u8, key: []const u8, title: []const u8, count: i64, last: f64, merge_counts: bool) void {
        for (self.visits.items) |*v| {
            if (std.mem.eql(u8, v.key, key)) {
                if (last >= v.last) {
                    self.gpa.free(v.url);
                    v.url = self.gpa.dupe(u8, url) catch v.url;
                    v.last = last;
                    if (title.len > 0) {
                        self.gpa.free(v.title);
                        v.title = self.gpa.dupe(u8, title) catch v.title;
                    }
                } else if (v.title.len == 0 and title.len > 0) {
                    self.gpa.free(v.title);
                    v.title = self.gpa.dupe(u8, title) catch v.title;
                }
                v.count = if (merge_counts) @min(1_000_000, v.count + count) else @max(v.count, count);
                return;
            }
        }
        self.visits.append(self.gpa, .{
            .url = self.gpa.dupe(u8, url) catch return,
            .key = self.gpa.dupe(u8, key) catch return,
            .title = self.gpa.dupe(u8, title) catch return,
            .count = @min(1_000_000, @max(0, count)),
            .last = last,
        }) catch {};
    }

    pub fn record(self: *History, raw_url: []const u8, title: []const u8, now_s: f64) void {
        self.ensureIndexed();
        if (!isWebUrl(raw_url)) return;
        const clean_url = sanitizeUrl(self.gpa, raw_url) orelse return;
        defer self.gpa.free(clean_url);
        const key = identity(self.gpa, clean_url) orelse return;
        defer self.gpa.free(key);
        self.upsert(clean_url, key, title, 1, now_s, true);
    }

    pub fn take(self: *History, raw_url: []const u8, title: []const u8, count: i64, last: f64) void {
        self.ensureIndexed();
        if (!isWebUrl(raw_url)) return;
        const clean_url = sanitizeUrl(self.gpa, raw_url) orelse return;
        defer self.gpa.free(clean_url);
        const key = identity(self.gpa, clean_url) orelse return;
        defer self.gpa.free(key);
        self.upsert(clean_url, key, title, @max(0, count), last, false);
    }

    pub fn retitle(self: *History, raw_url: []const u8, title: []const u8) void {
        if (title.len == 0) return;
        const key = identity(self.gpa, raw_url) orelse return;
        defer self.gpa.free(key);
        for (self.visits.items) |*v| {
            if (std.mem.eql(u8, v.key, key)) {
                if (std.ascii.eqlIgnoreCase(v.title, title) and std.mem.eql(u8, v.title, title)) return;
                self.gpa.free(v.title);
                v.title = self.gpa.dupe(u8, title) catch return;
                return;
            }
        }
    }

    pub fn forgetHost(self: *History, host_in: []const u8) void {
        self.ensureIndexed();
        const want = stripWww(host_in);
        var i: usize = self.visits.items.len;
        while (i > 0) {
            i -= 1;
            const v = self.visits.items[i];
            const h = hostOfKey(v.key);
            if (std.ascii.eqlIgnoreCase(h, want)) {
                self.gpa.free(v.url);
                self.gpa.free(v.key);
                self.gpa.free(v.title);
                _ = self.visits.orderedRemove(i);
            }
        }
        self.flush();
    }

    pub fn clear(self: *History) void {
        self.clearMem();
        self.indexed = true;
        self.flush();
    }

    pub fn flush(self: *History) void {
        if (!self.indexed) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "[") catch return;
        for (self.visits.items, 0..) |v, idx| {
            if (idx > 0) out.appendSlice(self.gpa, ",") catch return;
            out.appendSlice(self.gpa, "{\"url\":") catch return;
            appendJsonStr(&out, self.gpa, v.url);
            out.appendSlice(self.gpa, ",\"key\":") catch return;
            appendJsonStr(&out, self.gpa, v.key);
            out.appendSlice(self.gpa, ",\"title\":") catch return;
            appendJsonStr(&out, self.gpa, v.title);
            const tail = std.fmt.allocPrint(self.gpa, ",\"count\":{d},\"last\":{d:.3}}}", .{ v.count, v.last }) catch return;
            defer self.gpa.free(tail);
            out.appendSlice(self.gpa, tail) catch return;
        }
        out.appendSlice(self.gpa, "]") catch return;
        self.store.writeAtomic("history.json", out.items);
    }

    /// Inline address bar autocomplete: returns the rest of the best-matching
    /// visited host or path (stripping leading `www.` so typing `ex` offers `example.com`).
    pub fn offer(self: *History, typed: []const u8, now_s: f64) ?[]const u8 {
        self.ensureIndexed();
        const q = std.mem.trim(u8, typed, " \t\r\n");
        if (q.len == 0 or std.mem.indexOfScalar(u8, q, ' ') != null) return null;
        var best_key: ?[]const u8 = null;
        var best_score: f64 = -1e9;
        for (self.visits.items) |v| {
            if (v.count <= 0) continue;
            if (asciiStartsWithIgnoreCase(v.key, q)) {
                const sc = scoreVisit(v, q, now_s);
                if (sc > best_score) {
                    best_score = sc;
                    best_key = v.key;
                }
            }
        }
        const k = best_key orelse return null;
        if (std.mem.indexOfScalar(u8, q, '/') == null) {
            if (std.mem.indexOfScalar(u8, k, '/')) |slash| {
                return k[0..slash];
            }
        }
        return k;
    }

    pub fn suggestions(self: *History, alloc: std.mem.Allocator, query: []const u8, limit: usize, now_s: f64) []Suggestion {
        self.ensureIndexed();
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0) return &.{};
        var list: std.ArrayList(Suggestion) = .empty;
        for (self.visits.items) |v| {
            if (v.count <= 0) continue;
            const r = rankVisit(v, q);
            if (r == null) continue;
            const sc = standing(v.count, v.last, now_s) + r.? + (if (isHomepageKey(v.key)) @as(f64, 5) else 0);
            // Dedup by case-insensitive key/title
            var dup = false;
            for (list.items) |*existing| {
                if (std.ascii.eqlIgnoreCase(existing.url, v.url) or (v.title.len > 0 and std.ascii.eqlIgnoreCase(existing.title, v.title))) {
                    if (sc > existing.score) existing.* = .{ .title = v.title, .url = v.url, .score = sc };
                    dup = true;
                    break;
                }
            }
            if (!dup) list.append(alloc, .{ .title = v.title, .url = v.url, .score = sc }) catch {};
        }
        std.mem.sort(Suggestion, list.items, {}, struct {
            fn lt(_: void, a: Suggestion, b: Suggestion) bool {
                return a.score > b.score;
            }
        }.lt);
        if (list.items.len > limit) list.items.len = limit;
        return list.toOwnedSlice(alloc) catch &.{};
    }
};

pub fn isWebUrl(u: []const u8) bool {
    return asciiStartsWithIgnoreCase(u, "https://") or asciiStartsWithIgnoreCase(u, "http://");
}

pub fn stripWww(h: []const u8) []const u8 {
    if (h.len > 4 and asciiStartsWithIgnoreCase(h, "www.")) return h[4..];
    return h;
}

/// Removes user:pass@ credentials from a URL before it ever touches memory or disk.
pub fn sanitizeUrl(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const sch_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const scheme = raw[0..sch_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    const rest = raw[sch_end + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..auth_end];
    const host_port = if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth[at + 1 ..] else auth;
    if (host_port.len == 0) return null;
    const tail = if (auth_end < rest.len) rest[auth_end..] else "/";
    var out = std.ArrayList(u8).empty;
    for (scheme) |ch| out.append(gpa, std.ascii.toLower(ch)) catch return null;
    out.appendSlice(gpa, "://") catch return null;
    for (host_port) |ch| out.append(gpa, std.ascii.toLower(ch)) catch return null;
    out.appendSlice(gpa, tail) catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

/// Canonical identity key: lowercased `host[:port]` (without `www.`) + path + query + fragment,
/// except root `/` with no path keeps only `host[:port]` (unless query/fragment on non-root or root with query).
pub fn identity(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const sch_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const rest = raw[sch_end + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..auth_end];
    const host_port_raw = if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth[at + 1 ..] else auth;
    const host_port = stripWww(host_port_raw);
    if (host_port.len == 0) return null;
    var tail = if (auth_end < rest.len) rest[auth_end..] else "";
    if (std.mem.eql(u8, tail, "/")) tail = "";
    var out = std.ArrayList(u8).empty;
    for (host_port) |ch| out.append(gpa, std.ascii.toLower(ch)) catch return null;
    if (tail.len > 0) {
        if (tail[0] != '/') out.append(gpa, '/') catch return null;
        out.appendSlice(gpa, tail) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn hostOfKey(key: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, key, "/:?#") orelse key.len;
    return key[0..end];
}

fn isHomepageKey(key: []const u8) bool {
    return std.mem.indexOfScalar(u8, key, '/') == null;
}

fn standing(count: i64, last: f64, now_s: f64) f64 {
    const c_f: f64 = @floatFromInt(@max(0, count));
    const days = @max(0.0, (now_s - last) / 86_400.0);
    return std.math.log1p(c_f) * @exp(-days / 30.0) * 15.0;
}

pub fn rankVisit(v: Visit, q: []const u8) ?f64 {
    if (asciiStartsWithIgnoreCase(v.key, q)) return 100;
    // Subdomain boundary (`docs.example.com` for `example`)
    const host = hostOfKey(v.key);
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, host, pos, '.')) |dot| {
        const after = host[dot + 1 ..];
        if (asciiStartsWithIgnoreCase(after, q)) {
            // If `after` has no dot left, it's just the TLD (`.com`): penalize unless full host match
            if (std.mem.indexOfScalar(u8, after, '.') == null) return -15;
            return 85;
        }
        pos = dot + 1;
    }
    if (asciiStartsWithIgnoreCase(v.title, q)) return 70;
    if (wordBoundaryMatch(v.title, q) or wordBoundaryMatch(v.key, q)) return 60;
    if (asciiContainsIgnoreCase(v.title, q) or asciiContainsIgnoreCase(v.key, q)) return 40;
    return null;
}

fn scoreVisit(v: Visit, q: []const u8, now_s: f64) f64 {
    const r = rankVisit(v, q) orelse -1000;
    return standing(v.count, v.last, now_s) + r + (if (isHomepageKey(v.key)) @as(f64, 5) else 0);
}

fn asciiStartsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn asciiContainsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn wordBoundaryMatch(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len or needle.len == 0) return false;
    var i: usize = 1;
    while (i + needle.len <= hay.len) : (i += 1) {
        const prev = hay[i - 1];
        if (!std.ascii.isAlphanumeric(prev) and std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn appendJsonStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    out.append(gpa, '"') catch return;
    for (s) |ch| {
        switch (ch) {
            '"' => out.appendSlice(gpa, "\\\"") catch return,
            '\\' => out.appendSlice(gpa, "\\\\") catch return,
            '\n' => out.appendSlice(gpa, "\\n") catch return,
            '\r' => out.appendSlice(gpa, "\\r") catch return,
            '\t' => out.appendSlice(gpa, "\\t") catch return,
            else => out.append(gpa, ch) catch return,
        }
    }
    out.append(gpa, '"') catch return;
}

test "HistoryRegression: canonical identity, credentials, ranking, and flush" {
    const gpa = std.testing.allocator;
    var store = try Store.init(gpa, "/tmp/kea-zig-hist-test", null);
    defer store.deinit();

    var h = History.init(gpa, &store);
    defer h.deinit();
    h.indexed = true;

    // 1. Canonical identity keeps port, query, and fragment
    h.record("https://www.Example.com:8080/Path?a=1#frag", "Port One", 1000);
    h.record("https://example.com:9090/Path?a=1#frag", "Port Two", 1001);
    try std.testing.expectEqual(@as(usize, 2), h.visits.items.len);

    // 2. Credentials never reach memory or disk
    h.record("https://user:secretPass123@secure.example.org/vault", "Vault", 1002);
    h.flush();
    const raw_json = store.read("history.json").?;
    defer gpa.free(raw_json);
    try std.testing.expect(std.mem.indexOf(u8, raw_json, "secretPass123") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw_json, "https://secure.example.org/vault") != null);

    // 3. Completion finishes www sites without www
    h.record("https://www.wikipedia.org/wiki/Zig", "Zig Wiki", 1005);
    const off = h.offer("wiki", 1005).?;
    try std.testing.expectEqualStrings("wikipedia.org", off);

    // 4. Ranking prefers prefix > subdomain > word boundary > TLD
    const v_prefix: Visit = .{ .url = @constCast("https://com.example.org"), .key = @constCast("com.example.org"), .title = @constCast("Com"), .count = 2, .last = 1000 };
    const v_tld: Visit = .{ .url = @constCast("https://other.com"), .key = @constCast("other.com"), .title = @constCast("Other"), .count = 2, .last = 1000 };
    try std.testing.expect(rankVisit(v_prefix, "com").? > rankVisit(v_tld, "com").?);
}
