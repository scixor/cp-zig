const std = @import("std");
const Io = std.Io;

const cp_zig = @import("cp-zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    // const io = init.io;

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    const options = cp_zig.parseProgramOptions(&args) catch |err| {
        switch (err) {
            error.SourceNotFound => std.log.err("No source was given", .{}),
            error.DestNotFound => std.log.err("No destination was given", .{}),
        }
        return;
    };
    _ = options;

    // outer: for (args) |arg| {
    //     const arg_path = Io.Dir.path.parsePathPosix(arg);

    // see if exists
    // _ = cwd_dir.statFile(io, arg_path.root, .{}) catch |err| switch (err) {
    //     error.FileNotFound => {
    //         std.log.err("File not found {s}", .{arg_path.root});
    //         continue :outer;
    //     },
    //     else => return err,
    // };

    // switch (stat.kind) {
    //     .file => handleFile(arg_path),
    //     .directory => handleDirectory(),
    //     .sym_link => handleSymlink(),
    // }

    // const walker = try Io.Dir.walk(cwd_dir, arena);
    // }

    // In order to do I/O operations need an `Io` instance.

    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try stdout_writer.flush(); // Don't forget to flush!
}
