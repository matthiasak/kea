//! Bookmarks (`bookmarks.json`) and SiteSearch (`sitesearch.json`):
//! folder/item tree, multi-word case-insensitive search, deduplication,
//! and learned OpenSearch site templates (`@` chip in the Omnibox).
const std = @import("std");
const Store = @import("store.zig").Store;

pub const Bookmark = struct {
    id: u64,
    title: []u8,
    url: ?[]u8 = null,
    parent_id: u64 = 0, // 0 = root
};

pub const SiteEntry = struct {
    host: []u8,
    name: []u8,
    template: []u8,
};

pub const Bookmarks = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    items: std.ArrayList(Bookmark) = .empty,
    sites: std.ArrayList(SiteEntry) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, store: *const Store) Bookmarks {
        var b: Bookmarks = .{ .gpa = gpa, .store = store };
        b.load();
        b.seedDefaultSites();
        return b;
    }

    pub fn deinit(self: *Bookmarks) void {
        for (self.items.items) |it| {
            self.gpa.free(it.title);
            if (it.url) |u| self.gpa.free(u);
        }
        self.items.deinit(self.gpa);
        for (self.sites.items) |s| {
            self.gpa.free(s.host);
            self.gpa.free(s.name);
            self.gpa.free(s.template);
        }
        self.sites.deinit(self.gpa);
    }

    fn seedDefaultSites(self: *Bookmarks) void {
        const defaults = [_][3][]const u8{
            .{ "github.com", "GitHub", "https://github.com/search?q=%s" },
            .{ "en.wikipedia.org", "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s" },
            .{ "youtube.com", "YouTube", "https://www.youtube.com/results?search_query=%s" },
            .{ "reddit.com", "Reddit", "https://www.reddit.com/search/?q=%s" },
            .{ "news.ycombinator.com", "Hacker News", "https://hn.algolia.com/?q=%s" },
            .{ "stackoverflow.com", "Stack Overflow", "https://stackoverflow.com/search?q=%s" },
        };
        for (defaults) |d| {
            self.learnSite(d[0], d[1], d[2], false);
        }
        if (self.store.read("sitesearch.json")) |data| {
            defer self.gpa.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch {
                self.store.quarantine("sitesearch.json");
                return;
            };
            defer parsed.deinit();
            if (parsed.value == .array) {
                for (parsed.value.array.items) |item| {
                    if (item != .object) continue;
                    const h = item.object.get("host") orelse continue;
                    const n = item.object.get("name") orelse continue;
                    const t = item.object.get("template") orelse continue;
                    if (h == .string and n == .string and t == .string) {
                        self.learnSite(h.string, n.string, t.string, false);
                    }
                }
            }
        }
    }

    pub fn learnSite(self: *Bookmarks, host_in: []const u8, name: []const u8, template: []const u8, persist: bool) void {
        const host = if (host_in.len > 4 and std.ascii.startsWithIgnoreCase(host_in, "www.")) host_in[4..] else host_in;
        for (self.sites.items) |*s| {
            if (std.ascii.eqlIgnoreCase(s.host, host)) {
                self.gpa.free(s.name);
                self.gpa.free(s.template);
                s.name = self.gpa.dupe(u8, name) catch return;
                s.template = self.gpa.dupe(u8, template) catch return;
                if (persist) self.saveSites();
                return;
            }
        }
        self.sites.append(self.gpa, .{
            .host = self.gpa.dupe(u8, host) catch return,
            .name = self.gpa.dupe(u8, name) catch return,
            .template = self.gpa.dupe(u8, template) catch return,
        }) catch return;
        if (persist) self.saveSites();
    }

    pub fn forgetSite(self: *Bookmarks, host_in: []const u8) void {
        const host = if (host_in.len > 4 and std.ascii.startsWithIgnoreCase(host_in, "www.")) host_in[4..] else host_in;
        var i: usize = self.sites.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sites.items[i];
            if (std.ascii.eqlIgnoreCase(s.host, host) or std.ascii.eqlIgnoreCase(s.name, host)) {
                self.gpa.free(s.host);
                self.gpa.free(s.name);
                self.gpa.free(s.template);
                _ = self.sites.orderedRemove(i);
            }
        }
        self.saveSites();
    }

    pub fn matchSite(self: *const Bookmarks, word: []const u8) ?SiteEntry {
        if (word.len < 2 or std.mem.indexOfScalar(u8, word, ' ') != null) return null;
        for (self.sites.items) |s| {
            if (std.ascii.startsWithIgnoreCase(s.name, word) or std.ascii.startsWithIgnoreCase(s.host, word)) {
                return s;
            }
        }
        return null;
    }

    pub fn saveSites(self: *const Bookmarks) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "[") catch return;
        for (self.sites.items, 0..) |s, idx| {
            if (idx > 0) out.append(self.gpa, ',') catch return;
            const line = std.fmt.allocPrint(self.gpa, "{{\"host\":\"{s}\",\"name\":\"{s}\",\"template\":\"{s}\"}}", .{ s.host, s.name, s.template }) catch continue;
            defer self.gpa.free(line);
            out.appendSlice(self.gpa, line) catch return;
        }
        out.appendSlice(self.gpa, "]") catch return;
        self.store.writeAtomic("sitesearch.json", out.items);
    }

    pub fn add(self: *Bookmarks, title: []const u8, url: ?[]const u8, parent_id: u64) u64 {
        const id = self.next_id;
        self.next_id += 1;
        self.items.append(self.gpa, .{
            .id = id,
            .title = self.gpa.dupe(u8, if (title.len > 0) title else (url orelse "Untitled")) catch return 0,
            .url = if (url) |u| (self.gpa.dupe(u8, u) catch null) else null,
            .parent_id = parent_id,
        }) catch return 0;
        self.save();
        return id;
    }

    pub fn remove(self: *Bookmarks, id: u64) void {
        var i: usize = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const it = self.items.items[i];
            if (it.id == id or it.parent_id == id) {
                self.gpa.free(it.title);
                if (it.url) |u| self.gpa.free(u);
                _ = self.items.orderedRemove(i);
            }
        }
        self.save();
    }

    pub fn hasUrl(self: *const Bookmarks, url: []const u8) bool {
        for (self.items.items) |it| {
            if (it.url) |u| if (std.mem.eql(u8, u, url)) return true;
        }
        return false;
    }

    pub fn toggleUrl(self: *Bookmarks, title: []const u8, url: []const u8) bool {
        for (self.items.items) |it| {
            if (it.url) |u| if (std.mem.eql(u8, u, url)) {
                self.remove(it.id);
                return false;
            };
        }
        _ = self.add(title, url, 0);
        return true;
    }

    /// Multi-word case-insensitive match over bookmark title and URL.
    pub fn matchesQuery(it: Bookmark, query: []const u8) bool {
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0) return true;
        var words = std.mem.tokenizeAny(u8, q, " \t");
        while (words.next()) |w| {
            const in_title = containsIgnoreCase(it.title, w);
            const in_url = if (it.url) |u| containsIgnoreCase(u, w) else false;
            if (!in_title and !in_url) return false;
        }
        return true;
    }

    pub fn load(self: *Bookmarks) void {
        const data = self.store.read("bookmarks.json") orelse return;
        defer self.gpa.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch {
            self.store.quarantine("bookmarks.json");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .array) {
            self.store.quarantine("bookmarks.json");
            return;
        }
        self.loadArray(parsed.value.array.items, 0);
    }

    fn loadArray(self: *Bookmarks, arr: []const std.json.Value, parent_id: u64) void {
        for (arr) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const title_v = obj.get("title");
            const title_s = if (title_v != null and title_v.? == .string) title_v.?.string else "Bookmark";
            const url_v = obj.get("url");
            const url_s: ?[]const u8 = if (url_v != null and url_v.? == .string) url_v.?.string else null;
            const id = self.next_id;
            self.next_id += 1;
            self.items.append(self.gpa, .{
                .id = id,
                .title = self.gpa.dupe(u8, title_s) catch continue,
                .url = if (url_s) |u| (self.gpa.dupe(u8, u) catch null) else null,
                .parent_id = parent_id,
            }) catch continue;
            if (obj.get("children")) |ch| {
                if (ch == .array) self.loadArray(ch.array.items, id);
            }
        }
    }

    pub fn save(self: *const Bookmarks) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "[") catch return;
        for (self.items.items, 0..) |it, idx| {
            if (idx > 0) out.append(self.gpa, ',') catch return;
            const u = it.url orelse "";
            const line = if (it.url != null)
                std.fmt.allocPrint(self.gpa, "{{\"title\":\"{s}\",\"url\":\"{s}\"}}", .{ it.title, u }) catch continue
            else
                std.fmt.allocPrint(self.gpa, "{{\"title\":\"{s}\",\"children\":[]}}", .{it.title}) catch continue;
            defer self.gpa.free(line);
            out.appendSlice(self.gpa, line) catch return;
        }
        out.appendSlice(self.gpa, "]") catch return;
        self.store.writeAtomic("bookmarks.json", out.items);
    }
};

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}
