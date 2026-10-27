# zigkv file format (version 001)

A zigkv image is a single contiguous byte sequence. It is the same memory the
store operates on: `save` writes the image directly and `load` reads and
validates it without a serialization pass.

All multi-byte integers use the byte order declared in the header. A store is
created in the host's native byte order; an image created on a host with a
different byte order is rejected with `error.UnsupportedEndianness`.

```

offset 0                      header (64 bytes)
offset 64                     table (slots * entry_size)
align8(64 + table_bytes)      key arena (key_bytes)
keys_offset + key_bytes       value arena (value_bytes)

```

The image length is exactly `values_offset + value_bytes`. There is no trailing
data and no additional padding.

## Header

The header is eight 64-bit words, with the first word replaced by the ASCII
magic `zigkv001`. The `001` suffix is the file-format version.

| Offset | Field             | Meaning                                             |
|--------|-------------------|-----------------------------------------------------|
| 0      | `magic`           | ASCII `zigkv001`                                    |
| 8      | `flags`           | hash/index widths and byte order                    |
| 16     | `table_reserved`  | slot count: power of two, at least 16               |
| 24     | `table_size`      | live entries                                        |
| 32     | `key_bytes`       | key arena capacity                                  |
| 40     | `key_free_head`   | first free key block, or `NONE`                     |
| 48     | `value_bytes`     | value arena capacity                                |
| 56     | `value_free_head` | first free value block, or `NONE`                   |

### Flags

| Bit | Meaning                                            |
|-----|----------------------------------------------------|
| 0   | hash width: 0 = CityHash32, 1 = CityHash64         |
| 1   | key index width: 0 = `u32`, 1 = `u64`              |
| 2   | value index width: 0 = `u32`, 1 = `u64`            |
| 3   | data byte order: 0 = little-endian, 1 = big-endian |
| 59  | duplicate of bit 3                                 |
| all others | reserved, must be zero                       |

The duplicated byte-order bit is the bootstrap. For a flags word stored in the
file's byte order, bit 3 appears in byte 8 when read as little-endian and in
byte 15 when read as big-endian. Both bytes carry the same bit in a valid image,
so the loader can determine the file's byte order before decoding any other
field:

```text
lo = (bytes[8]  >> 3) & 1
hi = (bytes[15] >> 3) & 1

if lo != hi            -> error.Corrupt
if lo == 1             -> big-endian
else                   -> little-endian

if file order != host order -> error.UnsupportedEndianness
```

After bootstrapping, the loader reads the complete flags word in the file's byte
order and requires bit 3 == bit 59 and all reserved bits to be zero.

`table_reserved` must be a power of two and at least 16. `table_size` must not
exceed `table_reserved * 3 / 4`.

Arena capacities must be multiples of 8, at least one block header (8 bytes for
a `u32` arena, 16 bytes for a `u64` arena), and no larger than the arena's index
can represent:

- 32-bit arena: at most `0xFFFF_FFF8`
- 64-bit arena: bounded by the host address space / image size

## Table entries

A table entry is three back-to-back fields with no padding:

```text
hash      u32 or u64
key_off   u32 or u64
val_off   u32 or u64
```

The hash width is selected by flags bit 0; the two offsets by flags bits 1 and 2.
Entries are 12, 16, 20, or 24 bytes and may be accessed unaligned.

- `hash == 0` means an empty slot. A CityHash result of zero is remapped to 1.
- The full hash is stored. The slot index is `hash & (table_reserved - 1)`.
- Empty slots ignore `key_off` and `val_off`.

Lookup uses linear probing:

```text
h = hash(key); if h == 0 then h = 1
i = h & mask

repeat table_reserved times:
    e = entry(i)
    if e.hash == 0: return missing
    if e.hash == h and key_at(e.key_off) == key: return e
    i = (i + 1) & mask

return missing
```

Deletion uses backward-shift deletion. There are no tombstones. An entry at
probe position `k` is moved into the hole only when its home slot is not in the
cyclic interval `(hole, k]`; otherwise lookup for that key could stop at the
hole before reaching `k`.

## Key and value blocks

The key and value arenas are independent. A block header is 8 bytes in a
`u32` arena and 16 bytes in a `u64` arena. Blocks are 8-byte aligned.

Allocated block:

```text
u32 arena:  size:u32  len:u32  payload[len]  padding
u64 arena:  size:u64  len:u64  payload[len]  padding
```

Free block:

```text
u32 arena:  size:u32  next:u32
u64 arena:  size:u64  next:u64
```

- `size` is the total block size including the header, including alignment
  padding, and is always a multiple of 8.
- `len` is the payload length. Payload begins at `offset + header_size`.
- `next` is the next free block offset, or `NONE`.
- `NONE` is all-ones for the arena width. It is never 8-aligned, so it cannot
  collide with a valid block offset. Offset 0 is valid.
- A zero-length value still has a real block.

The free list is sorted by offset and fully coalesced: no two free blocks are
adjacent between operations. Allocation is first-fit from the lowest address
and splits a free block when the tail can hold a minimum block.

Freeing walks the free list to the insertion point and coalesces with the
previous block, the next block, or both.

## Validation

`load` and `loadInto` validate the image structure before returning a store:

1. length at least 64 bytes, magic/version, and byte-order bootstrap;
2. flags: reserved bits, duplicated endian bit, supported field widths;
3. host byte order;
4. slot count power-of-two and at least 16, with overflow-checked layout math;
5. arena capacities, alignment, and width limits;
6. exact image length;
7. load-factor accounting;
8. free-list bounds, alignment, sortedness, coalescing, and cycle-freedom;
9. arena tiling from offset 0 to capacity, with valid block sizes and payload
   lengths;
10. every live table entry has in-bounds, 8-aligned key/value offsets and a valid
    block header and payload length at that offset, and the live-entry count
    matches `table_size`.

`Store.verify` additionally re-hashes every live key and confirms that it is
reachable from its home slot.

### Validation limits

Validation is structural, but deliberately does not contain a full
reachability or ownership proof for table entries:

- A live entry's key/value offset is checked for bounds, 8-byte alignment, and a
  valid block header and payload length **at that offset**. It is not required
  to be the start of an arena block, so a fabricated header inside an allocated
  block's payload can pass.
- Distinct table entries are not checked for referencing distinct key/value
  blocks. Two slots may point at the same block and still pass validation.
- `verify()` re-hashes keys and checks probe reachability, but inherits these
  limits. In particular, an entry pointing at a fabricated header inside an
  allocated block can pass both `load` and `verify()`.

A crafted image that exploits either case can be corrupted by a later
`put`/`remove`, potentially leaving dangling table references and causing an
out-of-bounds read. Treat images from untrusted sources as unsafe.

## Persistence

- `save` creates/truncates the file and writes exactly `imageSize` bytes.
- `saveAtomic` writes a temporary file and atomically replaces the target.
- `load` allocates exactly the file size, reads it, and validates it.
- `loadInto` reads into a caller-provided buffer of at least the file size and
  uses only that prefix.
- No fsync is performed.
