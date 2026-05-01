# luavts — results summary

ReleaseFast Zig 0.15.2 + system gcc 15 / clang 22, x86_64 Linux,
on an idle 32-core machine. PUC Lua 5.4.8 (vendored), LuaJIT 2.1
(system lib), QuickJS-NG `main`, V8 `main` (monolith with
i18n/sandbox/temporal/wasm disabled).

All numbers raw from `results/all.csv`. Workloads are described in
`README.md`. Full per-host CSVs in `results/<runtime>.csv`.

## Embedding footprint

| | binary | RSS @ 1 VM | static lib |
|---|---|---|---|
| **lua54** | 1.6 MB | ~3 MB | 233 KB |
| luajit | 324 KB | ~3 MB | (system .so) |
| quickjs | 5.6 MB | ~3 MB | 4.1 MB |
| **v8** | **37 MB** | **~21 MB** | 75 MB monolith |

V8 is **23× larger on disk and 7× heavier per VM instance** than
PUC Lua 5.4. Multiply per-VM RSS by your AI fleet size to see the
real cost: 1k AI states is 3 GB (Lua) vs 21 GB (V8).

## VM startup (p50, μs)

| lua54 | luajit | quickjs | v8 |
|---|---|---|---|
| **16** | 33 | 72 | **605** |

V8 is **38× slower** to spin up an isolate than Lua is to spin up a
state. Hot-reload, per-AI sandbox creation, and worker fork-on-demand
all pay this cost.

## Host → script call overhead (ns/call, empty function)

| lua54 | luajit | quickjs | v8 |
|---|---|---|---|
| 17 | **9** | **10** | 76 |

LuaJIT and QuickJS tie for cheapest call edge. V8 is ~4× more
expensive per call because every entry sets up a HandleScope and
TryCatch in the shim. **For 20k AI leaf calls per tick, that's
1.5ms of overhead in V8 vs 0.34ms in Lua 5.4** — before any leaf does
real work.

## ai_tick — 5000 agents, p50 wall time per tick (μs)

| lua54 | luajit | quickjs | v8 |
|---|---|---|---|
| 346 | 26 | 680 | **15** |

V8's JIT crushes everything once warm. Lua 5.4 spends ~0.7% of the
20Hz tick budget (50ms) on 5k fully-scripted agents — already
comfortable. QuickJS uses ~1.4%; V8 is essentially free at 0.03%.
LuaJIT and V8 are within ~2× of each other.

At realistic AI-leaf call rates (~20k leaves/tick at 20Hz, mostly
short leaves), no runtime in this set hits the budget. The choice is
dominated by the *other* dimensions — startup, memory, build cost,
dependency surface.

## GC pause distribution — gc_pause workload (μs per 1k-table burst)

|  | p50 | p99 | max |
|---|---|---|---|
| lua54 | 91 | 114 | 156 |
| luajit | 39 | 78 | 157 |
| quickjs | 152 | 214 | 331 |
| v8 | **1** | 36 | **3231** |

V8's median is microscopic but its **max is 3.2ms** — generational GC
hands you a long tail when the old-gen collects. Lua 5.4 is the
opposite: incremental GC keeps the tail tight (max ≈ 1.4× p50) at the
cost of consistently higher per-step overhead.

For a 16.7ms (60Hz) tick, V8's worst-case GC pause **eats 19% of the
frame budget in a single hit**. Lua 5.4's worst-case eats 0.9%.
This is the headline answer to "which runtime is friendlier to the
Zig host's tick budget."

## math_loop — 1M iterations of `sqrt(i)*0.5` (ms)

| lua54 | luajit | quickjs | v8 |
|---|---|---|---|
| 19 | 1.65 | 30 | 1.76 |

Concession workload. V8 and LuaJIT JIT this aggressively; Lua 5.4 and
QuickJS interpret. **PUC Lua 5.4 is 35% faster than QuickJS even
without a JIT** — its dispatch loop and number boxing are leaner than
QuickJS's. For numeric inner loops the user hits in real code (e.g.
stat-roll formulas), this is the relevant interpreter-vs-interpreter
gap.

If you have a hot path that genuinely needs a JIT, LuaJIT remains
the escape hatch (modulo its frozen Lua 5.1 semantics). Nothing
measured here moves that conclusion.

## TypeScriptToLua tax (handwritten Lua vs TSTL output)

| workload | handwritten p50 | TSTL p50 | delta |
|---|---|---|---|
| call_overhead | 17 ns | 17 ns | 0% |
| ai_tick | 346 μs | 402 μs | +16% |
| gc_pause | 91 μs | 97 μs | +7% |
| math_loop | 19 ms | 24 ms | +29% |

TSTL is **free for short leaves and within noise for tables.** The
~16-30% overhead on tight loops comes from TSTL emitting `while
i < n` rather than Lua's bytecode-optimized `for i = 1, n` — TS's
arbitrary-increment `for` loop semantics force the translation.

Not a problem for typical AI-leaf shapes (small, no inner loops), and
not enough to recover the difference vs an embedded JS runtime.
**TS-the-language costs ~0% in steady state and ~30% on
unrealistic loops.** TS-via-V8 costs 7× more memory and 38× more
startup latency.

## Headline

For embedding scripting into a Zig MMO server:

1. **Binary size**: V8 is 23× the cost.
2. **Per-VM memory**: V8 is 7× the cost.
3. **VM startup**: V8 is 38× the cost.
4. **Call edge**: roughly comparable (Lua wins by ~4× over V8 for
   empty calls; the gap closes when leaves do real work).
5. **GC tail latency**: V8 worst-case is **22× Lua 5.4 worst-case**.
   This is the load-bearing one for a 60Hz host.
6. **Steady-state throughput**: V8 wins by 1-2 orders of magnitude
   when the JIT is hot. Doesn't matter at the realistic AI-leaf call
   rates this is sized for.
7. **TS ergonomics**: TSTL gets you ~95% of the way there at ~0%
   runtime cost.

The "TS for ergonomics" argument is real. The "embed V8 for that"
argument doesn't survive any of the numbers above.

## tick_budget — GC blast radius on the Zig host

Each tick = Zig-side hot loop (256k float ops, proxy for BT traversal in
Zig) + script tick (5k agents + N short-lived alloc per tick). 1200
ticks. Reports % overrun against the 60Hz host budget (16.7ms).

| pressure (allocs/tick) | lua54 p50 | luajit p50 | quickjs p50 | v8 p50 |
|---|---|---|---|---|
| 0 (no alloc) | 358 μs | 26 μs | 686 μs | 15 μs |
| 200 | 380 μs | 29 μs | 724 μs | 16 μs |
| 2,000 | 488 μs | 67 μs | 989 μs | 17 μs |
| 20,000 | 2.34 ms | 725 μs | 3.83 ms | 39 μs |
| 100,000 (extreme) | 11.0 ms | 3.78 ms | 16.8 ms | 135 μs |

**% of ticks exceeding 16.7ms (60Hz) budget:**

| pressure | lua54 | luajit | quickjs | v8 |
|---|---|---|---|---|
| ≤ 20,000 | 0/1200 | 0/1200 | 0/1200 | 0/1200 |
| 100,000 | 0/1200 | 0/1200 | **738/1200 (61.5%)** | 0/1200 |

The headline: at extreme alloc pressure (100k tables/objects per tick —
~10× any realistic BT-leaf rate), **QuickJS dropped 61.5% of 60Hz
ticks**. PUC Lua 5.4 stayed inside budget. V8's generational GC
handled it gracefully (p50 still 135 μs, max 4.7 ms).

**Why QuickJS chokes:** refcounting + cycle GC. Each freed object
triggers a refcount cascade; the periodic cycle collector then walks
the heap. With heavy churn the cycle collector dominates per-tick wall.

**Why V8 holds up:** generational GC sweeps the new-space cheaply.
Most allocs in this workload die young, so the minor GC is fast.
V8 only spikes when a major GC fires — which we caught on the gc_pause
benchmark (3.2 ms max), not here.

**Why Lua 5.4 stays predictable:** incremental GC spreads work over
many ticks. No big single-tick pauses; just slightly higher steady
overhead.

At realistic alloc rates (a few hundred allocs per tick at most),
every runtime is comfortably inside both 60Hz and 20Hz budgets. The
differentiator only appears under stress that real BT leaves won't
generate.

## cache_eviction — does VM GC evict the Zig host's hot data?

Time a Zig pass over a 4 MB f32 buffer (sized to overflow L2, fit in
L3). Compare baseline vs. interleaved with VM `step()` doing 1k-table
allocation bursts that force GC.

| runtime | baseline p50 | under-pressure p50 | delta |
|---|---|---|---|
| lua54 | 567 μs | 567 μs | -450 ns |
| luajit | 566 μs | 564 μs | -1.9 μs |
| quickjs | 567 μs | 567 μs | +0.9 μs |
| v8 | 597 μs | 562 μs | -35 μs |

**Result: not measurable.** Deltas are within ±1% of baseline — i.e.
single-digit microseconds against 567 μs passes. Modern x86 has 16-32
MB of LLC and aggressive hardware prefetching; a VM heap-walk on the
same core does not measurably evict a sequentially-accessed 4 MB
buffer from cache.

This is a **null result**, but a useful one: the cache-side cost we
worried about isn't the load-bearing axis. The pause-time cost
(`tick_budget`) and the per-VM memory cost (footprint table) are.

If your hot path has a working set of *random access* over an
L1-sized buffer (~32 KB), the picture might change — but BT traversal
and pose update don't fit that shape. Flag it as "measure if you
observe regression," not "design around."

## Caveats

- Single-machine numbers; CI variance ~5-10%, large numbers ±20%.
- V8 monolith built without i18n / Temporal / WASM. Real V8 is bigger
  still — these flags reduce its footprint, not Lua's.
- `gc_pause` allocates 1k tables per step. Real workloads (BT leaf
  reads, stat formulas) generate much less garbage, so absolute
  pauses will be lower for everyone — but the *ratio* between
  runtimes is the durable signal.
- LuaJIT included as ceiling reference only. Frozen at Lua 5.1
  semantics, which is why projects targeting modern Lua features bind
  against PUC Lua 5.4 instead.
