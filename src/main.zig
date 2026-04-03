const std = @import("std");
const Io = std.Io;

const cp = @import("root.zig");
const Backend = cp.args.Backend;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    const options = cp.args.parseProgramOptions(&args) catch |err| {
        switch (err) {
            error.SourceNotFound => std.log.err("No source was given", .{}),
            error.DestNotFound => std.log.err("No destination was given", .{}),
        }
        return;
    };

    if (options.backend == .evented) {
        var evented: Io.Evented = undefined;
        evented.init(init.gpa, .{}) catch |err| {
            std.log.err("cp: failed to init evented backend: {s}", .{@errorName(err)});
            return err;
        };
        defer evented.deinit();

        if (options.verbose) {
            std.log.info("cp: using {s} backend", .{options.backend.str()});
        }
        return cp.copy.copy(evented.io(), arena, &options);
    }

    var single: Io.Threaded = .init_single_threaded;
    const io: Io = switch (options.backend) {
        .single => single.io(),
        .threaded => init.io,
        .evented => unreachable,
    };

    if (options.verbose) {
        std.log.info("cp: using {s} backend", .{options.backend.str()});
    }

    try cp.copy.copy(io, arena, &options);
}
