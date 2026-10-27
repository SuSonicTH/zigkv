//! Test root for the zigkv library: unit, property, corruption and
//! alloc-failure tests.

const std = @import("std");
const zigkv = @import("zigkv.zig");
const arena = @import("arena.zig");
const format = @import("format.zig");
const hash_mod = @import("hash.zig");
const tables = @import("table.zig");
const image = @import("image.zig");

test "library module is importable" {
    try std.testing.expectEqualStrings("0.1.0", zigkv.version);
}

test "header round-trips across all width combinations" {
    inline for (comptime std.meta.tags(format.HashWidth)) |hash| {
        inline for (comptime std.meta.tags(format.IndexWidth)) |key_index| {
            inline for (comptime std.meta.tags(format.IndexWidth)) |value_index| {
                const header: format.Header = .{
                    .flags = .{
                        .hash = hash,
                        .key_index = key_index,
                        .value_index = value_index,
                    },
                    .table_reserved = 128,
                    .table_size = 7,
                    .key_bytes = 4096,
                    .key_free_head = format.Block(key_index).none,
                    .value_bytes = 8192,
                    .value_free_head = 24,
                };

                var bytes: [format.header_size]u8 = undefined;
                header.encode(&bytes);
                const decoded = try format.Header.decode(&bytes);

                try std.testing.expectEqual(hash, decoded.flags.hash);
                try std.testing.expectEqual(key_index, decoded.flags.key_index);
                try std.testing.expectEqual(value_index, decoded.flags.value_index);
                try std.testing.expectEqual(format.Endian.native, decoded.endian);
                try std.testing.expectEqual(header.table_reserved, decoded.table_reserved);
                try std.testing.expectEqual(header.table_size, decoded.table_size);
                try std.testing.expectEqual(header.key_bytes, decoded.key_bytes);
                try std.testing.expectEqual(header.key_free_head, decoded.key_free_head);
                try std.testing.expectEqual(header.value_bytes, decoded.value_bytes);
                try std.testing.expectEqual(header.value_free_head, decoded.value_free_head);

                try std.testing.expectEqualStrings(format.magic, bytes[0..format.magic.len]);
                try std.testing.expectEqual(
                    header.flags.encode(format.Endian.native),
                    std.mem.readInt(u64, bytes[format.field.flags..][0..8], format.Endian.native),
                );
            }
        }
    }
}

test "flags word encodes widths and both byte-order bits" {
    const all_u64: format.Flags = .{
        .hash = .city64,
        .key_index = .u64,
        .value_index = .u64,
    };
    try std.testing.expectEqual(@as(u64, 0b111), all_u64.encode(.little));
    try std.testing.expectEqual(
        @as(u64, 0b111) | (@as(u64, 1) << 3) | (@as(u64, 1) << 59),
        all_u64.encode(.big),
    );

    const all_32: format.Flags = .{
        .hash = .city32,
        .key_index = .u32,
        .value_index = .u32,
    };
    try std.testing.expectEqual(@as(u64, 0), all_32.encode(.little));

    const default_flags: format.Flags = .{};
    try std.testing.expectEqual(@as(u64, 1), default_flags.encode(.little));

    const decoded = try format.Flags.decode(all_u64.encode(.big));
    try std.testing.expectEqual(format.HashWidth.city64, decoded.hash);
    try std.testing.expectEqual(format.IndexWidth.u64, decoded.key_index);
    try std.testing.expectEqual(format.IndexWidth.u64, decoded.value_index);
}

test "flags decoding rejects reserved bits and mismatched duplicates" {
    try std.testing.expectError(error.Corrupt, format.Flags.decode(@as(u64, 1) << 4));
    try std.testing.expectError(error.Corrupt, format.Flags.decode(@as(u64, 1) << 3));
    try std.testing.expectError(error.Corrupt, format.Flags.decode(@as(u64, 1) << 59));
    try std.testing.expectError(error.Corrupt, format.Flags.decode(@as(u64, 1) << 60));

    _ = try format.Flags.decode((@as(u64, 1) << 3) | (@as(u64, 1) << 59));
}

test "byte-order bootstrap detects both orders and mismatched copies" {
    var bytes: [format.header_size]u8 = @splat(0);
    const flags: format.Flags = .{};

    std.mem.writeInt(u64, bytes[format.field.flags..][0..8], flags.encode(.little), .little);
    try std.testing.expectEqual(format.Endian.little, try format.Flags.detectEndian(&bytes));

    std.mem.writeInt(u64, bytes[format.field.flags..][0..8], flags.encode(.big), .big);
    try std.testing.expectEqual(format.Endian.big, try format.Flags.detectEndian(&bytes));

    var mismatched: [format.header_size]u8 = @splat(0);
    mismatched[format.field.flags] |= @as(u8, 1) << 3;
    try std.testing.expectError(error.Corrupt, format.Flags.detectEndian(&mismatched));
}

test "header rejects short images, bad magic, reserved flags and foreign endian" {
    const header: format.Header = .{
        .flags = .{},
        .table_reserved = 16,
        .table_size = 0,
        .key_bytes = 8,
        .key_free_head = format.Block(.u32).none,
        .value_bytes = 8,
        .value_free_head = format.Block(.u32).none,
    };

    var bytes: [format.header_size]u8 = undefined;
    header.encode(&bytes);
    _ = try format.Header.decode(&bytes);

    try std.testing.expectError(error.Corrupt, format.Header.decode(bytes[0 .. format.header_size - 1]));

    var bad_magic = bytes;
    bad_magic[format.magic.len - 1] = if (bad_magic[format.magic.len - 1] == '1') '2' else '3';
    try std.testing.expectError(error.UnsupportedVersion, format.Header.decode(&bad_magic));

    var bad_flags = bytes;
    const native_flags = std.mem.readInt(
        u64,
        bad_flags[format.field.flags..][0..8],
        format.Endian.native,
    );
    std.mem.writeInt(
        u64,
        bad_flags[format.field.flags..][0..8],
        native_flags | (@as(u64, 1) << 4),
        format.Endian.native,
    );
    try std.testing.expectError(error.Corrupt, format.Header.decode(&bad_flags));

    var foreign_header = header;
    foreign_header.endian = format.Endian.foreign;
    var foreign_bytes: [format.header_size]u8 = undefined;
    foreign_header.encode(&foreign_bytes);
    try std.testing.expectError(
        error.UnsupportedEndianness,
        format.Header.decode(&foreign_bytes),
    );
}

test "table entry accessors across all width combinations" {
    inline for (comptime std.meta.tags(format.HashWidth)) |hash| {
        inline for (comptime std.meta.tags(format.IndexWidth)) |key_index| {
            inline for (comptime std.meta.tags(format.IndexWidth)) |value_index| {
                const Entry = format.TableEntry(hash, key_index, value_index);
                const expected_size = format.hashSize(hash) +
                    format.indexSize(key_index) +
                    format.indexSize(value_index);

                try std.testing.expectEqual(expected_size, @as(u64, Entry.size));
                try std.testing.expectEqual(
                    expected_size,
                    format.entrySize(hash, key_index, value_index),
                );

                const fields: Entry.Fields = .{
                    .hash = switch (hash) {
                        .city32 => 0x89AB_CDEF,
                        .city64 => 0x0123_4567_89AB_CDEF,
                    },
                    .key_off = switch (key_index) {
                        .u32 => 0x0BAD_F00D,
                        .u64 => 0x0123_4567_0BAD_F00D,
                    },
                    .val_off = switch (value_index) {
                        .u32 => 0x0DDC_0FFE,
                        .u64 => 0x0123_4567_0DDC_0FFE,
                    },
                };

                const pos = 3;
                inline for (.{ format.Endian.little, format.Endian.big }) |order| {
                    var bytes: [Entry.size + 8]u8 = @splat(0xAA);
                    Entry.write(&bytes, pos, fields, order);

                    const got = Entry.read(&bytes, pos, order);
                    try std.testing.expectEqual(fields.hash, got.hash);
                    try std.testing.expectEqual(fields.key_off, got.key_off);
                    try std.testing.expectEqual(fields.val_off, got.val_off);
                    try std.testing.expectEqual(fields.hash, Entry.readHash(&bytes, pos, order));

                    for (bytes[0..pos]) |sentinel| {
                        try std.testing.expectEqual(@as(u8, 0xAA), sentinel);
                    }
                    for (bytes[pos + Entry.size ..]) |sentinel| {
                        try std.testing.expectEqual(@as(u8, 0xAA), sentinel);
                    }
                }
            }
        }
    }
}

test "block accessors across index widths" {
    inline for (comptime std.meta.tags(format.IndexWidth)) |width| {
        const B = format.Block(width);
        const expected_header: usize = if (width == .u32) 8 else 16;

        try std.testing.expectEqual(expected_header, B.header_size);
        try std.testing.expectEqual(@as(u64, expected_header), B.min_size);
        try std.testing.expectEqual(format.arenaNone(width), B.none);
        try std.testing.expectEqual(format.blockHeaderSize(width), @as(u64, B.header_size));
        try std.testing.expect(B.none % 8 != 0);

        const size: u64 = if (width == .u32) 40 else 4096;
        const len: u64 = if (width == .u32) 24 else 1024;

        inline for (.{ format.Endian.little, format.Endian.big }) |order| {
            const pos = 3;
            var bytes: [B.header_size + 16]u8 = @splat(0xCC);

            B.writeSize(&bytes, pos, size, order);
            B.writeLen(&bytes, pos, len, order);
            try std.testing.expectEqual(size, B.readSize(&bytes, pos, order));
            try std.testing.expectEqual(len, B.readLen(&bytes, pos, order));

            B.writeNext(&bytes, pos, B.none, order);
            try std.testing.expectEqual(B.none, B.readNext(&bytes, pos, order));

            for (bytes[0..pos]) |sentinel| {
                try std.testing.expectEqual(@as(u8, 0xCC), sentinel);
            }
            for (bytes[pos + B.header_size ..]) |sentinel| {
                try std.testing.expectEqual(@as(u8, 0xCC), sentinel);
            }
        }
    }
}

test "image layout across all width combinations" {
    inline for (comptime std.meta.tags(format.HashWidth)) |hash| {
        inline for (comptime std.meta.tags(format.IndexWidth)) |key_index| {
            inline for (comptime std.meta.tags(format.IndexWidth)) |value_index| {
                const options: image.Options = .{
                    .max_entries = 100,
                    .key_bytes = 100,
                    .value_bytes = 200,
                    .hash = hash,
                    .key_index = key_index,
                    .value_index = value_index,
                };
                const layout = try image.Layout.fromOptions(options);
                const entry_size = format.entrySize(hash, key_index, value_index);

                try std.testing.expectEqual(@as(u64, 128), layout.table_reserved);
                try std.testing.expectEqual(@as(u64, 128) * entry_size, layout.table_bytes);
                try std.testing.expectEqual(@as(u64, 64) + layout.table_bytes, layout.keys_offset);
                try std.testing.expectEqual(@as(u64, 0), layout.keys_offset % 8);
                try std.testing.expectEqual(@as(u64, 104), layout.key_bytes);
                try std.testing.expectEqual(@as(u64, 200), layout.value_bytes);
                try std.testing.expectEqual(layout.keys_offset + layout.key_bytes, layout.values_offset);
                try std.testing.expectEqual(layout.values_offset + layout.value_bytes, layout.file_size);
                try std.testing.expectEqual(layout.file_size, try image.imageSize(options));
                try std.testing.expectEqual(entry_size, layout.entrySize());
                try std.testing.expectEqual(@as(u64, 96), layout.capacity());
                try std.testing.expectEqual(hash, layout.flags.hash);
                try std.testing.expectEqual(key_index, layout.flags.key_index);
                try std.testing.expectEqual(value_index, layout.flags.value_index);
            }
        }
    }
}

test "default image size" {
    try std.testing.expectEqual(@as(u64, 1_130_560), try image.imageSize(.{}));
}

test "slot count rounds up to a power of two with a minimum of 16" {
    const cases = [_]struct { request: u64, expected: u64 }{
        .{ .request = 0, .expected = 16 },
        .{ .request = 1, .expected = 16 },
        .{ .request = 15, .expected = 16 },
        .{ .request = 16, .expected = 16 },
        .{ .request = 17, .expected = 32 },
        .{ .request = 1023, .expected = 1024 },
        .{ .request = 1024, .expected = 1024 },
        .{ .request = 1025, .expected = 2048 },
    };

    for (cases) |case| {
        const layout = try image.Layout.fromOptions(.{
            .max_entries = case.request,
            .key_bytes = 8,
            .value_bytes = 8,
        });
        try std.testing.expectEqual(case.expected, layout.table_reserved);
        try std.testing.expectEqual(case.expected - case.expected / 4, layout.capacity());
    }
}

test "arena capacities are normalized to the minimum block header and 8 bytes" {
    const cases = [_]struct {
        request: u64,
        width: format.IndexWidth,
        expected: u64,
    }{
        .{ .request = 0, .width = .u32, .expected = 8 },
        .{ .request = 1, .width = .u32, .expected = 8 },
        .{ .request = 8, .width = .u32, .expected = 8 },
        .{ .request = 9, .width = .u32, .expected = 16 },
        .{ .request = 15, .width = .u32, .expected = 16 },
        .{ .request = 17, .width = .u32, .expected = 24 },
        .{ .request = 0, .width = .u64, .expected = 16 },
        .{ .request = 1, .width = .u64, .expected = 16 },
        .{ .request = 16, .width = .u64, .expected = 16 },
        .{ .request = 17, .width = .u64, .expected = 24 },
    };

    for (cases) |case| {
        const key_layout = try image.Layout.fromOptions(.{
            .key_bytes = case.request,
            .value_bytes = 8,
            .key_index = case.width,
        });
        try std.testing.expectEqual(case.expected, key_layout.key_bytes);

        const value_layout = try image.Layout.fromOptions(.{
            .key_bytes = 8,
            .value_bytes = case.request,
            .value_index = case.width,
        });
        try std.testing.expectEqual(case.expected, value_layout.value_bytes);
    }
}

test "32-bit arenas accept exactly the maximum representable capacity" {
    const max_u32 = format.arenaMax(.u32);
    const layout = try image.Layout.fromOptions(.{
        .key_bytes = max_u32,
        .value_bytes = 8,
        .key_index = .u32,
    });
    try std.testing.expectEqual(max_u32, layout.key_bytes);
    try std.testing.expectError(
        error.ValueTooLarge,
        image.Layout.fromOptions(.{
            .key_bytes = max_u32 + 8,
            .value_bytes = 8,
            .key_index = .u32,
        }),
    );
}

test "layout rejects overflowing options" {
    try std.testing.expectError(
        error.OutOfSpace,
        image.Layout.fromOptions(.{ .max_entries = std.math.maxInt(u64) }),
    );

    try std.testing.expectError(
        error.OutOfSpace,
        image.Layout.fromOptions(.{
            .max_entries = @as(u64, 1) << 63,
            .hash = .city64,
            .key_index = .u64,
            .value_index = .u64,
        }),
    );

    try std.testing.expectError(
        error.ValueTooLarge,
        image.Layout.fromOptions(.{
            .key_bytes = @as(u64, 0x1_0000_0000),
            .key_index = .u32,
        }),
    );

    try std.testing.expectError(
        error.ValueTooLarge,
        image.Layout.fromOptions(.{
            .value_bytes = @as(u64, 0x1_0000_0000),
            .value_index = .u32,
        }),
    );

    try std.testing.expectError(
        error.OutOfSpace,
        image.Layout.fromOptions(.{
            .key_bytes = std.math.maxInt(u64) - 3,
            .key_index = .u64,
        }),
    );

    try std.testing.expectError(
        error.OutOfSpace,
        image.Layout.fromOptions(.{
            .key_bytes = std.math.maxInt(u64) - 7,
            .key_index = .u64,
        }),
    );
}

test "arena u32 splits, coalesces and reclaims the whole section" {
    const Block = format.Block(.u32);
    var memory: [128]u8 = undefined;
    var a = try arena.Arena.initEmpty(&memory, .u32, .little);

    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 128), Block.readSize(&memory, 0, .little));
    try std.testing.expectEqual(Block.none, Block.readNext(&memory, 0, .little));

    const first = try a.alloc(8);
    try std.testing.expectEqual(@as(u64, 0), first);
    try std.testing.expectEqual(@as(u64, 16), a.blockSize(first));
    try std.testing.expectEqual(@as(u64, 8), @as(u64, @intCast(a.payload(first).len)));
    try std.testing.expectEqual(@as(u64, 16), a.free_head);
    try std.testing.expectEqual(@as(u64, 112), Block.readSize(&memory, 16, .little));

    a.payloadMut(first)[0] = 0xAB;
    try std.testing.expectEqual(@as(u8, 0xAB), a.payload(first)[0]);

    const second = try a.alloc(0);
    try std.testing.expectEqual(@as(u64, 16), second);
    try std.testing.expectEqual(@as(u64, 8), a.blockSize(second));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @intCast(a.payload(second).len)));
    try std.testing.expectEqual(@as(u64, 24), a.free_head);
    try std.testing.expectEqual(@as(u64, 104), Block.readSize(&memory, 24, .little));

    try a.free(first);
    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 16), Block.readSize(&memory, 0, .little));
    try std.testing.expectEqual(@as(u64, 24), Block.readNext(&memory, 0, .little));

    try a.free(second);
    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 128), Block.readSize(&memory, 0, .little));
    try std.testing.expectEqual(Block.none, Block.readNext(&memory, 0, .little));

    const big = try a.alloc(120);
    try std.testing.expectEqual(@as(u64, 0), big);
    try std.testing.expectEqual(@as(u64, 128), a.blockSize(big));
    try std.testing.expectEqual(Block.none, a.free_head);
    try std.testing.expectError(error.OutOfSpace, a.alloc(0));
    try std.testing.expectEqual(Block.none, a.free_head);

    try a.free(big);
    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 128), Block.readSize(&memory, 0, .little));
}

test "arena first-fit skips a too-small free block" {
    const Block = format.Block(.u32);
    var memory: [64]u8 = undefined;
    var a = try arena.Arena.initEmpty(&memory, .u32, .little);

    const first = try a.alloc(0);
    const second = try a.alloc(0);
    try std.testing.expectEqual(@as(u64, 0), first);
    try std.testing.expectEqual(@as(u64, 8), second);

    try a.free(first);
    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 16), Block.readNext(&memory, 0, .little));

    const third = try a.alloc(8);
    try std.testing.expectEqual(@as(u64, 16), third);
    try std.testing.expectEqual(@as(u64, 16), a.blockSize(third));

    // The skipped 8-byte block at offset 0 is still the head and now points at
    // the split remainder at offset 32.
    try std.testing.expectEqual(@as(u64, 0), a.free_head);
    try std.testing.expectEqual(@as(u64, 8), Block.readSize(&memory, 0, .little));
    try std.testing.expectEqual(@as(u64, 32), Block.readNext(&memory, 0, .little));
    try std.testing.expectEqual(@as(u64, 32), Block.readSize(&memory, 32, .little));
    try std.testing.expectEqual(Block.none, Block.readNext(&memory, 32, .little));
}

test "arena u64 consumes an 8-byte tail that cannot hold a header" {
    const Block = format.Block(.u64);
    var memory: [32]u8 = undefined;
    var a = try arena.Arena.initEmpty(&memory, .u64, .little);

    const off = try a.alloc(8);
    try std.testing.expectEqual(@as(u64, 0), off);
    try std.testing.expectEqual(@as(u64, 32), @as(u64, @intCast(a.blockSize(off))));
    try std.testing.expectEqual(@as(u64, 32), Block.readSize(&memory, 0, .little));
    try std.testing.expectEqual(Block.none, a.free_head);
    try std.testing.expectError(error.OutOfSpace, a.alloc(0));
}

test "failed arena allocation leaves the free list intact" {
    const Block = format.Block(.u32);
    var memory: [32]u8 = undefined;
    var a = try arena.Arena.initEmpty(&memory, .u32, .little);

    const first = try a.alloc(8);
    try std.testing.expectEqual(@as(u64, 16), a.free_head);
    try std.testing.expectError(error.OutOfSpace, a.alloc(16));
    try std.testing.expectEqual(@as(u64, 16), a.free_head);
    try std.testing.expectEqual(@as(u64, 16), Block.readSize(&memory, 16, .little));
    try std.testing.expectEqual(Block.none, Block.readNext(&memory, 16, .little));

    try a.free(first);
    const full = try a.alloc(24);
    try std.testing.expectEqual(@as(u64, 0), full);
    try std.testing.expectEqual(@as(u64, 32), a.blockSize(full));
}

test "arena rejects malformed construction and invalid frees" {
    try std.testing.expectError(error.Corrupt, arena.Arena.initEmpty(&[_]u8{}, .u32, .little));
    var too_short: [7]u8 = undefined;
    try std.testing.expectError(error.Corrupt, arena.Arena.initEmpty(&too_short, .u32, .little));
    var unaligned: [9]u8 = undefined;
    try std.testing.expectError(error.Corrupt, arena.Arena.initEmpty(&unaligned, .u32, .little));
    var short_u64: [15]u8 = undefined;
    try std.testing.expectError(error.Corrupt, arena.Arena.initEmpty(&short_u64, .u64, .little));

    var memory: [32]u8 = undefined;
    var a = try arena.Arena.initEmpty(&memory, .u32, .little);
    const off = try a.alloc(8);

    try std.testing.expectError(error.Corrupt, a.free(4));
    try std.testing.expectError(error.Corrupt, a.free(32));
    try a.free(off);
    try std.testing.expectError(error.Corrupt, a.free(off));
}

test "arena property: random alloc/free matches a bitmap reference" {
    try runArenaProperty(.u32, .little, 0xA11CE_0001);
    try runArenaProperty(.u32, .big, 0xA11CE_0002);
    try runArenaProperty(.u64, .little, 0xA11CE_0003);
    try runArenaProperty(.u64, .big, 0xA11CE_0004);
}

const AllocRange = struct {
    off: u64,
    block_size: u64,
};

const LiveAlloc = struct {
    off: u64,
    block_size: u64,
    len: u64,
    id: u32,
};

const ReferenceArena = struct {
    used: []bool,
    header_size: u64,

    fn init(allocator: std.mem.Allocator, capacity: usize, header_size: u64) !ReferenceArena {
        const used = try allocator.alloc(bool, capacity);
        @memset(used, false);
        return .{ .used = used, .header_size = header_size };
    }

    fn deinit(self: *ReferenceArena, allocator: std.mem.Allocator) void {
        allocator.free(self.used);
    }

    fn mark(self: *ReferenceArena, off: u64, size: u64, value: bool) void {
        @memset(self.used[@intCast(off)..][0..@intCast(size)], value);
    }

    fn alloc(self: *ReferenceArena, len: u64) ?AllocRange {
        const capacity: u64 = @intCast(self.used.len);
        const with_header = std.math.add(u64, len, self.header_size) catch return null;
        const padded = std.math.add(u64, with_header, 7) catch return null;
        const need = padded & ~@as(u64, 7);
        if (need > capacity) return null;

        var off: u64 = 0;
        while (off + need <= capacity) : (off += 8) {
            var fits = true;
            var i = off;
            while (i < off + need) : (i += 1) {
                if (self.used[@intCast(i)]) {
                    fits = false;
                    break;
                }
            }
            if (!fits) continue;

            // The free list is coalesced, so this run is exactly one free block.
            var run = need;
            while (off + run < capacity and !self.used[@intCast(off + run)]) : (run += 1) {}

            const block_size = if (run - need < self.header_size) run else need;
            self.mark(off, block_size, true);
            return .{ .off = off, .block_size = block_size };
        }
        return null;
    }

    fn free(self: *ReferenceArena, off: u64, block_size: u64) void {
        self.mark(off, block_size, false);
    }
};

fn runArenaProperty(comptime width: format.IndexWidth, order: format.Endian, seed: u64) !void {
    const allocator = std.testing.allocator;
    const capacity: usize = 2048;
    const Block = format.Block(width);

    const memory = try allocator.alloc(u8, capacity);
    defer allocator.free(memory);

    var actual = try arena.Arena.initEmpty(memory, width, order);
    var reference = try ReferenceArena.init(allocator, capacity, @intCast(Block.header_size));
    defer reference.deinit(allocator);

    var live: std.ArrayList(LiveAlloc) = .empty;
    defer live.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var next_id: u32 = 1;

    var step: usize = 0;
    while (step < 2000) : (step += 1) {
        const should_alloc = live.items.len == 0 or
            random.uintLessThan(u8, 100) < 60;

        if (should_alloc) {
            const len = random.uintLessThan(u64, 257);
            const expected = reference.alloc(len);

            const got = actual.alloc(len) catch |err| {
                try std.testing.expectEqual(error.OutOfSpace, err);
                try std.testing.expect(expected == null);
                continue;
            };

            const want = expected orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(want.off, got);
            try std.testing.expectEqual(want.block_size, actual.blockSize(got));

            const payload = actual.payloadMut(got);
            try std.testing.expectEqual(len, @as(u64, @intCast(payload.len)));
            fillPattern(payload, next_id);

            try live.append(allocator, .{
                .off = got,
                .block_size = want.block_size,
                .len = len,
                .id = next_id,
            });
            next_id +%= 1;
        } else {
            const index = random.uintLessThan(usize, live.items.len);
            const item = live.swapRemove(index);
            try actual.free(item.off);
            reference.free(item.off, item.block_size);
        }

        for (live.items) |item| {
            try checkPattern(actual.payload(item.off), item.id);
        }
        try checkArenaInvariants(&actual, &reference, width, order);
    }

    // Freeing everything must collapse the arena back into one full block.
    for (live.items) |item| {
        try actual.free(item.off);
        reference.free(item.off, item.block_size);
    }
    live.clearRetainingCapacity();

    try checkArenaInvariants(&actual, &reference, width, order);
    try std.testing.expectEqual(@as(u64, 0), actual.free_head);
    try std.testing.expectEqual(@as(u64, capacity), Block.readSize(actual.memory, 0, order));
}

fn checkArenaInvariants(
    actual: *const arena.Arena,
    reference: *const ReferenceArena,
    comptime width: format.IndexWidth,
    order: format.Endian,
) !void {
    const Block = format.Block(width);
    const testing = std.testing;
    const capacity: u64 = @intCast(actual.memory.len);
    const header_size: u64 = @intCast(Block.header_size);

    // Free list: in bounds, aligned, sorted, non-adjacent and cycle-free.
    var prev: u64 = Block.none;
    var cur = actual.free_head;
    var free_nodes: u64 = 0;
    while (cur != Block.none) {
        try testing.expect(cur < capacity);
        try testing.expect(cur % 8 == 0);

        const size = Block.readSize(actual.memory, @intCast(cur), order);
        try testing.expect(size >= Block.min_size);
        try testing.expect(size % 8 == 0);
        try testing.expect(size <= capacity - cur);

        if (prev != Block.none) {
            const prev_size = Block.readSize(actual.memory, @intCast(prev), order);
            try testing.expect(cur > prev);
            try testing.expect(prev + prev_size < cur);
        }

        prev = cur;
        cur = Block.readNext(actual.memory, @intCast(cur), order);
        free_nodes += 1;
        try testing.expect(free_nodes <= capacity / Block.min_size + 1);
    }

    // Tiling: blocks cover the arena exactly and agree with the bitmap.
    var free_cursor = actual.free_head;
    var off: u64 = 0;
    var tiles: u64 = 0;
    while (off < capacity) {
        const size = Block.readSize(actual.memory, @intCast(off), order);
        try testing.expect(size >= Block.min_size);
        try testing.expect(size % 8 == 0);
        try testing.expect(size <= capacity - off);

        if (free_cursor != Block.none and free_cursor == off) {
            try testing.expectEqual(
                size,
                Block.readSize(actual.memory, @intCast(free_cursor), order),
            );
            for (reference.used[@intCast(off)..][0..@intCast(size)]) |used| {
                try testing.expect(!used);
            }
            free_cursor = Block.readNext(actual.memory, @intCast(free_cursor), order);
        } else {
            const len = Block.readLen(actual.memory, @intCast(off), order);
            try testing.expect(len <= size - header_size);
            for (reference.used[@intCast(off)..][0..@intCast(size)]) |used| {
                try testing.expect(used);
            }
        }

        off += size;
        tiles += 1;
        try testing.expect(tiles <= capacity / Block.min_size + 1);
    }
    try testing.expectEqual(capacity, off);
    try testing.expectEqual(Block.none, free_cursor);
}

fn fillPattern(bytes: []u8, id: u32) void {
    for (bytes, 0..) |*byte, i| {
        byte.* = patternByte(id, i);
    }
}

fn checkPattern(bytes: []const u8, id: u32) !void {
    for (bytes, 0..) |byte, i| {
        try std.testing.expectEqual(patternByte(id, i), byte);
    }
}

fn patternByte(id: u32, index: usize) u8 {
    const seed: u64 = @as(u64, id) *% 31;
    return @truncate(seed +% @as(u64, @intCast(index)) *% 17);
}

test "hash uses CityHash vectors and remaps zero" {
    try std.testing.expectEqual(@as(u64, 0x9ae16a3b2f90404f), hash_mod.hashKey("", .city64));
    try std.testing.expectEqual(@as(u64, 0xdc56d17a), hash_mod.hashKey("", .city32));
    try std.testing.expectEqual(@as(u64, 0xb3454265b6df75e3), hash_mod.hashKey("a", .city64));
    try std.testing.expectEqual(@as(u64, 0x3c973d4d), hash_mod.hashKey("a", .city32));

    try std.testing.expectEqual(@as(u64, 1), hash_mod.remap(0));
    try std.testing.expectEqual(@as(u64, 0xFFFF), hash_mod.remap(0xFFFF));
    try std.testing.expect(hash_mod.hashKey("anything", .city32) <= std.math.maxInt(u32));
}

test "table supports all width combinations" {
    inline for (comptime std.meta.tags(format.HashWidth)) |hash_width| {
        inline for (comptime std.meta.tags(format.IndexWidth)) |key_width| {
            inline for (comptime std.meta.tags(format.IndexWidth)) |value_width| {
                const flags: format.Flags = .{
                    .hash = hash_width,
                    .key_index = key_width,
                    .value_index = value_width,
                };
                const entry_size = comptime format.entrySize(hash_width, key_width, value_width);
                const slots: u64 = 16;
                const injectable_hash: u64 = 0x1234;

                var table_memory: [16 * entry_size]u8 = undefined;
                var table = try tables.Table.formatEmpty(&table_memory, flags, slots, .little);

                var key_memory: [256]u8 = undefined;
                var keys = try arena.Arena.initEmpty(&key_memory, key_width, .little);

                const texts = [_][]const u8{ "alpha", "beta", "gamma" };
                var key_offsets: [texts.len]u64 = undefined;
                for (texts, 0..) |text, i| {
                    key_offsets[i] = try putArenaKey(&keys, text);
                    try table.insert(
                        &keys,
                        text,
                        injectable_hash,
                        key_offsets[i],
                        @intCast(i + 1),
                    );
                }

                try std.testing.expectEqual(@as(u64, 3), table.count);
                try std.testing.expectEqual(entry_size, table.entrySize());
                try std.testing.expectEqual(@as(u64, 12), table.maxEntries());

                for (texts, 0..) |text, i| {
                    const slot = table.lookup(&keys, text, injectable_hash) orelse
                        return error.TestUnexpectedResult;
                    try std.testing.expectEqual(@as(u64, 4 + i), slot.index);
                    try std.testing.expectEqual(injectable_hash, slot.entry.hash);
                    try std.testing.expectEqual(key_offsets[i], slot.entry.key_off);
                    try std.testing.expectEqual(@as(u64, i + 1), slot.entry.val_off);

                    const entry = table.entryAt(slot.index);
                    try std.testing.expectEqual(key_offsets[i], entry.key_off);
                }

                const removed = table.remove(&keys, "beta", injectable_hash) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(u64, 5), removed.index);
                try std.testing.expectEqual(key_offsets[1], removed.entry.key_off);
                try std.testing.expectEqual(@as(u64, 2), removed.entry.val_off);
                try std.testing.expectEqual(@as(u64, 2), table.count);
                try std.testing.expect(table.lookup(&keys, "beta", injectable_hash) == null);
                try std.testing.expect(table.lookup(&keys, "alpha", injectable_hash) != null);
                try std.testing.expect(table.lookup(&keys, "gamma", injectable_hash) != null);

                try std.testing.expect(table.remove(&keys, "missing", 1) == null);
                try std.testing.expectEqual(@as(u64, 2), table.count);

                const alpha = table.lookup(&keys, "alpha", injectable_hash).?;
                table.setValueOffset(alpha.index, 999);
                try std.testing.expectEqual(@as(u64, 999), table.entryAt(alpha.index).val_off);
            }
        }
    }
}

test "table backward-shift moves entries whose home is before the hole" {
    const flags: format.Flags = .{};
    var table_memory: [16 * 16]u8 = undefined;
    var table = try tables.Table.formatEmpty(&table_memory, flags, 16, .little);

    var key_memory: [128]u8 = undefined;
    var keys = try arena.Arena.initEmpty(&key_memory, .u32, .little);

    const a_off = try putArenaKey(&keys, "a");
    const b_off = try putArenaKey(&keys, "b");
    const c_off = try putArenaKey(&keys, "c");

    try table.insert(&keys, "a", 16, a_off, 1);
    try table.insert(&keys, "b", 16, b_off, 2);
    try table.insert(&keys, "c", 18, c_off, 3);

    try std.testing.expectEqual(@as(u64, 0), table.entryAt(0).hash & 15);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(1).hash & 15);
    try std.testing.expectEqual(@as(u64, 2), table.entryAt(2).hash & 15);

    _ = table.remove(&keys, "a", 16);
    try std.testing.expectEqual(@as(u64, 2), table.count);
    try std.testing.expectEqual(b_off, table.entryAt(0).key_off);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(1).hash);
    try std.testing.expectEqual(c_off, table.entryAt(2).key_off);
    try std.testing.expect(table.lookup(&keys, "b", 16) != null);
    try std.testing.expect(table.lookup(&keys, "c", 18) != null);

    _ = table.remove(&keys, "b", 16);
    try std.testing.expectEqual(@as(u64, 1), table.count);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(0).hash);
    try std.testing.expectEqual(c_off, table.entryAt(2).key_off);
    try std.testing.expect(table.lookup(&keys, "c", 18) != null);
}

test "table backward-shift keeps entries whose home lies inside the gap" {
    const flags: format.Flags = .{};
    var table_memory: [16 * 16]u8 = undefined;
    var table = try tables.Table.formatEmpty(&table_memory, flags, 16, .little);

    var key_memory: [128]u8 = undefined;
    var keys = try arena.Arena.initEmpty(&key_memory, .u32, .little);

    const a_off = try putArenaKey(&keys, "a");
    const b_off = try putArenaKey(&keys, "b");
    const c_off = try putArenaKey(&keys, "c");

    try table.insert(&keys, "a", 16, a_off, 1);
    try table.insert(&keys, "b", 17, b_off, 2);
    try table.insert(&keys, "c", 18, c_off, 3);

    _ = table.remove(&keys, "a", 16);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(0).hash);
    try std.testing.expectEqual(b_off, table.entryAt(1).key_off);
    try std.testing.expectEqual(c_off, table.entryAt(2).key_off);
    try std.testing.expect(table.lookup(&keys, "b", 17) != null);
    try std.testing.expect(table.lookup(&keys, "c", 18) != null);

    _ = table.remove(&keys, "b", 17);
    try std.testing.expectEqual(@as(u64, 1), table.count);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(1).hash);
    try std.testing.expectEqual(c_off, table.entryAt(2).key_off);
    try std.testing.expect(table.lookup(&keys, "c", 18) != null);
}

test "table probes wrap around slot zero" {
    const flags: format.Flags = .{};
    var table_memory: [16 * 16]u8 = undefined;
    var table = try tables.Table.formatEmpty(&table_memory, flags, 16, .little);

    var key_memory: [128]u8 = undefined;
    var keys = try arena.Arena.initEmpty(&key_memory, .u32, .little);

    const a_off = try putArenaKey(&keys, "a");
    const b_off = try putArenaKey(&keys, "b");
    const c_off = try putArenaKey(&keys, "c");

    try table.insert(&keys, "a", 31, a_off, 1);
    try table.insert(&keys, "b", 31, b_off, 2);
    try table.insert(&keys, "c", 14, c_off, 3);

    try std.testing.expectEqual(a_off, table.entryAt(15).key_off);
    try std.testing.expectEqual(b_off, table.entryAt(0).key_off);
    try std.testing.expectEqual(c_off, table.entryAt(14).key_off);
    try std.testing.expect(table.lookup(&keys, "b", 31) != null);

    _ = table.remove(&keys, "a", 31);
    try std.testing.expectEqual(@as(u64, 2), table.count);
    try std.testing.expectEqual(b_off, table.entryAt(15).key_off);
    try std.testing.expectEqual(@as(u64, 0), table.entryAt(0).hash);
    try std.testing.expectEqual(c_off, table.entryAt(14).key_off);
    try std.testing.expect(table.lookup(&keys, "a", 31) == null);
    try std.testing.expect(table.lookup(&keys, "b", 31) != null);

    _ = table.remove(&keys, "c", 14);
    try std.testing.expectEqual(@as(u64, 1), table.count);
    try std.testing.expectEqual(b_off, table.entryAt(15).key_off);
    try std.testing.expect(table.lookup(&keys, "b", 31) != null);
}

test "table enforces the 0.75 load factor and accounts for deletes" {
    const flags: format.Flags = .{};
    var table_memory: [16 * 16]u8 = undefined;
    var table = try tables.Table.formatEmpty(&table_memory, flags, 16, .little);

    var key_memory: [512]u8 = undefined;
    var keys = try arena.Arena.initEmpty(&key_memory, .u32, .little);

    var buffer: [16]u8 = undefined;
    var i: u64 = 0;
    while (i < 12) : (i += 1) {
        const text = try std.fmt.bufPrint(&buffer, "k{d}", .{i});
        const off = try putArenaKey(&keys, text);
        try table.insert(&keys, text, i + 1, off, i + 1);
    }

    try std.testing.expectEqual(@as(u64, 12), table.count);
    try std.testing.expectEqual(@as(u64, 12), table.maxEntries());

    const extra_off = try putArenaKey(&keys, "extra");
    try std.testing.expectError(
        error.TableFull,
        table.insert(&keys, "extra", 100, extra_off, 100),
    );
    try std.testing.expectEqual(@as(u64, 12), table.count);
    try std.testing.expect(table.lookup(&keys, "extra", 100) == null);

    _ = table.remove(&keys, "k0", 1);
    try std.testing.expectEqual(@as(u64, 11), table.count);

    try table.insert(&keys, "extra", 100, extra_off, 100);
    try std.testing.expectEqual(@as(u64, 12), table.count);
    try std.testing.expect(table.lookup(&keys, "extra", 100) != null);
}

test "table init rejects malformed shape and load accounting" {
    const flags: format.Flags = .{};
    var memory: [16 * 16]u8 = undefined;

    try std.testing.expectError(
        error.Corrupt,
        tables.Table.init(&memory, flags, 8, .little, 0),
    );
    try std.testing.expectError(
        error.Corrupt,
        tables.Table.init(&memory, flags, 32, .little, 0),
    );
    try std.testing.expectError(
        error.Corrupt,
        tables.Table.init(&memory, flags, 16, .little, 13),
    );

    var non_power_memory: [24 * 16]u8 = undefined;
    try std.testing.expectError(
        error.Corrupt,
        tables.Table.init(&non_power_memory, flags, 24, .little, 0),
    );

    const table = try tables.Table.init(&memory, flags, 16, .little, 12);
    try std.testing.expectEqual(@as(u64, 12), table.count);
}

fn putArenaKey(keys: *arena.Arena, text: []const u8) !u64 {
    const off = try keys.alloc(text.len);
    @memcpy(keys.payloadMut(off), text);
    return off;
}

test "store basic put, get, exists and remove" {
    const allocator = std.testing.allocator;
    const options: zigkv.Store.Options = .{
        .max_entries = 64,
        .key_bytes = 256,
        .value_bytes = 256,
    };

    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();

    try std.testing.expectEqual(
        @as(usize, @intCast(try zigkv.Store.imageSize(options))),
        store.memory.len,
    );
    try std.testing.expectEqual(@as(u64, 48), store.capacity());
    try std.testing.expectEqual(@as(u64, 0), store.count());
    try std.testing.expectEqual(@as(u64, 0), store.generation);

    try std.testing.expect(store.getView("missing") == null);
    try std.testing.expect(store.exists("missing") == null);
    try std.testing.expect(!store.remove("missing"));
    var scratch: [16]u8 = undefined;
    try std.testing.expect((try store.get("missing", &scratch)) == null);

    try store.put("hello", "world");
    try std.testing.expectEqual(@as(u64, 1), store.count());
    try std.testing.expectEqual(@as(u64, 1), store.generation);
    try std.testing.expectEqual(@as(u64, 5), store.exists("hello").?);
    try std.testing.expectEqualStrings("world", store.getView("hello").?);

    var small: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, store.get("hello", &small));

    var exact: [5]u8 = undefined;
    try std.testing.expectEqualStrings("world", (try store.get("hello", &exact)).?);

    const copy = (try store.getAlloc("hello", allocator)).?;
    defer allocator.free(copy);
    try std.testing.expectEqualStrings("world", copy);
    try checkStoreHeader(&store);

    try store.put("hello", "there");
    try std.testing.expectEqual(@as(u64, 1), store.count());
    try std.testing.expectEqual(@as(u64, 2), store.generation);
    try std.testing.expectEqualStrings("there", store.getView("hello").?);
    try checkStoreHeader(&store);

    try std.testing.expect(store.remove("hello"));
    try std.testing.expectEqual(@as(u64, 0), store.count());
    try std.testing.expectEqual(@as(u64, 3), store.generation);
    try std.testing.expect(store.exists("hello") == null);
    try checkStoreHeader(&store);
}

test "store supports empty keys, empty values and binary data" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 128,
    });
    defer store.deinit();

    try store.put("", "");
    try std.testing.expectEqual(@as(u64, 0), store.exists("").?);
    var empty: [0]u8 = .{};
    try std.testing.expectEqual(@as(usize, 0), (try store.get("", &empty)).?.len);
    try std.testing.expectEqual(@as(usize, 0), store.getView("").?.len);

    const empty_copy = (try store.getAlloc("", allocator)).?;
    defer allocator.free(empty_copy);
    try std.testing.expectEqual(@as(usize, 0), empty_copy.len);

    const binary_key = [_]u8{ 0, 1, 2, 0xFF, 0 };
    const binary_value = [_]u8{ 0xFF, 0, 0x7F, 0x80, 1, 2 };
    try store.put(&binary_key, &binary_value);
    try std.testing.expectEqual(@as(u64, binary_value.len), store.exists(&binary_key).?);
    try std.testing.expectEqualSlices(u8, &binary_value, store.getView(&binary_key).?);

    var binary_copy: [binary_value.len]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &binary_value,
        (try store.get(&binary_key, &binary_copy)).?,
    );

    try std.testing.expect(store.remove(""));
    try std.testing.expect(store.exists("") == null);
    try std.testing.expect(store.exists(&binary_key) != null);
    try checkStoreHeader(&store);
}

test "store overwrite grows, shrinks and splits value blocks" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 256,
    });
    defer store.deinit();

    var large: [100]u8 = undefined;
    @memset(&large, 'A');
    try store.put("k", &large);
    const first_off = storeValueOff(&store, "k");

    // Shrink in place, then reclaim the split tail for a zero-length value.
    try store.put("k", "12345678");
    try std.testing.expectEqual(first_off, storeValueOff(&store, "k"));
    try std.testing.expectEqual(@as(u64, 16), store.values.blockSize(first_off));
    try std.testing.expectEqualStrings("12345678", store.getView("k").?);

    try store.put("j", "");
    try std.testing.expectEqual(first_off + 16, storeValueOff(&store, "j"));
    try std.testing.expectEqual(@as(u64, 0), store.exists("j").?);
    try std.testing.expectEqual(@as(u64, 2), store.count());

    // Grow within the existing block, then force a new block.
    try store.put("g", "a");
    const g_off = storeValueOff(&store, "g");
    try store.put("g", "12345678");
    try std.testing.expectEqual(g_off, storeValueOff(&store, "g"));
    try std.testing.expectEqualStrings("12345678", store.getView("g").?);

    try store.put("g", "123456789");
    const g2_off = storeValueOff(&store, "g");
    try std.testing.expect(g2_off != g_off);
    try std.testing.expectEqualStrings("123456789", store.getView("g").?);
    try std.testing.expectEqual(@as(u64, 3), store.count());
    try checkStoreHeader(&store);
}

test "store keeps failure atomicity on size, space and table limits" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 64,
        .key_bytes = 128,
        .value_bytes = 64,
    });
    defer store.deinit();

    var eight: [8]u8 = undefined;
    @memset(&eight, 'x');
    var sixteen: [16]u8 = undefined;
    @memset(&sixteen, 'y');

    try store.put("a", &eight);
    try store.put("b", &eight);
    try store.put("c", &sixteen);
    try std.testing.expect(store.remove("b"));

    const count_before = store.count();
    const generation_before = store.generation;
    const key_head_before = store.keys.free_head;
    const value_head_before = store.values.free_head;

    var forty: [40]u8 = undefined;
    @memset(&forty, 'z');
    try std.testing.expectError(error.OutOfSpace, store.put("d", &forty));
    try std.testing.expectEqual(count_before, store.count());
    try std.testing.expectEqual(generation_before, store.generation);
    try std.testing.expectEqual(key_head_before, store.keys.free_head);
    try std.testing.expectEqual(value_head_before, store.values.free_head);
    try std.testing.expect(store.exists("d") == null);
    try std.testing.expectEqualSlices(u8, &eight, store.getView("a").?);
    try std.testing.expectEqualSlices(u8, &sixteen, store.getView("c").?);

    // A growing overwrite must also leave the old value intact when the new
    // block cannot be allocated.
    var forty_eight: [48]u8 = undefined;
    @memset(&forty_eight, 'w');
    try std.testing.expectError(error.OutOfSpace, store.put("a", &forty_eight));
    try std.testing.expectEqual(count_before, store.count());
    try std.testing.expectEqual(generation_before, store.generation);
    try std.testing.expectEqualSlices(u8, &eight, store.getView("a").?);
    try std.testing.expectEqual(key_head_before, store.keys.free_head);
    try std.testing.expectEqual(value_head_before, store.values.free_head);

    var long_key: [200]u8 = undefined;
    @memset(&long_key, 'k');
    try std.testing.expectError(error.KeyTooLarge, store.put(&long_key, "v"));

    var too_big_value: [60]u8 = undefined;
    @memset(&too_big_value, 'v');
    try std.testing.expectError(error.ValueTooLarge, store.put("e", &too_big_value));

    try std.testing.expectEqual(count_before, store.count());
    try std.testing.expectEqual(generation_before, store.generation);
    try checkStoreHeader(&store);

    try store.put("e", "");
    try std.testing.expectEqual(@as(u64, 3), store.count());
    try std.testing.expect(store.exists("e") != null);
}

test "store enforces TableFull but still allows overwrites" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 256,
        .value_bytes = 256,
    });
    defer store.deinit();

    var buffer: [16]u8 = undefined;
    var i: u64 = 0;
    while (i < 12) : (i += 1) {
        const key = try std.fmt.bufPrint(&buffer, "k{d}", .{i});
        try store.put(key, "value");
    }
    try std.testing.expectEqual(@as(u64, 12), store.count());
    try std.testing.expectEqual(@as(u64, 12), store.capacity());

    try std.testing.expectError(error.TableFull, store.put("extra", "value"));
    try std.testing.expectEqual(@as(u64, 12), store.count());
    try std.testing.expect(store.exists("extra") == null);

    try store.put("k5", "updated");
    try std.testing.expectEqual(@as(u64, 12), store.count());
    try std.testing.expectEqualStrings("updated", store.getView("k5").?);

    try std.testing.expect(store.remove("k5"));
    try store.put("extra", "value");
    try std.testing.expectEqual(@as(u64, 12), store.count());
    try std.testing.expect(store.exists("extra") != null);
    try checkStoreHeader(&store);
}

test "store works across all width combinations" {
    const allocator = std.testing.allocator;

    inline for (comptime std.meta.tags(format.HashWidth)) |hash_width| {
        inline for (comptime std.meta.tags(format.IndexWidth)) |key_width| {
            inline for (comptime std.meta.tags(format.IndexWidth)) |value_width| {
                const options: zigkv.Store.Options = .{
                    .max_entries = 16,
                    .key_bytes = 128,
                    .value_bytes = 128,
                    .hash = hash_width,
                    .key_index = key_width,
                    .value_index = value_width,
                };
                var store = try zigkv.Store.init(allocator, options);
                defer store.deinit();

                try store.put("alpha", "one");
                try store.put("beta", "two");
                try store.put("gamma", "three");
                try std.testing.expectEqual(@as(u64, 3), store.count());
                try std.testing.expectEqualStrings("one", store.getView("alpha").?);
                try std.testing.expectEqualStrings("two", store.getView("beta").?);
                try std.testing.expectEqualStrings("three", store.getView("gamma").?);

                try store.put("beta", "TWO");
                try std.testing.expectEqualStrings("TWO", store.getView("beta").?);
                try std.testing.expect(store.remove("alpha"));
                try std.testing.expect(store.exists("alpha") == null);
                try std.testing.expectEqual(@as(u64, 2), store.count());
                try checkStoreHeader(&store);
            }
        }
    }
}

test "store initWithBuffer uses the prefix and leaves the tail untouched" {
    const allocator = std.testing.allocator;
    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    };
    const size = @as(usize, @intCast(try zigkv.Store.imageSize(options)));
    const tail_len = 32;

    const buffer = try allocator.alloc(u8, size + tail_len);
    defer allocator.free(buffer);
    @memset(buffer, 0xAA);

    var store = try zigkv.Store.initWithBuffer(buffer, options);
    defer store.deinit();

    try std.testing.expect(store.allocator == null);
    try std.testing.expectEqual(size, store.memory.len);
    try store.put("key", "value");
    try std.testing.expectEqualStrings("value", store.getView("key").?);
    try std.testing.expect(store.remove("key"));

    for (buffer[size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xAA), byte);
    }

    const too_small = try allocator.alloc(u8, size - 1);
    defer allocator.free(too_small);
    try std.testing.expectError(
        error.BufferTooSmall,
        zigkv.Store.initWithBuffer(too_small, options),
    );
}

fn storeValueOff(store: *const zigkv.Store, key: []const u8) u64 {
    const h = hash_mod.hashKey(key, store.header.flags.hash);
    return store.hash_table.lookup(&store.keys, key, h).?.entry.val_off;
}

fn checkStoreHeader(store: *const zigkv.Store) !void {
    const header = try format.Header.decode(store.memory);
    try std.testing.expectEqual(store.count(), header.table_size);
    try std.testing.expectEqual(store.keys.free_head, header.key_free_head);
    try std.testing.expectEqual(store.values.free_head, header.value_free_head);
    try std.testing.expectEqual(store.header.table_reserved, header.table_reserved);
    try std.testing.expectEqual(store.header.key_bytes, header.key_bytes);
    try std.testing.expectEqual(store.header.value_bytes, header.value_bytes);
}

test "iterator yields every entry exactly once" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 256,
        .value_bytes = 256,
    });
    defer store.deinit();

    var empty_iterator = store.iterator();
    try std.testing.expect(empty_iterator.next() == null);
    try std.testing.expect(empty_iterator.next() == null);

    const binary_key = [_]u8{ 0, 1, 0xFF };
    const binary_value = [_]u8{ 0xFF, 0, 0x7F };
    const pairs = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "", .value = "" },
        .{ .key = "alpha", .value = "one" },
        .{ .key = "beta", .value = "two" },
        .{ .key = &binary_key, .value = &binary_value },
    };

    var expected = std.StringHashMap([]const u8).init(allocator);
    defer expected.deinit();
    for (pairs) |pair| {
        try store.put(pair.key, pair.value);
        try expected.put(pair.key, pair.value);
    }

    var iterator = store.iterator();
    var seen: u64 = 0;
    while (iterator.next()) |entry| {
        seen += 1;
        const want = expected.fetchRemove(entry.key) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, want.value, entry.value);
    }

    try std.testing.expectEqual(store.count(), seen);
    try std.testing.expectEqual(@as(usize, 0), expected.count());
    try std.testing.expect(iterator.next() == null);
}

test "iterator reflects removals and resets its slot cursor" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 128,
    });
    defer store.deinit();

    try store.put("a", "1");
    try store.put("b", "2");
    try store.put("c", "3");

    var first = store.iterator();
    const first_entry = first.next().?;
    try std.testing.expectEqualStrings(
        store.getView(first_entry.key).?,
        first_entry.value,
    );

    try std.testing.expect(store.remove("b"));

    var second = store.iterator();
    var count: u64 = 0;
    while (second.next()) |entry| {
        count += 1;
        try std.testing.expect(!std.mem.eql(u8, entry.key, "b"));
        try std.testing.expect(store.getView(entry.key) != null);
    }
    try std.testing.expectEqual(@as(u64, 2), count);
}

test "iterator snapshots the generation and tolerates failed mutations" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 128,
        .value_bytes = 128,
    });
    defer store.deinit();

    try store.put("a", "one");
    const before = store.iterator();
    try std.testing.expectEqual(store.generation, before.generation);

    try store.put("b", "two");
    try std.testing.expect(before.generation != store.generation);

    // A failed mutation does not change the generation, so an existing
    // iterator remains valid.
    var after = store.iterator();
    try std.testing.expect(!store.remove("missing"));
    try std.testing.expectEqual(after.generation, store.generation);

    const entry = after.next().?;
    try std.testing.expect(store.getView(entry.key) != null);
    while (after.next()) |remaining| {
        try std.testing.expect(store.getView(remaining.key) != null);
    }
}

test "store save and load round-trip, and resaving is byte-identical" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: zigkv.Store.Options = .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 256,
    };
    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();

    const binary_key = [_]u8{ 0, 1, 2, 0xFF };
    const binary_value = [_]u8{ 0xFF, 0, 1, 2, 3 };
    try store.put("hello", "world");
    try store.put("", "");
    try store.put(&binary_key, &binary_value);
    try store.put("removed", "value");
    try std.testing.expect(store.remove("removed"));

    try store.save(io, tmp.dir, "data.zkv");
    const stat = try tmp.dir.statFile(io, "data.zkv", .{});
    try std.testing.expectEqual(@as(u64, @intCast(store.memory.len)), stat.size);

    var loaded = try zigkv.Store.load(allocator, io, tmp.dir, "data.zkv");
    defer loaded.deinit();

    try std.testing.expectEqual(store.count(), loaded.count());
    try std.testing.expectEqual(store.capacity(), loaded.capacity());
    try std.testing.expectEqual(@as(u64, 0), loaded.generation);
    try std.testing.expectEqualStrings("world", loaded.getView("hello").?);
    try std.testing.expectEqual(@as(u64, 0), loaded.exists("").?);
    try std.testing.expectEqualSlices(u8, &binary_value, loaded.getView(&binary_key).?);
    try std.testing.expect(loaded.exists("removed") == null);

    try loaded.save(io, tmp.dir, "resaved.zkv");
    const original = try tmp.dir.readFileAlloc(
        io,
        "data.zkv",
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    defer allocator.free(original);
    const resaved = try tmp.dir.readFileAlloc(
        io,
        "resaved.zkv",
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, original, resaved);
}

test "store loadInto uses the caller buffer prefix and rejects short buffers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    };
    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();
    try store.put("key", "value");
    try store.save(io, tmp.dir, "data.zkv");

    const stat = try tmp.dir.statFile(io, "data.zkv", .{});
    const size = @as(usize, @intCast(stat.size));
    const tail_len = 24;
    const buffer = try allocator.alloc(u8, size + tail_len);
    defer allocator.free(buffer);
    @memset(buffer, 0xAA);

    var loaded = try zigkv.Store.loadInto(buffer, io, tmp.dir, "data.zkv");
    defer loaded.deinit();

    try std.testing.expect(loaded.allocator == null);
    try std.testing.expectEqual(size, loaded.memory.len);
    try std.testing.expectEqualStrings("value", loaded.getView("key").?);

    try loaded.put("second", "entry");
    for (buffer[size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xAA), byte);
    }

    const too_small = try allocator.alloc(u8, size - 1);
    defer allocator.free(too_small);
    try std.testing.expectError(
        error.BufferTooSmall,
        zigkv.Store.loadInto(too_small, io, tmp.dir, "data.zkv"),
    );
}

test "saveAtomic creates and replaces an image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    };
    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();
    try store.put("key", "one");
    try store.saveAtomic(io, tmp.dir, "data.zkv");

    var loaded = try zigkv.Store.load(allocator, io, tmp.dir, "data.zkv");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("one", loaded.getView("key").?);

    try store.put("key", "two");
    try store.saveAtomic(io, tmp.dir, "data.zkv");

    var replaced = try zigkv.Store.load(allocator, io, tmp.dir, "data.zkv");
    defer replaced.deinit();
    try std.testing.expectEqualStrings("two", replaced.getView("key").?);
    try std.testing.expectEqual(@as(u64, 1), replaced.count());
}

test "image validation rejects short, long, and corrupt images" {
    const allocator = std.testing.allocator;
    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 128,
        .value_bytes = 128,
    };
    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();
    try store.put("alpha", "one");
    try store.put("beta", "two");
    try store.put("gamma", "three");

    const valid = try allocator.dupe(u8, store.memory);
    defer allocator.free(valid);
    _ = try image.validate(valid);

    // Extra and missing bytes violate the exact-length rule.
    {
        const extra = try allocator.alloc(u8, valid.len + 1);
        defer allocator.free(extra);
        @memcpy(extra[0..valid.len], valid);
        extra[valid.len] = 0;
        try std.testing.expectError(error.Corrupt, image.validate(extra));
    }
    try std.testing.expectError(error.Corrupt, image.validate(valid[0 .. valid.len - 1]));

    // Bad magic.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        copy[format.magic.len - 1] = if (copy[format.magic.len - 1] == '1') '2' else '3';
        try std.testing.expectError(error.UnsupportedVersion, image.validate(copy));
    }

    // Reserved flags bit.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        const word = std.mem.readInt(u64, copy[format.field.flags..][0..8], format.Endian.native);
        std.mem.writeInt(
            u64,
            copy[format.field.flags..][0..8],
            word | (@as(u64, 1) << 4),
            format.Endian.native,
        );
        try std.testing.expectError(error.Corrupt, image.validate(copy));
    }

    // Foreign byte order and mismatched byte-order copies.
    {
        const foreign = try allocator.dupe(u8, valid);
        defer allocator.free(foreign);
        foreign[format.field.flags] |= @as(u8, 1) << 3;
        foreign[format.field.flags + 7] |= @as(u8, 1) << 3;
        try std.testing.expectError(error.UnsupportedEndianness, image.validate(foreign));
    }
    {
        const mismatched = try allocator.dupe(u8, valid);
        defer allocator.free(mismatched);
        mismatched[format.field.flags] |= @as(u8, 1) << 3;
        try std.testing.expectError(error.Corrupt, image.validate(mismatched));
    }

    // Table size mismatch.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        const size = std.mem.readInt(
            u64,
            copy[format.field.table_size..][0..8],
            format.Endian.native,
        );
        std.mem.writeInt(
            u64,
            copy[format.field.table_size..][0..8],
            size + 1,
            format.Endian.native,
        );
        try std.testing.expectError(error.Corrupt, image.validate(copy));
    }

    // Free-list head outside the arena.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        std.mem.writeInt(
            u64,
            copy[format.field.key_free_head..][0..8],
            std.math.maxInt(u64),
            format.Endian.native,
        );
        try std.testing.expectError(error.Corrupt, image.validate(copy));
    }

    // A table entry pointing at an out-of-bounds key block.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        const header = try format.Header.decode(copy);
        const hash_table = try tables.Table.init(
            copy[format.header_size..][0..@intCast(
                header.table_reserved * format.entrySize(
                    header.flags.hash,
                    header.flags.key_index,
                    header.flags.value_index,
                ),
            )],
            header.flags,
            header.table_reserved,
            header.endian,
            header.table_size,
        );
        const slot = hash_table.lookup(&store.keys, "alpha", hash_mod.hashKey("alpha", header.flags.hash)).?;
        const Entry = format.TableEntry(.city64, .u32, .u32);
        const pos = format.header_size + @as(usize, @intCast(slot.index)) * Entry.size;
        var fields = Entry.read(copy, pos, header.endian);
        fields.key_off = 0xFFFF_FFF0;
        Entry.write(copy, pos, fields, header.endian);
        try std.testing.expectError(error.Corrupt, image.validate(copy));
    }

    // A block length larger than its block.
    {
        const copy = try allocator.dupe(u8, valid);
        defer allocator.free(copy);
        const val_off = storeValueOff(&store, "alpha");
        const absolute = @as(usize, @intCast(store.values_offset + val_off));
        const Block = format.Block(.u32);
        const size = Block.readSize(copy, absolute, format.Endian.native);
        Block.writeLen(copy, absolute, size, format.Endian.native);
        try std.testing.expectError(error.Corrupt, image.validate(copy));
    }
}

test "load reports corruption and endianness errors without leaking" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    };
    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();
    try store.put("key", "value");
    try store.save(io, tmp.dir, "valid.zkv");

    const valid = try tmp.dir.readFileAlloc(
        io,
        "valid.zkv",
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    defer allocator.free(valid);

    const extra = try allocator.alloc(u8, valid.len + 1);
    defer allocator.free(extra);
    @memcpy(extra[0..valid.len], valid);
    extra[valid.len] = 0;
    try tmp.dir.writeFile(io, .{ .sub_path = "extra.zkv", .data = extra });
    try std.testing.expectError(
        error.Corrupt,
        zigkv.Store.load(allocator, io, tmp.dir, "extra.zkv"),
    );

    const foreign = try allocator.dupe(u8, valid);
    defer allocator.free(foreign);
    foreign[format.field.flags] |= @as(u8, 1) << 3;
    foreign[format.field.flags + 7] |= @as(u8, 1) << 3;
    try tmp.dir.writeFile(io, .{ .sub_path = "foreign.zkv", .data = foreign });
    try std.testing.expectError(
        error.UnsupportedEndianness,
        zigkv.Store.load(allocator, io, tmp.dir, "foreign.zkv"),
    );
}

test "golden image loads and resaves byte-identically" {
    if (format.native_endian != .little) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const golden = try readFixture("testdata/golden.zkv");
    defer allocator.free(golden);
    try tmp.dir.writeFile(io, .{ .sub_path = "golden.zkv", .data = golden });

    var store = try zigkv.Store.load(allocator, io, tmp.dir, "golden.zkv");
    defer store.deinit();

    try std.testing.expectEqual(@as(u64, 3), store.count());
    try std.testing.expectEqualStrings("world", store.getView("hello").?);
    try std.testing.expectEqual(@as(u64, 0), store.exists("").?);
    const binary_key = [_]u8{ 0, 1, 2, 0xFF };
    const binary_value = [_]u8{ 0xFF, 0, 1, 2, 3 };
    try std.testing.expectEqualSlices(u8, &binary_value, store.getView(&binary_key).?);
    try std.testing.expect(store.exists("removed") == null);

    try store.save(io, tmp.dir, "resaved.zkv");
    const resaved = try tmp.dir.readFileAlloc(
        io,
        "resaved.zkv",
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    defer allocator.free(resaved);
    try std.testing.expectEqualSlices(u8, golden, resaved);
}

test "committed corrupt fixtures are rejected" {
    if (format.native_endian != .little) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        name: []const u8,
        file: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "extra",
            .file = "testdata/corrupt-extra-byte.zkv",
            .expected = error.Corrupt,
        },
        .{
            .name = "magic",
            .file = "testdata/corrupt-bad-magic.zkv",
            .expected = error.UnsupportedVersion,
        },
        .{
            .name = "free-head",
            .file = "testdata/corrupt-free-head.zkv",
            .expected = error.Corrupt,
        },
        .{
            .name = "table-size",
            .file = "testdata/corrupt-table-size.zkv",
            .expected = error.Corrupt,
        },
    };

    for (cases) |case| {
        const bytes = try readFixture(case.file);
        defer allocator.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = case.name, .data = bytes });
        try std.testing.expectError(
            case.expected,
            zigkv.Store.load(allocator, io, tmp.dir, case.name),
        );

        const buffer = try allocator.alloc(u8, bytes.len);
        defer allocator.free(buffer);
        try std.testing.expectError(
            case.expected,
            zigkv.Store.loadInto(buffer, io, tmp.dir, case.name),
        );
    }
}

fn readFixture(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(std.math.maxInt(usize)),
    );
}

test "save writes exactly imageSize from an oversized caller buffer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: zigkv.Store.Options = .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    };
    const size = @as(usize, @intCast(try zigkv.Store.imageSize(options)));
    const buffer = try allocator.alloc(u8, size + 16);
    defer allocator.free(buffer);
    @memset(buffer, 0x5A);

    var store = try zigkv.Store.initWithBuffer(buffer, options);
    defer store.deinit();
    try store.put("key", "value");

    try store.save(io, tmp.dir, "data.zkv");
    const stat = try tmp.dir.statFile(io, "data.zkv", .{});
    try std.testing.expectEqual(@as(u64, @intCast(size)), stat.size);

    for (buffer[size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0x5A), byte);
    }
}

test "store verify accepts a consistent store and rejects key corruption" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 128,
    });
    defer store.deinit();

    try store.put("alpha", "one");
    try store.put("beta", "two");
    try store.verify();

    const slot = store.hash_table.lookup(
        &store.keys,
        "alpha",
        hash_mod.hashKey("alpha", store.header.flags.hash),
    ).?;
    store.keys.payloadMut(slot.entry.key_off)[0] ^= 1;
    try std.testing.expectError(error.Corrupt, store.verify());
}

test "random operations match a StringHashMap model" {
    try runStoreModel(.{
        .max_entries = 128,
        .key_bytes = 4096,
        .value_bytes = 16384,
    }, 0x5EED_0001, 3000);

    try runStoreModel(.{
        .max_entries = 128,
        .key_bytes = 4096,
        .value_bytes = 16384,
        .hash = .city32,
        .key_index = .u64,
        .value_index = .u64,
    }, 0x5EED_0002, 3000);
}

test "random corruption never panics or reads out of bounds" {
    const allocator = std.testing.allocator;
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 32,
        .key_bytes = 128,
        .value_bytes = 256,
    });
    defer store.deinit();

    try store.put("alpha", "one");
    try store.put("beta", "two");
    try store.put("", "");
    try store.put("removed", "value");
    try std.testing.expect(store.remove("removed"));

    const valid = try allocator.dupe(u8, store.memory);
    defer allocator.free(valid);
    const buffer = try allocator.alloc(u8, valid.len + 8);
    defer allocator.free(buffer);
    @memset(buffer, 0xAA);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 2000) : (iteration += 1) {
        @memcpy(buffer[0..valid.len], valid);

        const changes = 1 + random.uintLessThan(usize, 8);
        var change: usize = 0;
        while (change < changes) : (change += 1) {
            const pos = random.uintLessThan(usize, valid.len);
            const bit: u3 = @intCast(random.uintLessThan(u8, 8));
            buffer[pos] ^= @as(u8, 1) << bit;
        }

        var slice: []const u8 = buffer[0..valid.len];
        if (random.uintLessThan(u8, 8) == 0) {
            slice = buffer[0..random.uintLessThan(usize, valid.len + 9)];
        } else if (random.uintLessThan(u8, 8) == 0) {
            slice = buffer[0 .. valid.len + random.uintLessThan(usize, 8)];
        }

        _ = image.validate(slice) catch {};
    }
}

test "arena exhaustion is reported and recoverable" {
    const allocator = std.testing.allocator;

    // Key arena full: two 8-byte keys consume both 16-byte blocks.
    var key_store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 32,
        .value_bytes = 32,
    });
    defer key_store.deinit();

    try key_store.put("aaaaaaaa", "a");
    try key_store.put("bbbbbbbb", "b");
    try std.testing.expectError(error.OutOfSpace, key_store.put("c", "c"));
    try std.testing.expectEqual(@as(u64, 2), key_store.count());
    try std.testing.expectEqualStrings("a", key_store.getView("aaaaaaaa").?);

    try std.testing.expect(key_store.remove("aaaaaaaa"));
    try key_store.put("c", "c");
    try std.testing.expectEqual(@as(u64, 2), key_store.count());
    try std.testing.expectEqualStrings("c", key_store.getView("c").?);

    // Value arena full: two 8-byte values consume both 16-byte blocks.
    var value_store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 128,
        .value_bytes = 32,
    });
    defer value_store.deinit();

    var eight: [8]u8 = undefined;
    @memset(&eight, 'x');
    try value_store.put("a", &eight);
    try value_store.put("b", &eight);
    try std.testing.expectError(error.OutOfSpace, value_store.put("c", "x"));
    try std.testing.expectEqual(@as(u64, 2), value_store.count());
    try std.testing.expectEqualSlices(u8, &eight, value_store.getView("a").?);

    // Overwriting in place still works when the arena is exhausted.
    try value_store.put("a", "short");
    try std.testing.expectEqualStrings("short", value_store.getView("a").?);

    try std.testing.expect(value_store.remove("a"));
    try value_store.put("c", "x");
    try std.testing.expectEqual(@as(u64, 2), value_store.count());
}

test "allocation failures during Store init and getAlloc do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureImpl,
        .{},
    );
}

test "allocation failures during load do not leak" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    });
    defer store.deinit();
    try store.put("key", "value");
    try store.save(io, tmp.dir, "data.zkv");

    try std.testing.checkAllAllocationFailures(
        allocator,
        loadFailureImpl,
        .{ io, tmp.dir, "data.zkv" },
    );
}

fn allocationFailureImpl(allocator: std.mem.Allocator) !void {
    var store = try zigkv.Store.init(allocator, .{
        .max_entries = 16,
        .key_bytes = 64,
        .value_bytes = 64,
    });
    defer store.deinit();

    try store.put("key", "value");

    const copy = (try store.getAlloc("key", allocator)).?;
    defer allocator.free(copy);
    try std.testing.expectEqualStrings("value", copy);
}

fn loadFailureImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !void {
    var store = try zigkv.Store.load(allocator, io, dir, path);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 1), store.count());
}

fn runStoreModel(options: zigkv.Store.Options, seed: u64, iterations: usize) !void {
    const allocator = std.testing.allocator;

    var key_storage: [48][8]u8 = undefined;
    var key_set: [48][]const u8 = undefined;
    for (&key_set, 0..) |*key, i| {
        const len: usize = if (i == 0) 0 else 1 + (i % 8);
        for (key_storage[i][0..len], 0..) |*byte, j| {
            byte.* = @truncate(i *% 37 +% j *% 11);
        }
        key.* = key_storage[i][0..len];
    }

    var store = try zigkv.Store.init(allocator, options);
    defer store.deinit();

    var model = std.StringHashMap([]u8).init(allocator);
    defer {
        var values = model.valueIterator();
        while (values.next()) |value| allocator.free(value.*);
        model.deinit();
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var value_storage: [64]u8 = undefined;

    var step: usize = 0;
    while (step < iterations) : (step += 1) {
        const key = key_set[random.uintLessThan(usize, key_set.len)];
        const op = random.uintLessThan(u8, 100);

        if (op < 55) {
            const value_len = random.uintLessThan(usize, value_storage.len);
            const value = value_storage[0..value_len];
            random.bytes(value);

            try store.put(key, value);

            if (model.fetchRemove(key)) |old| allocator.free(old.value);
            try model.put(key, try allocator.dupe(u8, value));
        } else if (op < 80) {
            const expected = model.fetchRemove(key);
            const removed = store.remove(key);
            try std.testing.expectEqual(expected != null, removed);
            if (expected) |old| allocator.free(old.value);
        } else {
            const expected = model.get(key);
            const actual = store.getView(key);
            if (expected) |value| {
                try std.testing.expectEqualSlices(u8, value, actual.?);
                try std.testing.expectEqual(
                    @as(u64, @intCast(value.len)),
                    store.exists(key).?,
                );
            } else {
                try std.testing.expect(actual == null);
                try std.testing.expect(store.exists(key) == null);
            }
        }

        try std.testing.expectEqual(model.count(), store.count());
        if (step % 1000 == 0) try store.verify();
    }

    try store.verify();
    try std.testing.expectEqual(model.count(), store.count());

    var actual_entries = store.iterator();
    var seen: u64 = 0;
    while (actual_entries.next()) |entry| {
        seen += 1;
        const expected = model.get(entry.key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, expected, entry.value);
    }
    try std.testing.expectEqual(model.count(), seen);

    var expected_entries = model.iterator();
    while (expected_entries.next()) |entry| {
        const actual = store.getView(entry.key_ptr.*) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, entry.value_ptr.*, actual);
    }
}
