//! P9 snapshot states: an answer's Markdown and a Mermaid diagram, as Ubi
//! Chat draws them, filling the window.
const Fixture = @import("ui/fixture.zig").Fixture;
const Answer = @import("ui/markdown.zig").Answer;

var shown: ?Answer = null;

fn show(f: *Fixture, text: []const u8) void {
    shown = .{ .b = f.browser, .text = text };
    shown.?.show(f);
}

/// What `show` kept, let go of before the fixture is.
pub fn done(f: *Fixture) void {
    if (shown) |*s| s.st.deinit(f.gpa);
    shown = null;
}

pub fn markdown(f: *Fixture) void {
    show(f,
        \\# Keas of the Alps
        \\## Where they live
        \\Keas are **clever** parrots of New Zealand's *Southern Alps*, known for `curiosity` and ~~shyness~~. Read more on [Wikipedia](https://en.wikipedia.org/wiki/Kea).
        \\
        \\1. Find a high pass
        \\2. Wait for a *kea*
        \\   - it finds you
        \\   - and your car
        \\
        \\> Keas have been seen opening rubbish bins.
        \\
        \\| Trait | Kea | Kākā |
        \\|---|---|---|
        \\| Habitat | Alpine | Forest |
        \\| Weight | 1 kg | 0.5 kg |
        \\
        \\---
        \\
        \\```zig
        \\const kea = "parrot";
        \\```
    );
}

pub fn mermaid(f: *Fixture) void {
    show(f,
        \\```mermaid
        \\flowchart TD
        \\  A[Sees a car] --> B{Rubber?}
        \\  B -->|yes| C(Chews it)
        \\  B -.->|no| D([Flies off])
        \\  C ==> E((Done))
        \\```
        \\
        \\```mermaid
        \\pie title Day
        \\  "Play" : 50
        \\  "Eat" : 30
        \\  "Sleep" : 20
        \\```
    );
}
