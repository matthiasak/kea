#!/usr/bin/env python3
"""The bookmark manager's batch operations: move, group, sort, dedupe, remove, undo.

Build first (`./build.sh release test`), then `python3 Tests/bookmarks_manager.py`. Drives
the model through the bench's `bookmarks` verb: several bookmarks moved at
once land in the order the list reads them, a folder can't be moved into
itself, and every change can be undone and redone. Nothing is drawn.
"""
import json
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-manager")


def op(**f):
    return sv.cmd({"do": "bookmarks", **f})["tree"]


def titles(nodes):
    return [n["title"] for n in nodes]


def main():
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

        # s4 is s1's address again.
        seed = [node("s1", "https://www.aaa.com/1"), node("s2", "https://zeta.com/2"),
                node("s3", "https://mid.com/3"), node("s4", "https://www.aaa.com/1"),
                node("A", kids=[node("a1", "https://a.example/1"), node("a2", "https://a.example/2")]),
                node("B", kids=[node("b1", "https://b.example/1")])]
        json.dump(seed, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        ids_of = lambda *names: [ids[n] for n in names]
        start = op(action="tree")
        t.ok("the seed is read", titles(start) == ["s1", "s2", "s3", "s4", "A", "B"], titles(start))

        tree = op(action="move", ids=ids_of("s3", "s1"), into=ids["A"], at=1)
        a = next(n for n in tree if n["title"] == "A")
        t.ok("move [s3, s1] into A at 1 follows the document, not the request",
             titles(a["children"]) == ["a1", "s1", "s3", "a2"], titles(a["children"]))
        t.ok("and takes them out of where they were", titles(tree) == ["s2", "s4", "A", "B"], titles(tree))
        tree = op(action="undo")
        t.ok("undo puts them back", tree == start, titles(tree))

        tree = op(action="move", ids=ids_of("A", "a1"), into=ids["A"])
        t.ok("a folder moved into itself is refused", tree == start, titles(tree))

        tree = op(action="move", ids=ids_of("s1", "s2"), into=None, at=4)
        t.ok("move [s1, s2] to the top level at 4 counts the list as it read",
             titles(tree) == ["s3", "s4", "s1", "s2", "A", "B"], titles(tree))
        op(action="undo")

        made = sv.cmd({"do": "bookmarks", "action": "group", "ids": ids_of("s4", "s2"), "name": "G"})
        tree = made["tree"]
        group = next((n for n in tree if n["title"] == "G"), {})
        t.ok("group [s2, s4] sits at s2's place holding both, in order",
             titles(tree)[:3] == ["s1", "G", "s3"] and titles(group.get("children", [])) == ["s2", "s4"], titles(tree))
        t.ok("and answers with the folder's id", made["made"] == group.get("id"), made)
        op(action="undo")

        # Out of order first, so a sort that leaves bookmarks where they are fails.
        op(action="move", ids=ids_of("s1"), into=None, at=4)
        tree = op(action="sort", folder=None, by="name")
        t.ok("sort by name: folders first, then the bookmarks by title",
             titles(tree) == ["A", "B", "s1", "s2", "s3", "s4"], titles(tree))
        op(action="undo")
        tree = op(action="undo")
        t.ok("both undone", tree == start, titles(tree))

        # By site: the host without its www., then the title. By name would
        # read s1, s2, s3; by the whole host s3, s2, s1.
        op(action="move", ids=ids_of("s1", "s2", "s3"), into=ids["A"], at=0)
        tree = op(action="sort", folder=ids["A"], by="site")
        a = next(n for n in tree if n["title"] == "A")
        order = [x for x in titles(a["children"]) if x in ("s1", "s2", "s3")]
        t.ok("sort by site orders by host without www.", order == ["s1", "s3", "s2"], titles(a["children"]))
        t.ok("and only that one level", titles(tree) == ["s4", "A", "B"], titles(tree))
        op(action="undo")
        tree = op(action="undo")
        t.ok("both undone", tree == start, titles(tree))

        done = sv.cmd({"do": "bookmarks", "action": "dedupe"})
        t.ok("dedupe removes one, and the first of the two addresses stays",
             done["count"] == 1 and titles(done["tree"]) == ["s1", "s2", "s3", "A", "B"], done)

        tree = op(action="remove", ids=ids_of("B"))
        t.ok("remove [B] takes it away", titles(tree) == ["s1", "s2", "s3", "A"], titles(tree))
        tree = op(action="undo")
        t.ok("undo brings it back in its place", titles(tree) == ["s1", "s2", "s3", "A", "B"], titles(tree))
        tree = op(action="redo")
        t.ok("redo takes it away again", titles(tree) == ["s1", "s2", "s3", "A"], titles(tree))
    finally:
        t.done(); sv.finish()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
