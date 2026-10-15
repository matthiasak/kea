#!/usr/bin/env python3
"""Ubi Chat: a chat column kept on this Mac, with pages pinned to it.

Build first (`./build.sh release test`), then `python3 Tests/ubi_chat.py`. Drives the
bench's `ai` verbs against a stand-in provider on this Mac: what each
question sends (the page in front, pinned pages, the chat so far), the eye,
tabs/ and @ pins, slash commands, Star and Make It a Task, rich + Markdown
copy, a private tab's chat refused off this Mac and never written, chats
kept across a relaunch, and the column taking its width from the page.
"""
import json
import os
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ubi-chat")

REPLY = "## Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- **one**\n- `two`\n\nSee [docs](https://example.com/docs)."
HTML = ('<meta charset="utf-8"><h2>Plan</h2><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>'
        '<ul><li><strong>one</strong></li><li><code>two</code></li></ul><p>See <a href="https://example.com/docs">docs</a>.</p>')
seen = []


class Standin(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        seen.append((self.path, body))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        third = len(REPLY) // 3 + 1
        for i in range(0, len(REPLY), third):
            self.wfile.write(f"data: {json.dumps({'choices': [{'delta': {'content': REPLY[i:i + third]}}]})}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


def ai(action, **f):
    return sv.cmd({"do": "ai", "action": action, **f})


def answered(n, within=20):
    """The state once the chat on screen has n turns, the nth done."""
    until = time.time() + within
    while True:
        st = ai("state")
        turns = st.get("turns", [])
        if (len(turns) >= n and turns[n - 1]["done"]) or time.time() > until:
            return st
        time.sleep(0.2)


def last_user():
    return seen[-1][1]["messages"][-1]["content"] if seen else ""


def right_edge(tab, within=3):
    """Where the page's web view ends on the right, once it is laid out."""
    until = time.time() + within
    while True:
        f = next((f for f in sv.sp("state")["paneFrames"] if f["id"] == tab), None)
        if f or time.time() > until:
            return f and f["x"] + f["width"]
        time.sleep(0.2)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Standin)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    t = sv.T()
    try:
        sv.setup()
        os.makedirs(sv.SUPPORT, exist_ok=True)
        json.dump([{"id": str(uuid.uuid4()).upper(), "title": "Gamma docs", "url": f"{sv.BASE}/gamma"}],
                  open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        ai("mock", url=f"http://127.0.0.1:{server.server_port}")
        ai("key", provider="openAI", key="sk-test")
        ai("use", provider="openAI", model="m")
        a = sv.page("alpha")
        sv.page("beta")
        p = sv.cmd({"do": "open", "url": f"{sv.BASE}/secret", "private": True})["id"]

        sv.cmd({"do": "select", "id": a})
        before = right_edge(a)
        ai("question", id=a, text="What is this?")
        time.sleep(0.5)
        after = right_edge(a)
        t.ok("the column takes 380 points from the page", before and after and abs(before - after - 380) < 2, (before, after))
        st = ai("state")
        t.ok("a first question waits on the notice", "kept on this Mac only" in st["notice"] and not seen, st["notice"])
        ai("agree")
        st = answered(1)
        path, body = seen[-1]
        t.ok("it goes to the provider, as Ubi Chat", path == "/openAI/chat/completions" and body["messages"][0]["role"] == "system"
             and "Ubi Chat" in body["messages"][0]["content"] and body["max_completion_tokens"] == 4096, path)
        t.ok("with the page in front, fenced, and the question",
             f"Page address: {sv.BASE}/alpha" in last_user() and last_user().count("/alpha") >= 2
             and last_user().rstrip().endswith("What is this?"), last_user()[-300:])
        t.ok("the answer arrives whole", st["turns"][0]["answer"] == REPLY and st["turns"][0]["place"] == "sent to OpenAI · m", st["turns"][0])
        time.sleep(0.5)
        strays = ai("state")["turns"][0]["strays"]
        t.ok("an address the page doesn't have is pointed out", any("example.com/docs" in s for s in strays), strays)

        sug = ai("type", text="tabs/bet")["suggestions"]
        t.ok("tabs/ finds an open tab", bool(sug) and sug[0]["url"] == f"{sv.BASE}/beta" and sug[0]["source"] == "tab", sug)
        st = ai("pick", index=0)
        t.ok("picking it pins it and takes the word out",
             [x["url"] for x in st["chat"]["pins"]] == [f"{sv.BASE}/beta"] and st["draft"] == "", st["chat"]["pins"])
        sug = ai("type", text="@gam")["suggestions"]
        t.ok("@ finds a bookmark", any(s["title"] == "Gamma docs" and s["source"] == "bookmark" for s in sug), sug)
        ai("type", text="Compare them")
        ai("submit")
        answered(2)
        msgs = seen[-1][1]["messages"]
        t.ok("the chat so far goes along", len(msgs) == 4 and msgs[1]["content"] == "What is this?" and msgs[2]["content"] == REPLY,
             [m["role"] for m in msgs])
        t.ok("with the pinned page beside the page in front",
             f"Page address: {sv.BASE}/beta" in last_user() and f"Page address: {sv.BASE}/alpha" in last_user(), last_user()[:400])
        t.ok("the eye closes", ai("eye")["chat"]["pageHidden"] is True)
        ai("type", text="Again")
        ai("submit")
        answered(3)
        t.ok("a closed eye leaves the page out and the pin in",
             "/alpha" not in last_user() and f"Page address: {sv.BASE}/beta" in last_user(), last_user()[:400])
        c = ai("copy", turn=0)
        t.ok("copy is the Markdown, and HTML made from it", c["markdown"] == REPLY and c["html"] == HTML, c["html"])
        ai("type", text="/rename-ws Trip")
        t.ok("/rename-ws names the chat", ai("submit")["chat"]["title"] == "Trip")
        ai("type", text="/clear-pins")
        t.ok("/clear-pins unpins", ai("submit")["chat"]["pins"] == [])
        ai("chat", what="star")
        st = ai("chat", what="task")
        trip = st["chat"]["id"]
        t.ok("Star and Make It a Task", st["chat"]["starred"] and st["chat"]["task"], st["chat"])

        ai("close")
        n = len(seen)
        ai("question", id=p, text="hi")
        time.sleep(1)
        st = ai("state")
        t.ok("a private tab's chat is refused off this Mac", st["shy"] and st["turns"] == [] and len(seen) == n,
             (st["shy"], len(seen) - n))
        ai("close")
        ai("question", id=a, text="x")
        answered(1)
        sv.cmd({"do": "select", "id": p})
        time.sleep(0.5)
        ai("type", text="y")
        ai("submit")
        answered(2)
        t.ok("a private page in front is never sent with a kept chat", last_user() == "y", last_user()[:200])

        ai("close")
        ai("use", provider="custom", model="llama-3")
        ai("question", id=a, text="Custom server question")
        st = answered(1)
        path, body = seen[-1]
        t.ok("custom server answers through Ubi Chat without a key or notice",
             path == "/custom/chat/completions" and st["turns"][0]["answer"] == REPLY
             and st["turns"][0]["place"] == "on 127.0.0.1 · llama-3", (path, st["turns"][0]))

        sv.quit()
        sv.launch()
        kept = json.load(open(f"{sv.SUPPORT}/chats.json"))
        mine = next((c for c in kept if c["id"] == trip), None)
        t.ok("chats are kept across a relaunch",
             bool(mine) and mine["title"] == "Trip" and mine["starred"] and mine["task"] and len(mine["turns"]) == 3, mine and mine["title"])
        t.ok("a private tab's chat is never written", not any(turn["question"] == "hi" for c in kept for turn in c["turns"]))
        st = ai("chat", what="open", chat=trip)
        t.ok("a kept chat opens again", st["chat"]["title"] == "Trip" and len(st["turns"]) == 3, len(st["turns"]))
        made = ai("picture", path=tempfile.mkdtemp())["made"]
        t.ok("the column draws", any(m.endswith("ai-panel.png") for m in made), made)

        sv.setup(splitView=True)
        sv.launch()
        left = sv.page("left")
        right = sv.page("right")
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(0.5)
        before = right_edge(right)
        ai("question", id=left)
        time.sleep(0.5)
        after = right_edge(right)
        t.ok("in Split View the column takes its width from the pages", before and after and abs(before - after - 380) < 2, (before, after))
    finally:
        t.done(); sv.finish()
        server.shutdown()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
