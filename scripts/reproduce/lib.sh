#!/usr/bin/env bash
# Shared helpers for Shard paper reproduction on memserver16 + bfhost_72.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
CFG_DIR="$ROOT/config"
OUT_DIR="${OUT_DIR:-$ROOT/results/reproduce}"
FIG_DIR="${FIG_DIR:-$ROOT/figs}"
CLIENT_HOST="${CLIENT_HOST:-bfhost_72}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/dongshuqi/Shard}"
SERVER_IB="${SERVER_IB:-10.10.1.16}"
TCP_PORT="${TCP_PORT:-12345}"
SERVER_IBDEV="${SERVER_IBDEV:-mlx5_2}"   # memserver16 active IB
CLIENT_IBDEV="${CLIENT_IBDEV:-mlx5_0}"   # bfhost_72 active IB
LD_PRELOAD_LIBS="./libibverbs.so:./libmlx5.so"

# Thread scale on this cluster (bfhost_72): 96 logical CPUs → 1 thread / CPU.
# Paper cluster: 3×36=108 physical-core-pinned threads (we cannot match that 1:1 here).
MODE="${MODE:-full}"   # quick | full | paper
case "$MODE" in
  quick)
    # small data; default peak threads lower for a short run
    MAX_KEY="${MAX_KEY:-1000000}"
    OP_NUM="${OP_NUM:-1000000}"
    DURATION="${DURATION:-5}"
    THREADS_SCALABILITY=(1 4 8 16 48 96)
    THREADS_PEAK="${THREADS_PEAK:-16}"
    COROS=(1 2)
    RUN_FARM="${RUN_FARM:-0}"
    ;;
  paper)
    # paper-scale keys/ops + paper total thread count (108; oversubscribe on 96 CPUs)
    MAX_KEY="${MAX_KEY:-100000000}"
    OP_NUM="${OP_NUM:-100000000}"
    DURATION="${DURATION:-10}"
    # bfhost_72: 96 logical CPUs (2S×24C×2HT); use 96 = 1 thread / logical CPU
    THREADS_SCALABILITY=(1 2 4 8 12 16 24 36 48 72 96)
    THREADS_PEAK="${THREADS_PEAK:-96}"
    COROS=(1 2 3 4)
    RUN_FARM="${RUN_FARM:-1}"
    ;;
  full|*)
    # mid-size data; peak 96 threads on this cluster
    MAX_KEY="${MAX_KEY:-10000000}"
    OP_NUM="${OP_NUM:-20000000}"
    DURATION="${DURATION:-10}"
    THREADS_SCALABILITY=(1 2 4 8 12 16 24 36 48 72 96)
    THREADS_PEAK="${THREADS_PEAK:-96}"
    COROS=(1 2 3 4)
    RUN_FARM="${RUN_FARM:-1}"
    ;;
esac

# Override after MODE defaults, e.g. COROS_OVERRIDE="2" or COROS_OVERRIDE="1 2 3 4"
if [[ -n "${COROS_OVERRIDE:-}" ]]; then
  # shellcheck disable=SC2206
  COROS=($COROS_OVERRIDE)
fi

mkdir -p "$OUT_DIR" "$FIG_DIR" "$OUT_DIR/logs" "$OUT_DIR/csv"

log() { echo "[$(date '+%F %T')] $*"; }

write_json() {
  # write_json <path> <python-dict-expr merging into base>
  local path="$1"
  local py="$2"
  python3 - "$path" <<PY
import json, sys
path = sys.argv[1]
base = {
  "nr_threads": 1,
  "tasks_per_thread": 1,
  "dataset": "YCSB_C",
  "dump_file_path": "/tmp/shard_dump.csv",
  "nic_numa_node": 0,
  "cpu_nodes": 2,
  "cores_per_cpu": 24,
  "insert_before_execution": True,
  "positive_search": False,
  "max_key": $MAX_KEY,
  "key_length": 8,
  "value_length": 8,
  "rehash_key": False,
  "operation_num": $OP_NUM,
  "duration": $DURATION,
  "intervals": $DURATION,
  "display_interval_result": False,
  "zipfian_const": 0.99,
  "node_id": 0,
  "client_num": 1,
  "memory_servers": [{"hostname": "$SERVER_IB", "port": $TCP_PORT}],
  "key_dist_a": 0.0,
  "key_dist_b": 0.0,
  "value_theta": 0.0,
  "value_k": 0.0,
  "value_sigma": 0.0,
}
override = $py
base.update(override)
with open(path, "w") as f:
    json.dump(base, f, indent=2)
    f.write("\n")
print("wrote", path)
PY
}

fix_ibdev_local() {
  python3 - "$CFG_DIR/smart_config.json" "$SERVER_IBDEV" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
c = json.load(open(path))
c.setdefault("infiniband", {})["name"] = name
c.setdefault("infiniband", {})["port"] = c.get("infiniband", {}).get("port", 1)
json.dump(c, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("local smart_config IB =", name)
PY
}

fix_ibdev_client() {
  ssh -o BatchMode=yes "$CLIENT_HOST" \
    "python3 -c \"
import json
path='${CLIENT_ROOT}/config/smart_config.json'
name='${CLIENT_IBDEV}'
c=json.load(open(path))
c.setdefault('infiniband', {})['name']=name
c['infiniband']['port']=c['infiniband'].get('port',1)
json.dump(c, open(path,'w'), indent=2)
open(path,'a').write('\\n')
print('client smart_config IB =', name)
\""
}

sync_client() {
  log "sync configs + bins + preload libs → $CLIENT_HOST"
  fix_ibdev_local
  # Push sources that affect client binary semantics (never multi-src --delete).
  rsync -a "$ROOT/shard/" "$CLIENT_HOST:$CLIENT_ROOT/shard/"
  rsync -a "$ROOT/include/" "$CLIENT_HOST:$CLIENT_ROOT/include/"
  rsync -a "$ROOT/scripts/" "$CLIENT_HOST:$CLIENT_ROOT/scripts/"
  rsync -a "$CFG_DIR/" "$CLIENT_HOST:$CLIENT_ROOT/config/"
  ssh -o BatchMode=yes "$CLIENT_HOST" "mkdir -p $CLIENT_ROOT/build/shard $CLIENT_ROOT/build/farm"
  rsync -a "$BUILD/shard/shard_bench" "$CLIENT_HOST:$CLIENT_ROOT/build/shard/"
  rsync -a "$BUILD/farm/hopscotch_bench" "$CLIENT_HOST:$CLIENT_ROOT/build/farm/" 2>/dev/null || true
  rsync -a "$BUILD/libibverbs.so" "$BUILD/libmlx5.so" "$CLIENT_HOST:$CLIENT_ROOT/build/"
  # critical: client NIC differs from server
  fix_ibdev_client
}

stop_backend() {
  # Prefer PID file — avoid `pkill -f <full-path>` which matches ssh/wrapper
  # command lines that merely *mention* the path (and can kill the runner).
  local pidf="$OUT_DIR/logs/backend.pid"
  if [[ -f "$pidf" ]]; then
    local pid
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      # also kill children of the launcher subshell if needed
      pkill -9 -P "$pid" 2>/dev/null || true
      # Reap so bash job-notify "Killed" cannot trip set -e mid-suite.
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf"
  fi
  # Fallback: kill by exact executable basename only (backend runs on memserver, not client)
  killall -9 shard_backend 2>/dev/null || true
  killall -9 hopscotch_backend 2>/dev/null || true
  sleep 1
}

stop_remote_clients() {
  # Leftover shard_bench holds initiator hugepages → next run mmap fails.
  ssh_cli 'killall -9 shard_bench hopscotch_bench 2>/dev/null || true' || true
  sleep 1
}

set_backend_total_tasks() {
  # total_tasks must match client_num * nr_threads * tasks_per_thread for AFS/resize sync
  local total="$1"
  python3 - "$CFG_DIR/backend.json" "$total" <<'PY'
import json, sys
path, total = sys.argv[1], int(sys.argv[2])
c = json.load(open(path))
c["total_tasks"] = total
json.dump(c, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("backend total_tasks =", total)
PY
}

start_backend() {
  local system="${1:-shard}"  # shard | farm
  local total_tasks="${2:-1}"
  set_backend_total_tasks "$total_tasks"
  stop_remote_clients
  stop_backend
  # give hugepages a moment to free after previous backend
  sleep 1
  local bin="$BUILD/shard/shard_backend"
  [[ "$system" == "farm" ]] && bin="$BUILD/farm/hopscotch_backend"
  log "start backend: $bin (total_tasks=$total_tasks)"
  (
    cd "$BUILD"
    # shellcheck disable=SC2086
    env LD_PRELOAD="$LD_PRELOAD_LIBS" "$bin" >"$OUT_DIR/logs/backend_${system}.log" 2>&1
  ) &
  echo $! >"$OUT_DIR/logs/backend.pid"
  disown $! 2>/dev/null || true
  # wait until listening
  for i in $(seq 1 60); do
    if ss -lntp 2>/dev/null | grep -q ":$TCP_PORT"; then
      log "backend up on :$TCP_PORT"
      return 0
    fi
    sleep 0.5
  done
  log "ERROR: backend failed to listen; tail log:"
  tail -30 "$OUT_DIR/logs/backend_${system}.log" || true
  return 1
}

# Parse "throughput = X.XXX M" / "P99 latency = Y.YYY us" from client log
parse_metrics() {
  local logf="$1"
  python3 - "$logf" <<'PY'
import re, sys, json
text = open(sys.argv[1], errors="ignore").read()
th = re.findall(r"throughput = ([0-9.]+) M", text)
p50 = re.findall(r"P50 latency = ([0-9.]+) us", text)
p99 = re.findall(r"P99 latency = ([0-9.]+) us", text)
intervals = re.findall(
    r"interval (\d+) thoughput = ([0-9.]+) M,.*?P99 latency = ([0-9.]+) us",
    text,
)
out = {
    "throughput_mops": float(th[-1]) if th else None,
    "p50_us": float(p50[-1]) if p50 else None,
    "p99_us": float(p99[-1]) if p99 else None,
    "intervals": [{"i": int(a), "throughput_mops": float(b), "p99_us": float(c)} for a,b,c in intervals],
}
print(json.dumps(out))
PY
}

run_client() {
  # run_client <system> <threads> <coro> <tag>
  local system="$1" threads="$2" coro="$3" tag="$4"
  local bin_rel="shard/shard_bench"
  [[ "$system" == "farm" ]] && bin_rel="farm/hopscotch_bench"
  local logf="$OUT_DIR/logs/${tag}.log"
  log "client $system thr=$threads coro=$coro → $logf"
  # push current datastructure.json
  scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
  ssh -o BatchMode=yes "$CLIENT_HOST" bash -s <<EOF
set -euo pipefail
cd $CLIENT_ROOT/build
export LD_PRELOAD=$LD_PRELOAD_LIBS
export REPORT_LATENCY=1
export COMPUTE_NODES=1
./$bin_rel $threads $coro
EOF
  # capture remote stdout by re-running with tee locally via ssh
}

# Short SSH hops only (avoid holding a multi-hour session that dies on Broken pipe).
ssh_cli() {
  ssh -o BatchMode=yes -o ClearAllForwardings=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
    "$CLIENT_HOST" "$@"
}

require_client_hugepages() {
  # initiator_cache_size is in MiB (smart_config); MAP_HUGE_2MB → pages = MiB/2.
  local need_mb need_pages free_pages i
  need_mb=$(python3 -c "import json;print(json.load(open('$CFG_DIR/smart_config.json')).get('initiator_cache_size',4096))")
  need_pages=$(( (need_mb + 1) / 2 ))
  for i in 1 2 3 4 5 6 7 8 9 10; do
    free_pages=$(ssh_cli 'grep -E "^HugePages_Free:" /proc/meminfo | awk "{print \$2}"' || echo 0)
    if [[ "${free_pages:-0}" -ge "$need_pages" ]]; then
      log "client hugepages ok: Free=$free_pages (need>=$need_pages)"
      return 0
    fi
    log "client hugepages Free=$free_pages < $need_pages — killing leftovers, retry $i/10"
    stop_remote_clients
    sleep 2
  done
  log "ERROR: bfhost_72 HugePages_Free=$free_pages < need~$need_pages (cache ${need_mb}MiB)."
  log "On bfhost_72 run: sudo bash -c 'echo 40960 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'"
  return 1
}

run_client_capture() {
  local system="$1" threads="$2" coro="$3" tag="$4"
  local bin_rel="shard/shard_bench"
  [[ "$system" == "farm" ]] && bin_rel="farm/hopscotch_bench"
  local logf="$OUT_DIR/logs/${tag}.log"
  local rlog="/tmp/${tag}.log" rpid="/tmp/${tag}.pid" rcfile="/tmp/${tag}.rc"
  log "client $system thr=$threads coro=$coro → $logf"
  require_client_hugepages || return 1
  # Keep JSON in sync with argv so total_tasks / generators match (avoid resize barrier deadlock)
  python3 - "$CFG_DIR/datastructure.json" "$threads" "$coro" <<'PY'
import json,sys
path, thr, coro = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
c=json.load(open(path))
c["nr_threads"]=thr
c["tasks_per_thread"]=coro
json.dump(c, open(path,"w"), indent=2); open(path,"a").write("\n")
PY
  scp -q "$CFG_DIR/datastructure.json" "$CLIENT_HOST:$CLIENT_ROOT/config/datastructure.json"
  # Detach bench from SSH: long 1e8 runs used to die with "Broken pipe" mid-measure.
  ssh_cli bash -s <<EOF
set -euo pipefail
rm -f '$rlog' '$rpid' '$rcfile'
cd '$CLIENT_ROOT/build'
# Outer pid is the bash wrapper; poll that. Bench is its child.
nohup bash -c 'env LD_PRELOAD=$LD_PRELOAD_LIBS REPORT_LATENCY=1 COMPUTE_NODES=1 DISABLE_CORO_THROT=1 \
  ./$bin_rel $threads $coro >"$rlog" 2>&1; echo \$? >"$rcfile"' </dev/null >/dev/null 2>&1 &
echo \$! >'$rpid'
EOF
  local pid
  pid=$(ssh_cli "cat '$rpid'")
  [[ -n "$pid" ]] || { log "WARN: failed to start remote client"; return 1; }
  log "remote pid=$pid; polling until exit"
  # Paper 1e8 prefill can take ~1–2h; measure should finish in tens of seconds.
  # Cap wall time so a stuck PART_DIRTY/resize spin cannot freeze the suite.
  local max_wall="${CLIENT_MAX_WALL_SEC:-$(( 4 * 3600 ))}"
  local waited=0
  while ssh_cli "kill -0 $pid 2>/dev/null"; do
    sleep 30
    waited=$((waited + 30))
    if (( waited >= max_wall )); then
      log "WARN: client $tag exceeded ${max_wall}s — killing remote pid $pid"
      ssh_cli "kill -9 $pid 2>/dev/null; pkill -9 -P $pid 2>/dev/null; true" || true
      break
    fi
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ssh_cli "test -f '$rcfile'" && break
    sleep 1
  done
  scp -q "$CLIENT_HOST:$rlog" "$logf.raw" || {
    log "WARN: failed to fetch $rlog"
    return 1
  }
  local rc
  rc=$(ssh_cli "cat '$rcfile' 2>/dev/null || echo 1")
  grep -v 'remote port forwarding failed' "$logf.raw" >"$logf" || cp "$logf.raw" "$logf"
  if [[ "$rc" != "0" ]]; then
    log "WARN: client rc=$rc; see $logf.raw"
    tail -40 "$logf" || true
    return 1
  fi
  parse_metrics "$logf" >"$OUT_DIR/logs/${tag}.json"
}

append_result_row() {
  # append_result_row <csv> <fig> <system> <dataset> <threads> <coro> <json_metrics>
  local csv="$1" fig="$2" system="$3" dataset="$4" threads="$5" coro="$6" metrics_json="$7"
  python3 - "$csv" "$fig" "$system" "$dataset" "$threads" "$coro" "$metrics_json" <<'PY'
import csv, json, os, sys
path, fig, system, dataset, thr, coro, mj = sys.argv[1:8]
m = json.loads(mj)
new = not os.path.exists(path)
with open(path, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=[
        "fig","system","dataset","threads","coro",
        "throughput_mops","p50_us","p99_us","intervals_json"
    ])
    if new: w.writeheader()
    w.writerow({
        "fig": fig, "system": system, "dataset": dataset,
        "threads": thr, "coro": coro,
        "throughput_mops": m.get("throughput_mops"),
        "p50_us": m.get("p50_us"), "p99_us": m.get("p99_us"),
        "intervals_json": json.dumps(m.get("intervals") or []),
    })
PY
}

best_coro_run() {
  # Pick best coro among COROS for fixed threads/dataset/system. Prints best metrics json path.
  # Restarts backend per coro so memory pool + total_tasks stay consistent.
  local fig="$1" system="$2" dataset="$3" threads="$4"
  local best_t="-1" best_coro="" best_json=""
  local c tag mj thr total
  for c in "${COROS[@]}"; do
    total=$((threads * c * 1))  # client_num=1
    start_backend "$system" "$total" || continue
    tag="${fig}_${system}_${dataset}_t${threads}_c${c}"
    if ! run_client_capture "$system" "$threads" "$c" "$tag"; then
      continue
    fi
    mj=$(cat "$OUT_DIR/logs/${tag}.json")
    thr=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('throughput_mops') or -1)" <<<"$mj")
    append_result_row "$OUT_DIR/results.csv" "$fig" "$system" "$dataset" "$threads" "$c" "$mj"
    python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)" "$thr" "$best_t" \
      && best_t="$thr" && best_coro="$c" && best_json="$OUT_DIR/logs/${tag}.json"
  done
  echo "$best_coro $best_t $best_json"
}
