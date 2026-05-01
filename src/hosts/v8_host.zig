//! V8 host. Talks to the C ABI exposed by v8_shim.cpp. Same workload
//! protocol as the other hosts.

const std = @import("std");
const bench = @import("bench");

extern fn lvts_init() void;
extern fn lvts_shutdown() void;
extern fn lvts_create() ?*anyopaque;
extern fn lvts_destroy(handle: ?*anyopaque) void;
extern fn lvts_set_params(handle: ?*anyopaque, outer: i64, inner: i64, n_agents: i64, n_ticks: i64, pressure: i64) void;
extern fn lvts_eval(handle: ?*anyopaque, src: [*]const u8, len: usize) c_int;
extern fn lvts_get_fn(handle: ?*anyopaque, name: [*:0]const u8) c_int;
extern fn lvts_call_void(handle: ?*anyopaque, fn_idx: c_int) c_int;
extern fn lvts_call_int(handle: ?*anyopaque, fn_idx: c_int, arg: i64) c_int;

fn die(msg: []const u8) noreturn {
    std.debug.print("v8_host: {s}\n", .{msg});
    std.process.exit(2);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 3) die("usage: v8_host <workload> <script_path> [variant] [pressure]");
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

    lvts_init();
    defer lvts_shutdown();

    if (workload == .vm_startup) {
        try runStartup(params);
        return;
    }

    const src = try bench.readScript(a, script_path);

    const vm = lvts_create() orelse die("lvts_create");
    defer lvts_destroy(vm);

    lvts_set_params(vm, @intCast(params.outer_iters), @intCast(params.inner_iters), @intCast(params.n_agents), @intCast(params.n_ticks), @intCast(params.pressure));
    if (lvts_eval(vm, src.ptr, src.len) != 0) die("eval failed");

    // setup() if defined
    {
        const idx = lvts_get_fn(vm, "setup");
        if (idx >= 0) _ = lvts_call_void(vm, idx);
    }

    switch (workload) {
        .call_overhead, .math_loop => try runOuter(vm, workload, variant, params),
        .ai_tick => try runAiTick(vm, variant, params),
        .gc_pause => try runGcPause(vm, variant, params),
        .tick_budget => try runTickBudget(vm, variant, params),
        .cache_eviction => try runCacheEviction(vm, variant, params),
        .vm_startup => unreachable,
    }
}

fn runOuter(vm: *anyopaque, workload: bench.Workload, variant: []const u8, p: bench.Params) !void {
    const step_idx = lvts_get_fn(vm, "step");
    if (step_idx < 0) die("missing step");

    // Warmup so JIT has a chance to optimize.
    var w: u64 = 0;
    while (w < @min(p.outer_iters / 100, 100_000)) : (w += 1) {
        _ = lvts_call_void(vm, step_idx);
    }

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        _ = lvts_call_void(vm, step_idx);
    }
    const t1 = bench.nowNs();

    const total = t1 - t0;
    const per = total / @max(p.outer_iters, 1);
    try bench.emitCsv(.{
        .runtime = "v8",
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

fn runAiTick(vm: *anyopaque, variant: []const u8, p: bench.Params) !void {
    const init_idx = lvts_get_fn(vm, "init_agents");
    if (init_idx < 0) die("missing init_agents");
    if (lvts_call_int(vm, init_idx, @intCast(p.n_agents)) != 0) die("init_agents failed");

    const tick_idx = lvts_get_fn(vm, "tick");
    if (tick_idx < 0) die("missing tick");

    // warmup so V8's optimizing tiers kick in
    var w: u64 = 0;
    while (w < 50) : (w += 1) {
        _ = lvts_call_void(vm, tick_idx);
    }

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    const t0 = bench.nowNs();
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const a0 = bench.nowNs();
        _ = lvts_call_void(vm, tick_idx);
        samples[i] = bench.nowNs() - a0;
    }
    const t1 = bench.nowNs();
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "v8",
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

fn runGcPause(vm: *anyopaque, variant: []const u8, p: bench.Params) !void {
    const step_idx = lvts_get_fn(vm, "step");
    if (step_idx < 0) die("missing step");

    const a = std.heap.page_allocator;
    var samples = try a.alloc(u64, p.outer_iters);
    defer a.free(samples);

    var i: u64 = 0;
    while (i < p.outer_iters) : (i += 1) {
        const a0 = bench.nowNs();
        _ = lvts_call_void(vm, step_idx);
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);

    try bench.emitCsv(.{
        .runtime = "v8",
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

fn runTickBudget(vm: *anyopaque, variant: []const u8, p: bench.Params) !void {
    const init_idx = lvts_get_fn(vm, "init_agents");
    if (init_idx < 0) die("missing init_agents");
    if (lvts_call_int(vm, init_idx, @intCast(p.n_agents)) != 0) die("init_agents failed");

    const tick_idx = lvts_get_fn(vm, "tick");
    if (tick_idx < 0) die("missing tick");

    const a = std.heap.page_allocator;
    const zig_buf = try a.alloc(f32, 1024);
    defer a.free(zig_buf);
    for (zig_buf, 0..) |*v, i| v.* = @floatFromInt(i & 0x7f);
    var samples = try a.alloc(u64, p.n_ticks);
    defer a.free(samples);

    // Long warmup so V8's optimizer settles.
    var w: u64 = 0;
    while (w < 200) : (w += 1) {
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        _ = lvts_call_void(vm, tick_idx);
    }

    var over_60: u64 = 0;
    var over_20: u64 = 0;
    var i: u64 = 0;
    while (i < p.n_ticks) : (i += 1) {
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.zigEngineWork(zig_buf));
        _ = lvts_call_void(vm, tick_idx);
        const dt = bench.nowNs() - t0;
        samples[i] = dt;
        if (dt > bench.TICK_BUDGET_NS_60HZ) over_60 += 1;
        if (dt > bench.TICK_BUDGET_NS_20HZ) over_20 += 1;
    }
    const stats = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "p={d} over60={d} over20={d}", .{ p.pressure, over_60, over_20 });

    try bench.emitCsv(.{
        .runtime = "v8",
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

fn runCacheEviction(vm: *anyopaque, variant: []const u8, p: bench.Params) !void {
    const step_idx = lvts_get_fn(vm, "step");
    if (step_idx < 0) die("missing step");

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
        .runtime = "v8",
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

    for (0..200) |_| {
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        _ = lvts_call_void(vm, step_idx);
    }

    for (0..p.outer_iters) |i| {
        _ = lvts_call_void(vm, step_idx);
        const t0 = bench.nowNs();
        std.mem.doNotOptimizeAway(bench.cachePass(buf));
        samples[i] = bench.nowNs() - t0;
    }
    const press = bench.summarize(samples);

    var notes_buf: [128]u8 = undefined;
    const notes = try std.fmt.bufPrint(&notes_buf, "phase=vm_pressure delta_p50_ns={d}", .{@as(i64, @intCast(press.p50)) - @as(i64, @intCast(base.p50))});

    try bench.emitCsv(.{
        .runtime = "v8",
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
        const vm = lvts_create() orelse die("lvts_create");
        lvts_destroy(vm);
        samples[i] = bench.nowNs() - a0;
    }
    const stats = bench.summarize(samples);
    try bench.emitCsv(.{
        .runtime = "v8",
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
