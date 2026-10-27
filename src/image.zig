//! Image layout math and strict structural validation.
//!
//! The image layout is:
//!
//! ```
//! offset 0                  header (64 B)
//! offset 64                 table (slots * entry_size)
//! align8(64 + table_bytes)  keys (key_bytes)
//! keys_offset + key_bytes   values (value_bytes)
//! ```

const std = @import("std");
const format = @import("format.zig");
const table_mod = @import("table.zig");

pub const Options = struct {
    /// Requested slot count, rounded up to a power of two and clamped to the
    /// format minimum of 16.
    max_entries: u64 = 1024,
    /// Requested key arena capacity. Rounded up to a multiple of 8 and to at
    /// least one block header (8 or 16 bytes, depending on `key_index`).
    key_bytes: u64 = 64 * 1024,
    /// Requested value arena capacity, normalized like `key_bytes`.
    value_bytes: u64 = 1024 * 1024,
    hash: format.HashWidth = .city64,
    key_index: format.IndexWidth = .u32,
    value_index: format.IndexWidth = .u32,
};

pub const Layout = struct {
    flags: format.Flags,
    table_reserved: u64,
    table_bytes: u64,
    keys_offset: u64,
    key_bytes: u64,
    values_offset: u64,
    value_bytes: u64,
    file_size: u64,

    pub const table_offset: u64 = format.header_size;

    pub fn fromOptions(options: Options) !Layout {
        const flags: format.Flags = .{
            .hash = options.hash,
            .key_index = options.key_index,
            .value_index = options.value_index,
        };

        const table_reserved = try roundUpSlots(options.max_entries);
        const key_bytes = try arenaCapacity(options.key_bytes, flags.key_index);
        const value_bytes = try arenaCapacity(options.value_bytes, flags.value_index);
        return buildLayout(flags, table_reserved, key_bytes, value_bytes);
    }

    pub fn entrySize(self: Layout) u64 {
        return format.entrySize(self.flags.hash, self.flags.key_index, self.flags.value_index);
    }

    /// Maximum number of live keys: slots * 3 / 4.
    pub fn capacity(self: Layout) u64 {
        return self.table_reserved / format.load_factor_denominator *
            format.load_factor_numerator;
    }
};

pub const ValidatedImage = struct {
    header: format.Header,
    layout: Layout,
};

pub fn imageSize(options: Options) !u64 {
    return (try Layout.fromOptions(options)).file_size;
}

/// Validate an image's structure and derive its section layout.
///
/// This checks the header, flags, saved byte order, capacities, exact file
/// length, load-factor accounting, both free lists (sorted, in bounds,
/// coalesced, cycle-free), both arena tilings, and every table entry's block
/// offsets. It never reads out of bounds on malformed input.
///
/// Validation deliberately does not prove that a table entry points at an arena
/// block start or that entries reference distinct blocks; see README "Known
/// limitations" and PLAN §10 risks 9-10.
pub fn validate(bytes: []const u8) !ValidatedImage {
    const header = try format.Header.decode(bytes);

    if (header.table_reserved < format.min_slots or
        !std.math.isPowerOfTwo(header.table_reserved))
    {
        return error.Corrupt;
    }
    if (header.table_size > header.table_reserved /
        format.load_factor_denominator * format.load_factor_numerator)
    {
        return error.Corrupt;
    }
    if (!validArenaCapacity(header.key_bytes, header.flags.key_index)) return error.Corrupt;
    if (!validArenaCapacity(header.value_bytes, header.flags.value_index)) return error.Corrupt;

    const layout = buildLayout(
        header.flags,
        header.table_reserved,
        header.key_bytes,
        header.value_bytes,
    ) catch return error.Corrupt;
    if (layout.file_size != @as(u64, @intCast(bytes.len))) return error.Corrupt;

    const table_start: usize = format.header_size;
    const table_end: usize = table_start + @as(usize, @intCast(layout.table_bytes));
    const keys_start: usize = @intCast(layout.keys_offset);
    const keys_end: usize = @intCast(layout.values_offset);
    const values_end: usize = @intCast(layout.file_size);

    const table_memory = bytes[table_start..table_end];
    const key_memory = bytes[keys_start..keys_end];
    const value_memory = bytes[keys_end..values_end];

    _ = table_mod.Table.init(
        @constCast(table_memory),
        header.flags,
        header.table_reserved,
        header.table_size,
    ) catch return error.Corrupt;

    try validateArena(key_memory, header.flags.key_index, header.key_free_head);
    try validateArena(value_memory, header.flags.value_index, header.value_free_head);
    try validateEntries(table_memory, header, key_memory, value_memory);

    return .{ .header = header, .layout = layout };
}

fn buildLayout(
    flags: format.Flags,
    table_reserved: u64,
    key_bytes: u64,
    value_bytes: u64,
) !Layout {
    const entry_size = format.entrySize(flags.hash, flags.key_index, flags.value_index);
    const table_bytes = std.math.mul(u64, table_reserved, entry_size) catch
        return error.OutOfSpace;

    const keys_unpadded = std.math.add(u64, @intCast(format.header_size), table_bytes) catch
        return error.OutOfSpace;
    const keys_offset = try align8(keys_unpadded);
    const values_offset = std.math.add(u64, keys_offset, key_bytes) catch
        return error.OutOfSpace;
    const file_size = std.math.add(u64, values_offset, value_bytes) catch
        return error.OutOfSpace;

    return .{
        .flags = flags,
        .table_reserved = table_reserved,
        .table_bytes = table_bytes,
        .keys_offset = keys_offset,
        .key_bytes = key_bytes,
        .values_offset = values_offset,
        .value_bytes = value_bytes,
        .file_size = file_size,
    };
}

/// Round a requested slot count up to a power of two, with a minimum of 16.
fn roundUpSlots(max_entries: u64) !u64 {
    if (max_entries <= format.min_slots) return format.min_slots;
    return std.math.ceilPowerOfTwo(u64, max_entries) catch error.OutOfSpace;
}

/// Normalize an arena capacity: at least one block header, a multiple of 8,
/// and representable by the arena's index width.
fn arenaCapacity(requested: u64, width: format.IndexWidth) !u64 {
    if (requested > format.arenaMax(width)) return error.ValueTooLarge;

    const minimum = format.blockHeaderSize(width);
    const capacity = @max(requested, minimum);
    return align8(capacity);
}

fn validArenaCapacity(capacity: u64, width: format.IndexWidth) bool {
    return capacity >= format.blockHeaderSize(width) and
        capacity % 8 == 0 and
        capacity <= format.arenaMax(width);
}

fn align8(value: u64) !u64 {
    const padded = std.math.add(u64, value, 7) catch return error.OutOfSpace;
    return padded & ~@as(u64, 7);
}

fn validateArena(
    memory: []const u8,
    width: format.IndexWidth,
    free_head: u64,
) !void {
    return switch (width) {
        inline else => |comptime_width| validateArenaImpl(
            comptime_width,
            memory,
            free_head,
        ),
    };
}

fn validateArenaImpl(
    comptime width: format.IndexWidth,
    memory: []const u8,
    free_head: u64,
) !void {
    const Block = format.Block(width);
    const capacity: u64 = @intCast(memory.len);
    const header_size: u64 = @intCast(Block.header_size);

    // Free list: in bounds, aligned, sorted, fully coalesced, cycle-free.
    var prev: u64 = Block.none;
    var cursor = free_head;
    var nodes: u64 = 0;
    while (cursor != Block.none) {
        if (cursor >= capacity or cursor % 8 != 0) return error.Corrupt;
        if (cursor + header_size > capacity) return error.Corrupt;

        const size = Block.readSize(memory, @intCast(cursor));
        if (size < Block.min_size or size % 8 != 0) return error.Corrupt;
        if (size > capacity - cursor) return error.Corrupt;

        if (prev != Block.none) {
            const prev_size = Block.readSize(memory, @intCast(prev));
            if (cursor <= prev) return error.Corrupt;
            if (prev + prev_size >= cursor) return error.Corrupt;
        }

        const next = Block.readNext(memory, @intCast(cursor));
        if (next != Block.none and next <= cursor) return error.Corrupt;

        prev = cursor;
        cursor = next;

        nodes += 1;
        if (nodes > capacity / Block.min_size + 1) return error.Corrupt;
    }

    // Arena tiling: walk every block and require it to end exactly at capacity.
    // A block is free exactly when its offset matches the free-list cursor.
    var free_cursor = free_head;
    var offset: u64 = 0;
    var tiles: u64 = 0;
    while (offset < capacity) {
        if (offset + header_size > capacity) return error.Corrupt;

        const size = Block.readSize(memory, @intCast(offset));
        if (size < Block.min_size or size % 8 != 0) return error.Corrupt;
        if (size > capacity - offset) return error.Corrupt;

        if (free_cursor != Block.none) {
            if (free_cursor < offset) return error.Corrupt;

            if (free_cursor == offset) {
                const next = Block.readNext(memory, @intCast(free_cursor));
                if (next != Block.none and next <= offset + size) return error.Corrupt;
                free_cursor = next;
            } else {
                try validateAllocatedBlock(Block, memory, offset, size);
            }
        } else {
            try validateAllocatedBlock(Block, memory, offset, size);
        }

        offset += size;
        tiles += 1;
        if (tiles > capacity / Block.min_size + 1) return error.Corrupt;
    }

    if (offset != capacity) return error.Corrupt;
    if (free_cursor != Block.none) return error.Corrupt;
}

fn validateAllocatedBlock(
    comptime Block: type,
    memory: []const u8,
    offset: u64,
    size: u64,
) !void {
    const header_size: u64 = @intCast(Block.header_size);
    const len = Block.readLen(memory, @intCast(offset));
    if (len > size - header_size) return error.Corrupt;
}

fn validateEntries(
    table_memory: []const u8,
    header: format.Header,
    key_memory: []const u8,
    value_memory: []const u8,
) !void {
    const hash_table = try table_mod.Table.init(
        @constCast(table_memory),
        header.flags,
        header.table_reserved,
        header.table_size,
    );

    var count: u64 = 0;
    var index: u64 = 0;
    while (index < hash_table.slots) : (index += 1) {
        const entry = hash_table.entryAt(index);
        if (entry.hash == 0) continue;

        count += 1;
        _ = try validateBlock(
            key_memory,
            header.flags.key_index,
            entry.key_off,
        );
        _ = try validateBlock(
            value_memory,
            header.flags.value_index,
            entry.val_off,
        );
    }

    if (count != header.table_size) return error.Corrupt;
}

/// Validate an allocated block header and return its payload length.
fn validateBlock(
    memory: []const u8,
    width: format.IndexWidth,
    offset: u64,
) !u64 {
    return switch (width) {
        inline else => |comptime_width| validateBlockImpl(
            comptime_width,
            memory,
            offset,
        ),
    };
}

fn validateBlockImpl(
    comptime width: format.IndexWidth,
    memory: []const u8,
    offset: u64,
) !u64 {
    const Block = format.Block(width);
    const capacity: u64 = @intCast(memory.len);
    const header_size: u64 = @intCast(Block.header_size);

    if (offset >= capacity or offset % 8 != 0) return error.Corrupt;
    if (offset + header_size > capacity) return error.Corrupt;

    const size = Block.readSize(memory, @intCast(offset));
    if (size < Block.min_size or size % 8 != 0) return error.Corrupt;
    if (size > capacity - offset) return error.Corrupt;

    const len = Block.readLen(memory, @intCast(offset));
    if (len > size - header_size) return error.Corrupt;
    return len;
}
