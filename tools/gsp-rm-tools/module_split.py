#!/usr/bin/env python3
"""Split a Ghidra C dump into functional modules.

Pipeline:
  1. Parse address-tagged function blocks, sort by address.
  2. Extract strings, MMIO constants, known struct offsets and direct calls.
  3. Seed modules from registry keys, subsystem strings, MMIO and offsets.
  4. Propagate labels through the call graph with string/MMIO/locality support.
  5. Detect shared utilities and emit per-module files, an index and a summary.

Usage:
  python3 module_split.py --input ../out/gsp_decompiled.c --outdir ../out/modules
"""

from __future__ import annotations

import argparse
import csv
import re
from collections import Counter, defaultdict
from pathlib import Path

HEADER_RE = re.compile(r"^/\* ==== (ram:[0-9a-f]+)\s+(\S+)\s+size=0x([0-9a-f]+) ==== \*/$")
STRING_RE = re.compile(r"(?:PTR_)?s_[A-Za-z0-9_]+?_ram_[0-9a-f]+")
CALL_RE = re.compile(r"\b((?:thunk_)?FUN_ram_[0-9a-f]+)\s*\(")
HEX_RE = re.compile(r"\b0x([0-9a-fA-F]{6,8})\b")
OFFSET_RE = re.compile(r"\+\s*0x([0-9a-fA-F]{3,5})\b")

# Known GSP config offsets from the public rtx-p2p / cmp170hx work.
KNOWN_OFFSETS = {
    0x4DD2: "platform",
    0x4DD3: "platform",
    0x4DD4: "platform",  # is_geforce
    0x4DD5: "platform",
    0x4DD7: "platform",
    0x4EAC: "platform",  # emulation_quadro
    0x50FC: "registry",  # feature-disable bitmask 0-7
    0x5100: "registry",  # feature-disable bitmask 8-9
    0x53CA: "registry",  # RMDisableFeatureDisablement
    0x54D3: "platform",  # selfhost override set
    0x54D4: "platform",  # selfhost override
}

# Module seed rules: (module, compiled regex, weight, label)
RULES = [
    ("registry", re.compile(r"RMDisableFeatureDisablement"), 12, "RMDisableFeatureDisablement"),
    ("registry", re.compile(r"RMOverrideSmSpeedSelect"), 12, "RMOverrideSmSpeedSelect"),
    ("registry", re.compile(r"FeatureDisablement"), 8, "FeatureDisablement"),
    ("registry", re.compile(r"Registry"), 4, "Registry"),
    ("registry", re.compile(r"^RM[A-Za-z0-9_]+$"), 1, "RM* registry key"),
    ("display", re.compile(r"RMHotPlug|RMBrightness|RMHdmi|RMHdcp|RMVrr|RMFrl|RMSor|RMImp"), 6, "display registry key"),
    ("pcie_bif", re.compile(r"RMPcie|RMLTR|RMBif|RMBar|RMHshub"), 6, "PCIe registry key"),
    ("power_clock", re.compile(r"RMPower|RMClock|RMElcg|RMElpg|RMFspg|RMBlcg|RMPmgr|RMTherm"), 4, "power registry key"),
    ("nvlink", re.compile(r"RMNvLink|NvLink|NVLink"), 6, "NvLink"),
    ("memory_wpr", re.compile(r"RMWpr|RMFbpa"), 6, "memory registry key"),
    ("vgpu", re.compile(r"RMVgpu|RMSriov|RMVGPU"), 6, "vGPU registry key"),
    ("sec2_acr", re.compile(r"RMSec2|RMFwsec"), 4, "SEC2 registry key"),
    ("gsp_core", re.compile(r"RMGsp"), 4, "GSP registry key"),
    ("platform", re.compile(r"is_geforce"), 12, "is_geforce"),
    ("platform", re.compile(r"GeForce"), 8, "GeForce"),
    ("platform", re.compile(r"Quadro"), 6, "Quadro"),
    ("platform", re.compile(r"RmEmulationQuadro"), 10, "RmEmulationQuadro"),
    ("platform", re.compile(r"RmOverrideSelfHostedMode"), 10, "RmOverrideSelfHostedMode"),
    ("platform", re.compile(r"[Pp]latform"), 3, "platform"),
    ("gr_fecs", re.compile(r"FECS"), 6, "FECS"),
    ("gr_fecs", re.compile(r"GPCCS"), 6, "GPCCS"),
    ("gr_fecs", re.compile(r"CTXSW|CTX_SW"), 6, "CTXSW"),
    ("gr_fecs", re.compile(r"GR_GLOBALCTX_BUFFER"), 8, "GR_GLOBALCTX_BUFFER"),
    ("gr_fecs", re.compile(r"GR_CTX_BUFFER"), 5, "GR_CTX_BUFFER"),
    ("gr_fecs", re.compile(r"GrCtxSwMode"), 10, "GrCtxSwMode"),
    ("gr_fecs", re.compile(r"GPCCLIENT"), 6, "GPCCLIENT"),
    ("gr_fecs", re.compile(r"GRAPHICS|Graphics"), 2, "Graphics"),
    ("pmu_devinit", re.compile(r"PMU"), 5, "PMU"),
    ("pmu_devinit", re.compile(r"Pmu"), 5, "Pmu"),
    ("pmu_devinit", re.compile(r"DEVINIT"), 4, "DEVINIT"),
    ("pmu_devinit", re.compile(r"NV_DEVINIT"), 4, "NV_DEVINIT"),
    ("pmu_devinit", re.compile(r"PMGR"), 6, "PMGR"),
    ("pmu_devinit", re.compile(r"PSTATE"), 5, "PSTATE"),
    ("pmu_devinit", re.compile(r"Clock|clock"), 2, "clock"),
    ("pmu_devinit", re.compile(r"Therm|therm"), 3, "thermal"),
    ("pmu_devinit", re.compile(r"Voltage|voltage"), 3, "voltage"),
    ("fsp_fmc", re.compile(r"FSP|Fsp"), 6, "FSP"),
    ("fsp_fmc", re.compile(r"FMC|Fmc"), 6, "FMC"),
    ("fsp_fmc", re.compile(r"GSP_FMC|GSP-FMC"), 10, "GSP_FMC"),
    ("fsp_fmc", re.compile(r"Chain.of.trust"), 12, "Chain-of-trust"),
    ("fsp_fmc", re.compile(r"(?:^|_)COT(?:_|$)"), 6, "COT"),
    ("fsp_fmc", re.compile(r"NVDM"), 6, "NVDM"),
    ("fsp_fmc", re.compile(r"MCTP"), 6, "MCTP"),
    ("sec2_acr", re.compile(r"SEC2|Sec2"), 4, "SEC2"),
    ("sec2_acr", re.compile(r"ACR"), 4, "ACR"),
    ("sec2_acr", re.compile(r"(?:^|_)FWSEC(?:_|$)"), 4, "FWSEC"),
    ("sec2_acr", re.compile(r"FRTS"), 4, "FRTS"),
    ("sec2_acr", re.compile(r"SecureScrub|secure scrub"), 6, "secure scrub"),
    ("sec2_acr", re.compile(r"SEC_FAULT"), 4, "SEC_FAULT"),
    ("memory_wpr", re.compile(r"WPR2"), 8, "WPR2"),
    ("memory_wpr", re.compile(r"WPR"), 4, "WPR"),
    ("memory_wpr", re.compile(r"FBPA"), 8, "FBPA"),
    ("memory_wpr", re.compile(r"Heap|heap"), 2, "heap"),
    ("memory_wpr", re.compile(r"MMU|Mmu"), 3, "MMU"),
    ("memory_wpr", re.compile(r"Scrub|scrub"), 3, "scrub"),
    ("memory_wpr", re.compile(r"sysmem|vidmem"), 2, "sysmem/vidmem"),
    ("feat_rate", re.compile(r"SPEED_SELECT|SpeedSelect"), 10, "SpeedSelect"),
    ("feat_rate", re.compile(r"FEAT_OVR"), 10, "FEAT_OVR"),
    ("feat_rate", re.compile(r"FUSE_SS"), 10, "FUSE_SS"),
    ("feat_rate", re.compile(r"ISSUE_RATE|IssueRate"), 10, "ISSUE_RATE"),
    ("feat_rate", re.compile(r"SM_ISSUE"), 10, "SM_ISSUE"),
    ("feat_rate", re.compile(r"FMLA32"), 8, "FMLA32"),
    ("feat_rate", re.compile(r"IMLA"), 4, "IMLA"),
    ("rpc_dispatch", re.compile(r"NV2080_CTRL"), 6, "NV2080_CTRL"),
    ("rpc_dispatch", re.compile(r"NV0000"), 4, "NV0000"),
    ("rpc_dispatch", re.compile(r"CTRL_CMD"), 4, "CTRL_CMD"),
    ("rpc_dispatch", re.compile(r"\bRPC\b|Rpc"), 3, "RPC"),
    ("rpc_dispatch", re.compile(r"Dispatch|dispatch"), 3, "dispatch"),
    ("display", re.compile(r"DISPLAY|Display"), 4, "DISPLAY"),
    ("display", re.compile(r"HDMI"), 5, "HDMI"),
    ("display", re.compile(r"(?:^|_)IMP(?:_|$)"), 4, "IMP"),
    ("display", re.compile(r"\bdisp|Disp"), 2, "disp"),
    ("pcie_bif", re.compile(r"BIF|Bif"), 5, "BIF"),
    ("pcie_bif", re.compile(r"LTR"), 5, "LTR"),
    ("pcie_bif", re.compile(r"HSHUB"), 8, "HSHUB"),
    ("pcie_bif", re.compile(r"PCIe|Pcie"), 4, "PCIe"),
    ("power_clock", re.compile(r"PMGR"), 6, "PMGR"),
    ("power_clock", re.compile(r"PSTATE"), 5, "PSTATE"),
    ("power_clock", re.compile(r"Clock|clock"), 3, "clock"),
    ("power_clock", re.compile(r"Therm|therm"), 3, "thermal"),
    ("power_clock", re.compile(r"Voltage|voltage"), 3, "voltage"),
    ("power_clock", re.compile(r"Power|power"), 2, "power"),
    ("gsp_core", re.compile(r"GSP|Gsp"), 1, "GSP"),
    ("gsp_core", re.compile(r"GSP_FALCON|GSP_RM|GspRm|GSP_PMU|GSP_BOOT|GSP_PLUGIN"), 5, "GSP core"),
    ("logging_debug", re.compile(r"NVRM"), 3, "NVRM"),
    ("logging_debug", re.compile(r"NV_[A-Z0-9_]*ERR"), 1, "NV error enum"),
    ("logging_debug", re.compile(r"Assert|assert"), 2, "assert"),
    ("logging_debug", re.compile(r"Panic|panic"), 3, "panic"),
    ("logging_debug", re.compile(r"Dump|dump"), 2, "dump"),
    ("logging_debug", re.compile(r"Debug|debug"), 2, "debug"),
    ("logging_debug", re.compile(r"Log|log"), 1, "log"),
]

MODULES = [
    "registry", "platform", "gr_fecs", "pmu_devinit", "fsp_fmc", "sec2_acr",
    "memory_wpr", "feat_rate", "rpc_dispatch", "display", "pcie_bif",
    "power_clock", "gsp_core", "nvlink", "vgpu", "logging_debug",
    "shared_util", "unclassified",
]
MODULE_PRIORITY = {module: index for index, module in enumerate(MODULES)}

SINK_MODULES = {"logging_debug", "shared_util"}


def parse_dump(path: Path):
    funcs = []
    current = None
    with path.open("r", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip()
            match = HEADER_RE.match(line)
            if match:
                if current is not None:
                    funcs.append(current)
                current = {
                    "addr": int(match.group(1).split(":")[1], 16),
                    "name": match.group(2),
                    "size": int(match.group(3), 16),
                    "body": [],
                }
            elif current is not None:
                current["body"].append(raw)
    if current is not None:
        funcs.append(current)

    for func in funcs:
        body = "".join(func["body"])
        func["body"] = body
        func["status"] = "failed" if "// decompilation failed" in body else "ok"
    funcs.sort(key=lambda f: f["addr"])
    return funcs


def extract_features(funcs):
    name_to_addr = {f["name"]: f["addr"] for f in funcs}
    unresolved_calls = 0

    for func in funcs:
        body = func["body"]

        strings = set()
        for token in STRING_RE.findall(body):
            if token.startswith("PTR_"):
                token = token[4:]
            if not token.startswith("s_"):
                continue
            token = token[2:]
            if "_ram_" not in token:
                continue
            text, _ = token.rsplit("_ram_", 1)
            strings.add(text)
        func["strings"] = strings

        mmio = set()
        for token in HEX_RE.findall(body):
            try:
                value = int(token, 16)
            except ValueError:
                continue
            if 0x100000 <= value <= 0x4FFFFFF and (value & 0xFFFF) != 0:
                mmio.add(value)
        func["mmio"] = mmio

        offsets = set()
        for token in OFFSET_RE.findall(body):
            value = int(token, 16)
            if value in KNOWN_OFFSETS:
                offsets.add(value)
        func["offsets"] = offsets

        callees = set()
        for name in CALL_RE.findall(body):
            if name.startswith("thunk_"):
                name = name[6:]
            target = name_to_addr.get(name)
            if target is None:
                unresolved_calls += 1
                continue
            if target != func["addr"]:
                callees.add(target)
        func["callees"] = callees

    callers = defaultdict(set)
    for func in funcs:
        for target in func["callees"]:
            callers[target].add(func["addr"])
    for func in funcs:
        func["callers"] = callers.get(func["addr"], set())

    return unresolved_calls


def mmio_module(value: int):
    if 0x823800 <= value <= 0x8238FF:
        return "feat_rate"
    if 0x820000 <= value <= 0x823FFF:
        return "registry"
    if 0x840000 <= value <= 0x841FFF:
        return "sec2_acr"
    if 0x1FA700 <= value <= 0x1FA7FF:
        return "memory_wpr"
    if 0x409000 <= value <= 0x409FFF:
        return "gr_fecs"
    if 0x504000 <= value <= 0x504FFF:
        return "gr_fecs"
    if 0x9A0000 <= value <= 0x9A0FFF:
        return "memory_wpr"
    return None


def score_function(func):
    string_scores = defaultdict(float)
    mmio_scores = defaultdict(float)
    offset_scores = defaultdict(float)
    reasons = defaultdict(list)

    for text in func["strings"]:
        for module, rule, weight, label in RULES:
            if rule.search(text):
                string_scores[module] += weight
                if len(reasons[module]) < 4:
                    reasons[module].append(label)

    for module in list(string_scores):
        string_scores[module] = min(string_scores[module], 30.0)

    mmio_count = defaultdict(int)
    for value in func["mmio"]:
        module = mmio_module(value)
        if module:
            mmio_count[module] += 1
            if len(reasons[module]) < 4:
                reasons[module].append(f"MMIO 0x{value:x}")
    for module, count in mmio_count.items():
        mmio_scores[module] = min(12.0, 4.0 * count)

    for offset in func["offsets"]:
        module = KNOWN_OFFSETS[offset]
        offset_scores[module] += 3.0
        if len(reasons[module]) < 4:
            reasons[module].append(f"offset 0x{offset:x}")

    scores = defaultdict(float)
    for module in set(string_scores) | set(mmio_scores) | set(offset_scores):
        scores[module] = string_scores[module] + mmio_scores[module] + offset_scores[module]

    return scores, string_scores, mmio_scores, offset_scores, reasons


def seed_modules(funcs, seed_threshold):
    labels = {}
    pattern_scores = {}
    pattern_reasons = {}

    mmio_seed_modules = {"feat_rate", "gr_fecs", "sec2_acr", "memory_wpr"}

    for func in funcs:
        scores, string_scores, mmio_scores, offset_scores, reasons = score_function(func)
        pattern_scores[func["addr"]] = scores
        pattern_reasons[func["addr"]] = reasons

        if func["status"] == "failed":
            labels[func["addr"]] = {
                "module": "failed",
                "score": 0.0,
                "confidence": 1.0,
                "seed": True,
                "reason": "decompilation failed",
            }
            continue

        if not scores:
            continue

        forced = None
        for text in func["strings"]:
            if re.search(r"RMDisableFeatureDisablement|RMOverrideSmSpeedSelect|"
                         r"FeatureDisablement", text):
                forced = "registry"
                break

        if forced:
            best = forced
            scores[best] = max(scores.get(best, 0.0), seed_threshold)
            reasons[best].insert(0, "registry parser anchor")
            string_ok = True
            mmio_ok = False
            offset_ok = False
        else:
            best = max(scores, key=lambda module: (
                scores[module], -MODULE_PRIORITY.get(module, len(MODULES))))
            string_ok = string_scores.get(best, 0.0) >= 5.0
            mmio_ok = (mmio_scores.get(best, 0.0) >= 8.0 and best in mmio_seed_modules)
            offset_ok = offset_scores.get(best, 0.0) >= 6.0

        if scores[best] >= seed_threshold and (string_ok or mmio_ok or offset_ok):
            labels[func["addr"]] = {
                "module": best,
                "score": scores[best],
                "confidence": min(1.0, scores[best] / 25.0),
                "seed": True,
                "reason": "; ".join(dict.fromkeys(reasons[best][:4])),
            }

    return labels, pattern_scores, pattern_reasons


def propagate(funcs, labels, pattern_scores, iterations, bin_size):
    by_addr = {f["addr"]: f for f in funcs}
    bin_counts = defaultdict(Counter)
    for addr, label in labels.items():
        if label["module"] not in ("failed", "unclassified"):
            bin_counts[addr // bin_size][label["module"]] += 1

    for iteration in range(iterations):
        changed = 0
        for func in funcs:
            addr = func["addr"]
            if addr in labels or func["status"] == "failed":
                continue

            scores = defaultdict(float)

            for callee in func["callees"]:
                label = labels.get(callee)
                if label and label["module"] not in ("failed", "unclassified"):
                    scores[label["module"]] += 1.0
            for caller in func["callers"]:
                label = labels.get(caller)
                if label and label["module"] not in ("failed", "unclassified"):
                    scores[label["module"]] += 0.25

            for module, score in pattern_scores.get(addr, {}).items():
                scores[module] += min(score, 12.0) * 0.30

            mmio_local = defaultdict(int)
            for value in func["mmio"]:
                module = mmio_module(value)
                if module:
                    mmio_local[module] += 1
            for module, count in mmio_local.items():
                scores[module] += min(2.0, 0.5 * count)

            for offset in func["offsets"]:
                scores[KNOWN_OFFSETS[offset]] += 1.0

            current_bin = addr // bin_size
            locality = Counter()
            for nearby in range(current_bin - 1, current_bin + 2):
                locality.update(bin_counts.get(nearby, {}))
            total_local = sum(locality.values())
            if total_local:
                for module, count in locality.items():
                    scores[module] += 1.5 * count / total_local

            for module in SINK_MODULES:
                if module in scores:
                    scores[module] *= 0.5

            if not scores:
                continue

            ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
            best_module, best_score = ranked[0]
            second_score = ranked[1][1] if len(ranked) > 1 else 0.0
            if best_score >= 3.0 and best_score - second_score >= 1.0:
                labels[addr] = {
                    "module": best_module,
                    "score": best_score,
                    "confidence": min(1.0, best_score / 10.0),
                    "seed": False,
                    "reason": "propagated",
                }
                if best_module not in ("failed", "unclassified"):
                    bin_counts[current_bin][best_module] += 1
                changed += 1

        if changed == 0:
            break

    return labels


def mark_shared(funcs, labels):
    by_addr = {f["addr"]: f for f in funcs}
    for func in funcs:
        addr = func["addr"]
        label = labels.get(addr)
        if not label or label["seed"] or label["module"] in ("failed", "unclassified"):
            continue
        caller_modules = Counter()
        for caller in func["callers"]:
            caller_label = labels.get(caller)
            if caller_label and caller_label["module"] not in ("failed", "unclassified"):
                caller_modules[caller_label["module"]] += 1
        total = sum(caller_modules.values())
        if total >= 15:
            top_share = caller_modules.most_common(1)[0][1] / total
            if len(caller_modules) >= 4 and top_share < 0.55:
                label["module"] = "shared_util"
                label["reason"] = "shared across modules"
                continue
        if (len(func["strings"]) == 0 and not func["mmio"] and not func["offsets"]
                and func["size"] <= 0x40 and len(func["callers"]) >= 10):
            label["module"] = "shared_util"
            label["reason"] = "small hot utility"


def locality_fallback(funcs, labels, bin_size):
    bin_counts = defaultdict(Counter)
    for func in funcs:
        label = labels.get(func["addr"])
        if label and label["module"] not in ("failed", "unclassified", "shared_util"):
            bin_counts[func["addr"] // bin_size][label["module"]] += 1

    for func in funcs:
        addr = func["addr"]
        if addr in labels or func["status"] == "failed":
            continue
        counts = bin_counts.get(addr // bin_size)
        if not counts:
            continue
        total = sum(counts.values())
        module, count = counts.most_common(1)[0]
        if total >= 3 and count / total >= 0.75:
            labels[addr] = {
                "module": module,
                "score": 0.0,
                "confidence": 0.35,
                "seed": False,
                "reason": "address locality",
            }


def write_outputs(funcs, labels, outdir: Path, unresolved_calls):
    outdir.mkdir(parents=True, exist_ok=True)
    by_addr = {f["addr"]: f for f in funcs}

    for func in funcs:
        if func["addr"] not in labels:
            labels[func["addr"]] = {
                "module": "unclassified",
                "score": 0.0,
                "confidence": 0.0,
                "seed": False,
                "reason": "no evidence",
            }

    grouped = defaultdict(list)
    for func in funcs:
        grouped[labels[func["addr"]]["module"]].append(func)

    order = MODULES + ["failed"]
    if "failed" not in order:
        order.append("failed")

    summary_rows = []
    for module in order:
        items = sorted(grouped.get(module, []), key=lambda f: f["addr"])
        if not items:
            continue
        path = outdir / f"mod_{module}.c"
        reasons = Counter()
        mmio = Counter()
        for func in items:
            label = labels[func["addr"]]
            if label["seed"] and label["reason"]:
                reasons[label["reason"]] += 1
            for value in func["mmio"]:
                hint = mmio_module(value)
                if hint == module:
                    mmio[f"0x{value:x}"] += 1
        with path.open("w") as handle:
            handle.write(f"/* ===== Module: {module} =====\n")
            handle.write(f" * Functions: {len(items)}\n")
            handle.write(f" * Address range: 0x{items[0]['addr']:08x} - 0x{items[-1]['addr']:08x}\n")
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
            "top_reasons": "; ".join(f"{k} ({v})" for k, v in reasons.most_common(5)),
            "top_mmio": "; ".join(f"{k} ({v})" for k, v in mmio.most_common(5)),
        })

    with (outdir / "module_index.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["address", "name", "module", "confidence", "score",
                         "seed", "reason", "size", "status", "strings", "mmio"])
        for func in funcs:
            label = labels[func["addr"]]
            writer.writerow([
                f"0x{func['addr']:08x}",
                func["name"],
                label["module"],
                f"{label['confidence']:.3f}",
                f"{label['score']:.2f}",
                int(label["seed"]),
                label["reason"],
                f"0x{func['size']:x}",
                func["status"],
                len(func["strings"]),
                len(func["mmio"]),
            ])

    edges = Counter()
    for func in funcs:
        source = labels[func["addr"]]["module"]
        for callee in func["callees"]:
            target = labels[callee]["module"]
            if source in ("failed", "unclassified") or target in ("failed", "unclassified"):
                continue
            edges[(source, target)] += 1

    with (outdir / "modules.md").open("w") as handle:
        handle.write("# GSP-RM module split\n\n")
        handle.write(f"Functions: {len(funcs)}  \n")
        handle.write(f"Unresolved direct calls: {unresolved_calls}\n\n")
        handle.write("| Module | Functions | Address range | Top seed reasons | Top MMIO |\n")
        handle.write("|---|---:|---|---|---|\n")
        for row in summary_rows:
            handle.write(
                f"| {row['module']} | {row['functions']} | "
                f"0x{row['first']:08x}–0x{row['last']:08x} | "
                f"{row['top_reasons']} | {row['top_mmio']} |\n"
            )
        handle.write("\n## Top cross-module call edges\n\n")
        handle.write("| From | To | Calls |\n|---|---|---:|\n")
        for (source, target), count in edges.most_common(40):
            handle.write(f"| {source} | {target} | {count} |\n")

    # Focus report for the BF16 / rate-control chain.
    focus_modules = {"registry", "platform", "feat_rate", "gr_fecs", "pmu_devinit", "fsp_fmc"}
    focus_values = []
    for func in funcs:
        label = labels[func["addr"]]
        if label["module"] not in focus_modules:
            continue
        relevant_mmio = [
            value for value in func["mmio"]
            if mmio_module(value) in ("feat_rate", "registry", "gr_fecs", "memory_wpr", "pcie_bif")
        ]
        relevant_strings = [
            text for text in func["strings"]
            if re.search(r"SpeedSelect|FEAT_OVR|FUSE_SS|ISSUE_RATE|FMLA32|IMLA|"
                         r"RMOverride|FeatureDisablement|is_geforce|FECS|GPCCS|PMU|DEVINIT",
                         text, re.IGNORECASE)
        ]
        if not relevant_mmio and not relevant_strings and label["score"] < 5.0:
            continue
        focus_values.append((func, label, relevant_mmio, relevant_strings))

    focus_values.sort(key=lambda item: (-item[1]["score"], item[0]["addr"]))
    with (outdir / "focus_bf16.md").open("w") as handle:
        handle.write("# BF16 / rate-control focus\n\n")
        handle.write("Functions in the registry/platform/GR/FECS/PMU/FSP modules that touch "
                     "rate, fuse, platform or feature evidence, or are strong seeds.\n\n")
        handle.write("| Address | Module | Score | Evidence | Function |\n")
        handle.write("|---|---|---:|---|---|\n")
        for func, label, relevant_mmio, relevant_strings in focus_values[:120]:
            evidence = []
            evidence.extend(f"0x{value:x}" for value in relevant_mmio[:4])
            evidence.extend(relevant_strings[:3])
            handle.write(
                f"| 0x{func['addr']:08x} | {label['module']} | {label['score']:.1f} | "
                f"{'; '.join(dict.fromkeys(evidence))} | {func['name']} |\n"
            )

    return summary_rows, edges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("../out/gsp_decompiled.c"))
    parser.add_argument("--outdir", type=Path, default=Path("../out/modules"))
    parser.add_argument("--seed-threshold", type=float, default=5.0)
    parser.add_argument("--iterations", type=int, default=8)
    parser.add_argument("--bin-size", type=int, default=0x2000)
    args = parser.parse_args()

    funcs = parse_dump(args.input)
    print(f"parsed functions: {len(funcs)}")
    failed = sum(1 for f in funcs if f["status"] == "failed")
    print(f"failed decompilations: {failed}")

    unresolved = extract_features(funcs)
    print(f"unresolved direct calls: {unresolved}")

    labels, pattern_scores, pattern_reasons = seed_modules(funcs, args.seed_threshold)
    print(f"seeded functions: {len(labels)}")

    labels = propagate(funcs, labels, pattern_scores, args.iterations, args.bin_size)
    assigned_after_propagation = sum(1 for f in funcs if f["addr"] in labels)
    print(f"assigned after propagation: {assigned_after_propagation}")

    mark_shared(funcs, labels)
    locality_fallback(funcs, labels, args.bin_size)

    summary, edges = write_outputs(funcs, labels, args.outdir, unresolved)
    print(f"output: {args.outdir}")
    for row in summary:
        print(f"  {row['module']:15s} {row['functions']:6d}  "
              f"0x{row['first']:08x}-0x{row['last']:08x}")


if __name__ == "__main__":
    main()
