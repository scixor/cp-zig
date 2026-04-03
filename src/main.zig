const std = @import("std");
const Io = std.Io;

const cp = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    const options = cp.args.parseProgramOptions(&args) catch |err| {
        switch (err) {
            error.SourceNotFound => std.log.err("No source was given", .{}),
            error.DestNotFound => std.log.err("No destination was given", .{}),
        }
        return;
    };

    try cp.copy.copySerially(io, arena, &options);
    // catch {
    // for now just exit
    // std.process.exit(1);
    // };

    // In order to do I/O operations need an `Io` instance.

    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try stdout_writer.flush(); // Don't forget to flush!
}
