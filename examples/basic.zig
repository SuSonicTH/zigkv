//! Basic zigkv example: create a store, use the API, iterate, and round-trip
//! the image through a file.

const std = @import("std");
const zigkv = @import("zigkv");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var store = try zigkv.Store.init(init.gpa, .{
        .max_entries = 64,
        .key_bytes = 1024,
        .value_bytes = 4096,
    });
    defer store.deinit();

    try store.put("hello", "world");
    try store.put("binary", &[_]u8{ 0x00, 0xFF, 0x10 });
    try store.put("", "empty key");

    var buffer: [64]u8 = undefined;
    const value = (try store.get("hello", &buffer)).?;

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &file_writer.interface;
    try out.print("hello = {s}\n", .{value});
    try out.print("live keys = {d} / {d}\n", .{ store.count(), store.capacity() });

    var iterator = store.iterator();
    while (iterator.next()) |entry| {
        try out.print("  {s} ({d} bytes)\n", .{ entry.key, entry.value.len });
    }

    const path = "zigkv-example.zkv";
    const dir = std.Io.Dir.cwd();
    try store.saveAtomic(io, dir, path);

    var loaded = try zigkv.Store.load(init.gpa, io, dir, path);
    defer loaded.deinit();
    try out.print("loaded keys = {d}\n", .{loaded.count()});
    try loaded.verify();
    try out.flush();

    try std.Io.Dir.cwd().deleteFile(io, path);
}
