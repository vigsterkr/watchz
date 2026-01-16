const std = @import("std");
const notifier = @import("notifier.zig");
const Notifier = notifier.Notifier;
const Notification = notifier.Notification;
const SessionReport = @import("../session/report.zig").SessionReport;
const encoding = @import("../utils/encoding.zig");

/// Email notification backend using SMTP
pub const EmailNotifier = struct {
    smtp_host: []const u8,
    smtp_port: u16,
    from: []const u8,
    to: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    use_tls: bool,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        smtp_host: []const u8,
        smtp_port: u16,
        from: []const u8,
        to: []const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        use_tls: bool,
    ) !*EmailNotifier {
        const self = try allocator.create(EmailNotifier);
        self.* = EmailNotifier{
            .smtp_host = try allocator.dupe(u8, smtp_host),
            .smtp_port = smtp_port,
            .from = try allocator.dupe(u8, from),
            .to = try allocator.dupe(u8, to),
            .username = if (username) |u| try allocator.dupe(u8, u) else null,
            .password = if (password) |p| try allocator.dupe(u8, p) else null,
            .use_tls = use_tls,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *EmailNotifier) void {
        self.allocator.free(self.smtp_host);
        self.allocator.free(self.from);
        self.allocator.free(self.to);
        if (self.username) |u| self.allocator.free(u);
        if (self.password) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    pub fn asNotifier(self: *EmailNotifier) Notifier {
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
        const self: *EmailNotifier = @ptrCast(@alignCast(ptr));

        const subject = try std.fmt.allocPrint(
            self.allocator,
            "[WatchZ {s}] {s}",
            .{ @tagName(notification.level), notification.title },
        );
        defer self.allocator.free(subject);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "Level: {s}\nTime: {d}\n\n{s}",
            .{ @tagName(notification.level), notification.timestamp, notification.message },
        );
        defer self.allocator.free(body);

        try self.sendEmail(subject, body);
    }

    fn sendReport(ptr: *anyopaque, report: *const SessionReport) !void {
        const self: *EmailNotifier = @ptrCast(@alignCast(ptr));

        const subject = try std.fmt.allocPrint(
            self.allocator,
            "[WatchZ] Update Session Report - {s}",
            .{@tagName(report.status)},
        );
        defer self.allocator.free(subject);

        const body = try report.format(self.allocator);
        defer self.allocator.free(body);

        try self.sendEmail(subject, body);
    }

    fn deinitNotifier(ptr: *anyopaque) void {
        const self: *EmailNotifier = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendEmail(self: *EmailNotifier, subject: []const u8, body: []const u8) !void {
        // Connect to SMTP server
        const address = try std.net.Address.parseIp(self.smtp_host, self.smtp_port);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        var buffered_stream = std.io.bufferedReader(stream.reader());
        const reader = buffered_stream.reader();
        const writer = stream.writer();

        // Read greeting (220)
        try self.readResponse(reader, "220");

        // Send EHLO
        try writer.print("EHLO localhost\r\n", .{});
        try self.readResponse(reader, "250");

        // Authenticate if credentials provided
        if (self.username != null and self.password != null) {
            try self.authenticate(reader, writer);
        }

        // MAIL FROM
        try writer.print("MAIL FROM:<{s}>\r\n", .{self.from});
        try self.readResponse(reader, "250");

        // RCPT TO
        try writer.print("RCPT TO:<{s}>\r\n", .{self.to});
        try self.readResponse(reader, "250");

        // DATA
        try writer.print("DATA\r\n", .{});
        try self.readResponse(reader, "354");

        // Email headers and body
        try writer.print("From: {s}\r\n", .{self.from});
        try writer.print("To: {s}\r\n", .{self.to});
        try writer.print("Subject: {s}\r\n", .{subject});
        try writer.print("Content-Type: text/plain; charset=utf-8\r\n", .{});
        try writer.print("\r\n", .{});
        try writer.print("{s}\r\n", .{body});
        try writer.print(".\r\n", .{});
        try self.readResponse(reader, "250");

        // QUIT
        try writer.print("QUIT\r\n", .{});
        try self.readResponse(reader, "221");

        std.log.debug("Email sent successfully to {s}", .{self.to});
    }

    fn authenticate(self: *EmailNotifier, reader: anytype, writer: anytype) !void {
        // Simple AUTH LOGIN implementation
        try writer.print("AUTH LOGIN\r\n", .{});
        try self.readResponse(reader, "334");

        // Send base64-encoded username
        const username_b64 = try encoding.base64Encode(self.allocator, self.username.?);
        defer self.allocator.free(username_b64);
        try writer.print("{s}\r\n", .{username_b64});
        try self.readResponse(reader, "334");

        // Send base64-encoded password
        const password_b64 = try encoding.base64Encode(self.allocator, self.password.?);
        defer self.allocator.free(password_b64);
        try writer.print("{s}\r\n", .{password_b64});
        try self.readResponse(reader, "235");
    }

    fn readResponse(self: *EmailNotifier, reader: anytype, expected_code: []const u8) !void {
        _ = self;
        var buffer: [512]u8 = undefined;
        const line = try reader.readUntilDelimiter(&buffer, '\n');

        // Check if response starts with expected code
        if (line.len < expected_code.len or !std.mem.eql(u8, line[0..expected_code.len], expected_code)) {
            std.log.err("SMTP error: expected {s}, got: {s}", .{ expected_code, line });
            return error.SmtpError;
        }
    }
};

test "email notifier creation" {
    const allocator = std.testing.allocator;

    var email = try EmailNotifier.init(
        allocator,
        "smtp.example.com",
        587,
        "from@example.com",
        "to@example.com",
        null,
        null,
        false,
    );
    defer email.deinit();

    try std.testing.expectEqualStrings("smtp.example.com", email.smtp_host);
    try std.testing.expectEqual(@as(u16, 587), email.smtp_port);
}
