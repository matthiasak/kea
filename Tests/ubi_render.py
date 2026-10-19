#!/usr/bin/env python3
"""Markdown block parser and clean-room Mermaid renderer in Ubi Chat."""
import os
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ubi-render")

FIXTURE = """## Plan

1. First
2. Second
   - nested a
   - nested b
3. Third

> Quote
> - inside

| a | b | c |
|---|:-:|--:|
| 1 | 2 | 3 |
| 4 | 5 |

```swift
let x = 1
```

---

Plain ~~old~~ **new** `code`"""

FLOW_TD = """```mermaid
flowchart TD
A[Start] --> B{Is it?}
B -->|Yes| C(Do it)
B -- No --> D([Stop])
C & D --> E((End))
```"""

FLOW_LR = """```mermaid
flowchart LR
A --> B --> C
```"""

SEQUENCE = """```mermaid
sequenceDiagram
participant A as Alice
participant B as Bob
A->>B: Hello
B-->>A: Hi
A-)C: Async
Note over A,B: talk
loop Every minute
B->>B: self
end
```"""

PIE = """```mermaid
pie title Pets
"Dogs" : 386
"Cats" : 85
"Rats" : 15
```"""

STATE = """```mermaid
stateDiagram-v2
[*] --> Still
Still --> Moving : push
Moving --> Still
Moving --> Crash
Crash --> [*]
```"""

CLASS = """```mermaid
classDiagram
class Animal {
+String name
+eat()
}
Animal <|-- Duck
Animal <|-- Fish
Duck : +swim()
```"""


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        ai = lambda **f: sv.cmd({"do": "ai", "action": "render", **f})

        # 1. Markdown fixture
        r = ai(text=FIXTURE)
        blocks = r["blocks"]
        kinds = [b["kind"] for b in blocks]
        t.ok("markdown fixture block kinds in order",
             kinds == ["heading", "list", "quote", "table", "code", "rule", "paragraph"], kinds)
        t.ok("heading level 2 Plan",
             blocks[0].get("level") == 2 and blocks[0].get("text") == "Plan", blocks[0])
        item2 = blocks[1]["items"][1] if len(blocks) > 1 and len(blocks[1].get("items", [])) >= 2 else []
        t.ok("ordered list with nested unordered list under item 2",
             blocks[1].get("ordered") is True and blocks[1].get("start") == 1
             and len(blocks[1].get("items", [])) == 3
             and [x["kind"] for x in item2] == ["paragraph", "list"]
             and item2[0].get("text") == "Second"
             and item2[1].get("ordered") is False and len(item2[1].get("items", [])) == 2,
             blocks[1])
        t.ok("quote holds paragraph and list",
             [x["kind"] for x in blocks[2].get("blocks", [])] == ["paragraph", "list"], blocks[2])
        t.ok("table has 3 columns and 2 rows",
             blocks[3].get("columns") == 3 and blocks[3].get("rows") == 2, blocks[3])
        t.ok("code block swift closed",
             blocks[4].get("language") == "swift" and blocks[4].get("closed") is True, blocks[4])

        # 2. Unclosed fence
        u = ai(text="```python\nprint(1)")["blocks"]
        t.ok("unclosed fence parses as open code block",
             len(u) == 1 and u[0].get("kind") == "code" and u[0].get("closed") is False, u)

        # 3. Diagrams
        d_td1 = ai(text=FLOW_TD)["diagrams"][0]
        d_td2 = ai(text=FLOW_TD)["diagrams"][0]
        t.ok("flowchart TD has 5 nodes, 5 edges, and deterministic size",
             d_td1.get("kind") == "flowchart" and d_td1.get("nodes") == 5 and d_td1.get("edges") == 5
             and d_td1.get("width") == d_td2.get("width") and d_td1.get("height") == d_td2.get("height"),
             (d_td1, d_td2))

        d_lr = ai(text=FLOW_LR)["diagrams"][0]
        t.ok("flowchart LR has 3 nodes, 2 edges, width > height",
             d_lr.get("kind") == "flowchart" and d_lr.get("nodes") == 3 and d_lr.get("edges") == 2
             and d_lr.get("width", 0) > d_lr.get("height", 0), d_lr)

        d_seq = ai(text=SEQUENCE)["diagrams"][0]
        t.ok("sequenceDiagram has 3 participants and 4 messages",
             d_seq.get("kind") == "sequence" and d_seq.get("nodes") == 3 and d_seq.get("edges") == 4, d_seq)

        d_pie = ai(text=PIE)["diagrams"][0]
        t.ok("pie chart has 3 slices",
             d_pie.get("kind") == "pie" and d_pie.get("nodes") == 3, d_pie)

        d_state = ai(text=STATE)["diagrams"][0]
        t.ok("stateDiagram-v2 has 5 nodes and 5 edges",
             d_state.get("kind") == "state" and d_state.get("nodes") == 5 and d_state.get("edges") == 5, d_state)

        d_class = ai(text=CLASS)["diagrams"][0]
        t.ok("classDiagram has 3 classes and 2 relations",
             d_class.get("kind") == "class" and d_class.get("nodes") == 3 and d_class.get("edges") == 2, d_class)

        d_gantt = ai(text="```mermaid\ngantt\ntitle A\n```")["diagrams"][0]
        t.ok("unsupported gantt falls back to source", d_gantt.get("kind") == "source", d_gantt)

        d_partial = ai(text="```mermaid\nflowchart TD\nA -->\n--> B\nC[unclosed\n```")["diagrams"][0]
        t.ok("malformed flowchart edges ignored without crash",
             d_partial.get("kind") == "flowchart" and d_partial.get("edges") == 0, d_partial)

        chain = " --> ".join(f"N{i}" for i in range(200))
        d_cap = ai(text=f"```mermaid\nflowchart TD\n{chain}\n```")["diagrams"][0]
        t.ok("200-node chain exceeds cap and falls back to source", d_cap.get("kind") == "source", d_cap)

        # 4. Fuzz
        rng = random.Random(7)
        vocab = [
            "flowchart TD", "graph LR", "sequenceDiagram", "pie", "stateDiagram", "classDiagram",
            "A", "B", "-->", "--", "-.->", "|x|", "[", "]", "(", ")", "{", "}", ":", "\n", ";",
            "<|--", "->>", "[*]", "\"", "&", "%%", "title", "```", "```mermaid", "- ", "1. ",
            "> ", "| a |", "|---|", "#",
        ]
        fuzz_ok = True
        for _ in range(300):
            sample = " ".join(rng.choice(vocab) for _ in range(rng.randint(5, 60)))
            if "blocks" not in ai(text=sample):
                fuzz_ok = False
                break
            if "blocks" not in ai(text=f"```mermaid\n{sample}\n```"):
                fuzz_ok = False
                break
        probe = sv.cmd({"do": "probe"})
        t.ok("300 random Markdown + Mermaid fuzz inputs never crash", fuzz_ok and bool(probe))

        # 5. Picture
        pic_path = "/tmp/kea-render/render.png"
        full_doc = "\n\n".join([FIXTURE, FLOW_TD, SEQUENCE, PIE])
        pic = ai(text=full_doc, path=pic_path)
        t.ok("render picture written to /tmp/kea-render/render.png",
             pic.get("made") == pic_path and os.path.exists(pic_path), pic)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
