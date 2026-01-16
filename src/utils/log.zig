const std = @import("std");

pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn fromString(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "trace")) return .trace;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

var current_level: Level = .info;
var mutex = std.Thread.Mutex{};

pub fn setLevel(level: Level) void {
    mutex.lock();
    defer mutex.unlock();
    current_level = level;
}

pub fn getLevel() Level {
    mutex.lock();
    defer mutex.unlock();
    return current_level;
}

fn shouldLog(level: Level) bool {
    const curr = getLevel();
    return @intFromEnum(level) >= @intFromEnum(curr);
}

fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;

    mutex.lock();
    defer mutex.unlock();

    const timestamp = std.time.timestamp();
    const dt = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = dt.getDaySeconds();
    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    const seconds = day_seconds.getSecondsIntoMinute();

    std.debug.print("{d:0>2}:{d:0>2}:{d:0>2} [{s}] " ++ fmt ++ "\n", .{
        hours,
        minutes,
        seconds,
        level.toString(),
    } ++ args);
}

pub fn trace(comptime fmt: []const u8, args: anytype) void {
    log(.trace, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
