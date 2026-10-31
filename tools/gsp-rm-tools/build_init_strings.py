#!/usr/bin/env python3
"""Recover exact message text for the kernel/INIT log IDs.

Most GSP-RM log sites emit only a metadata ID: the format string lives in the
missing `gsp_log_ga10x.bin`.  The early `FUN_ram_01179c62` writer is the exception.
It carries a per-statement fallback for a log-disabled build:

    if (log_disabled) FUN_ram_01179be4(format, filename, line, args...);
    else             FUN_ram_01179c62(n, args..., metadata_id);

Both branches are in the plaintext image, so the metadata ID -> (format, file,
line) mapping is recoverable by pairing each ring call with its adjacent fallback.
The strings are read out of `.fwimage`.  A proximity and argument-count check
rejects mispairs; 31 of the 42 early sites pass.

The INIT writer (`FUN_ram_011849a6`) has a `FUN_ram_01185308(format, args...)`
fallback shape, but it is not emitted per statement: long sequences of INIT ring
calls have no adjacent literal branch.  Strict pairing yields no trustworthy INIT
rows, so INIT text remains unavailable.

Output: `init_strings.csv`, keyed by metadata ID.  The decoder uses it
automatically when the file is present.

Usage:
    python3 -I build_init_strings.py
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_DECOMPILED = Path(os.environ.get("DECOMPILED", HERE / "gsp_decompiled.c"))
DEFAULT_IMAGE = Path(os.environ.get("FWIMAGE", HERE / "gsp_fwimage.bin"))
DEFAULT_OUT = Path(os.environ.get("OUT", HERE / "init_strings.csv"))

BASE = 0x01000000
HEADER_RE = re.compile(
    r"/\* ==== ram:([0-9a-fA-F]+)\s+(\S+)\s+size=(0x[0-9a-fA-F]+|\d+) ==== \*/"
)
SYMBOL_ADDR_RE = re.compile(r"_ram_([0-9a-fA-F]{8})")
LITERAL_RE = re.compile(
    r"(?:\(\s*(?:ulong|long|uint|int|unsigned\s+long)\s*\)\s*)?"
    r"(0x[0-9a-fA-F]+|\d+)[uUlL]*\s*$"
)
IDENT_RE = re.compile(r"[A-Za-z_]\w*")

WRITERS = {
    "FUN_ram_01179c62": {
        "name": "EARLY",
        "fallback": "FUN_ram_01179be4",
        "shape": "fmt_file_line",
        "id_lo": 0x20170000,
        "id_hi": 0x20180000,
    },
    "FUN_ram_011849a6": {
        "name": "INIT",
        "fallback": "FUN_ram_01185308",
        "shape": "fmt_only",
        "id_lo": 0x20180000,
        "id_hi": 0x20190000,
    },
}


def split_args(text: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    quote: str | None = None
    cur: list[str] = []
    for i, ch in enumerate(text):
        if quote is not None:
            cur.append(ch)
            if ch == quote and (i == 0 or text[i - 1] != "\\"):
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            cur.append(ch)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        parts.append("".join(cur).strip())
    return parts


def calls(text: str, name: str):
    for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", text):
        i = m.end()
        depth = 1
        quote: str | None = None
        while i < len(text) and depth:
            ch = text[i]
            if quote is not None:
                if ch == quote and text[i - 1] != "\\":
                    quote = None
            elif ch in "\"'":
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
        yield m.start(), split_args(text[m.end() : i - 1])


def symbol_addr(arg: str) -> int | None:
    m = SYMBOL_ADDR_RE.search(arg)
    return int(m.group(1), 16) if m else None


def read_cstring(data: bytes, addr: int) -> str | None:
    off = addr - BASE
    if off < 0 or off >= len(data):
        return None
    end = data.find(b"\0", off)
    if end < 0 or end - off > 512:
        return None
    try:
        return data[off:end].decode("utf-8")
    except UnicodeDecodeError:
        return data[off:end].decode("utf-8", errors="replace")


def resolve_string_arg(
    arg: str, func_text: str, fallback_pos: int
) -> tuple[int | None, str]:
    """Resolve the first fallback operand to a string address.

    Returns (address, mechanism).  Handles a direct Ghidra symbol and a local
    variable assigned a symbol shortly before the fallback call.
    """
    arg = arg.strip()
    direct = symbol_addr(arg)
    if direct is not None:
        return direct, "direct"

    name = arg
    if not IDENT_RE.fullmatch(name):
        return None, "unresolved"

    # Nearest preceding assignment to this variable in the same function.
    pat = re.compile(
        r"\b" + re.escape(name) + r"\s*=\s*(?:&\s*)?(?:s_|DAT_|_DAT_)[^\s;]*?_ram_([0-9a-fA-F]{8})"
    )
    best = None
    for m in pat.finditer(func_text, 0, fallback_pos):
        best = m
    if best is None:
        return None, "unresolved"
    return int(best.group(1), 16), "variable"


def extract(decompiled: Path, image: Path) -> list[dict]:
    text = decompiled.read_text(encoding="utf-8", errors="replace")
    data = image.read_bytes()
    headers = list(HEADER_RE.finditer(text))

    rows: list[dict] = []
    for i, h in enumerate(headers):
        func_start = h.start()
        func_end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        func_text = text[func_start:func_end]
        func_name = h.group(2)
        func_addr = int(h.group(1), 16)

        for writer, spec in WRITERS.items():
            fallbacks = list(calls(func_text, spec["fallback"]))
            logs = list(calls(func_text, writer))
            if not fallbacks or not logs:
                continue

            for log_pos, log_args in logs:
                if len(log_args) < 2:
                    continue
                try:
                    n_operands = int(log_args[0], 0)
                except ValueError:
                    continue
                m = LITERAL_RE.fullmatch(log_args[-1])
                if not m:
                    continue
                meta_id = int(m.group(1), 0)
                if not (spec["id_lo"] <= meta_id < spec["id_hi"]):
                    continue

                previous = [c for c in fallbacks if c[0] < log_pos]
                if not previous:
                    continue
                fb_pos, fb_args = previous[-1]
                if not fb_args:
                    continue
                # A fallback is only trustworthy when it is the paired branch of
                # this statement, not merely the nearest one earlier in a long
                # function.  Require proximity and a matching data-argument count.
                max_distance = 400 if spec["shape"] == "fmt_file_line" else 200
                if log_pos - fb_pos > max_distance:
                    continue

                if spec["shape"] == "fmt_file_line":
                    if len(fb_args) < 3:
                        continue
                    fmt_addr = symbol_addr(fb_args[0])
                    file_addr = symbol_addr(fb_args[1])
                    if fmt_addr is None or file_addr is None:
                        continue
                    fmt = read_cstring(data, fmt_addr)
                    filename = read_cstring(data, file_addr)
                    if fmt is None or filename is None:
                        continue
                    try:
                        line = int(fb_args[2], 0)
                    except ValueError:
                        line = None
                    via = "direct"
                    extra_args = len(fb_args) - 3
                else:
                    fmt_addr, via = resolve_string_arg(fb_args[0], func_text, fb_pos)
                    if fmt_addr is None:
                        continue
                    fmt = read_cstring(data, fmt_addr)
                    if fmt is None:
                        continue
                    filename = ""
                    line = None
                    extra_args = len(fb_args) - 1

                # The ring record stores n_operands - 1 data arguments; a paired
                # fallback must pass the same number.
                if extra_args != n_operands - 1:
                    continue

                rows.append(
                    {
                        "writer": writer,
                        "task": spec["name"],
                        "meta_id": meta_id,
                        "meta_id_hex": f"0x{meta_id:x}",
                        "format": fmt,
                        "filename": filename,
                        "line": line if line is not None else "",
                        "func_name": func_name,
                        "func_addr_hex": f"0x{func_addr:x}",
                        "n_operands": n_operands,
                        "fallback_args": extra_args,
                        "resolved_via": via,
                    }
                )

    rows.sort(key=lambda r: (r["meta_id"], r["func_addr_hex"]))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--decompiled", type=Path, default=DEFAULT_DECOMPILED)
    ap.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    for p in (args.decompiled, args.image):
        if not p.is_file():
            print(f"error: missing {p}", file=sys.stderr)
            return 1

    rows = extract(args.decompiled, args.image)
    fieldnames = [
        "writer",
        "task",
        "meta_id",
        "meta_id_hex",
        "format",
        "filename",
        "line",
        "func_name",
        "func_addr_hex",
        "n_operands",
        "fallback_args",
        "resolved_via",
    ]
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    ids = {r["meta_id"] for r in rows}
    by_task = {}
    for r in rows:
        by_task.setdefault(r["task"], set()).add(r["meta_id"])
    print(f"wrote {args.out}: {len(rows)} pairs, {len(ids)} distinct IDs")
    for task, tids in sorted(by_task.items()):
        print(f"  {task}: {len(tids)} distinct IDs")
    for r in rows[:3]:
        loc = f"{r['filename']}:{r['line']}" if r["filename"] else "-"
        print(f"  {r['meta_id_hex']} {r['task']} {loc} {r['format']!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
