//! Follow-up questions suggested after an answer, in the dock over the
//! composer: asked of the same model once the answer is in, quietly, as
//! the chat's name is.
const std = @import("std");
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const ai = @import("ai.zig");
const client = @import("client.zig");
const sse = @import("client_sse.zig");
const ubi = @import("ubi_chat.zig");
const runs = @import("assistant_runs.zig");
const assistant_mod = @import("assistant.zig");
const Assistant = assistant_mod.Assistant;
const A = std.mem.Allocator;

/// Up to 3 questions from the model's reply: list markers and quotes off,
/// 4 to 90 bytes each. On `a`.
pub fn parseLines(a: A, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l| {
        var s = std.mem.trim(u8, l, " \t\r");
        // "1." "1)" "-" "*" "•" "✦"
        var digits: usize = 0;
        while (digits < s.len and std.ascii.isDigit(s[digits])) digits += 1;
        if (digits > 0 and digits < s.len and (s[digits] == '.' or s[digits] == ')')) s = s[digits + 1 ..];
        inline for (.{ "- ", "* ", "•", "✦" }) |m| {
            if (std.mem.startsWith(u8, s, m)) s = s[m.len..];
        }
        s = unquoted(s);
        if (s.len < 4 or s.len > 90) continue;
        try out.append(a, try a.dupe(u8, s));
        if (out.items.len == 3) break;
    }
    return out.items;
}

/// Spaces, ASCII quotes and typographic quotes off both ends, whole code points only.
fn unquoted(text: []const u8) []const u8 {
    var s = text;
    while (true) {
        const before = s.len;
        s = std.mem.trim(u8, s, " \t\"'`*");
        inline for (.{ "“", "”", "‘", "’" }) |q| {
            if (std.mem.startsWith(u8, s, q)) s = s[q.len..];
            if (std.mem.endsWith(u8, s, q)) s = s[0 .. s.len - q.len];
        }
        if (s.len == before) return s;
    }
}

/// After an answer: the chat named (once), then follow-ups asked for.
pub fn afterAnswer(self: *Assistant, p: ai.Provider, model: []const u8) void {
    self.name(p, model);
    if (self.chat.turns.len == 0) return;
    const last = self.chat.turns[self.chat.turns.len - 1];
    if (last.failed != null or last.answer.len == 0) return;
    Run.start(self, p, model, last.question, last.answer);
}

const Run = struct {
    gpa: A,
    m: *ai.Ai,
    serial: u64,
    chat_id: json.Uuid,
    arena: std.heap.ArenaAllocator,
    provider: ai.Provider,
    model: []const u8,
    prompt: []const u8,
    key: ?[]u8 = null,
    asking: runs.Asking,

    fn start(self: *Assistant, p: ai.Provider, model: []const u8, question: []const u8, answer: []const u8) void {
        const r = self.gpa.create(Run) catch return;
        r.* = .{ .gpa = self.gpa, .m = self.m, .serial = self.serial, .chat_id = self.chat.id, .arena = .init(self.gpa), .provider = undefined, .model = undefined, .prompt = undefined, .asking = .{ .gpa = self.gpa, .owner = r, .on_end = ended, .most = 400 } };
        const a = r.arena.allocator();
        r.provider = json.clone(a, p) catch return r.free();
        r.model = a.dupe(u8, model) catch return r.free();
        r.prompt = std.fmt.allocPrint(a, "Question:\n{s}\n\nAnswer:\n{s}", .{ sse.prefix(question, 1500), sse.prefix(answer, 4000) }) catch return r.free();
        if (r.provider.takesKey()) return r.m.keys.key(r.m, r.provider, r, keyed);
        keyed(r, null);
    }

    fn keyed(raw: *anyopaque, key: ?[]u8) void {
        const r: *Run = @ptrCast(@alignCast(raw));
        if (r.key) |k| r.gpa.free(k);
        r.key = key;
        if (r.m.assistant(r.serial) == null) return r.free();
        const one = r.arena.allocator().alloc(client.Message, 1) catch return r.free();
        one[0] = .{ .role = .user, .text = r.prompt };
        r.asking.begin(r.m, .{ .provider = r.provider, .model = r.model, .system = ubi.followups_system, .messages = one, .key = r.key, .max_tokens = 2048, .thinking = 1024 });
    }

    fn free(r: *Run) void {
        if (r.key) |k| r.gpa.free(k);
        r.asking.deinit();
        r.arena.deinit();
        r.gpa.destroy(r);
    }

    fn ended(raw: *anyopaque) void {
        const r: *Run = @ptrCast(@alignCast(raw));
        defer r.free();
        if (r.asking.failure != null) return;
        const list = parseLines(r.arena.allocator(), r.asking.text.items) catch return;
        if (list.len == 0) return;
        const f = struct {
            fn f(qs: []const []const u8, a: A, c: *cs.Chat) !void {
                c.followups = try json.clone(a, qs);
            }
        }.f;
        if (r.m.assistant(r.serial)) |self| self.edit(r.chat_id, list, f) else assistant_mod.editStored(r.m, r.chat_id, list, f);
    }
};

test "follow-up lines lose their markers and quotes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try parseLines(arena.allocator(), "1. Why does it work?\n\n- \"What if n is 0?\"\n• ok\n✦ How is it proven?\n4) A fourth one?");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("Why does it work?", got[0]);
    try std.testing.expectEqualStrings("What if n is 0?", got[1]);
    try std.testing.expectEqualStrings("How is it proven?", got[2]);
}
