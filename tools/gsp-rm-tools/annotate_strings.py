#!/usr/bin/env python3
"""Annotate a Ghidra C dump with exact firmware string text.

Builds a string map from the raw .fwimage, then:
  - appends `/* "exact text" */` to lines referencing s_/DAT_ string addresses
  - writes strings.csv with every printable string and its address
  - writes strings.h with STR_<ADDR> macros

Usage:
  python3 annotate_strings.py \
    --dump out/gsp_decompiled.c \
    --image input/gsp_fwimage.bin \
    --out out/gsp_decompiled_str.c \
    --csv out/strings.csv \
    --header out/strings.h
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path

PRINTABLE_RE = re.compile(rb"[\x20-\x7e]{4,}")
S_RE = re.compile(r"(?:PTR_)?s_[A-Za-z0-9_]+?_ram_[0-9a-f]+")
DAT_RE = re.compile(r"(?:PTR_)?DAT_ram_[0-9a-f]+")
S_PARSE_RE = re.compile(r"(?:PTR_)?s_(.+?)_ram_([0-9a-f]+)")
DAT_PARSE_RE = re.compile(r"(?:PTR_)?DAT_ram_([0-9a-f]+)")


def scan_strings(image: Path, base: int):
    data = image.read_bytes()
    strings = {}
    for match in PRINTABLE_RE.finditer(data):
        raw = match.group()
        text = raw.decode("ascii", errors="ignore").strip()[:512]
        if len(text) < 4 or not any(ch.isalpha() for ch in text):
            continue
        strings[base + match.start()] = text
    return strings


def escape_comment(text: str) -> str:
    escaped = json.dumps(text, ensure_ascii=True)
    return escaped.replace("*/", "* /")


def string_for_token(token: str, string_map):
    match = S_PARSE_RE.match(token)
    if match:
        return int(match.group(2), 16)
    match = DAT_PARSE_RE.match(token)
    if match:
        return int(match.group(1), 16)
    return None


def annotate(dump: Path, out: Path, string_map):
    refs = Counter()
    with dump.open("r", errors="replace") as source, out.open("w") as target:
        for line in source:
            texts = []
            for token in S_RE.findall(line) + DAT_RE.findall(line):
                address = string_for_token(token, string_map)
                if address is None:
                    continue
                text = string_map.get(address)
                if not text:
                    continue
                refs[address] += 1
                if text not in texts:
                    texts.append(text)
            stripped = line.rstrip("\n")
            if texts and "/* strings:" not in stripped:
                comment = "; ".join(escape_comment(text) for text in texts[:4])
                stripped += f"  /* strings: {comment} */"
            target.write(stripped + "\n")
    return refs


KEY_RE = re.compile(r"^(RM|Rm|NV_?)[A-Za-z0-9_]{3,}$")
SHORT_KEYWORDS = {
    "FECS", "GPCCS", "PMU", "FSP", "FMC", "SEC2", "ACR", "WPR", "FBPA",
    "COT", "MCTP", "NVDM", "DEVINIT", "CTXSW", "HSHUB", "BIF", "LTR",
}


def keep_string(text: str, refs: int) -> bool:
    if refs:
        return True
    if text in SHORT_KEYWORDS:
        return True
    if KEY_RE.match(text):
        return True
    if len(text) >= 8 and ("_" in text or " " in text):
        return True
    return False


def write_outputs(string_map, refs: Counter, csv_path: Path, header_path: Path):
    kept = [(address, text) for address, text in sorted(string_map.items())
            if keep_string(text, refs.get(address, 0))]
    with csv_path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["address", "text", "length", "refs_in_c"])
        for address, text in kept:
            writer.writerow([f"0x{address:08x}", text, len(text), refs.get(address, 0)])

    with header_path.open("w") as handle:
        handle.write("/* Exact GSP-RM strings, address -> text (filtered). */\n")
        handle.write("#ifndef GSP_STRINGS_H\n#define GSP_STRINGS_H\n\n")
        for address, text in kept:
            macro = f"STR_{address:08X}"
            value = json.dumps(text, ensure_ascii=True)
            handle.write(f"#define {macro} {value}\n")
        handle.write("\n#endif\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--base", type=lambda value: int(value, 0), default=0x01000000)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--header", type=Path, required=True)
    args = parser.parse_args()

    string_map = scan_strings(args.image, args.base)
    print(f"strings found: {len(string_map)}")
    refs = annotate(args.dump, args.out, string_map)
    print(f"annotated references: {sum(refs.values())}")
    write_outputs(string_map, refs, args.csv, args.header)
    print(f"output: {args.out}")
    print(f"csv: {args.csv}")
    print(f"header: {args.header}")


if __name__ == "__main__":
    main()
