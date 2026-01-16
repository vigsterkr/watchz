const std = @import("std");

// Import notification modules
const notifier = @import("../src/notifications/notifier.zig");
const webhook = @import("../src/notifications/webhook.zig");
const email = @import("../src/notifications/email.zig");
const slack = @import("../src/notifications/slack.zig");
const shoutrrr = @import("../src/notifications/shoutrrr.zig");
const session_mod = @import("../src/session/session.zig");
const report_mod = @import("../src/session/report.zig");

const Notification = notifier.Notification;
const NotificationLevel = notifier.NotificationLevel;
const NotificationManager = notifier.NotificationManager;
const SessionReport = report_mod.SessionReport;
const ContainerUpdate = report_mod.ContainerUpdate;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("WatchZ Notification System Demo", .{});
    std.log.info("=================================\n", .{});

    // Create notification manager
    var manager = NotificationManager.init(allocator, .info, true);
    defer manager.deinit();

    std.log.info("1. Testing Shoutrrr URL Parser", .{});
    std.log.info("-------------------------------", .{});

    var parser = shoutrrr.ShoutrrrParser.init(allocator);

    // Example Shoutrrr URLs (these won't actually send, just parse)
    const example_urls = [_][]const u8{
        "webhook://example.com/hook",
        // Uncomment these to test parsing (but they won't send without valid credentials)
        // "slack://T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX@#updates?username=WatchZ",
        // "discord://webhook_id@token?username=WatchZ",
        // "smtp://user:pass@smtp.example.com:587/?from=watchz@example.com&to=admin@example.com",
    };

    for (example_urls) |url| {
        std.log.info("  Parsing: {s}", .{url});
        const parsed_notifier = parser.parseAndCreate(url) catch |err| {
            std.log.warn("  Failed to parse: {}", .{err});
            continue;
        };
        defer parsed_notifier.deinit();
        std.log.info("  ✓ Successfully parsed", .{});
    }

    std.log.info("\n2. Creating a Mock Session Report", .{});
    std.log.info("-----------------------------------", .{});

    // Create a session report
    var session = try SessionReport.init(allocator, "demo-session-12345");
    defer session.deinit();

    session.containers_scanned = 5;
    session.containers_with_updates = 2;
    session.containers_updated = 2;
    session.containers_failed = 0;

    // Add some container updates
    var update1 = try ContainerUpdate.init(
        allocator,
        "nginx-web",
        "abc123def456",
        "nginx:latest",
        .success,
    );
    try update1.setDigests(
        "sha256:old1234567890abcdef",
        "sha256:new1234567890abcdef",
    );
    try session.addUpdate(update1);

    var update2 = try ContainerUpdate.init(
        allocator,
        "redis-cache",
        "xyz789ghi012",
        "redis:7-alpine",
        .success,
    );
    try update2.setDigests(
        "sha256:oldredis1234567890",
        "sha256:newredis1234567890",
    );
    try session.addUpdate(update2);

    session.complete();

    std.log.info("Session ID: {s}", .{session.session_id});
    std.log.info("Status: {s}", .{@tagName(session.status)});
    std.log.info("Duration: {d}s", .{session.duration()});
    std.log.info("Containers scanned: {d}", .{session.containers_scanned});
    std.log.info("Containers updated: {d}", .{session.containers_updated});

    std.log.info("\n3. Formatted Session Report", .{});
    std.log.info("----------------------------", .{});

    const formatted = try session.format(allocator);
    defer allocator.free(formatted);
    std.log.info("\n{s}", .{formatted});

    std.log.info("\n4. Testing Notification Manager", .{});
    std.log.info("---------------------------------", .{});

    // Send a simple notification
    manager.notifyText(.info, "Test Notification", "This is a test message from WatchZ");
    std.log.info("✓ Simple notification sent", .{});

    // Send a notification about a container update
    manager.notifyUpdate(&session.updates.items[0]);
    std.log.info("✓ Container update notification sent", .{});

    std.log.info("\n5. Notification Levels", .{});
    std.log.info("----------------------", .{});

    const levels = [_]NotificationLevel{ .debug, .info, .warn, .error_level };
    for (levels) |level| {
        std.log.info("{s}: priority {d}", .{ @tagName(level), level.priority() });
    }

    std.log.info("\nDemo completed successfully!", .{});
}
