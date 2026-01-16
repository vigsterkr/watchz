const std = @import("std");
const log = @import("utils/log.zig");
const notifier = @import("notifications/notifier.zig");

pub const Config = struct {
    // Docker options
    docker_host: []const u8 = "unix:///var/run/docker.sock",
    api_version: []const u8 = "1.24",
    tls_verify: bool = false,

    // Scheduling
    poll_interval: u64 = 86400, // 24 hours in seconds
    run_once: bool = false,

    // Container selection
    container_names: std.ArrayList([]const u8),
    include_stopped: bool = false,
    revive_stopped: bool = false,
    label_enable: bool = false,
    scope: ?[]const u8 = null,

    // Update behavior
    cleanup: bool = false,
    no_pull: bool = false,
    no_restart: bool = false,
    monitor_only: bool = false,
    rolling_restart: bool = false,
    stop_timeout: u64 = 10, // seconds

    // Logging
    log_level: log.Level = .info,

    // Notification options
    notification_urls: std.ArrayList([]const u8),
    notification_level: notifier.NotificationLevel = .info,
    notification_report: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .container_names = .{},
            .notification_urls = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.container_names.items) |name| {
            self.allocator.free(name);
        }
        self.container_names.deinit(self.allocator);

        for (self.notification_urls.items) |url| {
            self.allocator.free(url);
        }
        self.notification_urls.deinit(self.allocator);
    }

    pub fn addContainerName(self: *Config, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        try self.container_names.append(self.allocator, owned);
    }

    pub fn addNotificationUrl(self: *Config, url: []const u8) !void {
        const owned = try self.allocator.dupe(u8, url);
        try self.notification_urls.append(self.allocator, owned);
    }

    pub fn parseDockerHost(self: *Config) !DockerHost {
        if (std.mem.startsWith(u8, self.docker_host, "unix://")) {
            return DockerHost{
                .unix_socket = self.docker_host[7..], // Skip "unix://"
            };
        } else if (std.mem.startsWith(u8, self.docker_host, "tcp://")) {
            return DockerHost{
                .tcp = self.docker_host[6..], // Skip "tcp://"
            };
        } else {
            return error.InvalidDockerHost;
        }
    }
};

pub const DockerHost = union(enum) {
    unix_socket: []const u8,
    tcp: []const u8,
};
