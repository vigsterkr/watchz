const std = @import("std");
const docker_types = @import("../docker/types.zig");
const config = @import("../config.zig");
const log = @import("../utils/log.zig");

/// Label prefixes for Watchtower compatibility and WatchZ custom labels
const WATCHTOWER_PREFIX = "com.centurylinklabs.watchtower.";
const WATCHZ_PREFIX = "ing.wik.watchz.";

/// Get a container label, checking both Watchtower and WatchZ prefixes
/// Returns the value if found with either prefix, preferring WatchZ labels
fn getContainerLabel(container: *const docker_types.Container, suffix: []const u8) ?[]const u8 {
    // Build label names
    var watchz_label_buf: [128]u8 = undefined;
    const watchz_label = std.fmt.bufPrint(&watchz_label_buf, "{s}{s}", .{ WATCHZ_PREFIX, suffix }) catch return null;

    var watchtower_label_buf: [128]u8 = undefined;
    const watchtower_label = std.fmt.bufPrint(&watchtower_label_buf, "{s}{s}", .{ WATCHTOWER_PREFIX, suffix }) catch return null;

    // Check WatchZ label first (takes precedence)
    if (container.labels.get(watchz_label)) |value| {
        return value;
    }
    // Fall back to Watchtower label
    if (container.labels.get(watchtower_label)) |value| {
        return value;
    }
    return null;
}

/// Check if a label has a specific value (handles both prefixes)
fn hasLabelValue(container: *const docker_types.Container, suffix: []const u8, expected: []const u8) bool {
    if (getContainerLabel(container, suffix)) |value| {
        return std.mem.eql(u8, value, expected);
    }
    return false;
}

/// Container filter that implements Watchtower-compatible filtering
/// with additional support for custom WatchZ labels (ing.wik.watchz.*)
pub const ContainerFilter = struct {
    cfg: *const config.Config,

    pub fn init(cfg: *const config.Config) ContainerFilter {
        return .{ .cfg = cfg };
    }

    /// Determines if a container should be monitored/updated
    pub fn shouldWatch(self: ContainerFilter, container: *const docker_types.Container) bool {
        // 1. Check if container is in the name filter list (if specified)
        if (!self.matchesNameFilter(container)) {
            log.debug("Container {s} excluded by name filter", .{container.name});
            return false;
        }

        // 2. Check label-based filtering if enabled
        if (self.cfg.label_enable) {
            if (!self.hasEnableLabel(container)) {
                log.debug("Container {s} excluded by label filter (no enable label)", .{container.name});
                return false;
            }
        }

        // 3. Check if container is explicitly disabled via label
        if (self.isExplicitlyDisabled(container)) {
            log.debug("Container {s} explicitly disabled by label", .{container.name});
            return false;
        }

        // 4. Check scope filter
        if (!self.matchesScope(container)) {
            log.debug("Container {s} excluded by scope filter", .{container.name});
            return false;
        }

        // 5. Check if container should be monitored only (no updates)
        if (self.isMonitorOnly(container)) {
            log.debug("Container {s} is monitor-only", .{container.name});
            // Still return true, but caller should check this separately
        }

        return true;
    }

    /// Check if container is in monitor-only mode (via label or global config)
    pub fn isMonitorOnly(self: ContainerFilter, container: *const docker_types.Container) bool {
        if (self.cfg.monitor_only) {
            return true;
        }
        return hasLabelValue(container, "monitor-only", "true");
    }

    /// Check if container should skip image pulls (via label or global config)
    pub fn shouldPull(self: ContainerFilter, container: *const docker_types.Container) bool {
        if (self.cfg.no_pull) {
            return false;
        }
        return !hasLabelValue(container, "no-pull", "true");
    }

    /// Get custom stop signal for container (from labels)
    pub fn getStopSignal(self: ContainerFilter, container: *const docker_types.Container) ?[]const u8 {
        _ = self;
        return getContainerLabel(container, "stop-signal");
    }

    /// Check if container matches the name filter
    fn matchesNameFilter(self: ContainerFilter, container: *const docker_types.Container) bool {
        // If no container names specified, all containers match
        if (self.cfg.container_names.items.len == 0) {
            return true;
        }

        // Check if container name is in the filter list
        // Container names from Docker API start with "/", so we need to handle both cases
        const name = container.name;
        const name_without_slash = if (std.mem.startsWith(u8, name, "/")) name[1..] else name;

        for (self.cfg.container_names.items) |filter_name| {
            if (std.mem.eql(u8, name_without_slash, filter_name) or
                std.mem.eql(u8, name, filter_name))
            {
                return true;
            }
        }

        return false;
    }

    /// Check if container has the enable label (Watchtower or WatchZ)
    fn hasEnableLabel(self: ContainerFilter, container: *const docker_types.Container) bool {
        _ = self;
        return hasLabelValue(container, "enable", "true");
    }

    /// Check if container is explicitly disabled via label
    fn isExplicitlyDisabled(self: ContainerFilter, container: *const docker_types.Container) bool {
        _ = self;
        return hasLabelValue(container, "enable", "false");
    }

    /// Check if container matches the scope filter
    fn matchesScope(self: ContainerFilter, container: *const docker_types.Container) bool {
        // If no scope specified, all containers match
        const scope = self.cfg.scope orelse return true;
        return hasLabelValue(container, "scope", scope);
    }
};

/// Filter a list of containers based on the configuration
pub fn filterContainers(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    containers: []const docker_types.Container,
) !std.ArrayList(*const docker_types.Container) {
    var filtered: std.ArrayList(*const docker_types.Container) = .{};
    errdefer filtered.deinit(allocator);

    const filter = ContainerFilter.init(cfg);

    for (containers) |*container| {
        if (filter.shouldWatch(container)) {
            try filtered.append(allocator, container);
        }
    }

    return filtered;
}

test "filter by name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    try cfg.addContainerName("nginx");
    try cfg.addContainerName("redis");

    const filter = ContainerFilter.init(&cfg);

    // Create test container
    var container = docker_types.Container{
        .id = "abc123",
        .name = "/nginx",
        .image = "nginx:latest",
        .image_id = "sha256:123",
        .state = "running",
        .status = "Up 1 hour",
        .labels = std.StringHashMap([]const u8).init(allocator),
        .created = 0,
        .allocator = allocator,
    };
    defer container.labels.deinit();

    try testing.expect(filter.shouldWatch(&container));

    container.name = "/postgres";
    try testing.expect(!filter.shouldWatch(&container));
}

test "filter by enable label - watchtower" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    cfg.label_enable = true;

    const filter = ContainerFilter.init(&cfg);

    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();

    try labels.put("com.centurylinklabs.watchtower.enable", "true");

    var container = docker_types.Container{
        .id = "abc123",
        .name = "/nginx",
        .image = "nginx:latest",
        .image_id = "sha256:123",
        .state = "running",
        .status = "Up 1 hour",
        .labels = labels,
        .created = 0,
        .allocator = allocator,
    };

    try testing.expect(filter.shouldWatch(&container));
}

test "filter by enable label - watchz custom" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    cfg.label_enable = true;

    const filter = ContainerFilter.init(&cfg);

    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();

    try labels.put("ing.wik.watchz.enable", "true");

    var container = docker_types.Container{
        .id = "abc123",
        .name = "/nginx",
        .image = "nginx:latest",
        .image_id = "sha256:123",
        .state = "running",
        .status = "Up 1 hour",
        .labels = labels,
        .created = 0,
        .allocator = allocator,
    };

    try testing.expect(filter.shouldWatch(&container));
}

test "filter by scope" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    cfg.scope = "production";

    const filter = ContainerFilter.init(&cfg);

    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();

    try labels.put("ing.wik.watchz.scope", "production");

    var container = docker_types.Container{
        .id = "abc123",
        .name = "/nginx",
        .image = "nginx:latest",
        .image_id = "sha256:123",
        .state = "running",
        .status = "Up 1 hour",
        .labels = labels,
        .created = 0,
        .allocator = allocator,
    };

    try testing.expect(filter.shouldWatch(&container));

    var labels2 = std.StringHashMap([]const u8).init(allocator);
    defer labels2.deinit();
    try labels2.put("ing.wik.watchz.scope", "staging");

    container.labels = labels2;
    try testing.expect(!filter.shouldWatch(&container));
}
