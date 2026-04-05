const std = @import("std");
const builtin = @import("builtin");

const Backend = @import("args.zig").Backend;

pub const JobsLimitReason = enum {
    backend_single,
    requested,
    cpuset,
    cgroup,
    cpu_count,
    fallback,
};

pub const JobsResolution = struct {
    requested_jobs: usize,
    base_cpu_count: usize,
    cgroup_limit: usize,
    cpuset_limit: usize,
    resolved_jobs: usize,
    limited_by: JobsLimitReason,

    pub fn log(self: JobsResolution, comptime label: []const u8) void {
        std.log.info("cp: " ++ label ++ " resolved_jobs={d} requested_jobs={d} base_cpu={d} cgroup_limit={d} cpuset_limit={d} limited_by={s}", .{
            self.resolved_jobs,
            self.requested_jobs,
            self.base_cpu_count,
            self.cgroup_limit,
            self.cpuset_limit,
            @tagName(self.limited_by),
        });
    }
};

pub fn assertS(cond: bool, comptime format: []const u8, args: anytype) void {
    @disableInstrumentation();
    if (!cond) {
        std.debug.panic(format, args);
        unreachable;
    }
}

pub fn resolveJobsInfo(backend: Backend, requested_jobs: usize) JobsResolution {
    if (backend == .single) {
        return .{
            .requested_jobs = requested_jobs,
            .base_cpu_count = 1,
            .cgroup_limit = 0,
            .cpuset_limit = 0,
            .resolved_jobs = 1,
            .limited_by = .backend_single,
        };
    }

    if (requested_jobs > 0) {
        return .{
            .requested_jobs = requested_jobs,
            .base_cpu_count = 0,
            .cgroup_limit = 0,
            .cpuset_limit = 0,
            .resolved_jobs = requested_jobs,
            .limited_by = .requested,
        };
    }

    const base = std.Thread.getCpuCount() catch 1;
    const cgroup_limit = linuxCgroupCpuLimit();
    const cpuset_limit = linuxCpusetCpuLimit();

    var jobs = if (base == 0) @as(usize, 1) else base;
    var limited_by: JobsLimitReason = if (base == 0) .fallback else .cpu_count;

    if (cgroup_limit > 0 and cgroup_limit < jobs) {
        jobs = cgroup_limit;
        limited_by = .cgroup;
    }

    if (cpuset_limit > 0 and cpuset_limit < jobs) {
        jobs = cpuset_limit;
        limited_by = .cpuset;
    }

    if (jobs == 0) {
        jobs = 1;
        limited_by = .fallback;
    }

    return .{
        .requested_jobs = requested_jobs,
        .base_cpu_count = base,
        .cgroup_limit = cgroup_limit,
        .cpuset_limit = cpuset_limit,
        .resolved_jobs = jobs,
        .limited_by = limited_by,
    };
}

fn linuxCgroupCpuLimit() usize {
    if (builtin.os.tag != .linux) return 0;

    var buf: [128]u8 = undefined;
    if (readSmallFile("/sys/fs/cgroup/cpu.max", &buf)) |content| {
        var tok = std.mem.tokenizeAny(u8, content, " \n\t");
        const quota_s = tok.next() orelse return 0;
        const period_s = tok.next() orelse return 0;
        if (std.mem.eql(u8, quota_s, "max")) return 0;

        const quota = std.fmt.parseUnsigned(usize, quota_s, 10) catch return 0;
        const period = std.fmt.parseUnsigned(usize, period_s, 10) catch return 0;
        if (quota == 0 or period == 0) return 0;
        return ceilDiv(quota, period);
    }

    var quota_buf: [64]u8 = undefined;
    var period_buf: [64]u8 = undefined;
    const quota_text = readSmallFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", &quota_buf) orelse return 0;
    const period_text = readSmallFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us", &period_buf) orelse return 0;

    const quota = std.fmt.parseInt(isize, std.mem.trim(u8, quota_text, " \n\t"), 10) catch return 0;
    const period = std.fmt.parseUnsigned(usize, std.mem.trim(u8, period_text, " \n\t"), 10) catch return 0;
    if (quota <= 0 or period == 0) return 0;
    return ceilDiv(@as(usize, @intCast(quota)), period);
}

fn linuxCpusetCpuLimit() usize {
    if (builtin.os.tag != .linux) return 0;

    var buf: [256]u8 = undefined;
    if (readSmallFile("/sys/fs/cgroup/cpuset.cpus.effective", &buf)) |content| {
        return parseCpuSetCount(std.mem.trim(u8, content, " \n\t"));
    }

    if (readSmallFile("/sys/fs/cgroup/cpuset/cpuset.cpus", &buf)) |content| {
        return parseCpuSetCount(std.mem.trim(u8, content, " \n\t"));
    }

    return 0;
}

fn parseCpuSetCount(cpuset: []const u8) usize {
    if (cpuset.len == 0) return 0;

    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, cpuset, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \n\t");
        if (part.len == 0) continue;

        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const start_s = std.mem.trim(u8, part[0..dash], " \n\t");
            const end_s = std.mem.trim(u8, part[dash + 1 ..], " \n\t");
            const start = std.fmt.parseUnsigned(usize, start_s, 10) catch continue;
            const end = std.fmt.parseUnsigned(usize, end_s, 10) catch continue;
            if (end >= start) count += (end - start + 1);
        } else {
            _ = std.fmt.parseUnsigned(usize, part, 10) catch continue;
            count += 1;
        }
    }

    return count;
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    const len = std.posix.read(fd, buf) catch return null;
    return buf[0..len];
}

fn ceilDiv(n: usize, d: usize) usize {
    if (d == 0) return 0;
    return (n + d - 1) / d;
}
