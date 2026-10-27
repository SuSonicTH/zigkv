//! Key hashing: CityHash32 / CityHash64 with the format's zero-hash remap.

const std = @import("std");
const format = @import("format.zig");

/// `hash == 0` marks an empty table slot, so a zero CityHash result is
/// remapped to 1.
pub fn remap(value: u64) u64 {
    return if (value == 0) 1 else value;
}

pub fn city32(key: []const u8) u64 {
    return remap(@as(u64, std.hash.CityHash32.hash(key)));
}

pub fn city64(key: []const u8) u64 {
    return remap(std.hash.CityHash64.hash(key));
}

/// Hash a key with the width declared in the image header.
pub fn hashKey(key: []const u8, width: format.HashWidth) u64 {
    return switch (width) {
        .city32 => city32(key),
        .city64 => city64(key),
    };
}
