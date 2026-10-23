//! Tests for the client: each provider's stream, read from a recorded
//! sample in small pieces; request shapes; errors and what they say.
const std = @import("std");
const t = std.testing;
const ai = @import("ai.zig");
const client = @import("client.zig");
const more = @import("client_more.zig");
const sse = @import("client_sse.zig");
const Rig = @import("test_rig.zig").Rig;

const Collected = struct {
    text: std.ArrayList(u8) = .empty,
    fn piece(raw: *anyopaque, s: []const u8) void {
        const c: *Collected = @ptrCast(@alignCast(raw));
        c.text.appendSlice(t.allocator, s) catch {};
    }
};

/// The fixture fed `step` bytes at a time, then ended; the text read and how it ended.
fn readAll(wire: ai.Wire, bytes: []const u8, step: usize, key: ?[]const u8, out: *Collected, r: *sse.Reader) sse.Said {
    r.* = .{ .a = t.allocator, .keep = t.allocator, .wire = wire, .key = key };
    var i: usize = 0;
    while (i < bytes.len) : (i += step) {
        const said = r.feed(bytes[i..@min(bytes.len, i + step)], out, Collected.piece);
        if (said != .more) return said;
    }
    return r.finish(out, Collected.piece);
}

fn expectStream(wire: ai.Wire, bytes: []const u8, want: []const u8) !void {
    for ([_]usize{ 1, 7, 64, bytes.len }) |step| {
        var out: Collected = .{};
        defer out.text.deinit(t.allocator);
        var r: sse.Reader = undefined;
        defer r.deinit();
        const said = readAll(wire, bytes, step, null, &out, &r);
        try t.expect(said == .done);
        try t.expectEqualStrings(want, out.text.items);
    }
}

test "SSE: OpenAI chat completions" {
    try expectStream(.openAI, @embedFile("../tests/fixtures/ai/openai.txt"), "Hello, world");
}

test "SSE: Anthropic messages" {
    try expectStream(.anthropic, @embedFile("../tests/fixtures/ai/anthropic.txt"), "Hello there");
}

test "SSE: Gemini streamGenerateContent, CRLF, thoughts left out, no [DONE]" {
    try expectStream(.gemini, @embedFile("../tests/fixtures/ai/gemini.txt"), "Bonjour le monde");
}

test "SSE: tool calls for OpenAI, Anthropic and Gemini" {
    const ToolCollector = struct {
        events: std.ArrayList(sse.ToolEvent) = .empty,
        arena: std.heap.ArenaAllocator,
        fn onPiece(_: *anyopaque, _: []const u8) void {}
        fn onTool(raw: *anyopaque, ev: sse.ToolEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const a = self.arena.allocator();
            self.events.append(a, .{
                .index = ev.index,
                .id = if (ev.id) |s| (a.dupe(u8, s) catch null) else null,
                .name = if (ev.name) |s| (a.dupe(u8, s) catch null) else null,
                .args_delta = a.dupe(u8, ev.args_delta) catch "",
            }) catch {};
        }
    };
    {
        var tc: ToolCollector = .{ .arena = .init(t.allocator) };
        defer tc.arena.deinit();
        var r: sse.Reader = .{ .a = t.allocator, .keep = t.allocator, .wire = .openAI, .key = null, .on_tool = ToolCollector.onTool };
        defer r.deinit();
        const data = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"function\":{\"name\":\"search_history\",\"arguments\":\"{\\\"query\\\":\\\"kea\\\"}\"}}]}}]}\ndata: [DONE]\n";
        try t.expect(r.feed(data, &tc, ToolCollector.onPiece) == .done);
        try t.expectEqual(@as(usize, 1), tc.events.items.len);
        try t.expectEqualStrings("call_abc", tc.events.items[0].id.?);
        try t.expectEqualStrings("search_history", tc.events.items[0].name.?);
        try t.expectEqualStrings("{\"query\":\"kea\"}", tc.events.items[0].args_delta);
    }
    {
        var tc: ToolCollector = .{ .arena = .init(t.allocator) };
        defer tc.arena.deinit();
        var r: sse.Reader = .{ .a = t.allocator, .keep = t.allocator, .wire = .anthropic, .key = null, .on_tool = ToolCollector.onTool };
        defer r.deinit();
        const data = "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"search_tabs\"}}\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"x\\\"}\"}}\n";
        try t.expect(r.feed(data, &tc, ToolCollector.onPiece) == .more);
        try t.expectEqual(@as(usize, 2), tc.events.items.len);
        try t.expectEqualStrings("tu_1", tc.events.items[0].id.?);
        try t.expectEqualStrings("search_tabs", tc.events.items[0].name.?);
        try t.expectEqualStrings("{\"query\":\"x\"}", tc.events.items[1].args_delta);
    }
    {
        var tc: ToolCollector = .{ .arena = .init(t.allocator) };
        defer tc.arena.deinit();
        var r: sse.Reader = .{ .a = t.allocator, .keep = t.allocator, .wire = .gemini, .key = null, .on_tool = ToolCollector.onTool };
        defer r.deinit();
        const data = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"search_bookmarks\",\"args\":{\"query\":\"zig\"}}}]}}]}\n";
        try t.expect(r.feed(data, &tc, ToolCollector.onPiece) == .more);
        try t.expectEqual(@as(usize, 1), tc.events.items.len);
        try t.expectEqualStrings("call_0", tc.events.items[0].id.?);
        try t.expectEqualStrings("search_bookmarks", tc.events.items[0].name.?);
        try t.expectEqualStrings("{\"query\":\"zig\"}", tc.events.items[0].args_delta);
    }
}

test "SSE: an error inside the stream stops it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    {
        var out: Collected = .{};
        defer out.text.deinit(t.allocator);
        var r: sse.Reader = undefined;
        defer r.deinit();
        const said = readAll(.anthropic, @embedFile("../tests/fixtures/ai/anthropic_error.txt"), 5, null, &out, &r);
        try t.expectEqualStrings("Par", out.text.items);
        const f = said.failed;
        defer t.allocator.free(f.http.said);
        const text = try f.describe(arena.allocator());
        try t.expectEqualStrings("Overloaded (500)", text);
    }
    {
        var out: Collected = .{};
        defer out.text.deinit(t.allocator);
        var r: sse.Reader = undefined;
        defer r.deinit();
        const said = readAll(.openAI, @embedFile("../tests/fixtures/ai/openrouter_error.txt"), 3, "sk-or-v1-abcdefghijkl", &out, &r);
        try t.expectEqualStrings("Hi", out.text.items);
        const f = said.failed;
        defer t.allocator.free(f.http.said);
        try t.expectEqual(@as(i64, 429), f.http.status);
        try t.expectEqualStrings("Rate limited for key ••••, try later", f.http.said);
    }
}

test "AIError says what Swift says" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("No key is kept for this provider.", try (client.Failure{ .no_key = {} }).describe(a));
    try t.expectEqualStrings("That address isn't the provider's.", try (client.Failure{ .refused_host = {} }).describe(a));
    try t.expectEqualStrings("The provider answered 503.", try (client.Failure{ .http = .{ .status = 503, .said = "" } }).describe(a));
    try t.expectEqualStrings("The provider's answer couldn't be read.", try (client.Failure{ .unreadable = {} }).describe(a));
    try t.expectEqualStrings("Invalid key •••• (401)", try (client.Failure{ .http = .{ .status = 401, .said = sse.said(a, "{\"error\":{\"message\":\"Invalid key AIzaSyA1234567890abcdef\"}}", null) } }).describe(a));
    try t.expectEqualStrings("Bad", sse.said(a, "[{\"error\":{\"message\":\"Bad\"}}]", null));
    try t.expectEqualStrings("plain", sse.said(a, "{\"error\":\"plain\"}", null));
    try t.expectEqualStrings("top", sse.said(a, "{\"message\":\"top\"}", null));
    try t.expectEqualStrings("", sse.said(a, "<html>", null));
    // The key, its first eight and its last four, and anything shaped like one.
    try t.expectEqualStrings("•••• and ••••… and ••••", try sse.scrub(a, "mykey-123456789 and mykey-12… and 6789", "mykey-123456789"));
    try t.expectEqualStrings("x •••• y", try sse.scrub(a, "x gsk_abcdefghij12 y", null));
}

test "requests: shapes per wire, limits and thinking as Swift sets them" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]client.Message{ .{ .role = .user, .text = "Q" }, .{ .role = .assistant, .text = "A" } };

    const oa = try client.request(rig.ai, a, .{ .provider = ai.openAI, .model = "m", .system = "S", .messages = &msgs, .key = "k1", .max_tokens = 4096, .thinking = 1024 });
    try t.expectEqualStrings("https://api.openai.com/v1/chat/completions", oa.url);
    try t.expectEqualStrings("{\"model\":\"m\",\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"Q\"},{\"role\":\"assistant\",\"content\":\"A\"}],\"max_completion_tokens\":4096}", oa.body);
    try t.expectEqualStrings("Bearer k1", oa.headers[2][1]);

    const orr = try client.request(rig.ai, a, .{ .provider = ai.openRouter, .model = "m", .system = "S", .messages = msgs[0..1], .key = "k" });
    try t.expectEqualStrings("{\"model\":\"m\",\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"Q\"}],\"provider\":{\"zdr\":true},\"max_tokens\":2048}", orr.body);

    const an = try client.request(rig.ai, a, .{ .provider = ai.anthropic, .model = "c", .system = "S", .messages = msgs[0..1], .key = "k2" });
    try t.expectEqualStrings("https://api.anthropic.com/v1/messages", an.url);
    try t.expectEqualStrings("{\"model\":\"c\",\"stream\":true,\"max_tokens\":2048,\"system\":\"S\",\"messages\":[{\"role\":\"user\",\"content\":\"Q\"}]}", an.body);
    try t.expectEqualStrings("x-api-key", an.headers[2][0]);
    try t.expectEqualStrings("2023-06-01", an.headers[3][1]);

    const ge = try client.request(rig.ai, a, .{ .provider = ai.gemini, .model = "gemini 3/x", .system = "S", .messages = &msgs, .key = "k3", .max_tokens = 8192, .thinking = 1024 });
    try t.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models/gemini%203%2Fx:streamGenerateContent?alt=sse", ge.url);
    try t.expectEqualStrings("{\"systemInstruction\":{\"parts\":[{\"text\":\"S\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Q\"}]},{\"role\":\"model\",\"parts\":[{\"text\":\"A\"}]}],\"generationConfig\":{\"maxOutputTokens\":8192,\"thinkingConfig\":{\"thinkingBudget\":1024}}}", ge.body);
    try t.expectEqualStrings("x-goog-api-key", ge.headers[2][0]);

    // No key: refused off this Mac, fine on it.
    try t.expectError(error.NoKey, client.request(rig.ai, a, .{ .provider = ai.anthropic, .model = "c", .system = "S", .messages = &msgs, .key = null }));
    const ol = try client.request(rig.ai, a, .{ .provider = ai.ollama, .model = "llama", .system = "S", .messages = &msgs, .key = null });
    try t.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", ol.url);
    try t.expectEqual(@as(usize, 2), ol.headers.len);
    const imgs = [_]client.Image{.{ .media_type = "image/jpeg", .b64 = "abc=" }};
    const img_msgs = [_]client.Message{.{ .role = .user, .text = "See", .images = &imgs }};
    const oa_img = try client.request(rig.ai, a, .{ .provider = ai.openAI, .model = "m", .system = "S", .messages = &img_msgs, .key = "k1" });
    try t.expect(std.mem.indexOf(u8, oa_img.body, "\"content\":[{\"type\":\"text\",\"text\":\"See\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,abc=\"}}]") != null);
    const an_img = try client.request(rig.ai, a, .{ .provider = ai.anthropic, .model = "c", .system = "S", .messages = &img_msgs, .key = "k2" });
    try t.expect(std.mem.indexOf(u8, an_img.body, "\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"abc=\"}},{\"type\":\"text\",\"text\":\"See\"}]") != null);
    const ge_img = try client.request(rig.ai, a, .{ .provider = ai.gemini, .model = "g", .system = "S", .messages = &img_msgs, .key = "k3" });
    try t.expect(std.mem.indexOf(u8, ge_img.body, "\"parts\":[{\"inlineData\":{\"mimeType\":\"image/jpeg\",\"data\":\"abc=\"}},{\"text\":\"See\"}]") != null);
    const calls = [_]client.Call{.{ .id = "call_1", .name = "search_history", .args = "{\"query\":\"kea\"}" }};
    const tool_msgs = [_]client.Message{
        .{ .role = .user, .text = "Find kea" },
        .{ .role = .assistant, .text = "", .calls = &calls },
        .{ .role = .tool, .text = "[{\"title\":\"Kea\",\"url\":\"https://kea.example/\"}]", .call_id = "call_1", .name = "search_history" },
    };
    const oa_tools = try client.request(rig.ai, a, .{ .provider = ai.openAI, .model = "m", .system = "S", .messages = &tool_msgs, .key = "k1", .tools = true });
    try t.expect(std.mem.indexOf(u8, oa_tools.body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"search_tabs\"") != null);
    try t.expect(std.mem.indexOf(u8, oa_tools.body, "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"search_history\",\"arguments\":\"{\\\"query\\\":\\\"kea\\\"}\"}}]") != null);
    try t.expect(std.mem.indexOf(u8, oa_tools.body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"[{\\\"title\\\":\\\"Kea\\\",\\\"url\\\":\\\"https://kea.example/\\\"}]\"}") != null);

    const an_tools = try client.request(rig.ai, a, .{ .provider = ai.anthropic, .model = "c", .system = "S", .messages = &tool_msgs, .key = "k2", .tools = true });
    try t.expect(std.mem.indexOf(u8, an_tools.body, "\"tools\":[{\"name\":\"search_tabs\"") != null);
    try t.expect(std.mem.indexOf(u8, an_tools.body, "{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"search_history\",\"input\":{\"query\":\"kea\"}}") != null);
    try t.expect(std.mem.indexOf(u8, an_tools.body, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":\"[{\\\"title\\\":\\\"Kea\\\",\\\"url\\\":\\\"https://kea.example/\\\"}]\"}]}") != null);

    const ge_tools = try client.request(rig.ai, a, .{ .provider = ai.gemini, .model = "g", .system = "S", .messages = &tool_msgs, .key = "k3", .tools = true, .web_search = true, .thinking = 8192, .effort = .high });
    try t.expect(std.mem.indexOf(u8, ge_tools.body, "\"tools\":[{\"functionDeclarations\":[{\"name\":\"search_tabs\"") != null);
    try t.expect(std.mem.indexOf(u8, ge_tools.body, "{\"googleSearch\":{}},{\"urlContext\":{}}") != null);
    try t.expect(std.mem.indexOf(u8, ge_tools.body, "\"thinkingConfig\":{\"thinkingBudget\":8192}") != null);
    try t.expect(std.mem.indexOf(u8, ge_tools.body, "{\"functionCall\":{\"name\":\"search_history\",\"args\":{\"query\":\"kea\"}}}") != null);
    try t.expect(std.mem.indexOf(u8, ge_tools.body, "{\"functionResponse\":{\"name\":\"search_history\",\"response\":{\"result\":\"[{\\\"title\\\":\\\"Kea\\\",\\\"url\\\":\\\"https://kea.example/\\\"}]\"}}}") != null);

    const or_plugins = try client.request(rig.ai, a, .{ .provider = ai.openRouter, .model = "google/gemini-3.8-flash", .system = "S", .messages = msgs[0..1], .key = "k", .web_search = true, .effort = .high });
    try t.expect(std.mem.indexOf(u8, or_plugins.body, "\"plugins\":[{\"id\":\"web\"}]") != null);
    try t.expect(std.mem.indexOf(u8, or_plugins.body, "\"reasoning\":{\"effort\":\"high\"}") != null);
}

test "allowed: a provider's own host only" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const m = rig.ai;
    try t.expect(client.allowed(m, "https://api.openai.com/v1/models", ai.openAI));
    try t.expect(!client.allowed(m, "http://api.openai.com/v1/models", ai.openAI));
    try t.expect(!client.allowed(m, "https://evil.com/v1/models", ai.openAI));
    try t.expect(!client.allowed(m, "https://user:pw@api.openai.com/v1/", ai.openAI));
    try t.expect(client.allowed(m, "http://127.0.0.1:11434/api/tags", ai.ollama));
    try t.expect(!client.allowed(m, "http://localhost:11434/api/tags", ai.ollama));
    try t.expect(client.allowed(m, "http://127.0.0.1:8080/v1/chat/completions", ai.custom));
    // A test run's stand-in, on the loopback address only.
    m.mock = try t.allocator.dupe(u8, "http://127.0.0.1:9999/");
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("http://127.0.0.1:9999/anthropic/", try m.base(arena.allocator(), ai.anthropic));
    try t.expect(client.allowed(m, "http://127.0.0.1:9999/anthropic/messages", ai.anthropic));
}

test "models: each way of listing" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ol = (try more.modelsRequest(rig.ai, a, ai.ollama, null)).?;
    try t.expectEqualStrings("http://127.0.0.1:11434/api/tags", ol.url);
    try t.expectEqual(@as(?f64, 2), ol.timeout);
    const ge = (try more.modelsRequest(rig.ai, a, ai.gemini, "k")).?;
    try t.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", ge.url);
    try t.expect((try more.modelsRequest(rig.ai, a, ai.anthropic, null)) == null);

    const names = try more.modelNames(a, ai.ollama, "{\"models\":[{\"name\":\"llama3\"},{\"name\":\"gpt-oss:cloud\"},{\"name\":\"x\",\"remote_host\":\"h\"},{\"name\":\"q-cloud\"}]}");
    try t.expectEqual(@as(usize, 1), names.len);
    try t.expectEqualStrings("llama3", names[0]);
    const g = try more.modelNames(a, ai.gemini, "{\"models\":[{\"name\":\"models/b\",\"supportedGenerationMethods\":[\"generateContent\"]},{\"name\":\"models/e\",\"supportedGenerationMethods\":[\"embedContent\"]},{\"name\":\"models/a\",\"supportedGenerationMethods\":[\"generateContent\"]}]}");
    try t.expectEqual(@as(usize, 2), g.len);
    try t.expectEqualStrings("a", g[0]);
    const o = try more.modelNames(a, ai.openAI, "{\"data\":[{\"id\":\"z\"},{\"id\":\"b\"}]}");
    try t.expectEqualStrings("b", o[0]);
}
