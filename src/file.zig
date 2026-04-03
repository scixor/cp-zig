const std = @import("std");
const cutil = @import("util.zig");

const Io = std.Io;
const Dir = Io.Dir;

const Allocator = std.mem.Allocator;

const BUFFER_SIZE = 1024;

pub const ParsedPath = struct {
    abs_path: []const u8,

    pub fn dupe(self: ParsedPath, alloc: Allocator) Allocator.Error!ParsedPath {
        return .{ .abs_path = try alloc.dupe(u8, self.abs_path) };
    }

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

pub fn parsePathAbsolute(io: Io, alloc: Allocator, dir: Dir, path: []const u8) ParsedPathError!ParsedPath {
    const is_abs = Dir.path.isAbsolute(path);
    var resolved: []u8 = if (is_abs) blk: {
        break :blk try alloc.dupe(u8, path);
    } else blk: {
        break :blk try pathToAbsolute(io, alloc, dir, path);
    };
    // HACK: because resolve removes the trailing/
    // TOOD: when we have our own string interning fix this
    // Dir.path.resolve strips trailing separators; restore if the input had one
    const had_trailing_sep = path.len > 1 and path[path.len - 1] == Dir.path.sep;
    if (had_trailing_sep and !std.mem.endsWith(u8, resolved, "/")) {
        const with_sep = try alloc.alloc(u8, resolved.len + 1);
        @memcpy(with_sep[0..resolved.len], resolved);
        with_sep[resolved.len] = '/';
        alloc.free(resolved);
        resolved = with_sep;
    }

    return ParsedPath{ .abs_path = resolved };
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

/// Resolves the paths for file and dir copy paths so it can be a simply copy between file to file or dir to dir
pub fn resolveTargetPaths(
    io: Io,
    alloc: Allocator,
    s_path: *const ParsedPath,
    s_stat: *const PathStat,
    d_path: *const ParsedPath,
    d_stat: *const PathStat,
) ResolveTargetErrorType!CopyTargetInfo {
    cutil.assertS(s_path.abs_path.len > 0, "Source path must be non empty", .{});
    cutil.assertS(s_stat.stat != null, "source must exist", .{});
    cutil.assertS(s_stat.path_type != .link, "Links are not supported yet why tf this reached here? {s}", .{s_path.abs_path});
    cutil.assertS(d_stat.path_type != .link, "Links are not supported yet why tf this reached here? {s}", .{d_path.abs_path});

    const dest_exists = d_stat.stat != null;
    const dest_is_file = d_stat.path_type == .file;

    // if the source is a file the target must be resolved to a file
    // e = existing, n = non existing, f = file, d = dir, S = source, D = dest,
    // case: eSf -> eDf = eDf
    // case: eSf -> nDf = nDf
    // case: eSf -> nDd = error (file cannot be to non existing dir we don't make it)
    // case: eSf -> eDd = eDd + filebase
    if (s_stat.path_type == .file) {
        if (dest_is_file) {
            // HACK: I know we are making copies here in case we have resolve a lot this would be insane to deal with for
            // perfs most likely we have to do view based paths with string interning
            const s_copy = try s_path.dupe(alloc);
            errdefer s_copy.deinit(alloc);
            const d_copy = try d_path.dupe(alloc);
            errdefer d_copy.deinit(alloc); // may be a no-op

            return CopyTargetInfo{
                .source_path = s_copy,
                .source_stat = s_stat.*,
                .dest_path = d_copy,
                .dest_stat = d_stat.*,
            };
        }

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
        errdefer alloc.free(final_dest);
        const s_copy = try s_path.dupe(alloc);
        const parsed_path = ParsedPath{ .abs_path = final_dest };
        errdefer parsed_path.deinit(alloc);
        const resolved_stat = try pathStat(io, &parsed_path);

        return CopyTargetInfo{
            .source_path = s_copy,
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

    // source is a dir so dest must be a dir too (even if pathStat guessed file due to no trailing /)
    const s_copy = try s_path.dupe(alloc);
    errdefer s_copy.deinit(alloc);
    const d_copy = try d_path.dupe(alloc);
    return CopyTargetInfo{
        .source_path = s_copy,
        .source_stat = s_stat.*,
        .dest_path = d_copy,
        .dest_stat = .{ .stat = d_stat.stat, .path_type = .dir },
    };
}
