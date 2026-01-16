const std = @import("std");
const zio = @import("zio");
const docker = @import("../docker/client.zig");
const types = @import("../docker/types.zig");
const registry = @import("../registry/client.zig");
const log = @import("../utils/log.zig");
const config_mod = @import("../config.zig");
const notifier = @import("../notifications/notifier.zig");

pub const UpdateResult = struct {
    container_id: []const u8,
    container_name: []const u8,
    old_image_id: []const u8,
    new_image_id: ?[]const u8,
    success: bool,
    error_msg: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UpdateResult) void {
        self.allocator.free(self.container_id);
        self.allocator.free(self.container_name);
        self.allocator.free(self.old_image_id);
        if (self.new_image_id) |id| self.allocator.free(id);
        if (self.error_msg) |msg| self.allocator.free(msg);
    }
};

pub const ContainerUpdater = struct {
    docker_client: *docker.AsyncClient,
    registry_client: *registry.RegistryClient,
    config: *config_mod.Config,
    notification_manager: ?*notifier.NotificationManager,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        docker_client: *docker.AsyncClient,
        registry_client: *registry.RegistryClient,
        cfg: *config_mod.Config,
        notification_mgr: ?*notifier.NotificationManager,
    ) ContainerUpdater {
        return ContainerUpdater{
            .docker_client = docker_client,
            .registry_client = registry_client,
            .config = cfg,
            .notification_manager = notification_mgr,
            .allocator = allocator,
        };
    }

    /// Send an error notification
    fn sendErrorNotification(self: *ContainerUpdater, container_name: []const u8, title: []const u8, err: anyerror) !void {
        if (self.notification_manager) |nm| {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Container {s}: {}",
                .{ container_name, err },
            );
            defer self.allocator.free(msg);

            const notif = notifier.Notification.init(.error_level, title, msg);
            nm.notify(notif);
        }
    }

    /// Check if a container needs updating
    pub fn needsUpdate(
        self: *ContainerUpdater,
        rt: *zio.Runtime,
        container: *const types.Container,
    ) !bool {
        _ = rt;
        log.debug("Checking if container {s} needs update", .{container.name});

        // Extract current digest from container
        const current_digest = container.image_id;

        // Check registry for latest digest
        var result = try self.registry_client.checkForUpdate(current_digest, container.image);
        defer result.deinit();

        if (result.has_update) {
            log.info("Update available for {s}: {s} -> {s}", .{
                container.name,
                result.current_digest,
                result.latest_digest,
            });
            return true;
        }

        log.debug("No update available for {s}", .{container.name});
        return false;
    }

    /// Update a single container
    pub fn updateContainer(
        self: *ContainerUpdater,
        rt: *zio.Runtime,
        container: *const types.Container,
    ) !UpdateResult {
        log.info("Updating container: {s}", .{container.name});

        var result = UpdateResult{
            .container_id = try self.allocator.dupe(u8, container.id),
            .container_name = try self.allocator.dupe(u8, container.name),
            .old_image_id = try self.allocator.dupe(u8, container.image_id),
            .new_image_id = null,
            .success = false,
            .error_msg = null,
            .allocator = self.allocator,
        };
        errdefer result.deinit();

        // Step 1: Pull new image
        if (!self.config.no_pull) {
            log.info("Pulling new image: {s}", .{container.image});
            self.docker_client.pullImage(rt, container.image) catch |err| {
                result.error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Failed to pull image: {}",
                    .{err},
                );
                try self.sendErrorNotification(container.name, "Failed to pull image", err);
                return result;
            };
        } else {
            log.info("Skipping image pull (no_pull enabled)", .{});
        }

        // Step 2: Stop old container
        if (!self.config.no_restart) {
            log.info("Stopping container: {s}", .{container.name});
            self.docker_client.stopContainer(rt, container.id, self.config.stop_timeout) catch |err| {
                result.error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Failed to stop container: {}",
                    .{err},
                );
                try self.sendErrorNotification(container.name, "Failed to stop container", err);
                return result;
            };
        }

        // Step 3: Remove old container
        log.info("Removing old container: {s}", .{container.name});
        self.docker_client.removeContainer(rt, container.id, false) catch |err| {
            result.error_msg = try std.fmt.allocPrint(
                self.allocator,
                "Failed to remove container: {}",
                .{err},
            );
            // Try to restart the old container as rollback
            if (!self.config.no_restart) {
                log.warn("Attempting to restart old container as rollback", .{});
                self.docker_client.startContainer(rt, container.id) catch |start_err| {
                    log.err("Failed to restart old container: {}", .{start_err});
                };
            }
            try self.sendErrorNotification(container.name, "Failed to remove container", err);
            return result;
        };

        // Step 4: Create new container with same configuration
        // For now, we'll use a simplified config - in production this should
        // recreate the container with all its original settings
        const config_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"Image\": \"{s}\"}}",
            .{container.image},
        );
        defer self.allocator.free(config_json);

        const new_id = self.docker_client.createContainer(rt, container.name, config_json) catch |err| {
            result.error_msg = try std.fmt.allocPrint(
                self.allocator,
                "Failed to create new container: {}",
                .{err},
            );
            try self.sendErrorNotification(container.name, "Failed to create new container", err);
            return result;
        };
        result.new_image_id = new_id;

        // Step 5: Start new container
        if (!self.config.no_restart) {
            log.info("Starting new container: {s}", .{container.name});
            self.docker_client.startContainer(rt, new_id) catch |err| {
                result.error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Failed to start new container: {}",
                    .{err},
                );
                // Try to remove the failed container
                self.docker_client.removeContainer(rt, new_id, false) catch |rm_err| {
                    log.err("Failed to remove failed container: {}", .{rm_err});
                };
                try self.sendErrorNotification(container.name, "Failed to start new container", err);
                return result;
            };
        }

        // Step 6: Cleanup old image if requested
        if (self.config.cleanup) {
            log.info("Removing old image: {s}", .{container.image_id});
            // Note: This needs to be implemented in docker client
            log.warn("Image cleanup not yet implemented", .{});
        }

        result.success = true;
        log.info("Container {s} updated successfully!", .{container.name});

        // Send success notification
        if (self.notification_manager) |nm| {
            const notif = notifier.Notification.init(
                .info,
                "Container Updated",
                try std.fmt.allocPrint(
                    self.allocator,
                    "Successfully updated container {s} from {s} to new image",
                    .{ container.name, container.image },
                ),
            );
            defer self.allocator.free(notif.message);
            nm.notify(notif);
        }

        return result;
    }

    /// Update multiple containers - either sequentially or in parallel based on config
    pub fn updateContainers(
        self: *ContainerUpdater,
        rt: *zio.Runtime,
        containers: []const types.Container,
    ) ![]UpdateResult {
        log.info("Updating {d} containers", .{containers.len});

        var results: std.ArrayListAligned(UpdateResult, null) = .{};
        errdefer {
            for (results.items) |*r| r.deinit();
            results.deinit(self.allocator);
        }

        if (self.config.rolling_restart or containers.len == 1) {
            // Sequential updates for rolling restart or single container
            log.info("Performing sequential updates (rolling restart mode)", .{});
            for (containers) |*container| {
                const result = try self.updateContainer(rt, container);
                try results.append(self.allocator, result);

                // Wait between updates if rolling restart
                if (self.config.rolling_restart and containers.len > 1) {
                    log.info("Rolling restart: waiting 5s before next update", .{});
                    try rt.sleep(zio.Duration.fromSeconds(5));
                }
            }
        } else {
            // Parallel updates using ZIO spawn
            log.info("Performing parallel updates", .{});

            var tasks = try self.allocator.alloc(zio.JoinHandle(UpdateResult), containers.len);
            defer self.allocator.free(tasks);

            // Spawn all update tasks
            for (containers, 0..) |*container, i| {
                const ctx = UpdateContext{
                    .updater = self,
                    .rt = rt,
                    .container = container,
                };
                tasks[i] = try rt.spawn(updateContainerTask, .{ctx}, .{});
            }

            // Wait for all tasks to complete and collect results
            for (tasks) |*task| {
                const result = task.join(rt);
                try results.append(self.allocator, result);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }
};

/// Context for parallel container updates
const UpdateContext = struct {
    updater: *ContainerUpdater,
    rt: *zio.Runtime,
    container: *const types.Container,
};

/// Task function for spawning container updates with ZIO
fn updateContainerTask(ctx: UpdateContext) UpdateResult {
    return ctx.updater.updateContainer(ctx.rt, ctx.container) catch |err| {
        const allocator = ctx.updater.allocator;
        return UpdateResult{
            .container_id = allocator.dupe(u8, ctx.container.id) catch "unknown",
            .container_name = allocator.dupe(u8, ctx.container.name) catch "unknown",
            .old_image_id = allocator.dupe(u8, ctx.container.image_id) catch "unknown",
            .new_image_id = null,
            .success = false,
            .error_msg = std.fmt.allocPrint(allocator, "Update failed: {}", .{err}) catch null,
            .allocator = allocator,
        };
    };
}
