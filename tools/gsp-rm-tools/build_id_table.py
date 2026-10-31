#!/usr/bin/env python3
"""Build the GSP-RM log metadata-ID -> call-site table.

The GSP-RM writes log records whose first word is a packed metadata word:

    bits 47:0   metadata VA - per-task logging-section base
    bits 55:48  N, total u64 entries in the record (2..22)
    bits 63:56  libos task id

The metadata VA points into the stripped `.fwlogging_*` section of the missing
`gsp_log_ga10x.bin`, which is the only place the format string and print level
live.  The VA itself, however, is a compile-time constant materialized at every
log call site in the plaintext `.fwimage`.  This script recovers those constants
from the decompiled image and emits them as a CSV.

Three writers are present in the main image:

    FUN_ram_01b9e86e  RM task              base 0x2018F000
    FUN_ram_011849a6  INIT task            base 0x20183000
    FUN_ram_01179c62  early/other task     base 0x20178000

The captured task-1 KERNEL buffer uses none of these bases; its metadata section
is not referenced in `.fwimage` and stays numeric (E59).

For each call `writer(n, arg..., &metadata)`:
    N          = n + 1
    n_args     = n - 1 = N - 2
    metadata   = last operand, a literal VA in the task's logging section

The decompiled C is the primary source: it gives the literal operand count and the
enclosing function.  Ghidra never analyzed several regions that contain real log
calls, so the script also performs a range-filtered `AUIPC+ADDI`/`LUI+ADDI` scan
for metadata VAs.  Those rows carry `source=raw` and `n_args=-1` (a wildcard); the
function comes from a Ghidra header or the nearest preceding prologue and the
module from the nearest `module_index.csv` entry.

A bare `AUIPC+JALR` call scan is not used: it produces thousands of false positives
in data.  The metadata-VA range filter and the prologue attribution keep the raw
fallback usable.

Usage:
    python3 build_id_table.py                     # defaults for this tree
    python3 build_id_table.py --out id_table.csv
"""

from __future__ import annotations

import argparse
import bisect
import collections
import csv
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_DECOMPILED = Path(os.environ.get("DECOMPILED", HERE / "gsp_decompiled.c"))
DEFAULT_MODULES = Path(os.environ.get("MODULES", HERE / "modules_v2"))
DEFAULT_IMAGE = Path(os.environ.get("FWIMAGE", HERE / "gsp_fwimage.bin"))
DEFAULT_OUT = Path(os.environ.get("OUT", HERE / "id_table.csv"))
DEFAULT_SUMMARY = Path(os.environ.get("SUMMARY", HERE / "id_table_summary.json"))

IMAGE_BASE = 0x01000000

# Metadata-ID ranges used by the raw fallback scanner.  These are the observed
# section bounds, not the permissive writer id_lo/id_hi used by the decompiled
# parser.
RAW_RANGES = {
    "FUN_ram_01b9e86e": (0x203B0000, 0x20530000),
    "FUN_ram_011849a6": (0x20186000, 0x20189000),
    "FUN_ram_01179c62": (0x20179500, 0x20179D00),
}

# The backward prologue scan can pick an inner stack adjustment inside a large
# function.  Ghidra-verified correction: 0x01187eae is inside FUN_ram_01187426
# (true span 0x01187426..0x011898f1), not a separate function.
RAW_FUNC_OVERRIDES = {
    0x01187EAE: (0x01187426, "FUN_ram_01187426"),
}

# writer -> (task class, logging-section base, accepted metadata-VA range)
WRITERS = {
    "FUN_ram_01b9e86e": {
        "task_class": "RM",
        "base": 0x2018F000,
        "id_lo": 0x20000000,
        "id_hi": 0x20600000,
    },
    "FUN_ram_01179c62": {
        "task_class": "EARLY",
        "base": 0x20178000,
        "id_lo": 0x20170000,
        "id_hi": 0x20180000,
    },
    "FUN_ram_011849a6": {
        "task_class": "INIT",
        "base": 0x20183000,
        "id_lo": 0x20180000,
        "id_hi": 0x20190000,
    },
}

HEADER_RE = re.compile(
    r"/\* ==== ram:([0-9a-fA-F]+)\s+(\S+)\s+size=(0x[0-9a-fA-F]+|\d+) ==== \*/"
)

# A literal metadata operand.  Ghidra sometimes prints a cast and/or an integer
# suffix, e.g. `(ulong)0x203b9b10`, `0x203b9b10ULL`.
LITERAL_RE = re.compile(
    r"(?:\(\s*(?:ulong|long|uint|int|unsigned\s+long)\s*\)\s*)?"
    r"(0x[0-9a-fA-F]+|\d+)[uUlL]*\s*$"
)

CALL_RE = re.compile(
    r"\b(FUN_ram_01b9e86e|FUN_ram_01179c62|FUN_ram_011849a6)\s*\("
)


def split_args(text: str) -> list[str]:
    """Split a C argument list on top-level commas, respecting quotes."""
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


def find_close(text: str, start: int) -> int | None:
    """Return the index just past the ')' matching the '(' before `start`."""
    depth = 1
    quote: str | None = None
    i = start
    n = len(text)
    while i < n:
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
            if depth == 0:
                return i + 1
        i += 1
    return None


def parse_number(text: str) -> int | None:
    text = text.strip()
    try:
        return int(text, 0)
    except ValueError:
        return None


def parse_literal(text: str) -> int | None:
    m = LITERAL_RE.fullmatch(text.strip())
    if not m:
        return None
    tok = m.group(1)
    try:
        return int(tok, 0)
    except ValueError:
        return None


def load_module_map(modules_dir: Path) -> dict[str, str]:
    """Map Ghidra function name -> module name.

    Prefers `module_index.csv` (one row per function, produced by the module
    splitter); falls back to parsing every header out of the module sources.
    """
    mapping: dict[str, str] = {}
    if not modules_dir.is_dir():
        return mapping

    index_csv = modules_dir / "module_index.csv"
    if index_csv.is_file():
        with index_csv.open(newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                name = row.get("name", "")
                module = row.get("module", "")
                if name and module and module != "-1":
                    mapping.setdefault(name, module)
        if mapping:
            return mapping

    for path in sorted(modules_dir.glob("*.c")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in HEADER_RE.finditer(text):
            mapping.setdefault(m.group(2), path.stem)
    return mapping


def load_module_addr_map(modules_dir: Path) -> tuple[list[int], list[str]]:
    """Return (sorted addresses, modules) from module_index.csv for raw functions."""
    addr: list[int] = []
    mods: list[str] = []
    index_csv = modules_dir / "module_index.csv"
    if not index_csv.is_file():
        return addr, mods
    with index_csv.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                a = int(row.get("address", ""), 0)
            except ValueError:
                continue
            m = row.get("module", "")
            if m and m != "-1":
                addr.append(a)
                mods.append(m)
    order = sorted(range(len(addr)), key=lambda i: addr[i])
    return [addr[i] for i in order], [mods[i] for i in order]


def module_for_addr(
    addr: int, module_addrs: list[int], module_names: list[str], max_gap: int = 0x20000
) -> str:
    if not module_addrs:
        return ""
    i = bisect.bisect_right(module_addrs, addr) - 1
    if i < 0 or addr - module_addrs[i] > max_gap:
        return ""
    return module_names[i]


def _sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def scan_metadata_targets(data: bytes) -> dict[int, list[int]]:
    """Find AUIPC+ADDI / LUI+ADDI pairs that materialize a metadata-style VA.

    Ghidra never analyzed several regions that contain real log calls; the raw
    instruction scan recovers those IDs.  The caller filters by the known
    per-writer metadata ranges.
    """
    targets: dict[int, list[int]] = {}

    def add(target: int, site: int) -> None:
        targets.setdefault(target, []).append(site)

    for off in range(0, len(data) - 7, 2):
        pc = IMAGE_BASE + off
        w0 = int.from_bytes(data[off : off + 4], "little")
        w1 = int.from_bytes(data[off + 4 : off + 8], "little")

        # AUIPC rd, imm20 ; ADDI rd, rd, imm12
        if (w0 & 0x7F) == 0x17:
            rd = (w0 >> 7) & 0x1F
            imm20 = _sext(w0 & 0xFFFFF000, 32)
            if (
                (w1 & 0x7F) == 0x13
                and ((w1 >> 12) & 7) == 0
                and ((w1 >> 15) & 0x1F) == rd
                and ((w1 >> 7) & 0x1F) == rd
            ):
                add(pc + imm20 + _sext(w1 >> 20, 12), pc)

        # LUI rd, imm20 ; ADDI rd, rd, imm12
        if (w0 & 0x7F) == 0x37:
            rd = (w0 >> 7) & 0x1F
            imm = w0 & 0xFFFFF000
            if (
                (w1 & 0x7F) == 0x13
                and ((w1 >> 12) & 7) == 0
                and ((w1 >> 15) & 0x1F) == rd
                and ((w1 >> 7) & 0x1F) == rd
            ):
                add(imm + _sext(w1 >> 20, 12), pc)

    return targets


def _is_prologue(data: bytes, addr: int) -> bool:
    off = addr - IMAGE_BASE
    if off < 0 or off + 2 > len(data):
        return False
    h = int.from_bytes(data[off : off + 2], "little")
    # C.ADDI16SP sp, -N : quadrant 1, funct3=011, rd=00010, imm[9]=1
    if (h & 0xEF83) == 0x6101 and (h & 0x1000):
        return True
    if off + 4 <= len(data):
        w = int.from_bytes(data[off : off + 4], "little")
        # ADDI sp, sp, -N
        if (
            (w & 0x7F) == 0x13
            and ((w >> 7) & 0x1F) == 2
            and ((w >> 12) & 7) == 0
            and ((w >> 15) & 0x1F) == 2
            and _sext(w >> 20, 12) < 0
        ):
            return True
    return False


def _prologue_start(data: bytes, site: int, limit: int = 4096) -> int | None:
    for addr in range(site, max(IMAGE_BASE, site - limit), -2):
        if _is_prologue(data, addr):
            return addr
    return None


def find_function(
    data: bytes,
    site: int,
    header_intervals: list[tuple[int, int, str]],
    header_starts: list[int],
    header_names: dict[int, str],
) -> tuple[int, str, int]:
    """Return (address, name, confidence).  Confidence 2 = Ghidra header."""
    idx = bisect.bisect_right(header_starts, site) - 1
    if idx >= 0:
        start, end, name = header_intervals[idx]
        if start <= site < end:
            return start, name, 2
    start = _prologue_start(data, site)
    if start is None:
        return 0, "?", 0
    return start, header_names.get(start, f"FUN_ram_{start:08x}"), 1


def build(
    decompiled: Path,
    modules_dir: Path,
    out_csv: Path,
    out_summary: Path,
    image: Path | None = None,
    augment_raw: bool = True,
) -> dict:
    text = decompiled.read_text(encoding="utf-8", errors="replace")
    headers = list(HEADER_RE.finditer(text))
    header_starts = [h.start() for h in headers]
    module_map = load_module_map(modules_dir)
    module_addrs, module_names = load_module_addr_map(modules_dir)

    # text.count("\n", 0, pos) per call is quadratic over a 48 MB file; index the
    # newlines once and bisect instead.
    newlines = [i for i, ch in enumerate(text) if ch == "\n"]

    def line_of(pos: int) -> int:
        return bisect.bisect_right(newlines, pos) + 1

    rows: list[dict] = []
    stats: dict[str, dict] = {}
    func_call_ordinal: collections.Counter[str] = collections.Counter()
    dynamic = collections.Counter()
    rejected = collections.Counter()

    for m in CALL_RE.finditer(text):
        writer = m.group(1)
        spec = WRITERS[writer]
        close = find_close(text, m.end())
        if close is None:
            rejected["unterminated"] += 1
            continue
        args = split_args(text[m.end() : close - 1])
        line_no = line_of(m.start())

        # The function definition itself has a non-numeric first parameter.
        if len(args) < 2:
            rejected["short"] += 1
            continue
        n_operands = parse_number(args[0])
        if n_operands is None:
            rejected["definition_or_bad_n"] += 1
            continue

        meta_id = parse_literal(args[-1])
        if meta_id is None:
            dynamic[writer] += 1
            continue
        if not (spec["id_lo"] <= meta_id < spec["id_hi"]):
            rejected["id_out_of_range"] += 1
            continue

        expected_len = n_operands + 1       # n operands + metadata pointer
        n_args = len(args) - 2             # args between count and metadata
        n_recovered = 0
        if len(args) != expected_len or n_args != n_operands - 1:
            # Ghidra occasionally loses or invents a vararg.  The stored argument
            # count is what the record encoding will carry at runtime; trust the
            # recovered operand list and mark the row.
            n_recovered = 1
        if n_args < 0 or n_args > 20:
            rejected["bad_n_args"] += 1
            continue

        hdr_idx = bisect.bisect_right(header_starts, m.start()) - 1
        if hdr_idx >= 0:
            h = headers[hdr_idx]
            func_addr = int(h.group(1), 16)
            func_name = h.group(2)
        else:
            func_addr = 0
            func_name = "?"

        ordinal = func_call_ordinal[func_name]
        func_call_ordinal[func_name] += 1

        rows.append(
            {
                "writer": writer,
                "task_class": spec["task_class"],
                "base": spec["base"],
                "meta_id": meta_id,
                "n_operands": n_operands,
                "n_args": n_args,
                "n_recovered": n_recovered,
                "call_ordinal": ordinal,
                "func_addr": func_addr,
                "func_name": func_name,
                "module": module_map.get(func_name, ""),
                "decomp_line": line_no,
                "source": "decompiled",
            }
        )
        s = stats.setdefault(
            writer,
            {
                "rows": 0,
                "distinct_ids": set(),
                "recovered_n": 0,
                "min_n_args": 99,
                "max_n_args": -1,
            },
        )
        s["rows"] += 1
        s["distinct_ids"].add(meta_id)
        s["recovered_n"] += n_recovered
        s["min_n_args"] = min(s["min_n_args"], n_args)
        s["max_n_args"] = max(s["max_n_args"], n_args)

    # Raw fallback: recover metadata IDs whose call sites Ghidra never analyzed.
    raw_rows = 0
    if augment_raw and image is not None and image.is_file():
        data = image.read_bytes()
        header_intervals = sorted(
            (
                int(h.group(1), 16),
                int(h.group(1), 16) + int(h.group(3), 0),
                h.group(2),
            )
            for h in headers
        )
        hstarts = [x[0] for x in header_intervals]
        hnames = {s: n for s, _, n in header_intervals}
        known_keys = {(r["base"], r["meta_id"]) for r in rows}
        raw_best: dict[tuple[int, int], dict] = {}

        for target, sites in scan_metadata_targets(data).items():
            writer = None
            for name, (lo, hi) in RAW_RANGES.items():
                if lo <= target < hi:
                    writer = name
                    break
            if writer is None:
                continue
            spec = WRITERS[writer]
            key = (spec["base"], target)
            if key in known_keys:
                continue

            best = None
            for site in sites:
                faddr, fname, conf = find_function(
                    data, site, header_intervals, hstarts, hnames
                )
                if faddr == 0:
                    continue
                if best is None or conf > best[2]:
                    best = (faddr, fname, conf)
            if best is None:
                continue

            faddr, fname, conf = best
            if faddr in RAW_FUNC_OVERRIDES:
                faddr, fname = RAW_FUNC_OVERRIDES[faddr]
                conf = 2
            raw_best[key] = {
                "writer": writer,
                "task_class": spec["task_class"],
                "base": spec["base"],
                "meta_id": target,
                "n_operands": -1,
                "n_args": -1,
                "n_recovered": 0,
                "call_ordinal": 0,
                "func_addr": faddr,
                "func_name": fname,
                "module": module_map.get(fname, "")
                or module_for_addr(faddr, module_addrs, module_names),
                "decomp_line": 0,
                "source": "raw",
            }

        rows.extend(raw_best.values())
        raw_rows = len(raw_best)

    # Sort for stable output and easy diffing.
    rows.sort(key=lambda r: (r["writer"], r["meta_id"], r["func_addr"], r["call_ordinal"]))

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "writer",
        "task_class",
        "base",
        "meta_id",
        "meta_id_hex",
        "n_operands",
        "n_args",
        "n_recovered",
        "call_ordinal",
        "func_addr",
        "func_addr_hex",
        "func_name",
        "module",
        "decomp_line",
        "source",
    ]
    with out_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(
                {
                    **r,
                    "base": f"0x{r['base']:08x}",
                    "meta_id": r["meta_id"],
                    "meta_id_hex": f"0x{r['meta_id']:x}",
                    "call_ordinal": r["call_ordinal"],
                    "func_addr": r["func_addr"],
                    "func_addr_hex": f"0x{r['func_addr']:08x}",
                }
            )

    raw_by_writer = collections.Counter(
        r["writer"] for r in rows if r["source"] == "raw"
    )
    ids_by_writer = {
        w: {r["meta_id"] for r in rows if r["writer"] == w} for w in WRITERS
    }
    summary = {
        "source": str(decompiled),
        "image": str(image) if image is not None else None,
        "modules": str(modules_dir),
        "out": str(out_csv),
        "rows": len(rows),
        "raw_rows": raw_rows,
        "writers": {},
        "dynamic_metadata_calls": dict(dynamic),
        "rejected": dict(rejected),
    }
    for writer, s in stats.items():
        ids = ids_by_writer[writer]
        summary["writers"][writer] = {
            "task_class": WRITERS[writer]["task_class"],
            "base": f"0x{WRITERS[writer]['base']:08x}",
            "decompiled_rows": s["rows"],
            "raw_rows": raw_by_writer[writer],
            "rows": s["rows"] + raw_by_writer[writer],
            "distinct_ids": len(ids),
            "recovered_n": s["recovered_n"],
            "n_args_min": s["min_n_args"],
            "n_args_max": s["max_n_args"],
            "id_min": f"0x{min(ids):x}" if ids else None,
            "id_max": f"0x{max(ids):x}" if ids else None,
        }
    out_summary.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--decompiled", type=Path, default=DEFAULT_DECOMPILED)
    ap.add_argument("--modules", type=Path, default=DEFAULT_MODULES)
    ap.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    ap.add_argument(
        "--no-raw",
        action="store_true",
        help="skip the raw-instruction fallback scan (decompiled call sites only)",
    )
    args = ap.parse_args()

    if not args.decompiled.is_file():
        print(f"error: decompiled image not found: {args.decompiled}", file=sys.stderr)
        return 1

    summary = build(
        args.decompiled,
        args.modules,
        args.out,
        args.summary,
        image=args.image,
        augment_raw=not args.no_raw,
    )
    print(f"wrote {summary['out']} ({summary['rows']} rows, {summary['raw_rows']} raw)")
    for writer, s in summary["writers"].items():
        print(
            f"  {writer}: {s['decompiled_rows']} decompiled + {s['raw_rows']} raw sites, "
            f"{s['distinct_ids']} distinct IDs ({s['id_min']}..{s['id_max']}), "
            f"n_args {s['n_args_min']}..{s['n_args_max']}, {s['recovered_n']} recovered-n"
        )
    if summary["dynamic_metadata_calls"]:
        print(f"  dynamic metadata operands (not tabulated): {summary['dynamic_metadata_calls']}")
    if summary["rejected"]:
        print(f"  rejected: {summary['rejected']}")
    print(f"wrote {args.summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
