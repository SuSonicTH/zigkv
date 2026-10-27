const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, exposed to consumers as `zigkv`.
    const zigkv = b.addModule("zigkv", .{
        .root_source_file = b.path("src/zigkv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The `zigkv` command-line tool.
    const exe = b.addExecutable(.{
        .name = "zigkv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigkv", .module = zigkv },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the zigkv CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // Library tests: unit, property, corruption and alloc-failure coverage.
    const lib_tests = b.addTest(.{
        .name = "zigkv-tests",
        .root_module = zigkv,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    // Persistence tests read the golden/corrupt fixtures from testdata/.
    run_lib_tests.setCwd(b.path("."));

    // CLI tests, so that `zig build test` also checks the executable compiles.
    const cli_tests = b.addTest(.{
        .name = "zigkv-cli-tests",
        .root_module = exe.root_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.setCwd(b.path("."));

    // End-to-end CLI tests execute the built binary, including argument
    // parsing, file I/O, stdin/stdout and exit codes.
    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("cli_exe", exe.getEmittedBin());
    const cli_e2e_tests = b.addTest(.{
        .name = "zigkv-cli-e2e-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_e2e_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli_test_options", .module = cli_test_options.createModule() },
            },
        }),
    });
    const run_cli_e2e_tests = b.addRunArtifact(cli_e2e_tests);
    run_cli_e2e_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit, property, corruption and CLI tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_cli_e2e_tests.step);

    // Benchmarks are built and run on demand only.
    const bench_exe = b.addExecutable(.{
        .name = "zigkv-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigkv", .module = zigkv },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // The basic API example is built and run on demand only.
    const example_exe = b.addExecutable(.{
        .name = "zigkv-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigkv", .module = zigkv },
            },
        }),
    });
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example", "Run the basic example");
    example_step.dependOn(&run_example.step);
}
