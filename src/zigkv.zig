//! zigkv: a single-file, memory-resident key/value store.
//!
//! The store image is the file format: saving is one write and loading is one
//! read, with no serialization or parsing pass. See docs/file-format.md for the
//! byte-level specification.
//!
//! This module is the public facade: `Store`, `Entry`, and `Iterator`.
//!
//! The field widths (hash, key index, value index) are fixed when a store is
//! created, so every public operation dispatches on them exactly once and then
//! runs fully specialized code (`Impl`). Nothing below that boundary re-checks
//! a width.

const std = @import("std");
const arena = @import("arena.zig");
const format = @import("format.zig");
const hash = @import("hash.zig");
const image = @import("image.zig");
const table = @import("table.zig");

/// Semantic version of the library.
pub const version = "0.1.0";

comptime {
    // The format uses u64 lengths and offsets throughout, and the host address
    // space must be able to hold the whole image.
    if (@bitSizeOf(usize) != 64) {
        @compileError("zigkv requires a 64-bit host");
    }
}

pub const Store = struct {
    /// Exactly `imageSize(options)` bytes (a prefix of a caller-owned buffer
    /// when initialized with `initWithBuffer`).
    memory: []u8,
    /// Null for caller-owned images.
    allocator: ?std.mem.Allocator,
    /// Bumped by every successful `put`/`remove`; not persisted.
    generation: u64,

    header: format.Header,
    hash_table: table.Table,
    keys: arena.Arena,
    values: arena.Arena,
    keys_offset: u64,
    values_offset: u64,

    pub const HashWidth = format.HashWidth;
    pub const IndexWidth = format.IndexWidth;
    pub const Options = image.Options;
    /// File-format magic and numeric version.
    pub const file_magic = format.magic;
    pub const file_version = format.file_version;

    /// Total image size in bytes for the given options.
    pub fn imageSize(options: Options) !u64 {
        return image.imageSize(options);
    }

    /// Allocate and format an empty store.
    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        const layout = try image.Layout.fromOptions(options);
        const size = std.math.cast(usize, layout.file_size) orelse
            return error.OutOfMemory;

        const memory = try allocator.alloc(u8, size);
        errdefer allocator.free(memory);
        return formatMemory(memory, allocator, layout);
    }

    /// Format an empty store into a caller-owned buffer. The buffer may be
    /// larger than the image; only the prefix is used and the tail is left
    /// untouched. `deinit` does not free the buffer.
    pub fn initWithBuffer(buffer: []u8, options: Options) !Store {
        const layout = try image.Layout.fromOptions(options);
        const size = std.math.cast(usize, layout.file_size) orelse
            return error.OutOfMemory;
        if (buffer.len < size) return error.BufferTooSmall;

        return formatMemory(buffer[0..size], null, layout);
    }

    /// Release the image when it was allocated by the store. Caller-owned
    /// buffers passed to `initWithBuffer`/`loadInto` are left untouched.
    pub fn deinit(self: *Store) void {
        if (self.allocator) |allocator| allocator.free(self.memory);
    }

    /// Insert or overwrite a key.
    ///
    /// `key` and `value` must not alias `self.memory`; in particular, copy a
    /// `getView` result before passing it back to `put`. On error the store is
    /// logically unchanged.
    pub fn put(self: *Store, key: []const u8, value: []const u8) !void {
        switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| return Impl(hash_width, key_width, value_width)
                        .put(self, key, value),
                },
            },
        }
    }

    /// Copy a value into `buffer`. Returns null when the key is missing, or
    /// `error.BufferTooSmall` if the buffer cannot hold the value. `buffer`
    /// must not overlap `self.memory`.
    pub fn get(
        self: *const Store,
        key: []const u8,
        buffer: []u8,
    ) !?[]const u8 {
        switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| return Impl(hash_width, key_width, value_width)
                        .get(self, key, buffer),
                },
            },
        }
    }

    /// Borrowed view of a value, valid until the next `put`, `remove` or
    /// `deinit`. No allocation. The slice must be copied before being passed
    /// back into `put`.
    pub fn getView(self: *const Store, key: []const u8) ?[]const u8 {
        return switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .getView(self, key),
                },
            },
        };
    }

    /// Allocate a caller-owned copy of a value. Returns null without
    /// allocating when the key is missing.
    pub fn getAlloc(
        self: *const Store,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| return Impl(hash_width, key_width, value_width)
                        .getAlloc(self, key, allocator),
                },
            },
        }
    }

    /// Value length, or null when the key is missing. A zero-length value
    /// returns 0 and is distinct from a missing key.
    pub fn exists(self: *const Store, key: []const u8) ?u64 {
        return switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .exists(self, key),
                },
            },
        };
    }

    /// Remove a key and free both blocks. Returns whether the key was present.
    pub fn remove(self: *Store, key: []const u8) bool {
        return switch (self.header.flags.hash) {
            inline else => |hash_width| switch (self.header.flags.key_index) {
                inline else => |key_width| switch (self.header.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .remove(self, key),
                },
            },
        };
    }

    /// Live entries.
    pub fn count(self: *const Store) u64 {
        return self.hash_table.count;
    }

    /// Maximum live keys: slots * 3 / 4.
    pub fn capacity(self: *const Store) u64 {
        return self.hash_table.maxEntries();
    }

    /// Deep validation: re-run structural image validation and re-hash every
    /// live key, checking that it is reachable from its home slot.
    ///
    /// This inherits the load-time validation limits documented in the README:
    /// it does not prove that entry offsets are block starts or that references
    /// are unique, so it cannot detect every malformed image accepted by `load`.
    pub fn verify(self: *const Store) !void {
        _ = try image.validate(self.memory);

        if (self.header.table_size != self.hash_table.count) return error.Corrupt;
        if (self.header.key_free_head != self.keys.free_head) return error.Corrupt;
        if (self.header.value_free_head != self.values.free_head) return error.Corrupt;

        var index: u64 = 0;
        while (index < self.hash_table.slots) : (index += 1) {
            const entry = self.hash_table.entryAt(index);
            if (entry.hash == 0) continue;

            const key = self.keys.payload(entry.key_off);
            const hash_value = hash.hashKey(key, self.header.flags.hash);
            if (hash_value != entry.hash) return error.Corrupt;

            const slot = self.hash_table.lookup(&self.keys, key, hash_value) orelse
                return error.Corrupt;
            if (slot.index != index) return error.Corrupt;
        }
    }

    /// Mirror the runtime table/free-list state into the image header.
    ///
    /// The constants (magic, flags, capacities) never change after creation, so
    /// only the three mutable words are rewritten.
    inline fn syncHeader(self: *Store) void {
        self.header.table_size = self.hash_table.count;
        self.header.key_free_head = self.keys.free_head;
        self.header.value_free_head = self.values.free_head;
        format.Header.writeRuntimeState(
            self.memory,
            self.header.table_size,
            self.header.key_free_head,
            self.header.value_free_head,
        );
    }

    /// Iterate live entries in slot order. The iterator borrows the store; its
    /// key/value views are valid until the next `put`, `remove` or `deinit`.
    /// Any mutation invalidates an existing iterator (Debug builds assert on
    /// the store's generation; release builds treat use as undefined).
    pub fn iterator(self: *const Store) Iterator {
        return .{
            .store = self,
            .index = 0,
            .generation = self.generation,
        };
    }

    /// Write the whole image to a new or truncated file. No fsync.
    pub fn save(
        self: *const Store,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        const file = try dir.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, self.memory);
    }

    /// Write the image to a temporary file and atomically replace `path`.
    pub fn saveAtomic(
        self: *const Store,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        var atomic = try dir.createFileAtomic(io, path, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, self.memory);
        try atomic.replace(io);
    }

    /// Read and validate an image into a fresh allocation.
    ///
    /// Validation is structural only; see the README "Known limitations" for
    /// crafted images that can pass validation.
    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Store {
        const stat = try dir.statFile(io, path, .{});
        const size = std.math.cast(usize, stat.size) orelse return error.OutOfMemory;

        const memory = try allocator.alloc(u8, size);
        errdefer allocator.free(memory);

        const file = try dir.openFile(io, path, .{});
        defer file.close(io);
        const read = try file.readPositionalAll(io, memory, 0);
        if (read != memory.len) return error.Corrupt;

        return adoptImage(memory, allocator);
    }

    /// Read and validate an image into a caller-owned buffer. The buffer may
    /// be larger than the file; only the prefix is used.
    ///
    /// Validation is structural only; see the README "Known limitations" for
    /// crafted images that can pass validation.
    pub fn loadInto(
        buffer: []u8,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Store {
        const stat = try dir.statFile(io, path, .{});
        const size = std.math.cast(usize, stat.size) orelse return error.OutOfMemory;
        if (buffer.len < size) return error.BufferTooSmall;

        const file = try dir.openFile(io, path, .{});
        defer file.close(io);
        const read = try file.readPositionalAll(io, buffer[0..size], 0);
        if (read != size) return error.Corrupt;

        return adoptImage(buffer[0..size], null);
    }

    /// Validate an existing image and construct a store over it.
    fn adoptImage(memory: []u8, allocator: ?std.mem.Allocator) !Store {
        const validated = try image.validate(memory);
        return adoptValidated(memory, allocator, validated);
    }

    fn adoptValidated(
        memory: []u8,
        allocator: ?std.mem.Allocator,
        validated: image.ValidatedImage,
    ) !Store {
        const header = validated.header;
        const layout = validated.layout;
        std.debug.assert(memory.len == @as(usize, @intCast(layout.file_size)));

        const table_start: usize = format.header_size;
        const table_end: usize = table_start + @as(usize, @intCast(layout.table_bytes));
        const keys_start: usize = @intCast(layout.keys_offset);
        const keys_end: usize = @intCast(layout.values_offset);
        const values_end: usize = @intCast(layout.file_size);

        const hash_table = try table.Table.init(
            memory[table_start..table_end],
            header.flags,
            header.table_reserved,
            header.table_size,
        );
        const keys = arena.Arena.init(
            memory[keys_start..keys_end],
            header.flags.key_index,
            header.key_free_head,
        );
        const values = arena.Arena.init(
            memory[keys_end..values_end],
            header.flags.value_index,
            header.value_free_head,
        );

        return .{
            .memory = memory,
            .allocator = allocator,
            .generation = 0,
            .header = header,
            .hash_table = hash_table,
            .keys = keys,
            .values = values,
            .keys_offset = layout.keys_offset,
            .values_offset = layout.values_offset,
        };
    }

    fn formatMemory(
        memory: []u8,
        allocator: ?std.mem.Allocator,
        layout: image.Layout,
    ) !Store {
        std.debug.assert(memory.len == @as(usize, @intCast(layout.file_size)));

        const header: format.Header = .{
            .flags = layout.flags,
            .table_reserved = layout.table_reserved,
            .table_size = 0,
            .key_bytes = layout.key_bytes,
            .key_free_head = 0,
            .value_bytes = layout.value_bytes,
            .value_free_head = 0,
        };
        header.encode(memory);

        const table_start: usize = format.header_size;
        const table_end: usize = table_start + @as(usize, @intCast(layout.table_bytes));
        const keys_start: usize = @intCast(layout.keys_offset);
        const keys_end: usize = @intCast(layout.values_offset);
        const values_end: usize = @intCast(layout.file_size);

        const hash_table = try table.Table.formatEmpty(
            memory[table_start..table_end],
            layout.flags,
            layout.table_reserved,
        );
        const keys = try arena.Arena.initEmpty(
            memory[keys_start..keys_end],
            layout.flags.key_index,
        );
        const values = try arena.Arena.initEmpty(
            memory[keys_end..values_end],
            layout.flags.value_index,
        );

        return .{
            .memory = memory,
            .allocator = allocator,
            .generation = 0,
            .header = header,
            .hash_table = hash_table,
            .keys = keys,
            .values = values,
            .keys_offset = layout.keys_offset,
            .values_offset = layout.values_offset,
        };
    }
};

/// Copy a payload, using an inline fixed-size move for the short sizes that
/// dominate small key/value stores. A runtime-length `@memcpy` compiles to a
/// `memcpy` call, which costs more than the store itself at these sizes.
inline fn copyPayload(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    if (src.len == 8) {
        @as(*align(1) u64, @ptrCast(dst.ptr)).* =
            @as(*align(1) const u64, @ptrCast(src.ptr)).*;
    } else if (src.len == 16) {
        @as(*align(1) u128, @ptrCast(dst.ptr)).* =
            @as(*align(1) const u128, @ptrCast(src.ptr)).*;
    } else {
        @memcpy(dst, src);
    }
}

inline fn freeBlock(comptime A: type, a: *arena.Arena, off: u64) void {
    A.free(a, off) catch @panic("zigkv: arena invariant violated");
}

/// Fully specialized operations for one combination of field widths.
///
/// The public `Store` methods dispatch here exactly once; nothing in this type
/// re-checks a width.
fn Impl(
    comptime hash_width: format.HashWidth,
    comptime key_width: format.IndexWidth,
    comptime value_width: format.IndexWidth,
) type {
    const Hash = hash_width;
    const KeyArena = arena.Impl(key_width);
    const ValueArena = arena.Impl(value_width);
    const Table = table.Impl(hash_width, key_width, value_width);

    return struct {
        inline fn hashKey(key: []const u8) u64 {
            return switch (Hash) {
                .city32 => hash.city32(key),
                .city64 => hash.city64(key),
            };
        }

        inline fn maxKeyLen(s: *const Store) u64 {
            return s.header.key_bytes - KeyArena.header_size;
        }

        inline fn maxValueLen(s: *const Store) u64 {
            return s.header.value_bytes - ValueArena.header_size;
        }

        fn put(s: *Store, key: []const u8, value: []const u8) !void {
            const hash_value = hashKey(key);
            // One probe sequence for both the lookup and the insert position.
            const found = try Table.probe(&s.hash_table, &s.keys, key, hash_value);

            if (found.entry) |entry| {
                return putExisting(s, found.index, entry.val_off, value);
            }

            const key_len: u64 = @intCast(key.len);
            const value_len: u64 = @intCast(value.len);
            if (key_len > maxKeyLen(s)) return error.KeyTooLarge;
            if (value_len > maxValueLen(s)) return error.ValueTooLarge;

            // Allocate both blocks before mutating the table so an allocation
            // failure leaves the store logically unchanged.
            const key_block = try KeyArena.allocBlock(&s.keys, key_len);
            errdefer freeBlock(KeyArena, &s.keys, key_block.off);
            copyPayload(key_block.payload, key);

            const value_block = try ValueArena.allocBlock(&s.values, value_len);
            errdefer freeBlock(ValueArena, &s.values, value_block.off);
            copyPayload(value_block.payload, value);

            Table.placeAt(&s.hash_table, found.index, hash_value, key_block.off, value_block.off);

            s.syncHeader();
            s.generation += 1;
        }

        /// Overwrite the value of an existing key. Kept out of line so the
        /// insert path above stays small; the arena coalescing code linked
        /// from the grow/replace branch is not needed there.
        noinline fn putExisting(
            s: *Store,
            index: u64,
            old_off: u64,
            value: []const u8,
        ) !void {
            const value_len: u64 = @intCast(value.len);
            if (value_len > maxValueLen(s)) return error.ValueTooLarge;

            const old_size = ValueArena.sizeAt(&s.values, old_off);

            if (value_len <= old_size - ValueArena.header_size) {
                // Keep the block: write the new payload, update `len`, and
                // return any tail that can hold a minimum block.
                if (value.len != 0) {
                    copyPayload(
                        ValueArena.payloadSpan(&s.values, old_off)[0..value.len],
                        value,
                    );
                }
                try ValueArena.shrinkToFit(&s.values, old_off, value_len);
            } else {
                const block = try ValueArena.allocBlock(&s.values, value_len);
                errdefer freeBlock(ValueArena, &s.values, block.off);

                copyPayload(block.payload, value);
                Table.setValueOffset(&s.hash_table, index, block.off);
                freeBlock(ValueArena, &s.values, old_off);
            }

            s.syncHeader();
            s.generation += 1;
        }

        fn get(s: *const Store, key: []const u8, buffer: []u8) !?[]const u8 {
            const val_off = Table.lookupValueOff(
                &s.hash_table,
                &s.keys,
                key,
                hashKey(key),
            ) orelse return null;

            const value = ValueArena.payloadConst(&s.values, val_off);
            if (value.len > buffer.len) return error.BufferTooSmall;
            copyPayload(buffer[0..value.len], value);
            return buffer[0..value.len];
        }

        fn getView(s: *const Store, key: []const u8) ?[]const u8 {
            const val_off = Table.lookupValueOff(
                &s.hash_table,
                &s.keys,
                key,
                hashKey(key),
            ) orelse return null;
            return ValueArena.payloadConst(&s.values, val_off);
        }

        fn getAlloc(
            s: *const Store,
            key: []const u8,
            allocator: std.mem.Allocator,
        ) !?[]u8 {
            const val_off = Table.lookupValueOff(
                &s.hash_table,
                &s.keys,
                key,
                hashKey(key),
            ) orelse return null;

            const value = ValueArena.payloadConst(&s.values, val_off);
            const copy = try allocator.alloc(u8, value.len);
            copyPayload(copy, value);
            return copy;
        }

        fn exists(s: *const Store, key: []const u8) ?u64 {
            const val_off = Table.lookupValueOff(
                &s.hash_table,
                &s.keys,
                key,
                hashKey(key),
            ) orelse return null;
            return @intCast(ValueArena.payloadLen(&s.values, val_off));
        }

        fn remove(s: *Store, key: []const u8) bool {
            const removed = Table.remove(
                &s.hash_table,
                &s.keys,
                key,
                hashKey(key),
            ) orelse return false;

            freeBlock(ValueArena, &s.values, removed.entry.val_off);
            freeBlock(KeyArena, &s.keys, removed.entry.key_off);

            s.syncHeader();
            s.generation += 1;
            return true;
        }
    };
}

/// Borrowed key/value pair yielded by `Iterator`.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Slot-order iterator over a store. Mutating the store invalidates it.
pub const Iterator = struct {
    store: *const Store,
    index: u64,
    /// Store generation at iterator creation, used for the Debug validity
    /// assert.
    generation: u64,

    /// Return the next live entry, or null when iteration is complete.
    pub fn next(self: *Iterator) ?Entry {
        std.debug.assert(self.generation == self.store.generation);

        const hash_table = &self.store.hash_table;
        while (self.index < hash_table.slots) {
            const index = self.index;
            self.index += 1;

            const entry = hash_table.entryAt(index);
            if (entry.hash == 0) continue;

            return .{
                .key = self.store.keys.payload(entry.key_off),
                .value = self.store.values.payload(entry.val_off),
            };
        }
        return null;
    }
};

test "version is set" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

comptime {
    // Include the unit/property/corruption suite in test builds only. Keeping
    // the test file in this module lets it exercise internal layers without
    // giving those files to a second module.
    if (@import("builtin").is_test) {
        _ = @import("zigkv_test.zig");
    }
}
