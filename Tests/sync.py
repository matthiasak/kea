#!/usr/bin/env python3
"""Sync across two Macs (FolderDrop and BucketDrop) and Send to Device."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

bucket_objects = {}
bucket_auths = []


class FakeS3(BaseHTTPRequestHandler):
    def _record_auth(self):
        bucket_auths.append(self.headers.get("Authorization", ""))

    def do_GET(self):
        self._record_auth()
        parsed = urllib.parse.urlsplit(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path.lstrip("/")
        if qs.get("list-type") == ["2"]:
            prefix = qs.get("prefix", [""])[0]
            bucket_prefix = f"{path}/"
            items = []
            for full_key, (data, mtime) in sorted(bucket_objects.items()):
                if full_key.startswith(bucket_prefix):
                    rel = full_key[len(bucket_prefix):]
                    if rel.startswith(prefix):
                        items.append((rel, mtime))
            xml_parts = [
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<ListBucketResult xmlns="http://doc.s3.amazonaws.com/2006-03-01">',
                f"<Name>{escape(path)}</Name>",
            ]
            for key, mtime in items:
                xml_parts.append(
                    f"<Contents><Key>{escape(key)}</Key><LastModified>{mtime}</LastModified></Contents>"
                )
            xml_parts.append("</ListBucketResult>")
            body = "".join(xml_parts).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path in bucket_objects:
            data, _ = bucket_objects[path]
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def do_PUT(self):
        self._record_auth()
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.lstrip("/")
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length) if length > 0 else b""
        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        bucket_objects[path] = (data, now_iso)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self._record_auth()
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.lstrip("/")
        bucket_objects.pop(path, None)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


def main():
    t = sv.T()
    store_dir = tempfile.mkdtemp(prefix="kea-sync-store-")
    s3_server = ThreadingHTTPServer(("127.0.0.1", 0), FakeS3)
    threading.Thread(target=s3_server.serve_forever, daemon=True).start()
    passphrase = "correct horse"

    try:
        # World A: setup, seed, launch
        sv.use("sync-a")
        sv.setup()
        support_a = sv.SUPPORT
        suite_a = sv.SUITE
        os.makedirs(support_a, exist_ok=True)
        json.dump(
            [{"id": str(uuid.uuid4()).upper(), "title": "Kea", "url": "https://en.wikipedia.org/wiki/Kea"}],
            open(f"{support_a}/bookmarks.json", "w"),
        )
        json.dump(
            [{"url": "https://example.com/kea", "key": "https://example.com/kea", "title": "Kea example", "count": 3, "last": 800000000}],
            open(f"{support_a}/history.json", "w"),
        )
        json.dump(
            [{"id": str(uuid.uuid4()).upper(), "title": "Trip", "touched": 800000000, "starred": False, "task": False, "pageHidden": False, "pins": [], "turns": []}],
            open(f"{support_a}/chats.json", "w"),
        )
        subprocess.run(["defaults", "write", suite_a, "look", "-string", "dark"], check=True)
        sv.launch()
        pin_tab = sv.page("pinme")
        sv.cmd({"do": "pin", "id": pin_tab})

        # World B: wipe, defaults, launch (without setup() so A stays alive)
        sv.use("sync-b")
        sv.wipe()
        support_b = sv.SUPPORT
        suite_b = sv.SUITE
        for k in ["bench", "welcomed"]:
            subprocess.run(["defaults", "write", suite_b, k, "-bool", "true"], check=True)
        sv.launch()

        # Case 1: A sets up folder sync and syncs now
        sv.use("sync-a")
        r1 = sv.cmd({"do": "sync", "action": "setup", "folder": store_dir, "passphrase": passphrase, "name": "Mac A"})
        st_a = sv.cmd({"do": "sync", "action": "now"})
        t.ok("Mac A sets up folder sync and status starts with Synced",
             r1.get("ok") is True and st_a.get("status", "").startswith("Synced"),
             (r1, st_a))

        # Case 2: B opens /from-b, tries wrong passphrase, then right passphrase
        sv.use("sync-b")
        from_b_tab = sv.page("from-b")
        try:
            sv.cmd({"do": "sync", "action": "setup", "folder": store_dir, "passphrase": "wrong", "name": "Mac B"})
            wrong_err = ""
        except RuntimeError as e:
            wrong_err = str(e)
        t.ok("wrong passphrase refused with doesn't open", "doesn't open" in wrong_err, wrong_err)

        r2 = sv.cmd({"do": "sync", "action": "setup", "folder": store_dir, "passphrase": passphrase, "name": "Mac B"})
        st_b = sv.cmd({"do": "sync", "action": "now"})
        time.sleep(2.5)

        b_marks = json.load(open(f"{support_b}/bookmarks.json"))
        b_hist = json.load(open(f"{support_b}/history.json"))
        b_chats = json.load(open(f"{support_b}/chats/index.json"))
        b_pins = json.load(open(f"{support_b}/pins.json"))
        b_look = subprocess.run(["defaults", "read", suite_b, "look"], capture_output=True, text=True).stdout.strip()
        devs_b = st_b.get("devices", [])

        t.ok("B receives bookmarks from A",
             any(m.get("url") == "https://en.wikipedia.org/wiki/Kea" for m in b_marks), b_marks)
        t.ok("B receives history from A",
             any(h.get("url") == "https://example.com/kea" for h in b_hist), b_hist)
        t.ok("B receives chats from A",
             any(c.get("title") == "Trip" for c in b_chats), b_chats)
        t.ok("A moves its old chats.json to a file per chat",
             not os.path.exists(f"{support_a}/chats.json")
             and any(c["title"] == "Trip" for c in json.load(open(f"{support_a}/chats/index.json"))))
        t.ok("B receives pins from A",
             any(p.get("home", "").endswith("/pinme") for defs in b_pins.values() for p in defs), b_pins)
        t.ok("B receives portable look setting from A", b_look == "dark", b_look)
        t.ok("B sees Mac A and its open /pinme tab",
             any(d.get("name") == "Mac A" and any(tab.get("url", "").endswith("/pinme") for tab in d.get("tabs", []))
                 for d in devs_b), devs_b)

        # Case 3: A syncs now; its bookmarks still have the Kea URL
        sv.use("sync-a")
        sv.cmd({"do": "sync", "action": "now"})
        a_marks = json.load(open(f"{support_a}/bookmarks.json"))
        t.ok("A keeps its bookmark after B joins",
             any(m.get("url") == "https://en.wikipedia.org/wiki/Kea" for m in a_marks), a_marks)

        # Case 4: Send to Device from B to Mac A
        sv.use("sync-b")
        sv.cmd({"do": "sync", "action": "send", "id": from_b_tab, "to": "Mac A"})
        sv.use("sync-a")
        st_a2 = sv.cmd({"do": "sync", "action": "now"})
        a_tabs = sv.cmd({"do": "tabs"})["tabs"]
        inbox_dir = os.path.join(store_dir, "kea", "v1", "inbox", st_a2["device"])
        inbox_files = os.listdir(inbox_dir) if os.path.isdir(inbox_dir) else []
        t.ok("sent tab from B opens on A and empties A's inbox",
             any(tab.get("url", "").endswith("/from-b") for tab in a_tabs) and len(inbox_files) == 0,
             (a_tabs, inbox_files))

        # Case 5: Clear History on A clears on B
        sv.use("sync-a")
        sv.cmd({"do": "run", "command": "history.clear"})
        sv.cmd({"do": "sync", "action": "now"})
        sv.use("sync-b")
        sv.cmd({"do": "sync", "action": "now"})
        time.sleep(2.5)
        b_hist_after = json.load(open(f"{support_b}/history.json"))
        t.ok("Clear History on A clears example.com/kea on B",
             not any("example.com/kea" in h.get("url", "") for h in b_hist_after), b_hist_after)

        # Case 6: Bucket backend via FakeS3
        endpoint = f"http://127.0.0.1:{s3_server.server_port}"
        sv.use("sync-a")
        sv.cmd({
            "do": "sync", "action": "setup",
            "endpoint": endpoint, "bucket": "kea-test",
            "access": "TESTKEY", "secret": "TESTSECRET",
            "passphrase": passphrase, "name": "Mac A",
        })
        bpin = sv.page("bucket-pin")
        sv.cmd({"do": "pin", "id": bpin})
        sv.cmd({"do": "sync", "action": "now"})

        sv.use("sync-b")
        sv.cmd({
            "do": "sync", "action": "setup",
            "endpoint": endpoint, "bucket": "kea-test",
            "access": "TESTKEY", "secret": "TESTSECRET",
            "passphrase": passphrase, "name": "Mac B",
        })
        sv.cmd({"do": "sync", "action": "now"})
        b_pins_bucket = json.load(open(f"{support_b}/pins.json"))
        t.ok("BucketDrop syncs /bucket-pin from A to B with SigV4 headers",
             any(p.get("home", "").endswith("/bucket-pin") for defs in b_pins_bucket.values() for p in defs)
             and bool(bucket_auths)
             and all(a.startswith("AWS4-HMAC-SHA256 Credential=TESTKEY/") for a in bucket_auths),
             (b_pins_bucket, bucket_auths[:2]))
    finally:
        t.done()
        for w in ["sync-a", "sync-b"]:
            sv.use(w)
            sv.quit()
            time.sleep(0.3)
            sv.wipe()
            subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)
        shutil.rmtree(store_dir, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
