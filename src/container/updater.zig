const std = @import("std");
const zio = @import("zio");
const docker = @import("../docker/client.zig");
const types = @import("../docker/types.zig");
const registry = @import("../registry/client.zig");
const registry_types = @import("../registry/types.zig");
const log = @import("../utils/log.zig");
const config_mod = @import("../config.zig");
const notifier = @import("../notifications/notifier.zig");
const config_builder = @import("config_builder.zig");

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

/// Extract the manifest digest from an image's RepoDigests that matches the given image reference
/// RepoDigests format: ["registry/namespace/repo@sha256:digest", ...]
/// We need to find the one that matches our image and extract just the "sha256:digest" part
fn extractManifestDigest(allocator: std.mem.Allocator, repo_digests: []const []const u8, image_name: []const u8) !?[]const u8 {
    if (repo_digests.len == 0) {
        return null;
    }

    // Parse the image name to get registry/repo info
    var image_ref = registry_types.ImageRef.parse(allocator, image_name) catch {
        log.warn("Failed to parse image name: {s}", .{image_name});
        return null;
    };
    defer image_ref.deinit();

    const repo_path = try image_ref.getRepositoryPath(allocator);
    defer allocator.free(repo_path);

    // Look for a RepoDigest that matches our image
    for (repo_digests) |repo_digest| {
        // RepoDigest format: "registry.io/namespace/repo@sha256:abcdef..."
        if (std.mem.indexOf(u8, repo_digest, "@")) |at_idx| {
            const image_part = repo_digest[0..at_idx];
            const digest_part = repo_digest[at_idx + 1 ..];

            // Check if this repo digest matches our image
            // We need to match: registry + repo_path
            const expected_prefix = if (std.mem.eql(u8, image_ref.registry, "docker.io"))
                try std.fmt.allocPrint(allocator, "docker.io/{s}", .{repo_path})
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ image_ref.registry, repo_path });
            defer allocator.free(expected_prefix);

            if (std.mem.eql(u8, image_part, expected_prefix)) {
                log.debug("Found matching RepoDigest: {s}", .{repo_digest});
                return try allocator.dupe(u8, digest_part);
            }
        }
    }

    // If no exact match, fall back to the first digest
    // This handles cases where the registry format might differ slightly
    if (repo_digests.len > 0) {
        if (std.mem.indexOf(u8, repo_digests[0], "@")) |at_idx| {
            const digest_part = repo_digests[0][at_idx + 1 ..];
            log.debug("Using first RepoDigest as fallback: {s}", .{repo_digests[0]});
            return try allocator.dupe(u8, digest_part);
        }
    }

    return null;
}

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
        log.debug("Checking if container {s} needs update", .{container.name});

        // Inspect the image to get RepoDigests (manifest digests)
        var image_info = self.docker_client.inspectImage(rt, container.image) catch |err| {
            log.warn("Failed to inspect image {s}: {}", .{ container.image, err });
            // Fall back to using image_id if inspect fails
            const current_digest = container.image_id;
            var result = try self.registry_client.checkForUpdate(current_digest, container.image);
            defer result.deinit();
            return result.has_update;
        };
        defer image_info.deinit();

        // Extract the manifest digest from RepoDigests
        const current_digest_opt = try extractManifestDigest(
            self.allocator,
            image_info.repo_digests.items,
            container.image,
        );

        if (current_digest_opt) |current_digest| {
            defer self.allocator.free(current_digest);

            log.debug("Using manifest digest from RepoDigests: {s}", .{current_digest});

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
        } else {
            // No RepoDigests found - likely a locally built image
            log.info("⏭ Skipping {s} - no RepoDigests found (likely local or untagged image)", .{container.name});
            return false;
        }
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

        // Step 0: Inspect container to get full configuration
        log.info("Inspecting container to preserve configuration: {s}", .{container.name});
        var container_details = self.docker_client.inspectContainer(rt, container.id) catch |err| {
            result.error_msg = try std.fmt.allocPrint(
                self.allocator,
                "Failed to inspect container: {}",
                .{err},
            );
            try self.sendErrorNotification(container.name, "Failed to inspect container", err);
            return result;
        };
        defer container_details.deinit();

        log.debug("Container has {d} networks configured", .{container_details.network_settings.networks.count()});

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

        // Step 4: Create new container with full configuration preserved
        log.info("Building container configuration...", .{});
        const config_json = try config_builder.buildCreateConfig(
            self.allocator,
            &container_details,
            container.image,
        );
        defer self.allocator.free(config_json);

        log.debug("Container config JSON (first 500 chars): {s}", .{config_json[0..@min(500, config_json.len)]});

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

        // Step 5: Handle multi-network containers
        // Docker API only allows one network at create time, so we need to:
        // 1. Disconnect from the initial network (if not host mode)
        // 2. Reconnect to all original networks with proper endpoint configs
        const is_host_network = std.mem.eql(u8, container_details.host_config.network_mode, "host");

        if (!is_host_network and container_details.network_settings.networks.count() > 0) {
            log.debug("Reconnecting to {d} networks...", .{container_details.network_settings.networks.count()});

            // Get the first network that we created with
            var first_network_iter = container_details.network_settings.networks.iterator();
            const first_network = first_network_iter.next();

            // Disconnect from the first network
            if (first_network) |network| {
                log.debug("Disconnecting from initial network: {s}", .{network.key_ptr.*});
                self.docker_client.disconnectNetwork(rt, network.key_ptr.*, new_id, true) catch |err| {
                    log.warn("Failed to disconnect from network {s}: {}", .{ network.key_ptr.*, err });
                };
            }

            // Reconnect to all original networks
            var network_iter = container_details.network_settings.networks.iterator();
            while (network_iter.next()) |entry| {
                const network_name = entry.key_ptr.*;
                const endpoint = entry.value_ptr.*;

                log.debug("Connecting to network: {s}", .{network_name});

                // Build endpoint config
                var endpoint_config: std.ArrayList(u8) = .{};
                defer endpoint_config.deinit(self.allocator);

                const writer = endpoint_config.writer(self.allocator);
                try writer.writeAll("{");

                // Add aliases, filtering out old container ID
                if (endpoint.aliases.items.len > 0) {
                    try writer.writeAll("\"Aliases\":[");
                    var first_alias = true;
                    const short_id = if (container_details.id.len >= 12) container_details.id[0..12] else container_details.id;

                    for (endpoint.aliases.items) |alias| {
                        // Skip the old container ID alias
                        if (std.mem.eql(u8, alias, short_id)) continue;

                        if (!first_alias) try writer.writeAll(",");
                        first_alias = false;
                        try writer.print("\"{s}\"", .{alias});
                    }
                    try writer.writeAll("]");
                }

                try writer.writeAll("}");

                const endpoint_json = try endpoint_config.toOwnedSlice(self.allocator);
                defer self.allocator.free(endpoint_json);

                self.docker_client.connectNetwork(rt, network_name, new_id, endpoint_json) catch |err| {
                    log.warn("Failed to connect to network {s}: {}", .{ network_name, err });
                    // Continue with other networks
                };
            }
        }

        // Step 6: Start new container
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

        // Step 7: Cleanup old image if requested
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
