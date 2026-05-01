//! LuaJIT 2.1 host. Lua 5.1 C API. Linked against system libluajit-5.1.
//!
//! Ceiling reference only — included so the perf headroom of the JIT
//! is visible against PUC Lua 5.4 (the committed runtime). LuaJIT is
//! frozen at Lua 5.1 semantics, which is why projects targeting modern
//! Lua features bind against PUC Lua instead.

const std = @import("std");
const bench = @import("bench");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

fn die(msg: []const u8) noreturn {
    std.debug.print("luajit_host: {s}\n", .{msg});
    std.process.exit(2);
}

fn lcheck(L: ?*c.lua_State, ok: c_int) void {
    if (ok != 0) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("luajit error: {s}\n", .{err});
        std.process.exit(2);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 3) die("usage: luajit_host <workload> <script_path> [variant] [pressure]");
    const workload = bench.Workload.fromArg(args[1]) orelse die("unknown workload");
    const script_path = args[2];
    const variant = if (args.len >= 4) args[3] else "handwritten";
    var params = bench.paramsFor(workload);
    if (workload == .tick_budget and args.len >= 5) {
        params.pressure = std.fmt.parseInt(u64, args[4], 10) catch die("bad pressure");
    }
    if (workload == .ai_tick and args.len >= 5) {
        params.n_agents = std.fmt.parseInt(u64, args[4], 10) catch die("bad n_agents");
    }

    if (workload == .vm_startup) {
        try runStartup(params);
        return;
    }

    const src = try bench.readScript(a, script_path);

    const L = c.luaL_newstate() orelse die("luaL_newstate");
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    pushParams(L, params);
    c.lua_setglobal(L, "PARAMS");

    lcheck(L, c.luaL_loadbuffer(L, src.ptr, src.len, "workload"));
    lcheck(L, c.lua_pcall(L, 0, 0, 0));

    c.lua_getglobal(L, "setup");
    if (c.lua_type(L, -1) == c.LUA_TFUNCTION) {
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
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

fn runOuter(L: ?*c.lua_State, workload: bench.Workload, variant: []const u8, p: bench.Params) !void {
    c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing global step()");
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    var w: u64 = 0;
    while (w < @min(p.outer_iters / 100, 10_000)) : (w += 1) {
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
    }

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
    }
    const t1 = bench.nowNs();

    const total = t1 - t0;
    const per = total / @max(p.outer_iters, 1);
    try bench.emitCsv(.{
        .runtime = "luajit",
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

fn runAiTick(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    c.lua_getglobal(L, "init_agents");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing init_agents");
    c.lua_pushinteger(L, @intCast(p.n_agents));
    lcheck(L, c.lua_pcall(L, 1, 0, 0));

    c.lua_getglobal(L, "tick");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing tick");
    const tick_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    var w: u64 = 0;
    while (w < 20) : (w += 1) {
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
    }

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const a0 = bench.nowNs();
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
        samples[i] = bench.nowNs() - a0;
    }
    const t1 = bench.nowNs();
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "luajit",
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

fn runGcPause(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("workload missing step()");
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const a0 = bench.nowNs();
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "luajit",
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

fn runTickBudget(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    c.lua_getglobal(L, "init_agents");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing init_agents");
    c.lua_pushinteger(L, @intCast(p.n_agents));
    lcheck(L, c.lua_pcall(L, 1, 0, 0));

    c.lua_getglobal(L, "tick");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing tick");
    const tick_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    const zig_buf = try a.alloc(f32, 1024);
    defer a.free(zig_buf);
    for (zig_buf, 0..) |*v, i| v.* = @floatFromInt(i & 0x7f);
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    var w: u64 = 0;
    while (w < 50) : (w += 1) {
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
    }

    var over_60: u64 = 0;
    var over_20: u64 = 0;
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, tick_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
        const dt = bench.nowNs() - t0;
        samples[i] = dt;
        if (dt > bench.TICK_BUDGET_NS_60HZ) over_60 += 1;
        if (dt > bench.TICK_BUDGET_NS_20HZ) over_20 += 1;
    }
    const stats = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "p={d} over60={d} over20={d}", .{ p.pressure, over_60, over_20 });

    try bench.emitCsv(.{
        .runtime = "luajit",
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

fn runCacheEviction(L: ?*c.lua_State, variant: []const u8, p: bench.Params) !void {
    c.lua_getglobal(L, "step");
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) die("missing step");
    const step_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const a = std.heap.page_allocator;
    const buf = try a.alloc(f32, bench.CACHE_BUF_FLOATS);
    defer a.free(buf);
    for (buf, 0..) |*v, i| v.* = @floatFromInt(i & 0xff);
    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    for (0..50) |_| std.mem.doNotOptimizeAway(bench.cachePass(buf));

    for (0..p.outer_iters) |i| {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const base = bench.summarize(samples);
    try bench.emitCsv(.{
        .runtime = "luajit",
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

    for (0..50) |_| {
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
    }

    for (0..p.outer_iters) |i| {
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, step_ref);
        lcheck(L, c.lua_pcall(L, 0, 0, 0));
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const press = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "phase=vm_pressure delta_p50_ns={d}", .{@as(i64, @intCast(press.p50)) - @as(i64, @intCast(base.p50))});

    try bench.emitCsv(.{
        .runtime = "luajit",
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
        .runtime = "luajit",
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
