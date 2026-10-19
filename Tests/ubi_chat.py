#!/usr/bin/env python3
"""Ubi Chat: a chat column kept on this Mac, with pages pinned to it.

Build first (`./build.sh release test`), then `python3 Tests/ubi_chat.py`. Drives the
bench's `ai` verbs against a stand-in provider on this Mac: what each
question sends (the page in front, pinned pages, the chat so far), the eye,
tabs/ and @ pins, slash commands, Star and Make It a Task, sessions,
compaction, clean-up, zoom, rich + Markdown copy, a private tab's chat
refused off this Mac and never written, chats kept across a relaunch, and
the column taking its width from the page.
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

NAMING, COMPACTING = "Name this chat", "Summarize the conversation so far"


def system_of(s):
    m = s[1].get("messages") or [{}]
    return m[0].get("content", "") if m[0].get("role") == "system" else ""


def asks():
    return [s for s in seen if not system_of(s).startswith((NAMING, COMPACTING))]


def until(check, within=10):
    end = time.time() + within
    while True:
        st = ai("state")
        if check(st) or time.time() > end:
            return st
        time.sleep(0.2)


class Standin(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        seen.append((self.path, body))
        msgs = body.get("messages") or []
        if msgs and msgs[-1].get("content", "").endswith("FAIL"):
            self.send_response(500)
            self.end_headers()
            return
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
    a = asks()
    return a[-1][1]["messages"][-1]["content"] if a else ""

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
        t.ok("a first question waits on the notice", "kept on this Mac, and on your other Macs if Sync carries them" in st["notice"] and not seen, st["notice"])
        ai("agree")
        st = answered(1)
        path, body = asks()[-1]
        t.ok("it goes to the provider, as Ubi Chat", path == "/openAI/chat/completions" and body["messages"][0]["role"] == "system"
             and "Ubi Chat" in body["messages"][0]["content"] and body["max_completion_tokens"] == 4096, path)
        t.ok("with the page in front, fenced, and the question",
             f"Page address: {sv.BASE}/alpha" in last_user() and last_user().count("/alpha") >= 2
             and last_user().rstrip().endswith("What is this?"), last_user()[-300:])
        t.ok("the answer arrives whole", st["turns"][0]["answer"] == REPLY and st["turns"][0]["place"] == "sent to OpenAI · m", st["turns"][0])
        time.sleep(0.5)
        strays = ai("state")["turns"][0]["strays"]
        t.ok("an address the page doesn't have is pointed out", any("example.com/docs" in s for s in strays), strays)
        st = until(lambda s: s["chat"]["title"] != "")
        names = [s for s in seen if system_of(s).startswith(NAMING)]
        t.ok("the model names the chat after its first answer",
             st["chat"]["title"] == "Plan" and len(names) == 1 and names[0][1].get("max_completion_tokens") == 2048,
             (st["chat"]["title"], len(names)))

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
        msgs = asks()[-1][1]["messages"]
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
        path, body = asks()[-1]
        t.ok("custom server answers through Ubi Chat without a key or notice",
             path == "/custom/chat/completions" and st["turns"][0]["answer"] == REPLY
             and st["turns"][0]["place"] == "on 127.0.0.1 · llama-3", (path, st["turns"][0]))

        sv.quit()
        sv.launch()
        kept = json.load(open(f"{sv.SUPPORT}/chats/index.json"))
        mine = next((c for c in kept if c["id"] == trip), None)
        t.ok("chats are kept across a relaunch",
             bool(mine) and mine["title"] == "Trip" and mine["starred"] and mine["task"] and mine["turns"] == 3, mine and mine["title"])
        chat_files = [p for p in Path(sv.SUPPORT, "chats").glob("*.json") if p.name != "index.json"]
        t.ok("a private tab's chat is never written",
             bool(chat_files) and not any(turn["question"] == "hi" for p in chat_files for turn in json.load(open(p)).get("turns", [])))
        st = ai("chat", what="open", chat=trip)
        t.ok("a kept chat opens again", st["chat"]["title"] == "Trip" and len(st["turns"]) == 3, len(st["turns"]))

        ai("mock", url=f"http://127.0.0.1:{server.server_port}")
        n = len(seen)
        ai("chat", what="compact")
        st = until(lambda s: s["chat"]["compacted"] == 1 and not s["compacting"])
        comp_reqs = [s for s in seen[n:] if system_of(s).startswith(COMPACTING)]
        t.ok("compact folds earlier turns into a summary",
             st["chat"]["summary"] == REPLY and len(st["turns"]) == 3 and len(comp_reqs) == 1
             and comp_reqs[0][1]["messages"][1]["content"] == "What is this?",
             (st["chat"], len(comp_reqs)))

        ai("type", text="After")
        ai("submit")
        answered(4)
        msgs = asks()[-1][1]["messages"]
        t.ok("after compact, requests send the summary and recent turns",
             len(msgs) == 8 and msgs[1]["content"].endswith(REPLY)
             and msgs[2]["content"] == "Understood." and msgs[3]["content"] == "Compare them",
             [m["role"] for m in msgs])

        ai("type", text="FAIL")
        ai("submit")
        st = answered(5)
        t.ok("failed turn recorded before clean-up", bool(st["turns"][4]["failed"]), st["turns"][4])
        st = ai("chat", what="cleanup")
        t.ok("clean-up removes failed turns and keeps compaction",
             len(st["turns"]) == 4 and not any(x["failed"] for x in st["turns"]) and st["chat"]["compacted"] == 1,
             st["turns"])

        t.ok("rename updates chat title", ai("chat", what="rename", name="Kept")["chat"]["title"] == "Kept")
        c = ai("chat", what="clone")
        first_clone = c["chat"]["id"]
        t.ok("clone duplicates turns and compaction with (copy) title",
             first_clone != trip and c["chat"]["title"] == "Kept (copy)"
             and len(c["turns"]) == 4 and c["chat"]["compacted"] == 1 and c["chat"]["starred"] is False,
             c["chat"])

        clones = [first_clone]
        for _ in range(5):
            clones.append(ai("chat", what="clone", chat=trip)["chat"]["id"])
        for cid in clones:
            ai("chat", what="star", chat=cid)
        secs = ai("sessions")["sections"]
        starred_sec = next((s for s in secs if s["title"] == "Starred"), None)
        secs_all = ai("sessions", all=True)["sections"]
        starred_all = next((s for s in secs_all if s["title"] == "Starred"), None)
        secs_q = ai("sessions", query="copy")["sections"]
        t.ok("sessions caps Starred at 5 with more=1, all=True shows 6, and query filters",
             bool(starred_sec) and len(starred_sec["items"]) == 5 and starred_sec["more"] == 1
             and bool(starred_all) and len(starred_all["items"]) == 6 and starred_all["more"] == 0
             and len(secs_q) == 1 and len(secs_q[0]["items"]) == 6,
             (starred_sec, starred_all, secs_q))

        del_id = clones[-1]
        ai("chat", what="delete", chat=del_id)
        time.sleep(0.3)
        idx_after = json.load(open(f"{sv.SUPPORT}/chats/index.json"))
        t.ok("delete removes the chat file and index entry",
             not Path(sv.SUPPORT, "chats", f"{del_id}.json").exists()
             and not any(e["id"] == del_id for e in idx_after),
             del_id)

        ai("chat", what="open", chat=trip)
        ai("pin")
        z = 1.0
        for _ in range(12):
            z = ai("zoom", by=1)["zoom"]
        z80 = ai("zoom", value=0.8)["zoom"]
        def_z = os.popen(f"defaults read {sv.SUITE} ai.zoom").read().strip()
        t.ok("zoom clamps at 2.0, sets 0.8, and persists ai.zoom",
             z == 2.0 and z80 == 0.8 and float(def_z or 0) == 0.8, (z, z80, def_z))

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
