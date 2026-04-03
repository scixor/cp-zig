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
    backend: Backend,
    source: [:0]const u8,
    dest: [:0]const u8,

    pub fn init(
        source: [:0]const u8,
        dest: [:0]const u8,
        opts: struct { recurse: bool = false, force: bool = false, verbose: bool = false, backend: Backend = .threaded },
    ) ProgramOptions {
        return .{
            .recurse = opts.recurse,
            .force = opts.force,
            .verbose = opts.verbose,
            .backend = opts.backend,
            .source = source,
            .dest = dest,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(ProgramOptions) == 40);
}

pub const ProgramParseError = error{
    SourceNotFound,
    DestNotFound,
};

pub fn parseProgramOptions(args: *const []const [:0]const u8) ProgramParseError!ProgramOptions {
    var recurse = false;
    var force = false;
    var verbose = false;
    var backend: Backend = .threaded;
    var source: [:0]const u8 = "";
    var dest: [:0]const u8 = "";

    for (args.*[1..]) |arg| {
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
        .backend = backend,
    });
}
