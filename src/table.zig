//! Open-addressed hash table with linear probing, full-hash entries and
//! backward-shift deletion (no tombstones).
//!
//! The table only owns slot storage. Keys are compared through the key arena
//! and key/value block allocation is the caller's responsibility; `insert`
//! expects the key to be absent (the store performs the lookup first).

const std = @import("std");
const arena = @import("arena.zig");
const format = @import("format.zig");

pub const Table = struct {
    /// Table section of the image: exactly `slots * entry_size` bytes.
    memory: []u8,
    endian: format.Endian,
    flags: format.Flags,
    slots: u64,
    /// Live entries, persisted as the header's `table_size`.
    count: u64,

    pub const Slot = struct {
        index: u64,
        entry: format.EntryFields,
    };

    /// Attach to an existing table. Validates the slot count, entry size and
    /// load-factor accounting; deeper structural checks belong to the image
    /// validator.
    pub fn init(
        memory: []u8,
        flags: format.Flags,
        slots: u64,
        endian: format.Endian,
        count: u64,
    ) !Table {
        if (slots < format.min_slots) return error.Corrupt;
        if (!std.math.isPowerOfTwo(slots)) return error.Corrupt;

        const entry_size = format.entrySize(flags.hash, flags.key_index, flags.value_index);
        const table_bytes = std.math.mul(u64, slots, entry_size) catch return error.Corrupt;
        if (table_bytes != @as(u64, @intCast(memory.len))) return error.Corrupt;

        const max = slots / format.load_factor_denominator * format.load_factor_numerator;
        if (count > max) return error.Corrupt;

        return .{
            .memory = memory,
            .endian = endian,
            .flags = flags,
            .slots = slots,
            .count = count,
        };
    }

    /// Create an all-empty table.
    pub fn formatEmpty(
        memory: []u8,
        flags: format.Flags,
        slots: u64,
        endian: format.Endian,
    ) !Table {
        const table = try init(memory, flags, slots, endian, 0);
        @memset(table.memory, 0);
        return table;
    }

    pub fn entrySize(self: *const Table) u64 {
        return format.entrySize(self.flags.hash, self.flags.key_index, self.flags.value_index);
    }

    /// Maximum live keys: slots * 3 / 4.
    pub fn maxEntries(self: *const Table) u64 {
        return self.slots / format.load_factor_denominator *
            format.load_factor_numerator;
    }

    pub fn entryAt(self: *const Table, index: u64) format.EntryFields {
        std.debug.assert(index < self.slots);
        return switch (self.flags.hash) {
            inline else => |hash_width| switch (self.flags.key_index) {
                inline else => |key_width| switch (self.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .read(self, index),
                },
            },
        };
    }

    /// Find a key. `hash_value` must be the key's nonzero remapped hash.
    pub fn lookup(
        self: *const Table,
        keys: *const arena.Arena,
        key: []const u8,
        hash_value: u64,
    ) ?Slot {
        return switch (self.flags.hash) {
            inline else => |hash_width| switch (self.flags.key_index) {
                inline else => |key_width| switch (self.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .lookup(self, keys, key, hash_value),
                },
            },
        };
    }

    /// Insert a key that is not already present. Returns `error.TableFull`
    /// when the 0.75 load factor would be exceeded; the table is unchanged.
    pub fn insert(
        self: *Table,
        keys: *const arena.Arena,
        key: []const u8,
        hash_value: u64,
        key_off: u64,
        val_off: u64,
    ) !void {
        return switch (self.flags.hash) {
            inline else => |hash_width| switch (self.flags.key_index) {
                inline else => |key_width| switch (self.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .insert(self, keys, key, hash_value, key_off, val_off),
                },
            },
        };
    }

    /// Remove a key with backward-shift deletion. Returns the removed entry,
    /// or null when the key is missing.
    pub fn remove(
        self: *Table,
        keys: *const arena.Arena,
        key: []const u8,
        hash_value: u64,
    ) ?Slot {
        return switch (self.flags.hash) {
            inline else => |hash_width| switch (self.flags.key_index) {
                inline else => |key_width| switch (self.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .remove(self, keys, key, hash_value),
                },
            },
        };
    }

    /// Replace the value offset of an existing slot.
    pub fn setValueOffset(self: *Table, index: u64, val_off: u64) void {
        std.debug.assert(index < self.slots);
        switch (self.flags.hash) {
            inline else => |hash_width| switch (self.flags.key_index) {
                inline else => |key_width| switch (self.flags.value_index) {
                    inline else => |value_width| Impl(hash_width, key_width, value_width)
                        .setValueOffset(self, index, val_off),
                },
            },
        }
    }
};

fn Impl(
    comptime hash_width: format.HashWidth,
    comptime key_width: format.IndexWidth,
    comptime value_width: format.IndexWidth,
) type {
    const Entry = format.TableEntry(hash_width, key_width, value_width);

    return struct {
        fn pos(index: u64) usize {
            return @intCast(index * @as(u64, Entry.size));
        }

        fn read(self: *const Table, index: u64) format.EntryFields {
            return Entry.read(self.memory, pos(index), self.endian);
        }

        fn write(self: *Table, index: u64, fields: format.EntryFields) void {
            Entry.write(self.memory, pos(index), fields, self.endian);
        }

        fn lookup(
            self: *const Table,
            keys: *const arena.Arena,
            key: []const u8,
            hash_value: u64,
        ) ?Table.Slot {
            std.debug.assert(hash_value != 0);
            const mask = self.slots - 1;

            var index = hash_value & mask;
            var probes: u64 = 0;
            while (probes < self.slots) : (probes += 1) {
                const entry = read(self, index);
                if (entry.hash == 0) return null;
                if (entry.hash == hash_value and
                    std.mem.eql(u8, keys.payload(entry.key_off), key))
                {
                    return .{ .index = index, .entry = entry };
                }
                index = (index + 1) & mask;
            }
            return null;
        }

        fn insert(
            self: *Table,
            keys: *const arena.Arena,
            key: []const u8,
            hash_value: u64,
            key_off: u64,
            val_off: u64,
        ) !void {
            std.debug.assert(hash_value != 0);
            if (self.count >= Table.maxEntries(self)) return error.TableFull;

            const mask = self.slots - 1;

            var index = hash_value & mask;
            var probes: u64 = 0;
            while (probes < self.slots) : (probes += 1) {
                const entry = read(self, index);
                if (entry.hash == 0) {
                    write(self, index, .{
                        .hash = hash_value,
                        .key_off = key_off,
                        .val_off = val_off,
                    });
                    self.count += 1;
                    return;
                }

                // The store looks up before inserting; catch a caller mistake.
                std.debug.assert(!(entry.hash == hash_value and
                    std.mem.eql(u8, keys.payload(entry.key_off), key)));

                index = (index + 1) & mask;
            }

            return error.TableFull;
        }

        fn remove(
            self: *Table,
            keys: *const arena.Arena,
            key: []const u8,
            hash_value: u64,
        ) ?Table.Slot {
            const found = lookup(self, keys, key, hash_value) orelse return null;
            return removeAt(self, found.index);
        }

        fn removeAt(self: *Table, index: u64) Table.Slot {
            std.debug.assert(self.count > 0);
            const removed: Table.Slot = .{
                .index = index,
                .entry = read(self, index),
            };
            self.count -= 1;

            const mask = self.slots - 1;

            var hole = index;
            outer: while (true) {
                write(self, hole, .{ .hash = 0, .key_off = 0, .val_off = 0 });

                var k = hole;
                while (true) {
                    k = (k + 1) & mask;
                    const entry = read(self, k);
                    if (entry.hash == 0) return removed;

                    const home = entry.hash & mask;
                    if (cyclicallyBetween(hole, home, k, self.slots)) {
                        // Moving this entry earlier would put it before its
                        // home slot, so it must stay.
                        continue;
                    }

                    write(self, hole, entry);
                    hole = k;
                    continue :outer;
                }
            }
        }

        fn setValueOffset(self: *Table, index: u64, val_off: u64) void {
            var entry = read(self, index);
            entry.val_off = val_off;
            write(self, index, entry);
        }
    };
}

/// True when `home` lies in the cyclic interval `(hole, k]`. Such an entry
/// cannot be moved into `hole` without breaking its probe sequence.
fn cyclicallyBetween(hole: u64, home: u64, k: u64, slots: u64) bool {
    const home_distance = cyclicDistance(hole, home, slots);
    const k_distance = cyclicDistance(hole, k, slots);
    return home_distance != 0 and home_distance <= k_distance;
}

fn cyclicDistance(from: u64, to: u64, slots: u64) u64 {
    return if (to >= from) to - from else to + (slots - from);
}
