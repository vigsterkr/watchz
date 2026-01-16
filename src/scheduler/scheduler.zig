const std = @import("std");
const zio = @import("zio");
const log = @import("../utils/log.zig");

/// Async scheduler for running periodic tasks
pub const Scheduler = struct {
    interval_seconds: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, interval_seconds: u64) Scheduler {
        return Scheduler{
            .interval_seconds = interval_seconds,
            .allocator = allocator,
        };
    }

    /// Run a task periodically until cancelled
    /// The task_fn should have signature: fn(*zio.Runtime) !void
    pub fn runPeriodic(
        self: *Scheduler,
        rt: *zio.Runtime,
        comptime task_fn: anytype,
        args: anytype,
    ) !void {
        log.info("Scheduler started with interval: {d} seconds", .{self.interval_seconds});

        while (true) {
            const start_time = std.time.milliTimestamp();

            // Run the task
            log.debug("Running scheduled task", .{});
            @call(.auto, task_fn, args) catch |err| {
                log.err("Scheduled task failed: {}", .{err});
            };

            const end_time = std.time.milliTimestamp();
            const elapsed_ms = end_time - start_time;
            const elapsed_sec = @divTrunc(elapsed_ms, 1000);

            log.debug("Task completed in {d}ms", .{elapsed_ms});

            // Calculate sleep time
            const sleep_sec = if (elapsed_sec < self.interval_seconds)
                self.interval_seconds - @as(u64, @intCast(elapsed_sec))
            else
                0;

            if (sleep_sec > 0) {
                log.debug("Sleeping for {d} seconds until next run", .{sleep_sec});
                try rt.sleep(zio.Duration.fromSeconds(sleep_sec));
            }
        }
    }

    /// Run a task once
    pub fn runOnce(
        comptime task_fn: anytype,
        args: anytype,
    ) !void {
        log.info("Running task once", .{});
        try task_fn(args);
    }
};
