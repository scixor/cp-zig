const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const Allocator = std.mem.Allocator;

const BUFFER_SIZE = 1024;

pub const ParsedPath = struct {
    abs_path: []const u8,

    pub fn deinit(self: ParsedPath, alloc: Allocator) void {
        alloc.free(self.abs_path);
    }
};

pub const RealPathAloocError = Dir.RealPathFileAllocError;
pub const ParsedPathError = RealPathAloocError;

const PathType = enum {
    file,
    dir,
    link,

    pub fn str(self: PathType) []const u8 {
        return @tagName(self);
    }
};

pub const PathStat = struct {
    stat: ?Dir.Stat,
    path_type: PathType,
};

pub const PathStatError = error{StatKindNotSupported} || Dir.StatFileError;

pub fn pathToAbsolute(io: Io, allocator: Allocator, dir: Dir, rel: []const u8) RealPathAloocError![]u8 {
    const dir_path = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    return try Dir.path.resolve(allocator, &.{ dir_path, rel });
}

pub fn parsePathAbsolute(io: Io, alloc: Allocator, cwd: Dir, path: []const u8) ParsedPathError!ParsedPath {
    const is_abs = Dir.path.isAbsolute(path);

    const final_path: []const u8 = if (is_abs) blk: {
        break :blk path;
    } else blk: {
        break :blk try pathToAbsolute(io, alloc, cwd, path);
    };

    return ParsedPath{ .abs_path = final_path };
}

pub fn pathStat(io: Io, path: *const ParsedPath) PathStatError!PathStat {
    std.debug.assert(Dir.path.isAbsolute(path.abs_path));
    // I am not sure why zig dones't have a full on absoulte version
    // but I gues this will work
    const stat: ?Dir.Stat = Dir.statFile(.{ .handle = 0 }, io, path.abs_path, .{}) catch |err| blk: switch (err) {
        error.FileNotFound => break :blk null,
        else => return err,
    };

    // doesn't exist just check if folder or not
    if (stat == null) {
        // std.debug.print("File doesn't exist {s}\n", .{path.abs_path});
        // very bad check I know
        const path_type = if (std.mem.endsWith(u8, path.abs_path, "/")) PathType.dir else PathType.file;
        return PathStat{ .path_type = path_type, .stat = null };
    }

    std.debug.assert(stat != null);
    // std.debug.print("File exists {s}\n", .{path.abs_path});

    // file exists
    const path_type = switch (stat.?.kind) {
        .file => PathType.file,
        .directory => PathType.dir,
        .sym_link => PathType.link,
        else => return PathStatError.StatKindNotSupported,
    };

    // std.debug.print("Type {s}\n", .{path_type.str()});

    return PathStat{ .stat = stat, .path_type = path_type };
}
