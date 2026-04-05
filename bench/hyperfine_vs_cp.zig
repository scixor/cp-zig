const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const MiB: usize = 1024 * 1024;

// I know : ) global variables but its jsust a script
var interrupted: std.atomic.Value(bool) = .init(false);
var old_sigint: ?std.posix.Sigaction = null;
var old_sigterm: ?std.posix.Sigaction = null;
var signal_handlers_installed = false;

const BenchOptions = struct {
    self_exe: []const u8,
    cpzig_bin: []const u8,
    cpz_bin: []const u8,
    fcp_bin: []const u8,
    cpz_args: []const u8,
    fcp_args: []const u8,
    backend: []const u8,
    runs: usize,
    warmup: usize,
    size_gib: usize,
    size_mib: usize,
    file_size_mib: usize,
    depth: usize,
    fanout: usize,
    tmp_root: []const u8,
    keep_temp: bool,
};

const WorkPaths = struct {
    workdir: []const u8,
    src_dir: []const u8,
    dst_cpzig: []const u8,
    dst_cp: []const u8,
    dst_cpz: []const u8,
    dst_fcp: []const u8,
    result_md: []const u8,
    result_json: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "__prepare")) {
        return runPrepare(init.io, args[2..]);
    }

    const options = parseBenchOptions(init.io, alloc, args) catch |err| {
        switch (err) {
            error.HelpRequested => {
                printUsage();
                return;
            },
            error.UnknownOption => std.log.err("bench: unknown option", .{}),
            error.MissingOptionValue => std.log.err("bench: missing option value", .{}),
            error.InvalidNumber => std.log.err("bench: invalid numeric argument", .{}),
            else => std.log.err("bench: {s}", .{@errorName(err)}),
        }
        return;
    };

    runBenchmark(init, alloc, options) catch |err| {
        std.log.err("bench: {s}", .{@errorName(err)});
    };
}

fn runPrepare(io: Io, paths: []const [:0]const u8) !void {
    for (paths) |path| {
        Dir.cwd().deleteTree(io, path) catch {};
    }
}

fn runBenchmark(init: std.process.Init, alloc: Allocator, options: BenchOptions) !void {
    interrupted.store(false, .release);
    installSignalHandlers();
    defer restoreSignalHandlers();

    if (options.runs < 1) return error.InvalidRuns;
    if (options.file_size_mib < 1) return error.InvalidFileSize;
    if (options.depth < 1) return error.InvalidDepth;
    if (options.fanout < 1) return error.InvalidFanout;

    const backend_flag = if (std.mem.eql(u8, options.backend, "threaded"))
        "--threaded"
    else if (std.mem.eql(u8, options.backend, "single"))
        "--single"
    else if (std.mem.eql(u8, options.backend, "evented"))
        "--evented"
    else
        return error.InvalidBackend;

    Dir.cwd().access(init.io, options.tmp_root, .{}) catch return error.InvalidTmpRoot;

    const path_env = init.environ_map.get("PATH") orelse "";

    if ((try findExecutableInPath(alloc, init.io, path_env, "hyperfine")).len == 0) {
        return error.MissingHyperfine;
    }

    const total_mib = if (options.size_mib > 0) options.size_mib else options.size_gib * 1024;
    if (total_mib < 1) return error.InvalidDatasetSize;

    if (!isExecutable(init.io, options.cpzig_bin)) {
        std.log.info("cp-zig binary not found at {s}, building ReleaseFast...", .{options.cpzig_bin});
        try runCommand(init.io, &.{ "zig", "build", "--release=fast" }, null);
    }
    if (!isExecutable(init.io, options.cpzig_bin)) {
        return error.MissingCpzig;
    }

    var cpz_bin = options.cpz_bin;
    if (cpz_bin.len == 0 and isExecutable(init.io, "/home/sid/Documents/projects/builds/fuc/target/release/cpz")) {
        cpz_bin = "/home/sid/Documents/projects/builds/fuc/target/release/cpz";
    }
    if (cpz_bin.len == 0) {
        cpz_bin = try findExecutableInPath(alloc, init.io, path_env, "cpz");
    }
    if (cpz_bin.len != 0 and !isExecutable(init.io, cpz_bin)) {
        return error.InvalidCpzBinary;
    }

    var fcp_bin = options.fcp_bin;
    if (fcp_bin.len == 0 and isExecutable(init.io, "/home/sid/Documents/projects/builds/fcp/target/release/fcp")) {
        fcp_bin = "/home/sid/Documents/projects/builds/fcp/target/release/fcp";
    }
    if (fcp_bin.len == 0) {
        fcp_bin = try findExecutableInPath(alloc, init.io, path_env, "fcp");
    }
    if (fcp_bin.len != 0 and !isExecutable(init.io, fcp_bin)) {
        return error.InvalidFcpBinary;
    }

    const total_files = @divTrunc(total_mib + options.file_size_mib - 1, options.file_size_mib);
    const effective_total_mib = total_files * options.file_size_mib;

    const workdir = try createWorkDir(alloc, init.io, options.tmp_root);
    defer if (!options.keep_temp) {
        Dir.cwd().deleteTree(init.io, workdir) catch {};
    };

    const paths = try buildPaths(alloc, workdir);
    try Dir.cwd().createDirPath(init.io, paths.src_dir);

    std.log.info("workdir: {s}", .{paths.workdir});
    std.log.info("dataset target: {d} MiB ({d} files x {d} MiB)", .{ effective_total_mib, total_files, options.file_size_mib });
    std.log.info("depth={d} fanout={d} backend={s} runs={d} warmup={d}", .{ options.depth, options.fanout, options.backend, options.runs, options.warmup });
    if (cpz_bin.len != 0) {
        std.log.info("cpz benchmark: enabled ({s})", .{cpz_bin});
    } else {
        std.log.info("cpz benchmark: disabled (binary not found)", .{});
    }
    if (fcp_bin.len != 0) {
        std.log.info("fcp benchmark: enabled ({s})", .{fcp_bin});
    } else {
        std.log.info("fcp benchmark: disabled (binary not found)", .{});
    }

    try createDataset(alloc, init.io, paths.src_dir, total_files, options.file_size_mib, options.depth, options.fanout);

    const stats = try collectTreeStats(alloc, init.io, paths.src_dir);
    std.log.info("source stats: bytes={d} files={d} dirs={d}", .{ stats.bytes, stats.files, stats.dirs });

    const prepare_cmd = try std.fmt.allocPrint(alloc, "{s} __prepare {s} {s} {s} {s}", .{
        options.self_exe,
        paths.dst_cpzig,
        paths.dst_cp,
        paths.dst_cpz,
        paths.dst_fcp,
    });
    const cpzig_cmd = try std.fmt.allocPrint(alloc, "{s} -r {s} {s} {s}", .{
        options.cpzig_bin,
        backend_flag,
        paths.src_dir,
        paths.dst_cpzig,
    });
    const cpzig_single_cmd = try std.fmt.allocPrint(alloc, "{s} -r --single {s} {s}", .{
        options.cpzig_bin,
        paths.src_dir,
        paths.dst_cpzig,
    });
    const cp_cmd = try std.fmt.allocPrint(alloc, "cp -r {s} {s}", .{ paths.src_dir, paths.dst_cp });

    var hyperfine_args: std.ArrayList([]const u8) = .empty;
    defer hyperfine_args.deinit(alloc);

    try hyperfine_args.appendSlice(alloc, &.{
        "hyperfine",
        "-N",
        "--warmup",
    });
    try hyperfine_args.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{options.warmup}));
    try hyperfine_args.appendSlice(alloc, &.{
        "--runs",
    });
    try hyperfine_args.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{options.runs}));
    try hyperfine_args.appendSlice(alloc, &.{
        "--prepare",
        prepare_cmd,
        "--export-markdown",
        paths.result_md,
        "--export-json",
        paths.result_json,
        "--command-name",
    });
    try hyperfine_args.append(alloc, try std.fmt.allocPrint(alloc, "cp-zig-{s}", .{options.backend}));
    try hyperfine_args.append(alloc, cpzig_cmd);

    if (!std.mem.eql(u8, options.backend, "single")) {
        try hyperfine_args.appendSlice(alloc, &.{ "--command-name", "cp-zig-single", cpzig_single_cmd });
    }

    try hyperfine_args.appendSlice(alloc, &.{ "--command-name", "cp", cp_cmd });

    if (cpz_bin.len != 0) {
        const cpz_cmd = try formatOptionalArgCommand(alloc, cpz_bin, options.cpz_args, paths.src_dir, paths.dst_cpz);
        try hyperfine_args.appendSlice(alloc, &.{ "--command-name", "cpz", cpz_cmd });
    }

    if (fcp_bin.len != 0) {
        const fcp_cmd = try formatOptionalArgCommand(alloc, fcp_bin, options.fcp_args, paths.src_dir, paths.dst_fcp);
        try hyperfine_args.appendSlice(alloc, &.{ "--command-name", "fcp", fcp_cmd });
    }

    std.log.info("running hyperfine...", .{});
    try runCommand(init.io, hyperfine_args.items, null);

    std.log.info("markdown results: {s}", .{paths.result_md});
    std.log.info("json results: {s}", .{paths.result_json});
    if (options.keep_temp) {
        std.log.info("temp directory kept: {s}", .{paths.workdir});
    } else {
        std.log.info("temp directory will be removed on exit", .{});
    }
}

fn parseBenchOptions(io: Io, alloc: Allocator, args: []const [:0]const u8) !BenchOptions {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    const default_cpzig = try std.fs.path.join(alloc, &.{ cwd, "zig-out", "bin", "cp-zig" });

    var options = BenchOptions{
        .self_exe = args[0],
        .cpzig_bin = default_cpzig,
        .cpz_bin = "",
        .fcp_bin = "",
        .cpz_args = "",
        .fcp_args = "",
        .backend = "threaded",
        .runs = 5,
        .warmup = 1,
        .size_gib = 5,
        .size_mib = 0,
        .file_size_mib = 1,
        .depth = 6,
        .fanout = 8,
        .tmp_root = "/tmp",
        .keep_temp = false,
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--keep-temp")) {
            options.keep_temp = true;
            continue;
        }

        if (i + 1 >= args.len) return error.MissingOptionValue;
        const value: []const u8 = args[i + 1];
        i += 1;

        if (std.mem.eql(u8, arg, "--cpzig")) {
            options.cpzig_bin = value;
        } else if (std.mem.eql(u8, arg, "--cpz")) {
            options.cpz_bin = value;
        } else if (std.mem.eql(u8, arg, "--fcp")) {
            options.fcp_bin = value;
        } else if (std.mem.eql(u8, arg, "--cpz-args")) {
            options.cpz_args = value;
        } else if (std.mem.eql(u8, arg, "--fcp-args")) {
            options.fcp_args = value;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            options.backend = value;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            options.runs = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            options.warmup = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--size-gib")) {
            options.size_gib = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--size-mib")) {
            options.size_mib = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--file-size-mib")) {
            options.file_size_mib = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            options.depth = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--fanout")) {
            options.fanout = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--tmp-root")) {
            options.tmp_root = value;
        } else {
            return error.UnknownOption;
        }
    }

    return options;
}

fn printUsage() void {
    std.log.info("Usage:", .{});
    std.log.info("  zig build bench -- [options]", .{});
    std.log.info("", .{});
    std.log.info("Options:", .{});
    std.log.info("  --cpzig PATH           Path to cp-zig binary (default: ./zig-out/bin/cp-zig)", .{});
    std.log.info("  --cpz PATH             Path to cpz binary (default: auto-detect)", .{});
    std.log.info("  --fcp PATH             Path to fcp binary (default: auto-detect)", .{});
    std.log.info("  --cpz-args STR         Extra cpz args before SRC DST", .{});
    std.log.info("  --fcp-args STR         Extra fcp args before SRC DST", .{});
    std.log.info("  --backend NAME         Backend for cp-zig: threaded|single|evented", .{});
    std.log.info("  --runs N               Hyperfine runs per command", .{});
    std.log.info("  --warmup N             Hyperfine warmup runs", .{});
    std.log.info("  --size-gib N           Dataset size in GiB", .{});
    std.log.info("  --size-mib N           Dataset size in MiB (overrides --size-gib)", .{});
    std.log.info("  --file-size-mib N      Size of each generated file in MiB", .{});
    std.log.info("  --depth N              Directory depth", .{});
    std.log.info("  --fanout N             Directory fanout per level", .{});
    std.log.info("  --tmp-root DIR         Parent temp directory", .{});
    std.log.info("  --keep-temp            Keep generated temp directory", .{});
    std.log.info("  --help                 Show this help", .{});
}

fn formatOptionalArgCommand(
    alloc: Allocator,
    bin: []const u8,
    extra_args: []const u8,
    src: []const u8,
    dst: []const u8,
) ![]const u8 {
    if (extra_args.len == 0) {
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ bin, src, dst });
    }

    return std.fmt.allocPrint(alloc, "{s} {s} {s} {s}", .{ bin, extra_args, src, dst });
}

fn isExecutable(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn findExecutableInPath(alloc: Allocator, io: Io, path_env: []const u8, name: []const u8) ![]const u8 {
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        const candidate = try std.fs.path.join(alloc, &.{ segment, name });
        if (isExecutable(io, candidate)) {
            return candidate;
        }
    }
    return "";
}

fn createWorkDir(alloc: Allocator, io: Io, tmp_root: []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        const dirname = try std.fmt.allocPrint(alloc, "cpzig-bench-{d:0>2}", .{attempt});
        const full = try std.fs.path.join(alloc, &.{ tmp_root, dirname });
        Dir.cwd().createDir(io, full, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return full;
    }

    return error.CreateWorkdirFailed;
}

fn buildPaths(alloc: Allocator, workdir: []const u8) !WorkPaths {
    return .{
        .workdir = workdir,
        .src_dir = try std.fs.path.join(alloc, &.{ workdir, "src" }),
        .dst_cpzig = try std.fs.path.join(alloc, &.{ workdir, "dst_cpzig" }),
        .dst_cp = try std.fs.path.join(alloc, &.{ workdir, "dst_cp" }),
        .dst_cpz = try std.fs.path.join(alloc, &.{ workdir, "dst_cpz" }),
        .dst_fcp = try std.fs.path.join(alloc, &.{ workdir, "dst_fcp" }),
        .result_md = try std.fs.path.join(alloc, &.{ workdir, "results.md" }),
        .result_json = try std.fs.path.join(alloc, &.{ workdir, "results.json" }),
    };
}

fn createDataset(
    alloc: Allocator,
    io: Io,
    src_dir: []const u8,
    total_files: usize,
    file_size_mib: usize,
    depth: usize,
    fanout: usize,
) !void {
    const seed_len = file_size_mib * MiB;
    const seed = try alloc.alloc(u8, seed_len);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE1234);
    prng.random().bytes(seed);

    var rel_buf: std.ArrayList(u8) = .empty;
    defer rel_buf.deinit(alloc);
    std.log.info("creating dataset...", .{});

    var i: usize = 0;
    while (i < total_files) : (i += 1) {
        if (interrupted.load(.acquire)) return error.Interrupted;

        rel_buf.clearRetainingCapacity();
        try buildRelPath(alloc, &rel_buf, i, depth, fanout);

        const dir_path = try std.fs.path.join(alloc, &.{ src_dir, rel_buf.items });
        try Dir.cwd().createDirPath(io, dir_path);

        const file_name = try std.fmt.allocPrint(alloc, "f{d:0>6}.bin", .{i});
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, file_name });
        const file = try Dir.createFileAbsolute(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, seed);

        if (((i + 1) % 256 == 0) or (i + 1 == total_files)) {
            std.log.info("created files: {d}/{d}", .{ i + 1, total_files });
        }
    }
}

fn buildRelPath(alloc: Allocator, buf: *std.ArrayList(u8), idx: usize, depth: usize, fanout: usize) !void {
    var n = idx;
    var d: usize = 1;
    while (d <= depth) : (d += 1) {
        if (buf.items.len > 0) {
            try buf.append(alloc, Dir.path.sep);
        }

        const bucket = n % fanout;
        n = @divTrunc(n, fanout);
        const segment = try std.fmt.allocPrint(alloc, "d{d}_{d}", .{ d, bucket });
        defer alloc.free(segment);
        try buf.appendSlice(alloc, segment);
    }
}

const TreeStats = struct {
    bytes: u64,
    files: usize,
    dirs: usize,
};

fn collectTreeStats(alloc: Allocator, io: Io, root: []const u8) !TreeStats {
    var stats: TreeStats = .{ .bytes = 0, .files = 0, .dirs = 0 };
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, root);

    while (stack.pop()) |path| {
        if (interrupted.load(.acquire)) return error.Interrupted;

        stats.dirs += 1;

        const dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer dir.close(io);

        var it = dir.iterateAssumeFirstIteration();
        while (try it.next(io)) |entry| {
            const child = try std.fs.path.join(alloc, &.{ path, entry.name });
            switch (entry.kind) {
                .directory => try stack.append(alloc, child),
                .file => {
                    const file_stat = try Dir.cwd().statFile(io, child, .{});
                    stats.files += 1;
                    stats.bytes += file_stat.size;
                },
                else => {},
            }
        }
    }

    return stats;
}

fn interruptSignalHandler(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

fn installSignalHandlers() void {
    if (comptime !supportsPosixSignals()) return;
    if (signal_handlers_installed) return;

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = interruptSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    var prev_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &prev_int);
    old_sigint = prev_int;

    var prev_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, &action, &prev_term);
    old_sigterm = prev_term;

    signal_handlers_installed = true;
}

fn restoreSignalHandlers() void {
    if (comptime !supportsPosixSignals()) return;
    if (!signal_handlers_installed) return;

    if (old_sigint) |prev_int| {
        std.posix.sigaction(.INT, &prev_int, null);
    }
    if (old_sigterm) |prev_term| {
        std.posix.sigaction(.TERM, &prev_term, null);
    }

    old_sigint = null;
    old_sigterm = null;
    signal_handlers_installed = false;
}

fn supportsPosixSignals() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .freestanding, .uefi, .emscripten => false,
        else => true,
    };
}

fn runCommand(io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .expand_arg0 = .expand,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
