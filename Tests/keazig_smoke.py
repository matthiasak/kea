#!/usr/bin/env python3
"""End-to-end smoke & integration suite for build/KeaZig.app over bench.sock."""
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "KeaZig.app")
PROBE = "keazig-smoke"
SUPPORT = Path(os.path.expanduser("~")) / "Library" / "Application Support" / f"Kea ({PROBE})"
SOCK = SUPPORT / "bench.sock"
SUITE = f"app.kea.browser.test.{PROBE}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<html><head><title>Slow Page</title></head><body>")
            self.wfile.flush()
            time.sleep(8)
            return
        title = "Zig Concurrency Guide" if "zig" in self.path else f"Page {self.path}"
        body = f"<html><head><title>{title}</title></head><body><h1>{title}</h1></body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        s.connect(str(SOCK))
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode())


def main():
    if not os.path.exists(APP):
        subprocess.run([str(ROOT / "build-zig.sh"), "release", "test"], cwd=str(ROOT), check=True)
    shutil.rmtree(SUPPORT, ignore_errors=True)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    (SUPPORT / "session.json").write_text("{broken json")
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "sidebar", "-bool", "true"], check=True)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    base = f"http://127.0.0.1:{port}"
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    env = os.environ.copy()
    env["KEA_PROBE"] = PROBE
    proc = subprocess.Popen([f"{APP}/Contents/MacOS/KeaZig"], env=env)
    passed = 0
    failed = 0

    def ok(name, cond, extra=None):
        nonlocal passed, failed
        if cond:
            passed += 1
            print("ok  ", name)
        else:
            failed += 1
            print("FAIL", name, extra)

    try:
        for _ in range(100):
            if SOCK.exists():
                break
            time.sleep(0.05)
        ok("KeaZig.app started and bound bench.sock", SOCK.exists())
        ok("corrupt session.json quarantined to session.json.corrupt", (SUPPORT / "session.json.corrupt").exists())

        pr0 = cmd({"do": "probe"})
        ok("probe reports zig-nanoui engine and non-zero stage hole", pr0.get("engine") == "zig-nanoui" and pr0["activePageFrame"][2] > 400, pr0)

        r1 = cmd({"do": "open", "url": f"{base}/zig-guide"})
        r2 = cmd({"do": "open", "url": f"{base}/second"})
        time.sleep(0.6)
        w1 = cmd({"do": "wait", "id": r1["id"]})
        ok("WKWebView loaded tab 1 and extracted title", "Zig Concurrency Guide" in w1.get("title", ""), w1)

        sp_pair = cmd({"do": "split", "action": "pair", "right": r1["id"]})
        w_single = pr0["activePageFrame"][2]
        w_split = sp_pair["activePageFrame"][2]
        ok("Split View halves active WKWebView stage hole width", w_split < w_single * 0.6, (w_single, w_split))
        cmd({"do": "split", "action": "close"})
        _ = r2

        p_before = cmd({"do": "probe"})["activePageFrame"][2]
        st_pan = cmd({"do": "panels", "chat": {"open": True, "width": 440}})
        p_after = cmd({"do": "probe"})["activePageFrame"][2]
        ok("opening 440 pt Ubi Chat shrinks WKWebView stage hole accordingly", st_pan["chat"]["open"] and abs((p_before - p_after) - 449) <= 20, (p_before, p_after, st_pan))

        f_off = cmd({"do": "field", "text": "127.0"})
        ok("Omnibox offers visited host completion", "127.0.0.1" in f_off.get("offer", ""), f_off)
        f_chip = cmd({"do": "field", "text": "github "})
        ok("typing 'github ' activates GitHub SiteSearch chip", f_chip.get("chip") == "GitHub", f_chip)

        r_slow = cmd({"do": "open", "url": f"{base}/slow"})
        time.sleep(0.15)
        cmd({"do": "press", "key": ".", "command": True})
        w_slow = cmd({"do": "wait", "id": r_slow["id"]})
        ok("Cmd+. stops loading on slow tab", w_slow.get("loading") is False, w_slow)

        cmd({"do": "open", "url": f"{base}/flushed-on-quit"})
        cmd({"do": "quit"})
        proc.wait(timeout=5)
        hist_text = (SUPPORT / "history.json").read_text() if (SUPPORT / "history.json").exists() else ""
        ok("quit flushes history.json synchronously", "/flushed-on-quit" in hist_text, hist_text[:200])
    finally:
        if proc.poll() is None:
            proc.kill()
        srv.shutdown()
        shutil.rmtree(SUPPORT, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)

    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
