const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const auth = @import("auth.zig");
const log = @import("../utils/log.zig");

/// Registry client for interacting with Docker registries
pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    authenticator: auth.Authenticator,
    http_client: http.Client,

    pub fn init(allocator: std.mem.Allocator) RegistryClient {
        return .{
            .allocator = allocator,
            .authenticator = auth.Authenticator.init(allocator),
            .http_client = http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *RegistryClient) void {
        self.authenticator.deinit();
        self.http_client.deinit();
    }

    /// Add authentication credentials for a registry
    pub fn addAuth(self: *RegistryClient, registry: []const u8, username: []const u8, password: []const u8) !void {
        try self.authenticator.addAuth(registry, username, password);
    }

    /// Get the manifest digest for an image
    /// This is the core operation for checking if an image has been updated
    pub fn getManifestDigest(
        self: *RegistryClient,
        image_ref: *const types.ImageRef,
    ) ![]const u8 {
        const repository_path = try image_ref.getRepositoryPath(self.allocator);
        defer self.allocator.free(repository_path);

        // For Docker Hub, we need to authenticate
        var token_opt: ?types.TokenResponse = null;
        defer if (token_opt) |*t| t.deinit();

        if (std.mem.eql(u8, image_ref.registry, "docker.io")) {
            token_opt = try self.authenticator.getDockerHubToken(repository_path);
        }

        // Build the manifest URL
        const url = if (std.mem.eql(u8, image_ref.registry, "docker.io"))
            try std.fmt.allocPrint(
                self.allocator,
                "https://registry-1.docker.io/v2/{s}/manifests/{s}",
                .{ repository_path, image_ref.tag },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "https://{s}/v2/{s}/manifests/{s}",
                .{ image_ref.registry, repository_path, image_ref.tag },
            );
        defer self.allocator.free(url);

        log.debug("Fetching manifest from: {s}", .{url});

        const uri = try std.Uri.parse(url);

        // Build headers - max 4 headers (1 auth + 3 accept)
        var headers_buf: [4]http.Header = undefined;
        var header_count: usize = 0;

        // Add auth header
        var auth_header_value: ?[]u8 = null;
        defer if (auth_header_value) |v| self.allocator.free(v);

        if (token_opt) |token| {
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token.token});
            headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header_value.? };
            header_count += 1;
        } else if (self.authenticator.getAuth(image_ref.registry)) |registry_auth| {
            if (registry_auth.auth) |auth_str| {
                auth_header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{auth_str});
                headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header_value.? };
                header_count += 1;
            }
        }

        // Add Accept headers
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.list.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.oci.image.manifest.v1+json" };
        header_count += 1;

        var req = try self.http_client.request(.HEAD, uri, .{
            .extra_headers = headers_buf[0..header_count],
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            log.err("Failed to fetch manifest for {s}: {}", .{ url, response.head.status });
            return error.ManifestFetchFailed;
        }

        // Extract Docker-Content-Digest header using iterator
        var header_iter = response.head.iterateHeaders();
        while (header_iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "docker-content-digest")) {
                log.debug("Got digest: {s}", .{hdr.value});
                return try self.allocator.dupe(u8, hdr.value);
            }
        }

        log.err("No Docker-Content-Digest header found for {s}", .{url});
        return error.DigestNotFound;
    }

    /// Fetch the full manifest for an image
    pub fn getManifest(
        self: *RegistryClient,
        image_ref: *const types.ImageRef,
    ) ![]const u8 {
        const repository_path = try image_ref.getRepositoryPath(self.allocator);
        defer self.allocator.free(repository_path);

        // For Docker Hub, we need to authenticate
        var token_opt: ?types.TokenResponse = null;
        defer if (token_opt) |*t| t.deinit();

        if (std.mem.eql(u8, image_ref.registry, "docker.io")) {
            token_opt = try self.authenticator.getDockerHubToken(repository_path);
        }

        // Build the manifest URL
        const url = if (std.mem.eql(u8, image_ref.registry, "docker.io"))
            try std.fmt.allocPrint(
                self.allocator,
                "https://registry-1.docker.io/v2/{s}/manifests/{s}",
                .{ repository_path, image_ref.tag },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "https://{s}/v2/{s}/manifests/{s}",
                .{ image_ref.registry, repository_path, image_ref.tag },
            );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        // Build headers - max 4 headers (1 auth + 3 accept)
        var headers_buf: [4]http.Header = undefined;
        var header_count: usize = 0;

        // Add auth header
        var auth_header_value: ?[]u8 = null;
        defer if (auth_header_value) |v| self.allocator.free(v);

        if (token_opt) |token| {
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token.token});
            headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header_value.? };
            header_count += 1;
        } else if (self.authenticator.getAuth(image_ref.registry)) |registry_auth| {
            if (registry_auth.auth) |auth_str| {
                auth_header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{auth_str});
                headers_buf[header_count] = .{ .name = "Authorization", .value = auth_header_value.? };
                header_count += 1;
            }
        }

        // Add Accept headers
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.list.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.oci.image.manifest.v1+json" };
        header_count += 1;

        var req = try self.http_client.request(.GET, uri, .{
            .extra_headers = headers_buf[0..header_count],
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            log.err("Failed to fetch manifest for {s}: {}", .{ url, response.head.status });
            return error.ManifestFetchFailed;
        }

        // Read the manifest body using Reader.allocRemaining
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        return reader.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
    }

    /// Check if an image has an update available
    /// Compares the current digest with the latest digest in the registry
    pub fn checkForUpdate(
        self: *RegistryClient,
        current_digest: []const u8,
        image_name: []const u8,
    ) !types.UpdateCheckResult {
        var image_ref = try types.ImageRef.parse(self.allocator, image_name);
        defer image_ref.deinit();

        log.info("Checking for updates: {s}", .{image_name});

        const latest_digest = try self.getManifestDigest(&image_ref);

        const has_update = !std.mem.eql(u8, current_digest, latest_digest);

        var message: ?[]const u8 = null;
        if (has_update) {
            message = try std.fmt.allocPrint(
                self.allocator,
                "Update available: {s} -> {s}",
                .{ current_digest, latest_digest },
            );
        }

        return .{
            .has_update = has_update,
            .current_digest = try self.allocator.dupe(u8, current_digest),
            .latest_digest = latest_digest,
            .message = message,
            .allocator = self.allocator,
        };
    }

    /// Check multiple images for updates in parallel
    pub fn checkForUpdatesParallel(
        self: *RegistryClient,
        images: []const ImageCheckRequest,
    ) ![]types.UpdateCheckResult {
        // For now, we'll check sequentially
        // TODO: Implement parallel checking with thread pool
        var results = try self.allocator.alloc(types.UpdateCheckResult, images.len);

        for (images, 0..) |image_req, i| {
            results[i] = try self.checkForUpdate(image_req.current_digest, image_req.image_name);
        }

        return results;
    }
};

pub const ImageCheckRequest = struct {
    image_name: []const u8,
    current_digest: []const u8,
};

test "ImageRef parse and reconstruct" {
    const allocator = std.testing.allocator;

    var ref = try types.ImageRef.parse(allocator, "nginx:1.21");
    defer ref.deinit();

    const repo_path = try ref.getRepositoryPath(allocator);
    defer allocator.free(repo_path);

    try std.testing.expectEqualStrings("library/nginx", repo_path);
}

test "RegistryClient init and deinit" {
    const allocator = std.testing.allocator;
    var client = RegistryClient.init(allocator);
    defer client.deinit();
}
