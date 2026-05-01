//! QuickJS-NG host. The realistic embeddable-JS comparison: small,
//! pure C, no JIT. Linked against vendored vendor/quickjs.

const std = @import("std");
const bench = @import("bench");

const c = @cImport({
    @cInclude("quickjs.h");
});

fn die(msg: []const u8) noreturn {
    std.debug.print("quickjs_host: {s}\n", .{msg});
    std.process.exit(2);
}

fn checkExc(ctx: *c.JSContext, v: c.JSValue) c.JSValue {
    if (c.JS_IsException(v)) {
        const exc = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exc);
        const s = c.JS_ToCString(ctx, exc);
        std.debug.print("js exception: {s}\n", .{s});
        c.JS_FreeCString(ctx, s);
        std.process.exit(2);
    }
    return v;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 3) die("usage: quickjs_host <workload> <script_path> [variant] [pressure]");
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

    // Load script + null-terminate for JS_Eval.
    const src = try bench.readScript(a, script_path);
    const src_z = try a.allocSentinel(u8, src.len, 0);
    @memcpy(src_z, src);

    const rt = c.JS_NewRuntime() orelse die("JS_NewRuntime");
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse die("JS_NewContext");
    defer c.JS_FreeContext(ctx);

    // Install PARAMS as a global object before evaluating the script.
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    {
        const p = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, p, "outer_iters", c.JS_NewInt64(ctx, @intCast(params.outer_iters)));
        _ = c.JS_SetPropertyStr(ctx, p, "inner_iters", c.JS_NewInt64(ctx, @intCast(params.inner_iters)));
        _ = c.JS_SetPropertyStr(ctx, p, "n_agents", c.JS_NewInt64(ctx, @intCast(params.n_agents)));
        _ = c.JS_SetPropertyStr(ctx, p, "n_ticks", c.JS_NewInt64(ctx, @intCast(params.n_ticks)));
        _ = c.JS_SetPropertyStr(ctx, p, "pressure", c.JS_NewInt64(ctx, @intCast(params.pressure)));
        _ = c.JS_SetPropertyStr(ctx, global, "PARAMS", p);
    }

    const eval_res = c.JS_Eval(ctx, src_z.ptr, src.len, "workload", c.JS_EVAL_TYPE_GLOBAL);
    _ = checkExc(ctx, eval_res);
    c.JS_FreeValue(ctx, eval_res);

    // setup() if defined
    {
        const setup_fn = c.JS_GetPropertyStr(ctx, global, "setup");
        defer c.JS_FreeValue(ctx, setup_fn);
        if (c.JS_IsFunction(ctx, setup_fn)) {
            const r = c.JS_Call(ctx, setup_fn, global, 0, null);
            _ = checkExc(ctx, r);
            c.JS_FreeValue(ctx, r);
        }
    }

    switch (workload) {
        .call_overhead, .math_loop => try runOuter(ctx, global, workload, variant, params),
        .ai_tick => try runAiTick(ctx, global, variant, params),
        .gc_pause => try runGcPause(ctx, global, variant, params),
        .tick_budget => try runTickBudget(ctx, global, variant, params),
        .cache_eviction => try runCacheEviction(ctx, global, variant, params),
        .vm_startup => unreachable,
    }
}

fn runOuter(ctx: *c.JSContext, global: c.JSValue, workload: bench.Workload, variant: []const u8, p: bench.Params) !void {
    const step_fn = c.JS_GetPropertyStr(ctx, global, "step");
    defer c.JS_FreeValue(ctx, step_fn);
    if (!c.JS_IsFunction(ctx, step_fn)) die("workload missing step()");

    var w: u64 = 0;
    while (w < @min(p.outer_iters / 100, 10_000)) : (w += 1) {
        const r = c.JS_Call(ctx, step_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
    }

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const r = c.JS_Call(ctx, step_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
    }
    const t1 = bench.nowNs();

    const total = t1 - t0;
    const per = total / @max(p.outer_iters, 1);
    try bench.emitCsv(.{
        .runtime = "quickjs",
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

fn runAiTick(ctx: *c.JSContext, global: c.JSValue, variant: []const u8, p: bench.Params) !void {
    const init_fn = c.JS_GetPropertyStr(ctx, global, "init_agents");
    defer c.JS_FreeValue(ctx, init_fn);
    if (!c.JS_IsFunction(ctx, init_fn)) die("missing init_agents");

    var argv = [_]c.JSValue{c.JS_NewInt64(ctx, @intCast(p.n_agents))};
    const ir = c.JS_Call(ctx, init_fn, global, 1, &argv);
    _ = checkExc(ctx, ir);
    c.JS_FreeValue(ctx, ir);

    const tick_fn = c.JS_GetPropertyStr(ctx, global, "tick");
    defer c.JS_FreeValue(ctx, tick_fn);
    if (!c.JS_IsFunction(ctx, tick_fn)) die("missing tick");

    var w: u64 = 0;
    while (w < 20) : (w += 1) {
        const r = c.JS_Call(ctx, tick_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
    }

    const allocator = std.heap.page_allocator;
    var samples = try allocator.alloc(u64, p.n_ticks);
    defer allocator.free(samples);

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const a0 = bench.nowNs();
        const r = c.JS_Call(ctx, tick_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
        samples[i] = bench.nowNs() - a0;
    }
    const t1 = bench.nowNs();
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "quickjs",
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

fn runGcPause(ctx: *c.JSContext, global: c.JSValue, variant: []const u8, p: bench.Params) !void {
    const step_fn = c.JS_GetPropertyStr(ctx, global, "step");
    defer c.JS_FreeValue(ctx, step_fn);
    if (!c.JS_IsFunction(ctx, step_fn)) die("missing step");

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const a0 = bench.nowNs();
        const r = c.JS_Call(ctx, step_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "quickjs",
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

fn runTickBudget(ctx: *c.JSContext, global: c.JSValue, variant: []const u8, p: bench.Params) !void {
    const init_fn = c.JS_GetPropertyStr(ctx, global, "init_agents");
    defer c.JS_FreeValue(ctx, init_fn);
    if (!c.JS_IsFunction(ctx, init_fn)) die("missing init_agents");
    var argv = [_]c.JSValue{c.JS_NewInt64(ctx, @intCast(p.n_agents))};
    const ir = c.JS_Call(ctx, init_fn, global, 1, &argv);
    _ = checkExc(ctx, ir);
    c.JS_FreeValue(ctx, ir);

    const tick_fn = c.JS_GetPropertyStr(ctx, global, "tick");
    defer c.JS_FreeValue(ctx, tick_fn);
    if (!c.JS_IsFunction(ctx, tick_fn)) die("missing tick");

    const a = std.heap.page_allocator;
    const zig_buf = try a.alloc(f32, 1024);
    defer a.free(zig_buf);
    for (zig_buf, 0..) |*v, i| v.* = @floatFromInt(i & 0x7f);
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    var w: u64 = 0;
    while (w < 50) : (w += 1) {
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        const r = c.JS_Call(ctx, tick_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
    }

    var over_60: u64 = 0;
    var over_20: u64 = 0;
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        const r = c.JS_Call(ctx, tick_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
        const dt = bench.nowNs() - t0;
        samples[i] = dt;
        if (dt > bench.TICK_BUDGET_NS_60HZ) over_60 += 1;
        if (dt > bench.TICK_BUDGET_NS_20HZ) over_20 += 1;
    }
    const stats = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "p={d} over60={d} over20={d}", .{ p.pressure, over_60, over_20 });

    try bench.emitCsv(.{
        .runtime = "quickjs",
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

fn runCacheEviction(ctx: *c.JSContext, global: c.JSValue, variant: []const u8, p: bench.Params) !void {
    const step_fn = c.JS_GetPropertyStr(ctx, global, "step");
    defer c.JS_FreeValue(ctx, step_fn);
    if (!c.JS_IsFunction(ctx, step_fn)) die("missing step");

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
        .runtime = "quickjs",
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
        const r = c.JS_Call(ctx, step_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
    }

    for (0..p.outer_iters) |i| {
        const r = c.JS_Call(ctx, step_fn, global, 0, null);
        c.JS_FreeValue(ctx, r);
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const press = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "phase=vm_pressure delta_p50_ns={d}", .{@as(i64, @intCast(press.p50)) - @as(i64, @intCast(base.p50))});

    try bench.emitCsv(.{
        .runtime = "quickjs",
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
        const rt = c.JS_NewRuntime() orelse die("JS_NewRuntime");
        const ctx = c.JS_NewContext(rt) orelse die("JS_NewContext");
        c.JS_FreeContext(ctx);
        c.JS_FreeRuntime(rt);
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);
    try bench.emitCsv(.{
        .runtime = "quickjs",
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
