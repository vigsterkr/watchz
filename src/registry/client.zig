const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const auth = @import("auth.zig");
const log = @import("../utils/log.zig");
const decompress_utils = @import("../utils/decompress.zig");

/// Check if an image is definitely a local image ID (not a registry reference)
fn isLocalImage(image_name: []const u8) bool {
    // Only skip images that are definitively local image IDs
    // These start with sha256: and are not pullable from any registry
    return std.mem.startsWith(u8, image_name, "sha256:");
}

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

    /// Discover token endpoint from WWW-Authenticate header in HTTP response
    fn discoverTokenEndpoint(self: *RegistryClient, response_head: anytype) !auth.AuthEndpoint {
        // Look for WWW-Authenticate header
        var header_iter = response_head.iterateHeaders();
        while (header_iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "www-authenticate")) {
                log.debug("Found WWW-Authenticate header: {s}", .{hdr.value});
                return try auth.parseWWWAuthenticate(self.allocator, hdr.value);
            }
        }

        log.warn("No WWW-Authenticate header found in 401 response", .{});
        return error.NoAuthHeaderFound;
    }

    /// Build manifest request headers with optional authorization and standard Accept headers
    /// Returns the number of headers added to the buffer
    fn buildManifestHeaders(
        headers_buf: []http.Header,
        auth_header_value: ?[]const u8,
    ) usize {
        var header_count: usize = 0;

        // Add auth header if provided
        if (auth_header_value) |auth_value| {
            headers_buf[header_count] = .{ .name = "Authorization", .value = auth_value };
            header_count += 1;
        }

        // Add Accept headers for all supported manifest types
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.docker.distribution.manifest.list.v2+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.oci.image.manifest.v1+json" };
        header_count += 1;
        headers_buf[header_count] = .{ .name = "Accept", .value = "application/vnd.oci.image.index.v1+json" };
        header_count += 1;

        return header_count;
    }

    /// Get the manifest digest for an image
    /// This is the core operation for checking if an image has been updated
    pub fn getManifestDigest(
        self: *RegistryClient,
        image_ref: *const types.ImageRef,
    ) ![]const u8 {
        const repository_path = try image_ref.getRepositoryPath(self.allocator);
        defer self.allocator.free(repository_path);

        // Get token for any registry (replaces Docker Hub specific code)
        var token_opt: ?types.TokenResponse = null;
        defer if (token_opt) |*t| t.deinit();

        token_opt = self.authenticator.getRegistryToken(image_ref.registry, repository_path) catch |err| blk: {
            log.debug("Token fetch failed for {s}: {}, trying without auth", .{ image_ref.registry, err });
            break :blk null;
        };

        // Build the manifest URL - Docker Hub uses a different host
        const registry_host = if (std.mem.eql(u8, image_ref.registry, "docker.io"))
            "registry-1.docker.io"
        else
            image_ref.registry;

        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}/v2/{s}/manifests/{s}",
            .{ registry_host, repository_path, image_ref.tag },
        );
        defer self.allocator.free(url);

        log.debug("Fetching manifest from: {s}", .{url});

        const uri = try std.Uri.parse(url);

        // Build headers - max 5 headers (1 auth + 4 accept)
        var headers_buf: [5]http.Header = undefined;

        // Prepare auth header value
        var auth_header_value: ?[]u8 = null;
        defer if (auth_header_value) |v| self.allocator.free(v);

        if (token_opt) |token| {
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token.token});
        } else if (self.authenticator.getAuth(image_ref.registry)) |registry_auth| {
            if (registry_auth.auth) |auth_str| {
                auth_header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{auth_str});
            }
        }

        // Build headers using helper
        var header_count = buildManifestHeaders(&headers_buf, auth_header_value);

        var req = try self.http_client.request(.HEAD, uri, .{
            .extra_headers = headers_buf[0..header_count],
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Handle 401 Unauthorized - discover auth endpoint and retry
        if (response.head.status == .unauthorized) {
            log.debug("Got 401 Unauthorized, attempting to discover auth endpoint", .{});

            // Discover token endpoint from WWW-Authenticate header
            var discovered_endpoint = self.discoverTokenEndpoint(response.head) catch |err| {
                log.warn("Failed to discover auth endpoint: {}", .{err});
                return error.AuthenticationFailed;
            };
            defer discovered_endpoint.deinit();

            log.debug("Discovered auth endpoint - realm: {s}, service: {s}", .{ discovered_endpoint.realm, discovered_endpoint.service });

            // Fetch token using discovered endpoint
            if (token_opt) |*old_token| {
                old_token.deinit();
            }
            token_opt = self.authenticator.fetchTokenFromEndpoint(image_ref.registry, repository_path, &discovered_endpoint) catch |err| {
                log.err("Failed to fetch token from discovered endpoint: {}", .{err});
                log.err("  Registry: {s}", .{image_ref.registry});
                log.err("  Repository: {s}", .{repository_path});
                log.err("  Auth endpoint: {s}", .{discovered_endpoint.realm});
                return error.AuthenticationFailed;
            };

            // Retry request with new token
            if (auth_header_value) |v| {
                self.allocator.free(v);
            }
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token_opt.?.token});

            // Rebuild headers with new token using helper
            header_count = buildManifestHeaders(&headers_buf, auth_header_value);

            // Create new request with token
            var retry_req = try self.http_client.request(.HEAD, uri, .{
                .extra_headers = headers_buf[0..header_count],
            });
            defer retry_req.deinit();

            try retry_req.sendBodiless();
            response = try retry_req.receiveHead(&redirect_buf);

            log.debug("Retry after auth discovery returned status: {}", .{response.head.status});
        }

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

        // Get token for any registry
        var token_opt: ?types.TokenResponse = null;
        defer if (token_opt) |*t| t.deinit();

        token_opt = self.authenticator.getRegistryToken(image_ref.registry, repository_path) catch |err| blk: {
            log.debug("Token fetch failed for {s}: {}, trying without auth", .{ image_ref.registry, err });
            break :blk null;
        };

        // Build the manifest URL - Docker Hub uses a different host
        const registry_host = if (std.mem.eql(u8, image_ref.registry, "docker.io"))
            "registry-1.docker.io"
        else
            image_ref.registry;

        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://{s}/v2/{s}/manifests/{s}",
            .{ registry_host, repository_path, image_ref.tag },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        // Build headers - max 5 headers (1 auth + 4 accept)
        var headers_buf: [5]http.Header = undefined;

        // Prepare auth header value
        var auth_header_value: ?[]u8 = null;
        defer if (auth_header_value) |v| self.allocator.free(v);

        if (token_opt) |token| {
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token.token});
        } else if (self.authenticator.getAuth(image_ref.registry)) |registry_auth| {
            if (registry_auth.auth) |auth_str| {
                auth_header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{auth_str});
            }
        }

        // Build headers using helper
        var header_count = buildManifestHeaders(&headers_buf, auth_header_value);

        var req = try self.http_client.request(.GET, uri, .{
            .extra_headers = headers_buf[0..header_count],
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Handle 401 Unauthorized - discover auth endpoint and retry
        if (response.head.status == .unauthorized) {
            log.debug("Got 401 Unauthorized, attempting to discover auth endpoint", .{});

            // Discover token endpoint from WWW-Authenticate header
            var discovered_endpoint = self.discoverTokenEndpoint(response.head) catch |err| {
                log.warn("Failed to discover auth endpoint: {}", .{err});
                return error.AuthenticationFailed;
            };
            defer discovered_endpoint.deinit();

            log.debug("Discovered auth endpoint - realm: {s}, service: {s}", .{ discovered_endpoint.realm, discovered_endpoint.service });

            // Fetch token using discovered endpoint
            if (token_opt) |*old_token| {
                old_token.deinit();
            }
            token_opt = self.authenticator.fetchTokenFromEndpoint(image_ref.registry, repository_path, &discovered_endpoint) catch |err| {
                log.err("Failed to fetch token from discovered endpoint: {}", .{err});
                log.err("  Registry: {s}", .{image_ref.registry});
                log.err("  Repository: {s}", .{repository_path});
                log.err("  Auth endpoint: {s}", .{discovered_endpoint.realm});
                return error.AuthenticationFailed;
            };

            // Retry request with new token
            if (auth_header_value) |v| {
                self.allocator.free(v);
            }
            auth_header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token_opt.?.token});

            // Rebuild headers with new token using helper
            header_count = buildManifestHeaders(&headers_buf, auth_header_value);

            // Create new request with token
            var retry_req = try self.http_client.request(.GET, uri, .{
                .extra_headers = headers_buf[0..header_count],
            });
            defer retry_req.deinit();

            try retry_req.sendBodiless();
            response = try retry_req.receiveHead(&redirect_buf);

            log.debug("Retry after auth discovery returned status: {}", .{response.head.status});
        }

        if (response.head.status != .ok) {
            log.err("Failed to fetch manifest for {s}: {}", .{ url, response.head.status });
            return error.ManifestFetchFailed;
        }

        // Read the manifest body using Reader.allocRemaining
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        const body = reader.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        // Check Content-Encoding header for compression
        var content_encoding: ?[]const u8 = null;
        var header_iter = response.head.iterateHeaders();
        while (header_iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-encoding")) {
                content_encoding = hdr.value;
                log.debug("Manifest response has Content-Encoding: {s}", .{hdr.value});
                break;
            }
        }

        // Decompress if needed
        const final_body = if (content_encoding) |enc| blk: {
            const is_gzip = std.mem.indexOf(u8, enc, "gzip") != null;

            if (is_gzip) {
                log.debug("Decompressing gzip manifest ({d} bytes compressed)", .{body.len});

                const decompressed = decompress_utils.decompressGzip(self.allocator, body) catch |err| {
                    log.err("Failed to decompress gzip manifest: {}", .{err});
                    self.allocator.free(body);
                    return error.ManifestFetchFailed;
                };

                log.debug("Decompressed manifest to {d} bytes", .{decompressed.len});
                self.allocator.free(body); // Free compressed body
                break :blk decompressed;
            } else {
                log.debug("Unsupported Content-Encoding: {s}, using as-is", .{enc});
                break :blk body;
            }
        } else body;

        return final_body;
    }

    /// Check if an image has an update available
    /// Compares the current digest with the latest digest in the registry
    pub fn checkForUpdate(
        self: *RegistryClient,
        current_digest: []const u8,
        image_name: []const u8,
    ) !types.UpdateCheckResult {
        // Skip digest-pinned images - user has explicitly pinned this version
        var image_ref = try types.ImageRef.parse(self.allocator, image_name);
        defer image_ref.deinit();

        if (image_ref.digest != null) {
            log.info("⏭ Skipping {s} - image is digest-pinned (version locked)", .{image_name});
            return .{
                .has_update = false,
                .current_digest = try self.allocator.dupe(u8, current_digest),
                .latest_digest = try self.allocator.dupe(u8, current_digest),
                .message = try self.allocator.dupe(u8, "Skipped: digest-pinned image"),
                .allocator = self.allocator,
            };
        }

        // Skip locally-built images
        if (isLocalImage(image_name)) {
            log.info("⏭ Skipping {s} - appears to be a locally-built image", .{image_name});
            return .{
                .has_update = false,
                .current_digest = try self.allocator.dupe(u8, current_digest),
                .latest_digest = try self.allocator.dupe(u8, current_digest),
                .message = try self.allocator.dupe(u8, "Skipped: local image"),
                .allocator = self.allocator,
            };
        }

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

test "isLocalImage detects sha256 image IDs" {
    // SHA256 image IDs should be detected as local
    try std.testing.expect(isLocalImage("sha256:abc123def456"));
    try std.testing.expect(isLocalImage("sha256:8a8b79bd46f3ad2285f42e7222b0061406c2d3443d0ee0d1dbc18b9e6e238e4f"));
}

test "isLocalImage allows Docker Hub library images" {
    // Official Docker Hub library images should NOT be detected as local
    try std.testing.expect(!isLocalImage("influxdb:latest"));
    try std.testing.expect(!isLocalImage("nginx:1.21"));
    try std.testing.expect(!isLocalImage("redis:alpine"));
    try std.testing.expect(!isLocalImage("postgres"));
    try std.testing.expect(!isLocalImage("ubuntu:22.04"));
}

test "isLocalImage allows namespaced Docker Hub images" {
    // User namespaced images should NOT be detected as local
    try std.testing.expect(!isLocalImage("grafana/grafana:latest"));
    try std.testing.expect(!isLocalImage("library/nginx:latest"));
}

test "isLocalImage allows custom registry images" {
    // Custom registry images should NOT be detected as local
    try std.testing.expect(!isLocalImage("ghcr.io/owner/repo:tag"));
    try std.testing.expect(!isLocalImage("registry.example.com:5000/namespace/repo:tag"));
    try std.testing.expect(!isLocalImage("localhost:5000/myapp:dev"));
}
