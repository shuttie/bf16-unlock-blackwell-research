#!/usr/bin/env python3
"""Diagnostic: Louvain communities of the GSP-RM call graph."""

from __future__ import annotations

import argparse
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

import networkx as nx

sys.path.insert(0, str(Path(__file__).resolve().parent))
import module_split as ms  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump", type=Path,
                    default=Path(os.environ.get("DECOMPILED", "gsp_decompiled.c")))
    args = ap.parse_args()
    funcs = ms.parse_dump(args.dump)
    ms.extract_features(funcs)
    labels, pattern_scores, _ = ms.seed_modules(funcs, 5.0)
    by_addr = {f["addr"]: f for f in funcs}

    graph = nx.Graph()
    for func in funcs:
        graph.add_node(func["addr"])
    for func in funcs:
        for callee in func["callees"]:
            if graph.has_edge(func["addr"], callee):
                graph[func["addr"]][callee]["weight"] += 1
            else:
                graph.add_edge(func["addr"], callee, weight=1)

    print(f"nodes={graph.number_of_nodes()} edges={graph.number_of_edges()}")
    print(f"seeds={len(labels)}")

    communities = nx.community.louvain_communities(
        graph, weight="weight", resolution=1.0, seed=42)
    communities = sorted(communities, key=len, reverse=True)
    print(f"communities={len(communities)}")

    sizes = [len(c) for c in communities]
    print("top sizes:", sizes[:25])
    print("singletons:", sum(1 for s in sizes if s == 1))

    for index, community in enumerate(communities[:20]):
        seed_counts = Counter()
        for addr in community:
            label = labels.get(addr)
            if label and label["seed"] and label["module"] != "failed":
                seed_counts[label["module"]] += 1
        strings = Counter()
        mmio = Counter()
        for addr in community:
            func = by_addr[addr]
            for text in func["strings"]:
                if len(text) >= 8:
                    strings[text] += 1
            for value in func["mmio"]:
                hint = ms.mmio_module(value)
                if hint:
                    mmio[f"0x{value:x}"] += 1
        print(f"\ncommunity {index}: size={len(community)} seeds={dict(seed_counts)}")
        print("  strings:", "; ".join(f"{s}({n})" for s, n in strings.most_common(8)))
        print("  mmio:", "; ".join(f"{s}({n})" for s, n in mmio.most_common(5)))


if __name__ == "__main__":
    main()
