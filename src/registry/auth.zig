const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const log = @import("../utils/log.zig");
const encoding = @import("../utils/encoding.zig");

/// Authenticator handles Docker registry authentication
pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    config: std.StringHashMap(types.AuthConfig),

    pub fn init(allocator: std.mem.Allocator) Authenticator {
        return .{
            .allocator = allocator,
            .config = std.StringHashMap(types.AuthConfig).init(allocator),
        };
    }

    pub fn deinit(self: *Authenticator) void {
        var iter = self.config.iterator();
        while (iter.next()) |entry| {
            var auth = entry.value_ptr.*;
            auth.deinit();
        }
        self.config.deinit();
    }

    /// Add authentication config for a registry
    pub fn addAuth(self: *Authenticator, registry: []const u8, username: []const u8, password: []const u8) !void {
        var auth = try types.AuthConfig.init(self.allocator, registry);
        auth.username = try self.allocator.dupe(u8, username);
        auth.password = try self.allocator.dupe(u8, password);

        // Create base64 encoded auth string
        auth.auth = try encoding.encodeBasicAuth(self.allocator, username, password);

        try self.config.put(registry, auth);
    }

    /// Get authentication config for a registry
    pub fn getAuth(self: *Authenticator, registry: []const u8) ?*types.AuthConfig {
        return self.config.getPtr(registry);
    }

    /// Get Docker Hub token for accessing a repository
    /// This implements the Docker Registry V2 token authentication flow
    pub fn getDockerHubToken(
        self: *Authenticator,
        repository: []const u8,
    ) !types.TokenResponse {
        const auth = self.getAuth("docker.io") orelse {
            // Anonymous access
            return try self.getAnonymousToken(repository);
        };

        return try self.getAuthenticatedToken(repository, auth);
    }

    /// Helper to perform HTTP GET and return body
    fn httpGetWithAuth(
        self: *Authenticator,
        url: []const u8,
        auth_header: ?[]const u8,
    ) ![]u8 {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        // Build extra headers array
        var extra_headers_buf: [1]http.Header = undefined;
        var extra_headers: []const http.Header = &.{};

        if (auth_header) |ah| {
            extra_headers_buf[0] = .{ .name = "Authorization", .value = ah };
            extra_headers = extra_headers_buf[0..1];
        }

        var req = try client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Read body using Reader.allocRemaining
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        return reader.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
    }

    /// Get token for authenticated Docker Hub access
    fn getAuthenticatedToken(
        self: *Authenticator,
        repository: []const u8,
        auth_config: *types.AuthConfig,
    ) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull",
            .{repository},
        );
        defer self.allocator.free(url);

        // Build basic auth header
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (auth_config.username) |username| {
            if (auth_config.password) |password| {
                auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.err("Failed to get Docker Hub token: {}", .{err});
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return try parseTokenResponse(self.allocator, body);
    }

    /// Get anonymous token for Docker Hub
    fn getAnonymousToken(self: *Authenticator, repository: []const u8) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull",
            .{repository},
        );
        defer self.allocator.free(url);

        const body = self.httpGetWithAuth(url, null) catch |err| {
            log.err("Failed to get anonymous Docker Hub token: {}", .{err});
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return try parseTokenResponse(self.allocator, body);
    }

    /// Get token for private registry (if it uses token auth)
    pub fn getPrivateRegistryToken(
        self: *Authenticator,
        registry: []const u8,
        repository: []const u8,
        auth_endpoint: []const u8,
        service: []const u8,
    ) !types.TokenResponse {
        const auth = self.getAuth(registry);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}?service={s}&scope=repository:{s}:pull",
            .{ auth_endpoint, service, repository },
        );
        defer self.allocator.free(url);

        // Build basic auth header if available
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (auth) |a| {
            if (a.username) |username| {
                if (a.password) |password| {
                    auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
                }
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.err("Failed to get private registry token: {}", .{err});
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return try parseTokenResponse(self.allocator, body);
    }
};

/// Parse JSON token response from registry
fn parseTokenResponse(allocator: std.mem.Allocator, json_data: []const u8) !types.TokenResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Token can be in either "token" or "access_token" field
    const token_value = root.get("token") orelse root.get("access_token") orelse {
        return error.InvalidTokenResponse;
    };

    var response = types.TokenResponse{
        .token = try allocator.dupe(u8, token_value.string),
        .access_token = null,
        .expires_in = null,
        .issued_at = null,
        .allocator = allocator,
    };

    if (root.get("access_token")) |at| {
        response.access_token = try allocator.dupe(u8, at.string);
    }

    if (root.get("expires_in")) |exp| {
        response.expires_in = exp.integer;
    }

    if (root.get("issued_at")) |issued| {
        response.issued_at = try allocator.dupe(u8, issued.string);
    }

    return response;
}

test "ImageRef parsing - simple image" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expectEqualStrings("latest", ref.tag);
}

test "ImageRef parsing - with tag" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx:1.21");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expectEqualStrings("1.21", ref.tag);
}

test "ImageRef parsing - with namespace" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "myuser/myapp:v1.0");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("myuser", ref.namespace);
    try std.testing.expectEqualStrings("myapp", ref.repository);
    try std.testing.expectEqualStrings("v1.0", ref.tag);
}

test "ImageRef parsing - with registry" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "ghcr.io/owner/repo:latest");
    defer ref.deinit();

    try std.testing.expectEqualStrings("ghcr.io", ref.registry);
    try std.testing.expectEqualStrings("owner", ref.namespace);
    try std.testing.expectEqualStrings("repo", ref.repository);
    try std.testing.expectEqualStrings("latest", ref.tag);
}

test "ImageRef parsing - with digest" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx@sha256:abc123");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expect(ref.digest != null);
    try std.testing.expectEqualStrings("sha256:abc123", ref.digest.?);
}
