const std = @import("std");
const builtin = @import("builtin");

const lua_root = "vendor/lua";
const quickjs_root = "vendor/quickjs";
const v8_root = "vendor/v8/v8";

pub fn build(b: *std.Build) void {
    // Pin glibc_version on Linux: Zig 0.15 + gcc 15's .sframe relocations
    // in /usr/lib/Scrt1.o trip the bundled LLD.
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // ---- shared bench module ----
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- PUC Lua 5.4 (vendored) ----
    const lua_lib = buildLua(b, target, optimize) catch @panic("lua source enumeration failed");

    {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/hosts/lua54_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe_mod.addIncludePath(b.path(lua_root ++ "/src"));
        exe_mod.addImport("bench", bench_mod);
        const exe = b.addExecutable(.{ .name = "lua54_host", .root_module = exe_mod });
        exe.linkLibrary(lua_lib);
        b.installArtifact(exe);
    }

    // ---- LuaJIT (system lib; ceiling reference) ----
    {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/hosts/luajit_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Arch ships luajit-2.1 headers under /usr/include/luajit-2.1.
        // Pinned glibc makes Zig treat as cross-compile; add system lib dir
        // back so linkSystemLibrary can resolve libluajit-5.1.
        exe_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe_mod.addImport("bench", bench_mod);
        const exe = b.addExecutable(.{ .name = "luajit_host", .root_module = exe_mod });
        exe.linkSystemLibrary("luajit-5.1");
        b.installArtifact(exe);
    }

    // ---- QuickJS-NG (vendored; only built if vendor/quickjs exists) ----
    if (dirExists(b, quickjs_root)) {
        const qjs_lib = buildQuickJS(b, target, optimize) catch @panic("quickjs build failed");
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/hosts/quickjs_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe_mod.addIncludePath(b.path(quickjs_root));
        exe_mod.addImport("bench", bench_mod);
        const exe = b.addExecutable(.{ .name = "quickjs_host", .root_module = exe_mod });
        exe.linkLibrary(qjs_lib);
        b.installArtifact(exe);
    }

    // ---- V8 (vendored monolith; only wired if scripts/fetch_v8.sh has run) ----
    //
    // V8 is built with libstdc++ (use_custom_libcxx=false in args.gn). Zig's
    // C++ pipeline links libc++ unconditionally when it sees C++ symbols,
    // producing mangling mismatches (NSt3__1 vs St). To dodge that we:
    //   1. Compile v8_host.zig to a relocatable .o via Zig
    //   2. Compile v8_shim.cpp via system g++ (mirrors V8's libstdc++)
    //   3. Link the final exe with g++ as the driver
    // Steps 2-3 are driven by scripts/build_v8_shim.sh (compiles shim) and
    // scripts/link_v8_host.sh (final link).
    const v8_lib_path = v8_root ++ "/out.gn/x64.release/obj/libv8_monolith.a";
    if (fileExists(b, v8_lib_path)) {
        const obj_mod = b.createModule(.{
            .root_source_file = b.path("src/hosts/v8_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        obj_mod.addImport("bench", bench_mod);
        const obj = b.addObject(.{ .name = "v8_host_zig", .root_module = obj_mod });
        // Stage the .o where the link script expects it.
        const stage = b.addInstallFile(obj.getEmittedBin(), "../src/hosts/v8_host.o");
        b.getInstallStep().dependOn(&stage.step);
    }
}

// ---- Lua 5.4 build ----

fn buildLua(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path(lua_root ++ "/src"));
    if (target.result.os.tag == .linux) mod.addCMacro("LUA_USE_LINUX", "");

    const sources = try collectLuaSources(b);
    mod.addCSourceFiles(.{
        .root = b.path(lua_root),
        .files = sources,
        .language = .c,
        .flags = &.{ "-std=c99", "-w" },
    });

    return b.addLibrary(.{ .name = "lua", .root_module = mod, .linkage = .static });
}

fn collectLuaSources(b: *std.Build) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = try std.fs.cwd().openDir(lua_root ++ "/src", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        if (std.mem.eql(u8, entry.name, "lua.c")) continue;
        if (std.mem.eql(u8, entry.name, "luac.c")) continue;
        const rel = try std.fmt.allocPrint(b.allocator, "src/{s}", .{entry.name});
        try list.append(b.allocator, rel);
    }
    return list.toOwnedSlice(b.allocator);
}

// ---- QuickJS-NG build ----

fn buildQuickJS(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    mod.addIncludePath(b.path(quickjs_root));

    // QuickJS-NG sources — see vendor/quickjs/CMakeLists.txt qjs_sources.
    const sources: []const []const u8 = &.{
        "quickjs.c",
        "libregexp.c",
        "libunicode.c",
        "dtoa.c",
    };

    mod.addCSourceFiles(.{
        .root = b.path(quickjs_root),
        .files = sources,
        .language = .c,
        .flags = &.{
            "-std=c11",
            "-w",
            "-D_GNU_SOURCE",
        },
    });

    return b.addLibrary(.{ .name = "quickjs", .root_module = mod, .linkage = .static });
}

// ---- helpers ----

fn dirExists(b: *std.Build, rel: []const u8) bool {
    const abs = b.pathFromRoot(rel);
    var dir = std.fs.openDirAbsolute(abs, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(b: *std.Build, rel: []const u8) bool {
    const abs = b.pathFromRoot(rel);
    const f = std.fs.openFileAbsolute(abs, .{}) catch return false;
    f.close();
    return true;
}
