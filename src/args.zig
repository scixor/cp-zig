const std = @import("std");
const Io = std.Io;

pub const Backend = enum {
    single,
    threaded,
    evented,

    pub fn str(self: Backend) []const u8 {
        return @tagName(self);
    }
};

pub const ProgramOptions = struct {
    recurse: bool,
    force: bool,
    verbose: bool,
    preserve_mode: bool,
    jobs: usize,
    backend: Backend,
    source: [:0]const u8,
    dest: [:0]const u8,

    pub fn init(
        source: [:0]const u8,
        dest: [:0]const u8,
        opts: struct {
            recurse: bool = false,
            force: bool = false,
            verbose: bool = false,
            preserve_mode: bool = true,
            jobs: usize = 0,
            backend: Backend = .threaded,
        },
    ) ProgramOptions {
        return .{
            .recurse = opts.recurse,
            .force = opts.force,
            .verbose = opts.verbose,
            .preserve_mode = opts.preserve_mode,
            .jobs = opts.jobs,
            .backend = opts.backend,
            .source = source,
            .dest = dest,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(ProgramOptions) == 48);
}

pub const ProgramParseError = error{
    HelpRequested,
    SourceNotFound,
    DestNotFound,
    UnknownArgument,
    TooManyPositionals,
    MissingJobsValue,
    InvalidJobs,
};

pub const ParseContext = struct {
    bad_arg: ?[]const u8 = null,
};

pub fn printUsage() void {
    std.log.info("Usage:", .{});
    std.log.info("  cp-zig [options] <source> <dest>", .{});
    std.log.info("", .{});
    std.log.info("Options:", .{});
    std.log.info("  -r                   Copy directories recursively", .{});
    std.log.info("  -f                   Overwrite destination files", .{});
    std.log.info("  -v                   Verbose output", .{});
    std.log.info("  --single             Use single-threaded backend", .{});
    std.log.info("  --threaded           Use threaded backend (default)", .{});
    std.log.info("  --evented            Use evented backend (currently disabled)", .{});
    std.log.info("  --jobs N             Limit async concurrency in threaded backend", .{});
    std.log.info("  --jobs=N             Same as --jobs N", .{});
    std.log.info("  --no-preserve-mode   Do not preserve source file mode", .{});
    std.log.info("  -h, --help           Show this help", .{});
}

pub fn parseProgramOptions(args: *const []const [:0]const u8, ctx: *ParseContext) ProgramParseError!ProgramOptions {
    var recurse = false;
    var force = false;
    var verbose = false;
    var preserve_mode = true;
    var jobs: usize = 0;
    var backend: Backend = .threaded;
    var source: [:0]const u8 = "";
    var dest: [:0]const u8 = "";

    var index: usize = 1;
    while (index < args.*.len) : (index += 1) {
        const arg = args.*[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return ProgramParseError.HelpRequested;
        } else if (std.mem.eql(u8, arg, "-r")) {
            recurse = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-f")) {
            force = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--single")) {
            backend = .single;
            continue;
        } else if (std.mem.eql(u8, arg, "--threaded")) {
            backend = .threaded;
            continue;
        } else if (std.mem.eql(u8, arg, "--evented")) {
            backend = .evented;
            continue;
        } else if (std.mem.eql(u8, arg, "--no-preserve-mode")) {
            preserve_mode = false;
            continue;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            if (index + 1 >= args.*.len) {
                ctx.bad_arg = arg;
                return ProgramParseError.MissingJobsValue;
            }
            index += 1;
            jobs = std.fmt.parseUnsigned(usize, args.*[index], 10) catch return ProgramParseError.InvalidJobs;
            continue;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            jobs = std.fmt.parseUnsigned(usize, arg["--jobs=".len..], 10) catch return ProgramParseError.InvalidJobs;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            ctx.bad_arg = arg;
            return ProgramParseError.UnknownArgument;
        }

        if (source.len == 0) {
            source = arg;
            continue;
        }
        if (dest.len == 0) {
            dest = arg;
            continue;
        }

        ctx.bad_arg = arg;
        return ProgramParseError.TooManyPositionals;
    }

    if (source.len == 0) return ProgramParseError.SourceNotFound;
    if (dest.len == 0) return ProgramParseError.DestNotFound;

    if (verbose) {
        std.log.info("Source: {s}", .{source});
        std.log.info("Dest: {s}", .{dest});
    }

    return ProgramOptions.init(source, dest, .{
        .recurse = recurse,
        .force = force,
        .verbose = verbose,
        .preserve_mode = preserve_mode,
        .jobs = jobs,
        .backend = backend,
    });
}
