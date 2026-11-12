const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Expose public Zig module
    const urasg_mod = b.addModule("urasg", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 2. Static C Library (liburasg.a / urasg.lib)
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "urasg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    static_lib.installHeader(b.path("include/urasg.h"), "urasg.h");
    b.installArtifact(static_lib);

    // 3. Dynamic Shared C Library (liburasg.so / urasg.dll)
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "urasg_shared",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(shared_lib);

    // 4. Freestanding WebAssembly target (liburasg.wasm)
    const wasm_step = b.step("wasm", "Build freestanding liburasg.wasm");
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "liburasg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&install_wasm.step);

    // 5. Unit and Integration Test Runner
    const lib_tests = b.addTest(.{
        .root_module = urasg_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run all UR-ASG and urc unit and blueprint tests");
    test_step.dependOn(&run_lib_tests.step);
}
