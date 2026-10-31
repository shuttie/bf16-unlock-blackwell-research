#!/usr/bin/env python3
"""Round-trip tests for the GSP-RM log decoder.

Builds synthetic rings with the same forward-write geometry as the firmware
writer, then checks the backward decoder.  No GPU, firmware image or dump is
needed beyond `id_table.csv`.

Run:
    python3 -I selftest.py
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gsp_log_decode as g
ID_TABLE = HERE / "id_table.csv"

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"PASS  {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL  {name}  {detail}")


def build_ring(records: list[tuple[int, list[int], int]], capacity_words: int) -> bytes:
    """Encode records exactly as FUN_ram_01b9e86e writes them.

    capacity_words is L = buffer_words - 1; valid ring indices are 1..L.
    """
    nwords = capacity_words + 1
    words = [0] * nwords
    idx = 1
    put = 0
    for meta, args, ts in records:
        # Firmware order: operands first, then the metadata operand, then time.
        for value in list(args) + [meta, ts]:
            words[idx] = value & 0xFFFFFFFFFFFFFFFF
            idx += 1
            if idx >= nwords:
                idx = 1
            put += 1
    words[0] = put
    return struct.pack(f"<{nwords}Q", *words)


def meta_word(task: int, n_args: int, base: int, meta_id: int) -> int:
    n = n_args + 2
    assert 2 <= n <= 22
    return (((meta_id - base) & g.META_ID_MASK) | (n << 48) | (task << 56))


def pick_rows(table: g.IdTable, count: int) -> list[g.IdRow]:
    seen = set()
    out = []
    for r in table.rows:
        if r.writer != "FUN_ram_01b9e86e" or r.n_args < 0 or r.n_args > 3:
            continue
        if r.meta_id in seen:
            continue
        seen.add(r.meta_id)
        out.append(r)
        if len(out) >= count:
            break
    return out


def main() -> int:
    if not ID_TABLE.is_file():
        print(f"error: {ID_TABLE} missing; run build_id_table.py first", file=sys.stderr)
        return 2
    table = g.IdTable.load(ID_TABLE)
    check("id table loaded", len(table.rows) > 30000, f"rows={len(table.rows)}")
    init_strings = (
        g.load_init_strings(g.DEFAULT_INIT_STRINGS)
        if g.DEFAULT_INIT_STRINGS.is_file()
        else {}
    )

    rows = pick_rows(table, 50)
    check("picked RM rows", len(rows) == 50)

    # ---- test 1: small ring, no wrap -------------------------------------
    recs = []
    expected = []
    for i, r in enumerate(rows):
        args = [(0x1000 + i * 4 + j) for j in range(r.n_args)]
        ts = 1_000_000 + i * 1000
        recs.append((meta_word(3, r.n_args, 0x2018F000, r.meta_id), args, ts))
        expected.append((r.meta_id, args, ts))
    data = build_ring(recs, capacity_words=4096)
    buf = g.parse_buffer(
        data, index=0, path="small", task_hint=3, id_table=table
    )
    check("small: record count", len(buf.records) == 50, f"got {len(buf.records)}")
    ok = True
    detail = ""
    for got, (mid, args, ts) in zip(buf.records, expected):
        if (got.meta_id, got.args, got.timestamp) != (mid, args, ts) or not got.resolved:
            ok = False
            detail = f"got id=0x{got.meta_id:x} args={got.args} ts={got.timestamp}"
            break
    check("small: records round-trip in order", ok, detail)
    check(
        "small: every record resolves",
        all(r.resolved for r in buf.records),
        f"unresolved={sum(1 for r in buf.records if not r.resolved)}",
    )
    check(
        "small: function names attached",
        all(r.func_name.startswith("FUN_ram_") for r in buf.records),
    )

    # ---- test 2: wrap ----------------------------------------------------
    # 500 variable-size records in a 64-word ring; the decoder must return the
    # newest complete tail without misparsing or returning stale data.
    recs2 = []
    ids2 = []
    for i in range(500):
        r = rows[i % len(rows)]
        args = [i, i ^ 0x5A5A] if r.n_args >= 2 else ([i] if r.n_args == 1 else [])
        ts = 10_000 + i
        recs2.append((meta_word(3, len(args), 0x2018F000, r.meta_id), args, ts))
        ids2.append((r.meta_id, args, ts))
    data2 = build_ring(recs2, capacity_words=64)
    buf2 = g.parse_buffer(data2, index=1, path="wrap", task_hint=3, id_table=table)
    check("wrap: parsed some records", len(buf2.records) > 0, f"got {len(buf2.records)}")
    check("wrap: all parsed records resolve", all(r.resolved for r in buf2.records))
    tail = ids2[-len(buf2.records) :] if buf2.records else []
    check(
        "wrap: newest tail matches",
        [ (r.meta_id, r.args, r.timestamp) for r in buf2.records ] == tail,
        f"got {len(buf2.records)} records",
    )
    check(
        "wrap: no bogus n_args",
        all(r.n_args == len(r.args) for r in buf2.records),
    )

    # ---- test 3: unresolved ID is still parsed ---------------------------
    low = 0x1234
    meta = (low & g.META_ID_MASK) | (4 << 48) | (3 << 56)  # N=4: 2 args + meta + time
    data3 = build_ring([(meta, [0xAA, 0xBB], 42)], capacity_words=64)
    buf3 = g.parse_buffer(data3, path="unk", task_hint=3, id_table=table)
    check("unknown: one record", len(buf3.records) == 1)
    if buf3.records:
        r = buf3.records[0]
        check("unknown: flagged", not r.resolved and "unknown_id" in r.flags, str(r.flags))
        check("unknown: args preserved", r.args == [0xAA, 0xBB], str(r.args))

    # ---- test 4: early writer and INIT base ------------------------------
    erow = next(
        r for r in table.rows if r.writer == "FUN_ram_01179c62" and r.n_args >= 0
    )
    data4 = build_ring(
        [
            (
                meta_word(1, erow.n_args, 0x20178000, erow.meta_id),
                [0x1] * erow.n_args,
                7,
            )
        ],
        capacity_words=64,
    )
    buf4 = g.parse_buffer(
        data4, path="early", task_hint=1, id_table=table, init_strings=init_strings
    )
    check("early: one record", len(buf4.records) == 1)
    if buf4.records:
        check("early: resolved", buf4.records[0].resolved, str(buf4.records[0].flags))
        check("early: base", buf4.records[0].base == 0x20178000)
        # build_init_strings.py should have supplied exact text for this ID.
        check(
            "early: exact text attached",
            buf4.records[0].init_string is not None,
            "run build_init_strings.py",
        )

    irow = next(
        r for r in table.rows if r.writer == "FUN_ram_011849a6" and r.n_args >= 0
    )
    data4i = build_ring(
        [
            (
                meta_word(2, irow.n_args, 0x20183000, irow.meta_id),
                [0x2] * irow.n_args,
                8,
            )
        ],
        capacity_words=64,
    )
    buf4i = g.parse_buffer(
        data4i, path="init", task_hint=2, id_table=table, init_strings=init_strings
    )
    check("init: one record", len(buf4i.records) == 1)
    if buf4i.records:
        check("init: resolved", buf4i.records[0].resolved, str(buf4i.records[0].flags))
        check("init: base", buf4i.records[0].base == 0x20183000)

    # ---- test 5: bad boundary stops / resync ----------------------------
    data5 = bytearray(build_ring(recs[:10], capacity_words=256))
    # Corrupt the meta word of the newest record (k = put-2).
    put = struct.unpack_from("<Q", data5, 0)[0]
    k = put - 2
    off = 8 * (1 + (k % 256))
    struct.pack_into("<Q", data5, off, 0)
    buf5 = g.parse_buffer(bytes(data5), path="bad", task_hint=3, id_table=table)
    check("bad boundary: stops", len(buf5.records) == 0 and len(buf5.gaps) == 1)
    buf5r = g.parse_buffer(
        bytes(data5), path="bad", task_hint=3, id_table=table, resync=True
    )
    check("resync: recovers older records", len(buf5r.records) >= 8, f"got {len(buf5r.records)}")
    check("resync: reports skipped words", any("resync" in n for n in buf5r.notes))

    # ---- test 6: auto put ------------------------------------------------
    data6 = bytearray(build_ring(recs[:5], capacity_words=128))
    struct.pack_into("<Q", data6, 0, 0)  # clobber word0
    buf6 = g.parse_buffer(
        bytes(data6), path="auto", task_hint=3, id_table=table, put_auto=True
    )
    check("auto put: finds records", len(buf6.records) >= 4, f"got {len(buf6.records)}")
    check("auto put: all resolve", all(r.resolved for r in buf6.records))

    # ---- test 7: empty / zeroed ring ------------------------------------
    data7 = build_ring([], capacity_words=64)
    buf7 = g.parse_buffer(
        data7, path="empty", task_hint=3, id_table=table, put_auto=True
    )
    check("empty: no records", len(buf7.records) == 0)
    check("empty: explains zero put", any("zero" in n for n in buf7.notes), str(buf7.notes))

    print()
    if FAILURES:
        print(f"FAILED {len(FAILURES)}: {', '.join(FAILURES)}")
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
