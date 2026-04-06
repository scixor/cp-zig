const std = @import("std");
const Io = std.Io;

const cp = @import("root.zig");
const cutil = @import("util.zig");
const Backend = cp.args.Backend;

fn runCopy(io: Io, arena: std.mem.Allocator, options: *const cp.args.ProgramOptions) void {
    if (options.verbose) {
        std.log.info("cp: using {s} backend", .{options.backend.str()});
    }

    cp.copy.copy(io, arena, options) catch |err| {
        switch (err) {
            error.ResolveSamePath => {},
            error.SourceLocationInvalid => std.log.err("cp: cannot stat '{s}': No such file or directory", .{options.source}),
            error.DestLocationInvalid => std.log.err("cp: cannot stat '{s}': unsupported file type", .{options.dest}),
            error.ResolveInvalidFileToDir => std.log.err("cp: cannot copy '{s}' to non-existing directory '{s}'", .{ options.source, options.dest }),
            error.ResolveInvalidDirToFile => std.log.err("cp: cannot overwrite non-directory '{s}' with directory '{s}'", .{ options.dest, options.source }),
            error.FileNoForce => std.log.err("cp: '{s}' already exists, use -f to overwrite", .{options.dest}),
            error.FileNotFound => std.log.err("cp: '{s}': No such file or directory", .{options.source}),
            error.AccessDenied, error.PermissionDenied => std.log.err("cp: permission denied", .{}),
            error.NoSpaceLeft => std.log.err("cp: no space left on device", .{}),
            error.OutOfMemory => std.log.err("cp: out of memory", .{}),
            error.Canceled => {},
            else => std.log.err("cp: {s}", .{@errorName(err)}),
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var parse_ctx: cp.args.ParseContext = .{};

    var options = cp.args.parseProgramOptions(&args, &parse_ctx) catch |err| {
        switch (err) {
            error.HelpRequested => {
                cp.args.printUsage();
                return;
            },
            error.SourceNotFound => std.log.err("cp: missing source path", .{}),
            error.DestNotFound => std.log.err("cp: missing destination path", .{}),
            error.MissingJobsValue => std.log.err("cp: option '{s}' requires a value", .{parse_ctx.bad_arg orelse "--jobs"}),
            error.InvalidJobs => std.log.err("cp: invalid --jobs value", .{}),
            error.UnknownArgument => std.log.err("cp: unknown argument '{s}'", .{parse_ctx.bad_arg orelse "<unknown>"}),
            error.TooManyPositionals => std.log.err("cp: unexpected extra positional argument '{s}'", .{parse_ctx.bad_arg orelse "<unknown>"}),
        }

        cp.args.printUsage();
        return;
    };

    const jobs_info = cutil.resolveJobsInfo(options.backend, options.jobs);
    options.jobs = jobs_info.resolved_jobs;
    if (options.verbose) jobs_info.log("jobs");

    switch (options.backend) {
        .evented => {
            // FIXME: (¬`‸´¬) Uring.zig error set bug in zig 0.16.0-dev.3091
            // Hope this gets through: https://codeberg.org/ziglang/zig/pulls/31764

            // var evented: Io.Evented = undefined;
            // evented.init(init.gpa, .{}) catch |err| {
            //     std.log.err("cp: failed to init evented backend: {s}", .{@errorName(err)});
            //     return err;
            // };
            // defer evented.deinit();
            // return runCopy(evented.io(), arena, &options);
            std.log.err("cp: evented backend is disabled (Uring.zig error set bug in this zig version)", .{});
            return;
        },
        .single => {
            var single: Io.Threaded = .init_single_threaded;
            return runCopy(single.io(), arena, &options);
        },
        .threaded => {
            var threaded: Io.Threaded = Io.Threaded.init(init.gpa, .{
                .async_limit = .limited(options.jobs),
            });
            defer threaded.deinit();
            return runCopy(threaded.io(), arena, &options);
        },
    }
}
