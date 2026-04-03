const std = @import("std");
const cutil = @import("util.zig");

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

pub const CopyTargetInfo = struct {
    source_path: ParsedPath,
    source_stat: PathStat,
    dest_path: ParsedPath,
    dest_stat: PathStat,

    pub fn deinit(self: CopyTargetInfo, alloc: Allocator) void {
        self.source_path.deinit(alloc);
        self.dest_path.deinit(alloc);
    }
};

const ResolveTargetInternalError = error{ ResolveInvalidFileToDir, ResolveInvalidDirToFile, ResolveSameDir };

pub const ResolveTargetErrorType = ResolveTargetInternalError || PathStatError || std.mem.Allocator.Error;

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
    const stat: ?Dir.Stat = Dir.statFile(undefined, io, path.abs_path, .{}) catch |err| blk: switch (err) {
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

// Resolves the paths for file and dir copy paths so it can be a simply copy
pub fn resolveTargetPaths(
    io: Io,
    alloc: Allocator,
    s_path: ParsedPath,
    s_stat: *const PathStat,
    d_path: ParsedPath,
    d_stat: *const PathStat,
) ResolveTargetErrorType!CopyTargetInfo {
    cutil.assertS(s_path.abs_path.len > 0, "Source path must be non empty", .{});
    cutil.assertS(s_stat.stat != null, "source must exist", .{});
    cutil.assertS(s_stat.path_type != .link, "Links are not supported yet why tf this reached here? {s}", .{s_path.abs_path});
    cutil.assertS(.path_type != .dir, "Links are not supported yet why tf this reached here? {s}", .{s_path.abs_path});

    const dest_exists = d_stat.stat != null;
    const dest_is_file = d_stat.path_type == .file;

    // if the source is a file the target must be resolved to a file
    // e = existing, n = non existing, f = file, d = dir, S = source, D = dest,
    // case: eSf -> eDf = eDf
    // case: eSf -> nDf = nDf
    // case: eSf -> nDd = error (file cannot be to non existing dir we don't make it)
    // case: eSf -> eDd = eDd + filebase
    if (s_stat.path_type == .file) {
        if (dest_is_file) return CopyTargetInfo{
            .source_path = s_path,
            .source_stat = s_stat.*,
            .dest_path = d_path,
            .dest_stat = d_stat.*,
        };

        if (!dest_exists and d_stat.path_type == .dir) {
            return error.ResolveInvalidFileToDir;
        }

        cutil.assertS(
            dest_exists and d_stat.path_type == .dir,
            "Expected destination to be valid directory: ef->edir {s}",
            .{d_path.abs_path},
        );

        // that means the path is existing directory
        const filename = Dir.path.basename(s_path.abs_path);
        const final_dest = try Dir.path.resolve(alloc, &.{ d_path.abs_path, filename });
        const parsed_path = ParsedPath{ .abs_path = final_dest };
        const resolved_stat = try pathStat(io, &parsed_path);

        return CopyTargetInfo{
            .source_path = s_path,
            .source_stat = s_stat.*,
            .dest_path = parsed_path,
            .dest_stat = resolved_stat,
        };
    }

    cutil.assertS(s_stat.path_type == .dir, "Source expected to be directory", .{});

    // directory cannot be copied to a file
    if (dest_exists and dest_is_file) return error.ResolveInvalidDirToFile;

    // this means the dest is a directory if same just return it
    if (dest_exists and std.mem.eql(u8, s_path.abs_path, d_path.abs_path)) return ResolveTargetInternalError.ResolveSameDir;

    // if exists or doesn't exist we write to that directory so just return it
    return CopyTargetInfo{
        .source_path = s_path,
        .source_stat = s_stat.*,
        .dest_path = d_path,
        .dest_stat = d_stat.*,
    };
}
