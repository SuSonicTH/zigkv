# zigkv — implementation plan (v1.0, final)

Status: **finalized**. Implementation not started.
Target: Zig **0.17.0**, no third-party dependencies, 64-bit hosts.

## 1. Goals and non-goals

### Goals

* A single-file, memory-resident key/value store with variable-length binary keys
  and values.
* Two backing modes: owned (allocator) and caller-owned (`[]u8` buffer, which may
  be larger than the image).
* The in-memory image **is** the file format. `save` = one write, `load` = one
  read. No serialization pass.
* All cross-section references are **offsets relative to a section base**, never
  pointers. Everything is position-independent.
* `put`, `get`, `getView`, `getAlloc`, `remove`, `exists`, plus an iterator.
* CityHash32/CityHash64 over keys, open-addressed table, separate key/value
  arenas with address-ordered coalescing free lists.
* CLI (`zigkv`) for create/put/get/remove/exists/list/stat.
* Corruption-safe loading: a malformed file must produce an error, never
  out-of-bounds access or undefined behavior.

### Non-goals (v1)

* Concurrency / multi-process locking (single-threaded; caller synchronizes).
* Crash consistency, journaling, WAL. `save` is a bulk image write.
* Resizing an existing store (`TableFull` / `OutOfSpace` are terminal in v1).
  Growth is planned for a later version.
* Compaction (moving live data).
* mmap as a first-class feature. The README's "mem-mapped" wording is stale; a
  caller may pass an mmap'd buffer, but nothing special is done.
* Byte-swapping files: a big-endian image only loads on a big-endian host.

## 2. File format

All integers use the **native byte order of the creating host**, declared in the
header. `flags` carries the byte-order bit twice so the loader can bootstrap
(§2.1). All struct access uses unaligned `std.mem.readInt` / `writeInt`; a store
buffer has no alignment requirement.

### 2.1 Header — 64 bytes, 8 x u64

| off | field             | meaning                                                     |
|-----|-------------------|-------------------------------------------------------------|
| 0   | `magic`           | ASCII bytes `zigkv001`                                      |
| 8   | `flags`           | widths + byte order, see below                              |
| 16  | `table_reserved`  | slot count, power of two, >= 16                             |
| 24  | `table_size`      | live entries                                                |
| 32  | `key_bytes`       | key arena capacity, multiple of 8, >= block header size     |
| 40  | `key_free_head`   | offset of first free key block, or `NONE`                   |
| 48  | `value_bytes`     | value arena capacity, same rules                            |
| 56  | `value_free_head` | offset of first free value block, or `NONE`                 |

`flags` bits (all other bits reserved, must be 0):

| bit  | meaning                                                   |
|------|-----------------------------------------------------------|
| 0    | hash width: 0 = 32-bit, 1 = 64-bit                        |
| 1    | key index width: 0 = `u32`, 1 = `u64`                     |
| 2    | value index width: 0 = `u32`, 1 = `u64`                   |
| 3    | data byte order: 0 = little-endian, 1 = big-endian        |
| 59   | duplicate of bit 3; must equal bit 3                      |
| rest | reserved, zero                                            |

The duplicate endianness bit is the bootstrap. For the 8 bytes of `flags` at
offsets 8..15, bit 3 of the whole word is bit 3 of byte 8 under a little-endian
read and bit 3 of byte 15 under a big-endian read. Both bytes carry the same
bit, so the loader can determine the file's byte order before it can decode any
other field:

```
lo = (memory[8] >> 3) & 1
hi = (memory[15] >> 3) & 1
if (lo != hi) return error.Corrupt;
file_order = if (lo == 1) .big else .little;
if (file_order != native_endian) return error.UnsupportedEndianness;
```

After that, read `flags` in the file's byte order and verify bit 3 == bit 59
and that all reserved bits are zero. On write, constructing the word as
`width_bits | (order_bit << 3) | (order_bit << 59)` and serializing it in the
host byte order sets both copies correctly.

`magic` is ASCII, so it is byte-order independent. The `001` is the file version;
no separate field. Anything else -> `error.UnsupportedVersion`.

### 2.2 Layout

```
offset 0                      header (64 B)
offset 64                     table  (slots * entry_size)
align8(64 + table_bytes)      keys   (key_bytes)
keys_base + key_bytes         values (value_bytes)
```

`file_size == values_base + value_bytes` exactly. `keys_base` is 8-aligned
because `slots` is a power of two and `entry_size` is a multiple of 4. No other
padding.

### 2.3 Table entry

The entry is the concatenation of three fields, no padding, unaligned access:

```
hash      u32 or u64   (flags bit 0)
key_off   u32 or u64   (flags bit 1)
val_off   u32 or u64   (flags bit 2)
```

Sizes: 12, 16, 20 or 24 bytes.

* `hash == 0` means **empty slot**; a CityHash result of 0 is remapped to 1.
* The **full** hash is stored; only the slot index is masked
  (`slot = hash & (table_reserved - 1)`), so a future resize can rehash without
  reading key bytes.
* All eight width combinations are valid.

### 2.4 Key/value block

Block header width follows the arena's index width: **8 bytes** (`u32` arena) or
**16 bytes** (`u64` arena). Blocks are 8-byte aligned; minimum block = header
size.

```
u32 arena:
  allocated:  u32 size | u32 len   | payload[len] | padding
  free:       u32 size | u32 next
u64 arena:
  allocated:  u64 size | u64 len   | payload[len] | padding
  free:       u64 size | u64 next
```

* `size` = total block size including header, multiple of 8, stored for both
  allocated and free blocks.
* `len` = payload length; payload starts at `off + header_size`.
* `next == NONE` terminates the free list, which is **sorted by offset and fully
  coalesced**.
* Zero-length values still get a block, so `val_off` is always a real block.
* `NONE` = all-ones for the arena width (`0xFFFF_FFFF` /
  `0xFFFF_FFFF_FFFF_FFFF`); both are non-8-aligned, so they cannot collide with a
  valid block offset. Offset 0 remains valid.
* 32-bit arenas: capacity <= `0xFFFF_FFF8`, `len <= capacity - 8`.
* 64-bit arenas: capacity and `len` are `u64`.

## 3. Algorithms

### 3.1 Lookup

```
h = hash(key); if (h == 0) h = 1
i = h & mask
for probe in 0..table_reserved:
    e = entry(i)
    if e.hash == 0: return null
    if e.hash == h and keyAt(e.key_off) == key: return e
    i = (i + 1) & mask
return null
```

### 3.2 Insert / overwrite

1. Look up `key`.
2. If found: keep the key block. If `new_len <= old_block.size - header`, write
   in place, update `len`, and split the tail back into the free list when the
   tail is >= one minimum block. Otherwise allocate a new value block, copy, free
   the old one.
3. If absent: allocate and copy the key block, allocate and copy the value block,
   insert into the first empty slot, `table_size += 1`.
4. If `table_size + 1 > table_reserved * 3 / 4`, return `error.TableFull`.
5. `generation += 1` on success.

Failure atomicity: allocate both blocks before mutating the table; on any failure
free what was allocated and return with the store logically unchanged.

**Aliasing (Q13 = B):** `put` performs no alias detection. `key` and `value` must
not point into `self.memory`; otherwise the free-list/header writes and the
payload copy can corrupt the store (and `@memcpy` may overlap, which is UB). In
particular, a `getView` result must be copied before being passed to `put`.

### 3.3 Delete

* Find the slot; free the key and value blocks.
* Backward-shift deletion, no tombstones, exact `table_size`.
* `generation += 1`; return `true`.

```
j = i
while true:
  table[j] = empty
  k = j
  while true:
    k = (k + 1) & mask
    if table[k].hash == 0: return
    home = table[k].hash & mask
    if not cyclically_between(j, home, k): break
  table[j] = table[k]; j = k
```

### 3.4 Arena allocation — address-ordered, coalescing

The free list is kept sorted by offset and fully coalesced. No adjacent free
blocks can exist between operations.

`alloc(len)`:

1. `need = align8(header + len)`.
2. First-fit walk from the head (lowest address). If the head fits, O(1).
3. If `size - need >= min_block`: split in place; the remainder at `off + need`
   keeps the old `next`, and `block.size = need`. Otherwise unlink the block.
4. Set `len`, return `off`.

`free(off)`:

1. Walk to the insertion point (`prev < off < cur`), O(number of free blocks).
2. Coalesce with `prev` if `prev + prev.size == off`; coalesce with `cur` if
   `off + size == cur`.
3. Link the merged block.

Fragmentation is impossible: `alloc` fails only when no contiguous run is large
enough. `defragment()` is not needed and is not part of v1 (Q33 = A).

### 3.5 Load / validation

1. `len >= 64`; magic; byte-order bootstrap as in §2.1.
2. Read `flags` in the file's order: reserved bits zero, bit 3 == bit 59,
   entry size in {12, 16, 20, 24}.
3. Byte order matches the host, else `error.UnsupportedEndianness`.
4. `table_reserved` is a power of two >= 16; all layout math checked for
   overflow.
5. `key_bytes` / `value_bytes` multiples of 8, >= block header size, <= arena max
   for the declared width.
6. `file_size == values_base + value_bytes` exactly.
7. `table_size <= table_reserved * 3 / 4`.
8. Walk the free lists: sorted, in bounds, 8-aligned, sizes valid, no cycles, and
   two coalesced neighbors must never be adjacent.
9. **Arena tiling walk** per arena, O(capacity / min_block): advance from offset
   0 by each block's `size`, holding a cursor into the sorted free list. A block
   is free iff its offset equals the cursor; consume it and verify the next free
   block is not physically adjacent. Otherwise treat it as allocated and check
   `len <= size - header`. Finish at exactly `capacity` with the free cursor
   exhausted. This proves the arena is tiled without gaps or overlaps.
10. Walk the table: non-empty entries have in-bounds, 8-aligned offsets; the
    key/value block at each offset has a valid header and the payload fits the
    arena. Count live entries and compare with `table_size`.
11. Optional `verify()`: re-hash every live key, compare with the stored hash,
    and confirm reachability from its home slot.

`initWithBuffer` cannot re-validate a caller that scribbles the buffer later;
exclusive ownership while the store is live is documented.

### 3.6 Persistence

```
save(io, dir, path)              create/truncate, writeStreamingAll(image)
saveAtomic(io, dir, path)        createFileAtomic + write + rename
load(allocator, io, dir, path)   stat, alloc exact size, readPositionalAll, validate
loadInto(buf, io, dir, path)     caller buffer >= file size, read prefix, validate
```

No fsync by default. `save` writes exactly `imageSize` (the header-declared
size), never a larger caller buffer.

## 4. Public API

```zig
pub const Store = struct {
    memory: []u8,                  // exactly imageSize bytes
    allocator: ?std.mem.Allocator, // null => caller-owned
    generation: u64,               // not persisted; bumped by put/remove

    pub const HashWidth = enum(u1) { city32 = 0, city64 = 1 };
    pub const IndexWidth = enum(u1) { u32 = 0, u64 = 1 };

    pub const Options = struct {
        max_entries: u64 = 1024,       // slots, rounded up to a power of two
        key_bytes: u64 = 64 * 1024,
        value_bytes: u64 = 1024 * 1024,
        hash: HashWidth = .city64,
        key_index: IndexWidth = .u32,
        value_index: IndexWidth = .u32,
    };

    pub fn imageSize(options: Options) !u64;
    pub fn init(allocator: std.mem.Allocator, options: Options) !Store;
    pub fn initWithBuffer(buffer: []u8, options: Options) !Store;
    pub fn deinit(self: *Store) void;

    pub fn put(self: *Store, key: []const u8, value: []const u8) !void;
    pub fn get(self: *const Store, key: []const u8, buffer: []u8) !?[]const u8;
    pub fn getView(self: *const Store, key: []const u8) ?[]const u8;
    pub fn getAlloc(self: *const Store, key: []const u8, allocator: std.mem.Allocator) !?[]u8;
    pub fn exists(self: *const Store, key: []const u8) ?u64;
    pub fn remove(self: *Store, key: []const u8) bool;

    pub fn count(self: *const Store) u64;       // live entries
    pub fn capacity(self: *const Store) u64;    // max live keys = slots * 3 / 4
    pub fn iterator(self: *const Store) Iterator;
    pub fn verify(self: *const Store) !void;

    pub fn save(self: *const Store, io: std.Io, dir: std.Io.Dir, path: []const u8) !void;
    pub fn saveAtomic(self: *const Store, io: std.Io, dir: std.Io.Dir, path: []const u8) !void;
    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Store;
    pub fn loadInto(buffer: []u8, io: std.Io, dir: std.Io.Dir, path: []const u8) !Store;
};

pub const Entry = struct { key: []const u8, value: []const u8 };
pub const Iterator = struct { /* table slot cursor + generation */ };
```

Contracts:

* `get` copies into `buffer`; too small -> `error.BufferTooSmall`; empty value
  returns `&buffer[0..0]`; `null` means missing. `buffer` must not overlap
  `memory`.
* `getView` returns a borrowed slice into the image. It is valid until the next
  mutating call (`put`, `remove`) or `deinit`. No allocation. The slice must not
  be fed back into `put`/`get` without copying.
* `getAlloc` = `exists` + allocate + `get`; returns null without allocating when
  missing; caller owns the result.
* `exists` returns the value length; `?u64` distinguishes missing from a
  zero-length value.
* `put` requires key/value to not alias `memory` (no runtime check).
* Iterator yields `Entry` views in unspecified slot order; any mutation between
  `next()` calls invalidates it (Debug assert via `generation`, documented as
  undefined in release).
* `remove` returns whether the key was present.
* `initWithBuffer` requires `buffer.len >= imageSize(options)`, formats the
  prefix, leaves the tail untouched.
* `loadInto` requires `buffer.len >= file size`, uses the prefix.

## 5. Errors and limits

```
OutOfSpace, TableFull, KeyTooLarge, ValueTooLarge, BufferTooSmall,
UnsupportedEndianness, UnsupportedVersion, Corrupt, OutOfMemory
```

Integer types:

* `exists` / `count` / `capacity` / lengths: `u64`.
* Table slots: power of two, >= 16; `max_entries` rounded up.
* 32-bit arena max: 4 GiB - 8; 64-bit arena max: host address space.
* 64-bit hosts only.

## 6. Code layout

```
build.zig
build.zig.zon
src/zigkv.zig        public facade, Store, iterator
src/format.zig       constants, flags/bootstrap, header/entry/block accessors
src/hash.zig         CityHash wrapper + zero remap
src/table.zig        probe, lookup, insert, backward-shift delete
src/arena.zig        block alloc/free/split/coalesce
src/image.zig        imageSize, format, validate, arena tiling walk
src/io.zig           save/load helpers
src/main.zig         CLI
src/zigkv_test.zig   unit + property + corruption tests
examples/basic.zig
bench/bench.zig
testdata/            golden images, corrupt fixtures
```

Zig 0.17 specifics:

* `std.hash.CityHash32.hash([]const u8) u32`, `std.hash.CityHash64.hash` exist in
  std; cross-check against reference vectors.
* I/O takes `std.Io`: `dir.createFile(io, ...)`,
  `file.writeStreamingAll(io, bytes)`, `file.readPositionalAll(io, buf, 0)`.
  Tests use `std.testing.io`; binaries get `io` from `std.process.Init`.
* `std.mem.readInt`/`writeInt` with `.native`; the flags bootstrap reads bytes 8
  and 15 directly.
* `build.zig` uses `b.createModule`, `b.addTest`, `b.addExecutable`.

## 7. Milestones

**M1 — skeleton**: build files, module, CLI stub, `zig build test` green.

**M2 — format layer**: flags/bootstrap, header/entry/block accessors for the
width matrix, layout math, `imageSize`, magic/version, overflow rejection. Tests
across all 8 width combinations.

**M3 — arena**: alloc/free/split, address-ordered coalescing, sorted-invariant
property tests against a bitmap reference allocator, 32/64-bit block headers.

**M4 — table**: probe/lookup/insert/delete with injectable hashes, backward-shift
clusters, load-factor limit, `table_size` accounting, 32/64-bit entries.

**M5 — Store API**: init/initWithBuffer/deinit, put/get/getView/getAlloc/exists/
remove, overwrite grow/shrink, empty key/value, binary keys, failure atomicity,
duration contracts documented.

**M6 — iterator**: slot-order iteration, views, generation assert.

**M7 — persistence**: save/load/loadInto/saveAtomic, strict validation, free-list
sortedness/coalescing checks, arena tiling walk, golden + corrupt fixtures,
endianness rejection.

**M8 — CLI**: create/put/get/remove/exists/list/stat, binary-safe I/O.

**M9 — hardening**: random ops vs `std.StringHashMap` model, corruption fuzz,
exhaustion tests, alloc-failure tests, benchmarks vs std maps.

**M10 — polish**: README (drop "mem-mapped"), file-format doc, examples, doc
comments, `zig fmt`.

## 8. Test plan

| Area | Tests |
|------|-------|
| Layout | all 8 width combos, entry sizes 12/16/20/24, image size, overflow, min/max capacities |
| Header | flags round-trip, duplicated endianness bit, reserved bits, power-of-two slots |
| Arena | 32/64 headers, split boundaries, sorted list, coalesce prev/both/next, full arena, failed alloc leaves the list intact |
| Table | hits/misses, forced collisions, wrap-around, delete clusters, backward shift, load factor, full table |
| Store | empty key/value, 1 B..1 MiB, binary keys, overwrite grow/shrink/split, remove absent, duplicate put, getView lifetime |
| get/getAlloc | exact/short buffer, zero-length, missing key, alloc failure leaks |
| Iterator | all entries once, empty store, Debug generation assert |
| Persistence | save/load round-trip, width matrix, buffer vs allocator, identical bytes, truncated/extra byte, corrupt flags/offsets/free lists, arena gaps |
| Fuzz | ops vs reference map; random corruption never UB |
| Alloc failures | `checkAllAllocationFailures` |

Endianness: the suite runs on the host order. A crafted image with the two
bootstrap bits set to a foreign order must fail with
`error.UnsupportedEndianness`; a crafted image with mismatched copies must fail
with `error.Corrupt`. Real big-endian paths can only be exercised on a big-endian
host.

## 9. Benchmarks

* put/get/remove on 100k keys, uniform and zipf.
* Value sizes 8 B / 256 B / 4 KiB.
* 32-bit vs 64-bit index/hash combos.
* Cost of address-ordered `free` as free-block count grows (the O(n) risk).
* Against `std.StringHashMap([]u8)` / `std.ArrayHashMap`.

## 10. Risks and documented limitations

1. **O(n) `free`** from the address-ordered list. If benchmarks show it, switch to
   boundary tags (format v2) or size-class bins.
2. **Aliasing is unchecked** (Q13 = B). Passing a `getView` slice back into `put`
   or a buffer inside the image to `get` corrupts the store. This is documented
   in the API; it is the caller's responsibility.
3. **Native-endian files** are not portable across endianness; loading a foreign
   file returns `error.UnsupportedEndianness`.
4. **u64 arenas** require 64-bit hosts and 64-bit lengths throughout.
5. **Fixed capacity**: `TableFull` / `OutOfSpace` are normal outcomes.
6. **Validation is load-time only**: buffer scribbling after `initWithBuffer` is
   the caller's fault.
7. **Backward-shift deletion** is subtle; needs cluster-heavy tests.
8. **Future growth** cannot widen index widths in place; a 32-bit arena can never
   grow past 4 GiB without a rebuild into a wider image.

## 11. CLI

```
zigkv create <file> [--slots N] [--key-bytes N] [--value-bytes N]
                    [--hash 32|64] [--key-index 32|64] [--value-index 32|64]
zigkv put    <file> <key> [<value> | -]      # "-" reads value bytes from stdin
zigkv get    <file> <key>                    # raw value bytes to stdout
zigkv remove <file> <key>
zigkv exists <file> <key>                    # prints length, exit 0/1
zigkv list   <file> [--null]                 # key<TAB>value, or NUL-separated
zigkv stat   <file>
```

Binary keys: `--key-hex <hex>` or `--key-file <path>` in place of the positional
key. Every mutating command loads, mutates, and saves the whole image. `stat`
prints version, widths, byte order, slots, live keys, max live keys, and arena
capacities.

## 12. Decision log (final)

| # | Decision |
|---|----------|
| 1 | Library + example + bench + CLI, no CI |
| 2 | `Store`, `put/get/getView/getAlloc/exists/remove/save/saveAtomic/load` |
| 3 | Zig 0.17.0 pinned, MIT |
| 4 | Overwrite: reuse key block; value in place if it fits, split tail |
| 5 | Fixed capacity in v1; errors on full; growth later |
| 6 | Both `get` (copy) and `getView` (borrowed) |
| 7 | `error.BufferTooSmall`, no truncation |
| 8 | `exists -> ?u64`, `remove -> bool`, `put -> !void` |
| 9 | Empty keys and values allowed; empty value distinct from missing |
| 10 | `getAlloc` returns caller-owned `!?[]u8`; no allocation when missing |
| 11 | Single-threaded, documented |
| 12 | `count`, `capacity`, `verify`, iterator |
| 13 | No alias detection (B); non-aliasing is a documented contract |
| 14 | No mmap support |
| 15 | Header exactly 64 B |
| 16 | Per-section index widths (32/64) and hash width (32/64), flagged |
| 17 | Hash width explicit at create, default city64 |
| 18 | Full hash stored |
| 19 | Native endianness, flagged twice (bit 3 and bit 59); foreign order errors |
| 20 | Unaligned access, no buffer alignment requirement |
| 21 | Uniform block header, width follows arena width (8/16 B) |
| 22 | `NONE` = all-ones, offset 0 valid, zero-length values get a block |
| 23 | `max_entries` = slots, pow2, >= 16; defaults 1024 / 64 KiB / 1 MiB |
| 24 | Header -> table -> keys -> values, align8 only, exact size |
| 25 | Magic `zigkv001` carries the version |
| 26 | Linear probing |
| 27 | Backward-shift deletion, no tombstones |
| 28 | Load factor 0.75 |
| 29 | Table fixed at create |
| 30 | Hash 0 remapped to 1 |
| 31 | Free list: address-ordered, first-fit, split |
| 32 | Coalescing on every free; no fragmentation |
| 33 | No `defragment()`; `verify()` checks sortedness/coalescing |
| 34 | No compaction |
| 35 | `put` is failure-atomic |
| 36 | `save`/`saveAtomic` path helpers, no fsync |
| 37 | `load`/`loadInto` constructors only |
| 38 | Strict file length; header wins |
| 39 | Structural validation on every load; deep `verify()` separate |
| 40 | `initWithBuffer` accepts >= `imageSize`, uses the prefix; `save` writes `imageSize` |
