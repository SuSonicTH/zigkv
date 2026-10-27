//! zigkv micro-benchmarks.
//!
//! Run with:
//!
//!     zig build bench -Doptimize=ReleaseFast
//!     zig build bench -Doptimize=ReleaseFast -- 20000
//!
//! The optional argument overrides the default key count (100,000).
//!
//! Each implementation is built and measured `rounds` times from scratch and
//! the best sample of each metric is reported, which removes the page-fault and
//! cold-cache bias of a single run. Results are ns per operation.

const std = @import("std");
const zigkv = @import("zigkv");

const default_keys: usize = 100_000;
const value_sizes = [_]usize{ 8, 256, 4096 };
const rounds: usize = 5;

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

/// Raw nanoseconds for one round; `null` means "not measured yet".
const Timings = struct {
    put: i96 = max,
    get: i96 = max,
    hot: i96 = max,
    miss: i96 = max,
    remove: i96 = max,

    const max: i96 = std.math.maxInt(i96);

    /// Merge two rounds, keeping the fastest sample of each metric.
    fn merge(self: Timings, other: Timings) Timings {
        return .{
            .put = @min(self.put, other.put),
            .get = @min(self.get, other.get),
            .hot = @min(self.hot, other.hot),
            .miss = @min(self.miss, other.miss),
            .remove = @min(self.remove, other.remove),
        };
    }
};

const Result = struct {
    implementation: []const u8,
    value_size: usize,
    put: f64,
    get: f64,
    hot: f64,
    miss: f64,
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
        std.mem.writeInt(u64, key, @intCast(i), .native);
        keys[i] = key[0..];
    }

    // Keys that are guaranteed absent, used for the negative-lookup column.
    const absent_storage = try allocator.alloc([8]u8, key_count);
    defer allocator.free(absent_storage);
    const absent = try allocator.alloc([]const u8, key_count);
    defer allocator.free(absent);
    for (absent_storage, 0..) |*key, i| {
        std.mem.writeInt(u64, key, @intCast(i + key_count), .native);
        absent[i] = key[0..];
    }

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(allocator);

    for (value_sizes) |value_size| {
        const value = try allocator.alloc(u8, value_size);
        defer allocator.free(value);
        @memset(value, @truncate(value_size));

        try results.append(
            allocator,
            try measureStore(allocator, io, keys, absent, value, width_configs[0]),
        );

        // Exercise the width matrix with small values only; the large-value
        // runs dominate memory and are represented by the default widths.
        if (value_size == 8) {
            for (width_configs[1..]) |config| {
                try results.append(
                    allocator,
                    try measureStore(allocator, io, keys, absent, value, config),
                );
            }
        }

        try results.append(allocator, try measureStringHashMap(allocator, io, keys, absent, value));
        try results.append(allocator, try measureStringArrayHashMap(allocator, io, keys, absent, value));
    }

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    const image_bytes = try zigkv.Store.imageSize(.{
        .max_entries = @intCast(key_count * 2),
        .key_bytes = @intCast(key_count * 32 + 4096),
        .value_bytes = @intCast(key_count * 40 + 4096),
    });

    try out.print(
        "zigkv benchmarks: {d} keys, 8-byte keys, best of {d} rounds, image {d} MiB\n\n",
        .{ key_count, rounds, image_bytes / (1024 * 1024) },
    );
    try printMarkdownTable(out, results.items);
    try out.writeAll(
        "\nNote: the std maps store a pointer to the caller's value; zigkv copies\n" ++
            "key and value into the image. The Put column is not directly\n" ++
            "comparable for the 256- and 4096-byte rows.\n",
    );
    try out.flush();
}

fn measureStore(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
    config: WidthConfig,
) !Result {
    var best: Timings = .{};
    for (0..rounds) |_| {
        best = best.merge(try storeRound(allocator, io, keys, absent, value, config));
    }

    const n = keys.len;
    return .{
        .implementation = config.name,
        .value_size = value.len,
        .put = perOp(best.put, n),
        .get = perOp(best.get, n),
        .hot = perOp(best.hot, n),
        .miss = perOp(best.miss, n),
        .remove = perOp(best.remove, n),
    };
}

fn storeRound(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
    config: WidthConfig,
) !Timings {
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

    var timings: Timings = .{};
    var checksum: usize = 0;

    var start = nanoTimestamp(io);
    for (keys) |key| try store.put(key, value);
    timings.put = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| {
        if (store.getView(key)) |found| checksum +%= found.len;
    }
    timings.get = nanoTimestamp(io) - start;

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (store.getView(keys[i & (hot - 1)])) |found| checksum +%= found.len;
    }
    timings.hot = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (absent) |key| {
        if (store.getView(key)) |found| checksum +%= found.len;
    }
    timings.miss = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| _ = store.remove(key);
    timings.remove = nanoTimestamp(io) - start;
    std.debug.assert(store.count() == 0);

    std.mem.doNotOptimizeAway(checksum);
    return timings;
}

fn measureStringHashMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
) !Result {
    var best: Timings = .{};
    for (0..rounds) |_| {
        best = best.merge(try stringHashMapRound(allocator, io, keys, absent, value));
    }

    const n = keys.len;
    return .{
        .implementation = "std.StringHashMap",
        .value_size = value.len,
        .put = perOp(best.put, n),
        .get = perOp(best.get, n),
        .hot = perOp(best.hot, n),
        .miss = perOp(best.miss, n),
        .remove = perOp(best.remove, n),
    };
}

fn stringHashMapRound(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
) !Timings {
    var map: std.StringHashMap([]const u8) = .init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(keys.len));

    const n = keys.len;
    var timings: Timings = .{};
    var checksum: usize = 0;

    var start = nanoTimestamp(io);
    for (keys) |key| try map.put(key, value);
    timings.put = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    timings.get = nanoTimestamp(io) - start;

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (map.get(keys[i & (hot - 1)])) |found| checksum +%= found.len;
    }
    timings.hot = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (absent) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    timings.miss = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| _ = map.remove(key);
    timings.remove = nanoTimestamp(io) - start;
    std.debug.assert(map.count() == 0);

    std.mem.doNotOptimizeAway(checksum);
    return timings;
}

fn measureStringArrayHashMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
) !Result {
    var best: Timings = .{};
    for (0..rounds) |_| {
        best = best.merge(try stringArrayHashMapRound(allocator, io, keys, absent, value));
    }

    const n = keys.len;
    return .{
        .implementation = "std.ArrayHashMap",
        .value_size = value.len,
        .put = perOp(best.put, n),
        .get = perOp(best.get, n),
        .hot = perOp(best.hot, n),
        .miss = perOp(best.miss, n),
        .remove = perOp(best.remove, n),
    };
}

fn stringArrayHashMapRound(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    absent: []const []const u8,
    value: []const u8,
) !Timings {
    var map: std.array_hash_map.String([]const u8) = .empty;
    defer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, keys.len);

    const n = keys.len;
    var timings: Timings = .{};
    var checksum: usize = 0;

    var start = nanoTimestamp(io);
    for (keys) |key| try map.put(allocator, key, value);
    timings.put = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    timings.get = nanoTimestamp(io) - start;

    const hot = @max(1, n / 100);
    start = nanoTimestamp(io);
    for (0..n) |i| {
        if (map.get(keys[i & (hot - 1)])) |found| checksum +%= found.len;
    }
    timings.hot = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (absent) |key| {
        if (map.get(key)) |found| checksum +%= found.len;
    }
    timings.miss = nanoTimestamp(io) - start;

    start = nanoTimestamp(io);
    for (keys) |key| _ = map.swapRemove(key);
    timings.remove = nanoTimestamp(io) - start;
    std.debug.assert(map.entries.len == 0);

    std.mem.doNotOptimizeAway(checksum);
    return timings;
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
    try writeCell(out, "Miss ns/op", metric_width, true);
    try writeCell(out, "Remove ns/op", metric_width, true);
    try out.writeAll("|\n");

    try writeLeftSeparator(out, implementation_width);
    try writeRightSeparator(out, value_width);
    try writeRightSeparator(out, metric_width);
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
        var miss_buffer: [32]u8 = undefined;
        var remove_buffer: [32]u8 = undefined;

        const value_text = try std.fmt.bufPrint(&value_buffer, "{d}", .{result.value_size});
        const put_text = try std.fmt.bufPrint(&put_buffer, "{d:.1}", .{result.put});
        const get_text = try std.fmt.bufPrint(&get_buffer, "{d:.1}", .{result.get});
        const hot_text = try std.fmt.bufPrint(&hot_buffer, "{d:.1}", .{result.hot});
        const miss_text = try std.fmt.bufPrint(&miss_buffer, "{d:.1}", .{result.miss});
        const remove_text = try std.fmt.bufPrint(&remove_buffer, "{d:.1}", .{result.remove});

        try writeCell(out, result.implementation, implementation_width, false);
        try writeCell(out, value_text, value_width, true);
        try writeCell(out, put_text, metric_width, true);
        try writeCell(out, get_text, metric_width, true);
        try writeCell(out, hot_text, metric_width, true);
        try writeCell(out, miss_text, metric_width, true);
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
