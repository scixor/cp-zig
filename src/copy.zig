const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const cp_file = @import("file.zig");
const util = @import("util.zig");
const ProgramOptions = @import("args.zig").ProgramOptions;

const CopyInvalidError = error{
    DestinationDirInvalid,
    FileNoForce,
    CannotOverwrite,
    DirSameLocation,
};

const CopyFileError = CopyInvalidError || Dir.CopyFileError || cp_file.PathStatError || std.mem.Allocator.Error;

const CopyInternalError = error{
    SourceLocationInvalid,
    DestinationLocationInvalid,
    SameLocation,
};

pub const CopyError = CopyInternalError || CopyFileError || cp_file.ParsedPathError || cp_file.PathStatError || Dir.CopyFileError;

fn copyFileToFile(io: Io, source: []const u8, dest: []const u8, force: bool) Dir.CopyFileError!void {
    // std.debug.print("Source path: {s}\n{s}\n", .{ source, dest });
    try Dir.copyFileAbsolute(source, dest, io, .{ .replace = force });
}

fn copyFile(
    io: Io,
    alloc: std.mem.Allocator,
    source_path: *const cp_file.ParsedPath,
    source_stat: *const cp_file.PathStat,
    dest_path: *const cp_file.ParsedPath,
    dest_stat: *const cp_file.PathStat,
    force: bool,
) CopyFileError!void {
    util.assertS(source_stat.path_type == .file, "Source should be a file", .{});
    util.assertS(source_stat.stat != null, "Source file should exist", .{});

    if (source_path.abs_path.len == 0) return;

    // e = existing, n = non existing, f = file, dir = directory
    const dest_exists = dest_stat.stat != null;
    // Total cases covered in this function
    // case: ef -> nf : Y
    // case: ef -> edir : Y
    // case: ef -> ef : Y with -f
    // case: ef -> ef : N without -f
    // case: ef -> ndir : N

    // case: ef -> ndir : N
    if (!dest_exists and dest_stat.path_type == .dir) {
        return CopyFileError.DestinationDirInvalid;
    }

    // case: ef -> ef : N without -f
    if (dest_exists and dest_stat.path_type == .file and !force) {
        return CopyFileError.FileNoForce;
    }

    // case: ef -> nf : Y
    // case: ef -> ef : Y with -f
    if (!dest_exists and dest_stat.path_type == .file) {
        try copyFileToFile(io, source_path.abs_path, dest_path.abs_path, force);
        return;
    }

    // case: ef -> edir : Y
    // TODO: This is too big, ideally, the copyFile would resolve destination path
    if (dest_exists and dest_stat.path_type == .dir) {
        const filename = Dir.path.basename(source_path.abs_path);
        const final_dest = try Dir.path.resolve(alloc, &.{ dest_path.abs_path, filename });

        if (std.mem.eql(u8, source_path.abs_path, dest_path.abs_path)) {
            return CopyFileError.DirSameLocation;
        }

        // try to see if file already exists at dest
        // NOTE: this does mean more syscalls
        // but I have been bitten by this a lot trying to copy and forgetting that
        // there is a same name file there
        const parsed_path = cp_file.ParsedPath{ .abs_path = final_dest };
        const dir_file_dest_stat = try cp_file.pathStat(io, &parsed_path);
        const dest_exists_file = dir_file_dest_stat.stat != null and dir_file_dest_stat.path_type == .file;

        if (dir_file_dest_stat.stat == null or (dest_exists_file and force)) {
            try copyFileToFile(io, source_path.abs_path, final_dest, force);
            return;
        }

        if (dest_exists_file and !force) return CopyFileError.FileNoForce;
        // if it was force we are not able to overwrite it
        if (force) return CopyFileError.CannotOverwrite;
        // silent exit for now
        return;
    }
}

pub fn copySerially(io: Io, alloc: std.mem.Allocator, options: *const ProgramOptions) CopyError!void {
    const cwd = Dir.cwd();

    const source_path = try cp_file.parsePathAbsolute(io, alloc, cwd, options.source);
    defer source_path.deinit(alloc);

    const source_stat = cp_file.pathStat(io, &source_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Source file kind not supported: '{s}'", .{options.source});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    if (source_stat.stat == null) {
        std.log.err("Source not found : '{s}'", .{options.source});
        return error.SourceLocationInvalid;
    }

    const dest_path: cp_file.ParsedPath = try cp_file.parsePathAbsolute(io, alloc, cwd, options.dest);
    defer dest_path.deinit(alloc);

    const dest_stat = cp_file.pathStat(io, &dest_path) catch |err| switch (err) {
        error.StatKindNotSupported => {
            std.log.err("Dest file kind not supported: '{s}'", .{options.dest});
            return error.SourceLocationInvalid;
        },
        else => return err,
    };

    if (std.mem.eql(u8, source_path.abs_path, dest_path.abs_path)) {
        return CopyInternalError.SameLocation;
    }

    // file to X
    if (source_stat.path_type == .file) {
        try copyFile(io, alloc, &source_path, &source_stat, &dest_path, &dest_stat, options.force);
    }
}
