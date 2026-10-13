"""Checks that need no docker, no GPU and no network — so they can run on every
commit rather than only on the hardware.

Three invariants, each of which was violated at least once while this
repository was being assembled:

  1. **Hunk headers match their bodies.** Hand-editing a patch (to rename a
     symbol, to reword a comment) is easy and silently corrupting. `git apply`
     would catch it at build time on the DGX, twenty minutes later.

  2. **verify.py's markers exist in the patches.** `verify.py --static` checks
     the built tree for every marker by name, so that a patch which applies
     cleanly but has stopped covering a call site is caught. That check is
     worthless if a marker is misspelled — it would report a missing marker
     for a patch that is fine, or worse, be quietly dropped.

  3. **No product names leak.** These patches end up inside a GPL'd file and
     therefore inside every published source bundle. A product name in there
     would ship one product's identity to the other's customers.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Names of the products that consume this repository. They must not appear in
# anything that gets built into the image.
PRODUCT_NAMES = ("ecobillz", "vonzl")


def hunk_headers_match_bodies(text: str, name: str) -> bool:
    """Every `@@ -a,b +c,d @@` must agree with the lines that follow it."""
    lines = text.split("\n")
    # The last element is the artefact of the file's trailing newline, not a
    # context line. Counting it is an off-by-one that makes good hunks look
    # corrupt.
    if lines and lines[-1] == "":
        lines.pop()

    ok, i = True, 0
    while i < len(lines):
        header = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", lines[i])
        if not header:
            i += 1
            continue
        want = (int(header.group(2) or 1), int(header.group(4) or 1))
        old = new = 0
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line.startswith("@@") or line.startswith("diff --git"):
                break
            if line.startswith("-"):
                old += 1
            elif line.startswith("+"):
                new += 1
            elif line.startswith(" ") or line == "":
                old += 1
                new += 1
            elif line.startswith("\\"):  # "\ No newline at end of file"
                pass
            else:
                break
            j += 1
        if (old, new) != want:
            print(f"FAIL {name}: hunk at line {i + 1} declares "
                  f"-{want[0]},+{want[1]} but its body has -{old},+{new}")
            ok = False
        i = j
    return ok


def main() -> int:
    patch_files = sorted((ROOT / "patches").glob("*.patch"))
    if not patch_files:
        print("FAIL no patches found")
        return 1

    ok = True
    combined = ""
    for p in patch_files:
        text = p.read_text()
        combined += text
        if hunk_headers_match_bodies(text, p.name):
            print(f"ok   {p.name}: hunk headers consistent")
        else:
            ok = False

    # 2. Markers.
    verify_src = (ROOT / "scripts" / "verify.py").read_text()
    block = re.search(r"MARKERS = \((.*?)\n\)", verify_src, re.S)
    if not block:
        print("FAIL could not find MARKERS in verify.py")
        return 1
    markers = re.findall(r'"((?:[^"\\]|\\.)*)"', block.group(1))
    missing = [m for m in markers if m not in combined]
    if missing:
        for m in missing:
            print(f"FAIL verify.py marker not present in any patch: {m}")
        ok = False
    else:
        print(f"ok   all {len(markers)} verify.py markers present in the patches")

    # 3. Product names.
    #
    # Scanned explicitly rather than by glob, and the list is exactly what a
    # recipient can end up reading: everything the Dockerfile COPYs into the
    # image, plus release-source.sh because it writes the bundle's own README.
    #
    # This file is not in that list — it names both products by definition, and
    # globbing scripts/ made the checker fail on itself.
    scanned = ["Dockerfile", "scripts/verify.py", "scripts/entrypoint.sh",
               "scripts/release-source.sh"]
    scanned += [str(q.relative_to(ROOT)) for q in sorted((ROOT / "patches").glob("*.patch"))]
    for rel in scanned:
        text = (ROOT / rel).read_text()
        for name in PRODUCT_NAMES:
            hits = [
                f"{rel}:{n}" for n, line in enumerate(text.split("\n"), 1)
                if name in line.lower()
            ]
            if hits:
                print(f"FAIL product name {name!r} appears in: {', '.join(hits)}")
                ok = False
    if ok:
        print(f"ok   no product names in any of the {len(scanned)} files a recipient reads")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
