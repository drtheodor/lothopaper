const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lothopaper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("build.zig.zon", build_zig_zon);

    const clap = b.dependency("clap", .{}).module("clap");
    exe.root_module.addImport("clap", clap);

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    }).module("zigimg");

    exe.root_module.addImport("zigimg", zigimg);

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 3);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("zwlr_layer_shell_v1", 4);

    exe.root_module.addImport("wayland", wayland);

    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("GL");

    exe.linkLibC();

    if (b.release_mode != .off) {
        wayland.strip = true;
        clap.strip = true;
        build_zig_zon.strip = true;
        exe.root_module.strip = true;

        exe.link_gc_sections = true;
        exe.link_data_sections = true;
        exe.lto = .full;
        exe.want_lto = true;
    }

    b.installArtifact(exe);

    // run step
    const run_exe = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the binary");
    run_step.dependOn(&run_exe.step);

    // test step
    const test_targets = [_]std.Target.Query{
        .{}, //native
        // Add other test targets, for example x86_64 linux
        // .{
        //     .cpu_arch = .x86_64,
        //     .os_tag = .linux,
        // },
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_targets) |test_target| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(test_target),
            }),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        // only run tests considered non-foreign.
        // -fqemu and -fwasmtime command-line arguments may affect which tests run
        run_unit_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_unit_tests.step);
    }
}
