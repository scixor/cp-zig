const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

const Allocator = std.mem.Allocator;

pub const PathType = enum {
    file,
    dir,
    link,
};

pub const PathStat = struct {
    stat: ?Dir.Stat,
    path_type: PathType,
};

pub const PathStatError = error{StatKindNotSupported} || Dir.StatFileError;

pub const CopyTargetInfo = struct {
    source: []const u8,
    source_stat: PathStat,
    dest: []const u8,
    dest_owned: bool,
    dest_stat: PathStat,

    pub fn deinit(self: CopyTargetInfo, alloc: Allocator) void {
        if (self.dest_owned) alloc.free(self.dest);
    }
};

const ResolveError = error{
    SourceLocationInvalid,
    DestLocationInvalid,
    ResolveInvalidFileToDir,
    ResolveInvalidDirToFile,
    ResolveSamePath,
};

pub const ResolveTargetError = ResolveError || PathStatError || Allocator.Error || Dir.RealPathFileAllocError;

pub fn joinChildPathZ(
    alloc: Allocator,
    parent: []const u8,
    child: []const u8,
) Allocator.Error![:0]u8 {
    if (parent.len == 0) {
        return try alloc.dupeZ(u8, child);
    }
    const size = parent.len + 1 + child.len;
    const out = try alloc.alloc(u8, size + 1);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = Dir.path.sep;
    @memcpy(out[parent.len + 1 .. parent.len + 1 + child.len], child);
    out[size] = 0;
    return out[0..size :0];
}

fn pathStat(dir: Dir, io: Io, path: []const u8) PathStatError!PathStat {
    const stat: ?Dir.Stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (stat == null) {
        const path_type = if (path.len > 1 and path[path.len - 1] == Dir.path.sep)
            PathType.dir
        else
            PathType.file;
        return .{ .path_type = path_type, .stat = null };
    }

    const path_type: PathType = switch (stat.?.kind) {
        .file => .file,
        .directory => .dir,
        .sym_link => .link,
        else => return error.StatKindNotSupported,
    };

    return .{ .stat = stat, .path_type = path_type };
}

pub fn resolveCopyTarget(
    io: Io,
    alloc: Allocator,
    source: []const u8,
    dest: []const u8,
) ResolveTargetError!CopyTargetInfo {
    const cwd = Dir.cwd();

    const source_stat = pathStat(cwd, io, source) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Source file kind not supported: '{s}'", .{source});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    if (source_stat.stat == null) return error.SourceLocationInvalid;
    if (source_stat.path_type == .link) {
        std.log.err("cp: links are not supported yet", .{});
        return error.SourceLocationInvalid;
    }

    const dest_stat = pathStat(cwd, io, dest) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Dest file kind not supported: '{s}'", .{dest});
            return error.DestLocationInvalid;
        },
        else => return err,
    };

    // resolve normalized paths for same-path detection
    const norm_source = try cwd.realPathFileAlloc(io, source, alloc);
    defer alloc.free(norm_source);

    // source is a file
    if (source_stat.path_type == .file) {
        if (dest_stat.path_type == .file) {
            // ef -> ef or ef -> nf
            if (dest_stat.stat != null) {
                const norm_dest = try cwd.realPathFileAlloc(io, dest, alloc);
                defer alloc.free(norm_dest);
                if (std.mem.eql(u8, norm_source, norm_dest)) {
                    return error.ResolveSamePath;
                }
            }
            return .{
                .source = source,
                .source_stat = source_stat,
                .dest = dest,
                .dest_owned = false,
                .dest_stat = dest_stat,
            };
        }

        // ef -> non-existing dir
        if (dest_stat.stat == null and dest_stat.path_type == .dir) {
            return error.ResolveInvalidFileToDir;
        }

        // ef -> existing dir: append filename
        const filename = Dir.path.basename(source);
        const final_dest = try Dir.path.resolve(alloc, &.{ dest, filename });
        const resolved_stat = pathStat(cwd, io, final_dest) catch |err| switch (err) {
            error.StatKindNotSupported => {
                alloc.free(final_dest);
                return error.SourceLocationInvalid;
            },
            else => {
                alloc.free(final_dest);
                return err;
            },
        };

        if (resolved_stat.stat != null) {
            const norm_dest = cwd.realPathFileAlloc(io, final_dest, alloc) catch |err| {
                alloc.free(final_dest);
                return err;
            };
            defer alloc.free(norm_dest);
            if (std.mem.eql(u8, norm_source, norm_dest)) {
                alloc.free(final_dest);
                return error.ResolveSamePath;
            }
        }

        return .{
            .source = source,
            .source_stat = source_stat,
            .dest = final_dest,
            .dest_owned = true,
            .dest_stat = resolved_stat,
        };
    }

    // source is a dir
    if (dest_stat.stat != null and dest_stat.path_type == .file) {
        return error.ResolveInvalidDirToFile;
    }

    if (dest_stat.stat != null) {
        const norm_dest = try cwd.realPathFileAlloc(io, dest, alloc);
        defer alloc.free(norm_dest);
        if (std.mem.eql(u8, norm_source, norm_dest)) {
            return error.ResolveSamePath;
        }
    }

    return .{
        .source = source,
        .source_stat = source_stat,
        .dest = dest,
        .dest_owned = false,
        .dest_stat = .{ .stat = dest_stat.stat, .path_type = .dir },
    };
}
