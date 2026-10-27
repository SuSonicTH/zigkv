//! `zigkv` command-line interface.
//!
//! Mutating commands load, mutate and save the whole image. Values are raw
//! bytes, so `get`, `put -` and `list --null` are binary-safe.

const std = @import("std");
const zigkv = @import("zigkv");

const usage =
    \\usage: zigkv <command> [arguments]
    \\
    \\commands:
    \\  create <file> [--slots N] [--key-bytes N] [--value-bytes N]
    \\                [--hash 32|64] [--key-index 32|64] [--value-index 32|64]
    \\  put    <file> <key> [<value> | -]
    \\  get    <file> <key>
    \\  remove <file> <key>
    \\  exists <file> <key>
    \\  list   <file> [--null]
    \\  stat   <file>
    \\
    \\Binary keys: use --key-hex <hex> or --key-file <path> in place of the
    \\positional key. A value of "-" is read from stdin. `list --null` emits
    \\key NUL value NUL records.
    \\
    \\options:
    \\  -h, --help     print this help
    \\      --version  print the version
    \\
;

pub const Command = enum {
    create,
    put,
    get,
    remove,
    exists,
    list,
    stat,
};

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "create", .create },
    .{ "put", .put },
    .{ "get", .get },
    .{ "remove", .remove },
    .{ "exists", .exists },
    .{ "list", .list },
    .{ "stat", .stat },
});

pub fn parseCommand(name: []const u8) ?Command {
    return command_map.get(name);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        stderrPrint(init.io, "zigkv: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) usageError(io, "missing command", .{});

    const arg = args[1];
    if (std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "help"))
    {
        try stdoutWrite(io, usage);
        return;
    }
    if (std.mem.eql(u8, arg, "--version")) {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "zigkv {s}\n", .{zigkv.version});
        try stdoutWrite(io, text);
        return;
    }

    const command = parseCommand(arg) orelse
        usageError(io, "unknown command '{s}'", .{arg});

    switch (command) {
        .create => try runCreate(io, gpa, args),
        .put => try runPut(io, gpa, allocator, args),
        .get => try runGet(io, gpa, allocator, args),
        .remove => try runRemove(io, gpa, allocator, args),
        .exists => try runExists(io, gpa, allocator, args),
        .list => try runList(io, gpa, args),
        .stat => try runStat(io, gpa, args),
    }
}

fn runCreate(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) usageError(io, "create: missing file", .{});
    const path = args[2];

    var options: zigkv.Store.Options = .{};
    var index: usize = 3;
    while (index < args.len) {
        const flag = args[index];
        index += 1;

        if (std.mem.eql(u8, flag, "--slots")) {
            options.max_entries = try parseU64(io, optionValue(io, args, &index, flag), flag);
        } else if (std.mem.eql(u8, flag, "--key-bytes")) {
            options.key_bytes = try parseU64(io, optionValue(io, args, &index, flag), flag);
        } else if (std.mem.eql(u8, flag, "--value-bytes")) {
            options.value_bytes = try parseU64(io, optionValue(io, args, &index, flag), flag);
        } else if (std.mem.eql(u8, flag, "--hash")) {
            options.hash = try parseHashWidth(io, optionValue(io, args, &index, flag));
        } else if (std.mem.eql(u8, flag, "--key-index")) {
            options.key_index = try parseIndexWidth(io, optionValue(io, args, &index, flag));
        } else if (std.mem.eql(u8, flag, "--value-index")) {
            options.value_index = try parseIndexWidth(io, optionValue(io, args, &index, flag));
        } else {
            usageError(io, "create: unknown option '{s}'", .{flag});
        }
    }

    var store = try zigkv.Store.init(gpa, options);
    defer store.deinit();
    try store.save(io, std.Io.Dir.cwd(), path);
}

fn runPut(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usageError(io, "put: missing file", .{});
    const path = args[2];

    var index: usize = 3;
    const key = try parseKey(io, allocator, args, &index);
    const value = try parseValue(io, allocator, args, &index);
    if (index != args.len) usageError(io, "put: unexpected argument '{s}'", .{args[index]});

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();
    try store.put(key, value);
    try store.save(io, std.Io.Dir.cwd(), path);
}

fn runGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usageError(io, "get: missing file", .{});
    const path = args[2];

    var index: usize = 3;
    const key = try parseKey(io, allocator, args, &index);
    if (index != args.len) usageError(io, "get: unexpected argument '{s}'", .{args[index]});

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();

    const value = store.getView(key) orelse std.process.exit(1);

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    try out.writeAll(value);
    try out.flush();
}

fn runRemove(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usageError(io, "remove: missing file", .{});
    const path = args[2];

    var index: usize = 3;
    const key = try parseKey(io, allocator, args, &index);
    if (index != args.len) usageError(io, "remove: unexpected argument '{s}'", .{args[index]});

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();

    if (!store.remove(key)) std.process.exit(1);
    try store.save(io, std.Io.Dir.cwd(), path);
}

fn runExists(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) usageError(io, "exists: missing file", .{});
    const path = args[2];

    var index: usize = 3;
    const key = try parseKey(io, allocator, args, &index);
    if (index != args.len) usageError(io, "exists: unexpected argument '{s}'", .{args[index]});

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();

    const length = store.exists(key) orelse std.process.exit(1);

    var buffer: [64]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    try out.print("{d}\n", .{length});
    try out.flush();
}

fn runList(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) usageError(io, "list: missing file", .{});
    const path = args[2];

    var null_separated = false;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--null")) {
            null_separated = true;
        } else {
            usageError(io, "list: unknown option '{s}'", .{args[index]});
        }
    }

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    var iterator = store.iterator();
    while (iterator.next()) |entry| {
        try out.writeAll(entry.key);
        if (null_separated) {
            try out.writeByte(0);
            try out.writeAll(entry.value);
            try out.writeByte(0);
        } else {
            try out.writeByte('\t');
            try out.writeAll(entry.value);
            try out.writeByte('\n');
        }
    }
    try out.flush();
}

fn runStat(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 3) usageError(io, "stat: missing file", .{});
    if (args.len != 3) usageError(io, "stat: unexpected argument '{s}'", .{args[3]});
    const path = args[2];

    var store = try zigkv.Store.load(gpa, io, std.Io.Dir.cwd(), path);
    defer store.deinit();

    const header = store.header;
    const byte_order = if (header.endian == .big) "big" else "little";

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    const hash_bits: u8 = if (header.flags.hash == .city64) 64 else 32;
    const key_index_bits: u8 = if (header.flags.key_index == .u64) 64 else 32;
    const value_index_bits: u8 = if (header.flags.value_index == .u64) 64 else 32;

    try out.print("format: {s}\n", .{zigkv.Store.file_magic});
    try out.print("version: {d}\n", .{zigkv.Store.file_version});
    try out.print("byte-order: {s}\n", .{byte_order});
    try out.print("hash-width: {d}\n", .{hash_bits});
    try out.print("key-index-width: {d}\n", .{key_index_bits});
    try out.print("value-index-width: {d}\n", .{value_index_bits});
    try out.print("slots: {d}\n", .{header.table_reserved});
    try out.print("live-keys: {d}\n", .{store.count()});
    try out.print("max-live-keys: {d}\n", .{store.capacity()});
    try out.print("key-bytes: {d}\n", .{header.key_bytes});
    try out.print("value-bytes: {d}\n", .{header.value_bytes});
    try out.flush();
}

fn parseKey(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    index: *usize,
) ![]const u8 {
    if (index.* >= args.len) usageError(io, "missing key", .{});
    const arg = args[index.*];

    if (std.mem.eql(u8, arg, "--key-hex")) {
        index.* += 1;
        if (index.* >= args.len) usageError(io, "--key-hex requires a value", .{});
        const text = args[index.*];
        index.* += 1;
        return decodeHexKey(io, allocator, text);
    }

    if (std.mem.eql(u8, arg, "--key-file")) {
        index.* += 1;
        if (index.* >= args.len) usageError(io, "--key-file requires a path", .{});
        const path = args[index.*];
        index.* += 1;
        return std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(std.math.maxInt(usize)),
        );
    }

    index.* += 1;
    return arg;
}

fn parseValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    index: *usize,
) ![]const u8 {
    if (index.* >= args.len) return "";
    const arg = args[index.*];
    index.* += 1;

    if (std.mem.eql(u8, arg, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
        return reader.interface.allocRemaining(allocator, .unlimited);
    }
    return arg;
}

fn decodeHexKey(
    io: std.Io,
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    return std.fmt.hexToBytes(bytes, text) catch
        usageError(io, "invalid hex key", .{});
}

fn optionValue(
    io: std.Io,
    args: []const [:0]const u8,
    index: *usize,
    flag: []const u8,
) []const u8 {
    if (index.* >= args.len) usageError(io, "{s} requires a value", .{flag});
    const value = args[index.*];
    index.* += 1;
    return value;
}

fn parseU64(io: std.Io, text: []const u8, flag: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch
        usageError(io, "{s} expects a non-negative integer", .{flag});
}

fn parseHashWidth(io: std.Io, text: []const u8) !zigkv.Store.HashWidth {
    if (std.mem.eql(u8, text, "32")) return .city32;
    if (std.mem.eql(u8, text, "64")) return .city64;
    usageError(io, "--hash expects 32 or 64", .{});
}

fn parseIndexWidth(io: std.Io, text: []const u8) !zigkv.Store.IndexWidth {
    if (std.mem.eql(u8, text, "32")) return .u32;
    if (std.mem.eql(u8, text, "64")) return .u64;
    usageError(io, "--key-index/--value-index expects 32 or 64", .{});
}

fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn usageError(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    stderrPrint(io, fmt, fmt_args);
    stderrPrint(io, "\n\n{s}", .{usage});
    std.process.exit(2);
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, fmt_args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

test "parseCommand recognizes every command" {
    try std.testing.expectEqual(Command.create, parseCommand("create").?);
    try std.testing.expectEqual(Command.put, parseCommand("put").?);
    try std.testing.expectEqual(Command.get, parseCommand("get").?);
    try std.testing.expectEqual(Command.remove, parseCommand("remove").?);
    try std.testing.expectEqual(Command.exists, parseCommand("exists").?);
    try std.testing.expectEqual(Command.list, parseCommand("list").?);
    try std.testing.expectEqual(Command.stat, parseCommand("stat").?);
}

test "parseCommand rejects unknown commands" {
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("Create") == null);
    try std.testing.expect(parseCommand("--help") == null);
}

test "usage documents every command" {
    inline for (@typeInfo(Command).@"enum".field_names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, usage, name) != null);
    }
}

test "decodeHexKey decodes binary keys" {
    const bytes = try decodeHexKey(std.testing.io, std.testing.allocator, "00ff10");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x10 }, bytes);
}
