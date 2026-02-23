const std = @import("std");
const Io = std.Io;

const ProgramOptions = struct {
    recurse: bool,
    force: bool,
    verbose: bool,
    source: [:0]const u8,
    dest: [:0]const u8,
};

comptime {
    std.debug.assert(@sizeOf(ProgramOptions) == 40);
}

const ProgramParseError = error{
    SourceNotFound,
    DestNotFound,
};

pub fn parseProgramOptions(args: *const []const [:0]const u8) ProgramParseError!ProgramOptions {
    var recurse = false;
    var force = false;
    var verbose = false;
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
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            std.log.warn("cp: Unknown argument '{s}' ignoring", .{arg});
            continue;
        }

        if (source.len == 0) source = arg;
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

    return .{
        .recurse = recurse,
        .force = force,
        .verbose = verbose,
        .source = source,
        .dest = dest,
    };
}
