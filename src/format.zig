//! Byte-level file format definitions: constants, flags and byte-order
//! bootstrap, header accessors, table entries, and key/value block accessors.
//!
//! Every multi-byte field is accessed with `std.mem.readInt` / `writeInt`, so
//! the store buffer has no alignment requirement. Integers use the image's
//! declared byte order.

const std = @import("std");

pub const Endian = std.lang.Endian;
pub const native_endian = Endian.native;

/// ASCII magic; the `001` suffix is the file-format version.
pub const magic = "zigkv001";

/// Numeric file-format version carried by the magic suffix.
pub const file_version: u16 = 1;

/// Header size in bytes (8 x u64).
pub const header_size: usize = 64;

/// Header field offsets.
pub const field = struct {
    pub const magic: usize = 0;
    pub const flags: usize = 8;
    pub const table_reserved: usize = 16;
    pub const table_size: usize = 24;
    pub const key_bytes: usize = 32;
    pub const key_free_head: usize = 40;
    pub const value_bytes: usize = 48;
    pub const value_free_head: usize = 56;
};

pub const min_slots: u64 = 16;
pub const load_factor_numerator: u64 = 3;
pub const load_factor_denominator: u64 = 4;

pub const HashWidth = enum(u1) {
    city32 = 0,
    city64 = 1,
};

pub const IndexWidth = enum(u1) {
    u32 = 0,
    u64 = 1,
};

/// Decoded table-entry fields. The stored widths are widened to u64 for use by
/// callers.
pub const EntryFields = struct {
    hash: u64,
    key_off: u64,
    val_off: u64,
};

pub fn hashSize(width: HashWidth) u64 {
    return switch (width) {
        .city32 => 4,
        .city64 => 8,
    };
}

pub fn indexSize(width: IndexWidth) u64 {
    return switch (width) {
        .u32 => 4,
        .u64 => 8,
    };
}

/// Size of a table entry for the given field widths: 12, 16, 20 or 24 bytes.
pub fn entrySize(hash: HashWidth, key_index: IndexWidth, value_index: IndexWidth) u64 {
    return hashSize(hash) + indexSize(key_index) + indexSize(value_index);
}

/// Size of a key/value block header, which follows the arena's index width.
pub fn blockHeaderSize(width: IndexWidth) u64 {
    return indexSize(width) * 2;
}

/// Largest arena capacity representable by the index width.
pub fn arenaMax(width: IndexWidth) u64 {
    return switch (width) {
        // The final 8-byte aligned capacity below 2^32.
        .u32 => 0xFFFF_FFF8,
        // The host address space, bounded by the u64 image size.
        .u64 => std.math.maxInt(u64),
    };
}

/// A free-list terminator for the given arena width.
pub fn arenaNone(width: IndexWidth) u64 {
    return switch (width) {
        .u32 => std.math.maxInt(u32),
        .u64 => std.math.maxInt(u64),
    };
}

/// Flags word layout.
///
/// | bit | meaning                          |
/// |-----|----------------------------------|
/// | 0   | hash width (0 = 32, 1 = 64)      |
/// | 1   | key index width (0 = 32, 1 = 64) |
/// | 2   | value index width (0 = 32, 1 = 64) |
/// | 3   | data byte order (0 = LE, 1 = BE) |
/// | 59  | duplicate of bit 3               |
pub const Flags = struct {
    hash: HashWidth = .city64,
    key_index: IndexWidth = .u32,
    value_index: IndexWidth = .u32,

    /// Build the flags word, serializing the byte-order bit into both copies.
    /// The caller writes the returned word in `order`.
    pub fn encode(self: Flags, order: Endian) u64 {
        const order_bit: u64 = if (order == .big) 1 else 0;
        const hash_bit: u64 = if (self.hash == .city64) 1 else 0;
        const key_bit: u64 = if (self.key_index == .u64) 1 else 0;
        const value_bit: u64 = if (self.value_index == .u64) 1 else 0;
        return hash_bit |
            (key_bit << 1) |
            (value_bit << 2) |
            (order_bit << 3) |
            (order_bit << 59);
    }

    /// Decode and validate a flags word. Reserved bits must be zero and the
    /// two byte-order copies must agree.
    pub fn decode(word: u64) !Flags {
        const allowed: u64 = 0b111 | (@as(u64, 1) << 3) | (@as(u64, 1) << 59);
        if ((word & ~allowed) != 0) return error.Corrupt;
        if (((word >> 3) & 1) != ((word >> 59) & 1)) return error.Corrupt;

        return .{
            .hash = if ((word & 1) != 0) .city64 else .city32,
            .key_index = if (((word >> 1) & 1) != 0) .u64 else .u32,
            .value_index = if (((word >> 2) & 1) != 0) .u64 else .u32,
        };
    }

    /// Determine a file's byte order from the duplicated flag bit without
    /// decoding any other field. Bit 3 of the flags word lands in byte 8 under
    /// a little-endian read and byte 15 under a big-endian read.
    pub fn detectEndian(bytes: []const u8) !Endian {
        if (bytes.len < header_size) return error.Corrupt;

        const lo = (bytes[field.flags] >> 3) & 1;
        const hi = (bytes[field.flags + 7] >> 3) & 1;
        if (lo != hi) return error.Corrupt;
        return if (lo == 1) .big else .little;
    }
};

pub const Header = struct {
    flags: Flags,
    endian: Endian = native_endian,
    table_reserved: u64,
    table_size: u64,
    key_bytes: u64,
    key_free_head: u64,
    value_bytes: u64,
    value_free_head: u64,

    /// Parse a header from at least 64 bytes. Validates the magic/version, the
    /// byte-order bootstrap and the flags word. Structural validation of the
    /// remaining fields belongs to the image layer.
    pub fn decode(bytes: []const u8) !Header {
        if (bytes.len < header_size) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[field.magic..][0..magic.len], magic)) {
            return error.UnsupportedVersion;
        }

        const order = try Flags.detectEndian(bytes);
        if (order != native_endian) return error.UnsupportedEndianness;

        return .{
            .flags = try Flags.decode(readU64(bytes, field.flags, order)),
            .endian = order,
            .table_reserved = readU64(bytes, field.table_reserved, order),
            .table_size = readU64(bytes, field.table_size, order),
            .key_bytes = readU64(bytes, field.key_bytes, order),
            .key_free_head = readU64(bytes, field.key_free_head, order),
            .value_bytes = readU64(bytes, field.value_bytes, order),
            .value_free_head = readU64(bytes, field.value_free_head, order),
        };
    }

    /// Write a complete 64-byte header.
    pub fn encode(self: Header, out: []u8) void {
        std.debug.assert(out.len >= header_size);
        @memcpy(out[field.magic..][0..magic.len], magic);
        writeU64(out, field.flags, self.flags.encode(self.endian), self.endian);
        writeU64(out, field.table_reserved, self.table_reserved, self.endian);
        writeU64(out, field.table_size, self.table_size, self.endian);
        writeU64(out, field.key_bytes, self.key_bytes, self.endian);
        writeU64(out, field.key_free_head, self.key_free_head, self.endian);
        writeU64(out, field.value_bytes, self.value_bytes, self.endian);
        writeU64(out, field.value_free_head, self.value_free_head, self.endian);
    }
};

/// Table-entry accessors for one width combination. `size` is 12, 16, 20 or
/// 24 bytes; entries may live at any byte offset.
pub fn TableEntry(
    comptime hash_width: HashWidth,
    comptime key_width: IndexWidth,
    comptime value_width: IndexWidth,
) type {
    const HashInt = switch (hash_width) {
        .city32 => u32,
        .city64 => u64,
    };
    const KeyInt = indexInt(key_width);
    const ValueInt = indexInt(value_width);

    return struct {
        pub const hash_size: usize = @sizeOf(HashInt);
        pub const key_offset: usize = hash_size;
        pub const value_offset: usize = hash_size + @sizeOf(KeyInt);
        pub const size: usize = hash_size + @sizeOf(KeyInt) + @sizeOf(ValueInt);

        /// `hash == 0` marks an empty slot.
        pub const empty_hash: u64 = 0;

        pub const Fields = EntryFields;

        pub fn read(bytes: []const u8, pos: usize, order: Endian) Fields {
            return .{
                .hash = std.mem.readInt(HashInt, bytes[pos..][0..@sizeOf(HashInt)], order),
                .key_off = std.mem.readInt(KeyInt, bytes[pos + key_offset ..][0..@sizeOf(KeyInt)], order),
                .val_off = std.mem.readInt(ValueInt, bytes[pos + value_offset ..][0..@sizeOf(ValueInt)], order),
            };
        }

        pub fn write(bytes: []u8, pos: usize, fields: Fields, order: Endian) void {
            std.mem.writeInt(HashInt, bytes[pos..][0..@sizeOf(HashInt)], @intCast(fields.hash), order);
            std.mem.writeInt(KeyInt, bytes[pos + key_offset ..][0..@sizeOf(KeyInt)], @intCast(fields.key_off), order);
            std.mem.writeInt(ValueInt, bytes[pos + value_offset ..][0..@sizeOf(ValueInt)], @intCast(fields.val_off), order);
        }

        pub fn readHash(bytes: []const u8, pos: usize, order: Endian) u64 {
            return std.mem.readInt(HashInt, bytes[pos..][0..@sizeOf(HashInt)], order);
        }
    };
}

/// Key/value block accessors for one arena index width. Blocks are 8-byte
/// aligned, but these accessors work at any byte offset.
pub fn Block(comptime width: IndexWidth) type {
    const Int = indexInt(width);

    return struct {
        pub const index_type = Int;
        pub const header_size: usize = @sizeOf(Int) * 2;
        pub const min_size: u64 = @sizeOf(Int) * 2;
        /// Free-list terminator. It is never 8-aligned, so it cannot collide
        /// with a valid block offset; offset 0 remains valid.
        pub const none: u64 = std.math.maxInt(Int);

        pub fn readSize(bytes: []const u8, pos: usize, order: Endian) u64 {
            return std.mem.readInt(Int, bytes[pos..][0..@sizeOf(Int)], order);
        }

        pub fn writeSize(bytes: []u8, pos: usize, value: u64, order: Endian) void {
            std.mem.writeInt(Int, bytes[pos..][0..@sizeOf(Int)], @intCast(value), order);
        }

        /// `len` for an allocated block, at the second word of the header.
        pub fn readLen(bytes: []const u8, pos: usize, order: Endian) u64 {
            return std.mem.readInt(Int, bytes[pos + @sizeOf(Int) ..][0..@sizeOf(Int)], order);
        }

        pub fn writeLen(bytes: []u8, pos: usize, value: u64, order: Endian) void {
            std.mem.writeInt(Int, bytes[pos + @sizeOf(Int) ..][0..@sizeOf(Int)], @intCast(value), order);
        }

        /// `next` for a free block, at the second word of the header.
        pub fn readNext(bytes: []const u8, pos: usize, order: Endian) u64 {
            return std.mem.readInt(Int, bytes[pos + @sizeOf(Int) ..][0..@sizeOf(Int)], order);
        }

        pub fn writeNext(bytes: []u8, pos: usize, value: u64, order: Endian) void {
            std.mem.writeInt(Int, bytes[pos + @sizeOf(Int) ..][0..@sizeOf(Int)], @intCast(value), order);
        }
    };
}

/// The Zig integer type used by an arena with the given index width.
pub fn indexInt(comptime width: IndexWidth) type {
    return switch (width) {
        .u32 => u32,
        .u64 => u64,
    };
}

fn readU64(bytes: []const u8, pos: usize, order: Endian) u64 {
    return std.mem.readInt(u64, bytes[pos..][0..8], order);
}

fn writeU64(bytes: []u8, pos: usize, value: u64, order: Endian) void {
    std.mem.writeInt(u64, bytes[pos..][0..8], value, order);
}
