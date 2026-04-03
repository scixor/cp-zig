const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const cfile = @import("file.zig");
const cutil = @import("util.zig");
const ProgramOptions = @import("args.zig").ProgramOptions;

const CopyInvalidError = error{
    DestinationDirInvalid,
    FileNoForce,
    CannotOverwrite,
    DirSameLocation,
};

const CopyFileError = CopyInvalidError || Dir.CopyFileError || cfile.PathStatError || std.mem.Allocator.Error;

const CopyInternalError = error{
    SourceLocationInvalid,
};

pub const CopyError = CopyInternalError || CopyFileError || cfile.ParsedPathError || cfile.PathStatError || Dir.CopyFileError || cfile.ResolveTargetErrorType;

fn copyFileToFile(io: Io, source: []const u8, dest: []const u8, force: bool) Dir.CopyFileError!void {
    // std.debug.print("Source path: {s}\n{s}\n", .{ source, dest });
    try Dir.copyFileAbsolute(source, dest, io, .{ .replace = force });
}

fn copyFile(
    io: Io,
    info: cfile.CopyTargetInfo,
    force: bool,
) CopyFileError!void {
    // we assume that CopyTargetInfo has resolved paths for us so we don't have to deal with directory
    cutil.assertS(info.source_stat.stat != null, "Source file should exist", .{});
    cutil.assertS(info.source_stat.path_type == .file, "Source should be a file", .{});
    cutil.assertS(info.dest_stat.path_type == .file, "Dest should be file", .{});

    if (info.source_path.abs_path.len == 0) return;

    // e = existing, n = non existing, f = file, dir = directory
    const dest_exists = info.dest_stat.stat != null;
    // Total cases covered in this function
    // case: ef -> nf : Y
    // case: ef -> ef : Y with -f
    // case: ef -> ef : N without -f

    // case: ef -> ef : N without -f
    if (dest_exists and info.dest_stat.path_type == .file and !force) {
        return CopyFileError.FileNoForce;
    }

    // case: ef -> nf : Y
    // case: ef -> ef : Y with -f
    if (info.dest_stat.path_type == .file) {
        try copyFileToFile(io, info.source_path.abs_path, info.dest_path.abs_path, force);
        return;
    }
}

fn resolveCopyTarget(
    io: Io,
    alloc: std.mem.Allocator,
    options: *const ProgramOptions,
) CopyError!cfile.CopyTargetInfo {
    const cwd = Dir.cwd();

    const source_path = try cfile.parsePathAbsolute(io, alloc, cwd, options.source);
    defer source_path.deinit(alloc);

    const source_stat = cfile.pathStat(io, &source_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Source file kind not supported: '{s}'", .{options.source});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    if (source_stat.stat == null) {
        return error.SourceLocationInvalid;
    }

    if (source_stat.path_type == .link) {
        std.log.err("cp: links are not supported yet : ( ", .{});
        return error.SourceLocationInvalid;
    }

    const dest_path: cfile.ParsedPath = try cfile.parsePathAbsolute(io, alloc, cwd, options.dest);
    defer dest_path.deinit(alloc);

    const dest_stat = cfile.pathStat(io, &dest_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Dest file kind not supported: '{s}'", .{options.dest});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    return try cfile.resolveTargetPaths(io, alloc, &source_path, &source_stat, &dest_path, &dest_stat);
}

pub fn copySerially(io: Io, alloc: std.mem.Allocator, options: *const ProgramOptions) CopyError!void {
    const resolved = try resolveCopyTarget(io, alloc, options);
    defer resolved.deinit(alloc);

    if (std.mem.eql(u8, resolved.source_path.abs_path, resolved.dest_path.abs_path)) {
        std.log.info("cp: Same location skipping: {s}", .{resolved.dest_path.abs_path});
        return;
    }

    // file to X
    if (resolved.source_stat.path_type == .file) {
        return try copyFile(io, resolved, options.force);
    }

    return std.log.err("Directory and link hasn't been imlemented yet : )", .{});
}
