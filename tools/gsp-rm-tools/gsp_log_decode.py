#!/usr/bin/env python3
"""Offline decoder for GSP-RM libos log ring buffers.

The host allocates one cached sysmem ring per firmware task and hands its GPU
physical address to GSP-RM.  Firmware writes fixed-size u64 records:

    [ arg0 ... arg(N-2) ][ meta ][ timestamp ]

    meta bits 47:0   metadata VA - per-task logging-section base
    meta bits 55:48  N, total u64 entries in the record (2..22)
    meta bits 63:56  libos task id

The metadata VA points at a `libosLogMetadata` struct in the stripped
`.fwlogging_*` section of the missing `gsp_log_ga10x.bin`.  We do not have that
file, so this decoder substitutes the static metadata-ID table produced by
`build_id_table.py`: every metadata VA is a compile-time constant at a known
call site, so each record still resolves to the emitting function, module and
argument count.  The message text, source line and severity are unavailable.

Ring geometry (driver: liblogdecode.c, firmware: FUN_ram_01b9e86e):

    word[0]      total u64 words ever written (monotonic; not a ring index)
    word[1..L]   ring data, L = buffer_size/8 - 1
    data word k (0-based word number) -> word[1 + (k % L)]

Decoder walks backwards from the newest complete record, then reverses.

Usage:
    gsp_log_decode.py --manifest run/manifest.json
    gsp_log_decode.py gsp_log_gpu0_0.bin --task rm
    gsp_log_decode.py --stats raw/*.bin --task-map auto

See README.md for the capture format.
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ID_TABLE = HERE / "id_table.csv"
DEFAULT_INIT_STRINGS = HERE / "init_strings.csv"

TASK_NAMES = {
    0: "UNKNOWN",
    1: "KERNEL",
    2: "INIT",
    3: "RM",
    4: "INTR",
    5: "VGPU",
    6: "MNOC",
    7: "DEBUG",
    8: "ROOT",
    9: "RMON",
}

TASK_ALIASES = {
    "kernel": 1,
    "krnl": 1,
    "init": 2,
    "rm": 3,
    "intr": 4,
    "vgpu": 5,
    "mnoc": 6,
    "debug": 7,
    "dbg": 7,
    "root": 8,
    "rmon": 9,
}

# Per-task logging-section base.  Tasks that share a `.fwlogging_*` section
# share a base:
#   1 KERNEL, 2 INIT                     -> .fwlogging_kernel_* / .fwlogging_init
#   3 RM, 4 INTR, 9 RMON                 -> .fwlogging_rm
#   5 VGPU, 6 MNOC, 7 DEBUG, 8 ROOT      -> unknown base; resolved by membership
KNOWN_BASES = {
    1: 0x20178000,  # KERNEL, FUN_ram_01179c62
    2: 0x20183000,  # INIT,   FUN_ram_011849a6
    3: 0x2018F000,  # RM,     FUN_ram_01b9e86e
    4: 0x2018F000,  # INTR shares .fwlogging_rm
    9: 0x2018F000,  # RMON shares .fwlogging_rm
}
CANDIDATE_BASES = (0x2018F000, 0x20183000, 0x20178000)

META_ID_MASK = (1 << 48) - 1
ENTRY_MIN = 2
ENTRY_MAX = 22
DEFAULT_RESYNC_WINDOW = 64


@dataclass
class IdRow:
    writer: str
    task_class: str
    base: int
    meta_id: int
    n_operands: int
    n_args: int
    n_recovered: int
    call_ordinal: int
    func_addr: int
    func_name: str
    module: str
    decomp_line: int
    source: str = "decompiled"


class IdTable:
    def __init__(self, rows: list[IdRow] | None = None):
        self.rows: list[IdRow] = rows or []
        self.by_key: dict[tuple[int, int], list[IdRow]] = collections.defaultdict(list)
        self.by_id: dict[int, list[IdRow]] = collections.defaultdict(list)
        for r in self.rows:
            self.by_key[(r.base, r.meta_id)].append(r)
            self.by_id[r.meta_id].append(r)

    @classmethod
    def load(cls, path: Path) -> "IdTable":
        rows: list[IdRow] = []
        with path.open(newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                rows.append(
                    IdRow(
                        writer=r["writer"],
                        task_class=r["task_class"],
                        base=int(r["base"], 0),
                        meta_id=int(r["meta_id_hex"], 16),
                        n_operands=int(r["n_operands"] or -1),
                        n_args=int(r["n_args"]),
                        n_recovered=int(r["n_recovered"] or 0),
                        call_ordinal=int(r["call_ordinal"]),
                        func_addr=int(r["func_addr_hex"], 16),
                        func_name=r["func_name"],
                        module=r["module"],
                        decomp_line=int(r["decomp_line"] or 0),
                        source=r.get("source", "decompiled"),
                    )
                )
        return cls(rows)

    def lookup(self, task: int, meta_low: int) -> tuple[int, int, list[IdRow], list[str]]:
        """Resolve a 48-bit metadata offset.

        Returns (base, meta_id, rows, flags).  rows is empty when unknown.
        """
        flags: list[str] = []
        bases: list[int] = []
        if task in KNOWN_BASES:
            bases.append(KNOWN_BASES[task])
        for b in CANDIDATE_BASES:
            if b not in bases:
                bases.append(b)

        hits: list[tuple[int, int, list[IdRow]]] = []
        for b in bases:
            va = b + meta_low
            rows = self.by_key.get((b, va))
            if rows:
                hits.append((b, va, rows))

        if not hits:
            # Last resort: the same numeric VA may exist under either base.
            for b in CANDIDATE_BASES:
                rows = self.by_key.get((b, meta_low + b))
                if rows:
                    hits.append((b, meta_low + b, rows))

        if not hits:
            base = KNOWN_BASES.get(task, CANDIDATE_BASES[0])
            return base, base + meta_low, [], ["unknown_id"]

        if len(hits) > 1:
            flags.append("ambiguous_id")

        base, va, rows = hits[0]
        if task in KNOWN_BASES and base != KNOWN_BASES[task]:
            flags.append("base_mismatch")
        if task not in KNOWN_BASES:
            flags.append("base_inferred")
        return base, va, rows, flags


@dataclass
class InitString:
    meta_id: int
    fmt: str
    filename: str
    line: int | None
    func_name: str

    def render(self) -> str:
        """Substitute the file/line prefix, leave record arguments as specifiers."""
        text = self.fmt
        # Only KERNEL rows carry a filename; INIT rows must keep their own %s
        # arguments untouched.
        if self.filename and "%s" in text:
            text = text.replace("%s", self.filename, 1)
        if self.line is not None and "%u" in text:
            text = text.replace("%u", str(self.line), 1)
        return text.rstrip("\n")


def load_init_strings(path: Path) -> dict[int, InitString]:
    out: dict[int, InitString] = {}
    with path.open(newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            mid = int(r["meta_id_hex"], 16)
            out.setdefault(
                mid,
                InitString(
                    meta_id=mid,
                    fmt=r["format"],
                    filename=r["filename"],
                    line=int(r["line"]) if r["line"] else None,
                    func_name=r["func_name"],
                ),
            )
    return out


@dataclass
class Record:
    buffer_index: int
    path: str
    gpu: int | None
    task: int
    task_name: str
    timestamp: int
    meta_word: int
    meta_low: int
    n: int
    n_args: int
    args: list[int]
    base: int
    meta_id: int
    rows: list[IdRow]
    init_string: InitString | None = None
    flags: list[str] = field(default_factory=list)
    k_start: int = 0
    k_end: int = 0

    @property
    def func_name(self) -> str:
        return self.rows[0].func_name if self.rows else "?"

    @property
    def func_addr(self) -> int:
        return self.rows[0].func_addr if self.rows else 0

    @property
    def module(self) -> str:
        return self.rows[0].module if self.rows else ""

    @property
    def resolved(self) -> bool:
        return bool(self.rows)


@dataclass
class BufferInfo:
    index: int
    path: str
    gpu: int | None
    task_hint: int | None
    task_name_hint: str
    base_override: int | None
    size_bytes: int
    capacity: int
    declared_put: int
    put: int
    wrapped: bool
    records: list[Record]
    gaps: list[dict]
    notes: list[str]


def align_base(task: int, override: int | None) -> int | None:
    return override if override is not None else KNOWN_BASES.get(task)


def parse_task(text: str | int | None) -> int | None:
    if text is None or text == "":
        return None
    if isinstance(text, int):
        return text
    t = text.strip().lower()
    if t.isdigit():
        return int(t)
    if t.startswith("0x"):
        return int(t, 16)
    return TASK_ALIASES.get(t)


def guess_task_from_path(path: str) -> int | None:
    stem = Path(path).stem.lower()
    tokens = re.split(r"[^a-z0-9]+", stem)
    for tok in tokens:
        t = TASK_ALIASES.get(tok)
        if t is not None:
            return t
        m = re.fullmatch(r"task(\d+)", tok)
        if m:
            return int(m.group(1))
    for name, t in TASK_ALIASES.items():
        if name in stem:
            return t
    return None


def _word(words: tuple[int, ...], k: int, capacity: int) -> int:
    return words[1 + (k % capacity)]


def parse_buffer(
    data: bytes,
    *,
    index: int = 0,
    path: str = "<memory>",
    gpu: int | None = None,
    task_hint: int | None = None,
    base_override: int | None = None,
    put_override: int | None = None,
    put_auto: bool = False,
    id_table: IdTable | None = None,
    init_strings: dict[int, "InitString"] | None = None,
    resync: bool = False,
    resync_window: int = DEFAULT_RESYNC_WINDOW,
    max_records: int | None = None,
) -> BufferInfo:
    if len(data) < 16 or len(data) % 8:
        raise ValueError(f"{path}: size {len(data)} is not a usable u64 ring")
    nwords = len(data) // 8
    words = struct.unpack_from(f"<{nwords}Q", data, 0)
    capacity = nwords - 1
    declared_put = words[0]

    if put_override is not None:
        put = put_override
    elif declared_put == 0 and put_auto:
        # The put counter is only advanced once a whole record lands, so a zero
        # word0 with populated data means the capture raced firmware startup (or
        # word0 was clobbered).  Find the newest plausible record end.
        put = 0
        for cand in range(capacity - 1, 0, -1):
            meta = _word(words, cand - 1, capacity)
            n = (meta >> 48) & 0xFF
            task_bits = (meta >> 56) & 0xFF
            if (
                ENTRY_MIN <= n <= ENTRY_MAX
                and task_bits < 16
                and cand - (n - 1) >= 0
            ):
                put = cand + 1
                break
    elif declared_put == 0:
        put = 0
    else:
        put = declared_put

    notes: list[str] = []
    if put_auto and declared_put == 0:
        notes.append(f"put counter auto-detected at 0x{put:x}")
    if put > (1 << 56):
        raise ValueError(f"{path}: implausible put counter 0x{put:x}")
    if declared_put != put:
        notes.append(f"put overridden: word0=0x{declared_put:x} -> 0x{put:x}")
    if put == 0:
        notes.append("put counter is zero: no records (or capture raced init)")
        return BufferInfo(
            index=index,
            path=path,
            gpu=gpu,
            task_hint=task_hint,
            task_name_hint=TASK_NAMES.get(task_hint or -1, ""),
            base_override=base_override,
            size_bytes=len(data),
            capacity=capacity,
            declared_put=declared_put,
            put=put,
            wrapped=False,
            records=[],
            gaps=[],
            notes=notes,
        )

    wrapped = put > capacity
    floor = put - capacity if wrapped else 0
    end = put - 1
    records: list[Record] = []
    gaps: list[dict] = []
    skipped = 0

    while end >= floor and end >= 1:
        if max_records is not None and len(records) >= max_records:
            notes.append(f"stopped at max_records={max_records}")
            break

        ts = _word(words, end, capacity)
        meta = _word(words, end - 1, capacity)
        n = (meta >> 48) & 0xFF
        task_bits = (meta >> 56) & 0xFF
        meta_low = meta & META_ID_MASK

        valid = ENTRY_MIN <= n <= ENTRY_MAX and task_bits < 16
        if valid and end - (n - 1) < floor:
            valid = False  # record begins before the retained window

        if not valid:
            gaps.append(
                {
                    "k_end": end,
                    "meta_word": f"0x{meta:x}",
                    "n": n,
                    "task": task_bits,
                    "reason": "bad record boundary",
                }
            )
            if not resync:
                notes.append(
                    f"stopped at bad boundary k={end} (N={n}, task={task_bits}); "
                    "pass --resync to scan past it"
                )
                break
            # Scan backwards one word at a time for the next plausible boundary.
            found = None
            for cand in range(end - 1, max(floor, end - resync_window) - 1, -1):
                if cand < 1:
                    break
                m = _word(words, cand - 1, capacity)
                nn = (m >> 48) & 0xFF
                tt = (m >> 56) & 0xFF
                if ENTRY_MIN <= nn <= ENTRY_MAX and tt < 16 and cand - (nn - 1) >= floor:
                    found = cand
                    break
            if found is None:
                notes.append(
                    f"resync gave up after {min(resync_window, end - floor)} words"
                )
                break
            skipped += end - found
            end = found
            continue

        # Forward order is [arg0 ... arg(N-2)][meta][timestamp]: the writer emits
        # operands first, then the metadata operand, then the time counter.
        start = end - (n - 1)
        args = [_word(words, k, capacity) for k in range(start, end - 1)]

        task = task_bits
        flags: list[str] = []
        if task == 0 and task_hint is not None:
            task = task_hint
            flags.append("task_from_buffer")
        base = base_override if base_override is not None else None
        if base is None:
            if id_table is not None:
                base, meta_id, rows, rflags = id_table.lookup(task, meta_low)
                flags.extend(rflags)
            else:
                base = KNOWN_BASES.get(task, CANDIDATE_BASES[0])
                meta_id = base + meta_low
                rows = []
        else:
            meta_id = base + meta_low
            rows = id_table.by_key.get((base, meta_id), []) if id_table else []

        if rows:
            # An inlined statement can leave several call sites for one ID.  Prefer
            # the one whose literal argument count matches this record.  A raw
            # fallback row has n_args=-1: it identifies the function but not the
            # operand count, so it is a wildcard.
            exact = [row for row in rows if row.n_args == n - 2]
            wild = [row for row in rows if row.n_args < 0]
            if exact:
                rows = exact
            elif wild:
                rows = wild
            else:
                flags.append("n_args_mismatch")
            if rows[0].n_recovered:
                flags.append("recovered_n")
            if rows[0].source == "raw":
                flags.append("raw_function")
        if task_bits >= len(TASK_NAMES):
            flags.append("unknown_task")

        init_text = None
        task_base_ok = (
            (task == 1 and base == 0x20178000)
            or (task == 2 and base == 0x20183000)
        )
        if init_strings and task_base_ok and meta_id in init_strings:
            init_text = init_strings[meta_id]

        records.append(
            Record(
                buffer_index=index,
                path=path,
                gpu=gpu,
                task=task,
                task_name=TASK_NAMES.get(task, f"T{task}"),
                timestamp=ts,
                meta_word=meta,
                meta_low=meta_low,
                n=n,
                n_args=n - 2,
                args=args,
                base=base,
                meta_id=meta_id,
                rows=rows,
                init_string=init_text,
                flags=flags,
                k_start=start,
                k_end=end,
            )
        )
        end = start - 1

    records.reverse()
    if skipped:
        notes.append(f"resync skipped {skipped} words")
    if wrapped:
        notes.append(f"ring wrapped: retained {min(put, capacity)} of {put} words")

    return BufferInfo(
        index=index,
        path=path,
        gpu=gpu,
        task_hint=task_hint,
        task_name_hint=TASK_NAMES.get(task_hint or -1, ""),
        base_override=base_override,
        size_bytes=len(data),
        capacity=capacity,
        declared_put=declared_put,
        put=put,
        wrapped=wrapped,
        records=records,
        gaps=gaps,
        notes=notes,
    )


def load_manifest(path: Path) -> list[dict]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    base_dir = path.parent
    entries = []
    raw_buffers = obj.get("buffers", obj if isinstance(obj, list) else [])
    if not isinstance(raw_buffers, list):
        raise ValueError(f"{path}: 'buffers' must be a list")
    for i, b in enumerate(raw_buffers):
        if isinstance(b, str):
            b = {"path": b}
        p = Path(b["path"])
        if not p.is_absolute():
            p = base_dir / p
        entries.append(
            {
                "index": i,
                "path": str(p),
                "gpu": b.get("gpu", obj.get("gpu") if isinstance(obj, dict) else None),
                "task": parse_task(b.get("task")),
                "base": _parse_optional_int(b.get("base")),
                "size": _parse_optional_int(b.get("size")),
                "put": None if b.get("put") in (None, "auto") else _parse_optional_int(b.get("put")),
                "put_auto": b.get("put") == "auto",
            }
        )
    return entries


def _parse_optional_int(v) -> int | None:
    if v is None or v == "":
        return None
    if isinstance(v, int):
        return v
    return int(str(v), 0)


def format_args(args: list[int]) -> str:
    return "[" + ", ".join(f"0x{a:x}" for a in args) + "]"


def format_record(
    r: Record,
    *,
    delta_ns: int | None,
    time_unit: str,
) -> str:
    if time_unit == "ticks" or delta_ns is None:
        tfield = f"t={r.timestamp}"
    elif time_unit == "ns":
        tfield = f"+{delta_ns} ns"
    else:
        # Firmware timestamps are GSP timer ticks, assumed to be nanoseconds.
        scale = {"us": 1e-3, "ms": 1e-6, "s": 1e-9}[time_unit]
        tfield = f"+{delta_ns * scale:.6f} {time_unit}"
    flags = f"  !{'|'.join(r.flags)}" if r.flags else ""
    func = f"{r.func_name} [{r.module}]" if r.resolved else "UNRESOLVED"
    if r.rows and r.rows[0].source == "raw":
        func += " [raw]"
    if len(r.rows) > 1:
        func += f" (+{len(r.rows) - 1} caller candidates)"
    text = ""
    if r.init_string is not None:
        rendered = r.init_string.render().replace("\n", "\\n")
        text = f'  text="{rendered}"'
    return (
        f"[{tfield:>16}] t={r.task} {r.task_name:<7} "
        f"id=0x{r.meta_id:x} n_args={r.n_args}  {func}  args={format_args(r.args)}"
        f"{text}{flags}"
    )


def record_to_dict(r: Record, first_ts: int | None) -> dict:
    d = {
        "buffer": r.buffer_index,
        "path": r.path,
        "gpu": r.gpu,
        "task": r.task,
        "task_name": r.task_name,
        "timestamp": r.timestamp,
        "meta_word": f"0x{r.meta_word:016x}",
        "meta_id": f"0x{r.meta_id:x}",
        "meta_low": f"0x{r.meta_low:x}",
        "base": f"0x{r.base:x}",
        "n": r.n,
        "n_args": r.n_args,
        "args": [f"0x{a:x}" for a in r.args],
        "resolved": r.resolved,
        "func_addr": f"0x{r.func_addr:x}" if r.resolved else None,
        "func_name": r.func_name if r.resolved else None,
        "module": r.module if r.resolved else None,
        "source": r.rows[0].source if r.resolved else None,
        "flags": r.flags,
        "text": r.init_string.render() if r.init_string is not None else None,
        "text_source": (
            f"{r.init_string.filename}:{r.init_string.line}"
            if r.init_string is not None
            else None
        ),
    }
    if first_ts is not None and r.timestamp >= first_ts:
        d["delta_ns"] = r.timestamp - first_ts
    if len(r.rows) > 1:
        d["caller_candidates"] = [
            {
                "func_addr": f"0x{row.func_addr:x}",
                "func_name": row.func_name,
                "module": row.module,
                "n_args": row.n_args,
            }
            for row in r.rows[:8]
        ]
    return d


def print_stats(buffers: list[BufferInfo], out=sys.stdout) -> None:
    print("# stats", file=out)
    total = 0
    resolved = 0
    task_counts = collections.Counter()
    unknown_ids = collections.Counter()
    flag_counts = collections.Counter()
    for b in buffers:
        total += len(b.records)
        resolved += sum(1 for r in b.records if r.resolved)
        for r in b.records:
            task_counts[r.task_name] += 1
            for f in r.flags:
                flag_counts[f] += 1
            if not r.resolved:
                unknown_ids[f"0x{r.meta_id:x}"] += 1
        print(
            f"# buffer {b.index}: {b.path} size={b.size_bytes}B "
            f"capacity={b.capacity} put=0x{b.put:x} records={len(b.records)} "
            f"gaps={len(b.gaps)} wrapped={b.wrapped}",
            file=out,
        )
        for n in b.notes:
            print(f"#   note: {n}", file=out)
    pct = (100.0 * resolved / total) if total else 0.0
    print(
        f"# total records={total} resolved={resolved} ({pct:.1f}%) "
        f"unresolved={total - resolved}",
        file=out,
    )
    if task_counts:
        print(
            "# tasks: " + ", ".join(f"{k}={v}" for k, v in task_counts.most_common()),
            file=out,
        )
    if flag_counts:
        print(
            "# flags: " + ", ".join(f"{k}={v}" for k, v in flag_counts.most_common()),
            file=out,
        )
    if unknown_ids:
        print(
            "# top unresolved IDs: "
            + ", ".join(f"{k}({v})" for k, v in unknown_ids.most_common(20)),
            file=out,
        )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Decode raw GSP-RM libos log ring buffers without gsp_log_ga10x.bin",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("buffers", nargs="*", help="raw ring buffer file(s)")
    ap.add_argument("--manifest", type=Path, help="JSON manifest of buffers (see README)")
    ap.add_argument("--id-table", type=Path, default=DEFAULT_ID_TABLE)
    ap.add_argument(
        "--init-strings",
        type=Path,
        default=DEFAULT_INIT_STRINGS,
        help="exact kernel/INIT message table (default: init_strings.csv)",
    )
    ap.add_argument(
        "--no-init-strings",
        action="store_true",
        help="do not attach the recovered kernel/INIT message text",
    )
    ap.add_argument(
        "--task",
        help="task id or name applied to bare files (init/rm/intr/mnoc/dbg/root/rmon/krnl)",
    )
    ap.add_argument("--base", help="override logging-section base (hex)")
    ap.add_argument("--put", help="override put counter (hex or 'auto')")
    ap.add_argument("--format", choices=("text", "jsonl", "csv"), default="text")
    ap.add_argument("--merge", action="store_true", help="sort all records by timestamp")
    ap.add_argument("--stats", action="store_true", help="print a decode summary")
    ap.add_argument("--limit", type=int, default=None, help="max records printed")
    ap.add_argument(
        "--time-unit",
        choices=("ns", "us", "ms", "s", "ticks"),
        default="ns",
        help="timestamp unit for display (default: ns)",
    )
    ap.add_argument(
        "--resync",
        action="store_true",
        help="scan past a bad record boundary instead of stopping",
    )
    ap.add_argument(
        "--resync-window",
        type=int,
        default=DEFAULT_RESYNC_WINDOW,
        help=f"words to scan during resync (default {DEFAULT_RESYNC_WINDOW})",
    )
    ap.add_argument(
        "--filter-task", action="append", default=[], help="only records for this task"
    )
    ap.add_argument(
        "--filter-func", default=None, help="only records whose function name contains this"
    )
    ap.add_argument(
        "--filter-module", default=None, help="only records whose module contains this"
    )
    args = ap.parse_args(argv)

    id_table = IdTable.load(args.id_table) if args.id_table.is_file() else None
    if id_table is None:
        print(
            f"warning: id table not found at {args.id_table}; records will be numeric",
            file=sys.stderr,
        )
    init_strings = None
    if not args.no_init_strings and args.init_strings.is_file():
        init_strings = load_init_strings(args.init_strings)

    entries: list[dict] = []
    if args.manifest:
        entries.extend(load_manifest(args.manifest))
    for i, p in enumerate(args.buffers):
        entries.append(
            {
                "index": len(entries) + i,
                "path": p,
                "gpu": None,
                "task": parse_task(args.task) or guess_task_from_path(p),
                "base": _parse_optional_int(args.base),
                "size": None,
                "put": None if args.put in (None, "auto") else int(args.put, 0),
                "put_auto": args.put == "auto",
            }
        )
    if not entries:
        ap.error("no buffers given (use --manifest or positional files)")

    buffers: list[BufferInfo] = []
    for e in entries:
        path = Path(e["path"])
        try:
            data = path.read_bytes()
        except OSError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        if e.get("size") is not None:
            if e["size"] > len(data):
                print(
                    f"error: {path}: manifest size 0x{e['size']:x} exceeds file size "
                    f"0x{len(data):x}",
                    file=sys.stderr,
                )
                return 1
            data = data[: e["size"]]
        task_hint = e.get("task")
        if task_hint is None:
            task_hint = guess_task_from_path(e["path"])
        try:
            buf = parse_buffer(
                data,
                index=e["index"],
                path=str(path),
                gpu=e.get("gpu"),
                task_hint=task_hint,
                base_override=e.get("base"),
                put_override=e.get("put"),
                put_auto=bool(e.get("put_auto")),
                id_table=id_table,
                init_strings=init_strings,
                resync=args.resync,
                resync_window=args.resync_window,
            )
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        buffers.append(buf)

    records = [(b, r) for b in buffers for r in b.records]

    if args.filter_task:
        wanted = {parse_task(t) for t in args.filter_task}
        if None in wanted:
            ap.error(f"unrecognized --filter-task: {args.filter_task}")
        records = [(b, r) for b, r in records if r.task in wanted]
    if args.filter_func:
        needle = args.filter_func.lower()
        records = [(b, r) for b, r in records if needle in r.func_name.lower()]
    if args.filter_module:
        needle = args.filter_module.lower()
        records = [(b, r) for b, r in records if needle in r.module.lower()]

    if args.merge:
        records.sort(key=lambda br: (br[1].timestamp, br[0].index))
        print(
            "# warning: --merge assumes comparable task clocks; the per-task "
            "localToGlobalTimerDelta is not known",
            file=sys.stderr,
        )

    first_ts = min((r.timestamp for _, r in records), default=None)

    if args.format == "text":
        for b in buffers:
            if not args.merge:
                print(
                    f"# buffer {b.index}: {b.path} gpu={b.gpu} "
                    f"hint={b.task_name_hint or '-'} size={b.size_bytes}B "
                    f"capacity={b.capacity} put=0x{b.put:x} "
                    f"records={len(b.records)} wrapped={b.wrapped}"
                )
                for n in b.notes:
                    print(f"#   note: {n}")
                for g in b.gaps:
                    print(f"#   gap: {g}")
        if args.merge:
            print(
                f"# merged {len(records)} records from {len(buffers)} buffer(s)"
            )
        shown = 0
        for b, r in records:
            if args.limit is not None and shown >= args.limit:
                break
            delta = None
            if first_ts is not None and r.timestamp >= first_ts:
                delta = r.timestamp - first_ts
            print(format_record(r, delta_ns=delta, time_unit=args.time_unit))
            shown += 1
        if args.limit is not None and shown >= args.limit and len(records) > shown:
            print(f"# ... {len(records) - shown} more record(s) suppressed by --limit")

    elif args.format == "jsonl":
        for i, (b, r) in enumerate(records):
            if args.limit is not None and i >= args.limit:
                break
            print(json.dumps(record_to_dict(r, first_ts)))

    else:  # csv
        fieldnames = [
            "buffer",
            "gpu",
            "task",
            "task_name",
            "timestamp",
            "delta_ns",
            "meta_id",
            "n",
            "n_args",
            "args",
            "resolved",
            "func_addr",
            "func_name",
            "module",
            "source",
            "flags",
            "text",
            "text_source",
            "caller_candidates",
        ]
        w = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
        w.writeheader()
        for i, (b, r) in enumerate(records):
            if args.limit is not None and i >= args.limit:
                break
            d = record_to_dict(r, first_ts)
            d["args"] = " ".join(d["args"])
            d["flags"] = "|".join(d["flags"])
            d["caller_candidates"] = "|".join(
                f"{c['func_name']}@{c['func_addr']}"
                for c in d.get("caller_candidates", [])
            )
            w.writerow({k: d.get(k) for k in fieldnames})

    if args.stats:
        print_stats(buffers, out=sys.stdout if args.format == "text" else sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
