const std = @import("std");
const zio = @import("zio");
const config = @import("config.zig");
const docker_client = @import("docker/client.zig");
const registry_client = @import("registry/client.zig");
const log = @import("utils/log.zig");
const env = @import("utils/env.zig");
const filter = @import("container/filter.zig");
const notifier = @import("notifications/notifier.zig");
const updater_mod = @import("container/updater.zig");
const scheduler_mod = @import("scheduler/scheduler.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments and environment variables
    var cfg = try parseArgs(allocator);
    defer cfg.deinit();

    // Set log level
    log.setLevel(cfg.log_level);

    log.info("WatchZ v0.1.0 - Docker Container Update Monitor (Async)", .{});
    log.info("Docker host: {s}", .{cfg.docker_host});
    log.info("Poll interval: {d} seconds", .{cfg.poll_interval});

    // Initialize zio runtime
    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    // Spawn the main task
    var main_task = try rt.spawn(mainTask, .{ rt, &cfg }, .{});
    try main_task.join(rt);
}

fn mainTask(rt: *zio.Runtime, cfg: *config.Config) !void {
    const allocator = cfg.allocator;

    // Parse docker host
    const docker_host = try cfg.parseDockerHost();
    const socket_path = switch (docker_host) {
        .unix_socket => |path| path,
        .tcp => {
            log.err("TCP connections not yet supported with async client", .{});
            return error.UnsupportedConnection;
        },
    };

    // Create Docker client
    var client = docker_client.AsyncClient.init(allocator, socket_path, cfg.api_version);

    // Create Registry client
    var reg_client = registry_client.RegistryClient.init(allocator);
    defer reg_client.deinit();

    // Load Docker credentials from ~/.docker/config.json
    log.debug("Loading Docker credentials...", .{});
    reg_client.authenticator.loadFromDockerConfig() catch |err| {
        log.debug("Could not load Docker config: {}", .{err});
    };

    // Count loaded credentials
    var cred_count: usize = 0;
    var reg_iter = reg_client.authenticator.config.iterator();
    while (reg_iter.next()) |_| {
        cred_count += 1;
    }
    if (cred_count > 0) {
        log.info("Loaded credentials for {d} registry(ies)", .{cred_count});
    }

    // Negotiate API version with Docker daemon
    log.info("Connecting to Docker daemon...", .{});
    try client.negotiateApiVersion(rt);

    // Test connection
    try client.ping(rt);

    // Get Docker version
    var version = try client.getVersion(rt);
    defer version.deinit();

    log.info("Docker version: {s}", .{version.version});
    log.info("API version: {s}", .{version.api_version});
    log.info("Platform: {s}/{s}", .{ version.os, version.arch });

    // Run once or continuously
    if (cfg.run_once) {
        log.info("Running once and exiting...", .{});
        try checkAndUpdateTask(rt, &client, &reg_client, cfg);
    } else {
        log.info("Starting scheduler with {d}s interval", .{cfg.poll_interval});
        var scheduler = scheduler_mod.Scheduler.init(allocator, cfg.poll_interval);
        try scheduler.runPeriodic(rt, checkAndUpdateTask, .{ rt, &client, &reg_client, cfg });
    }
}

fn checkAndUpdateTask(
    rt: *zio.Runtime,
    client: *docker_client.AsyncClient,
    reg_client: *registry_client.RegistryClient,
    cfg: *config.Config,
) !void {
    const allocator = cfg.allocator;

    log.info("Checking for container updates...", .{});

    // List containers
    const containers = try client.listContainers(rt, cfg.include_stopped);
    defer {
        for (containers) |*c| c.deinit();
        allocator.free(containers);
    }

    log.info("Found {d} container(s)", .{containers.len});

    // Apply filters to determine which containers to watch
    var filtered = try filter.filterContainers(allocator, cfg, containers);
    defer filtered.deinit(allocator);

    log.info("After filtering: {d} container(s) to watch", .{filtered.items.len});

    const container_filter = filter.ContainerFilter.init(cfg);

    // Display container status
    for (containers) |container| {
        const is_watched = for (filtered.items) |f| {
            if (std.mem.eql(u8, f.id, container.id)) break true;
        } else false;

        const watch_status = if (is_watched) "✓ WATCHING" else "✗ EXCLUDED";
        log.info("  {s} {s} ({s}): {s} [{s}]", .{
            watch_status,
            container.name,
            container.id[0..@min(12, container.id.len)],
            container.image,
            container.state,
        });

        if (is_watched) {
            const monitor_only = container_filter.isMonitorOnly(&container);
            const should_pull = container_filter.shouldPull(&container);

            if (monitor_only) {
                log.info("      Mode: MONITOR-ONLY (detection only)", .{});
            }
            if (!should_pull) {
                log.info("      Pull: DISABLED (no-pull label)", .{});
            }
        }
    }

    if (filtered.items.len == 0) {
        log.info("No containers to watch", .{});
        return;
    }

    // Check for updates (always, regardless of monitor-only mode)
    log.info("Checking for available updates...", .{});

    var updater = updater_mod.ContainerUpdater.init(allocator, client, reg_client, cfg, null);

    // Check which containers need updates
    const ContainerPtr = *const @TypeOf(containers[0]);
    var containers_to_update: std.ArrayList(ContainerPtr) = .{};
    defer containers_to_update.deinit(allocator);

    for (filtered.items) |filtered_container| {
        // Find the full container object
        for (containers) |*container| {
            if (std.mem.eql(u8, container.id, filtered_container.id)) {
                if (updater.needsUpdate(rt, container) catch false) {
                    try containers_to_update.append(allocator, container);
                }
                break;
            }
        }
    }

    if (containers_to_update.items.len > 0) {
        log.info("Found {d} container(s) with updates available:", .{containers_to_update.items.len});

        // List containers with updates
        for (containers_to_update.items) |container| {
            log.info("  📦 {s} - update available", .{container.name});
        }

        // Only perform updates if NOT in monitor-only mode
        if (!cfg.monitor_only) {
            log.info("Applying updates to {d} container(s)...", .{containers_to_update.items.len});

            // Convert to slice
            const to_update_slice = try allocator.alloc(@TypeOf(containers[0]), containers_to_update.items.len);
            defer allocator.free(to_update_slice);

            for (containers_to_update.items, 0..) |container, i| {
                to_update_slice[i] = container.*;
            }

            const results = try updater.updateContainers(rt, to_update_slice);
            defer {
                for (results) |*r| r.deinit();
                allocator.free(results);
            }

            // Report results
            var success_count: usize = 0;
            var failure_count: usize = 0;
            for (results) |result| {
                if (result.success) {
                    success_count += 1;
                    log.info("✓ {s} updated successfully", .{result.container_name});
                } else {
                    failure_count += 1;
                    log.err("✗ {s} failed: {s}", .{
                        result.container_name,
                        result.error_msg orelse "unknown error",
                    });
                }
            }

            log.info("Update complete: {d} succeeded, {d} failed", .{ success_count, failure_count });
        } else {
            log.info("=== DRY RUN MODE ===", .{});
            log.info("Monitor-only mode: Updates detected but NOT applied", .{});
            log.info("Remove --monitor-only flag to apply these updates", .{});
            log.info("===================", .{});
        }
    } else {
        log.info("All containers are up to date ✓", .{});
    }
}

fn parseArgs(allocator: std.mem.Allocator) !config.Config {
    var cfg = config.Config.init(allocator);
    errdefer cfg.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            cfg.log_level = .debug;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            cfg.log_level = .trace;
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--include-stopped")) {
            cfg.include_stopped = true;
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--run-once")) {
            cfg.run_once = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cleanup")) {
            cfg.cleanup = true;
        } else if (std.mem.eql(u8, arg, "--monitor-only")) {
            cfg.monitor_only = true;
        } else if (std.mem.eql(u8, arg, "--no-pull")) {
            cfg.no_pull = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interval")) {
            const value = args.next() orelse return error.MissingValue;
            cfg.poll_interval = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            const value = args.next() orelse return error.MissingValue;
            cfg.docker_host = value;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--api-version")) {
            const value = args.next() orelse return error.MissingValue;
            cfg.api_version = value;
        } else if (std.mem.eql(u8, arg, "--tlsverify")) {
            cfg.tls_verify = true;
        } else if (std.mem.eql(u8, arg, "--scope")) {
            const value = args.next() orelse return error.MissingValue;
            cfg.scope = value;
        } else if (std.mem.eql(u8, arg, "--label-enable")) {
            cfg.label_enable = true;
        } else if (std.mem.eql(u8, arg, "--revive-stopped")) {
            cfg.revive_stopped = true;
        } else if (std.mem.eql(u8, arg, "--no-restart")) {
            cfg.no_restart = true;
        } else if (std.mem.eql(u8, arg, "--rolling-restart")) {
            cfg.rolling_restart = true;
        } else if (std.mem.eql(u8, arg, "--stop-timeout")) {
            const value = args.next() orelse return error.MissingValue;
            cfg.stop_timeout = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            log.err("Unknown option: {s}", .{arg});
            return error.UnknownOption;
        } else {
            // Container name
            try cfg.addContainerName(arg);
        }
    }

    // Check environment variables as fallback
    if (env.getStringEnv(allocator, "DOCKER_HOST")) |host| {
        if (std.mem.eql(u8, cfg.docker_host, "unix:///var/run/docker.sock")) {
            cfg.docker_host = host; // Transfer ownership to config
        } else {
            allocator.free(host);
        }
    }

    // WATCHZ_POLL_INTERVAL
    if (env.getU64Env(allocator, "WATCHZ_POLL_INTERVAL")) |interval| {
        cfg.poll_interval = interval;
    }

    // WATCHZ_DEBUG
    if (env.getBoolEnv(allocator, "WATCHZ_DEBUG")) |debug| {
        if (debug) cfg.log_level = .debug;
    }

    // WATCHZ_CLEANUP
    if (env.getBoolEnv(allocator, "WATCHZ_CLEANUP")) |cleanup| {
        cfg.cleanup = cleanup;
    }

    // WATCHZ_LABEL_ENABLE
    if (env.getBoolEnv(allocator, "WATCHZ_LABEL_ENABLE")) |label_enable| {
        cfg.label_enable = label_enable;
    }

    // WATCHZ_MONITOR_ONLY
    if (env.getBoolEnv(allocator, "WATCHZ_MONITOR_ONLY")) |monitor_only| {
        cfg.monitor_only = monitor_only;
    }

    // WATCHZ_SCOPE
    if (env.getStringEnv(allocator, "WATCHZ_SCOPE")) |scope| {
        cfg.scope = scope; // Transfer ownership to config
    }

    // WATCHZ_NOTIFICATION_URL (can be comma-separated for multiple URLs)
    {
        var url_list = try env.getStringListEnv(allocator, "WATCHZ_NOTIFICATION_URL");
        defer {
            for (url_list.items) |url| allocator.free(url);
            url_list.deinit(allocator);
        }
        for (url_list.items) |url| {
            try cfg.addNotificationUrl(url);
        }
    }

    // WATCHZ_NOTIFICATION_LEVEL
    if (env.getStringEnv(allocator, "WATCHZ_NOTIFICATION_LEVEL")) |value| {
        defer allocator.free(value);
        if (notifier.NotificationLevel.fromString(value)) |parsed| {
            cfg.notification_level = parsed;
        } else {
            log.warn("Invalid WATCHZ_NOTIFICATION_LEVEL value '{s}'", .{value});
        }
    }

    // WATCHZ_NOTIFICATION_REPORT
    if (env.getBoolEnv(allocator, "WATCHZ_NOTIFICATION_REPORT")) |report| {
        cfg.notification_report = report;
    }

    return cfg;
}

fn printHelp() !void {
    std.debug.print(
        \\WatchZ v0.1.0 - Docker Container Update Monitor (Async with ZIO)
        \\
        \\USAGE: watchz [OPTIONS] [CONTAINER_NAMES...]
        \\
        \\OPTIONS:
        \\  -h, --help                    Show this help message
        \\  -d, --debug                   Enable debug logging
        \\  --trace                       Enable trace logging
        \\  -i, --interval <SECONDS>      Poll interval (default: 86400)
        \\  -c, --cleanup                 Remove old images after update
        \\  -R, --run-once                Run once and exit
        \\  -S, --include-stopped         Include stopped containers
        \\  --revive-stopped              Restart stopped containers if updated
        \\  --monitor-only                Only monitor, don't update
        \\  --no-pull                     Don't pull new images
        \\  --no-restart                  Don't restart containers after update
        \\  --rolling-restart             Restart one container at a time
        \\  --stop-timeout <SECONDS>      Timeout for stopping containers (default: 10)
        \\  --label-enable                Only update containers with enable label
        \\  --scope <SCOPE>               Filter by scope label
        \\
        \\DOCKER OPTIONS:
        \\  -H, --host <HOST>             Docker host (default: unix:///var/run/docker.sock)
        \\  -a, --api-version <VERSION>   Docker API version (default: 1.24)
        \\  --tlsverify                   Use TLS and verify certificate
        \\
        \\LABELS (Watchtower Compatible + WatchZ Custom):
        \\  Watchtower labels:
        \\    com.centurylinklabs.watchtower.enable=true/false
        \\    com.centurylinklabs.watchtower.monitor-only=true
        \\    com.centurylinklabs.watchtower.scope=<scope>
        \\    com.centurylinklabs.watchtower.no-pull=true
        \\    com.centurylinklabs.watchtower.stop-signal=SIGTERM
        \\  
        \\  WatchZ custom labels (ing.wik.watchz.*):
        \\    ing.wik.watchz.enable=true/false
        \\    ing.wik.watchz.monitor-only=true
        \\    ing.wik.watchz.scope=<scope>
        \\    ing.wik.watchz.no-pull=true
        \\    ing.wik.watchz.stop-signal=SIGTERM
        \\
        \\EXAMPLES:
        \\  # List all containers
        \\  watchz --run-once
        \\
        \\  # Monitor specific containers
        \\  watchz nginx redis postgres
        \\
        \\  # Only update containers with enable label
        \\  watchz --label-enable
        \\
        \\  # Filter by scope
        \\  watchz --scope production
        \\
        \\  # Debug mode with all containers
        \\  watchz --debug --include-stopped
        \\
        \\ENVIRONMENT VARIABLES:
        \\  DOCKER_HOST                   Docker socket/host
        \\  WATCHZ_POLL_INTERVAL          Poll interval in seconds
        \\  WATCHZ_DEBUG                  Enable debug mode (true/false)
        \\  WATCHZ_CLEANUP                Remove old images (true/false)
        \\  WATCHZ_LABEL_ENABLE           Only watch labeled containers (true/false)
        \\  WATCHZ_MONITOR_ONLY           Monitor mode (true/false)
        \\  WATCHZ_SCOPE                  Scope filter
        \\  WATCHZ_NOTIFICATION_URL       Notification URL (comma-separated for multiple)
        \\  WATCHZ_NOTIFICATION_LEVEL     Notification level (debug/info/warn/error)
        \\  WATCHZ_NOTIFICATION_REPORT    Send session report (true/false)
        \\
        \\
    , .{});
}

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
