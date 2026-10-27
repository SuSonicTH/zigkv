//! Address-ordered, coalescing arena for key and value blocks.
//!
//! The free list is sorted by block offset and fully coalesced: no two free
//! blocks are adjacent between operations. Allocation is first-fit from the
//! lowest address, splitting a free block when the remainder can hold a
//! minimum block. Blocks are 8-byte aligned and their header width follows the
//! arena's index width (8 bytes for u32, 16 bytes for u64).

const std = @import("std");
const format = @import("format.zig");

pub const Arena = struct {
    /// The arena section of the image. Offsets used by this API are relative
    /// to this slice.
    memory: []u8,
    endian: format.Endian,
    width: format.IndexWidth,
    /// Offset of the first free block, or `NONE`.
    free_head: u64,

    /// Attach to an existing, already-validated arena without modifying it.
    pub fn init(
        memory: []u8,
        width: format.IndexWidth,
        endian: format.Endian,
        free_head: u64,
    ) Arena {
        return .{
            .memory = memory,
            .endian = endian,
            .width = width,
            .free_head = free_head,
        };
    }

    /// Format an empty arena as one large free block. `memory.len` must be a
    /// multiple of 8, hold at least one block header, and fit the declared
    /// index width.
    pub fn initEmpty(
        memory: []u8,
        width: format.IndexWidth,
        endian: format.Endian,
    ) !Arena {
        if (memory.len < format.blockHeaderSize(width)) return error.Corrupt;
        if (memory.len % 8 != 0) return error.Corrupt;

        const cap: u64 = @intCast(memory.len);
        if (cap > format.arenaMax(width)) return error.ValueTooLarge;

        var result = Arena{
            .memory = memory,
            .endian = endian,
            .width = width,
            .free_head = 0,
        };
        switch (width) {
            .u32 => Impl(.u32).writeEmpty(&result),
            .u64 => Impl(.u64).writeEmpty(&result),
        }
        return result;
    }

    pub fn capacity(self: *const Arena) u64 {
        return @intCast(self.memory.len);
    }

    /// Allocate a block whose payload can hold `len` bytes and return its
    /// offset. The block may be larger than requested at the end of the arena.
    pub fn alloc(self: *Arena, len: u64) !u64 {
        return switch (self.width) {
            .u32 => Impl(.u32).alloc(self, len),
            .u64 => Impl(.u64).alloc(self, len),
        };
    }

    /// Free the allocated block at `off`. Coalesces with free neighbors and
    /// keeps the free list sorted by offset.
    pub fn free(self: *Arena, off: u64) !void {
        return switch (self.width) {
            .u32 => Impl(.u32).free(self, off),
            .u64 => Impl(.u64).free(self, off),
        };
    }

    /// Total block size, including the header and padding.
    pub fn blockSize(self: *const Arena, off: u64) u64 {
        return switch (self.width) {
            .u32 => Impl(.u32).sizeAt(self, off),
            .u64 => Impl(.u64).sizeAt(self, off),
        };
    }

    /// Borrowed payload of an allocated block.
    pub fn payload(self: *const Arena, off: u64) []const u8 {
        return switch (self.width) {
            .u32 => Impl(.u32).payloadConst(self, off),
            .u64 => Impl(.u64).payloadConst(self, off),
        };
    }

    /// Mutable payload of an allocated block.
    pub fn payloadMut(self: *Arena, off: u64) []u8 {
        return switch (self.width) {
            .u32 => Impl(.u32).payloadMutable(self, off),
            .u64 => Impl(.u64).payloadMutable(self, off),
        };
    }

    /// Mutable backing span of an allocated block: header-size bytes through
    /// the end of the block (payload plus padding). Used for in-place growth.
    pub fn payloadSpan(self: *Arena, off: u64) []u8 {
        return switch (self.width) {
            .u32 => Impl(.u32).payloadSpan(self, off),
            .u64 => Impl(.u64).payloadSpan(self, off),
        };
    }

    /// Set a smaller payload length in place and return the unused tail to the
    /// free list when it can hold a minimum block. The payload bytes must
    /// already be written.
    pub fn shrinkToFit(self: *Arena, off: u64, new_len: u64) !void {
        return switch (self.width) {
            .u32 => Impl(.u32).shrinkToFit(self, off, new_len),
            .u64 => Impl(.u64).shrinkToFit(self, off, new_len),
        };
    }
};

fn Impl(comptime width: format.IndexWidth) type {
    const Block = format.Block(width);

    return struct {
        fn pos(off: u64) usize {
            return @intCast(off);
        }

        fn capacity(self: *const Arena) u64 {
            return @intCast(self.memory.len);
        }

        fn sizeAt(self: *const Arena, off: u64) u64 {
            return Block.readSize(self.memory, pos(off), self.endian);
        }

        fn nextAt(self: *const Arena, off: u64) u64 {
            return Block.readNext(self.memory, pos(off), self.endian);
        }

        fn lenAt(self: *const Arena, off: u64) u64 {
            return Block.readLen(self.memory, pos(off), self.endian);
        }

        fn writeEmpty(self: *Arena) void {
            Block.writeSize(self.memory, 0, @intCast(self.memory.len), self.endian);
            Block.writeNext(self.memory, 0, Block.none, self.endian);
        }

        fn alloc(self: *Arena, len: u64) !u64 {
            const need = try alignNeeded(len, @intCast(Block.header_size), capacity(self));

            var prev: u64 = Block.none;
            var cur = self.free_head;
            while (cur != Block.none) {
                std.debug.assert(cur < capacity(self));
                std.debug.assert(cur % 8 == 0);

                const size = sizeAt(self, cur);
                const next = nextAt(self, cur);
                std.debug.assert(size >= Block.min_size);
                std.debug.assert(size % 8 == 0);
                std.debug.assert(size <= capacity(self) - cur);

                if (size >= need) {
                    if (size - need >= Block.min_size) {
                        // Keep the block here, move the free remainder after it.
                        const remainder = cur + need;
                        Block.writeSize(self.memory, pos(remainder), size - need, self.endian);
                        Block.writeNext(self.memory, pos(remainder), next, self.endian);
                        if (prev == Block.none) {
                            self.free_head = remainder;
                        } else {
                            Block.writeNext(self.memory, pos(prev), remainder, self.endian);
                        }
                        Block.writeSize(self.memory, pos(cur), need, self.endian);
                    } else {
                        // The tail is too small to become a block; consume it
                        // and keep the original, larger block size.
                        if (prev == Block.none) {
                            self.free_head = next;
                        } else {
                            Block.writeNext(self.memory, pos(prev), next, self.endian);
                        }
                    }

                    Block.writeLen(self.memory, pos(cur), len, self.endian);
                    return cur;
                }

                prev = cur;
                cur = next;
            }

            return error.OutOfSpace;
        }

        fn free(self: *Arena, off: u64) !void {
            const cap = capacity(self);
            if (off >= cap or off % 8 != 0) return error.Corrupt;

            const size = sizeAt(self, off);
            if (size < Block.min_size or size % 8 != 0) return error.Corrupt;
            if (size > cap - off) return error.Corrupt;

            // Find the insertion point: prev < off < cur.
            var prev: u64 = Block.none;
            var cur = self.free_head;
            while (cur != Block.none and cur < off) {
                std.debug.assert(cur < cap);
                prev = cur;
                cur = nextAt(self, cur);
            }
            if (cur == off) return error.Corrupt; // already free

            var merged_size = size;
            var merged_next = cur;
            var merge_prev = false;

            if (prev != Block.none) {
                const prev_size = sizeAt(self, prev);
                if (prev + prev_size == off) {
                    merged_size = std.math.add(u64, prev_size, size) catch
                        return error.Corrupt;
                    merge_prev = true;
                }
            }

            if (cur != Block.none) {
                const cur_size = sizeAt(self, cur);
                if (off + size == cur) {
                    merged_size = std.math.add(u64, merged_size, cur_size) catch
                        return error.Corrupt;
                    merged_next = nextAt(self, cur);
                }
            }

            if (merge_prev) {
                Block.writeSize(self.memory, pos(prev), merged_size, self.endian);
                Block.writeNext(self.memory, pos(prev), merged_next, self.endian);
            } else {
                Block.writeSize(self.memory, pos(off), merged_size, self.endian);
                Block.writeNext(self.memory, pos(off), merged_next, self.endian);
                if (prev == Block.none) {
                    self.free_head = off;
                } else {
                    Block.writeNext(self.memory, pos(prev), off, self.endian);
                }
            }
        }

        fn payloadConst(self: *const Arena, off: u64) []const u8 {
            const start = pos(off) + Block.header_size;
            const len = lenAt(self, off);
            return self.memory[start..][0..@intCast(len)];
        }

        fn payloadMutable(self: *Arena, off: u64) []u8 {
            const start = pos(off) + Block.header_size;
            const len = lenAt(self, off);
            return self.memory[start..][0..@intCast(len)];
        }

        fn payloadSpan(self: *Arena, off: u64) []u8 {
            const span_len = sizeAt(self, off) - @as(u64, @intCast(Block.header_size));
            const start = pos(off) + Block.header_size;
            return self.memory[start..][0..@intCast(span_len)];
        }

        fn shrinkToFit(self: *Arena, off: u64, new_len: u64) !void {
            const size = sizeAt(self, off);
            const header_size: u64 = @intCast(Block.header_size);
            if (new_len > size - header_size) return error.Corrupt;

            const needed = try alignNeeded(new_len, header_size, capacity(self));
            if (needed > size) return error.Corrupt;

            const tail = size - needed;
            if (tail >= Block.min_size) {
                Block.writeSize(self.memory, pos(off + needed), tail, self.endian);
                Block.writeSize(self.memory, pos(off), needed, self.endian);
                Block.writeLen(self.memory, pos(off), new_len, self.endian);
                try free(self, off + needed);
            } else {
                Block.writeLen(self.memory, pos(off), new_len, self.endian);
            }
        }
    };
}

/// Round `header_size + len` up to a multiple of 8. The requested block must
/// fit in the arena.
fn alignNeeded(len: u64, header_size: u64, capacity: u64) !u64 {
    const with_header = std.math.add(u64, len, header_size) catch return error.OutOfSpace;
    const padded = std.math.add(u64, with_header, 7) catch return error.OutOfSpace;
    const need = padded & ~@as(u64, 7);
    if (need > capacity) return error.OutOfSpace;
    return need;
}
