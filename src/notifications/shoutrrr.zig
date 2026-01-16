const std = @import("std");
const notifier = @import("notifier.zig");
const Notifier = notifier.Notifier;
const WebhookNotifier = @import("webhook.zig").WebhookNotifier;
const EmailNotifier = @import("email.zig").EmailNotifier;
const SlackNotifier = @import("slack.zig").SlackNotifier;
const DiscordNotifier = @import("slack.zig").DiscordNotifier;

/// Shoutrrr URL format support for Watchtower compatibility
/// Format: service://[username[:password]@][host[:port]][/path][?query]
///
/// Examples:
///   - slack://token@channel
///   - discord://token@webhookid
///   - smtp://username:password@host:port/?from=sender@example.com&to=recipient@example.com
///   - generic://host:port/path
pub const ShoutrrrParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShoutrrrParser {
        return ShoutrrrParser{ .allocator = allocator };
    }

    /// Parse a Shoutrrr URL and create the appropriate notifier
    pub fn parseAndCreate(self: *ShoutrrrParser, url: []const u8) !Notifier {
        // Find the scheme (service type)
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidShoutrrrUrl;
        const scheme = url[0..scheme_end];
        const rest = url[scheme_end + 3 ..];

        if (std.mem.eql(u8, scheme, "slack")) {
            return try self.parseSlack(rest);
        } else if (std.mem.eql(u8, scheme, "discord")) {
            return try self.parseDiscord(rest);
        } else if (std.mem.eql(u8, scheme, "smtp") or std.mem.eql(u8, scheme, "email")) {
            return try self.parseEmail(rest);
        } else if (std.mem.eql(u8, scheme, "generic") or std.mem.eql(u8, scheme, "webhook")) {
            return try self.parseWebhook(url);
        } else {
            std.log.warn("Unknown Shoutrrr service: {s}, treating as generic webhook", .{scheme});
            return try self.parseWebhook(url);
        }
    }

    fn parseSlack(self: *ShoutrrrParser, rest: []const u8) !Notifier {
        // Format: slack://token@channel or slack://token@channel?username=foo

        // Split at @
        const at_pos = std.mem.indexOf(u8, rest, "@") orelse return error.InvalidSlackUrl;
        const token = rest[0..at_pos];
        const after_at = rest[at_pos + 1 ..];

        // Split channel and query string
        var channel: []const u8 = after_at;
        var query: ?[]const u8 = null;
        if (std.mem.indexOf(u8, after_at, "?")) |q_pos| {
            channel = after_at[0..q_pos];
            query = after_at[q_pos + 1 ..];
        }

        // Build webhook URL
        const webhook_url = try std.fmt.allocPrint(
            self.allocator,
            "https://hooks.slack.com/services/{s}",
            .{token},
        );
        errdefer self.allocator.free(webhook_url);

        // Parse query parameters
        var username: ?[]const u8 = null;
        var icon: ?[]const u8 = null;

        if (query) |q| {
            var params = QueryParser.init(q);
            while (params.next()) |param| {
                if (std.mem.eql(u8, param.key, "username")) {
                    username = param.value;
                } else if (std.mem.eql(u8, param.key, "icon")) {
                    icon = param.value;
                }
            }
        }

        const slack = try SlackNotifier.init(
            self.allocator,
            webhook_url,
            username,
            channel,
            icon,
        );
        self.allocator.free(webhook_url);

        return slack.asNotifier();
    }

    fn parseDiscord(self: *ShoutrrrParser, rest: []const u8) !Notifier {
        // Format: discord://token@webhookid or discord://token@webhookid?username=foo

        const at_pos = std.mem.indexOf(u8, rest, "@") orelse return error.InvalidDiscordUrl;
        const token = rest[0..at_pos];
        const after_at = rest[at_pos + 1 ..];

        var webhook_id: []const u8 = after_at;
        var query: ?[]const u8 = null;
        if (std.mem.indexOf(u8, after_at, "?")) |q_pos| {
            webhook_id = after_at[0..q_pos];
            query = after_at[q_pos + 1 ..];
        }

        // Build Discord webhook URL
        const webhook_url = try std.fmt.allocPrint(
            self.allocator,
            "https://discord.com/api/webhooks/{s}/{s}",
            .{ webhook_id, token },
        );
        errdefer self.allocator.free(webhook_url);

        var username: ?[]const u8 = null;
        var avatar: ?[]const u8 = null;

        if (query) |q| {
            var params = QueryParser.init(q);
            while (params.next()) |param| {
                if (std.mem.eql(u8, param.key, "username")) {
                    username = param.value;
                } else if (std.mem.eql(u8, param.key, "avatar")) {
                    avatar = param.value;
                }
            }
        }

        const discord = try DiscordNotifier.init(
            self.allocator,
            webhook_url,
            username,
            avatar,
        );
        self.allocator.free(webhook_url);

        return discord.asNotifier();
    }

    fn parseEmail(self: *ShoutrrrParser, rest: []const u8) !Notifier {
        // Format: smtp://username:password@host:port/?from=sender@example.com&to=recipient@example.com

        // Parse credentials if present
        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var host_part: []const u8 = rest;

        if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
            const creds = rest[0..at_pos];
            host_part = rest[at_pos + 1 ..];

            if (std.mem.indexOf(u8, creds, ":")) |colon_pos| {
                username = creds[0..colon_pos];
                password = creds[colon_pos + 1 ..];
            } else {
                username = creds;
            }
        }

        // Parse host and port
        var host: []const u8 = host_part;
        var port: u16 = 25; // Default SMTP port
        var query: ?[]const u8 = null;

        // Extract query string if present
        if (std.mem.indexOf(u8, host_part, "?")) |q_pos| {
            host = host_part[0..q_pos];
            query = host_part[q_pos + 1 ..];
        }

        // Parse host:port
        if (std.mem.indexOf(u8, host, ":")) |colon_pos| {
            const port_str = host[colon_pos + 1 ..];
            host = host[0..colon_pos];
            port = std.fmt.parseInt(u16, port_str, 10) catch 25;
        }

        // Parse required email parameters from query
        var from: ?[]const u8 = null;
        var to: ?[]const u8 = null;
        var use_tls = true;

        if (query) |q| {
            var params = QueryParser.init(q);
            while (params.next()) |param| {
                if (std.mem.eql(u8, param.key, "from")) {
                    from = param.value;
                } else if (std.mem.eql(u8, param.key, "to")) {
                    to = param.value;
                } else if (std.mem.eql(u8, param.key, "tls")) {
                    use_tls = std.mem.eql(u8, param.value, "true");
                }
            }
        }

        if (from == null or to == null) {
            return error.EmailMissingRequiredParams;
        }

        const email = try EmailNotifier.init(
            self.allocator,
            host,
            port,
            from.?,
            to.?,
            username,
            password,
            use_tls,
        );

        return email.asNotifier();
    }

    fn parseWebhook(self: *ShoutrrrParser, url: []const u8) !Notifier {
        // Generic webhook - just use the URL as-is
        const webhook = try WebhookNotifier.init(self.allocator, url);
        return webhook.asNotifier();
    }
};

/// Simple query string parser
const QueryParser = struct {
    query: []const u8,
    pos: usize = 0,

    const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    fn init(query: []const u8) QueryParser {
        return QueryParser{ .query = query };
    }

    fn next(self: *QueryParser) ?Param {
        if (self.pos >= self.query.len) return null;

        // Find next & or end of string
        const start = self.pos;
        const end = std.mem.indexOfPos(u8, self.query, self.pos, "&") orelse self.query.len;
        self.pos = if (end < self.query.len) end + 1 else self.query.len;

        const param_str = self.query[start..end];

        // Split on =
        const eq_pos = std.mem.indexOf(u8, param_str, "=") orelse return null;

        return Param{
            .key = param_str[0..eq_pos],
            .value = param_str[eq_pos + 1 ..],
        };
    }
};

test "parse slack shoutrrr url" {
    const allocator = std.testing.allocator;
    var parser = ShoutrrrParser.init(allocator);

    const url = "slack://T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX@#updates";
    var notif = try parser.parseAndCreate(url);
    defer notif.deinit();
}

test "parse email shoutrrr url" {
    const allocator = std.testing.allocator;
    var parser = ShoutrrrParser.init(allocator);

    const url = "smtp://user:pass@smtp.example.com:587/?from=sender@example.com&to=recipient@example.com";
    var notif = try parser.parseAndCreate(url);
    defer notif.deinit();
}

test "query parser" {
    var parser = QueryParser.init("key1=value1&key2=value2&key3=value3");

    const param1 = parser.next().?;
    try std.testing.expectEqualStrings("key1", param1.key);
    try std.testing.expectEqualStrings("value1", param1.value);

    const param2 = parser.next().?;
    try std.testing.expectEqualStrings("key2", param2.key);
    try std.testing.expectEqualStrings("value2", param2.value);

    const param3 = parser.next().?;
    try std.testing.expectEqualStrings("key3", param3.key);
    try std.testing.expectEqualStrings("value3", param3.value);

    try std.testing.expect(parser.next() == null);
}
