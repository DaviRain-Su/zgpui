const std = @import("std");

const PrefixPaths = struct {
    prefix: []const u8,
    include: []const u8,
    lib: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const paths = detectPrefix(b, target);
    const is_macos = target.result.os.tag == .macos;

    // ------------------------------------------------------------------
    // C bindings (translate-c modules)
    // ------------------------------------------------------------------
    const glfw_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/glfw.h"),
        .target = target,
        .optimize = optimize,
    });
    addPrefixIncludePaths(b, glfw_c, paths, target);

    const wgpu_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/wgpu.h"),
        .target = target,
        .optimize = optimize,
    });
    addPrefixIncludePaths(b, wgpu_c, paths, target);

    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/text.h"),
        .target = target,
        .optimize = optimize,
    });
    addTextIncludePaths(b, text_c, paths, target);

    const objc_c = if (is_macos) b.addTranslateC(.{
        .root_source_file = b.path("src/c/objc.h"),
        .target = target,
        .optimize = optimize,
    }) else null;

    // --- yoga (Phase 4) ---
    const yoga_cpp_flags = &.{
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
    };
    const yoga_cpp_files = &.{
        "yoga/YGConfig.cpp",
        "yoga/YGEnums.cpp",
        "yoga/YGNode.cpp",
        "yoga/YGNodeLayout.cpp",
        "yoga/YGNodeStyle.cpp",
        "yoga/YGPixelGrid.cpp",
        "yoga/YGValue.cpp",
        "yoga/algorithm/AbsoluteLayout.cpp",
        "yoga/algorithm/Baseline.cpp",
        "yoga/algorithm/Cache.cpp",
        "yoga/algorithm/CalculateLayout.cpp",
        "yoga/algorithm/FlexLine.cpp",
        "yoga/algorithm/PixelGrid.cpp",
        "yoga/config/Config.cpp",
        "yoga/debug/AssertFatal.cpp",
        "yoga/debug/Log.cpp",
        "yoga/event/event.cpp",
        "yoga/node/LayoutResults.cpp",
        "yoga/node/Node.cpp",
    };
    const yoga_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    yoga_mod.addIncludePath(b.path("vendor/yoga"));
    yoga_mod.addCSourceFiles(.{
        .root = b.path("vendor/yoga"),
        .files = yoga_cpp_files,
        .flags = yoga_cpp_flags,
    });
    const yoga_lib = b.addLibrary(.{
        .name = "yoga",
        .linkage = .static,
        .root_module = yoga_mod,
    });
    preferSystemGnuLinker(yoga_lib, target);

    const yoga_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/yoga.h"),
        .target = target,
        .optimize = optimize,
    });
    yoga_c.addIncludePath(b.path("vendor/yoga"));
    // --- yoga (Phase 4) ---

    var c_imports_buf: [5]std.Build.Module.Import = undefined;
    var c_import_count: usize = 0;
    c_imports_buf[c_import_count] = .{ .name = "glfw_c", .module = glfw_c.createModule() };
    c_import_count += 1;
    c_imports_buf[c_import_count] = .{ .name = "wgpu_c", .module = wgpu_c.createModule() };
    c_import_count += 1;
    if (objc_c) |objc| {
        c_imports_buf[c_import_count] = .{ .name = "objc_c", .module = objc.createModule() };
        c_import_count += 1;
    }
    c_imports_buf[c_import_count] = .{ .name = "text_c", .module = text_c.createModule() };
    c_import_count += 1;
    c_imports_buf[c_import_count] = .{ .name = "yoga_c", .module = yoga_c.createModule() };
    c_import_count += 1;
    const c_imports = c_imports_buf[0..c_import_count];

    // ------------------------------------------------------------------
    // zgpui module
    // ------------------------------------------------------------------
    const zgpui = b.addModule("zgpui", .{
        .root_source_file = b.path("src/zgpui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = c_imports,
    });
    linkSystemDeps(b, zgpui, target, paths);
    // --- yoga (Phase 4) ---
    zgpui.linkLibrary(yoga_lib);
    // --- yoga (Phase 4) ---

    // ------------------------------------------------------------------
    // Examples: every examples/*.zig becomes a run step `zig build run-<name>`
    // ------------------------------------------------------------------
    addExamples(b, target, optimize, zgpui);

    // ------------------------------------------------------------------
    // Tests: `zig build test` (unit tests must not require a window/GPU)
    // ------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = zgpui });
    preferSystemGnuLinker(mod_tests, target);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // --- yoga (Phase 4) ---
    const layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/layout/layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yoga_c", .module = yoga_c.createModule() },
        },
    });
    layout_test_mod.linkLibrary(yoga_lib);
    const layout_tests = b.addTest(.{ .root_module = layout_test_mod });
    const run_layout_tests = b.addRunArtifact(layout_tests);
    const layout_test_step = b.step("test-layout", "Run layout unit tests");
    layout_test_step.dependOn(&run_layout_tests.step);
    // --- yoga (Phase 4) ---
}

fn detectPrefix(b: *std.Build, target: std.Build.ResolvedTarget) PrefixPaths {
    if (b.graph.environ_map.get("ZGPUI_PREFIX")) |prefix| return prefixPaths(b, prefix);

    if (target.result.os.tag == .macos) {
        if (b.graph.environ_map.get("HOMEBREW_PREFIX")) |prefix| return prefixPaths(b, prefix);
        const candidates = [_][]const u8{ "/opt/homebrew", "/usr/local", "/usr" };
        for (candidates) |candidate| {
            if (prefixLooksValid(b, candidate)) return prefixPaths(b, candidate);
        }
        return prefixPaths(b, "/opt/homebrew");
    }

    const candidates = [_][]const u8{ "/usr/local", "/usr" };
    for (candidates) |candidate| {
        if (prefixLooksValid(b, candidate)) return prefixPaths(b, candidate);
    }
    return prefixPaths(b, "/usr");
}

fn prefixPaths(b: *std.Build, prefix: []const u8) PrefixPaths {
    return .{
        .prefix = b.dupe(prefix),
        .include = b.dupe(b.fmt("{s}/include", .{prefix})),
        .lib = b.dupe(b.fmt("{s}/lib", .{prefix})),
    };
}

fn prefixLooksValid(b: *std.Build, prefix: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "{s}/include/GLFW/glfw3.h", .{prefix}) catch return false;
    std.Io.Dir.accessAbsolute(b.graph.io, marker, .{}) catch return false;
    return true;
}

fn addPrefixIncludePaths(b: *std.Build, step: *std.Build.Step.TranslateC, paths: PrefixPaths, target: std.Build.ResolvedTarget) void {
    step.addSystemIncludePath(.{ .cwd_relative = paths.include });
    // Official wgpu-native zips nest headers under include/webgpu/.
    step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/webgpu", .{paths.prefix}) });
    if (target.result.os.tag == .linux) {
        step.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        step.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
    }
    if (target.result.os.tag == .windows) {
        if (b.graph.environ_map.get("MSYSTEM_PREFIX")) |msys| {
            step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{msys}) });
        }
    }
}

fn addTextIncludePaths(b: *std.Build, step: *std.Build.Step.TranslateC, paths: PrefixPaths, target: std.Build.ResolvedTarget) void {
    addPrefixIncludePaths(b, step, paths, target);
    step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{paths.prefix}) });
    step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{paths.prefix}) });
    if (target.result.os.tag == .linux) {
        step.addSystemIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
        step.addSystemIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    }
    if (target.result.os.tag == .windows) {
        if (b.graph.environ_map.get("MSYSTEM_PREFIX")) |msys| {
            step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{msys}) });
            step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{msys}) });
        }
    }
}

fn linkSystemDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, paths: PrefixPaths) void {
    mod.addLibraryPath(.{ .cwd_relative = paths.lib });
    mod.addSystemIncludePath(.{ .cwd_relative = paths.include });
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/webgpu", .{paths.prefix}) });

    switch (target.result.os.tag) {
        .macos => {
            mod.linkSystemLibrary("objc", .{});
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("Metal", .{});
        },
        .linux => {
            // Distro packages live under /usr even when ZGPUI_PREFIX points at
            // a wgpu-native release tree.
            mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
            mod.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
        },
        .windows => {
            // MSYS2 MinGW packages supply GLFW / FreeType / HarfBuzz; wgpu-native
            // usually lives under ZGPUI_PREFIX (see docs/WINDOWS.md). Prefer
            // `-Dtarget=x86_64-windows-gnu` so Zig links with the MinGW toolchain.
            if (b.graph.environ_map.get("MSYSTEM_PREFIX")) |msys| {
                mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{msys}) });
                mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{msys}) });
                mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{msys}) });
                mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{msys}) });
            }
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("opengl32", .{});
            mod.linkSystemLibrary("dwmapi", .{});
            // Transitive deps pulled in by MinGW FreeType / HarfBuzz builds.
            mod.linkSystemLibrary("rpcrt4", .{});
            mod.linkSystemLibrary("dwrite", .{});
            mod.linkSystemLibrary("graphite2", .{});
            mod.linkSystemLibrary("z", .{});
            mod.linkSystemLibrary("bz2", .{});
            mod.linkSystemLibrary("png", .{});
            mod.linkSystemLibrary("brotlidec", .{});
            mod.linkSystemLibrary("brotlicommon", .{});
        },
        else => {},
    }

    // MinGW ships libglfw3; macOS/Homebrew and many Linux packages use libglfw.
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("glfw3", .{});
    } else {
        mod.linkSystemLibrary("glfw", .{});
    }
    mod.linkSystemLibrary("wgpu_native", .{});
    mod.linkSystemLibrary("freetype", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
}

fn addExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zgpui: *std.Build.Module,
) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "examples", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const name = entry.name[0 .. entry.name.len - 4];

        if (target.result.os.tag != .macos and std.mem.eql(u8, name, "03_native")) continue;

        const exe = b.addExecutable(.{
            .name = b.dupe(name),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zgpui", .module = zgpui },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run example {s}", .{name}));
        run_step.dependOn(&run_cmd.step);
    }
}
