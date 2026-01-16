const std = @import("std");
const notifier = @import("notifier.zig");
const Notifier = notifier.Notifier;
const Notification = notifier.Notification;
const NotificationLevel = notifier.NotificationLevel;
const SessionReport = @import("../session/report.zig").SessionReport;
const HttpUtils = @import("../utils/http.zig").HttpUtils;

/// Slack webhook notifier using Slack's Incoming Webhooks
pub const SlackNotifier = struct {
    webhook_url: []const u8,
    username: ?[]const u8,
    channel: ?[]const u8,
    icon_emoji: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        webhook_url: []const u8,
        username: ?[]const u8,
        channel: ?[]const u8,
        icon_emoji: ?[]const u8,
    ) !*SlackNotifier {
        const self = try allocator.create(SlackNotifier);
        self.* = SlackNotifier{
            .webhook_url = try allocator.dupe(u8, webhook_url),
            .username = if (username) |u| try allocator.dupe(u8, u) else null,
            .channel = if (channel) |c| try allocator.dupe(u8, c) else null,
            .icon_emoji = if (icon_emoji) |i| try allocator.dupe(u8, i) else null,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *SlackNotifier) void {
        self.allocator.free(self.webhook_url);
        if (self.username) |u| self.allocator.free(u);
        if (self.channel) |c| self.allocator.free(c);
        if (self.icon_emoji) |i| self.allocator.free(i);
        self.allocator.destroy(self);
    }

    pub fn asNotifier(self: *SlackNotifier) Notifier {
        return Notifier{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendReport = sendReport,
                .deinit = deinitNotifier,
            },
        };
    }

    fn send(ptr: *anyopaque, notification: Notification) !void {
        const self: *SlackNotifier = @ptrCast(@alignCast(ptr));

        const color = self.getLevelColor(notification.level);

        // Build Slack message with attachment
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        const writer = payload.writer();
        try writer.writeAll("{");

        // Optional fields
        if (self.username) |username| {
            try writer.print("\"username\":\"{s}\",", .{username});
        }
        if (self.channel) |channel| {
            try writer.print("\"channel\":\"{s}\",", .{channel});
        }
        if (self.icon_emoji) |icon| {
            try writer.print("\"icon_emoji\":\"{s}\",", .{icon});
        }

        // Main text
        try writer.print("\"text\":\"*WatchZ Notification*\",", .{});

        // Attachment with details
        try writer.writeAll("\"attachments\":[{");
        try writer.print("\"color\":\"{s}\",", .{color});
        try writer.print("\"title\":\"{s}\",", .{notification.title});
        try writer.print("\"text\":\"{s}\",", .{notification.message});
        try writer.print("\"footer\":\"WatchZ\",", .{});
        try writer.print("\"ts\":{d}", .{notification.timestamp});
        try writer.writeAll("}]}");

        try self.sendWebhook(payload.items);
    }

    fn sendReport(ptr: *anyopaque, report: *const SessionReport) !void {
        const self: *SlackNotifier = @ptrCast(@alignCast(ptr));

        const color = switch (report.status) {
            .completed => "good",
            .partial_failure => "warning",
            .failed => "danger",
            .running => "#439FE0",
        };

        // Build Slack message
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        const writer = payload.writer();
        try writer.writeAll("{");

        // Optional fields
        if (self.username) |username| {
            try writer.print("\"username\":\"{s}\",", .{username});
        }
        if (self.channel) |channel| {
            try writer.print("\"channel\":\"{s}\",", .{channel});
        }
        if (self.icon_emoji) |icon| {
            try writer.print("\"icon_emoji\":\"{s}\",", .{icon});
        }

        // Main text
        try writer.print("\"text\":\"*WatchZ Update Session Report*\",", .{});

        // Attachment with report
        try writer.writeAll("\"attachments\":[{");
        try writer.print("\"color\":\"{s}\",", .{color});
        try writer.print("\"title\":\"Session {s} - {s}\",", .{ report.session_id, @tagName(report.status) });

        // Build fields
        try writer.writeAll("\"fields\":[");
        try writer.print("{{\"title\":\"Duration\",\"value\":\"{d}s\",\"short\":true}},", .{report.duration()});
        try writer.print("{{\"title\":\"Scanned\",\"value\":\"{d}\",\"short\":true}},", .{report.containers_scanned});
        try writer.print("{{\"title\":\"Updated\",\"value\":\"{d}\",\"short\":true}},", .{report.containers_updated});
        try writer.print("{{\"title\":\"Failed\",\"value\":\"{d}\",\"short\":true}}", .{report.containers_failed});
        try writer.writeAll("],");

        // Add container updates as text
        if (report.updates.items.len > 0) {
            try writer.writeAll("\"text\":\"");
            for (report.updates.items) |update| {
                try writer.print("• *{s}*: {s}\\n", .{ update.container_name, @tagName(update.status) });
            }
            try writer.writeAll("\",");
        }

        try writer.print("\"footer\":\"WatchZ\",", .{});
        try writer.print("\"ts\":{d}", .{report.start_time});
        try writer.writeAll("}]}");

        try self.sendWebhook(payload.items);
    }

    fn deinitNotifier(ptr: *anyopaque) void {
        const self: *SlackNotifier = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn getLevelColor(self: *SlackNotifier, level: NotificationLevel) []const u8 {
        _ = self;
        return switch (level) {
            .debug => "#CCCCCC",
            .info => "good", // green
            .warn => "warning", // yellow/orange
            .error_level => "danger", // red
        };
    }

    fn sendWebhook(self: *SlackNotifier, payload: []const u8) !void {
        const http_utils = HttpUtils.init(self.allocator);
        try http_utils.postJson(self.webhook_url, payload, null);
    }
};

/// Discord webhook notifier (very similar to Slack)
pub const DiscordNotifier = struct {
    webhook_url: []const u8,
    username: ?[]const u8,
    avatar_url: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        webhook_url: []const u8,
        username: ?[]const u8,
        avatar_url: ?[]const u8,
    ) !*DiscordNotifier {
        const self = try allocator.create(DiscordNotifier);
        self.* = DiscordNotifier{
            .webhook_url = try allocator.dupe(u8, webhook_url),
            .username = if (username) |u| try allocator.dupe(u8, u) else null,
            .avatar_url = if (avatar_url) |a| try allocator.dupe(u8, a) else null,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *DiscordNotifier) void {
        self.allocator.free(self.webhook_url);
        if (self.username) |u| self.allocator.free(u);
        if (self.avatar_url) |a| self.allocator.free(a);
        self.allocator.destroy(self);
    }

    pub fn asNotifier(self: *DiscordNotifier) Notifier {
        return Notifier{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendReport = sendReport,
                .deinit = deinitNotifier,
            },
        };
    }

    fn send(ptr: *anyopaque, notification: Notification) !void {
        const self: *DiscordNotifier = @ptrCast(@alignCast(ptr));

        const color = self.getLevelColor(notification.level);

        // Build Discord message with embed
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        const writer = payload.writer();
        try writer.writeAll("{");

        if (self.username) |username| {
            try writer.print("\"username\":\"{s}\",", .{username});
        }
        if (self.avatar_url) |avatar| {
            try writer.print("\"avatar_url\":\"{s}\",", .{avatar});
        }

        try writer.writeAll("\"embeds\":[{");
        try writer.print("\"title\":\"{s}\",", .{notification.title});
        try writer.print("\"description\":\"{s}\",", .{notification.message});
        try writer.print("\"color\":{d},", .{color});
        try writer.print("\"timestamp\":\"{d}\"", .{notification.timestamp});
        try writer.writeAll("}]}");

        try self.sendWebhook(payload.items);
    }

    fn sendReport(ptr: *anyopaque, report: *const SessionReport) !void {
        const self: *DiscordNotifier = @ptrCast(@alignCast(ptr));

        const formatted = try report.format(self.allocator);
        defer self.allocator.free(formatted);

        // Build Discord message
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try std.json.stringify(.{
            .username = self.username,
            .avatar_url = self.avatar_url,
            .content = formatted,
        }, .{}, payload.writer());

        try self.sendWebhook(payload.items);
    }

    fn deinitNotifier(ptr: *anyopaque) void {
        const self: *DiscordNotifier = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn getLevelColor(self: *DiscordNotifier, level: NotificationLevel) u32 {
        _ = self;
        return switch (level) {
            .debug => 0xCCCCCC,
            .info => 0x00FF00, // green
            .warn => 0xFFA500, // orange
            .error_level => 0xFF0000, // red
        };
    }

    fn sendWebhook(self: *DiscordNotifier, payload: []const u8) !void {
        const http_utils = HttpUtils.init(self.allocator);
        try http_utils.postJson(self.webhook_url, payload, null);
    }
};

test "slack notifier creation" {
    const allocator = std.testing.allocator;

    var slack = try SlackNotifier.init(
        allocator,
        "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX",
        "WatchZ",
        "#updates",
        ":robot:",
    );
    defer slack.deinit();

    try std.testing.expect(slack.username != null);
}
