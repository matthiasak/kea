//! Tests for providers and keys: a test run keeps keys in memory and never
//! reaches the keychain.
const std = @import("std");
const t = std.testing;
const ai = @import("ai.zig");
const keys = @import("keys.zig");
const ubi = @import("ubi_chat.zig");
const Rig = @import("test_rig.zig").Rig;

test "providers: where each runs, and whether it takes a key" {
    try t.expectEqual(@as(usize, 7), ai.built_ins.len);
    try t.expect(!ai.anthropic.isLocal() and ai.anthropic.takesKey());
    try t.expect(ai.ollama.isLocal() and !ai.ollama.takesKey());
    try t.expect(ai.custom.isLocal() and ai.custom.takesKey());
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("LM Studio, on this Mac", try ai.lmStudio.label(a));
    try t.expectEqualStrings("Custom server", try ai.custom.label(a));

    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    try t.expectEqualStrings("api.anthropic.com", try rig.ai.host(a, ai.anthropic));
    try t.expect(rig.ai.staysOnThisMac(ai.ollama));
    try t.expect(!rig.ai.staysOnThisMac(ai.openAI));
    try t.expectEqualStrings("sent to Anthropic · claude-haiku-4-5", try ubi.place(a, rig.ai, ai.anthropic, "claude-haiku-4-5"));
    try t.expectEqualStrings("on this Mac · Ollama · llama3", try ubi.place(a, rig.ai, ai.ollama, "llama3"));
    try t.expectEqualStrings("on 127.0.0.1 · qwen", try ubi.place(a, rig.ai, ai.custom, "qwen"));
    const n = try ubi.notice(a, rig.ai, ai.openRouter);
    try t.expect(std.mem.startsWith(u8, n, "When you ask, KeaZig sends your question, the chat so far, and the text and addresses of the pages you share to openrouter.ai, which passes them"));
    try t.expect(std.mem.endsWith(u8, n, "\n\nKeaZig asks OpenRouter to use only providers that keep nothing (zero data retention)."));
    try t.expect(rig.ai.named("gemini") != null);
    try t.expect(rig.ai.named("nobody") == null);
    try t.expectEqual(@as(usize, 7), (try rig.ai.all(a)).len);
    // Ready once chosen with a model and, off this Mac, a key.
    try t.expect(ubi.quiet(rig.ai) == null);
    rig.prefs.ai_provider = try t.allocator.dupe(u8, "anthropic");
    try t.expect(ubi.quiet(rig.ai) == null);
    try t.expectEqual(keys.Saved.kept, rig.ai.keys.save(rig.ai, "sk-ant-key", ai.anthropic));
    try t.expectEqualStrings("claude-haiku-4-5", ubi.quiet(rig.ai).?.model);
}

test "keys: kept in memory in a test run, sources by account" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const m = rig.ai;
    const k = &m.keys;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("anthropic@api.anthropic.com", try k.account(a, m, ai.anthropic));
    try t.expectEqual(keys.Saved.failed, k.save(m, "   ", ai.anthropic));
    try t.expectEqual(keys.Saved.failed, k.save(m, "key", ai.ollama));
    try t.expectEqual(keys.Saved.kept, k.save(m, "  sk-abc1a2b\n", ai.anthropic));
    try t.expectEqualStrings("••••1a2b", k.hint(a, m, ai.anthropic).?);
    try t.expect(k.hint(a, m, ai.openAI) == null);

    // A variable or a command instead; a bad name is ignored.
    k.setSource(m, .{ .environment = "9BAD" }, ai.openAI);
    try t.expect(k.source(a, m, ai.openAI) == .keychain);
    k.setSource(m, .{ .environment = "KEAZIG_TEST_NO_SUCH_VAR" }, ai.openAI);
    try t.expectEqualStrings("KEAZIG_TEST_NO_SUCH_VAR", k.source(a, m, ai.openAI).environment);
    try t.expectEqualStrings("$KEAZIG_TEST_NO_SUCH_VAR", k.hint(a, m, ai.openAI).?);
    k.setSource(m, .{ .command = "op read x" }, ai.gemini);
    try t.expectEqualStrings("from a command", k.hint(a, m, ai.gemini).?);
    // Both live side by side in `ai.keySources`.
    try t.expectEqualStrings("op read x", k.source(a, m, ai.gemini).command);
    try t.expect(k.source(a, m, ai.openAI) == .environment);

    const Got = struct {
        key: ?[]u8 = null,
        fn then(raw: *anyopaque, key: ?[]u8) void {
            const g: *@This() = @ptrCast(@alignCast(raw));
            g.key = key;
        }
    };
    var got: Got = .{};
    k.key(m, ai.anthropic, &got, Got.then);
    defer if (got.key) |x| t.allocator.free(x);
    try t.expectEqualStrings("sk-abc1a2b", got.key.?);

    k.forget(m, ai.anthropic);
    try t.expect(k.hint(a, m, ai.anthropic) == null);
    k.forgetAll();
    try t.expect(k.source(a, m, ai.gemini) == .keychain);
    try t.expect(keys.isVariableName("_A1") and !keys.isVariableName("A-B") and !keys.isVariableName(""));
}
