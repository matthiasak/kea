#!/usr/bin/env python3
"""Organize with AI: the bookmark list sent to a stand-in provider, its answer read.

Build first (`./build.sh release test`), then `python3 Tests/bookmarks_ai.py`. Drives the
bench's `ai organize` and `ai apply` against a stand-in on this Mac: invented,
repeated and left-out numbers, empty folders and chatter around the JSON are
handled; Apply is one undoable change, and refused when the list changed since.
"""
import json
import os
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-ai")

REPLY = ""
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
            chunk = {"choices": [{"delta": {"content": REPLY[i:i + third]}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


def titles(nodes):
    return [n["title"] for n in nodes]


def organize(**f):
    return sv.cmd({"do": "ai", "action": "organize", "provider": "openAI", "model": "m", **f})


def main():
    global REPLY
    server = ThreadingHTTPServer(("127.0.0.1", 0), Standin)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    t = sv.T()
    try:
        sv.setup()
        os.makedirs(sv.SUPPORT, exist_ok=True)
        ids = {}

        def node(title, url=None, kids=None):
            ids[title] = str(uuid.uuid4()).upper()
            made = {"id": ids[title], "title": title}
            if url: made["url"] = url
            if kids is not None: made["children"] = kids
            return made

        seed = [node("s1", "https://news.example/a") | {"title": "Daily News"},
                node("s2", "https://shop.example/") | {"title": "Shop"},
                node("s3", "https://news.example/b") | {"title": "Morning News"},
                node("s4", "https://news.example/a") | {"title": "Daily News again"},
                node("A", kids=[node("a1", "https://food.example/r") | {"title": "Recipe"}]),
                node("B", kids=[node("b1", "https://docs.example/d") | {"title": "Docs"}])]
        json.dump(seed, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        sv.cmd({"do": "ai", "action": "mock", "url": f"http://127.0.0.1:{server.server_port}"})
        sv.cmd({"do": "ai", "action": "key", "provider": "openAI", "key": "sk-test"})
        start = sv.cmd({"do": "bookmarks", "action": "tree"})["tree"]

        REPLY = ('```json\n{"tree":[{"folder":"News","items":[1,3,99,1]},{"folder":"Empty","items":[]},'
                 '{"folder":"Life","items":[5,{"folder":"Deep","items":[2]}]}],"remove":[4,3]}\n```')
        got = organize()
        tree = got.get("tree", [])
        by = lambda name, nodes=tree: next((n for n in nodes if n["title"] == name), {})
        life = by("Life")
        t.ok("top level is News, Life, then Docs left out", titles(tree) == ["News", "Life", "Docs"], titles(tree))
        t.ok("News holds the two placed once", titles(by("News").get("children", [])) == ["Daily News", "Morning News"], got)
        t.ok("Life holds Recipe and Deep, Deep holds Shop",
             titles(life.get("children", [])) == ["Recipe", "Deep"]
             and titles(by("Deep", life.get("children", [])).get("children", [])) == ["Shop"], got)
        t.ok("only the unplaced number is removed", got.get("removed") == ["Daily News again"], got)
        t.ok("one bookmark left out", got.get("leftOut") == 1, got)

        path, body = seen[-1]
        messages = body["messages"]
        t.ok("the request went to the provider with 8192 tokens",
             path == "/openAI/chat/completions" and body.get("max_completion_tokens") == 8192, (path, body.get("max_completion_tokens")))
        t.ok("system message names the task",
             messages[0]["role"] == "system" and "You organize one person's browser bookmarks" in messages[0]["content"], messages[0])
        user = messages[-1]["content"]
        t.ok("the list, its folders and the standing instruction are sent",
             "1. Daily News — news.example/a" in user and "(in: A)" in user
             and "My instruction: Sensible grouping, flatten all folders into one top-level folder" in user, user)

        applied = sv.cmd({"do": "ai", "action": "apply"})
        t.ok("apply puts the proposal in, and lets go of it", applied["tree"] == tree and applied["held"] is False, applied)
        undone = sv.cmd({"do": "bookmarks", "action": "undo"})["tree"]
        t.ok("one undo restores the seed exactly", undone == start, titles(undone))

        organize(text="by topic")
        t.ok("a typed instruction replaces the standing one", seen[-1][1]["messages"][-1]["content"].endswith("My instruction: by topic"))

        organize()
        after = sv.cmd({"do": "bookmarks", "action": "remove", "ids": [ids["b1"]]})["tree"]
        refused = sv.cmd({"do": "ai", "action": "apply"})
        t.ok("a list changed since is not overwritten", refused["tree"] == after and refused["held"] is False, titles(refused["tree"]))

        REPLY = "Sorry, I can't help with that."
        try:
            organize()
            unreadable = False
        except RuntimeError as e:
            unreadable = str(e).endswith("unreadable")
        t.ok("an answer that isn't a list is unreadable", unreadable)
    finally:
        t.done(); sv.finish()
        server.shutdown()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
