#!/usr/bin/env python3
"""Headless Swift Kea reference capture (run from /tmp/sb)."""
import json, os, shutil, sqlite3, struct, subprocess, sys, time, urllib.parse, uuid, zlib
from pathlib import Path
MAIN_REPO = "/Users/keas/code/search-browser"
if os.path.realpath(os.getcwd()) == os.path.realpath(MAIN_REPO) and os.environ.get("KEA_REF_ALLOW_CWD") != "1":
    sys.exit(f"Refusing to run in {MAIN_REPO}; run from the /tmp/sb copy instead.")

sys.path.insert(0, "Tests")
import split_view as sv  # noqa: E402

sv.use("kea-ref")


def _patched_do_get(self):
    port = self.server.server_port
    if self.path == "/asker":
        body = f"<!doctype html><title>asker</title><iframe src='http://localhost:{port}/frame'></iframe>".encode()
    elif self.path == "/frame":
        body = b"<!doctype html><script>setTimeout(function(){ alert('from the frame') }, 1200)</script>"
    else:
        title = urllib.parse.unquote(self.path.strip("/"))
        body = f"<!doctype html><title>{title}</title><p>{self.path}".encode()
    self.send_response(200)
    self.send_header("Content-Type", "text/html")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)


sv.H.do_GET = _patched_do_get

MARKDOWN_TEXT = """# Keas of the Alps
## Where they live
Keas are **clever** parrots of New Zealand's *Southern Alps*, known for `curiosity` and ~~shyness~~. Read more on [Wikipedia](https://en.wikipedia.org/wiki/Kea).

1. Find a high pass
2. Wait for a *kea*
   - it finds you
   - and your car

> Keas have been seen opening rubbish bins.

| Trait | Kea | Kākā |
|---|---|---|
| Habitat | Alpine | Forest |
| Weight | 1 kg | 0.5 kg |

---

```zig
const kea = "parrot";
```"""

MERMAID_TEXT = """```mermaid
flowchart TD
  A[Sees a car] --> B{Rubber?}
  B -->|yes| C(Chews it)
  B -.->|no| D([Flies off])
  C ==> E((Done))
```

```mermaid
pie title Day
  "Play" : 50
  "Eat" : 30
  "Sleep" : 20
```"""

CHAT_ANSWER = """## The kea

The **kea** is a parrot of New Zealand's Southern Alps.

- Curious and playful
- Lives above the tree line
- Eats roots, leaves and insects

Its Latin name is `Nestor notabilis`."""

EXT_MANIFEST = json.dumps({"manifest_version": 3, "name": "Kea Fixture", "version": "1.0", "action": {"default_popup": "popup.html", "default_title": "Kea Fixture"}})
EXT_POPUP = "<!doctype html><title>Fixture Popup</title><body>The fixture's popup</body>"

def read_reduce_motion():
    r = subprocess.run(["defaults", "read", "com.apple.universalaccess", "reduceMotion"], capture_output=True, text=True)
    return 1 if r.stdout.strip().lower() in ("1", "true", "yes") else 0

def png_dimensions(path):
    try:
        with open(path, "rb") as f:
            hdr = f.read(24)
        if len(hdr) >= 24 and hdr[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", hdr[16:24])
            return [int(w), int(h)], [int(w // 2), int(h // 2)]
    except OSError:
        pass
    return [0, 0], [0, 0]


def seed_support():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    fixtures = Path("zig/src/tests/fixtures/kea")
    for name in ("bookmarks.json", "history.json", "downloads.json", "pins.json", "spaces.json"):
        src = fixtures / name
        if src.exists():
            shutil.copyfile(src, os.path.join(sv.SUPPORT, name))

    chats_dir = os.path.join(sv.SUPPORT, "chats")
    os.makedirs(chats_dir, exist_ok=True)
    chat_id = str(uuid.uuid4()).upper()
    turn_id = str(uuid.uuid4()).upper()
    now_apple = time.time() - 978307200.0
    chat_obj = {"id": chat_id, "title": "Kea facts", "touched": now_apple, "starred": False, "task": False, "pageHidden": False, "pins": [], "turns": [{"id": turn_id, "question": "Tell me about the kea", "answer": CHAT_ANSWER, "done": True, "strays": [], "place": "on this Mac · Ollama · llama3.2"}]}
    index_obj = [{"id": chat_id, "title": "Kea facts", "touched": now_apple, "starred": False, "task": False, "turns": 1}]
    with open(os.path.join(chats_dir, f"{chat_id}.json"), "w") as f: json.dump(chat_obj, f)
    with open(os.path.join(chats_dir, "index.json"), "w") as f: json.dump(index_obj, f)
    chrome_dir = os.path.join(sv.SUPPORT, "Import/Google/Chrome/Default")
    os.makedirs(chrome_dir, exist_ok=True)
    with open(os.path.join(chrome_dir, "Bookmarks"), "w") as f:
        f.write(
            '{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":['
            '{"type":"url","name":"Zig","url":"https://ziglang.org/"},'
            '{"type":"url","name":"Kea","url":"https://kea.example/"}]},'
            '"other":{"type":"folder","name":"Other","children":[]}}}'
        )
    chrome_hist = os.path.join(chrome_dir, "History")
    if os.path.exists(chrome_hist):
        os.remove(chrome_hist)
    con = sqlite3.connect(chrome_hist)
    con.executescript(
        "CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_time INTEGER);"
        "INSERT INTO urls VALUES('https://chrome-one.example/', 'One', 3, 0, 13300000000000000);"
        "INSERT INTO urls VALUES('https://chrome-two.example/', 'Two', 1, 0, 13300000000000001);"
    )
    con.close()

    fox_dir = os.path.join(sv.SUPPORT, "Import/Firefox/Profiles/kea.default")
    os.makedirs(fox_dir, exist_ok=True)
    fox_places = os.path.join(fox_dir, "places.sqlite")
    if os.path.exists(fox_places):
        os.remove(fox_places)
    con = sqlite3.connect(fox_places)
    con.executescript(
        "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER);"
        "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);"
        "INSERT INTO moz_places VALUES(1, 'https://fox.example/', 'Fox', 2, 0, 1700000000000000);"
        "INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, 'toolbar', 'toolbar_____');"
        "INSERT INTO moz_bookmarks VALUES(2, 1, 1, 1, 0, 'Fox', 'foxfoxfoxfox');"
    )
    con.close()

    ext_dir = os.path.join(sv.SUPPORT, "Kea Fixture")
    os.makedirs(ext_dir, exist_ok=True)
    with open(os.path.join(ext_dir, "manifest.json"), "w") as f:
        f.write(EXT_MANIFEST)
    with open(os.path.join(ext_dir, "popup.html"), "w") as f:
        f.write(EXT_POPUP)

    icons_dir = os.path.join(sv.SUPPORT, "icons")
    os.makedirs(icons_dir, exist_ok=True)
    icon_src = Path("zig/src/tests/fixtures/icon.png")
    if icon_src.exists():
        shutil.copyfile(icon_src, os.path.join(icons_dir, "icon-colour.test.png"))

    def write_rgba_png(path, side, inset, r, g, b):
        raw = b"".join(b"\x00" + b"".join((bytes((r, g, b, 255)) if (inset <= x < side - inset and inset <= y < side - inset) else b"\x00\x00\x00\x00") for x in range(side)) for y in range(side))
        chunk = lambda tag, d: struct.pack(">I", len(d)) + tag + d + struct.pack(">I", zlib.crc32(tag + d) & 0xFFFFFFFF)
        open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

    write_rgba_png(os.path.join(icons_dir, "icon-black.test.png"), 128, 24, 0, 0, 0)
    write_rgba_png(os.path.join(icons_dir, "icon-white.test.png"), 128, 24, 255, 255, 255)
    write_rgba_png(os.path.join(icons_dir, "icon-16.test.png"), 128, 0, 40, 140, 220)


def collect_holes():
    holes = []
    seen = set()

    def add_rect(x, y, w, h):
        if w <= 0 or h <= 0:
            return
        key = (round(float(x), 2), round(float(y), 2), round(float(w), 2), round(float(h), 2))
        if key not in seen:
            seen.add(key)
            holes.append({"x": float(x), "y": float(y), "w": float(w), "h": float(h)})

    st = sv.sp("state")
    for pf in st.get("paneFrames", []):
        add_rect(pf["x"], pf["y"], pf["width"], pf["height"])
    pr = sv.cmd({"do": "probe"})
    for field in ("activePageFrame", "peekFrame"):
        r = pr.get(field)
        if isinstance(r, list) and len(r) == 4:
            add_rect(r[0], r[1], r[2], r[3])
    return holes, pr


def write_sidecar(out_dir, name, look, pixels, points, lights, cards, holes, extra=None):
    data = {"pixels": pixels, "points": points, "lights": lights, "cards": bool(cards), "holes": holes}
    if extra: data.update(extra)
    with open(os.path.join(out_dir, f"{name}-{look}.json"), "w") as f: json.dump(data, f, indent=2)

def write_standalone_sidecar(out_dir, name, look, png_path):
    px, pt = png_dimensions(png_path)
    write_sidecar(out_dir, name, look, px, pt, [], False, [])

def capture_picture(out_dir, name, look, settle=0.8):
    if settle > 0: time.sleep(settle)
    png_path = os.path.abspath(os.path.join(out_dir, f"{name}-{look}.png"))
    r = sv.cmd({"do": "picture", "path": png_path, "page": False})
    holes, pr = collect_holes()
    cards = bool(pr.get("sidebar", True)) and not bool(pr.get("folded", False))
    write_sidecar(out_dir, name, look, r.get("pixels", [2880, 1800]), r.get("points", [1440, 900]), r.get("lights", []), cards, holes)
    print(f"captured {name}-{look}.png")
    return r

def open_bg_tabs(want_total):
    cur = len(sv.sp("state").get("tabs", []))
    while cur < want_total:
        sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/Tab%20{cur}", "foreground": False, "atEnd": True})
        cur += 1
    time.sleep(0.8)


def reset_tabs_to(want_total):
    st = sv.sp("state")
    for p_id in st.get("pins", []):
        try:
            sv.cmd({"do": "pin", "id": p_id, "off": True})
        except Exception:
            pass
    for sp_item in st.get("splits", []):
        for tid in sp_item.get("tabs", []):
            try:
                sv.sp("detach", id=tid)
            except Exception:
                pass
    try:
        for grp in sv.sp("state").get("groups", []):
            pass
        for t_item in sv.sp("state").get("tabs", []):
            sv.cmd({"do": "group", "id": t_item["id"], "name": "none"})
    except Exception:
        pass
    tabs = sv.sp("state").get("tabs", [])
    while len(tabs) > want_total and len(tabs) > 1:
        sv.sp("close", id=tabs[-1]["id"])
        tabs = sv.sp("state").get("tabs", [])
    open_bg_tabs(want_total)


def capture_look(out_dir, look, reduce_motion, errors):
    plist = os.path.expanduser(f"~/Library/Preferences/{sv.SUITE}.plist")

    def guard(state_name, fn):
        try:
            fn()
        except Exception as exc:
            print(f"WARN {state_name}-{look}: {exc}", file=sys.stderr)
            errors.append({"state": f"{state_name}-{look}", "error": str(exc)})

    try:
        sv.setup(**{"kea.facts": False, "sidebar": True, "tabs.groups": True, "search.sites": True})
        subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", look], check=True)
        subprocess.run(["defaults", "write", sv.SUITE, "welcomed", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", sv.SUITE, "ai.provider", "-string", "ollama"], check=True)
        subprocess.run(["defaults", "write", sv.SUITE, "ai.model.ollama", "-string", "llama3.2"], check=True)
        seed_support()

        sv.launch()
        sv.cmd({"do": "window"})
        sv.cmd({"do": "resize", "width": 1440, "height": 900, "steps": 1})
        time.sleep(1.0)

        r0 = capture_picture(out_dir, "p0-default", look, settle=0.5)
        if r0.get("points") != [1440, 900]:
            raise RuntimeError(f"Expected points [1440, 900], got {r0.get('points')}")
        pr0 = sv.cmd({"do": "probe"})
        if pr0.get("bookmarkCount", 0) == 0:
            raise RuntimeError(f"Seeded bookmarks did not load: {pr0}")

        open_bg_tabs(4)
        guard("p3-cards", lambda: capture_picture(out_dir, "p3-cards", look))

        def do_column():
            col_path = os.path.abspath(os.path.join(out_dir, f"column-{look}.png"))
            sv.cmd({"do": "column", "path": col_path, "height": 900})
            write_standalone_sidecar(out_dir, "column", look, col_path)

        guard("column", do_column)

        def do_strip():
            sv.cmd({"do": "ui", "sidebar": False})
            capture_picture(out_dir, "p3-strip", look, settle=1.0)
            strip_path = os.path.abspath(os.path.join(out_dir, f"strip-{look}.png"))
            sv.cmd({"do": "strip", "path": strip_path, "width": 1440})
            write_standalone_sidecar(out_dir, "strip", look, strip_path)

        guard("p3-strip", do_strip)

        def do_strip_12():
            open_bg_tabs(12)
            capture_picture(out_dir, "p4-strip-12-tabs", look)

        guard("p4-strip-12-tabs", do_strip_12)
        reset_tabs_to(3)

        def do_omnibox_list():
            sv.sp("select", id=sv.sp("state")["tabs"][0]["id"])
            sv.cmd({"do": "field", "text": "gi"})
            capture_picture(out_dir, "p6-omnibox-list", look, settle=0.6)
            sv.cmd({"do": "sitesearch", "action": "esc"})
            time.sleep(0.4)

        guard("p6-omnibox-list", do_omnibox_list)

        def do_site_chip():
            sv.sp("select", id=sv.sp("state")["tabs"][0]["id"])
            sv.cmd({"do": "field", "text": "red"})
            sv.cmd({"do": "sitesearch", "action": "tab"})
            sv.cmd({"do": "field", "text": "kea"})
            capture_picture(out_dir, "p6-site-chip", look, settle=0.6)
            sv.cmd({"do": "sitesearch", "action": "esc"})
            time.sleep(0.4)

        guard("p6-site-chip", do_site_chip)

        def do_site_card():
            tabs = sv.sp("state")["tabs"]
            sv.sp("select", id=tabs[1]["id"])
            time.sleep(0.5)
            sv.cmd({"do": "ui", "edittab": f"{sv.BASE}/Tab%201"})
            time.sleep(0.4)
            for sname in ("p6-site-card", "site"):
                sp_path = os.path.abspath(os.path.join(out_dir, f"{sname}-{look}.png"))
                sv.cmd({"do": "site", "path": sp_path, "security": False})
                write_standalone_sidecar(out_dir, sname, look, sp_path)
            sv.cmd({"do": "ui", "finishedit": True})
            time.sleep(0.4)

        guard("p6-site-card", do_site_card)

        def do_find():
            tabs = sv.sp("state")["tabs"]
            sv.sp("select", id=tabs[-1]["id"])
            sv.cmd({"do": "find", "text": "Tab"})
            capture_picture(out_dir, "p8-find", look, settle=0.6)
            sv.cmd({"do": "sitesearch", "action": "esc"})
            time.sleep(0.4)

        guard("p8-find", do_find)

        def do_bookmarks_bar():
            sv.cmd({"do": "ui", "bookmarksBar": True})
            capture_picture(out_dir, "p8-bookmarks-bar", look, settle=0.8)
            sv.cmd({"do": "ui", "bookmarksBar": False})
            time.sleep(0.5)

        guard("p8-bookmarks-bar", do_bookmarks_bar)

        sv.cmd({"do": "ui", "sidebar": True})
        time.sleep(1.0)
        sv.sp("select", id=sv.sp("state")["tabs"][0]["id"])

        def do_side_panel():
            sv.cmd({"do": "ui", "bookmarksSidebar": True})
            capture_picture(out_dir, "p8-side-panel", look, settle=1.0)
            sv.cmd({"do": "ui", "bookmarksSidebar": False})
            time.sleep(0.8)

        guard("p8-side-panel", do_side_panel)

        def do_split():
            tabs = sv.sp("state")["tabs"]
            sv.sp("enabled", on=True)
            sv.sp("select", id=tabs[1]["id"])
            sv.sp("pair", id=tabs[2]["id"], **{"with": tabs[1]["id"]}, side="right")
            capture_picture(out_dir, "p7-split", look, settle=1.0)
            sv.sp("detach", id=tabs[2]["id"])
            sv.sp("enabled", on=False)
            time.sleep(0.8)

        guard("p7-split", do_split)

        def do_peek():
            tabs = sv.sp("state")["tabs"]
            sv.sp("select", id=tabs[1]["id"])
            sv.cmd({"do": "peek", "url": f"{sv.BASE}/Peek"})
            capture_picture(out_dir, "p7-peek", look, settle=1.0)
            sv.cmd({"do": "peek", "url": "close"})
            time.sleep(0.8)

        guard("p7-peek", do_peek)

        def do_switcher():
            reset_tabs_to(8)
            tabs = sv.sp("state")["tabs"]
            sv.sp("select", id=tabs[1]["id"])
            sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]})
            capture_picture(out_dir, "p7-switcher", look, settle=0.8)
            sv.sp("mouse", points=[[10, 10], [10, 10]])
            time.sleep(0.5)

        guard("p7-switcher", do_switcher)

        def do_pins_groups():
            reset_tabs_to(8)
            tabs = sv.sp("state")["tabs"]
            for t_item in tabs[1:4]:
                sv.cmd({"do": "pin", "id": t_item["id"], "listed": False})
            loose = [t_item for t_item in sv.sp("state")["tabs"] if t_item["id"] not in sv.sp("state")["pins"]]
            sv.cmd({"do": "group", "id": loose[-1]["id"], "new": True, "name": "Reading"})
            sv.cmd({"do": "group", "id": loose[-2]["id"], "name": "Reading"})
            capture_picture(out_dir, "p4-column-pins-groups", look, settle=1.0)

        guard("p4-column-pins-groups", do_pins_groups)

        reset_tabs_to(3)
        sv.sp("select", id=sv.sp("state")["tabs"][0]["id"])
        time.sleep(0.5)

        ext_folder = os.path.abspath(os.path.join(sv.SUPPORT, "Kea Fixture"))
        try:
            sv.cmd({"do": "ext-answer", "answer": "yes"})
            sv.cmd({"do": "ext-folder", "path": ext_folder})
            time.sleep(1.5)
        except Exception:
            pass

        settings_pages = [
            ("p8-settings-general", "general"),
            ("p8-settings-tabs", "tabs"),
            ("p8-settings-shortcuts", "shortcuts"),
            ("p8-settings-downloads", "downloads"),
            ("p8-settings-privacy", "privacy"),
            ("p8-settings-ai", "ai"),
            ("p8-settings-about", "about"),
            ("p10-settings-passwords", "passwords"),
            ("p13-extensions-settings", "extensions"),
        ]
        for state_name, page_id in settings_pages:
            def do_setting(sn=state_name, pid=page_id):
                sv.cmd({"do": "ui", "settings": False})
                time.sleep(0.3)
                subprocess.run(["defaults", "write", sv.SUITE, "settings.page", "-string", pid], check=True)
                time.sleep(0.2)
                sv.cmd({"do": "ui", "settings": True})
                capture_picture(out_dir, sn, look, settle=1.0)

            guard(state_name, do_setting)
        sv.cmd({"do": "ui", "settings": False})
        time.sleep(0.6)

        panel_states = [
            ("p8-welcome", {"welcome": True}, {"welcome": False}),
            ("p8-history", {"history": True}, {"history": False}),
            ("p8-downloads", {"downloads": True}, {"downloads": False}),
            ("p8-bookmarks-manager", {"bookmarks": True}, {"bookmarks": False}),
            ("p10-passwords", {"passwords": True}, {"passwords": False}),
            ("p11-import", {"import": "on"}, {"import": "off"}),
        ]
        for state_name, on_cmd, off_cmd in panel_states:
            def do_panel(sn=state_name, on_c=on_cmd, off_c=off_cmd):
                sv.cmd({"do": "ui", **on_c})
                capture_picture(out_dir, sn, look, settle=1.2)
                sv.cmd({"do": "ui", **off_c})
                time.sleep(0.6)

            guard(state_name, do_panel)

        def do_chat():
            sv.cmd({"do": "ai", "action": "use", "provider": "ollama", "model": "llama3.2"})
            chats = sv.cmd({"do": "ai", "action": "sessions"}).get("sections", [])
            if chats and chats[0].get("items"):
                cid = chats[0]["items"][0]["id"]
                sv.cmd({"do": "ai", "action": "chat", "what": "open", "chat": cid})
            else:
                sv.cmd({"do": "run", "command": "view.ask"})
            capture_picture(out_dir, "p9-chat", look, settle=1.0)
            sv.cmd({"do": "ai", "action": "close"})
            time.sleep(0.6)

        guard("p9-chat", do_chat)

        for rname, rtext in (("p9-markdown", MARKDOWN_TEXT), ("p9-mermaid", MERMAID_TEXT)):
            def do_render(rn=rname, rt=rtext):
                rpath = os.path.abspath(os.path.join(out_dir, f"{rn}-{look}.png"))
                sv.cmd({"do": "ai", "action": "render", "text": rt, "path": rpath, "width": 520})
                write_standalone_sidecar(out_dir, rn, look, rpath)

            guard(rname, do_render)

        def do_fold():
            sv.cmd({"do": "ui", "folded": True, "peek": True})
            time.sleep(1.0)
            fold_path = os.path.abspath(os.path.join(out_dir, f"fold-{look}.png"))
            sv.cmd({"do": "fold", "path": fold_path, "width": 1440})
            write_standalone_sidecar(out_dir, "fold", look, fold_path)
            sv.cmd({"do": "ui", "folded": False, "peek": False})
            time.sleep(1.0)

        guard("fold", do_fold)

        def do_icons_states():
            sv.quit()
            subprocess.run(["defaults", "write", sv.SUITE, "glyph", "-string", "icons"], check=True)
            subprocess.run(["defaults", "write", sv.SUITE, "sidebar", "-bool", "false"], check=True)
            seed_support()
            sv.launch()
            sv.cmd({"do": "window"})
            sv.cmd({"do": "resize", "width": 1440, "height": 900, "steps": 1})
            time.sleep(0.8)
            hosts = ["icon-colour.test", "icon-black.test", "icon-white.test", "icon-16.test"]
            tabs = sv.sp("state").get("tabs", [])
            if tabs:
                sv.cmd({"do": "go", "id": tabs[0]["id"], "url": f"https://{hosts[0]}/Tab%201"})
            for idx in range(1, 4):
                sv.cmd({"do": "split", "action": "open", "url": f"https://{hosts[idx % len(hosts)]}/Tab%20{idx + 1}", "foreground": False, "atEnd": True})
            capture_picture(out_dir, "p4-strip-icons", look, settle=1.0)

            sv.cmd({"do": "ui", "sidebar": True})
            for idx in range(4, 8):
                sv.cmd({"do": "split", "action": "open", "url": f"https://{hosts[(idx - 1) % len(hosts)]}/Tab%20{idx}", "foreground": False, "atEnd": True})
            tabs = sv.sp("state")["tabs"]
            for t_item in tabs[1:4]:
                sv.cmd({"do": "pin", "id": t_item["id"], "listed": False})
            loose = [t_item for t_item in sv.sp("state")["tabs"] if t_item["id"] not in sv.sp("state")["pins"]]
            sv.cmd({"do": "group", "id": loose[-1]["id"], "new": True, "name": "Reading"})
            sv.cmd({"do": "group", "id": loose[-2]["id"], "name": "Reading"})
            capture_picture(out_dir, "p4-column-pins-icons", look, settle=1.0)
            subprocess.run(["defaults", "write", sv.SUITE, "glyph", "-string", "letters"], check=True)

        guard("p4-icons", do_icons_states)

        if not reduce_motion:
            sv.cmd({"do": "ui", "folded": True, "peek": False})
            time.sleep(1.0)
            for action in ("peek", "unpeek", "fold"):
                def do_film(act=action):
                    if act == "fold":
                        sv.cmd({"do": "ui", "folded": False, "peek": False})
                        time.sleep(1.0)
                    prefix = os.path.abspath(os.path.join(out_dir, f"film-{act}-{look}"))
                    res = sv.cmd({"do": "film", "action": act, "path": prefix, "frames": 30, "every": 0.02})
                    frames = res.get("frames", [])
                    film_meta = {"action": act, "look": look, "t": [int(fr.get("t", 0)) for fr in frames], "frames": frames}
                    with open(os.path.join(out_dir, f"film-{act}-{look}.json"), "w") as f:
                        json.dump(film_meta, f, indent=2)
                    print(f"filmed {act}-{look} ({len(frames)} frames)")
                    time.sleep(0.8)

                guard(f"film-{action}", do_film)
    finally:
        sv.finish()
        try:
            if os.path.exists(plist):
                os.remove(plist)
        except OSError:
            pass


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/kea-ref"
    os.makedirs(out_dir, exist_ok=True)
    reduce_motion = read_reduce_motion()
    errors = []
    if reduce_motion:
        print("Reduce Motion is ON (1): skipping film captures.")

    for look in ("light", "dark"):
        capture_look(out_dir, look, reduce_motion, errors)

    meta = {"reduceMotion": reduce_motion, "world": sv.W, "skippedFilms": bool(reduce_motion), "errors": errors}
    with open(os.path.join(out_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)


if __name__ == "__main__":
    main()
