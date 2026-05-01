//! PUC Lua 5.4 host. Loads a workload script that defines globals
//! `setup(params)` and `step()`, runs `step` N times, emits a CSV row.
//!
//! Usage: lua54_host <workload> <script_path> [variant]

const std = @import("std");
const bench = @import("bench");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

fn die(msg: []const u8) noreturn {
    std.debug.print("lua54_host: {s}\n", .{msg});
    std.process.exit(2);
}

fn lcheck(L: ?*c.lua_State, ok: c_int) void {
    if (ok != c.LUA_OK) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("lua error: {s}\n", .{err});
        std.process.exit(2);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 3) die("usage: lua54_host <workload> <script_path> [variant] [pressure]");
    const workload_str = args[1];
    const script_path = args[2];
    const variant = if (args.len >= 4) args[3] else "handwritten";

    const workload = bench.Workload.fromArg(workload_str) orelse die("unknown workload");
    var params = bench.paramsFor(workload);
    if (workload == .tick_budget and args.len >= 5) {
        params.pressure = std.fmt.parseInt(u64, args[4], 10) catch die("bad pressure");
    }
    if (workload == .ai_tick and args.len >= 5) {
        params.n_agents = std.fmt.parseInt(u64, args[4], 10) catch die("bad n_agents");
    }

    // ---- vm_startup is special: time create/teardown, no script work ----
    if (workload == .vm_startup) {
        try runStartup(params);
        return;
    }

    const src = try bench.readScript(a, script_path);

    const L = c.luaL_newstate() orelse die("luaL_newstate");
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    // Push params as a global table BEFORE loading the chunk.
    pushParams(L, params);
    c.lua_setglobal(L, "PARAMS");

    // Load + run the chunk to define globals.
    lcheck(L, c.luaL_loadbufferx(L, src.ptr, src.len, "workload", null));
    lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));

    // Call setup() if present.
    _ = c.lua_getglobal(L, "setup");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    } else {
        c.lua_settop(L, -2);
    }

    switch (workload) {
        .call_overhead, .math_loop => try runOuter(L, workload, variant, params),
        .ai_tick => try runAiTick(L, variant, params),
        .gc_pause => try runGcPause(L, variant, params),
        .tick_budget => try runTickBudget(L, variant, params),
        .cache_eviction => try runCacheEviction(L, variant, params),
        .vm_startup => unreachable,
    }
}

fn pushParams(L: ?*c.lua_State, p: bench.Params) void {
    c.lua_createtable(L, 0, 5);
    c.lua_pushinteger(L, @intCast(p.outer_iters));
    c.lua_setfield(L, -2, "outer_iters");
    c.lua_pushinteger(L, @intCast(p.inner_iters));
    c.lua_setfield(L, -2, "inner_iters");
    c.lua_pushinteger(L, @intCast(p.n_agents));
    c.lua_setfield(L, -2, "n_agents");
    c.lua_pushinteger(L, @intCast(p.n_ticks));
    c.lua_setfield(L, -2, "n_ticks");
    c.lua_pushinteger(L, @intCast(p.pressure));
    c.lua_setfield(L, -2, "pressure");
}

/// Generic outer-loop runner. step() called params.outer_iters times,
/// total time recorded. Per-call latency = total / iters.
fn runOuter(L: ?*c.lua_State, workload: bench.Workload, variant: []const u8, p: bench.Params) !void {
    _ = c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing global step()");
    // Stash step at registry index for fast retrieval.
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    // Warmup
    var w: u64 = 0;
    while (w < @min(p.outer_iters / 100, 10_000)) : (w += 1) {
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    }

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    }
    const t1 = bench.nowNs();

    const total = t1 - t0;
    const per = total / @max(p.outer_iters, 1);
    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = @tagName(workload),
        .variant = variant,
        .iters = p.outer_iters,
        .total_ns = total,
        .min_ns = per,
        .p50_ns = per,
        .p95_ns = per,
        .p99_ns = per,
        .max_ns = per,
        .rss_kb = bench.rssKb(),
    });
}

/// AI tick: workload defines init_agents(n) and tick(). Host runs tick
/// `n_ticks` times and records per-tick latencies.
fn runAiTick(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    // init_agents(n_agents)
    _ = c.lua_getglobal(L, "init_agents");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing init_agents");
    c.lua_pushinteger(L, @intCast(p.n_agents));
    lcheck(L, c.lua_pcallk(L, 1, 0, 0, 0, null));

    _ = c.lua_getglobal(L, "tick");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing tick");
    const tick_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    // warmup
    var w: u64 = 0;
    while (w < 20) : (w += 1) {
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    }

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const a0 = bench.nowNs();
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
        samples[i] = bench.nowNs() - a0;
    }
    const t1 = bench.nowNs();
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "ai_tick",
        .variant = variant,
        .iters = p.n_ticks,
        .total_ns = t1 - t0,
        .min_ns = stats.min,
        .p50_ns = stats.p50,
        .p95_ns = stats.p95,
        .p99_ns = stats.p99,
        .max_ns = stats.max,
        .rss_kb = bench.rssKb(),
    });
}

/// GC pause: workload defines step() that allocates inner_iters tables;
/// host samples per-step time and reports p99 (steady-state pause).
fn runGcPause(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    _ = c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing step()");
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const a0 = bench.nowNs();
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "gc_pause",
        .variant = variant,
        .iters = p.outer_iters,
        .total_ns = 0,
        .min_ns = stats.min,
        .p50_ns = stats.p50,
        .p95_ns = stats.p95,
        .p99_ns = stats.p99,
        .max_ns = stats.max,
        .rss_kb = bench.rssKb(),
    });
}

/// tick_budget: simulates a Zig host tick — Zig-side hot loop + script
/// tick under alloc pressure. Reports per-tick latency vs 60Hz/20Hz
/// budgets so GC blast radius is visible as % overrun.
fn runTickBudget(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    _ = c.lua_getglobal(L, "init_agents");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing init_agents");
    c.lua_pushinteger(L, @intCast(p.n_agents));
    lcheck(L, c.lua_pcallk(L, 1, 0, 0, 0, null));

    _ = c.lua_getglobal(L, "tick");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing tick");
    const tick_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    const zig_buf = try a.alloc(f32, 1024);
    defer a.free(zig_buf);
    for (zig_buf, 0..) |*v, i| v.* = @floatFromInt(i & 0x7f);

    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    // Warmup
    var w: u64 = 0;
    while (w < 50) : (w += 1) {
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    }

    var over_60: u64 = 0;
    var over_20: u64 = 0;
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
        const dt = bench.nowNs() - t0;
        samples[i] = dt;
        if (dt > bench.TICK_BUDGET_NS_60HZ) over_60 += 1;
        if (dt > bench.TICK_BUDGET_NS_20HZ) over_20 += 1;
    }
    const stats = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "p={d} over60={d} over20={d}", .{ p.pressure, over_60, over_20 });

    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "tick_budget",
        .variant = variant,
        .iters = p.n_ticks,
        .total_ns = 0,
        .min_ns = stats.min,
        .p50_ns = stats.p50,
        .p95_ns = stats.p95,
        .p99_ns = stats.p99,
        .max_ns = stats.max,
        .rss_kb = bench.rssKb(),
        .notes = notes,
    });
}

/// cache_eviction: emits two CSV rows.
///   "baseline" — pass over Zig hot buffer in a tight loop, no VM activity.
///   "vm_pressure" — same pass, but interleaved with VM step() that
///                   allocates aggressively (forcing GC heap walks).
/// (vm_pressure_p50 - baseline_p50) is the per-pass cache eviction tax.
fn runCacheEviction(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    _ = c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing step");
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    const buf = try a.alloc(f32, bench.CACHE_BUF_FLOATS);
    defer a.free(buf);
    for (buf, 0..) |*v, i| v.* = @floatFromInt(i & 0xff);

    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    // Warmup cache.
    for (0..50) |_| std.mem.doNotOptimizeAway(bench.cachePass(buf));

    // Phase 1: baseline (no VM)
    for (0..p.outer_iters) |i| {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const base = bench.summarize(samples);
    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "cache_eviction",
        .variant = variant,
        .iters = p.outer_iters,
        .total_ns = 0,
        .min_ns = base.min,
        .p50_ns = base.p50,
        .p95_ns = base.p95,
        .p99_ns = base.p99,
        .max_ns = base.max,
        .rss_kb = bench.rssKb(),
        .notes = "phase=baseline",
    });

    // Phase 2: under VM pressure
    for (0..50) |_| {
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
    }

    for (0..p.outer_iters) |i| {
        // VM step first → its GC walks the Lua heap, evicting the f32 buf.
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcallk(L, 0, 0, 0, 0, null));
        // Then time the buf pass — cache is now cold from the GC.
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const press = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(
        &notes_buf,
        "phase=vm_pressure delta_p50_ns={d}",
        .{@as(i64, @intCast(press.p50)) - @as(i64, @intCast(base.p50))},
    );

    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "cache_eviction",
        .variant = variant,
        .iters = p.outer_iters,
        .total_ns = 0,
        .min_ns = press.min,
        .p50_ns = press.p50,
        .p95_ns = press.p95,
        .p99_ns = press.p99,
        .max_ns = press.max,
        .rss_kb = bench.rssKb(),
        .notes = notes,
    });
}

/// vm_startup: create + open libs + close, no script. Pure embedding cost.
fn runStartup(p: bench.Params) !void {
    const allocator = std.heap.page_allocator;
    var samples = try allocator.alloc(u64, p.outer_iters);
    defer allocator.free(samples);

    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const a0 = bench.nowNs();
        const L = c.luaL_newstate() orelse die("luaL_newstate");
        c.luaL_openlibs(L);
        c.lua_close(L);
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);
    try bench.emitCsv(.{
        .runtime = "lua54",
        .workload = "vm_startup",
        .variant = "n/a",
        .iters = p.outer_iters,
        .total_ns = 0,
        .min_ns = stats.min,
        .p50_ns = stats.p50,
        .p95_ns = stats.p95,
        .p99_ns = stats.p99,
        .max_ns = stats.max,
        .rss_kb = bench.rssKb(),
    });
}
