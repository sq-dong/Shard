#!/usr/bin/env python3
"""Plot Shard paper-style figures from results.csv (VLDB'25 / Shard eval)."""
from __future__ import annotations

import argparse
import csv
import json
import os
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np

# All series in blue (user request); hatch still distinguishes multi-system bars.
COLORS = {
    "shard": "#1f77b4",
    "farm": "#1f77b4",
    "race": "#1f77b4",
    "sephash": "#1f77b4",
    "outback": "#1f77b4",
    "clevel": "#1f77b4",
}
MARKERS = {"shard": "o", "farm": "s"}
HATCH = {"shard": "", "farm": "//"}
EDGE = "#0b3d91"

YCSB_ORDER = ["YCSB_A", "YCSB_B", "YCSB_C", "YCSB_D", "YCSB_F"]
YCSB_LABELS = ["A", "B", "C", "D", "F"]


def setup_style():
    mpl.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "DejaVu Serif", "Times", "serif"],
        "font.size": 11,
        "axes.labelsize": 12,
        "axes.titlesize": 12,
        "legend.fontsize": 9,
        "xtick.labelsize": 10,
        "ytick.labelsize": 10,
        "axes.linewidth": 0.8,
        "figure.dpi": 150,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "pdf.fonttype": 42,
    })


def load_csv(path: str) -> List[dict]:
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def ffloat(x) -> Optional[float]:
    try:
        if x is None or x == "":
            return None
        return float(x)
    except Exception:
        return None


def best_by_coro(rows: List[dict]) -> List[dict]:
    """Keep max throughput per (fig, system, dataset, threads)."""
    best: Dict[Tuple, dict] = {}
    for r in rows:
        key = (r["fig"], r["system"], r["dataset"], r["threads"])
        thr = ffloat(r.get("throughput_mops"))
        if thr is None:
            continue
        cur = best.get(key)
        if cur is None or thr > (ffloat(cur.get("throughput_mops")) or -1):
            best[key] = r
    return list(best.values())


def sys_label(s: str) -> str:
    return {"shard": "Shard", "farm": "FaRM"}.get(s, s)


def save(fig, out: str):
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    fig.savefig(out + ".pdf")
    fig.savefig(out + ".png")
    plt.close(fig)
    print("wrote", out + ".{pdf,png}")


def plot_fig12(rows: List[dict], out_dir: str, mode: str):
    rows = [r for r in best_by_coro(rows) if r["fig"] == "fig12"]
    if not rows:
        print("fig12: no data")
        return

    def panel(ax, zipf: bool, title: str):
        systems = sorted({r["system"] for r in rows})
        xs = np.arange(len(YCSB_ORDER))
        width = 0.8 / max(len(systems), 1)
        for i, sys in enumerate(systems):
            vals = []
            for ds in YCSB_ORDER:
                name = ds + ("_zipf" if zipf else "")
                hits = [r for r in rows if r["system"] == sys and r["dataset"] == name]
                vals.append(ffloat(hits[0]["throughput_mops"]) if hits else 0.0)
            offset = (i - (len(systems) - 1) / 2) * width
            bars = ax.bar(xs + offset, vals, width * 0.92, label=sys_label(sys),
                          color=COLORS.get(sys, "#1f77b4"), edgecolor=EDGE,
                          linewidth=0.5, hatch=HATCH.get(sys, ""))
            for b, v in zip(bars, vals):
                if v and v > 0:
                    ax.text(b.get_x() + b.get_width() / 2, b.get_height(),
                            f"{v:.1f}", ha="center", va="bottom", fontsize=7)
        ax.set_xticks(xs)
        ax.set_xticklabels(YCSB_LABELS)
        ax.set_ylabel("Throughput (Mops/s)")
        ax.set_title(title)
        ax.set_ylim(bottom=0)
        ax.grid(axis="y", linestyle="--", alpha=0.4)
        ax.legend(frameon=False, loc="upper right")

    fig, axes = plt.subplots(1, 2, figsize=(8.5, 3.2), sharey=True)
    panel(axes[0], False, "(a) Uniform")
    panel(axes[1], True, "(b) Zipfian (0.99)")
    fig.suptitle("Figure 12  YCSB", y=1.02, fontsize=11)
    save(fig, os.path.join(out_dir, "fig12_ycsb"))


def plot_fig13(rows: List[dict], out_dir: str, mode: str):
    ops = [("search", "fig13_search", "(a) Search"),
           ("insert", "fig13_insert", "(b) Insertion"),
           ("update", "fig13_update", "(c) Update"),
           ("delete", "fig13_delete", "(d) Deletion")]
    data = best_by_coro(rows)
    fig, axes = plt.subplots(2, 2, figsize=(8.5, 6.0))
    any_data = False
    for ax, (op, figkey, title) in zip(axes.flat, ops):
        sub = [r for r in data if r["fig"] == figkey]
        if not sub:
            ax.set_title(title + " (no data)")
            ax.axis("off")
            continue
        any_data = True
        systems = sorted({r["system"] for r in sub})
        for sys in systems:
            pts = sorted(
                [(int(r["threads"]), ffloat(r["throughput_mops"])) for r in sub if r["system"] == sys],
                key=lambda x: x[0],
            )
            pts = [(x, y) for x, y in pts if y is not None]
            if not pts:
                continue
            xs, ys = zip(*pts)
            ax.plot(xs, ys, marker=MARKERS.get(sys, "o"), color=COLORS.get(sys, "#1f77b4"),
                    label=sys_label(sys), linewidth=1.5, markersize=5)
        ax.set_xlabel("#Threads")
        ax.set_ylabel("Throughput (Mops/s)")
        ax.set_title(title)
        ax.set_ylim(bottom=0)
        ax.grid(True, linestyle="--", alpha=0.4)
        ax.legend(frameon=False)
    if not any_data:
        print("fig13: no data")
        plt.close(fig)
        return
    fig.suptitle("Figure 13  Scalability", y=1.01, fontsize=11)
    fig.tight_layout()
    save(fig, os.path.join(out_dir, "fig13_scalability"))


def plot_fig14(rows: List[dict], out_dir: str, mode: str):
    ops = [("search", "fig14_search", "(a) Search"),
           ("insert", "fig14_insert", "(b) Insertion")]
    # fall back to fig13_* latency if fig14_* missing
    data = best_by_coro(rows)
    fig, axes = plt.subplots(1, 2, figsize=(8.5, 3.2))
    any_data = False
    for ax, (op, figkey, title) in zip(axes, ops):
        sub = [r for r in data if r["fig"] in (figkey, figkey.replace("fig14", "fig13"))]
        # prefer fig14
        prefer = [r for r in sub if r["fig"] == figkey] or sub
        if not prefer:
            ax.set_title(title + " (no data)")
            ax.axis("off")
            continue
        any_data = True
        systems = sorted({r["system"] for r in prefer})
        for sys in systems:
            pts = []
            for r in prefer:
                if r["system"] != sys:
                    continue
                p99 = ffloat(r.get("p99_us"))
                if p99 is None:
                    continue
                pts.append((int(r["threads"]), p99))
            pts = sorted(pts)
            if not pts:
                continue
            xs, ys = zip(*pts)
            ax.plot(xs, ys, marker=MARKERS.get(sys, "o"), color=COLORS.get(sys, "#1f77b4"),
                    label=sys_label(sys), linewidth=1.5, markersize=5)
        ax.set_xlabel("#Threads")
        ax.set_ylabel("P99 latency (µs)")
        ax.set_title(title)
        ax.set_ylim(bottom=0)
        ax.grid(True, linestyle="--", alpha=0.4)
        ax.legend(frameon=False)
    if not any_data:
        print("fig14: no data")
        plt.close(fig)
        return
    fig.suptitle("Figure 14  Tail latency", y=1.02, fontsize=11)
    fig.tight_layout()
    save(fig, os.path.join(out_dir, "fig14_latency"))


def plot_fig15(rows: List[dict], out_dir: str, mode: str):
    rows = [r for r in best_by_coro(rows) if r["fig"] == "fig15"]
    if not rows:
        print("fig15: no data")
        return
    order = ["zippydb_all_random", "zippydb_all_dist"]
    labels = ["all_random", "all_dist"]
    systems = sorted({r["system"] for r in rows})
    # Closer category centers than default spacing of 1.0.
    xs = np.arange(len(order)) * 0.55
    width = min(0.32, 0.8 / max(len(systems), 1))
    fig, ax = plt.subplots(figsize=(4.2, 3.2))
    for i, sys in enumerate(systems):
        vals = []
        for ds in order:
            hits = [r for r in rows if r["system"] == sys and r["dataset"] == ds]
            vals.append(ffloat(hits[0]["throughput_mops"]) if hits else 0.0)
        offset = (i - (len(systems) - 1) / 2) * width
        ax.bar(xs + offset, vals, width * 0.9, label=sys_label(sys),
               color=COLORS.get(sys, "#1f77b4"), edgecolor=EDGE, linewidth=0.5,
               hatch=HATCH.get(sys, ""))
    ax.set_xticks(xs)
    ax.set_xticklabels(labels)
    ax.set_xlim(xs[0] - 0.55, xs[-1] + 0.55)
    ax.set_ylabel("Throughput (Mops/s)")
    ax.set_title("Figure 15  Real-world")
    ax.set_ylim(bottom=0)
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    ax.legend(frameon=False)
    save(fig, os.path.join(out_dir, "fig15_realworld"))


def plot_fig16(rows: List[dict], out_dir: str, mode: str):
    rows = [r for r in rows if r["fig"] == "fig16"]
    if not rows:
        print("fig16: no data")
        return
    fig, ax = plt.subplots(figsize=(6.5, 3.2))
    any_data = False
    for r in rows:
        intervals = json.loads(r.get("intervals_json") or "[]")
        if not intervals:
            continue
        any_data = True
        xs = [it["i"] for it in intervals]
        ys = [it["throughput_mops"] for it in intervals]
        sys = r["system"]
        ax.plot(xs, ys, marker=MARKERS.get(sys, "o"), color=COLORS.get(sys, "#1f77b4"),
                label=sys_label(sys), linewidth=1.5, markersize=4)
    if not any_data:
        print("fig16: no interval series (need display_interval_result)")
        plt.close(fig)
        return
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Throughput (Mops/s)")
    ax.set_title("Figure 16  Real-time insertion")
    ax.set_ylim(bottom=0)
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.legend(frameon=False)
    save(fig, os.path.join(out_dir, "fig16_realtime"))


def write_notes(out_dir: str, mode: str):
    path = os.path.join(out_dir, "REPRO_NOTES.txt")
    with open(path, "w") as f:
        f.write(f"""Shard paper reproduction notes ({mode})
=====================================
Cluster: 1 memory (memserver16) + 1 compute (bfhost_72, 96 logical CPUs)
Paper:   3×36=108 threads, 1 thread / physical core
Here:    THREADS_PEAK=96 (1 thread / logical CPU) — closest without oversubscribe

Feasible figures with this open-source tree:
  Fig 12  YCSB A/B/C/D/F  — Shard (+ FaRM/hopscotch if RUN_FARM=1)
  Fig 13  Search/Insert/Update/Delete scalability
  Fig 14  Search/Insert P99 latency (from same runs)
  Fig 15  ZippyDB MixGraph (all_random / all_dist)
  Fig 16  Real-time insert intervals

Not reproduced (need missing baselines or compile-time knobs):
  Fig 12/13/14/15/16 bars for RACE, SepHash, Outback, CLevel (not in repo)
  Fig 17  technique ablation (needs instrumented builds)
  Fig 18  SYNC_ALPHA sweep (compile-time #define in shard.h)
  Table 4 space accounting

Scale notes:
  - full/paper: THREADS_PEAK=96; paper only enlarges max_key/op_num
  - Throughput from SDS_INFO log (not CSV×3 multi-client factor)
""")
    print("wrote", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="full")
    args = ap.parse_args()
    setup_style()
    rows = load_csv(args.csv)
    os.makedirs(args.out, exist_ok=True)
    if not rows:
        print("WARNING: empty csv", args.csv)
    plot_fig12(rows, args.out, args.mode)
    plot_fig13(rows, args.out, args.mode)
    plot_fig14(rows, args.out, args.mode)
    plot_fig15(rows, args.out, args.mode)
    plot_fig16(rows, args.out, args.mode)
    write_notes(args.out, args.mode)


if __name__ == "__main__":
    main()
