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

    // NOTE: do we want to incur this? probably
    if (std.mem.eql(u8, info.source_path.abs_path, info.dest_path.abs_path)) {
        std.log.info("cp: Same as source file skipping: {s}", .{info.dest_path.abs_path});
        return;
    }

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

fn copyDirInner(
    io: Io,
    sdir: Dir,
    ddir: Dir,
    force: bool,
) !void {
    var it = sdir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                Dir.copyFile(sdir, entry.name, ddir, entry.name, io, .{ .replace = force }) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        std.log.info("cp: skipping existing file: {s}", .{entry.name});
                        continue;
                    },
                    else => return err,
                };
            },
            .directory => {
                // create dest subdir if needed, preserving source permissions
                const src_sub = try sdir.openDir(io, entry.name, .{ .iterate = true });
                defer src_sub.close(io);

                const src_stat = try src_sub.stat(io);

                const dst_sub = ddir.openDir(io, entry.name, .{}) catch |err| switch (err) {
                    error.FileNotFound => blk: {
                        try ddir.createDir(io, entry.name, src_stat.permissions);
                        break :blk try ddir.openDir(io, entry.name, .{});
                    },
                    else => return err,
                };
                defer dst_sub.close(io);

                try copyDirInner(io, src_sub, dst_sub, force);
            },
            else => continue,
        }
    }
}

fn copyDir(
    io: Io,
    info: cfile.CopyTargetInfo,
    force: bool,
) !void {
    // we assume Target has resolved this to absolute directories
    cutil.assertS(info.source_stat.stat != null, "Source directory should exist", .{});
    cutil.assertS(info.source_stat.path_type == .dir, "Source should be a directory", .{});
    cutil.assertS(info.dest_stat.path_type == .dir, "Destination path should be directory", .{});

    // skip the expensive work if we are in same directory as source
    if (std.mem.eql(u8, info.source_path.abs_path, info.dest_path.abs_path)) {
        std.log.info("cp: Same source dir skipping: {s}", .{info.dest_path.abs_path});
        return;
    }

    const sdir = try Dir.openDirAbsolute(io, info.source_path.abs_path, .{ .iterate = true });
    defer sdir.close(io);

    // if it doesn't exist, create the directory at that place
    if (info.dest_stat.stat == null) {
        try Dir.createDirAbsolute(io, info.dest_path.abs_path, info.source_stat.stat.?.permissions);
    }

    // open the damn thing
    const ddir = try Dir.openDirAbsolute(io, info.dest_path.abs_path, .{});
    defer ddir.close(io);

    try copyDirInner(io, sdir, ddir, force);
}

fn resolveCopyTarget(
    io: Io,
    alloc: std.mem.Allocator,
    source_dir: Dir,
    dest_dir: Dir,
    source: []const u8,
    dest: []const u8,
) CopyError!cfile.CopyTargetInfo {
    const source_path = try cfile.parsePathAbsolute(io, alloc, source_dir, source);
    defer source_path.deinit(alloc);

    const source_stat = cfile.pathStat(io, &source_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Source file kind not supported: '{s}'", .{source});
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

    const dest_path: cfile.ParsedPath = try cfile.parsePathAbsolute(io, alloc, dest_dir, dest);
    defer dest_path.deinit(alloc);

    const dest_stat = cfile.pathStat(io, &dest_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Dest file kind not supported: '{s}'", .{dest});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    return try cfile.resolveTargetPaths(io, alloc, &source_path, &source_stat, &dest_path, &dest_stat);
}

pub fn copySerially(io: Io, alloc: std.mem.Allocator, options: *const ProgramOptions) CopyError!void {
    const cwd = Dir.cwd();
    const resolved = resolveCopyTarget(io, alloc, cwd, cwd, options.source, options.dest) catch |err| switch (err) {
        error.ResolveSameDir => {
            std.log.info("cp: Same directory skipping: {s}", .{options.source});
            return;
        },
        else => return err,
    };
    defer resolved.deinit(alloc);

    // file to X
    if (resolved.source_stat.path_type == .file) {
        return try copyFile(io, resolved, options.force);
    }

    if (!options.recurse) {
        std.log.err("cp: Recurse not set cannot copy a directory wihout it", .{});
    }

    if (resolved.source_stat.path_type == .dir) {
        return try copyDir(io, resolved, options.force);
    }
}
