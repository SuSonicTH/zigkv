# Performance

Host: AMD Ryzen 7 7735HS (8C/16T, 16 MiB L3), Zig 0.17.0, ReleaseFast.

```sh
zig build bench -Doptimize=ReleaseFast -- 100000
```

The argument overrides the default key count (100,000). Each implementation is
built and measured five times from scratch, and the fastest sample of each
metric is reported. Results are ns per operation.

```
zigkv benchmarks: 100000 keys, 8-byte keys, best of 5 rounds, image 10 MiB

| Implementation       | Value |    Put ns/op |    Get ns/op | Hot 1% ns/op |   Miss ns/op | Remove ns/op |
|:---------------------|------:|-------------:|-------------:|-------------:|-------------:|-------------:|
| store city64/u32/u32 |     8 |         19.1 |         11.6 |          5.7 |         14.8 |         23.7 |
| store city32/u32/u32 |     8 |         20.2 |         13.8 |          7.3 |         17.2 |         25.9 |
| store city64/u64/u64 |     8 |         21.7 |         11.6 |          5.4 |         15.7 |         23.8 |
| store city32/u64/u64 |     8 |         20.6 |         13.7 |          7.3 |         17.9 |         26.3 |
| std.StringHashMap    |     8 |         21.3 |         14.6 |          4.7 |         19.7 |         13.0 |
| std.ArrayHashMap     |     8 |         16.8 |         17.0 |          8.8 |         16.9 |         17.8 |
| store city64/u32/u32 |   256 |         79.1 |         33.4 |          6.0 |         17.2 |         23.5 |
| std.StringHashMap    |   256 |         20.0 |         14.4 |          4.8 |         19.6 |         13.2 |
| std.ArrayHashMap     |   256 |         17.0 |         17.0 |          8.7 |         16.9 |         17.8 |
| store city64/u32/u32 |  4096 |        502.1 |         49.1 |          5.9 |         17.5 |         23.6 |
| std.StringHashMap    |  4096 |         16.4 |         14.5 |          4.6 |         19.5 |         12.9 |
| std.ArrayHashMap     |  4096 |         15.3 |         17.0 |          8.6 |         16.8 |         17.7 |
```

## Why larger values are slower

`put` copies the key and value into the image, so its cost grows with the value
size: about 19 ns at 8 bytes, 76 ns at 256 bytes and 493 ns at 4096 bytes. The
copy dominates; the table and probe work stay the same.

`getView` does not copy the value, but a lookup still has to find the entry and
then touch the value block. Larger values occupy more memory and have worse
cache locality, so the value access increasingly becomes a cache miss: `get`
rises from 11 ns at 8 bytes to 34 ns at 256 bytes and 49 ns at 4096 bytes. The
hot 1% column stays near 6 ns regardless of value size because those values fit
in cache and stay there.

The std map rows store a pointer to the caller's value instead of copying it, so
their `Put` numbers are not directly comparable for the 256- and 4096-byte rows.

## Load and validation

`load` reads the image and then validates the header, both arenas and every live
table entry. On the host above, a 93 MiB image with 1,000,000 entries (8-byte
keys and values) loads in about 44 ms; a raw read of the same file takes about
18 ms. `verify()`, which repeats the structural validation and additionally
re-hashes every key, takes about 59 ms. Validation fixes the image's width
combination once and then runs fully specialized code, so the per-entry checks
do not re-dispatch on the field widths. (These numbers come from a small
load/validation harness, not from `zig build bench`.)

## Removal order and free-list cost

The arenas keep one free list sorted by block offset. `free` walks that list to
the insertion point, so the cost depends on how many free blocks precede the
block being freed. Removing all 100,000 entries from a full store (8-byte keys
and values, measured with a small fill/remove harness):

| Removal order       | Time per remove |
|:--------------------|----------------:|
| ascending key order |           ~25 ns |
| random order        |           ~30 us |

In the random case the free list grows to roughly 50,000 nodes and every free
walks about half of it, so a full teardown is O(n²). Coalescing keeps the list
short when removals are clustered: adjacent freed blocks merge into a single
node. Allocation is first-fit and can hit the same scan cost when the free list
is long. A boundary-tag or size-class free list (a format change) is the
structural fix.

