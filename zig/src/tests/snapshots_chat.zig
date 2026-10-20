//! P9 snapshot state: Ubi Chat open in its column with one finished turn.
const std = @import("std");
const Fixture = @import("ui/fixture.zig").Fixture;
const app = @import("kea");

/// The answer: a heading, a list and inline code.
const answer =
    \\## The kea
    \\
    \\The **kea** is a parrot of New Zealand's Southern Alps.
    \\
    \\- Curious and playful
    \\- Lives above the tree line
    \\- Eats roots, leaves and insects
    \\
    \\Its Latin name is `Nestor notabilis`.
;

pub fn chat(f: *Fixture) void {
    // The model the turn names, in the picker too.
    f.kea.prefs.set("ai_provider", "ollama");
    f.kea.prefs.setAIModel("llama3.2", "ollama");
    const a = f.browser.openChat() orelse return;
    const Chat = @TypeOf(a.chat);
    const Turn = std.meta.Child(@TypeOf(a.chat.turns));
    a.mutate({}, struct {
        fn put(_: void, al: std.mem.Allocator, ch: *Chat) error{OutOfMemory}!void {
            const list = try al.alloc(Turn, 1);
            list[0] = .{ .id = app.json.Uuid.random(), .question = "Tell me about the kea", .answer = answer, .done = true, .place = "on this Mac · Ollama · llama3.2" };
            ch.turns = list;
            ch.title = "Kea facts";
        }
    }.put);
}
