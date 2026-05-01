//! Shared benchmark harness: monotonic timing, sample stats, RSS read,
//! CSV row emission. Each host imports this and orchestrates its own
//! runtime around `Sample`/`run`.

const std = @import("std");

pub const Sample = struct {
    runtime: []const u8,
    workload: []const u8,
    variant: []const u8, // "handwritten" | "tstl" | "tsc"
    iters: u64,
    total_ns: u64,
    min_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    rss_kb: u64,
    notes: []const u8 = "",
};

pub fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Read VmRSS from /proc/self/status in KB. Returns 0 on non-Linux or read failure.
pub fn rssKb() u64 {
    var buf: [4096]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
    defer f.close();
    const n = f.read(&buf) catch return 0;
    const text = buf[0..n];
    const key = "VmRSS:";
    const idx = std.mem.indexOf(u8, text, key) orelse return 0;
    var i = idx + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    var j = i;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    if (j == i) return 0;
    return std.fmt.parseInt(u64, text[i..j], 10) catch 0;
}

/// Sort `samples` ascending and compute summary stats.
pub fn summarize(samples: []u64) struct { min: u64, p50: u64, p95: u64, p99: u64, max: u64 } {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;
    if (n == 0) return .{ .min = 0, .p50 = 0, .p95 = 0, .p99 = 0, .max = 0 };
    return .{
        .min = samples[0],
        .p50 = samples[n / 2],
        .p95 = samples[(n * 95) / 100],
        .p99 = samples[(n * 99) / 100],
        .max = samples[n - 1],
    };
}

/// Emit a CSV row to stdout. The driver script (run_all.sh) tees these
/// per-host into results/<runtime>.csv.
pub fn emitCsv(s: Sample) !void {
    var stdout_buf: [1024]u8 = undefined;
    const stdout = std.fs.File.stdout();
    const w = try std.fmt.bufPrint(
        &stdout_buf,
        "{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{s}\n",
        .{
            s.runtime,
            s.workload,
            s.variant,
            s.iters,
            s.total_ns,
            s.min_ns,
            s.p50_ns,
            s.p95_ns,
            s.p99_ns,
            s.max_ns,
            s.rss_kb,
            s.notes,
        },
    );
    _ = try stdout.write(w);
}

pub fn emitCsvHeader() !void {
    const stdout = std.fs.File.stdout();
    _ = try stdout.write("runtime,workload,variant,iters,total_ns,min_ns,p50_ns,p95_ns,p99_ns,max_ns,rss_kb,notes\n");
}

/// Read a workload script file into an allocator-owned buffer.
pub fn readScript(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

/// Workload selectors. Each host parses argv[1] into one of these.
pub const Workload = enum {
    call_overhead,
    ai_tick,
    vm_startup,
    gc_pause,
    math_loop,
    tick_budget,
    cache_eviction,

    pub fn fromArg(s: []const u8) ?Workload {
        if (std.mem.eql(u8, s, "call_overhead")) return .call_overhead;
        if (std.mem.eql(u8, s, "ai_tick")) return .ai_tick;
        if (std.mem.eql(u8, s, "vm_startup")) return .vm_startup;
        if (std.mem.eql(u8, s, "gc_pause")) return .gc_pause;
        if (std.mem.eql(u8, s, "math_loop")) return .math_loop;
        if (std.mem.eql(u8, s, "tick_budget")) return .tick_budget;
        if (std.mem.eql(u8, s, "cache_eviction")) return .cache_eviction;
        return null;
    }
};

/// Standard workload parameters. Hosts call `paramsFor(workload)` and
/// pass the results into the script via numeric globals or a config
/// table — runtime-dependent, see each host.
pub const Params = struct {
    /// outer-loop iteration count (host → script calls)
    outer_iters: u64,
    /// inner-loop count (script-side work per call)
    inner_iters: u64,
    /// number of agents for ai_tick
    n_agents: u64,
    /// number of ticks for ai_tick (1200 = 1 minute @ 20Hz)
    n_ticks: u64,
    /// alloc pressure (tables/objects per tick) — tick_budget only
    pressure: u64 = 0,
};

pub fn paramsFor(w: Workload) Params {
    return switch (w) {
        .call_overhead => .{ .outer_iters = 1_000_000, .inner_iters = 0, .n_agents = 0, .n_ticks = 0 },
        .ai_tick => .{ .outer_iters = 1, .inner_iters = 0, .n_agents = 5_000, .n_ticks = 1_200 },
        .vm_startup => .{ .outer_iters = 1_000, .inner_iters = 0, .n_agents = 0, .n_ticks = 0 },
        .gc_pause => .{ .outer_iters = 1_200, .inner_iters = 1_000, .n_agents = 0, .n_ticks = 0 },
        .math_loop => .{ .outer_iters = 100, .inner_iters = 1_000_000, .n_agents = 0, .n_ticks = 0 },
        .tick_budget => .{ .outer_iters = 0, .inner_iters = 0, .n_agents = 5_000, .n_ticks = 1_200 },
        // cache_eviction: 500 iters, each allocates inner_iters tables.
        .cache_eviction => .{ .outer_iters = 500, .inner_iters = 1_000, .n_agents = 0, .n_ticks = 0 },
    };
}

/// Cache buffer: 4 MB. Bigger than typical L2 (1 MB), smaller than
/// typical LLC (8-32 MB). Fits in L3 fully when nothing else competes;
/// gets evicted to memory when a VM GC walks a multi-MB heap on the
/// same core. The eviction-tax delta surfaces against this contention.
pub const CACHE_BUF_FLOATS: usize = 1024 * 1024; // 4 MB

/// One pass over the buffer: read + multiply-accumulate. Returns a sum
/// the caller should consume so the optimizer doesn't elide the touch.
pub fn cachePass(buf: []f32) f32 {
    var s: f32 = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const v = buf[i];
        buf[i] = v * 1.0001 + 0.001;
        s += buf[i];
    }
    return s;
}

/// Tick budget: 50ms (20Hz). 60Hz host (16.7ms) reported separately.
pub const TICK_BUDGET_NS_20HZ: u64 = 50_000_000;
pub const TICK_BUDGET_NS_60HZ: u64 = 16_666_666;

/// Zig-side "engine work" simulated per tick. Single-pass over a fixed
/// buffer; deterministic and CPU-bound. Returns a side-effect sum that
/// the caller should consume so the optimizer can't elide the work.
pub fn zigEngineWork(buf: []f32) f32 {
    var s: f32 = 0;
    for (buf, 0..) |v, i| {
        const x = v + @as(f32, @floatFromInt(i & 0xff)) * 0.001;
        s += x * x;
    }
    return s;
}

/// Stats for a tick_budget run, beyond plain percentiles.
pub const TickBudgetStats = struct {
    p50: u64,
    p99: u64,
    max: u64,
    over_60hz: u64,
    over_20hz: u64,
    n: u64,

    pub fn fmtNotes(self: TickBudgetStats, out: []u8) ![]u8 {
        return std.fmt.bufPrint(
            out,
            "over60={d}/{d} over20={d}/{d}",
            .{ self.over_60hz, self.n, self.over_20hz, self.n },
        );
    }
};
