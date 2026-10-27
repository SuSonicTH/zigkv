//! End-to-end tests for the `zigkv` command-line tool.
//!
//! These tests execute the built binary in a temporary working directory so
//! they exercise argument parsing, file I/O, stdin/stdout and exit codes, not
//! just the helper functions in `main.zig`.

const std = @import("std");
const cli_exe = @import("cli_test_options").cli_exe;

const Allocator = std.mem.Allocator;
const Io = std.Io;

fn resolveExe(allocator: Allocator) ![:0]u8 {
    if (std.fs.path.isAbsolute(cli_exe)) return allocator.dupeSentinel(u8, cli_exe, 0);
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, cli_exe, allocator);
}

fn runCli(
    allocator: Allocator,
    exe_path: []const u8,
    cwd: Io.Dir,
    args: []const []const u8,
) !std.process.RunResult {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = exe_path;
    @memcpy(argv[1..], args);

    return std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

fn exitCode(term: std.process.Child.Term) !u8 {
    return switch (term) {
        .exited => |code| code,
        else => error.TestUnexpectedResult,
    };
}

fn expectCli(
    allocator: Allocator,
    exe_path: []const u8,
    cwd: Io.Dir,
    args: []const []const u8,
    expected_code: u8,
    expected_stdout: ?[]const u8,
) !void {
    const result = try runCli(allocator, exe_path, cwd, args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(expected_code, try exitCode(result.term));
    if (expected_stdout) |expected| {
        try std.testing.expectEqualStrings(expected, result.stdout);
    }
}

fn expectCliContains(
    allocator: Allocator,
    exe_path: []const u8,
    cwd: Io.Dir,
    args: []const []const u8,
    expected_code: u8,
    expected_stderr: []const u8,
) !void {
    const result = try runCli(allocator, exe_path, cwd, args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(expected_code, try exitCode(result.term));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected_stderr) != null);
}

fn expectCliStdoutContains(
    allocator: Allocator,
    exe_path: []const u8,
    cwd: Io.Dir,
    args: []const []const u8,
    expected_code: u8,
    expected_stdout: []const u8,
) !void {
    const result = try runCli(allocator, exe_path, cwd, args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(expected_code, try exitCode(result.term));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected_stdout) != null);
}

/// Run the CLI with a file as stdin and no captured output. Used to exercise
/// `put ... -`, which produces no output of its own.
fn runWithStdinFile(
    allocator: Allocator,
    exe_path: []const u8,
    cwd: Io.Dir,
    args: []const []const u8,
    stdin_file: std.Io.File,
) !u8 {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = exe_path;
    @memcpy(argv[1..], args);

    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdin = .{ .file = stdin_file },
        .stdout = .ignore,
        .stderr = .ignore,
    });

    const term = child.wait(std.testing.io) catch |err| {
        child.kill(std.testing.io);
        return err;
    };
    return exitCode(term);
}

test "CLI round-trips text and binary keys" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const exe_path = try resolveExe(allocator);
    defer allocator.free(exe_path);

    try expectCli(allocator, exe_path, tmp.dir, &.{
        "create", "data.zkv", "--slots", "16", "--key-bytes", "64", "--value-bytes", "64",
    }, 0, "");

    try expectCli(allocator, exe_path, tmp.dir, &.{ "put", "data.zkv", "hello", "world" }, 0, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "get", "data.zkv", "hello" }, 0, "world");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "exists", "data.zkv", "hello" }, 0, "5\n");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "list", "data.zkv" }, 0, "hello\tworld\n");

    // Binary key supplied on the command line.
    try expectCli(allocator, exe_path, tmp.dir, &.{
        "put", "data.zkv", "--key-hex", "00ff", "binary-value",
    }, 0, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{
        "get", "data.zkv", "--key-hex", "00ff",
    }, 0, "binary-value");
    try expectCli(allocator, exe_path, tmp.dir, &.{
        "exists", "data.zkv", "--key-hex", "00ff",
    }, 0, "12\n");

    // NUL-separated listing is binary-safe.
    const listing = try runCli(allocator, exe_path, tmp.dir, &.{ "list", "data.zkv", "--null" });
    defer allocator.free(listing.stdout);
    defer allocator.free(listing.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(listing.term));
    try std.testing.expect(std.mem.indexOf(u8, listing.stdout, "hello\x00world\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.stdout, "\x00\xff\x00binary-value\x00") != null);

    try expectCli(allocator, exe_path, tmp.dir, &.{ "remove", "data.zkv", "hello" }, 0, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "exists", "data.zkv", "hello" }, 1, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "get", "data.zkv", "hello" }, 1, "");
}

test "CLI supports key files, stdin values, stat and widths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const exe_path = try resolveExe(allocator);
    defer allocator.free(exe_path);

    try expectCli(allocator, exe_path, tmp.dir, &.{
        "create", "wide.zkv", "--slots",     "32", "--key-bytes",   "128", "--value-bytes", "128",
        "--hash", "32",       "--key-index", "64", "--value-index", "64",
    }, 0, "");

    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{ "stat", "wide.zkv" }, 0, "slots: 32\n");
    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{ "stat", "wide.zkv" }, 0, "hash-width: 32\n");
    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{ "stat", "wide.zkv" }, 0, "key-index-width: 64\n");
    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{ "stat", "wide.zkv" }, 0, "value-index-width: 64\n");
    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{ "stat", "wide.zkv" }, 0, "max-live-keys: 24\n");

    const key_file = [_]u8{ 0x00, 0xFF, 0x10 };
    try tmp.dir.writeFile(io, .{ .sub_path = "key.bin", .data = &key_file });
    try expectCli(allocator, exe_path, tmp.dir, &.{
        "put", "wide.zkv", "--key-file", "key.bin", "file-key-value",
    }, 0, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{
        "get", "wide.zkv", "--key-file", "key.bin",
    }, 0, "file-key-value");

    try tmp.dir.writeFile(io, .{ .sub_path = "stdin.txt", .data = "from stdin" });
    const stdin_file = try tmp.dir.openFile(io, "stdin.txt", .{});
    defer stdin_file.close(io);
    try std.testing.expectEqual(
        @as(u8, 0),
        try runWithStdinFile(allocator, exe_path, tmp.dir, &.{
            "put", "wide.zkv", "from-stdin", "-",
        }, stdin_file),
    );
    try expectCli(allocator, exe_path, tmp.dir, &.{ "get", "wide.zkv", "from-stdin" }, 0, "from stdin");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "exists", "wide.zkv", "from-stdin" }, 0, "10\n");
}

test "CLI reports usage errors without touching the store" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const exe_path = try resolveExe(allocator);
    defer allocator.free(exe_path);

    try expectCli(allocator, exe_path, tmp.dir, &.{"--version"}, 0, "zigkv 0.1.0\n");
    try expectCliStdoutContains(allocator, exe_path, tmp.dir, &.{"--help"}, 0, "usage: zigkv");

    try expectCliContains(allocator, exe_path, tmp.dir, &.{"bogus"}, 2, "unknown command");
    try expectCliContains(allocator, exe_path, tmp.dir, &.{
        "create", "bad.zkv", "--bogus",
    }, 2, "create: unknown option '--bogus'");
    try expectCliContains(allocator, exe_path, tmp.dir, &.{
        "create", "bad.zkv", "--slots",
    }, 2, "--slots requires a value");
    try expectCliContains(allocator, exe_path, tmp.dir, &.{
        "create", "bad.zkv", "--hash", "16",
    }, 2, "--hash expects 32 or 64");

    try expectCli(allocator, exe_path, tmp.dir, &.{ "get", "missing.zkv", "hello" }, 1, "");
    try expectCli(allocator, exe_path, tmp.dir, &.{ "remove", "missing.zkv", "hello" }, 1, "");
}
