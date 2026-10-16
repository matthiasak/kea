#!/usr/bin/env python3
"""Side panels (Ubi Chat and Bookmarks): resize, side, expand, pop out."""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("panels")


def page_frame():
    return sv.cmd({"do": "probe"})["activePageFrame"]


def panels(**fields):
    return sv.cmd({"do": "panels", **fields})


def close_to(a, b, tol=1.5):
    return abs(a - b) <= tol


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        sv.page("a")
        time.sleep(0.6)
        base = page_frame()
        bx, by, bw, bh = base

        # 1. Open Ubi Chat via view.ask
        sv.cmd({"do": "run", "command": "view.ask"})
        time.sleep(0.6)
        f1 = page_frame()
        t.ok("opening Ubi Chat takes 380 pt from width, x unchanged",
             close_to(f1[2], bw - 380) and close_to(f1[0], bx), (base, f1))

        # 2. Resize chat to 500, clamp 5000 -> 720, back to 500
        panels(chat={"width": 500})
        f2 = page_frame()
        t.ok("chat width 500 takes 500 pt from page", close_to(f2[2], bw - 500), f2)
        st_clamp = panels(chat={"width": 5000})
        t.ok("chat width clamps at 720", st_clamp["chat"]["width"] == 720, st_clamp["chat"])
        panels(chat={"width": 500})

        # 3. Move chat to left side
        panels(chat={"side": "left"})
        f3 = page_frame()
        t.ok("chat on left shifts page x by 500 and keeps right edge",
             close_to(f3[0], bx + 500) and close_to(f3[0] + f3[2], bx + bw), f3)

        # 4. Expand chat over page, then collapse
        st_exp = panels(chat={"expanded": True})
        f4 = page_frame()
        t.ok("expanded chat reports expanded and leaves full page frame beneath",
             st_exp["chat"]["expanded"] is True and close_to(f4[0], bx) and close_to(f4[2], bw),
             (st_exp["chat"], f4))
        panels(chat={"expanded": False})
        f4b = page_frame()
        t.ok("collapsing expanded chat restores 500 pt sidebar width",
             close_to(f4b[2], bw - 500), f4b)

        # 5. Pop out chat into its own window, then dock back
        st_pop = panels(chat={"popped": True})
        pr = sv.cmd({"do": "probe"})
        f5 = pr["activePageFrame"]
        kinds = [w.get("kind") for w in pr.get("windows", [])]
        t.ok("popped chat has window frame, SidePanelWindow in probe, and full page frame",
             st_pop["chat"]["window"] is not None and "SidePanelWindow" in kinds
             and close_to(f5[0], bx) and close_to(f5[2], bw),
             (st_pop["chat"], kinds, f5))
        st_unpop = panels(chat={"popped": False})
        f5b = page_frame()
        t.ok("docking chat back closes window and takes 500 pt from page",
             st_unpop["chat"]["window"] is None and close_to(f5b[2], bw - 500),
             (st_unpop["chat"], f5b))

        # 6. Close chat, open Bookmarks sidebar, resize to 300, move to left
        sv.cmd({"do": "ai", "action": "close"})
        sv.cmd({"do": "ui", "bookmarksSidebar": True})
        time.sleep(0.6)
        f6 = page_frame()
        t.ok("bookmarks sidebar takes 232 pt by default", close_to(f6[2], bw - 232), f6)
        panels(bookmarks={"width": 300})
        f6b = page_frame()
        t.ok("bookmarks width 300 takes 300 pt from page", close_to(f6b[2], bw - 300), f6b)
        panels(bookmarks={"side": "left"})
        f6c = page_frame()
        t.ok("bookmarks on left shifts page x by 300", close_to(f6c[0], bx + 300), f6c)

        # 7. Relaunch without setup preserves widths and sides
        sv.quit()
        sv.launch()
        st_re = panels()
        ai_w = subprocess.run(["defaults", "read", sv.SUITE, "ai.width"], capture_output=True, text=True).stdout.strip()
        t.ok("relaunch keeps bookmarks width 300, side left, and ai.width 500",
             st_re["bookmarks"]["width"] == 300 and st_re["bookmarks"]["side"] == "left"
             and float(ai_w or 0) == 500.0,
             (st_re, ai_w))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
