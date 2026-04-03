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

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{}));

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

    try testing.expectError(error.FileNoForce, copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{})));

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

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .force = true }));

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

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest_dir, .{}));

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

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest_dot, .{}));

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

    try testing.expectError(error.ResolveInvalidFileToDir, copy.copy(io, alloc, &ProgramOptions.init(source, missing_dir, .{})));
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

    try testing.expectError(error.SourceLocationInvalid, copy.copy(io, alloc, &ProgramOptions.init(missing_source, dest, .{})));
}

// -- Directory copy tests --

fn readFile(dir: Io.Dir, io: Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try dir.readFileAlloc(io, path, alloc, .limited(4096));
}

test "copy dir to new dest" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try writeFile(tmp.dir, io, "src/a.txt", "aaa");
    try writeFile(tmp.dir, io, "src/b.txt", "bbb");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    const a = try readFile(tmp.dir, io, alloc, "dst/a.txt");
    defer alloc.free(a);
    try testing.expectEqualStrings("aaa", a);

    const b = try readFile(tmp.dir, io, alloc, "dst/b.txt");
    defer alloc.free(b);
    try testing.expectEqualStrings("bbb", b);
}

test "copy dir with nested subdirs" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/sub", .default_dir);
    try tmp.dir.createDir(io, "src/sub/deep", .default_dir);
    try writeFile(tmp.dir, io, "src/top.txt", "top");
    try writeFile(tmp.dir, io, "src/sub/mid.txt", "mid");
    try writeFile(tmp.dir, io, "src/sub/deep/bot.txt", "bot");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    const top = try readFile(tmp.dir, io, alloc, "dst/top.txt");
    defer alloc.free(top);
    try testing.expectEqualStrings("top", top);

    const mid = try readFile(tmp.dir, io, alloc, "dst/sub/mid.txt");
    defer alloc.free(mid);
    try testing.expectEqualStrings("mid", mid);

    const bot = try readFile(tmp.dir, io, alloc, "dst/sub/deep/bot.txt");
    defer alloc.free(bot);
    try testing.expectEqualStrings("bot", bot);
}

test "copy dir into existing dest merges" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try writeFile(tmp.dir, io, "src/new.txt", "new");

    try tmp.dir.createDir(io, "dst", .default_dir);
    try writeFile(tmp.dir, io, "dst/existing.txt", "existing");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    // new file was copied in
    const new = try readFile(tmp.dir, io, alloc, "dst/new.txt");
    defer alloc.free(new);
    try testing.expectEqualStrings("new", new);

    // existing file is untouched
    const existing = try readFile(tmp.dir, io, alloc, "dst/existing.txt");
    defer alloc.free(existing);
    try testing.expectEqualStrings("existing", existing);
}

test "copy dir skips existing files without force" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try writeFile(tmp.dir, io, "src/conflict.txt", "new version");

    try tmp.dir.createDir(io, "dst", .default_dir);
    try writeFile(tmp.dir, io, "dst/conflict.txt", "old version");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    // old content preserved -- skipped without -f
    const out = try readFile(tmp.dir, io, alloc, "dst/conflict.txt");
    defer alloc.free(out);
    try testing.expectEqualStrings("old version", out);
}

test "copy dir overwrites existing files with force" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try writeFile(tmp.dir, io, "src/conflict.txt", "new version");

    try tmp.dir.createDir(io, "dst", .default_dir);
    try writeFile(tmp.dir, io, "dst/conflict.txt", "old version");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true, .force = true }));

    const out = try readFile(tmp.dir, io, alloc, "dst/conflict.txt");
    defer alloc.free(out);
    try testing.expectEqualStrings("new version", out);
}

test "copy dir to same location skips" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "src", .default_dir);
    try writeFile(tmp.dir, io, "src/a.txt", "unchanged");

    const source = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "src");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    // file should still be there, untouched
    const out = try readFile(tmp.dir, io, alloc, "src/a.txt");
    defer alloc.free(out);
    try testing.expectEqualStrings("unchanged", out);
}

test "copy empty dir" {
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "empty", .default_dir);

    const source = try pathInTmp(tmp.dir, io, alloc, "empty");
    defer alloc.free(source);
    const dest = try pathInTmp(tmp.dir, io, alloc, "dst");
    defer alloc.free(dest);

    try copy.copy(io, alloc, &ProgramOptions.init(source, dest, .{ .recurse = true }));

    // dest dir should exist and be empty
    const dst_dir = try tmp.dir.openDir(io, "dst", .{ .iterate = true });
    defer dst_dir.close(io);
    var it = dst_dir.iterate();
    try testing.expect(try it.next(io) == null);
}
