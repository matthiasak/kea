//! The rest of `Assistant` (AIAssist.swift): what the composer suggests,
//! the slash commands, compacting a long chat, cleaning up, and stopping.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const ai = @import("ai.zig");
const ubi = @import("ubi_chat.zig");
const sse = @import("client_sse.zig");
const runs = @import("assistant_runs.zig");
const Assistant = @import("assistant.zig").Assistant;
const Chat = cs.Chat;
const Turn = cs.Turn;
const A = std.mem.Allocator;

/// Commands while a "/" word is typed; pages to pin after "@", "tabs/",
/// "bookmarks/" or "history/". On `a`.
pub fn suggestions(self: *Assistant, a: A) ![]const ubi.Suggestion {
    const draft = self.draft.items;
    if (std.mem.startsWith(u8, draft, "/") and std.mem.indexOfScalar(u8, draft, ' ') == null) {
        const prefix = try std.ascii.allocLowerString(a, draft);
        var out: std.ArrayList(ubi.Suggestion) = .empty;
        for (ubi.commands) |c| if (std.mem.startsWith(u8, c.name, prefix))
            try out.append(a, .{ .source = .command, .title = c.name, .detail = c.hint, .url = null });
        return out.items;
    }
    if (draft.len == 0 or std.mem.endsWith(u8, draft, " ")) return &.{};
    const b = self.browser orelse return &.{};
    var words = std.mem.splitBackwardsScalar(u8, draft, ' ');
    const word = words.first();
    if (word.len == 0) return &.{};
    const lower = try std.ascii.allocLowerString(a, word);
    const Kind = struct { prefix: []const u8, sources: []const ubi.Source };
    const kinds = [_]Kind{
        .{ .prefix = "@", .sources = &.{ .tab, .bookmark, .history } },
        .{ .prefix = "tabs/", .sources = &.{.tab} },
        .{ .prefix = "bookmarks/", .sources = &.{.bookmark} },
        .{ .prefix = "history/", .sources = &.{.history} },
    };
    for (kinds) |k| if (std.mem.startsWith(u8, lower, k.prefix)) {
        var except: std.ArrayList([]const u8) = .empty;
        for (self.chat.pins) |p| try except.append(a, p.url);
        return ubi.pages(a, lower[k.prefix.len..], k.sources, b, except.items);
    };
    return &.{};
}

pub fn pick(self: *Assistant, s: ubi.Suggestion) void {
    if (s.source == .command) {
        if (std.mem.eql(u8, s.title, "/rename-ws")) return self.setDraft("/rename-ws ");
        return self.run(s.title);
    }
    const address = s.url orelse return;
    self.mutate(cs.ChatPin{ .id = json.Uuid.random(), .title = s.title, .url = address }, struct {
        fn f(p: cs.ChatPin, a: A, c: *Chat) !void {
            const list = try a.alloc(cs.ChatPin, c.pins.len + 1);
            @memcpy(list[0..c.pins.len], c.pins);
            list[c.pins.len] = try json.clone(a, p);
            c.pins = list;
        }
    }.f);
    // The word typed for it goes; a space is left after the rest.
    const cut = std.mem.lastIndexOfScalar(u8, self.draft.items, ' ');
    if (cut) |i| self.draft.shrinkRetainingCapacity(i + 1) else self.draft.clearRetainingCapacity();
    self.keep();
}

/// A slash command, typed whole.
pub fn run(self: *Assistant, text: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const own = a.dupe(u8, text) catch return;
    const space = std.mem.indexOfScalar(u8, own, ' ');
    const name = std.ascii.allocLowerString(a, if (space) |i| own[0..i] else own) catch return;
    const rest = if (space) |i| std.mem.trim(u8, own[i + 1 ..], " \t\r\n") else "";
    self.draft.clearRetainingCapacity();
    const is = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (is(name, "/summarize")) {
        self.summarize();
    } else if (is(name, "/clear")) {
        self.new(true);
    } else if (is(name, "/clear-pins")) {
        self.clearPins();
    } else if (is(name, "/rename-ws")) {
        if (rest.len == 0) {
            self.setDraft("/rename-ws ");
            self.announce("Type a name after /rename-ws");
        } else {
            self.mutate(sse.prefix(rest, 80), struct {
                fn f(t: []const u8, al: A, c: *Chat) !void {
                    c.title = try al.dupe(u8, t);
                }
            }.f);
            self.keep();
        }
    } else if (is(name, "/copy-workspace")) {
        ubi.copy(self.gpa, ubi.markdown(a, self.chat) catch return);
        self.announce("Chat copied");
    } else if (is(name, "/help")) {
        self.help_shown = true;
    } else if (is(name, "/compact")) {
        self.compact();
    } else if (is(name, "/clean-up")) {
        self.cleanUp();
    } else {
        self.setDraft(own);
        self.announce(std.fmt.allocPrint(a, "No command {s}", .{name}) catch "No command");
    }
}

pub fn compact(self: *Assistant) void {
    if (self.busy() or self.compacting or self.notice != null) return;
    const b = self.browser orelse return;
    const r = ubi.ready(self.m, b) orelse return;
    if (self.shy and !self.m.staysOnThisMac(r.provider)) return self.announce("In a private tab, only an AI on this Mac");
    var buf: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "chat.told.{s}", .{r.provider.id}) catch return;
    if (!r.provider.isLocal() and !(self.m.store.@"bool"(key) orelse false)) {
        var said: [128]u8 = undefined;
        return self.announce(std.fmt.bufPrint(&said, "Ask {s} a question first", .{r.provider.name}) catch "Ask a question first");
    }
    self.compactWith(r.provider, r.model);
}

/// Turns before the last two folded into a summary, `remembered` at a time,
/// each batch's summary taking the one before it (past `compact`'s checks).
pub fn compactWith(self: *Assistant, p: ai.Provider, model: []const u8) void {
    const start = folded(self.chat);
    const end = @as(isize, @intCast(self.chat.turns.len)) - 2;
    if (end <= @as(isize, @intCast(start))) return self.announce("Nothing to compact yet");
    self.compact_run += 1;
    self.compacting = true;
    runs.Compact.start(self, p, model, start, @intCast(end));
}

/// How many turns the summary covers, never more than there are.
pub fn folded(c: Chat) usize {
    return @min(@as(usize, @intCast(@max(0, c.compacted orelse 0))), c.turns.len);
}

fn isBad(t: Turn) bool {
    return t.failed != null or std.mem.trim(u8, t.answer, " \t\r\n").len == 0;
}

/// Failed and empty turns gone, and chats with no turns.
pub fn cleanUp(self: *Assistant) void {
    if (self.busy() or self.compacting) return;
    const fold = folded(self.chat);
    var bad_before: usize = 0;
    for (self.chat.turns[0..fold]) |t| {
        if (isBad(t)) bad_before += 1;
    }
    const before = self.chat.turns.len;
    const Fix = struct { fold: usize, bad_before: usize };
    self.mutate(Fix{ .fold = fold, .bad_before = bad_before }, struct {
        fn f(x: Fix, a: A, c: *Chat) !void {
            var kept: std.ArrayList(Turn) = .empty;
            for (c.turns) |t| if (!isBad(t)) try kept.append(a, t);
            c.turns = kept.items;
            if (c.compacted != null) {
                const next = x.fold -| x.bad_before;
                if (next == 0) {
                    c.compacted = null;
                    c.summary = null;
                } else c.compacted = @intCast(next);
            }
        }
    }.f);
    const removed = before - self.chat.turns.len;
    const empties = if (self.shy) 0 else self.m.chats.sweepEmpty();
    if (self.chat.turns.len == 0) {
        if (!self.shy) self.m.chats.remove(self.chat.id);
        self.new(true);
    } else if (removed > 0) self.keep();
    if (removed == 0 and empties == 0) return self.announce("Nothing to clean up");
    var buf: [128]u8 = undefined;
    self.announce(std.fmt.bufPrint(&buf, "Removed {d} failed turns and {d} empty chats", .{ removed, empties }) catch "Removed");
}

pub fn stop(self: *Assistant) void {
    if (self.task) |t| t.cancel();
    self.task = null;
    self.compact_run += 1;
    if (self.compactor) |c| c.cancel();
    self.compactor = null;
    self.compacting = false;
}

pub fn addAttachment(self: *Assistant, name: []const u8, media_type: []const u8, data: []const u8, is_image: bool) void {
    const n = self.gpa.dupe(u8, name) catch return;
    const m = self.gpa.dupe(u8, media_type) catch return self.gpa.free(n);
    const d = self.gpa.dupe(u8, data) catch {
        self.gpa.free(n);
        self.gpa.free(m);
        return;
    };
    const id = self.next_attachment_id;
    self.next_attachment_id += 1;
    self.attachments.append(self.gpa, .{ .id = id, .name = n, .media_type = m, .data = d, .is_image = is_image }) catch {
        self.gpa.free(n);
        self.gpa.free(m);
        self.gpa.free(d);
        return;
    };
    self.changed();
}

pub fn removeAttachment(self: *Assistant, id: u64) void {
    for (self.attachments.items, 0..) |att, i| if (att.id == id) {
        self.gpa.free(att.name);
        self.gpa.free(att.media_type);
        self.gpa.free(att.data);
        _ = self.attachments.orderedRemove(i);
        self.changed();
        return;
    };
}

pub fn clearAttachments(self: *Assistant) void {
    for (self.attachments.items) |att| {
        self.gpa.free(att.name);
        self.gpa.free(att.media_type);
        self.gpa.free(att.data);
    }
    self.attachments.clearRetainingCapacity();
}

pub fn attachFilePath(self: *Assistant, path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(10 * 1024 * 1024)) catch return false;
    defer self.gpa.free(bytes);
    if (bytes.len == 0) return false;
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) {
        self.addAttachment(base, "image/png", bytes, true);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) {
        self.addAttachment(base, "image/jpeg", bytes, true);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) {
        self.addAttachment(base, "image/gif", bytes, true);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) {
        self.addAttachment(base, "image/webp", bytes, true);
        return true;
    }
    self.addAttachment(base, "text/plain", bytes, false);
    return true;
}

pub fn pasteFromClipboard(self: *Assistant) bool {
    if (nanoui.clipboard.readFiles(self.gpa) catch null) |paths| {
        defer nanoui.dialog.freePaths(self.gpa, paths);
        var any = false;
        for (paths) |p| if (self.attachFilePath(p)) {
            any = true;
        };
        if (any) return true;
    }
    if (nanoui.clipboard.readImage(self.gpa) catch null) |png| {
        defer self.gpa.free(png);
        if (png.len > 0) {
            self.addAttachment("Clipboard Image.png", "image/png", png, true);
            return true;
        }
    }
    if (nanoui.clipboard.readText(self.gpa) catch null) |txt| {
        defer self.gpa.free(txt);
        if (txt.len > 0) return false;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    if (objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString("public.data")})) |nsdata| {
        const n = objc.msg(objc.NSUInteger, nsdata, "length", .{});
        if (n > 0 and n <= 10 * 1024 * 1024) {
            const ptr = objc.msg([*]const u8, nsdata, "bytes", .{});
            self.addAttachment("Clipboard Buffer", "text/plain", ptr[0..n], false);
            return true;
        }
    }
    return false;
}

pub fn takeAttachments(self: *Assistant, a: A, images: *std.ArrayList(@import("client.zig").Image), extra_text: *std.ArrayList(u8)) !void {
    if (self.shot) |jpeg| {
        defer {
            self.gpa.free(jpeg);
            self.shot = null;
        }
        const enc = std.base64.standard.Encoder;
        const dst = try a.alloc(u8, enc.calcSize(jpeg.len));
        try images.append(a, .{ .media_type = "image/jpeg", .b64 = enc.encode(dst, jpeg) });
    }
    defer self.clearAttachments();
    for (self.attachments.items) |att| {
        if (att.is_image) {
            const enc = std.base64.standard.Encoder;
            const dst = try a.alloc(u8, enc.calcSize(att.data.len));
            try images.append(a, .{
                .media_type = try a.dupe(u8, att.media_type),
                .b64 = enc.encode(dst, att.data),
            });
        } else {
            var aw: std.Io.Writer.Allocating = .fromArrayList(a, extra_text);
            try aw.writer.print("\n\n<attachment name=\"{s}\">\n{s}\n</attachment>", .{ att.name, att.data });
            extra_text.* = aw.toArrayList();
        }
    }
}
