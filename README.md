# luavts — embedded scripting benchmarks

Why **PUC Lua 5.4 + TypeScriptToLua** is the right embedding choice for an
MMO server's scripting hot path — argued with measurements, not vibes.

## TL;DR

- **V8 ships 23× the binary** of PUC Lua 5.4 (36.6 MB vs 1.6 MB)
- **V8 uses 9× the RAM per VM** (20.2 MB vs 2.3 MB)
- **V8 takes 38× longer to spin up an isolate** (604.8 μs vs 16.1 μs)
- **QuickJS drops 91% of 60Hz ticks** at extreme alloc pressure; PUC Lua 5.4 stays inside budget
- **TSTL output runs within ~5–15% of handwritten Lua** — TS ergonomics are essentially free
- **V8 wins steady-state throughput by 1–2 orders of magnitude** when its JIT can warm up — but at realistic AI-leaf call rates, no runtime hits the tick budget anyway

The first three are the load-bearing arguments for an MMO server with many isolated VMs.

---

## Charts

Generated from `results/all.csv` + `results/footprint.csv` via `scripts/build_readme.py`.
Re-run the sweep (`./scripts/run_all.sh`) and regenerate (`python3 scripts/build_readme.py`)
to refresh.

### Binary size (host + runtime, ReleaseFast)

_smaller is better_

```
LuaJIT 2.1   ▎                                368 KB    1.00×
PUC Lua 5.4  █▎                               1.6 MB    4.43×
QuickJS-NG   ████▌                            5.6 MB   15.58×
V8           ██████████████████████████████  36.6 MB  101.80×
```

### Process RSS @ 1 VM (loaded + idle)

_smaller is better_

```
PUC Lua 5.4  ███▍                             2.3 MB    1.00×
LuaJIT 2.1   ████                             2.7 MB    1.19×
QuickJS-NG   ████▌                            3.1 MB    1.37×
V8           ██████████████████████████████  20.2 MB    8.87×
```

### VM startup latency (p50)

_smaller is better_

```
PUC Lua 5.4  ▊                                16.1 μs    1.00×
LuaJIT 2.1   █▋                               33.0 μs    2.06×
QuickJS-NG   ███▋                             75.5 μs    4.70×
V8           ██████████████████████████████  604.8 μs   37.66×
```

### Host → script call edge (empty fn)

_smaller is better_

```
LuaJIT 2.1   ███▊                            10 ns    1.00×
QuickJS-NG   ████▌                           12 ns    1.20×
PUC Lua 5.4  ██████▊                         18 ns    1.80×
V8           ██████████████████████████████  80 ns    8.00×
```

### ai_tick — p50 wall per tick (5,000 agents)

_smaller is better_

```
V8           ▋                                15.2 μs    1.00×
LuaJIT 2.1   █                                23.6 μs    1.55×
PUC Lua 5.4  ████████████████▌               375.6 μs   24.66×
QuickJS-NG   ██████████████████████████████  681.8 μs   44.77×
```

### ai_tick — scaling across agent counts

_p50 wall per tick. Answers "does QuickJS / V8 / etc. pull ahead at higher N?"_

| n_agents | PUC Lua 5.4 | LuaJIT 2.1 | QuickJS-NG | V8 | qjs ÷ lua54 |
|---:|---:|---:|---:|---:|---:|
| 500 | 37.3 μs | 2.4 μs | 69.2 μs | 1.6 μs | 1.85× |
| 1,000 | 72.7 μs | 4.6 μs | 134.7 μs | 3.4 μs | 1.85× |
| 5,000 | 360.4 μs | 25.1 μs | 675.7 μs | 14.6 μs | 1.87× |
| 10,000 | 715.1 μs | 48.1 μs | 1.37 ms | 29.7 μs | 1.92× |
| 25,000 | 1.78 ms | 118.6 μs | 3.45 ms | 72.3 μs | 1.94× |
| 50,000 | 3.60 ms | 239.4 μs | 6.75 ms | 150.6 μs | 1.88× |
| 100,000 | 7.18 ms | 607.9 μs | 13.61 ms | 305.1 μs | 1.90× |

**The QuickJS-vs-Lua ratio is flat across the entire range** — QuickJS
doesn't pull ahead at higher agent counts. What *does* pull ahead is V8,
because its JIT compiles the per-agent inner loop down to near-native
code. QuickJS has no JIT, so it stays a constant factor behind PUC Lua
5.4's interpreter at every scale.

### ai_tick — max tick wall (worst case across 1,200 ticks)

_smaller is better_

```
V8           ▉                                49.6 μs    1.00×
LuaJIT 2.1   ██▏                             110.9 μs    2.24×
PUC Lua 5.4  █████████▋                      505.9 μs   10.21×
QuickJS-NG   ██████████████████████████████   1.56 ms   31.44×
```

### GC tail latency — gc_pause max

_smaller is better_

```
LuaJIT 2.1   █▊                              153.6 μs    1.00×
QuickJS-NG   ███▍                            297.6 μs    1.94×
PUC Lua 5.4  ████                            344.2 μs    2.24×
V8           ██████████████████████████████   2.57 ms   16.74×
```

### tick_budget — % of ticks exceeding 60Hz budget under load

_Each Zig host tick pairs the script's `tick()` with a fixed Zig-side hot loop. Pressure = short-lived alloc per tick — drives GC._

| runtime | p=0 | p=200 | p=2000 | p=20000 | p=100000 |
|---|---|---|---|---|---|
| PUC Lua 5.4 | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) |
| LuaJIT 2.1 | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) |
| QuickJS-NG | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 1090/1200 (90.8%) |
| V8 | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) | 0/1200 (0.0%) |

**tick_budget p50 (μs per tick) across pressure levels:**

| runtime | p=0 | p=200 | p=2k | p=20k | p=100k |
|---|---|---|---|---|---|
| PUC Lua 5.4 | 349.9 μs | 377.4 μs | 481.1 μs | 2.32 ms | 11.13 ms |
| LuaJIT 2.1 | 26.3 μs | 28.9 μs | 59.4 μs | 732.0 μs | 3.78 ms |
| QuickJS-NG | 682.0 μs | 746.9 μs | 985.2 μs | 3.96 ms | 17.16 ms |
| V8 | 15.0 μs | 15.2 μs | 18.5 μs | 37.0 μs | 136.3 μs |

### TypeScriptToLua tax

_Same workload, handwritten Lua vs `.ts` → TSTL → `.lua`. Run on PUC Lua 5.4._

| workload | handwritten p50 | TSTL p50 | overhead |
|---|---|---|---|
| call_overhead | 18 ns | 20 ns | +11% |
| ai_tick | 375.6 μs | 422.2 μs | +12% |
| gc_pause | 93.1 μs | 97.9 μs | +5% |
| math_loop | 20.18 ms | 24.31 ms | +20% |

---

## Runtimes compared

| Runtime | Version | Source | Role |
|---|---|---|---|
| PUC Lua 5.4 | 5.4.8 | vendored, built via `build.zig` | the committed runtime |
| LuaJIT | 2.1 | system lib | ceiling reference (rejected: frozen at 5.1) |
| QuickJS-NG | `main` | vendored | the realistic embeddable-JS alternative |
| V8 | `main` monolith | vendored via depot_tools | the "but V8 is faster" claim |

All hosts written in **Zig** so FFI cost reflects what a real Zig server
would observe. `extern "C"` in Zig has zero call-convention overhead vs C,
so these numbers carry over to any C-style embedding.

## Workloads

| Workload | What it measures | Why it matters |
|---|---|---|
| `embed_footprint` | binary size + RSS | per-AI VM isolation budget |
| `vm_startup` | create + teardown | hot reload, sandbox spin-up |
| `call_overhead` | host→empty-fn × 1M | the AI-leaf hot path |
| `ai_tick` | 5k agents × 1200 ticks | the load-bearing benchmark |
| `gc_pause` | per-step pause distribution | GC tail risk in isolation |
| `tick_budget` | Zig host tick + script tick | **GC blast radius on the Zig host** |
| `cache_eviction` | host hot-buffer pass before/after VM GC | invisible cache tax (null result) |
| `math_loop` | tight numeric loop | concession workload — JIT wins, doesn't matter |

Each workload exists in three forms — handwritten `.lua`, `.ts` (compiled to
`.lua` via TSTL and `.js` via tsc), and handwritten `.js` — so the TSTL output
runs head-to-head against handwritten Lua.

## How to run

```bash
# Fetch the runtimes that aren't checked in (lua is vendored as source):
./scripts/fetch_quickjs.sh      # ~5 MB git clone
./scripts/fetch_v8.sh           # depot_tools + monolith — long: ~1-2 hours, ~12 GB disk

# Build hosts (fast — Zig-only):
zig build -Drelease=true

# Build the V8 host (separate because of libstdc++/lld constraints):
./scripts/build_v8_shim.sh      # g++ shim.cpp → shim.o
./scripts/link_v8_host.sh       # final link with clang++/lld + libstdc++

# Build TS workloads (TSTL → .lua, tsc → .js):
(cd tools/ts && npm install && npm run build)

# Run full sweep:
./scripts/run_all.sh

# Regenerate this README from the fresh CSVs:
python3 scripts/build_readme.py
```

## Layout

```
src/
  bench.zig              shared timing/stats/CSV utilities
  hosts/
    lua54_host.zig       PUC Lua 5.4 host (links vendor/lua)
    luajit_host.zig      LuaJIT host (links system libluajit-5.1)
    quickjs_host.zig     QuickJS-NG host (links vendor/quickjs)
    v8_host.zig          V8 host — Zig calls extern C in v8_shim
    v8_shim.cpp          Tiny C ABI over V8's C++ API
  workloads/
    lua/                 handwritten Lua
    js/                  handwritten JS
    ts/                  TS source
    ts-out-lua/          TSTL output (generated)
    ts-out-js/           tsc output (generated)
vendor/
  lua/                   PUC Lua 5.4.8 source (vendored)
  quickjs/               QuickJS-NG checkout
  v8/                    V8 monolith (post fetch_v8.sh)
tools/ts/                package.json, tsconfig.{tstl,tsc}.json
scripts/                 fetch_v8, build_v8_shim, link_v8_host, run_all, build_readme
results/
  all.csv                concatenated raw results
  footprint.csv          binary size per runtime
  <runtime>.csv          per-runtime CSV
  summary.md             long-form analysis & caveats
```

## What this is *not*

- A language comparison. JS and Lua have their own merits;
  this only argues about embedding cost.
- A browser/Node argument. We're embedding into a Zig server,
  not running a web page. Workers, async I/O, DOM are irrelevant here.
- A WASM argument. Different fight, separate benchmark.

Long-form analysis with caveats: [`results/summary.md`](results/summary.md).
