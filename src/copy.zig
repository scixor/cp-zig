const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const cfile = @import("file.zig");
const cutil = @import("util.zig");
const ProgramOptions = @import("args.zig").ProgramOptions;

const CopyFileError = error{FileNoForce} || Dir.CopyFileError || cfile.PathStatError || std.mem.Allocator.Error;
const CopyDirError = CopyFileError || Dir.OpenError || Dir.CreateDirError || Dir.StatFileError || Dir.Iterator.Error || Io.Cancelable || Io.QueueClosedError || std.mem.Allocator.Error;

pub const CopyError = CopyDirError || cfile.ResolveTargetError;

const DirTask = struct {
    path_ptr: [*:0]u8,
};

const CopyDirContext = struct {
    io: Io,
    alloc: std.mem.Allocator,
    source_dir: Dir,
    dest_dir: Dir,
    force: bool,
    preserve_mode: bool,
    queue: *Io.Queue(DirTask),
    pending: std.atomic.Value(usize),
    failed: std.atomic.Value(bool),
};

const joinChildPathZ = cfile.joinChildPathZ;

fn enqueueDir(ctx: *CopyDirContext, path: [:0]u8) CopyDirError!void {
    _ = ctx.pending.fetchAdd(1, .acq_rel);
    // try to queue this directory for the worker
    const enqueued = ctx.queue.put(ctx.io, &.{.{ .path_ptr = path.ptr }}, 0) catch |err| {
        if (ctx.pending.fetchSub(1, .acq_rel) == 1) {
            ctx.queue.close(ctx.io);
        }
        ctx.alloc.free(path[0 .. path.len + 1]);
        return err;
    };

    // if queue is not full we return
    if (enqueued == 1) return;

    // Queue full -- process inline to avoid deadlock among workers.
    // Keep pending incremented until processing completes
    // (҂◡_◡) ᕤ this took sooo long to figure out
    defer {
        if (ctx.pending.fetchSub(1, .acq_rel) == 1) {
            ctx.queue.close(ctx.io);
        }
    }
    processDirectory(ctx, path) catch |err| {
        ctx.alloc.free(path[0 .. path.len + 1]);
        return err;
    };
    ctx.alloc.free(path[0 .. path.len + 1]);
}

fn processEntries(ctx: *CopyDirContext, parent: []const u8, it: *Dir.Iterator) CopyDirError!void {
    while (try it.next(ctx.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const dir_path = try joinChildPathZ(ctx.alloc, parent, entry.name);
                const perms = if (ctx.preserve_mode)
                    (try ctx.source_dir.statFile(ctx.io, dir_path, .{})).permissions
                else
                    Dir.Permissions.default_dir;
                ctx.dest_dir.createDir(ctx.io, dir_path, perms) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        ctx.alloc.free(dir_path[0 .. dir_path.len + 1]);
                        return err;
                    },
                };
                try enqueueDir(ctx, dir_path);
            },
            .file => {
                const file_path = try joinChildPathZ(ctx.alloc, parent, entry.name);
                defer ctx.alloc.free(file_path[0 .. file_path.len + 1]);
                // FIXME: (⁠╥⁠﹏⁠╥⁠) all .replace = false will error out for Io.Uring implementation with "EINVAL"
                // made a fix hope it goes through https://codeberg.org/ziglang/zig/pulls/31754
                Dir.copyFile(ctx.source_dir, file_path, ctx.dest_dir, file_path, ctx.io, .{
                    .replace = ctx.force,
                    .permissions = if (ctx.preserve_mode) null else File.Permissions.default_file,
                }) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        std.log.info("cp: skipping existing file: {s}", .{file_path});
                    },
                    else => return err,
                };
            },
            else => continue,
        }
    }
}

fn processDirectory(ctx: *CopyDirContext, path: []const u8) CopyDirError!void {
    if (path.len == 0) {
        var it = ctx.source_dir.iterate();
        return processEntries(ctx, path, &it);
    }
    const sub = try ctx.source_dir.openDir(ctx.io, path, .{ .iterate = true });
    defer sub.close(ctx.io);
    var it = sub.iterate();
    return processEntries(ctx, path, &it);
}

fn dirWorker(ctx: *CopyDirContext) Io.Cancelable!void {
    while (true) {
        const task = ctx.queue.getOne(ctx.io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };

        const path: [:0]u8 = std.mem.span(task.path_ptr);
        defer ctx.alloc.free(path[0 .. path.len + 1]);

        processDirectory(ctx, path) catch |err| {
            if (!ctx.failed.swap(true, .acq_rel)) {
                std.log.err("cp: error: {s}", .{@errorName(err)});
            }
            ctx.queue.close(ctx.io);
            return error.Canceled;
        };

        if (ctx.pending.fetchSub(1, .acq_rel) == 1) {
            ctx.queue.close(ctx.io);
        }
    }
}

fn copyFile(
    io: Io,
    info: cfile.CopyTargetInfo,
    options: *const ProgramOptions,
) CopyFileError!void {
    cutil.assertS(info.source_stat.stat != null, "Source file should exist", .{});
    cutil.assertS(info.source_stat.path_type == .file, "Source should be a file", .{});
    cutil.assertS(info.dest_stat.path_type == .file, "Dest should be file", .{});

    if (info.dest_stat.stat != null and !options.force) {
        return error.FileNoForce;
    }

    const cwd = Dir.cwd();
    Dir.copyFile(cwd, info.source, cwd, info.dest, io, .{
        .replace = options.force,
        .permissions = if (options.preserve_mode) null else File.Permissions.default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.FileNoForce,
        else => return err,
    };
}

fn copyDir(
    io: Io,
    alloc: std.mem.Allocator,
    info: cfile.CopyTargetInfo,
    options: *const ProgramOptions,
) CopyDirError!void {
    cutil.assertS(info.source_stat.stat != null, "Source directory should exist", .{});
    cutil.assertS(info.source_stat.path_type == .dir, "Source should be a directory", .{});
    cutil.assertS(info.dest_stat.path_type == .dir, "Destination path should be directory", .{});

    const cwd = Dir.cwd();

    const sdir = try cwd.openDir(io, info.source, .{ .iterate = true });
    defer sdir.close(io);

    if (info.dest_stat.stat == null) {
        const perms = if (options.preserve_mode) info.source_stat.stat.?.permissions else Dir.Permissions.default_dir;
        try cwd.createDir(io, info.dest, perms);
    }

    const ddir = try cwd.openDir(io, info.dest, .{});
    defer ddir.close(io);

    const jobs = @max(options.jobs, 1);
    const queue_capacity = @max(jobs * 8, 256);
    const buffer = try alloc.alloc(DirTask, queue_capacity);
    defer alloc.free(buffer);
    var queue = Io.Queue(DirTask).init(buffer);
    defer queue.close(io);

    var ctx: CopyDirContext = .{
        .io = io,
        .alloc = alloc,
        .source_dir = sdir,
        .dest_dir = ddir,
        .force = options.force,
        .preserve_mode = options.preserve_mode,
        .queue = &queue,
        .pending = .init(1),
        .failed = .init(false),
    };

    const root = try alloc.dupeZ(u8, "");
    errdefer alloc.free(root);
    try queue.putOne(io, .{ .path_ptr = root.ptr });

    var workers: Io.Group = .init;
    // for all jobs possible launch a worker which takes from queue and processes them
    // and also enqueue when new directories found
    for (0..jobs) |_| {
        workers.async(io, dirWorker, .{&ctx});
    }

    workers.await(io) catch |err| {
        if (ctx.failed.load(.acquire) and err == error.Canceled) return error.Canceled;
        // who the heck knows what happened
        return err;
    };
}

pub fn copy(io: Io, alloc: std.mem.Allocator, options: *const ProgramOptions) CopyError!void {
    const resolved = cfile.resolveCopyTarget(io, alloc, options.source, options.dest) catch |err| switch (err) {
        error.ResolveSamePath => return,
        else => return err,
    };
    defer resolved.deinit(alloc);

    if (resolved.source_stat.path_type == .file) {
        return try copyFile(io, resolved, options);
    }

    if (!options.recurse) {
        return error.ResolveInvalidDirToFile;
    }

    if (resolved.source_stat.path_type == .dir) {
        return try copyDir(io, alloc, resolved, options);
    }
}
