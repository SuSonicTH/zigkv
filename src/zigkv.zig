//! zigkv: a single-file, memory-resident key/value store.
//!
//! The store image is the file format: saving is one write and loading is one
//! read, with no serialization or parsing pass. See docs/file-format.md for the
//! byte-level specification.
//!
//! This module is the public facade: `Store`, `Entry`, and `Iterator`.

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
        const hash_value = self.hashOf(key);

        if (self.hash_table.lookup(&self.keys, key, hash_value)) |slot| {
            const value_len: u64 = @intCast(value.len);
            if (value_len > self.maxValueLen()) return error.ValueTooLarge;

            const old_off = slot.entry.val_off;
            const header_size = format.blockHeaderSize(self.header.flags.value_index);
            const old_size = self.values.blockSize(old_off);

            if (value_len <= old_size - header_size) {
                // Keep the block: write the new payload, update `len`, and
                // return any tail that can hold a minimum block.
                if (value.len != 0) {
                    @memcpy(self.values.payloadSpan(old_off)[0..value.len], value);
                }
                try self.values.shrinkToFit(old_off, value_len);
            } else {
                const new_off = try self.values.alloc(value_len);
                errdefer freeBlock(&self.values, new_off);

                @memcpy(self.values.payloadMut(new_off), value);
                self.hash_table.setValueOffset(slot.index, new_off);
                freeBlock(&self.values, old_off);
            }

            self.syncHeader();
            self.generation += 1;
            return;
        }

        const key_len: u64 = @intCast(key.len);
        const value_len: u64 = @intCast(value.len);
        if (key_len > self.maxKeyLen()) return error.KeyTooLarge;
        if (value_len > self.maxValueLen()) return error.ValueTooLarge;
        if (self.hash_table.count >= self.hash_table.maxEntries()) {
            return error.TableFull;
        }

        // Allocate both blocks before mutating the table so an allocation
        // failure leaves the store logically unchanged.
        const key_off = try self.keys.alloc(key_len);
        errdefer freeBlock(&self.keys, key_off);
        @memcpy(self.keys.payloadMut(key_off), key);

        const val_off = try self.values.alloc(value_len);
        errdefer freeBlock(&self.values, val_off);
        @memcpy(self.values.payloadMut(val_off), value);

        try self.hash_table.insert(&self.keys, key, hash_value, key_off, val_off);

        self.syncHeader();
        self.generation += 1;
    }

    /// Copy a value into `buffer`. Returns null when the key is missing, or
    /// `error.BufferTooSmall` if the buffer cannot hold the value. `buffer`
    /// must not overlap `self.memory`.
    pub fn get(
        self: *const Store,
        key: []const u8,
        buffer: []u8,
    ) !?[]const u8 {
        const slot = self.hash_table.lookup(&self.keys, key, self.hashOf(key)) orelse
            return null;

        const value = self.values.payload(slot.entry.val_off);
        if (value.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }

    /// Borrowed view of a value, valid until the next `put`, `remove` or
    /// `deinit`. No allocation. The slice must be copied before being passed
    /// back into `put`.
    pub fn getView(self: *const Store, key: []const u8) ?[]const u8 {
        const slot = self.hash_table.lookup(&self.keys, key, self.hashOf(key)) orelse
            return null;
        return self.values.payload(slot.entry.val_off);
    }

    /// Allocate a caller-owned copy of a value. Returns null without
    /// allocating when the key is missing.
    pub fn getAlloc(
        self: *const Store,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        const slot = self.hash_table.lookup(&self.keys, key, self.hashOf(key)) orelse
            return null;

        const value = self.values.payload(slot.entry.val_off);
        const copy = try allocator.alloc(u8, value.len);
        @memcpy(copy, value);
        return copy;
    }

    /// Value length, or null when the key is missing. A zero-length value
    /// returns 0 and is distinct from a missing key.
    pub fn exists(self: *const Store, key: []const u8) ?u64 {
        const slot = self.hash_table.lookup(&self.keys, key, self.hashOf(key)) orelse
            return null;
        return @intCast(self.values.payload(slot.entry.val_off).len);
    }

    /// Remove a key and free both blocks. Returns whether the key was present.
    pub fn remove(self: *Store, key: []const u8) bool {
        const removed = self.hash_table.remove(&self.keys, key, self.hashOf(key)) orelse
            return false;

        freeBlock(&self.values, removed.entry.val_off);
        freeBlock(&self.keys, removed.entry.key_off);

        self.syncHeader();
        self.generation += 1;
        return true;
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

    fn hashOf(self: *const Store, key: []const u8) u64 {
        return hash.hashKey(key, self.header.flags.hash);
    }

    fn maxKeyLen(self: *const Store) u64 {
        return self.header.key_bytes -
            format.blockHeaderSize(self.header.flags.key_index);
    }

    fn maxValueLen(self: *const Store) u64 {
        return self.header.value_bytes -
            format.blockHeaderSize(self.header.flags.value_index);
    }

    /// Mirror the runtime table/free-list state into the image header.
    fn syncHeader(self: *Store) void {
        self.header.table_size = self.hash_table.count;
        self.header.key_free_head = self.keys.free_head;
        self.header.value_free_head = self.values.free_head;
        self.header.encode(self.memory);
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
            header.endian,
            header.table_size,
        );
        const keys = arena.Arena.init(
            memory[keys_start..keys_end],
            header.flags.key_index,
            header.endian,
            header.key_free_head,
        );
        const values = arena.Arena.init(
            memory[keys_end..values_end],
            header.flags.value_index,
            header.endian,
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

        const endian = format.native_endian;
        const header: format.Header = .{
            .flags = layout.flags,
            .endian = endian,
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
            endian,
        );
        const keys = try arena.Arena.initEmpty(
            memory[keys_start..keys_end],
            layout.flags.key_index,
            endian,
        );
        const values = try arena.Arena.initEmpty(
            memory[keys_end..values_end],
            layout.flags.value_index,
            endian,
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

fn freeBlock(a: *arena.Arena, off: u64) void {
    a.free(off) catch @panic("zigkv: arena invariant violated");
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
