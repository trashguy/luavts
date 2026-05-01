#!/usr/bin/env bash
# Sweep every (runtime × workload) combination and emit results/.
#
# Run with no args. Output:
#   results/<runtime>.csv          per-runtime aggregated CSV
#   results/all.csv                concatenated, headered
#   results/footprint.csv          binary size + 1-VM RSS per runtime
#   results/summary.md             pivoted comparison tables
#
# Each host self-emits one CSV row per run on stdout.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/results"
BIN="$ROOT/zig-out/bin"
mkdir -p "$RES"

# -------- discover available hosts --------
HOSTS=()
for h in lua54_host luajit_host quickjs_host v8_host; do
    [ -x "$BIN/$h" ] && HOSTS+=("$h")
done

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "no host binaries in $BIN — run 'zig build' (and scripts/link_v8_host.sh for V8)"
    exit 1
fi

echo "== runtimes available: ${HOSTS[*]}"

# -------- workloads + script paths --------
# Each row: <workload> <handwritten_lua_path> <handwritten_js_path> <tstl_lua_path> <tsc_js_path>
declare -A LUA_HW=(
    [call_overhead]="src/workloads/lua/call_overhead.lua"
    [ai_tick]="src/workloads/lua/ai_tick.lua"
    [gc_pause]="src/workloads/lua/gc_pause.lua"
    [math_loop]="src/workloads/lua/math_loop.lua"
    [vm_startup]="src/workloads/lua/call_overhead.lua"
    [cache_eviction]="src/workloads/lua/gc_pause.lua"
    [tick_budget]="src/workloads/lua/tick_budget.lua"
)
declare -A JS_HW=(
    [call_overhead]="src/workloads/js/call_overhead.js"
    [ai_tick]="src/workloads/js/ai_tick.js"
    [gc_pause]="src/workloads/js/gc_pause.js"
    [math_loop]="src/workloads/js/math_loop.js"
    [vm_startup]="src/workloads/js/call_overhead.js"
    [cache_eviction]="src/workloads/js/gc_pause.js"
    [tick_budget]="src/workloads/js/tick_budget.js"
)
declare -A LUA_TSTL=(
    [call_overhead]="src/workloads/ts-out-lua/call_overhead.lua"
    [ai_tick]="src/workloads/ts-out-lua/ai_tick.lua"
    [gc_pause]="src/workloads/ts-out-lua/gc_pause.lua"
    [math_loop]="src/workloads/ts-out-lua/math_loop.lua"
)
declare -A JS_TSC=(
    [call_overhead]="src/workloads/ts-out-js/call_overhead.js"
    [ai_tick]="src/workloads/ts-out-js/ai_tick.js"
    [gc_pause]="src/workloads/ts-out-js/gc_pause.js"
    [math_loop]="src/workloads/ts-out-js/math_loop.js"
)

WORKLOADS=(call_overhead ai_tick gc_pause math_loop vm_startup cache_eviction)
TICK_BUDGET_PRESSURES=(0 200 2000 20000 100000)
AI_TICK_SCALING=(500 1000 5000 10000 25000 50000 100000)

# -------- emit aggregate CSVs --------
ALL="$RES/all.csv"
echo "runtime,workload,variant,iters,total_ns,min_ns,p50_ns,p95_ns,p99_ns,max_ns,rss_kb,notes" > "$ALL"

run_one() {
    local host="$1" workload="$2" script="$3" variant="$4" pressure="${5:-}"
    local rtcsv="$RES/${host%_host}.csv"
    [ -f "$rtcsv" ] || echo "runtime,workload,variant,iters,total_ns,min_ns,p50_ns,p95_ns,p99_ns,max_ns,rss_kb,notes" > "$rtcsv"
    local out
    if [ -n "$pressure" ]; then
        out=$("$BIN/$host" "$workload" "$ROOT/$script" "$variant" "$pressure" 2>&1) || { echo "  FAIL: $host $workload $variant p=$pressure" >&2; echo "$out" >&2; return; }
    else
        out=$("$BIN/$host" "$workload" "$ROOT/$script" "$variant" 2>&1) || { echo "  FAIL: $host $workload $variant" >&2; echo "$out" >&2; return; }
    fi
    echo "$out" >> "$rtcsv"
    echo "$out" >> "$ALL"
    echo "  $out"
}

for host in "${HOSTS[@]}"; do
    rt="${host%_host}"
    : > "$RES/$rt.csv"
    echo "runtime,workload,variant,iters,total_ns,min_ns,p50_ns,p95_ns,p99_ns,max_ns,rss_kb,notes" > "$RES/$rt.csv"
    echo "== $host"
    for w in "${WORKLOADS[@]}"; do
        case "$rt" in
            lua54|luajit)
                run_one "$host" "$w" "${LUA_HW[$w]}" handwritten
                if [ -n "${LUA_TSTL[$w]:-}" ] && [ -f "$ROOT/${LUA_TSTL[$w]}" ]; then
                    run_one "$host" "$w" "${LUA_TSTL[$w]}" tstl
                fi
                ;;
            quickjs|v8)
                run_one "$host" "$w" "${JS_HW[$w]}" handwritten
                if [ -n "${JS_TSC[$w]:-}" ] && [ -f "$ROOT/${JS_TSC[$w]}" ]; then
                    run_one "$host" "$w" "${JS_TSC[$w]}" tsc
                fi
                ;;
        esac
    done
    # tick_budget gets its own loop because it varies pressure.
    for press in "${TICK_BUDGET_PRESSURES[@]}"; do
        case "$rt" in
            lua54|luajit) run_one "$host" tick_budget "${LUA_HW[tick_budget]}" handwritten "$press" ;;
            quickjs|v8)   run_one "$host" tick_budget "${JS_HW[tick_budget]}" handwritten "$press" ;;
        esac
    done
done

# -------- ai_tick scaling sweep (separate CSV: results/scaling.csv) --------
# Each row: <runtime>,<n_agents>,<p50_ns>,<p99_ns>,<max_ns>,<rss_kb>
# Used by build_readme.py to render the scaling-vs-agent-count table.
SCALING="$RES/scaling.csv"
echo "runtime,n_agents,p50_ns,p99_ns,max_ns,rss_kb" > "$SCALING"
echo
echo "== ai_tick scaling sweep"
for host in "${HOSTS[@]}"; do
    rt="${host%_host}"
    case "$rt" in
        lua54|luajit) script="${LUA_HW[ai_tick]}" ;;
        quickjs|v8)   script="${JS_HW[ai_tick]}" ;;
    esac
    for n in "${AI_TICK_SCALING[@]}"; do
        if out=$("$BIN/$host" ai_tick "$ROOT/$script" handwritten "$n" 2>&1); then
            # CSV row: runtime,workload,variant,iters,total_ns,min_ns,p50_ns,p95_ns,p99_ns,max_ns,rss_kb,notes
            # Pull p50 (col 7), p99 (col 9), max (col 10), rss_kb (col 11).
            echo "$out" | awk -F, -v rt="$rt" -v n="$n" \
                '{print rt","n","$7","$9","$10","$11}' >> "$SCALING"
            echo "  $rt n=$n  $(echo "$out" | awk -F, '{print $7}')ns p50"
        else
            echo "  FAIL $rt n=$n: $out" >&2
        fi
    done
done

# -------- binary footprint --------
FP="$RES/footprint.csv"
echo "runtime,binary_bytes,binary_human" > "$FP"
for host in "${HOSTS[@]}"; do
    rt="${host%_host}"
    bytes=$(stat -c%s "$BIN/$host")
    human=$(numfmt --to=iec --suffix=B "$bytes")
    echo "$rt,$bytes,$human" >> "$FP"
done

echo
echo "== results/ written:"
ls -lh "$RES/"
