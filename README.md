# zigkv

A fast, single-file, memory-resident key/value store for **Zig 0.17.0**, with
variable-length binary keys and values.

> **Status:** design finalized — see [PLAN.md](PLAN.md). Implementation not
> started yet.

## What it is

`zigkv` keeps the whole store in one contiguous memory image, and that image
*is* the file format: saving is one write, loading is one read. There is no
serialization pass and no re-parsing. No pointers are ever stored — every
cross-section reference is an offset relative to a section base — so the image
can be moved, reallocated, or handed to the store as a caller-owned buffer.

## Features

- **Two backends:** allocate the image, or format a store into a `[]u8` you own.
- **Binary-safe:** keys and values are arbitrary byte slices; empty keys and
  zero-length values are valid and distinct from "missing".
- **API:** `put`, `get`, `getView`, `getAlloc`, `remove`, `exists`, plus an
  iterator and `count` / `capacity` / `verify`.
- **Hashing:** CityHash32 or CityHash64 (from `std.hash`), chosen at creation.
- **Table:** open addressing with linear probing, backward-shift deletion (no
  tombstones), 0.75 load factor.
- **Storage:** separate key and value arenas with sorted, fully coalescing free
  lists; first-fit allocation with splitting, so free space never fragments.
- **Per-section widths:** hash and each arena's offsets are independently 32- or
  64-bit, fixed at creation and recorded in the header.
- **Corruption-safe loading:** header, free lists and the arena tiling are
  validated before the store is handed back; malformed images return errors,
  never out-of-bounds reads.
- **CLI:** `create`, `put`, `get`, `remove`, `exists`, `list`, `stat`.

## Planned API

```zig
const std = @import("std");
const zigkv = @import("zigkv");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var store = try zigkv.Store.init(gpa, .{
        .max_entries = 1024,       // table slots (rounded up to a power of two)
        .key_bytes = 64 * 1024,    // key arena capacity
        .value_bytes = 1024 * 1024 // value arena capacity
    });
    defer store.deinit();

    try store.put("hello", "world");

    var buffer: [256]u8 = undefined;
    if (try store.get("hello", &buffer)) |value| {
        std.debug.print("{s}\n", .{value}); // "world"
    }

    if (store.exists("hello")) |len| {
        std.debug.print("value is {d} bytes\n", .{len});
    }

    try store.save(init.io, std.Io.Dir.cwd(), "data.zkv");
}
```

Other entry points:

```zig
// gpa and init from the example above.
// Caller-owned image. The buffer may be larger than needed; only the prefix is
// used, and save writes exactly imageSize bytes.
const needed: usize = @intCast(try zigkv.Store.imageSize(.{}));
var buffer = try gpa.alloc(u8, needed);
defer gpa.free(buffer);
var store = try zigkv.Store.initWithBuffer(buffer, .{});
defer store.deinit(); // does not free caller memory

// Load into a fresh allocation, or into a buffer at least as large as the file.
var loaded = try zigkv.Store.load(gpa, init.io, std.Io.Dir.cwd(), "data.zkv");
defer loaded.deinit();
var into = try zigkv.Store.loadInto(buffer, init.io, std.Io.Dir.cwd(), "data.zkv");
defer into.deinit();
```

`get` copies into the provided buffer (`error.BufferTooSmall` if it does not
fit). `getView` returns a borrowed slice into the image, valid until the next
`put`/`remove`/`deinit`. `getAlloc` returns a caller-owned allocation.

**Aliasing is not checked.** Inputs to `put` and the buffer passed to `get` must
not point into the store's own memory. In particular, copy a `getView` result
before passing it back to `put`.

## CLI

```sh
zigkv create data.zkv --slots 1024 --key-bytes 65536 --value-bytes 1048576
zigkv put    data.zkv hello world
zigkv get    data.zkv hello
zigkv exists data.zkv hello
zigkv remove data.zkv hello
zigkv list   data.zkv
zigkv stat   data.zkv
```

Values can be read from stdin with `-`; binary keys use `--key-hex` or
`--key-file`. Mutating commands load, mutate, and save the whole image.

## File format

```
┌────────────┬──────────────────────┬──────────────┬──────────────┐
│ header     │ table                │ key arena    │ value arena  │
│ 64 bytes   │ slots × entry size   │ key_bytes    │ value_bytes  │
└────────────┴──────────────────────┴──────────────┴──────────────┘
```

- Header: `zigkv001` magic, flags (hash/index widths and byte order), slot count,
  live count, arena capacities, free-list heads.
- Table entry: full hash + key offset + value offset, with each field 32 or 64
  bits as configured.
- Key/value block: `size` + `len` (or `next` when free), 8- or 16-byte header
  depending on the arena width, payload 8-byte aligned.
- Integers use the creating host's byte order, declared in the header; loading a
  foreign-endian image is an error rather than a silent misread.

See [PLAN.md](PLAN.md) for the byte-level specification and algorithms.

## Non-goals (v1)

- Concurrency or multi-process locking; stores are single-threaded.
- Crash consistency, journaling, or fsync-on-save.
- Growing an existing store (`TableFull` / `OutOfSpace` are terminal).
- Compaction, range queries, TTL, iteration order guarantees.
- Cross-endian images.

## Building

Not buildable yet — the build files land in M1. The intended commands are:

```sh
zig build          # library + CLI
zig build test     # unit, property, corruption and alloc-failure tests
```

Requires Zig 0.17.0 and a 64-bit host.

## License

MIT
