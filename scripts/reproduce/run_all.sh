#!/usr/bin/env bash
# One-click: reproduce paper figures feasible on memserver16 + bfhost_72.
#
# Usage:
#   MODE=quick ./scripts/reproduce/run_all.sh          # small-scale (~tens of minutes)
#   MODE=full  ./scripts/reproduce/run_all.sh          # default near-paper scale
#   MODE=paper ./scripts/reproduce/run_all.sh          # max_key=1e8 (long)
#   FIGS="12 13" MODE=quick ./scripts/reproduce/run_all.sh
#
# Env: CLIENT_HOST, MAX_KEY, OP_NUM, RUN_FARM=0|1, SKIP_BUILD=1, SKIP_SYNC=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FIGS="${FIGS:-12 13 14 15 16}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_SYNC="${SKIP_SYNC:-0}"
SKIP_PLOT="${SKIP_PLOT:-0}"

rebuild() {
  if [[ "$SKIP_BUILD" == "1" ]]; then
    log "SKIP_BUILD=1"
    return
  fi
  log "rebuild shard (+ farm) in $BUILD"
  local targets=(shard_bench shard_backend)
  if [[ "${RUN_FARM:-0}" == "1" ]]; then
    targets+=(hopscotch_bench hopscotch_backend)
  else
    # Still try farm bins so RUN_FARM can be flipped later; ignore failures.
    cmake --build "$BUILD" -j"$(nproc)" --target hopscotch_bench hopscotch_backend || true
  fi
  cmake --build "$BUILD" -j"$(nproc)" --target "${targets[@]}"
}

prepare() {
  mkdir -p "$OUT_DIR" "$FIG_DIR" "$OUT_DIR/logs" "$OUT_DIR/csv"
  if [[ "${APPEND_RESULTS:-0}" == "1" ]]; then
    log "APPEND_RESULTS=1 — keep existing $OUT_DIR/results.csv"
    touch "$OUT_DIR/results.csv"
  else
    : >"$OUT_DIR/results.csv" 2>/dev/null || true
    rm -f "$OUT_DIR/results.csv"
  fi
  rebuild
  if [[ "$SKIP_SYNC" != "1" ]]; then
    sync_client
  fi
}

# ---------- Fig 12: YCSB A/B/C/D/F uniform + zipfian @ peak threads ----------
run_fig12() {
  log "=== Figure 12: YCSB throughput ==="
  local datasets_u=(YCSB_A YCSB_B YCSB_C YCSB_D YCSB_F)
  local datasets_z=(YCSB_A_zipf YCSB_B_zipf YCSB_C_zipf YCSB_D_zipf YCSB_F_zipf)
  local systems=(shard)
  [[ "$RUN_FARM" == "1" ]] && systems+=(farm)

  local sys ds
  for sys in "${systems[@]}"; do
    for ds in "${datasets_u[@]}" "${datasets_z[@]}"; do
      write_json "$CFG_DIR/datastructure.json" "{
        'dataset': '$ds',
        'insert_before_execution': True,
        'display_interval_result': False,
        'dump_file_path': '/tmp/shard_dump.csv',
      }"
      scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
      # best_coro_run restarts backend per coro with matching total_tasks
      best_coro_run "fig12" "$sys" "$ds" "$THREADS_PEAK" || true
    done
    stop_backend
  done
}

# ---------- Fig 13 + 14: scalability + tail latency (same runs) ----------
run_fig13_14() {
  log "=== Figure 13/14: single-op scalability + latency ==="
  local ops=(
    "search:SepHash_uniform_RO"
    "insert:SepHash_uniform_WO"
    "update:SepHash_uniform_UO"
    "delete:SepHash_uniform_DO"
  )
  local systems=(shard)
  [[ "$RUN_FARM" == "1" ]] && systems+=(farm)
  # For insert scalability, start empty so WO measures inserts; others prefill.
  local sys pair op ds thr c tag mj

  for sys in "${systems[@]}"; do
    for pair in "${ops[@]}"; do
      op="${pair%%:*}"
      ds="${pair##*:}"
      for thr in "${THREADS_SCALABILITY[@]}"; do
        local prefill=True
        [[ "$op" == "insert" ]] && prefill=False
        write_json "$CFG_DIR/datastructure.json" "{
          'dataset': '$ds',
          'insert_before_execution': $prefill,
          'display_interval_result': False,
          'dump_file_path': '/tmp/shard_dump.csv',
        }"
        scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
        # sweep coro at peak; else fixed coro with fresh backend + matching total_tasks
        if [[ "$thr" -eq "$THREADS_PEAK" ]]; then
          best_coro_run "fig13_${op}" "$sys" "$ds" "$thr" || true
        else
          c="${COROS[$(( ${#COROS[@]} > 1 ? 1 : 0 ))]}"
          start_backend "$sys" "$((thr * c))" || continue
          tag="fig13_${op}_${sys}_${ds}_t${thr}_c${c}"
          if run_client_capture "$sys" "$thr" "$c" "$tag"; then
            mj=$(cat "$OUT_DIR/logs/${tag}.json")
            append_result_row "$OUT_DIR/results.csv" "fig13_${op}" "$sys" "$ds" "$thr" "$c" "$mj"
            append_result_row "$OUT_DIR/results.csv" "fig14_${op}" "$sys" "$ds" "$thr" "$c" "$mj"
          fi
        fi
      done
      # copy peak fig13 rows to fig14
      python3 - "$OUT_DIR/results.csv" "$op" <<'PY'
import csv, sys
path, op = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(path)))
fields = rows[0].keys() if rows else None
extra = []
for r in rows:
    if r["fig"] == f"fig13_{op}":
        n = dict(r); n["fig"] = f"fig14_{op}"; extra.append(n)
if extra and fields:
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        for r in extra: w.writerow(r)
PY
      stop_backend
    done
  done
}

# ---------- Fig 15: ZippyDB / MixGraph ----------
run_fig15() {
  log "=== Figure 15: real-world MixGraph ==="
  local systems=(shard)
  [[ "$RUN_FARM" == "1" ]] && systems+=(farm)
  # all_random: a=b=0 → random modeling; all_dist: RocksDB ZippyDB-like power params
  local workloads=(
    "zippydb_all_random:0.0:0.0:0.0:0.0:0.0"
    "zippydb_all_dist:14.18:-2.998:0.15:23.5:0.25"
  )
  local sys w name a b th k sg
  for sys in "${systems[@]}"; do
    for w in "${workloads[@]}"; do
      IFS=':' read -r name a b th k sg <<<"$w"
      write_json "$CFG_DIR/datastructure.json" "{
        'dataset': '$name',
        'insert_before_execution': True,
        'key_dist_a': $a, 'key_dist_b': $b,
        'value_theta': $th, 'value_k': $k, 'value_sigma': $sg,
        'display_interval_result': False,
        'dump_file_path': '/tmp/shard_dump.csv',
      }"
      scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
      best_coro_run "fig15" "$sys" "$name" "$THREADS_PEAK" || true
    done
    stop_backend
  done
}

# ---------- Fig 16: realtime insert throughput ----------
run_fig16() {
  log "=== Figure 16: realtime insertion ==="
  local systems=(shard)
  [[ "$RUN_FARM" == "1" ]] && systems+=(farm)
  local sys c tag mj
  for sys in "${systems[@]}"; do
    write_json "$CFG_DIR/datastructure.json" "{
      'dataset': 'SepHash_uniform_WO',
      'insert_before_execution': False,
      'display_interval_result': True,
      'intervals': $DURATION,
      'duration': $DURATION,
      'operation_num': $OP_NUM,
      'dump_file_path': '/tmp/shard_dump.csv',
    }"
    scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
    c="${COROS[$(( ${#COROS[@]} > 1 ? 1 : 0 ))]}"
    start_backend "$sys" "$((THREADS_PEAK * c))" || continue
    tag="fig16_${sys}_WO_t${THREADS_PEAK}_c${c}"
    if run_client_capture "$sys" "$THREADS_PEAK" "$c" "$tag"; then
      mj=$(cat "$OUT_DIR/logs/${tag}.json")
      append_result_row "$OUT_DIR/results.csv" "fig16" "$sys" "SepHash_uniform_WO" "$THREADS_PEAK" "$c" "$mj"
    fi
    stop_backend
  done
}

plot_all() {
  if [[ "$SKIP_PLOT" == "1" ]]; then
    log "SKIP_PLOT=1"
    return
  fi
  log "plot figures → $FIG_DIR"
  python3 "$SCRIPT_DIR/plot_paper.py" --csv "$OUT_DIR/results.csv" --out "$FIG_DIR" --mode "$MODE"
}

main() {
  log "MODE=$MODE MAX_KEY=$MAX_KEY OP_NUM=$OP_NUM THREADS_PEAK=$THREADS_PEAK RUN_FARM=$RUN_FARM"
  log "FIGS=$FIGS CLIENT=$CLIENT_HOST"
  prepare
  trap 'stop_backend' EXIT

  # de-dup so "13 14" only runs scalability suite once
  declare -A WANT=()
  local f
  for f in $FIGS; do WANT["$f"]=1; done

  [[ -n "${WANT[12]:-}" ]] && run_fig12
  if [[ -n "${WANT[13]:-}" || -n "${WANT[14]:-}" ]]; then
    run_fig13_14
  fi
  [[ -n "${WANT[15]:-}" ]] && run_fig15
  [[ -n "${WANT[16]:-}" ]] && run_fig16
  for f in 17 18; do
    if [[ -n "${WANT[$f]:-}" ]]; then
      log "SKIP Fig $f: needs compile-time variants (SYNC_ALPHA / technique flags)"
    fi
  done

  plot_all
  log "done. results: $OUT_DIR/results.csv  figs: $FIG_DIR"
}

main "$@"
