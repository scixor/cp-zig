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
    SourceNotFound,
    DestNotFound,
    InvalidJobs,
};

pub fn parseProgramOptions(args: *const []const [:0]const u8) ProgramParseError!ProgramOptions {
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
        // std.log.debug("Info Arg: '{s}'", .{arg});
        if (std.mem.eql(u8, arg, "-r")) {
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
            if (index + 1 >= args.*.len) return ProgramParseError.InvalidJobs;
            index += 1;
            jobs = std.fmt.parseUnsigned(usize, args.*[index], 10) catch return ProgramParseError.InvalidJobs;
            continue;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            jobs = std.fmt.parseUnsigned(usize, arg["--jobs=".len..], 10) catch return ProgramParseError.InvalidJobs;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            std.log.warn("cp: Unknown argument '{s}' ignoring", .{arg});
            continue;
        }

        if (source.len == 0) {
            source = arg;
            continue;
        }
        if (dest.len == 0) dest = arg;

        // ignore the rest :)
        // I know we are still looping over everything but don't care
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
