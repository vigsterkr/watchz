const std = @import("std");
const SessionReport = @import("../session/report.zig").SessionReport;
const ContainerUpdate = @import("../session/report.zig").ContainerUpdate;

/// Notification severity level
pub const NotificationLevel = enum {
    debug,
    info,
    warn,
    error_level,

    pub fn fromString(s: []const u8) ?NotificationLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .error_level;
        return null;
    }

    pub fn priority(self: NotificationLevel) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .error_level => 3,
        };
    }
};

/// Notification content
pub const Notification = struct {
    level: NotificationLevel,
    title: []const u8,
    message: []const u8,
    timestamp: i64,

    pub fn init(level: NotificationLevel, title: []const u8, message: []const u8) Notification {
        return Notification{
            .level = level,
            .title = title,
            .message = message,
            .timestamp = std.time.timestamp(),
        };
    }
};

/// Base interface for notification backends
pub const Notifier = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, notification: Notification) anyerror!void,
        sendReport: *const fn (ptr: *anyopaque, report: *const SessionReport) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Notifier, notification: Notification) !void {
        try self.vtable.send(self.ptr, notification);
    }

    pub fn sendReport(self: Notifier, report: *const SessionReport) !void {
        try self.vtable.sendReport(self.ptr, report);
    }

    pub fn deinit(self: Notifier) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Manages multiple notification backends
pub const NotificationManager = struct {
    notifiers: std.ArrayList(Notifier),
    min_level: NotificationLevel,
    send_reports: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, min_level: NotificationLevel, send_reports: bool) NotificationManager {
        return NotificationManager{
            .notifiers = std.ArrayList(Notifier).init(allocator),
            .min_level = min_level,
            .send_reports = send_reports,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        for (self.notifiers.items) |notifier| {
            notifier.deinit();
        }
        self.notifiers.deinit();
    }

    pub fn addNotifier(self: *NotificationManager, notifier: Notifier) !void {
        try self.notifiers.append(notifier);
    }

    pub fn notify(self: *NotificationManager, notification: Notification) void {
        // Check if notification level meets minimum threshold
        if (notification.level.priority() < self.min_level.priority()) {
            return;
        }

        for (self.notifiers.items) |notifier| {
            notifier.send(notification) catch |err| {
                std.log.err("Failed to send notification via {any}: {}", .{ notifier.ptr, err });
            };
        }
    }

    pub fn notifyReport(self: *NotificationManager, report: *const SessionReport) void {
        if (!self.send_reports) {
            return;
        }

        for (self.notifiers.items) |notifier| {
            notifier.sendReport(report) catch |err| {
                std.log.err("Failed to send report via {any}: {}", .{ notifier.ptr, err });
            };
        }
    }

    /// Send a simple text notification
    pub fn notifyText(self: *NotificationManager, level: NotificationLevel, title: []const u8, message: []const u8) void {
        const notification = Notification.init(level, title, message);
        self.notify(notification);
    }

    /// Notify about a container update
    pub fn notifyUpdate(self: *NotificationManager, update: *const ContainerUpdate) void {
        const level: NotificationLevel = switch (update.status) {
            .failed => .error_level,
            .success => .info,
            .update_available => .info,
            else => .debug,
        };

        const title = std.fmt.allocPrint(self.allocator, "Container Update: {s}", .{update.container_name}) catch return;
        defer self.allocator.free(title);

        const message = std.fmt.allocPrint(
            self.allocator,
            "Status: {s}\nImage: {s}\nContainer ID: {s}",
            .{ @tagName(update.status), update.image, update.container_id },
        ) catch return;
        defer self.allocator.free(message);

        self.notifyText(level, title, message);
    }
};
