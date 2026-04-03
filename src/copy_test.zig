const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const copy = @import("copy.zig");
const ProgramOptions = @import("args.zig").ProgramOptions;

fn writeFile(dir: Io.Dir, io: Io, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);

    var buffer: [128]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn pathInTmp(tmp_dir: Io.Dir, io: Io, alloc: std.mem.Allocator, rel: []const u8) ![:0]u8 {
    const tmp_abs = try tmp_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_abs);
    const joined = try Io.Dir.path.resolve(alloc, &.{ tmp_abs, rel });
    defer alloc.free(joined);
    return try alloc.dupeZ(u8, joined);
}

test "copy file to new file" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "hello cp-zig");

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dest.txt");
    defer alloc.free(dest);

    try copy.copySerially(io, alloc, &ProgramOptions.init(source, dest, .{}));

    const out = try tmp.dir.readFileAlloc(io, "dest.txt", alloc, .limited(1024));
    defer alloc.free(out);
    try testing.expectEqualStrings("hello cp-zig", out);
}

test "copy file refuses overwrite without force" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "new content");
    try writeFile(tmp.dir, io, "dest.txt", "old content");

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dest.txt");
    defer alloc.free(dest);

    try testing.expectError(error.FileNoForce, copy.copySerially(io, alloc, &ProgramOptions.init(source, dest, .{})));

    const out = try tmp.dir.readFileAlloc(io, "dest.txt", alloc, .limited(1024));
    defer alloc.free(out);
    try testing.expectEqualStrings("old content", out);
}

test "copy file overwrites with force" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "new content");
    try writeFile(tmp.dir, io, "dest.txt", "old content");

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dest.txt");
    defer alloc.free(dest);

    try copy.copySerially(io, alloc, &ProgramOptions.init(source, dest, .{ .force = true }));

    const out = try tmp.dir.readFileAlloc(io, "dest.txt", alloc, .limited(1024));
    defer alloc.free(out);
    try testing.expectEqualStrings("new content", out);
}

test "copy file into existing directory" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "inside dir");
    try tmp.dir.createDir(io, "out", .default_dir);

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const dest_dir = try pathInTmp(tmp.dir, io, alloc, "out");
    defer alloc.free(dest_dir);

    try copy.copySerially(io, alloc, &ProgramOptions.init(source, dest_dir, .{}));

    const out = try tmp.dir.readFileAlloc(io, "out/source.txt", alloc, .limited(1024));
    defer alloc.free(out);
    try testing.expectEqualStrings("inside dir", out);
}

test "copy file to dot skips same location" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "same-place");

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const dest_dot = try pathInTmp(tmp.dir, io, alloc, ".");
    defer alloc.free(dest_dot);

    try copy.copySerially(io, alloc, &ProgramOptions.init(source, dest_dot, .{}));

    const out = try tmp.dir.readFileAlloc(io, "source.txt", alloc, .limited(1024));
    defer alloc.free(out);
    try testing.expectEqualStrings("same-place", out);
}

test "copy file to non-existing directory path errors" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "source.txt", "content");

    const source = try pathInTmp(tmp.dir, io, alloc, "source.txt");
    defer alloc.free(source);
    const missing_base = try pathInTmp(tmp.dir, io, alloc, "missing");
    defer alloc.free(missing_base);
    const missing_dir = try std.mem.concatWithSentinel(alloc, u8, &.{ missing_base, "/" }, 0);
    defer alloc.free(missing_dir);

    try testing.expectError(error.ResolveInvalidFileToDir, copy.copySerially(io, alloc, &ProgramOptions.init(source, missing_dir, .{})));
}

test "copy non-existing source errors" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_source = try pathInTmp(tmp.dir, io, alloc, "not-found.txt");
    defer alloc.free(missing_source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dest.txt");
    defer alloc.free(dest);

    try testing.expectError(error.SourceLocationInvalid, copy.copySerially(io, alloc, &ProgramOptions.init(missing_source, dest, .{})));
}
