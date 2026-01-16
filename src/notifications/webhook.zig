const std = @import("std");
const notifier = @import("notifier.zig");
const Notifier = notifier.Notifier;
const Notification = notifier.Notification;
const SessionReport = @import("../session/report.zig").SessionReport;
const HttpUtils = @import("../utils/http.zig").HttpUtils;

/// Generic webhook notifier that sends HTTP POST requests
pub const WebhookNotifier = struct {
    url: []const u8,
    allocator: std.mem.Allocator,
    headers: ?std.StringHashMap([]const u8) = null,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !*WebhookNotifier {
        const self = try allocator.create(WebhookNotifier);
        self.* = WebhookNotifier{
            .url = try allocator.dupe(u8, url),
            .allocator = allocator,
            .headers = null,
        };
        return self;
    }

    pub fn deinit(self: *WebhookNotifier) void {
        self.allocator.free(self.url);
        if (self.headers) |*h| {
            var it = h.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            h.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn addHeader(self: *WebhookNotifier, key: []const u8, value: []const u8) !void {
        if (self.headers == null) {
            self.headers = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.headers.?.put(owned_key, owned_value);
    }

    pub fn asNotifier(self: *WebhookNotifier) Notifier {
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
        const self: *WebhookNotifier = @ptrCast(@alignCast(ptr));

        // Build JSON payload
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try std.json.stringify(.{
            .level = @tagName(notification.level),
            .title = notification.title,
            .message = notification.message,
            .timestamp = notification.timestamp,
        }, .{}, payload.writer());

        try self.sendPost(payload.items);
    }

    fn sendReport(ptr: *anyopaque, report: *const SessionReport) !void {
        const self: *WebhookNotifier = @ptrCast(@alignCast(ptr));

        // Format report as plain text
        const formatted = try report.format(self.allocator);
        defer self.allocator.free(formatted);

        // Build JSON payload with report
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try std.json.stringify(.{
            .type = "session_report",
            .session_id = report.session_id,
            .status = @tagName(report.status),
            .containers_scanned = report.containers_scanned,
            .containers_updated = report.containers_updated,
            .containers_failed = report.containers_failed,
            .duration = report.duration(),
            .report = formatted,
        }, .{}, payload.writer());

        try self.sendPost(payload.items);
    }

    fn deinitNotifier(ptr: *anyopaque) void {
        const self: *WebhookNotifier = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendPost(self: *WebhookNotifier, body: []const u8) !void {
        const http_utils = HttpUtils.init(self.allocator);
        try http_utils.postJson(self.url, body, self.headers);
    }
};

test "webhook notifier creation" {
    const allocator = std.testing.allocator;

    var webhook = try WebhookNotifier.init(allocator, "http://example.com/webhook");
    defer webhook.deinit();

    try std.testing.expectEqualStrings("http://example.com/webhook", webhook.url);
}
