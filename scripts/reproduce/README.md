# Reproduce Shard paper figures

Topology: memory node (`shard_backend`) + compute node (`shard_bench`).

## One-click

```bash
cd ~/Shard

# Small-scale run
MODE=quick FIGS="12" RUN_FARM=0 ./scripts/reproduce/run_all.sh

# 96 threads (one per logical CPU on this cluster)
MODE=full ./scripts/reproduce/run_all.sh

# Paper-scale keys/ops (still 96 threads here; paper used 108)
MODE=paper MAX_KEY=100000000 OP_NUM=0 DURATION=10 \
  COROS_OVERRIDE="1 2" RUN_FARM=0 FIGS="12 13 14 15 16" \
  ./scripts/reproduce/run_all.sh
```

`OP_NUM=0` ends the run by `DURATION` only (avoids a fake ~10 Mops cap from `OP_NUM/DURATION`).

Outputs (local; listed in `.gitignore`):
- `results/reproduce/results.csv`
- `results/reproduce/logs/`
- `figs/fig12_ycsb.{pdf,png}` … `fig16_realtime.{pdf,png}`

## Feasible vs not

| Paper | Status |
|-------|--------|
| Fig 12 YCSB | Yes (Shard; optional FaRM). No RACE/SepHash/Outback/CLevel in this repo |
| Fig 13 scalability | Yes (search/insert/update/delete) |
| Fig 14 tail latency | Yes (P99 from same runs) |
| Fig 15 ZippyDB | Yes (MixGraph all_random / all_dist) |
| Fig 16 realtime | Yes (interval throughput) |
| Fig 17 ablation | No (needs instrumented builds) |
| Fig 18 alpha sweep | No (`SYNC_ALPHA` is compile-time) |

Always run binaries under `build/` with:

```bash
LD_PRELOAD=./libibverbs.so:./libmlx5.so
```

(the script sets this).

## Plot only

```bash
python3 scripts/reproduce/plot_paper.py \
  --csv results/reproduce_real/results.csv \
  --out figs --mode paper
```
