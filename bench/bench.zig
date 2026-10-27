//! zigkv micro-benchmarks.
//!
//! Run with:
//!
//!     zig build bench -Doptimize=ReleaseFast
//!     zig build bench -Doptimize=ReleaseFast -- 20000
//!
//! The optional argument overrides the default key count (100,000).

const std = @import("std");
const zigkv = @import("zigkv");

const default_keys: usize = 100_000;
const value_sizes = [_]usize{ 8, 256, 4096 };

const WidthConfig = struct {
    name: []const u8,
    hash: zigkv.Store.HashWidth,
    key_index: zigkv.Store.IndexWidth,
    value_index: zigkv.Store.IndexWidth,
};

const width_configs = [_]WidthConfig{
    .{
        .name = "store city64/u32/u32",
        .hash = .city64,
        .key_index = .u32,
        .value_index = .u32,
    },
    .{
        .name = "store city32/u32/u32",
        .hash = .city32,
        .key_index = .u32,
        .value_index = .u32,
    },
    .{
        .name = "store city64/u64/u64",
        .hash = .city64,
        .key_index = .u64,
        .value_index = .u64,
    },
    .{
        .name = "store city32/u64/u64",
        .hash = .city32,
        .key_index = .u64,
        .value_index = .u64,
    },
};

const Result = struct {
    implementation: []const u8,
    value_size: usize,
    put: f64,
    get: f64,
    hot: f64,
    remove: f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var key_count = default_keys;
    if (args.len > 1) {
        key_count = try std.fmt.parseInt(usize, args[1], 10);
    }
    if (key_count == 0) return error.InvalidArguments;

    const keys_storage = try allocator.alloc([8]u8, key_count);
    defer allocator.free(keys_storage);
    const keys = try allocator.alloc([]const u8, key_count);
    defer allocator.free(keys);

    for (keys_storage, 0..) |*key, i| {
        std.mem.writeInt(u64, key, @intCast(i), .little);
        keys[i] = key[0..];
    }

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(allocator);

    for (value_sizes) |value_size| {
        const value = try allocator.alloc(u8, value_size);
        defer allocator.free(value);
        @memset(value, @truncate(value_size));

        try results.append(
            allocator,
            try measureStore(allocator, io, keys, value, width_configs[0]),
        );

        // Exercise the width matrix with small values only; the large-value
        // runs dominate memory and are represented by the default widths.
        if (value_size == 8) {
            for (width_configs[1..]) |config| {
                try results.append(
                    allocator,
                    try measureStore(allocator, io, keys, value, config),
                );
            }
        }

        try results.append(allocator, try measureStringHashMap(allocator, io, keys, value));
        try results.append(allocator, try measureStringArrayHashMap(allocator, io, keys, value));
    }

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    try out.print("zigkv benchmarks: {d} keys, 8-byte keys\n\n", .{key_count});
    try printMarkdownTable(out, results.items);
    try out.flush();
}

fn measureStore(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    value: []const u8,
    config: WidthConfig,
) !Result {
    const n = keys.len;
    const options: zigkv.Store.Options = .{
        .max_entries = @intCast(n * 2),
        .key_bytes = @intCast(n * 32 + 4096),
        .value_bytes = @intCast(n * (value.len + 32) + 4096),
        .hash = config.hash,
        .key_index = config.key_index,
        .value_index = config.value_index,
    };

    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();

    var start = nanoTimestamp(io);
    for (keys) |key| try store.put(key, value);
    const put_ns = perOp(nanoTimestamp(io) - start, n);

    var checksum: usize = 0;
    start = nanoTimestamp(io);
    for (keys) |key| {
        if (store.getView(key)) |found| checksum +%= found.len;
    }
    const get_ns = perOp(nanoTimestamp(io) - start, n);

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (store.getView(keys[i % hot])) |found| checksum +%= found.len;
    }
    const hot_ns = perOp(nanoTimestamp(io) - start, n);

    start = nanoTimestamp(io);
    for (keys) |key| _ = store.remove(key);
    const remove_ns = perOp(nanoTimestamp(io) - start, n);
    std.debug.assert(store.count() == 0);

    std.mem.doNotOptimizeAway(checksum);
    return .{
        .implementation = config.name,
        .value_size = value.len,
        .put = put_ns,
        .get = get_ns,
        .hot = hot_ns,
        .remove = remove_ns,
    };
}

fn measureStringHashMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    value: []const u8,
) !Result {
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(keys.len));

    const n = keys.len;
    var start = nanoTimestamp(io);
    for (keys) |key| try map.put(key, value);
    const put_ns = perOp(nanoTimestamp(io) - start, n);

    var checksum: usize = 0;
    start = nanoTimestamp(io);
    for (keys) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    const get_ns = perOp(nanoTimestamp(io) - start, n);

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (map.get(keys[i % hot])) |found| checksum +%= found.len;
    }
    const hot_ns = perOp(nanoTimestamp(io) - start, n);

    start = nanoTimestamp(io);
    for (keys) |key| _ = map.remove(key);
    const remove_ns = perOp(nanoTimestamp(io) - start, n);
    std.debug.assert(map.count() == 0);

    std.mem.doNotOptimizeAway(checksum);
    return .{
        .implementation = "std.StringHashMap",
        .value_size = value.len,
        .put = put_ns,
        .get = get_ns,
        .hot = hot_ns,
        .remove = remove_ns,
    };
}

fn measureStringArrayHashMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    value: []const u8,
) !Result {
    var map: std.array_hash_map.String([]const u8) = .empty;
    defer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, keys.len);

    const n = keys.len;
    var start = nanoTimestamp(io);
    for (keys) |key| try map.put(allocator, key, value);
    const put_ns = perOp(nanoTimestamp(io) - start, n);

    var checksum: usize = 0;
    start = nanoTimestamp(io);
    for (keys) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    const get_ns = perOp(nanoTimestamp(io) - start, n);

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (map.get(keys[i % hot])) |found| checksum +%= found.len;
    }
    const hot_ns = perOp(nanoTimestamp(io) - start, n);

    start = nanoTimestamp(io);
    for (keys) |key| _ = map.swapRemove(key);
    const remove_ns = perOp(nanoTimestamp(io) - start, n);
    std.debug.assert(map.entries.len == 0);

    std.mem.doNotOptimizeAway(checksum);
    return .{
        .implementation = "std.ArrayHashMap",
        .value_size = value.len,
        .put = put_ns,
        .get = get_ns,
        .hot = hot_ns,
        .remove = remove_ns,
    };
}

fn printMarkdownTable(out: *std.Io.Writer, results: []const Result) !void {
    var implementation_width = "Implementation".len;
    for (results) |result| {
        implementation_width = @max(implementation_width, result.implementation.len);
    }

    const value_width = 5;
    const metric_width = 12;

    try writeCell(out, "Implementation", implementation_width, false);
    try writeCell(out, "Value", value_width, true);
    try writeCell(out, "Put ns/op", metric_width, true);
    try writeCell(out, "Get ns/op", metric_width, true);
    try writeCell(out, "Hot 1% ns/op", metric_width, true);
    try writeCell(out, "Remove ns/op", metric_width, true);
    try out.writeAll("|\n");

    try writeLeftSeparator(out, implementation_width);
    try writeRightSeparator(out, value_width);
    try writeRightSeparator(out, metric_width);
    try writeRightSeparator(out, metric_width);
    try writeRightSeparator(out, metric_width);
    try writeRightSeparator(out, metric_width);
    try out.writeAll("|\n");

    for (results) |result| {
        var value_buffer: [32]u8 = undefined;
        var put_buffer: [32]u8 = undefined;
        var get_buffer: [32]u8 = undefined;
        var hot_buffer: [32]u8 = undefined;
        var remove_buffer: [32]u8 = undefined;

        const value_text = try std.fmt.bufPrint(&value_buffer, "{d}", .{result.value_size});
        const put_text = try std.fmt.bufPrint(&put_buffer, "{d:.1}", .{result.put});
        const get_text = try std.fmt.bufPrint(&get_buffer, "{d:.1}", .{result.get});
        const hot_text = try std.fmt.bufPrint(&hot_buffer, "{d:.1}", .{result.hot});
        const remove_text = try std.fmt.bufPrint(&remove_buffer, "{d:.1}", .{result.remove});

        try writeCell(out, result.implementation, implementation_width, false);
        try writeCell(out, value_text, value_width, true);
        try writeCell(out, put_text, metric_width, true);
        try writeCell(out, get_text, metric_width, true);
        try writeCell(out, hot_text, metric_width, true);
        try writeCell(out, remove_text, metric_width, true);
        try out.writeAll("|\n");
    }
}

fn writeCell(out: *std.Io.Writer, text: []const u8, width: usize, right_align: bool) !void {
    std.debug.assert(text.len <= width);
    try out.writeByte('|');
    try out.writeByte(' ');
    if (right_align) {
        try writeSpaces(out, width - text.len);
        try out.writeAll(text);
    } else {
        try out.writeAll(text);
        try writeSpaces(out, width - text.len);
    }
    try out.writeByte(' ');
}

fn writeLeftSeparator(out: *std.Io.Writer, width: usize) !void {
    try out.writeAll("|:");
    try writeDashes(out, width + 1);
}

fn writeRightSeparator(out: *std.Io.Writer, width: usize) !void {
    try out.writeByte('|');
    try writeDashes(out, width + 1);
    try out.writeByte(':');
}

fn writeSpaces(out: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.writeByte(' ');
}

fn writeDashes(out: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.writeByte('-');
}

fn nanoTimestamp(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn perOp(delta: i96, n: usize) f64 {
    return @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(n));
}
