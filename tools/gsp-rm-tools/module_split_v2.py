#!/usr/bin/env python3
"""Community + evidence module split for the GSP-RM C dump.

Pipeline:
  - parse the (string-annotated) C dump
  - add exact string text from the raw .fwimage
  - seed known modules from registry keys, subsystem strings, MMIO, offsets
  - Louvain communities on the direct-call graph (resolution 3.0)
  - label each community by seed majority, MMIO evidence, or string keywords
  - fill isolated functions by keyword then address locality
  - emit per-module C files, an index, a summary and a BF16 focus report

Run with the project venv (networkx):
  .venv/bin/python -I scripts/module_split_v2.py ...
"""

from __future__ import annotations

import argparse
import bisect
import csv
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import networkx as nx

sys.path.insert(0, str(Path(__file__).resolve().parent))
import module_split as ms  # noqa: E402

PRINTABLE_RE = re.compile(rb"[\x20-\x7e]{4,}")
S_RE = re.compile(r"(?:PTR_)?s_[A-Za-z0-9_]+?_ram_[0-9a-f]+")
DAT_RE = re.compile(r"(?:PTR_)?DAT_ram_[0-9a-f]+")
S_PARSE_RE = re.compile(r"(?:PTR_)?s_(.+?)_ram_([0-9a-f]+)")
DAT_PARSE_RE = re.compile(r"(?:PTR_)?DAT_ram_([0-9a-f]+)")
KEY_RE = re.compile(r"^(RM|Rm|NV_?)[A-Za-z0-9_]{3,}$")
SHORT_KEYWORDS = {
    "FECS", "GPCCS", "PMU", "FSP", "FMC", "SEC2", "ACR", "WPR", "FBPA",
    "COT", "MCTP", "NVDM", "DEVINIT", "CTXSW", "HSHUB", "BIF", "LTR",
}

# Broad keyword classifiers for communities without a specific seed.
KEYWORD_MODULES = [
    ("registry", ("registry", "featuredisablement", "rmoverridesmspeedselect",
                  "rmdisablefeaturedisablement")),
    ("nvlink", ("nvlink",)),
    ("vgpu", ("vgpu", "sr-iov", "sriov")),
    ("display", ("hotplug", "brightness", "hdmi", "hdcp", "display",
                 "frl", "sor", "vrr")),
    ("pcie_bif", ("pcie", "ltr", "bif", "hshub")),
    ("power_clock", ("pmgr", "clock", "power", "therm", "voltage",
                     "elcg", "elpg", "fspg")),
    ("memory_wpr", ("wpr", "fbpa", "page", "mmu", "vas", "sysmem",
                    "vidmem", "pramin", "heap")),
    ("mnoc", ("mnoc",)),
    ("crypto", ("aes", "nvrng", "nvpka", "ccc", "keyop", "nist", "crypto", "rng")),
    ("i2c_gpio", ("i2c", "gpio")),
    ("inforom", ("inforom", "bbx", "prgn")),
    ("fifo", ("fifo", "channel", "runlist", "gpfifo", "tsg", "ctxsw")),
    ("perf", ("perf", "prof", "counter", "hwpm")),
    ("libos", ("libos", "kernel", "task", "rootfs", "memorypool",
               "addressspace", "worker", "mutex", "semaphore", "thread",
               "timer", "event", "queue")),
    ("rm_core", ("alloc", "free", "list", "lock", "obj", "object", "client",
                 "device", "handle", "ref", "state")),
]

FOCUS_MODULES = {"registry", "platform", "feat_rate", "gr_fecs",
                 "pmu_devinit", "fsp_fmc", "memory_wpr"}


def keep_string(text: str, refs: int) -> bool:
    if refs:
        return True
    if text in SHORT_KEYWORDS:
        return True
    if KEY_RE.match(text):
        return True
    return len(text) >= 8 and ("_" in text or " " in text)


def scan_strings(image: Path, base: int):
    data = image.read_bytes()
    strings = {}
    for match in PRINTABLE_RE.finditer(data):
        text = match.group().decode("ascii", errors="ignore").strip()[:512]
        if len(text) < 4 or not any(ch.isalpha() for ch in text):
            continue
        strings[base + match.start()] = text
    return strings


def add_exact_strings(funcs, string_map):
    for func in funcs:
        extra = set()
        for token in S_RE.findall(func["body"]):
            match = S_PARSE_RE.match(token)
            if match:
                text = string_map.get(int(match.group(2), 16))
                if text:
                    extra.add(text)
        for token in DAT_RE.findall(func["body"]):
            match = DAT_PARSE_RE.match(token)
            if match:
                text = string_map.get(int(match.group(1), 16))
                if text and keep_string(text, 0):
                    extra.add(text)
        func["strings"].update(extra)


def keyword_classify(strings):
    scores = Counter()
    for text, count in strings.items():
        lowered = text.lower()
        for module, keywords in KEYWORD_MODULES:
            if any(keyword in lowered for keyword in keywords):
                scores[module] += count
    if not scores:
        return None
    return scores.most_common(1)[0][0]


def build_graph(funcs):
    graph = nx.Graph()
    for func in funcs:
        graph.add_node(func["addr"])
    for func in funcs:
        for callee in func["callees"]:
            if graph.has_edge(func["addr"], callee):
                graph[func["addr"]][callee]["weight"] += 1
            else:
                graph.add_edge(func["addr"], callee, weight=1)
    return graph


def classify_community(community, by_addr, seed_labels, pattern_scores):
    seed_weights = Counter()
    mmio_counts = Counter()
    mmio_nodes = Counter()
    strings = Counter()
    evidence = Counter()
    evidence_nodes = Counter()
    keyword_scores = Counter()
    keyword_nodes = Counter()

    for addr in community:
        label = seed_labels.get(addr)
        if label and label["module"] != "failed":
            seed_weights[label["module"]] += max(1.0, label["score"] / 10.0)
        func = by_addr[addr]
        matched_modules = set()
        for text in func["strings"]:
            strings[text] += 1
            lowered = text.lower()
            for module, keywords in KEYWORD_MODULES:
                if any(keyword in lowered for keyword in keywords):
                    keyword_scores[module] += 1
                    matched_modules.add(module)
        for module in matched_modules:
            keyword_nodes[module] += 1
        seen_mmio = set()
        for value in func["mmio"]:
            hint = ms.mmio_module(value)
            if hint:
                mmio_counts[hint] += 1
                seen_mmio.add(hint)
        for hint in seen_mmio:
            mmio_nodes[hint] += 1
        for module, score in pattern_scores.get(addr, {}).items():
            evidence[module] += min(score, 10.0)
            evidence_nodes[module] += 1

    size = len(community)
    required = max(2, int(size * 0.01))

    if seed_weights:
        module, weight = seed_weights.most_common(1)[0]
        total = sum(seed_weights.values())
        purity = weight / total if total else 1.0
        seed_count = sum(
            1 for addr in community
            if seed_labels.get(addr)
            and seed_labels[addr]["module"] == module
            and seed_labels[addr].get("seed"))
        if (seed_count >= required and purity >= 0.60) or (seed_count >= 1 and size <= 50):
            reason = ("seeds: "
                      + "; ".join(f"{m}({w:.1f})" for m, w in seed_weights.most_common(4)))
            return module, 0.55 + 0.45 * purity, reason, strings, mmio_counts

    if keyword_scores:
        module, score = keyword_scores.most_common(1)[0]
        required_keyword = max(2, int(size * 0.02))
        if keyword_nodes[module] >= required_keyword and score >= 2:
            return (module, 0.38,
                    f"keywords -> {module} ({keyword_nodes[module]} nodes)",
                    strings, mmio_counts)

    if mmio_nodes:
        module, count = mmio_nodes.most_common(1)[0]
        if count >= required and count >= 2:
            return module, 0.35, f"MMIO nodes: {module}({count})", strings, mmio_counts

    if evidence:
        module, weight = evidence.most_common(1)[0]
        if evidence_nodes[module] >= required and weight >= 4.0:
            reason = ("evidence: "
                      + "; ".join(f"{m}({w:.1f})" for m, w in evidence.most_common(4)))
            return module, 0.35, reason, strings, mmio_counts

    return None, 0.0, "no evidence", strings, mmio_counts


def assign(funcs, seed_labels, pattern_scores, resolution, bin_size):
    by_addr = {f["addr"]: f for f in funcs}
    graph = build_graph(funcs)
    communities = nx.community.louvain_communities(
        graph, weight="weight", resolution=resolution, seed=42)
    communities = sorted(communities, key=len, reverse=True)

    labels = {}
    community_info = {}

    for index, community in enumerate(communities):
        module, confidence, reason, strings, mmio_counts = classify_community(
            community, by_addr, seed_labels, pattern_scores)
        if module is None and len(community) >= 20:
            top = strings.most_common(1)
            keyword = re.sub(r"[^A-Za-z0-9]+", "_", top[0][0])[:24] if top else ""
            module = f"community_{index}" + (f"_{keyword}" if keyword else "")
            confidence = 0.20
            reason = "unlabelled community"
        if module is None:
            continue

        community_info[index] = {
            "module": module,
            "size": len(community),
            "reason": reason,
            "top_strings": strings.most_common(6),
            "top_mmio": mmio_counts.most_common(6),
        }

        for addr in community:
            seed = seed_labels.get(addr)
            if seed and seed.get("seed") and seed["module"] != "failed":
                labels[addr] = dict(seed)
                labels[addr]["community"] = index
            else:
                labels[addr] = {
                    "module": module,
                    "score": 0.0,
                    "confidence": confidence,
                    "seed": False,
                    "reason": reason,
                    "community": index,
                }

    # Fill functions not covered by any community (mostly isolated nodes).
    assigned_addrs = sorted(labels)
    for func in funcs:
        addr = func["addr"]
        if addr in labels:
            continue
        if func["status"] == "failed":
            labels[addr] = {
                "module": "failed", "score": 0.0, "confidence": 1.0,
                "seed": True, "reason": "decompilation failed", "community": -1,
            }
            continue

        own_strings = Counter({text: 1 for text in func["strings"]})
        module = keyword_classify(own_strings)
        if module:
            labels[addr] = {
                "module": module, "score": 0.0, "confidence": 0.30,
                "seed": False, "reason": "own keywords", "community": -1,
            }
            continue

        if assigned_addrs:
            position = bisect.bisect_left(assigned_addrs, addr)
            candidates = []
            if position < len(assigned_addrs):
                candidates.append(assigned_addrs[position])
            if position > 0:
                candidates.append(assigned_addrs[position - 1])
            nearest = min(candidates, key=lambda value: abs(value - addr))
            if abs(nearest - addr) <= 0x40000:
                nearest_label = labels[nearest]
                labels[addr] = {
                    "module": nearest_label["module"], "score": 0.0,
                    "confidence": 0.20, "seed": False,
                    "reason": f"address locality from 0x{nearest:08x}",
                    "community": -1,
                }
                continue

        bin_name = f"misc_0x{addr & ~(bin_size - 1):08x}"
        labels[addr] = {
            "module": bin_name, "score": 0.0, "confidence": 0.10,
            "seed": False, "reason": "isolated / no evidence", "community": -1,
        }

    return labels, community_info


def safe_name(module: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", module)


def write_outputs(funcs, labels, community_info, outdir: Path):
    outdir.mkdir(parents=True, exist_ok=True)
    grouped = defaultdict(list)
    for func in funcs:
        grouped[labels[func["addr"]]["module"]].append(func)

    known_order = [
        "registry", "platform", "feat_rate", "gr_fecs", "pmu_devinit",
        "fsp_fmc", "sec2_acr", "memory_wpr", "rpc_dispatch", "display",
        "pcie_bif", "power_clock", "gsp_core", "nvlink", "vgpu",
        "logging_debug", "mnoc", "libos", "crypto", "i2c_gpio",
        "inforom", "fifo", "perf", "rm_core",
    ]
    dynamic = sorted(
        (module for module in grouped if module not in known_order
         and module not in ("unclassified", "failed")),
        key=lambda module: (-len(grouped[module]), module))
    order = [module for module in known_order if module in grouped]
    order += dynamic
    if "failed" in grouped:
        order.append("failed")

    summary_rows = []
    for module in order:
        items = sorted(grouped[module], key=lambda f: f["addr"])
        if not items:
            continue
        strings = Counter()
        mmio = Counter()
        for func in items:
            for text in func["strings"]:
                if len(text) >= 6:
                    strings[text] += 1
            for value in func["mmio"]:
                hint = ms.mmio_module(value)
                if hint:
                    mmio[f"0x{value:x}"] += 1
        path = outdir / f"mod_{safe_name(module)}.c"
        with path.open("w") as handle:
            handle.write(f"/* ===== Module: {module} =====\n")
            handle.write(f" * Functions: {len(items)}\n")
            handle.write(f" * Address range: 0x{items[0]['addr']:08x} - 0x{items[-1]['addr']:08x}\n")
            handle.write(" * Top strings: " + "; ".join(
                f"{s} ({n})" for s, n in strings.most_common(4)) + "\n")
            handle.write(" */\n\n")
            for func in items:
                handle.write(f"/* ==== ram:{func['addr']:08x}  {func['name']}  "
                             f"size=0x{func['size']:x} ==== */\n")
                handle.write(func["body"].strip("\n"))
                handle.write("\n\n")
        summary_rows.append({
            "module": module,
            "functions": len(items),
            "first": items[0]["addr"],
            "last": items[-1]["addr"],
            "strings": "; ".join(f"{s} ({n})" for s, n in strings.most_common(4)),
            "mmio": "; ".join(f"{s} ({n})" for s, n in mmio.most_common(4)),
        })

    with (outdir / "module_index.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["address", "name", "module", "community", "confidence",
                         "seed", "reason", "size", "status", "strings", "mmio"])
        for func in funcs:
            label = labels[func["addr"]]
            writer.writerow([
                f"0x{func['addr']:08x}", func["name"], label["module"],
                label.get("community", -1), f"{label['confidence']:.3f}",
                int(label.get("seed", False)), label["reason"],
                f"0x{func['size']:x}", func["status"],
                len(func["strings"]), len(func["mmio"]),
            ])

    with (outdir / "modules.md").open("w") as handle:
        handle.write("# GSP-RM module split (community + evidence)\n\n")
        handle.write(f"Functions: {len(funcs)}  \nCommunities: {len(community_info)}\n\n")
        handle.write("| Module | Functions | Address range | Top strings | Top MMIO |\n")
        handle.write("|---|---:|---|---|---|\n")
        for row in summary_rows:
            handle.write(
                f"| {row['module']} | {row['functions']} | "
                f"0x{row['first']:08x}–0x{row['last']:08x} | "
                f"{row['strings']} | {row['mmio']} |\n")

    focus = []
    for func in funcs:
        label = labels[func["addr"]]
        relevant_mmio = [v for v in func["mmio"]
                         if ms.mmio_module(v) in ("feat_rate", "registry", "gr_fecs",
                                                  "memory_wpr", "sec2_acr")]
        relevant_strings = [s for s in func["strings"]
                            if re.search(r"SpeedSelect|FEAT_OVR|FUSE_SS|ISSUE_RATE|"
                                         r"FMLA32|IMLA|RMOverride|FeatureDisablement|"
                                         r"is_geforce|FECS|GPCCS|PMU|DEVINIT|WPR",
                                         s, re.IGNORECASE)]
        if not relevant_mmio and not relevant_strings:
            continue
        if label["module"] not in FOCUS_MODULES and not label["seed"]:
            continue
        focus.append((func, label, relevant_mmio, relevant_strings))
    focus.sort(key=lambda item: (-item[1]["confidence"], item[0]["addr"]))
    with (outdir / "focus_bf16.md").open("w") as handle:
        handle.write("# BF16 / rate-control focus\n\n")
        handle.write("| Address | Module | Confidence | Evidence | Function |\n")
        handle.write("|---|---|---:|---|---|\n")
        for func, label, relevant_mmio, relevant_strings in focus[:160]:
            evidence = [f"0x{v:x}" for v in relevant_mmio[:4]] + relevant_strings[:3]
            handle.write(
                f"| 0x{func['addr']:08x} | {label['module']} | "
                f"{label['confidence']:.2f} | {'; '.join(dict.fromkeys(evidence))} | "
                f"{func['name']} |\n")

    return summary_rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--outdir", type=Path, required=True)
    parser.add_argument("--base", type=lambda value: int(value, 0), default=0x01000000)
    parser.add_argument("--resolution", type=float, default=3.0)
    parser.add_argument("--bin-size", type=lambda value: int(value, 0), default=0x400000)
    args = parser.parse_args()

    funcs = ms.parse_dump(args.input)
    print(f"parsed functions: {len(funcs)}")
    ms.extract_features(funcs)
    string_map = scan_strings(args.image, args.base)
    print(f"strings indexed: {len(string_map)}")
    add_exact_strings(funcs, string_map)

    seed_labels, pattern_scores, _ = ms.seed_modules(funcs, 5.0)
    print(f"seeds: {len(seed_labels)}")

    labels, community_info = assign(
        funcs, seed_labels, pattern_scores, args.resolution, args.bin_size)
    print(f"assigned: {len(labels)} / {len(funcs)}")

    rows = write_outputs(funcs, labels, community_info, args.outdir)
    print(f"output: {args.outdir}")
    for row in rows[:40]:
        print(f"  {row['module']:32s} {row['functions']:6d}  "
              f"0x{row['first']:08x}-0x{row['last']:08x}")


if __name__ == "__main__":
    main()
